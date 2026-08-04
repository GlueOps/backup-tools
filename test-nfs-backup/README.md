# NFS backup/restore end-to-end test

Exercises `backup-nfs` and `restore-nfs` against a local restic repository
inside the built image. Covers the metadata fidelity the design promises
(ownership, modes, setuid, symlinks, hardlinks, xattrs), the shrink guard, the
confirmation tokens, and path-traversal rejection.

Two suites:

- **`e2e-test.sh`** (48 checks) — backup/restore behaviour against a local
  repository: metadata fidelity, the shrink guard, confirmation tokens,
  path-traversal rejection, and the full-restore layout regression.
- **`backend-test.sh`** (31 checks) — everything that happens *before* restic
  touches data: backend detection per URL scheme, per-backend credential
  validation, repo-init gating, URL-credential redaction, and SFTP key handling
  including the non-root uid path.

```bash
docker build -t backup-tools .
docker run --rm \
  -v "$PWD/test-nfs-backup/e2e-test.sh:/e2e.sh:ro" \
  -v "$PWD/test-nfs-backup/backend-test.sh:/bt.sh:ro" \
  backup-tools bash -c '
    apt-get update >/dev/null &&
    apt-get install -y attr openssh-sftp-server openssh-client >/dev/null &&
    bash /bt.sh && bash /e2e.sh'
```

Exits non-zero if any check fails. Expected: `31 passed` then `48 passed`.

The SFTP tests point restic at a local `sftp-server` process via `sftp.command`,
which exercises the real SFTP backend with no network and no server to set up.
`openssh-sftp-server` is installed only for the test — it is not in the image.

Note the test simulates the production `/canary` subPath mount with a symlink to
`/data/.backup-canary`. In the cluster that is a real volumeMount of the same
PVC; `backup-nfs` asserts the heartbeat is visible under `/data` and fails fast
if the mounts are wrong.
