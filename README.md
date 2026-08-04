
# Requirements for ALL backup jobs

- AWS S3 Credentials. Regardless of whether you backup google team drives or github repos, you will need these environment variables to be set:

```bash
export AWS_DEFAULT_REGION=us-west-2 # must be the same region as the bucket
export S3_BUCKET_NAME="bucket-name"
export AWS_ACCESS_KEY_ID=XXXXXXXXXXXXXXXXXXXXX 
export AWS_SECRET_ACCESS_KEY=XXXXXXXXXXXXXXXXXXXXX
```

# GitHub Organization backups

Following variables must be set

```bash
export GITHUB_ORG_TO_BACKUP="GlueOps" # Set this to the organization you want to backup. The GITHUB_TOKEN must have read access to all the repos in this organization.
export GITHUB_TOKEN="" # GitH needs to have read access to all repositories within the organization. We use the fine grained access tokens (beta feature)
```

- To create a GITHUB_TOKEN use the newer fine grained tokens:

<img width="823" alt="image" src="https://github.com/GlueOps/backup-tools/assets/6570292/52599edf-100b-4f9a-987d-de5505d603b8">

- Example backup

```bash
docker build . -t backup && docker run -it backup
# Export ALL the variables required as mentioned in this README.md and then run:
backup-github
```

# NFS backups

Full-fidelity [restic](https://restic.net/) backup of an NFS export mounted at
`/data`, plus a restore path. The export is expected to be laid out as
`/data/<group>/<subject>/`, where `<group>` is a cohort/tenant directory and
`<subject>` is the unit you would restore individually.

Unlike the other jobs in this image, this one does **not** use `S3_BUCKET_NAME`.
restic addresses its own repository, and **the URL scheme selects the backend** —
these scripts are not S3-specific:

```bash
export RESTIC_REPOSITORY="..."      # see the backend table below
export RESTIC_PASSWORD="XXXXXXXX"   # ESCROW THIS OUT OF BAND -- see the warning below
```

## Backends

Set `RESTIC_REPOSITORY` to the URL for your target and provide its credentials.
Everything is read from the environment, so in Kubernetes these are simply keys
in the secret projected via `envFrom` — no values-file change per backend.

| Backend | `RESTIC_REPOSITORY` | Credentials |
|---|---|---|
| **S3-compatible** — AWS, Hetzner Object Storage, Cloudflare R2, Backblaze B2 (S3 API), MinIO, Wasabi | `s3:https://<endpoint>/<bucket>/<prefix>` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, optionally `AWS_DEFAULT_REGION` |
| **SFTP** — incl. Hetzner Storage Box | `sftp:<user>@<host>:/<path>` | `RESTIC_SSH_KEY`, `RESTIC_SSH_KNOWN_HOSTS` (both file paths — see below) |
| **Backblaze B2** (native) | `b2:<bucket>:<path>` | `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY` |
| **Azure Blob** | `azure:<container>:/` | `AZURE_ACCOUNT_NAME` + `AZURE_ACCOUNT_KEY` or `AZURE_ACCOUNT_SAS` |
| **Google Cloud Storage** | `gs:<bucket>:/` | `GOOGLE_PROJECT_ID` + `GOOGLE_APPLICATION_CREDENTIALS` (path to a mounted JSON key) or `GOOGLE_ACCESS_TOKEN` |
| **OpenStack Swift** | `swift:<container>:/<path>` | `OS_AUTH_URL`, `OS_USERNAME`, `OS_PASSWORD`, … (v1: `ST_AUTH`, `ST_USER`, `ST_KEY`) |
| **REST server** | `rest:https://<host>:8000/` | `RESTIC_REST_USERNAME`, `RESTIC_REST_PASSWORD` |
| **Local path / mounted volume** | `/mnt/backup` | none |

`rclone:` URLs are detected and rejected with a clear message — rclone is not
installed in this image.

Missing credentials are caught **before** restic runs, and the error names the
exact variables for the backend you selected.

### SFTP specifics

`RESTIC_SSH_KEY` and `RESTIC_SSH_KNOWN_HOSTS` are **paths to mounted files**, not
values — `envFrom` cannot deliver files, so mount the secret as a volume.

The key is copied to a private location and `chmod 600` at startup. This is not
cosmetic: ssh refuses a private key that is group- or world-readable, Kubernetes
mounts secrets read-only owned by root, and the restore job runs as a non-root
uid — so the key cannot be used in place.

Host keys must be **pinned**; there is no option to skip verification. Generate
the file once:

```bash
ssh-keyscan -t ed25519 <host> > known_hosts
```

To manage the connection yourself (jump host, custom ssh wrapper), set
`sftp.command` or `sftp.args` via `RESTIC_EXTRA_OPTS` — the built-in arguments
are then not injected, because restic rejects `sftp.command` and `sftp.args`
together.

### Tuning

`RESTIC_EXTRA_OPTS` is passed through as `-o` options, space separated:

```bash
export RESTIC_EXTRA_OPTS="s3.connections=10 sftp.connections=8"
```

### Creating the repository

Auto-init is **gated**. On first run only:

```bash
export ALLOW_REPO_INIT=true
```

then remove it. `restic cat config` fails identically whether the repository is
missing, the password is wrong, or the backend is unreachable — so without this
gate a typo in `RESTIC_REPOSITORY` would silently create a *new empty repository*,
back up into it, and report success. The shrink guard cannot catch that either,
because it sees "no previous snapshot — first run".

Deployment-specific values — set these per environment, they are **not**
hardcoded in the scripts:

| Variable | Default | Used by | Meaning |
|---|---|---|---|
| `BACKUP_HOST` | `foobar` | both | The `--host` label restic stamps on snapshots and filters by. Not a hostname that gets resolved or connected to. **Must be identical for backup and restore**, or the restore's filter matches nothing. |
| `RESTORE_TERM` | `foobar` | `restore-nfs` | The `<group>` directory under `/data`. |
| `RESTIC_KEEP_TAGS` | unset | `backup-nfs prune` | Comma-separated tags pinned against pruning. |
| `HEARTBEAT_URL` | unset | `backup-nfs backup` | External dead-man's switch, pinged on success. |
| `ALLOW_REPO_INIT` | `false` | both | Permit creating the repository. Set for the first run only. |
| `RESTIC_EXTRA_OPTS` | unset | both | Space-separated `-o` options for backend tuning. |
| `RESTIC_SSH_KEY` | unset | sftp | Path to a mounted SSH private key. |
| `RESTIC_SSH_KNOWN_HOSTS` | unset | sftp | Path to a mounted `known_hosts`. Required — host keys are always verified. |

> **If `RESTIC_PASSWORD` is lost the repository is mathematically unrecoverable.**
> Do not store it only in the Vault whose backups you would need it to restore.

## Backup

```bash
backup-nfs backup    # full backup of /data -- no excludes, full metadata
backup-nfs prune     # apply retention, then reclaim space (needs delete-capable creds)
backup-nfs verify    # restic check + restore the canary and assert it is fresh
```

`backup` requires uid 0 and an export configured with `no_root_squash`. Without
it, files that are not world-readable are silently skipped and restores cannot
set ownership; the script treats restic's exit 3 as a hard failure so this fails
loudly rather than shipping an unusable backup.

`prune` retention: `--keep-last 7 --keep-daily 14 --keep-weekly 8
--keep-monthly 24 --keep-yearly 10`, plus any tags named in `RESTIC_KEEP_TAGS`
(comma-separated) which are pinned permanently.

## Restore

```bash
export BACKUP_HOST=foobar RESTORE_TERM=foobar

# one directory under /data/<group>/<subject>
RESTORE_MODE=list      RESTORE_STUDENT=foo                          restore-nfs student
RESTORE_MODE=additive  RESTORE_STUDENT=foo RESTORE_SNAPSHOT_ID=abc  restore-nfs student

# the whole export
RESTORE_MODE=verify RESTORE_SNAPSHOT_ID=abc  restore-nfs full
```

| Subcommand | Modes | Default writes anything? |
|---|---|---|
| `student` | `list`, `additive`, `overwrite`, `exact` | No — `list` |
| `full` | `verify`, `stage`, `commit` | No — `verify` |

`additive` only creates files that do not already exist, so it cannot destroy
anything. `overwrite` and `exact` take a durable pre-restore restic snapshot
first. `exact` and `commit` additionally require `RESTORE_CONFIRM` set to a token
bound to the resolved snapshot id — the script prints the expected value.

# Google Drive Shared Drive Backups

## note this only works for shared team drives. we do not have anything to backup personal drives

- First the drive needs to be shared to our service account: `rclone@glueops.dev` with `Contributor" access
- The team drive ID can be found from the URL. Example: https://drive.google.com/drive/folders/0ZZH9DD53YuyEaYU7sqb would have a team drive ID of: `0ZZH9DD53YuyEaYU7sqb`

Following variables must be set

```bash
export RCLONE_DRIVE_SERVICE_ACCOUNT_CREDENTIALS='<<json-without \n (newlines)>>' # Get this from the IAM user in the rclone google cloud service account project and remove all newlines \n
export RCLONE_DRIVE_TEAM_DRIVE="XXXXXXXXXXXXXX" # team drive id ex. `0ZZH9DD53YuyEaYU7sqb`
```

- Example to run a download of the team drive to local
  
```bash
docker build . -t backup && docker run -it backup
# Export ALL the variables required as mentioned in this README.md and then run:
./gdrive-backup.sh
```
