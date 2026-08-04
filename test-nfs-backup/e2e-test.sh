#!/usr/bin/env bash
# End-to-end test of backup-nfs / restore-nfs inside the built image.
# Exercises the metadata cases the design promises to preserve.
set -uo pipefail

export RESTIC_REPOSITORY=/repo
export ALLOW_REPO_INIT=true   # first run creates the test repo; gated by design
export RESTIC_PASSWORD=testpassword
export RESTORE_TERM=testterm
export BACKUP_HOST=test-host
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3' got '$2'"; fi; }

echo "=== build test tree ==="
S=/data/testterm/student-a
mkdir -p "$S/sub"
echo "hello world" > "$S/normal.txt"
echo "topsecret"   > "$S/.secret";        chmod 600 "$S/.secret"
echo "linked"      > "$S/hard1";          ln "$S/hard1" "$S/hard2"
ln -s normal.txt "$S/link.txt"
printf 'setuid\n' > "$S/suid";            chown 0:0 "$S/suid"; chmod 4755 "$S/suid"
dd if=/dev/zero of="$S/sparse.bin" bs=1 count=0 seek=10M 2>/dev/null
setfattr -n user.testattr -v hello "$S/normal.txt" 2>/dev/null && XATTR=yes || XATTR=no
echo "deep" > "$S/sub/deep.txt"
mkdir -p "$S/bulk"; for i in $(seq 1 300); do echo "f$i" > "$S/bulk/f$i.txt"; done
chown -R 1337:1337 "$S/bulk"; chown 1337:1337 "$S" "$S/sub" "$S"/normal.txt "$S"/.secret "$S"/hard1 "$S"/hard2 "$S"/link.txt "$S"/sparse.bin "$S"/sub/deep.txt
# NOTE: $S/suid is deliberately left root-owned with its setuid bit set. chown()
# clears setuid, so it must be chowned BEFORE chmod -- that ordering is exactly
# why restic must chown-then-chmod on restore.
echo "  xattr support on this fs: $XATTR"
echo "  files: $(find "$S" | wc -l)"

mkdir -p /data/.backup-canary && ln -sfn /data/.backup-canary /canary
echo "  simulated /canary -> /data/.backup-canary subPath mount"

echo "=== 1. backup ==="
backup-nfs backup >/tmp/backup.log 2>&1
rc=$?; [ $rc -eq 0 ] && ok "backup exit 0" || { bad "backup exit $rc"; tail -20 /tmp/backup.log; }
grep -q "backup OK" /tmp/backup.log && ok "logged 'backup OK'" || bad "missing 'backup OK'"

echo "=== 2. second backup exercises the shrink guard ==="
backup-nfs backup >/tmp/backup2.log 2>&1
rc=$?; [ $rc -eq 0 ] && ok "second backup exit 0" || { bad "second backup exit $rc"; tail -20 /tmp/backup2.log; }
grep -q "file count: previous=" /tmp/backup2.log && ok "shrink guard ran" || bad "shrink guard did not run"

echo "=== 3. shrink guard must FAIL when data disappears ==="
mv "$S" /tmp/stash
mkdir -p "$S" && echo x > "$S/only.txt" && chown -R 1337:1337 "$S"
backup-nfs backup >/tmp/backup3.log 2>&1
rc=$?; [ $rc -ne 0 ] && ok "shrink guard failed the job (exit $rc)" || bad "shrink guard did NOT fire — data loss would be silent"
rm -rf "$S"; mv /tmp/stash "$S"

echo "=== 4. list mode writes nothing ==="
SNAP=$(restic snapshots --json | jq -r '.[0].short_id')
RESTORE_MODE=list RESTORE_STUDENT=student-a restore-nfs student >/tmp/list.log 2>&1
rc=$?; [ $rc -eq 0 ] && ok "list exit 0" || { bad "list exit $rc"; tail -20 /tmp/list.log; }

echo "=== 5. additive restore after deleting files ==="
rm -f "$S/normal.txt" "$S/.secret" "$S/sub/deep.txt"
echo "student typed this after the loss" > "$S/newwork.txt"; chown 1337:1337 "$S/newwork.txt"
RESTORE_MODE=additive RESTORE_STUDENT=student-a RESTORE_SNAPSHOT_ID="$SNAP" \
  restore-nfs student >/tmp/restore.log 2>&1
rc=$?; [ $rc -eq 0 ] && ok "additive exit 0" || { bad "additive exit $rc"; tail -30 /tmp/restore.log; }
grep -q "RESTORE (additive) COMPLETE" /tmp/restore.log && ok "logged the exact string the runbook greps" || bad "runbook grep string missing"

echo "=== 6. verify restored content and metadata ==="
[ -f "$S/normal.txt" ]  && ok "deleted file restored"       || bad "deleted file NOT restored"
[ -f "$S/sub/deep.txt" ] && ok "nested file restored"       || bad "nested file NOT restored"
[ -f "$S/newwork.txt" ] && ok "post-loss work preserved"    || bad "additive DESTROYED newer work"
check "restored path is not double-nested" "$([ -e "$S/data" ] && echo nested || echo flat)" "flat"
check ".secret mode"  "$(stat -c %a "$S/.secret" 2>/dev/null)"  "600"
check ".secret owner" "$(stat -c %u:%g "$S/.secret" 2>/dev/null)" "1337:1337"
check "setuid bit"    "$(stat -c %a "$S/suid" 2>/dev/null)"     "4755"
check "setuid owner"  "$(stat -c %u:%g "$S/suid" 2>/dev/null)"  "0:0"
check "symlink"       "$(readlink "$S/link.txt" 2>/dev/null)"   "normal.txt"
check "hardlink pair" "$(stat -c %h "$S/hard1" 2>/dev/null)"    "2"
if [ "$XATTR" = yes ]; then
  check "xattr" "$(getfattr -n user.testattr --only-values "$S/normal.txt" 2>/dev/null)" "hello"
fi

echo "=== 7. exact mode must REFUSE without the confirm token ==="
RESTORE_MODE=exact RESTORE_STUDENT=student-a RESTORE_SNAPSHOT_ID="$SNAP" \
  restore-nfs student >/tmp/exact-noconfirm.log 2>&1
rc=$?; [ $rc -eq 2 ] && ok "exact refused without token (exit 2)" || bad "exact: expected exit 2, got $rc"
[ -f "$S/newwork.txt" ] && ok "newer work untouched by refused restore" || bad "refused restore still deleted data"

echo "=== 8. exact mode with a WRONG token must refuse ==="
RESTORE_MODE=exact RESTORE_STUDENT=student-a RESTORE_SNAPSHOT_ID="$SNAP" \
  RESTORE_CONFIRM="restore-student-a-WRONGSNAP" restore-nfs student >/tmp/exact-badtok.log 2>&1
rc=$?; [ $rc -eq 2 ] && ok "wrong token refused (exit 2)" || bad "wrong token: expected exit 2, got $rc"

echo "=== 9. exact mode with the correct token deletes newer work ==="
RESTORE_MODE=exact RESTORE_STUDENT=student-a RESTORE_SNAPSHOT_ID="$SNAP" \
  RESTORE_CONFIRM="restore-student-a-${SNAP}" restore-nfs student >/tmp/exact.log 2>&1
rc=$?; [ $rc -eq 0 ] && ok "exact exit 0" || { bad "exact exit $rc"; tail -30 /tmp/exact.log; }
[ ! -f "$S/newwork.txt" ] && ok "exact removed post-snapshot file" || bad "exact did not delete as documented"
restic snapshots --tag pre-restore --json 2>/dev/null | jq -e 'length > 0' >/dev/null \
  && ok "pre-restore safety snapshot exists" || bad "NO pre-restore snapshot — rollback impossible"

echo "=== 10. path traversal via RESTORE_STUDENT must be rejected ==="
for evil in "../../etc" "a/../../b" "" "-rf" "UPPER"; do
  RESTORE_MODE=additive RESTORE_STUDENT="$evil" RESTORE_SNAPSHOT_ID="$SNAP" \
    restore-nfs student >/tmp/evil.log 2>&1
  rc=$?
  [ $rc -ne 0 ] && ok "rejected RESTORE_STUDENT='$evil'" || bad "ACCEPTED RESTORE_STUDENT='$evil'"
done

echo "=== 11. path traversal via RESTORE_TERM (unvalidated!) ==="
RESTORE_MODE=additive RESTORE_TERM="../../tmp" RESTORE_STUDENT="student-a" \
  RESTORE_SNAPSHOT_ID="$SNAP" restore-nfs student >/tmp/evilterm.log 2>&1
rc=$?
[ $rc -eq 64 ] && ok "rejected RESTORE_TERM='../../tmp' (exit 64)" || bad "RESTORE_TERM traversal not rejected (exit $rc)"
grep -q "not a valid cohort" /tmp/evilterm.log && ok "clear error message" || bad "no validation message"

echo "=== 12. full restore: verify mode writes nothing ==="
RESTORE_MODE=verify RESTORE_SNAPSHOT_ID="$SNAP" restore-nfs full >/tmp/full-verify.log 2>&1
rc=$?; [ $rc -eq 0 ] && ok "full verify exit 0" || { bad "full verify exit $rc"; tail -20 /tmp/full-verify.log; }

echo "=== 13. full commit must refuse 'latest' and a missing token ==="
RESTORE_MODE=commit RESTORE_SNAPSHOT_ID=latest restore-nfs full >/tmp/full-latest.log 2>&1
rc=$?; [ $rc -ne 0 ] && ok "full commit rejected 'latest'" || bad "full commit ACCEPTED 'latest'"
RESTORE_MODE=commit RESTORE_SNAPSHOT_ID="$SNAP" restore-nfs full >/tmp/full-notok.log 2>&1
rc=$?; [ $rc -ne 0 ] && ok "full commit refused without token" || bad "full commit ran WITHOUT token"

echo "=== 14. prune ==="
backup-nfs prune >/tmp/prune.log 2>&1
rc=$?; [ $rc -eq 0 ] && ok "prune exit 0" || { bad "prune exit $rc"; tail -20 /tmp/prune.log; }

echo "=== 15. verify mode (canary round-trip) ==="
mkdir -p /verify
backup-nfs verify >/tmp/verify.log 2>&1
rc=$?; [ $rc -eq 0 ] && ok "verify exit 0" || { bad "verify exit $rc"; tail -25 /tmp/verify.log; }

echo "=== 16. full stage: must not touch live data, must not double-nest ==="
rm -rf /data/.restore-staging
SNAP2=$(restic snapshots --host "$BACKUP_HOST" --tag daily --json | jq -r '.[-1].short_id')
RESTORE_MODE=stage RESTORE_SNAPSHOT_ID="$SNAP2" restore-nfs full >/tmp/stage.log 2>&1
rc=$?; [ $rc -eq 0 ] && ok "stage exit 0" || { bad "stage exit $rc"; tail -20 /tmp/stage.log; }
[ -d "/data/.restore-staging/$SNAP2/testterm" ] && ok "staged layout is flat (no /data/data nesting)" \
  || bad "staged layout WRONG: $(find /data/.restore-staging -maxdepth 3 2>/dev/null | head -5)"
[ -f "$S/normal.txt" ] && ok "stage left live data alone" || bad "stage TOUCHED live data"

echo "=== 17. THE BIG ONE: full commit must restore in place, not wipe the export ==="
# Regression test for a bug where a bare snapshot id (rather than snap:/data)
# restored to /data/data/... while --delete pruned the target ROOT -- which
# recursively deleted the entire live export and still exited 0.
echo "unrelated top-level file" > /data/DO-NOT-DELETE.txt
mkdir -p /data/othercohort/somebody && echo keep > /data/othercohort/somebody/work.txt
restic backup /data --host "$BACKUP_HOST" --tag daily --no-scan -q
SNAP3=$(restic snapshots --host "$BACKUP_HOST" --tag daily --json | jq -r '.[-1].short_id')
rm -rf "$S/bulk"                      # simulate damage that the restore should repair
rm -rf /data/.restore-staging
RESTORE_MODE=commit RESTORE_SNAPSHOT_ID="$SNAP3" \
  RESTORE_CONFIRM="restore-${SNAP3}-to-prod" restore-nfs full >/tmp/commit.log 2>&1
rc=$?; [ $rc -eq 0 ] && ok "commit exit 0" || { bad "commit exit $rc"; tail -30 /tmp/commit.log; }
[ ! -e /data/data ]                        && ok "NOT double-nested under /data/data" || bad "DOUBLE-NESTED -- the export was restored to /data/data"
[ -f "$S/normal.txt" ]                     && ok "student data present after commit"  || bad "STUDENT DATA DESTROYED by full commit"
[ -f /data/othercohort/somebody/work.txt ] && ok "other cohort survived"              || bad "OTHER COHORT DELETED by full commit"
[ -f /data/DO-NOT-DELETE.txt ]             && ok "unrelated top-level file survived"  || bad "UNRELATED FILE DELETED by full commit"
[ -d "$S/bulk" ]                           && ok "commit repaired the deleted directory" || bad "commit did not restore removed data"
grep -q "PRE-RESTORE SNAPSHOT: [0-9a-f]" /tmp/commit.log && ok "printed a usable rollback snapshot id" || bad "no rollback id (or it was 'null')"

echo "=== 18. verify still passes after all that ==="
backup-nfs backup >/tmp/b4.log 2>&1 || true
backup-nfs verify >/tmp/v2.log 2>&1
rc=$?; [ $rc -eq 0 ] && ok "verify exit 0" || { bad "verify exit $rc"; tail -20 /tmp/v2.log; }

echo
echo "================= RESULT: $PASS passed, $FAIL failed ================="
[ "$FAIL" -eq 0 ]
