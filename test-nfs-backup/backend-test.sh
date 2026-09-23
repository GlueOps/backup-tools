#!/usr/bin/env bash
# Backend selection, preflight validation and repo-init gating.
#
# Complements e2e-test.sh (which exercises backup/restore behaviour against a
# local repository). This file is about everything that happens BEFORE restic
# touches data: is the backend understood, are its credentials present, and can
# a typo silently create a new empty repository.
set -uo pipefail

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Run backup-nfs in a clean env with only the given assignments, capture output.
run() {
  local out rc
  # timeout: some of these repos are unreachable by design, and restic would
  # otherwise sit in connect() until the suite looks hung.
  out="$(timeout 20 env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root TMPDIR=/tmp "$@" \
        /usr/bin/backup-nfs backup 2>&1)"; rc=$?
  LAST_OUT="$out"; return $rc
}
# Assert the run failed AND the message mentions the expected text.
fails_with() {
  local label="$1" want="$2"; shift 2
  run "$@" && { bad "$label -- command SUCCEEDED, expected failure"; return; }
  if grep -qF "$want" <<<"$LAST_OUT"; then ok "$label"
  else bad "$label -- wrong message. got: $(head -2 <<<"$LAST_OUT" | tr '\n' ' ')"; fi
}

echo "=== 1. missing repository / password are caught before anything else ==="
fails_with "no repository location at all" "no repository location"  RESTIC_PASSWORD=t
fails_with "no password"           "no repository password"        RESTIC_REPOSITORY=/tmp/r

echo "=== 2. each backend demands its own credentials, by name ==="
fails_with "s3 without keys"    "AWS_ACCESS_KEY_ID"   RESTIC_REPOSITORY="s3:https://e.example.com/b" RESTIC_PASSWORD=t
fails_with "s3 without secret"  "AWS_SECRET_ACCESS_KEY" RESTIC_REPOSITORY="s3:https://e.example.com/b" RESTIC_PASSWORD=t AWS_ACCESS_KEY_ID=x
fails_with "b2 without keys"    "B2_ACCOUNT_ID"       RESTIC_REPOSITORY="b2:bucket:/p" RESTIC_PASSWORD=t
fails_with "azure without keys" "AZURE_ACCOUNT_NAME"  RESTIC_REPOSITORY="azure:c:/"    RESTIC_PASSWORD=t
fails_with "gs without project" "GOOGLE_PROJECT_ID"   RESTIC_REPOSITORY="gs:b:/"       RESTIC_PASSWORD=t
fails_with "swift without auth" "OS_AUTH_URL"         RESTIC_REPOSITORY="swift:c:/"    RESTIC_PASSWORD=t

echo "=== 3. b2 error distinguishes native backend from the S3 API ==="
run RESTIC_REPOSITORY="b2:bucket:/p" RESTIC_PASSWORD=t
grep -q "S3 API" <<<"$LAST_OUT" && ok "b2 message points at the s3: alternative" \
  || bad "b2 message does not mention the S3 API route"

echo "=== 4. rclone is named as unsupported rather than failing obscurely ==="
fails_with "rclone not in image" "rclone is not installed" RESTIC_REPOSITORY="rclone:rem:/p" RESTIC_PASSWORD=t

echo "=== 5. auto-init is gated (the silent-new-repo failure mode) ==="
rm -rf /tmp/gated
fails_with "refuses to create a repo by default" "ALLOW_REPO_INIT=true" \
  RESTIC_REPOSITORY=/tmp/gated RESTIC_PASSWORD=t
[ ! -e /tmp/gated/config ] && ok "no repository was created" || bad "a repository WAS created despite the gate"

mkdir -p /data/foobar/x /canary && echo a > /data/foobar/x/f
rm -rf /data/.backup-canary && mkdir -p /data/.backup-canary
rm -rf /canary && ln -s /data/.backup-canary /canary
if env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root TMPDIR=/tmp \
     RESTIC_REPOSITORY=/tmp/gated RESTIC_PASSWORD=t ALLOW_REPO_INIT=true \
     /usr/bin/backup-nfs backup >/tmp/init.log 2>&1; then
  ok "ALLOW_REPO_INIT=true creates it and the backup succeeds"
else
  bad "ALLOW_REPO_INIT=true still failed"; tail -5 /tmp/init.log
fi
[ -f /tmp/gated/config ] && ok "repository exists afterwards" || bad "no repository created"

echo "=== 6. a typo'd repo path is refused, not silently re-created ==="
fails_with "typo'd repository refused" "Refusing to auto-create" \
  RESTIC_REPOSITORY=/tmp/gatedd RESTIC_PASSWORD=t

echo "=== 7. restore never auto-creates a repository, even if told to ==="
out=$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root TMPDIR=/tmp \
  RESTIC_REPOSITORY=/tmp/never RESTIC_PASSWORD=t ALLOW_REPO_INIT=true \
  RESTORE_MODE=list /usr/bin/restore-nfs student 2>&1)
[ $? -ne 0 ] && [ ! -e /tmp/never/config ] \
  && ok "restore refused to init even with ALLOW_REPO_INIT=true" \
  || bad "restore created a repository -- it must never do that"

echo "=== 8. credentials embedded in a repo URL are redacted in logs ==="
run RESTIC_REPOSITORY="rest:https://user:hunter2@example.com:8000/" RESTIC_PASSWORD=t
if grep -q "hunter2" <<<"$LAST_OUT"; then bad "PASSWORD LEAKED into the log"
else ok "URL password redacted"; fi

echo "=== 8b. RESTIC_REPOSITORY_FILE is honoured (restic supports it) ==="
echo "/tmp/viafile" > /tmp/repofile
mkdir -p /data/foobar/x /data/.backup-canary; echo a > /data/foobar/x/f
rm -rf /canary; ln -s /data/.backup-canary /canary
if env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root TMPDIR=/tmp \
     RESTIC_REPOSITORY_FILE=/tmp/repofile RESTIC_PASSWORD=t ALLOW_REPO_INIT=true \
     /usr/bin/backup-nfs backup >/tmp/rf.log 2>&1; then
  ok "backup works with only RESTIC_REPOSITORY_FILE set"
else bad "RESTIC_REPOSITORY_FILE rejected"; tail -3 /tmp/rf.log; fi
[ -f /tmp/viafile/config ] && ok "repo created at the path named in the file" || bad "no repo at the file's path"

echo "=== 8c. keyless S3 auth is not blocked (IRSA / ECS / profile / metadata) ==="
for c in "AWS_ROLE_ARN=arn:x AWS_WEB_IDENTITY_TOKEN_FILE=/t" "AWS_PROFILE=prod" \
         "AWS_SHARED_CREDENTIALS_FILE=/c" "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/v2/x" \
         "RESTIC_SKIP_CREDENTIAL_CHECK=true"; do
  out=$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root TMPDIR=/tmp RESTIC_PASSWORD=t \
        RESTIC_REPOSITORY="s3:https://s3.amazonaws.com/b" $c timeout 15 \
        /usr/bin/backup-nfs backup 2>&1)
  grep -q "none of these are set" <<<"$out" && bad "blocked legitimate auth: $c" \
    || ok "accepted: ${c%% *}"
done
# ...but genuine misconfiguration must still fail
fails_with "still rejects S3 with no credentials at all" "AWS_ACCESS_KEY_ID" \
  RESTIC_REPOSITORY="s3:https://s3.amazonaws.com/b" RESTIC_PASSWORD=t
fails_with "key id without its secret still rejected" "AWS_SECRET_ACCESS_KEY" \
  RESTIC_REPOSITORY="s3:https://s3.amazonaws.com/b" RESTIC_PASSWORD=t AWS_ACCESS_KEY_ID=x

echo "=== 8d. redaction survives a password containing '@' ==="
. /usr/lib/backup-tools/restic-common.sh
RESTIC_REPOSITORY="rest:https://u:p@ss/w@rd@h/" red="$(redact_repo)"
grep -q "w@rd" <<<"$red" && bad "PASSWORD TAIL LEAKED: $red" || ok "fully redacted: $red"
RESTIC_REPOSITORY="s3:https://ep/bucket/my@dir" red="$(redact_repo)"
[ "$red" = "s3:https://ep/bucket/my@dir" ] && ok "plain path containing '@' left intact" \
  || bad "over-redacted a credential-free URL: $red"

echo "=== 9. sftp: missing key material fails with actionable guidance ==="
fails_with "sftp without RESTIC_SSH_KEY" "RESTIC_SSH_KEY" \
  RESTIC_REPOSITORY="sftp:h:/p" RESTIC_PASSWORD=t
ssh-keygen -qt ed25519 -N "" -f /tmp/testkey
fails_with "sftp without known_hosts" "RESTIC_SSH_KNOWN_HOSTS" \
  RESTIC_REPOSITORY="sftp:h:/p" RESTIC_PASSWORD=t RESTIC_SSH_KEY=/tmp/testkey
fails_with "sftp refuses host-key bypass by omission" "ssh-keyscan" \
  RESTIC_REPOSITORY="sftp:h:/p" RESTIC_PASSWORD=t RESTIC_SSH_KEY=/tmp/testkey

echo "=== 9b. default sftp path injects pinned-host-key args ==="
ssh-keygen -qt ed25519 -N "" -f /tmp/k2 2>/dev/null
echo "h ssh-ed25519 AAAA" > /tmp/kh2
run RESTIC_REPOSITORY="sftp:nonexistent.invalid:/p" RESTIC_PASSWORD=t \
    RESTIC_SSH_KEY=/tmp/k2 RESTIC_SSH_KNOWN_HOSTS=/tmp/kh2
grep -q "using key /tmp/k2 with pinned host keys" <<<"$LAST_OUT" \
  && ok "injected sftp.args with pinned known_hosts" || bad "did not take the default sftp path"
grep -qi "StrictHostKeyChecking=no" <<<"$LAST_OUT" && bad "host-key checking was disabled" \
  || ok "never disables host-key checking"

echo "=== 9c. SSH material supplied as env CONTENT rather than a file path ==="
ssh-keygen -qt ed25519 -N "" -f /tmp/k3 2>/dev/null
KEYC="$(cat /tmp/k3)"; KHC="h ssh-ed25519 AAAA"
# should reach the connection stage, i.e. get past all key/known_hosts checks
run RESTIC_REPOSITORY="sftp:nonexistent.invalid:/p" RESTIC_PASSWORD=t \
    RESTIC_SSH_KEY_CONTENT="$KEYC" RESTIC_SSH_KNOWN_HOSTS_CONTENT="$KHC"
grep -q "using the key supplied via RESTIC_SSH_KEY_CONTENT" <<<"$LAST_OUT" \
  && ok "accepted the key from env content" || bad "did not accept key content: $(head -3 <<<"$LAST_OUT"|tr '\n' ' ')"
grep -q "host keys pinned from RESTIC_SSH_KNOWN_HOSTS_CONTENT" <<<"$LAST_OUT" \
  && ok "accepted known_hosts from env content" || bad "did not accept known_hosts content"
[ "$(stat -c %a /tmp/.restic-ssh/id 2>/dev/null)" = "600" ] \
  && ok "key written as mode 600 (ssh refuses anything looser)" \
  || bad "key mode is $(stat -c %a /tmp/.restic-ssh/id 2>/dev/null), expected 600"

fails_with "a mangled key is rejected with a useful message" "not a usable private key" \
  RESTIC_REPOSITORY="sftp:h:/p" RESTIC_PASSWORD=t \
  RESTIC_SSH_KEY_CONTENT="-----BEGIN OPENSSH PRIVATE KEY----- allonoline -----END OPENSSH PRIVATE KEY-----" \
  RESTIC_SSH_KNOWN_HOSTS_CONTENT="$KHC"

fails_with "path and content together are refused, not silently guessed" "Pick one" \
  RESTIC_REPOSITORY="sftp:h:/p" RESTIC_PASSWORD=t \
  RESTIC_SSH_KEY=/tmp/k3 RESTIC_SSH_KEY_CONTENT="$KEYC"

fails_with "still demands a key when neither form is given" "RESTIC_SSH_KEY_CONTENT" \
  RESTIC_REPOSITORY="sftp:h:/p" RESTIC_PASSWORD=t

echo "=== 9d. env-content key works for a real sftp round trip ==="
mkdir -p /srv/envrepo
if env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root TMPDIR=/tmp \
     RESTIC_REPOSITORY="sftp:localhost:/srv/envrepo" RESTIC_PASSWORD=t \
     RESTIC_SSH_KEY_CONTENT="$KEYC" RESTIC_SSH_KNOWN_HOSTS_CONTENT="$KHC" \
     RESTIC_EXTRA_OPTS="sftp.command=/usr/lib/openssh/sftp-server" \
     ALLOW_REPO_INIT=true BACKUP_HOST=envtest \
     /usr/bin/backup-nfs backup >/tmp/envrt.log 2>&1; then
  ok "full backup over sftp using an env-supplied key"
else bad "env-key sftp backup failed"; tail -6 /tmp/envrt.log; fi
[ -f /srv/envrepo/config ] && ok "repo created at the sftp path" || bad "no repo created"

echo "=== 10. sftp: real backup+restore round trip over the SFTP backend ==="
# sftp.command points restic at a local sftp-server, so this exercises the real
# SFTP code path with no network. It also exercises RESTIC_EXTRA_OPTS.
# A literal line, not ssh-keyscan: this must not depend on network access.
echo "localhost ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleHostKeyForTestsOnly00000000000" > /tmp/known_hosts
mkdir -p /srv/sftprepo
export RESTIC_REPOSITORY="sftp:localhost:/srv/sftprepo" RESTIC_PASSWORD=t
export RESTIC_SSH_KEY=/tmp/testkey RESTIC_SSH_KNOWN_HOSTS=/tmp/known_hosts
export RESTIC_EXTRA_OPTS="sftp.command=/usr/lib/openssh/sftp-server sftp.connections=3"
export ALLOW_REPO_INIT=true BACKUP_HOST=sftp-test
if backup-nfs backup >/tmp/sftp.log 2>&1; then ok "backup over sftp succeeded"
else bad "backup over sftp failed"; tail -8 /tmp/sftp.log; fi
grep -q "backend=sftp" /tmp/sftp.log && ok "detected backend=sftp" || bad "backend not reported as sftp"
grep -q "connection managed via RESTIC_EXTRA_OPTS" /tmp/sftp.log \
  && ok "deferred to user-supplied sftp.command (restic rejects args+command)" \
  || bad "did not defer to user-supplied sftp.command"
[ -f /srv/sftprepo/config ] && ok "repo written to the sftp path" || bad "nothing at the sftp path"

RESTORE_MODE=list RESTORE_TERM=foobar RESTORE_STUDENT=x restore-nfs student >/tmp/sftpls.log 2>&1 \
  && ok "restore list over sftp succeeded" || { bad "restore over sftp failed"; tail -5 /tmp/sftpls.log; }

echo "=== 11. sftp as a non-root uid (restore-student runs as 1337) ==="
# Models production: the repo is owned by the uid that connects, exactly as a
# Storage Box repo is owned by the Storage Box user. A root-owned local repo
# would NOT be readable -- restic creates config as mode 400 -- but that is an
# artifact of both ends sharing a filesystem here, not a real-world case.
chmod 644 /tmp/testkey     # deliberately too-open, as a Secret mount would be
install -d -o 1337 -g 1337 /tmp/u1337 /srv/repo1337
# sftp-server refuses a uid with no passwd entry; a real server always has one.
getent passwd 1337 >/dev/null || useradd -u 1337 -M -d /tmp/u1337 -s /bin/bash tester1337

as1337() {
  setpriv --reuid=1337 --regid=1337 --clear-groups \
    env PATH=/usr/local/bin:/usr/bin:/bin HOME=/tmp/u1337 TMPDIR=/tmp/u1337 \
    RESTIC_REPOSITORY="sftp:localhost:/srv/repo1337" RESTIC_PASSWORD=t \
    RESTIC_SSH_KEY=/tmp/testkey RESTIC_SSH_KNOWN_HOSTS=/tmp/known_hosts \
    RESTIC_EXTRA_OPTS="sftp.command=/usr/lib/openssh/sftp-server" \
    BACKUP_HOST=sftp-test "$@"
}
# Harness setup, not an assertion: seed a repo owned by uid 1337.
as1337 restic -o sftp.command=/usr/lib/openssh/sftp-server init >/dev/null 2>&1

# `restore-nfs student` is the command that actually runs as 1337 in production.
# (`backup-nfs backup` correctly refuses any uid but 0 -- it must read files that
# are not world-readable -- so it is the wrong command to assert this with.)
if as1337 RESTORE_MODE=list RESTORE_TERM=foobar RESTORE_STUDENT=x \
     /usr/bin/restore-nfs student >/tmp/uid.log 2>&1; then
  ok "uid 1337 reached the sftp backend using a 0644 root-owned key"
else
  bad "uid 1337 sftp access failed"; tail -8 /tmp/uid.log
fi
grep -q "backend=sftp" /tmp/uid.log && ok "uid 1337 resolved backend=sftp" || bad "backend not detected as 1337"
perm=$(stat -c %a /tmp/u1337/.restic-ssh/id 2>/dev/null)
[ "$perm" = "600" ] && ok "key copied to a private path as mode 600" \
  || bad "copied key mode is '$perm', expected 600 (ssh would refuse it)"
[ "$(stat -c %U /tmp/u1337/.restic-ssh/id 2>/dev/null)" != "root" ] \
  && ok "copy is owned by the running uid, not root" || bad "copy still root-owned"

echo "=== 12. D1: a second restore must not resolve 'latest' to a pre-restore snapshot ==="
export RESTIC_REPOSITORY=/tmp/d1repo RESTIC_PASSWORD=t BACKUP_HOST=h RESTORE_TERM=t1
unset RESTIC_SSH_KEY RESTIC_SSH_KNOWN_HOSTS RESTIC_EXTRA_OPTS
restic init -q >/dev/null 2>&1
mkdir -p /data/t1/alice && echo "GOOD-WORK" > /data/t1/alice/thesis.txt
restic backup /data --host h --tag daily --no-scan -q >/dev/null 2>&1
echo GARBAGE1 > /data/t1/alice/thesis.txt
RESTORE_MODE=overwrite RESTORE_STUDENT=alice restore-nfs student >/dev/null 2>&1
[ "$(cat /data/t1/alice/thesis.txt)" = "GOOD-WORK" ] && ok "run 1 restored the daily snapshot" || bad "run 1 wrong"
echo GARBAGE2 > /data/t1/alice/thesis.txt
RESTORE_MODE=overwrite RESTORE_STUDENT=alice restore-nfs student >/dev/null 2>&1
[ "$(cat /data/t1/alice/thesis.txt)" = "GOOD-WORK" ] \
  && ok "run 2 also restored the daily, NOT run 1's pre-restore snapshot" \
  || bad "run 2 restored DAMAGED data ($(cat /data/t1/alice/thesis.txt)) -- latest resolved to a pre-restore snapshot"

PRE=$(restic snapshots --host h --tag pre-restore --json | jq -r ".[0].short_id")
if RESTORE_MODE=exact RESTORE_STUDENT=alice RESTORE_SNAPSHOT_ID="$PRE" \
     RESTORE_CONFIRM="restore-alice-${PRE}" restore-nfs student >/dev/null 2>&1; then
  ok "an EXPLICIT pre-restore id is still usable for rollback"
else bad "rollback to an explicit pre-restore id was broken by the filters"; fi

echo "=== 13. D2: a typo'd student name is actually diagnosed ==="
echo "GOOD-WORK" > /data/t1/alice/thesis.txt
RESTORE_MODE=list RESTORE_STUDENT=nosuchstudent restore-nfs student >/tmp/l1.log 2>&1
grep -q "nothing found at that path" /tmp/l1.log && ok "unknown student diagnosed" \
  || bad "no diagnostic for an unknown student (restic ls exits 0 even when the path is absent)"
RESTORE_MODE=list RESTORE_STUDENT=alice restore-nfs student >/tmp/l2.log 2>&1
grep -q "thesis.txt" /tmp/l2.log && ok "a real student still lists their files" || bad "real student listing broken"
grep -q "nothing found at that path" /tmp/l2.log && bad "false 'nothing found' for a real student" \
  || ok "no false negative for a real student"

echo "=== 14. D3: wrong password and unreachable backend are told apart ==="
fails_with "wrong password is named as such" "RESTIC_PASSWORD is WRONG" \
  RESTIC_REPOSITORY=/tmp/d1repo RESTIC_PASSWORD=DEFINITELYWRONG ALLOW_REPO_INIT=true
fails_with "wrong password is not 'fixed' by ALLOW_REPO_INIT" "nothing to
       create" \
  RESTIC_REPOSITORY=/tmp/d1repo RESTIC_PASSWORD=DEFINITELYWRONG ALLOW_REPO_INIT=true
# A backend error that is neither "missing" (10) nor "wrong password" (12).
# Deliberately NOT a network target: restic retries connection failures with
# backoff for minutes, so an unreachable host makes the suite look hung rather
# than asserting anything. A permission-denied local path fails immediately with
# exit 1, exercising the same branch. (It also has to run as non-root, since
# root bypasses the permission check -- hence restore-nfs, which is the command
# designed to run unprivileged.)
mkdir -p /tmp/noperm/repo && chmod 000 /tmp/noperm
install -d -o 1337 -g 1337 /tmp/u2 2>/dev/null || true
out=$(setpriv --reuid=1337 --regid=1337 --clear-groups \
      env PATH=/usr/local/bin:/usr/bin:/bin HOME=/tmp/u2 TMPDIR=/tmp/u2 \
      RESTIC_REPOSITORY=/tmp/noperm/repo RESTIC_PASSWORD=t ALLOW_REPO_INIT=true \
      BACKUP_HOST=h RESTORE_TERM=t1 RESTORE_MODE=list \
      /usr/bin/restore-nfs student 2>&1) || true
grep -q "cannot reach the backend" <<<"$out" \
  && ok "a non-10/non-12 backend error is reported as such, not as a missing repo" \
  || bad "backend error misreported: $(head -2 <<<"$out" | tr '\n' ' ')"
chmod 755 /tmp/noperm

echo "=== 15. D4: staged restores do not trip the shrink guard ==="
export RESTIC_REPOSITORY=/tmp/d4repo ALLOW_REPO_INIT=true RESTIC_PASSWORD=t
rm -rf /data/.restore-staging; mkdir -p /data/.backup-canary; rm -rf /canary; ln -s /data/.backup-canary /canary
for i in $(seq 1 120); do echo x > /data/t1/alice/f$i; done
backup-nfs backup >/dev/null 2>&1; backup-nfs backup >/dev/null 2>&1
SNAP=$(restic snapshots --host h --tag daily --json | jq -r ".[-1].short_id")
mkdir -p "/data/.restore-staging/$SNAP"
restic restore "${SNAP}:/data" --target "/data/.restore-staging/$SNAP" -q >/dev/null 2>&1
backup-nfs backup >/tmp/s1.log 2>&1 && ok "backup succeeds while a restore is staged" || { bad "backup failed with staging present"; tail -3 /tmp/s1.log; }
rm -rf /data/.restore-staging
if backup-nfs backup >/tmp/s2.log 2>&1; then
  ok "backup succeeds after the staging dir is removed (no false data-loss alert)"
else
  bad "SHRINK GUARD FALSE POSITIVE after staging cleanup"; grep -E "file count|fell" /tmp/s2.log
fi
grep -q "restore-staging" /tmp/s2.log && bad "staging dir was backed up" || ok "staging dir excluded from the snapshot"

echo
echo "================= RESULT: $PASS passed, $FAIL failed ================="
[ "$FAIL" -eq 0 ]
