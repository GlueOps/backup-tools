#!/usr/bin/env bash
# Restore from the NFS restic repository.
#
# Installed as /usr/bin/restore-nfs. Subcommands: student | full
#
# Never runs on a schedule. Both owning CronJobs are permanently suspended with
# a 31-February schedule; an operator triggers a run with
# `kubectl create job --from=cronjob/...`.
#
# Deployment-specific values come from the environment, never hardcoded here:
#   BACKUP_HOST   snapshot host label, must match backup-nfs (default: foobar)
#   RESTORE_TERM  cohort directory under the export root (default: foobar)
#
# Parameters arrive as env vars. Every mode that writes must be named explicitly
# — the committed defaults (`list` / `verify`) write nothing.

set -Eeuo pipefail

SUB="${1:-}"
# shellcheck source=restic-common.sh
. /usr/lib/backup-tools/restic-common.sh

# Cohort directory under the export root. Deployment-specific -- set it in the
# job spec, not here.
TERM_DIR="${RESTORE_TERM:-foobar}"
SNAP_IN="${RESTORE_SNAPSHOT_ID:-latest}"

# RESTORE_TERM is interpolated straight into the restore target path, so it is
# validated exactly as strictly as RESTORE_STUDENT. Without this, a mistyped
# RESTORE_TERM=../../tmp resolves to a target outside the cohort directory.
if ! [[ "$TERM_DIR" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  echo "FATAL: RESTORE_TERM='$TERM_DIR' is not a valid cohort directory name." >&2
  echo "       Must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ — no slashes, no '..'." >&2
  exit 64
fi

# Must match BACKUP_HOST in backup-nfs, or the --host filters below match
# nothing and every lookup reports "snapshot not found".
HOSTTAG="${BACKUP_HOST:-foobar}"

restic_setup
# A restore must never create a repository -- if it cannot open one, the
# parameters are wrong and proceeding would restore nothing from nowhere.
ALLOW_REPO_INIT=false ensure_repo


# Resolve whatever the operator typed ("latest", a short id) to a concrete id,
# so every later message and confirmation token refers to one specific snapshot.
resolve_snapshot() {
  local want="$1" id
  # stderr is deliberately NOT swallowed: an S3 outage and a genuinely missing
  # snapshot must not both surface as "snapshot not found" during an incident.
  id="$(restic "${ROPTS[@]}" snapshots --json "$want" | jq -r 'if length > 0 then .[-1].short_id else empty end')"
  [ -n "$id" ] || die "snapshot '$want' not found. Run in 'list' mode to see what exists."
  echo "$id"
}

case "$SUB" in

# =============================================================== student ======
# Blast radius is bounded MECHANICALLY by validating RESTORE_STUDENT, which is
# why this path needs no PR. Runs as uid 1337 and never chowns, so it does not
# depend on no_root_squash.
student)
  MODE="${RESTORE_MODE:-list}"
  try_unlock

  # ---- list: safe default, writes nothing -----------------------------------
  if [ "$MODE" = "list" ]; then
    log "snapshots available:"
    restic "${ROPTS[@]}" snapshots --host "$HOSTTAG" --tag daily
    if [ -n "${RESTORE_STUDENT:-}" ]; then
      log ""
      log "contents of '${RESTORE_STUDENT}' in the latest snapshot:"
      # Not `restic ls ... | head -50`: head exits at 50, restic takes SIGPIPE,
      # and pipefail propagates 141 -- so any student with >50 files printed
      # their contents AND THEN "nothing found", which is the first thing an
      # operator reads during an incident. Branch on restic's own status.
      if restic "${ROPTS[@]}" ls latest "/data/${TERM_DIR}/${RESTORE_STUDENT}" > /tmp/ls.out 2>/tmp/ls.err; then
        head -50 /tmp/ls.out
        [ "$(wc -l < /tmp/ls.out)" -gt 50 ] && log "  ... ($(wc -l < /tmp/ls.out) entries total)"
      else
        log "  (nothing found at that path — check the student name and term)"
        head -3 /tmp/ls.err >&2 || true
      fi
    fi
    log ""
    log "Pick the last snapshot BEFORE the damage, then re-run with:"
    log "  RESTORE_MODE=additive RESTORE_STUDENT=<name> RESTORE_SNAPSHOT_ID=<id>"
    exit 0
  fi

  # ---- validate the target --------------------------------------------------
  # This regex is the entire safety mechanism for this path. It rejects "..",
  # "/", empty, and the cohort root, so the job cannot touch anything outside
  # one student's directory regardless of what is passed in.
  STUDENT="${RESTORE_STUDENT:-}"
  [ -n "$STUDENT" ] || die "RESTORE_STUDENT is required for mode '$MODE'"
  if ! [[ "$STUDENT" =~ ^[a-z0-9][a-z0-9-]{0,50}$ ]]; then
    die "RESTORE_STUDENT='$STUDENT' is not a valid CDE name.
       Must match ^[a-z0-9][a-z0-9-]{0,50}$ — no slashes, no '..', not empty."
  fi

  LIVE="/data/${TERM_DIR}/${STUDENT}"
  [ -d "$LIVE" ] || log "WARNING: ${LIVE} does not currently exist — it will be created."

  SNAPID="$(resolve_snapshot "$SNAP_IN")"
  # <snapshot>:<subfolder> makes restored paths RELATIVE to the subfolder, so
  # the student's files land directly at --target with no prefix to strip.
  SRC="${SNAPID}:/data/${TERM_DIR}/${STUDENT}"

  case "$MODE" in
    additive)
      # Creates only files that do not currently exist. Cannot overwrite,
      # cannot delete. This is the right answer for "I deleted my work".
      OVERWRITE="never"; DELETE=false; NEEDS_CONFIRM=false ;;
    overwrite)
      # Also replaces files whose content differs. Keeps files the snapshot
      # does not have. This PERMANENTLY REPLACES work created since the
      # snapshot -- it does not delete files, but it does destroy edits. The
      # pre-restore snapshot below is the only way back.
      OVERWRITE="if-changed"; DELETE=false; NEEDS_CONFIRM=false ;;
    exact)
      # Makes the directory identical to the snapshot, DELETING anything
      # created since. `overwrite` replaces edits; only this mode also removes
      # files, which is why only this one requires a confirmation token.
      OVERWRITE="if-changed"; DELETE=true;  NEEDS_CONFIRM=true ;;
    *)
      die "unknown RESTORE_MODE='$MODE' (expected: list | additive | overwrite | exact)" 64 ;;
  esac

  if [ "$NEEDS_CONFIRM" = true ]; then
    WANT="restore-${STUDENT}-${SNAPID}"
    if [ "${RESTORE_CONFIRM:-}" != "$WANT" ]; then
      # exit 2 == "refused, awaiting confirmation" — distinct from a generic
      # failure so an operator (or a wrapper) can tell them apart.
      die "mode '$MODE' deletes files created since the snapshot.
       Re-run with RESTORE_CONFIRM=${WANT}
       (the token is bound to this snapshot, so a stale one cannot authorise a
       different restore)." 2
    fi
  fi

  log "student=${STUDENT} snapshot=${SNAPID} mode=${MODE} target=${LIVE} uid=$(id -u)"

  # Durable rollback point for the two modes that can destroy data. A restic
  # snapshot is better than a trash directory: it is off-box, deduplicated
  # against what is already stored, and cannot be lost to a full disk.
  if [ "$MODE" != "additive" ] && [ -d "$LIVE" ]; then
    log "taking pre-restore safety snapshot of ${LIVE}"
    restic "${ROPTS[@]}" backup "$LIVE" \
      --host "$HOSTTAG" \
      --tag pre-restore --tag "pre-restore-${STUDENT}" \
      --no-scan
    # Print the id, not just the tag: this is the most-run path, the operator
    # needs something to roll back TO, and by the second attempt the tag alone
    # is ambiguous.
    PRE_STU="$(restic "${ROPTS[@]}" snapshots --host "$HOSTTAG" --tag "pre-restore-${STUDENT}" --json \
               | jq -r 'if length > 0 then .[-1].short_id else empty end')"
    [ -n "${PRE_STU:-}" ] || die "pre-restore snapshot could not be resolved.
       Refusing to modify ${LIVE} without a recorded rollback point."
    log "PRE-RESTORE SNAPSHOT: ${PRE_STU}  <-- rollback with:"
    log "  RESTORE_MODE=exact RESTORE_STUDENT=${STUDENT} RESTORE_SNAPSHOT_ID=${PRE_STU} \\"
    log "  RESTORE_CONFIRM=restore-${STUDENT}-${PRE_STU}"
  fi

  ARGS=( "$SRC" --target "$LIVE" --sparse --overwrite "$OVERWRITE" )
  [ "$DELETE" = true ] && ARGS+=( --delete )

  restic "${ROPTS[@]}" restore "${ARGS[@]}" --verify

  log "RESTORE (${MODE}) COMPLETE for ${STUDENT} from ${SNAPID}"
  log ""
  log "The running VS Code server will not see these changes until it restarts."
  log "Finish with:  kubectl -n prod delete pod -l app.kubernetes.io/name=${STUDENT}"
  ;;

# ================================================================== full ======
# Rebuilds the entire export. Requires no_root_squash, a merged PR to set the
# parameters, AND a manual job creation.
full)
  MODE="${RESTORE_MODE:-verify}"
  try_unlock

  if [ "$MODE" != "verify" ] && [ "$(id -u)" -ne 0 ]; then
    die "mode '$MODE' must run as uid 0 to reproduce ownership across mixed uids.
       Running as $(id -u). Is no_root_squash active on the export?"
  fi

  # ---- verify: safe default, writes nothing ---------------------------------
  if [ "$MODE" = "verify" ]; then
    log "snapshots available:"
    restic "${ROPTS[@]}" snapshots --host "$HOSTTAG" --tag daily
    log ""
    log "repository integrity check:"
    restic "${ROPTS[@]}" check
    if [ "${RESTORE_SNAPSHOT_ID:-REPLACE_ME}" != "REPLACE_ME" ]; then
      SNAPID="$(resolve_snapshot "$SNAP_IN")"
      log ""
      log "snapshot ${SNAPID} contents vs live:"
      restic "${ROPTS[@]}" stats --json "$SNAPID" | jq -r '"  snapshot: \(.total_file_count) files, \(.total_size) bytes"'
      echo "  live:     $(find /data -xdev -type f 2>/dev/null | wc -l) files, $(du -sb /data 2>/dev/null | cut -f1) bytes"
    fi
    exit 0
  fi

  [ "${RESTORE_SNAPSHOT_ID:-REPLACE_ME}" != "REPLACE_ME" ] \
    || die "RESTORE_SNAPSHOT_ID is still the placeholder. Set it in values.yaml via PR."
  [ "$SNAP_IN" != "latest" ] \
    || die "'latest' is not accepted for a full restore. Name an explicit snapshot id
       so the confirmation token is bound to a specific point in time."

  SNAPID="$(resolve_snapshot "$SNAP_IN")"

  case "$MODE" in
    # ---- stage: materialise into a scratch dir; prod untouched --------------
    stage)
      STAGE="/data/.restore-staging/${SNAPID}"
      # restic cannot reliably reconstruct hardlinks into a populated target —
      # its own docs say to start from scratch. A non-empty staging dir would
      # silently produce copies where there should be links.
      [ -e "$STAGE" ] && die "staging dir ${STAGE} already exists.
       Remove it first — restoring into a populated target can silently break
       hardlink reconstruction."
      mkdir -p "$STAGE"
      log "staging snapshot ${SNAPID} into ${STAGE} (live data untouched)"
      # ${SNAPID}:/data, not ${SNAPID} -- see the comment on the commit branch.
      # Staging must reproduce the exact layout commit produces, or the operator
      # signs off on a layout the real restore will not recreate.
      restic "${ROPTS[@]}" restore "${SNAPID}:/data" --target "$STAGE" --sparse --verify
      log "STAGED. Inspect it from any pod on the PVC, then re-run with RESTORE_MODE=commit."
      log "Free space check:  df -h /data"
      ;;

    # ---- commit: overwrite the live export ---------------------------------
    commit)
      WANT="restore-${SNAPID}-to-prod"
      [ "${RESTORE_CONFIRM:-}" = "$WANT" ] \
        || die "full restore requires RESTORE_CONFIRM=${WANT} (set via PR)." 2

      log "pre-restore safety snapshot of the ENTIRE live export"
      restic "${ROPTS[@]}" backup /data \
        --host "$HOSTTAG" \
        --tag pre-restore --tag "pre-restore-full" \
        --no-scan
      PRE="$(restic "${ROPTS[@]}" snapshots --host "$HOSTTAG" --tag pre-restore-full --json \
             | jq -r 'if length > 0 then .[-1].short_id else empty end')"
      # This id is the only thing standing between the operator and recovery if
      # the restore goes wrong. Never let it be empty or the string "null".
      [ -n "${PRE:-}" ] || die "pre-restore snapshot was taken but could not be
       resolved. Refusing to overwrite the live export without a recorded
       rollback point."
      log "PRE-RESTORE SNAPSHOT: ${PRE}  <-- record this, it is your rollback point"

      log "restoring ${SNAPID} over the live export"
      # ${SNAPID}:/data -- NOT bare ${SNAPID}. Snapshot paths are absolute, so a
      # bare id restores to <target>/data/... and, because --delete prunes at the
      # target ROOT against the snapshot's root tree (whose only entry is
      # "data"), it would RECURSIVELY DELETE THE ENTIRE LIVE EXPORT and report
      # success. The :subfolder form rebases paths onto the target so the layout
      # is reproduced in place. Verified: restic 0.19.1.
      restic "${ROPTS[@]}" restore "${SNAPID}:/data" --target /data --sparse \
        --overwrite always --delete --verify

      log "FULL RESTORE COMPLETE from ${SNAPID}"
      log "Rollback if needed:  RESTORE_SNAPSHOT_ID=${PRE} RESTORE_MODE=commit"
      log "Now revert the replicas:0 commit to bring consumers back."
      ;;

    *)
      die "unknown RESTORE_MODE='$MODE' (expected: verify | stage | commit)" 64 ;;
  esac
  ;;

*)
  die "usage: restore-nfs <student|full>" 64
  ;;
esac
