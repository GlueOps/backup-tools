
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

Unlike the other jobs in this image, this one does **not** use `S3_BUCKET_NAME` —
restic addresses its own repository:

```bash
export RESTIC_REPOSITORY="s3:https://s3.<region>.example.com/<bucket>/<prefix>"
export RESTIC_PASSWORD="XXXXXXXX"   # ESCROW THIS OUT OF BAND -- see the warning below
export AWS_ACCESS_KEY_ID=XXXXXXXXXXXXXXXXXXXXX
export AWS_SECRET_ACCESS_KEY=XXXXXXXXXXXXXXXXXXXXX
export AWS_DEFAULT_REGION=<region>
```

Deployment-specific values — set these per environment, they are **not**
hardcoded in the scripts:

| Variable | Default | Used by | Meaning |
|---|---|---|---|
| `BACKUP_HOST` | `foobar` | both | The `--host` label restic stamps on snapshots and filters by. Not a hostname that gets resolved or connected to. **Must be identical for backup and restore**, or the restore's filter matches nothing. |
| `RESTORE_TERM` | `foobar` | `restore-nfs` | The `<group>` directory under `/data`. |
| `RESTIC_KEEP_TAGS` | unset | `backup-nfs prune` | Comma-separated tags pinned against pruning. |
| `HEARTBEAT_URL` | unset | `backup-nfs backup` | External dead-man's switch, pinged on success. |

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
