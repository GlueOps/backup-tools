# NFS backup/restore end-to-end test

Exercises `backup-nfs` and `restore-nfs` against a local restic repository
inside the built image. Covers the metadata fidelity the design promises
(ownership, modes, setuid, symlinks, hardlinks, xattrs), the shrink guard, the
confirmation tokens, and path-traversal rejection.

```bash
docker build -t backup-tools .
docker run --rm -v "$PWD/test-nfs-backup/e2e-test.sh:/e2e.sh:ro" backup-tools \
  bash -c 'apt-get update >/dev/null && apt-get install -y attr >/dev/null && bash /e2e.sh'
```

Exits non-zero if any check fails. Expected: `37 passed, 0 failed`.

Note the test simulates the production `/canary` subPath mount with a symlink to
`/data/.backup-canary`. In the cluster that is a real volumeMount of the same
PVC; `backup-nfs` asserts the heartbeat is visible under `/data` and fails fast
if the mounts are wrong.
