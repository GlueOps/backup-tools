#!/usr/bin/env bash
# Full-fidelity restic backup of the shared NFS export.
#
# Installed as /usr/bin/backup-nfs. Modes: backup | prune | verify
#
# Credentials and repo location arrive as env vars, projected wholesale from
# Vault by the chart's externalSecret -> envFrom:
#   RESTIC_REPOSITORY, RESTIC_PASSWORD,
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
#
# Deployment-specific values come from the environment, never hardcoded here:
#   BACKUP_HOST        snapshot host label (default: foobar)
#   RESTIC_KEEP_TAGS   comma-separated tags pinned against pruning (optional)
#   HEARTBEAT_URL      external dead-man's switch, pinged on success (optional)
#
# NOTE ON FIDELITY: there are deliberately NO --exclude flags anywhere in this
# script. The requirement is a complete backup. restic captures uid/gid, mode,
# setuid/setgid/sticky, symlinks, hardlinks, sparse content, timestamps and
# user.* xattrs with no flags. (There is no xattr flag on `restic backup` at
# all; --exclude-xattr / --include-xattr are restore-side filters.)
#
# POSIX ACLs, file capabilities and SELinux contexts are NOT captured. That is a
# limitation of NFSv4.2, not of restic: RFC 8276 restricts xattrs over NFS to
# the user.* namespace, and this server has vers3 disabled so the NFSACL
# sideband is unavailable. Closing that gap requires running restic on the NFS
# server against the local filesystem.

set -Eeuo pipefail

MODE="${1:-backup}"
# Snapshot "host" label. Purely an identifier restic stamps on snapshots and
# filters by -- it is not resolved or connected to. It MUST be identical here
# and in restore-nfs, or the restore's --host filter finds nothing.
HOSTTAG="${BACKUP_HOST:-foobar}"
# Most lock contention resolves itself; this makes `unlock` genuinely rare.
LOCKOPT="--retry-lock 30m"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FATAL: $*" >&2; exit "${2:-1}"; }

# Create the repo on first run. `restic cat config` is the cheapest existence
# probe that also proves the password is correct.
if ! restic cat config >/dev/null 2>&1; then
  log "repository not initialised — running restic init"
  restic init
fi

# Clear locks left by a crashed job. NOT the same as `unlock --remove-all`,
# which would break a concurrently running one. Be aware this is not purely a
# "stale lock" operation: restic removes ANY lock older than 30 minutes
# regardless of host or liveness, and only does a same-host process-liveness
# check below that age. Healthy jobs refresh their lock every 5 minutes, so this
# is normally safe -- but keep prune, backup and verify on separate schedules.
# Never fatal: an object-store hiccup here must not fail the run.
restic unlock || log "WARNING: restic unlock failed; continuing"

case "$MODE" in

# ---------------------------------------------------------------------- backup
backup)
  if [ "$(id -u)" -ne 0 ]; then
    die "must run as uid 0. Running as $(id -u) cannot read non-world-readable files."
  fi

  # End-to-end restorability proof. /canary is the only writable mount; the rest
  # of the export is mounted read-only so this job cannot damage live data.
  mkdir -p /canary
  date -u +%s > /canary/heartbeat

  # /canary is a subPath mount of <export>/.backup-canary, so the heartbeat MUST
  # also be visible under the read-only /data mount — otherwise it is not inside
  # the backup and `verify` has nothing to prove restorability with. Without this
  # check a broken volumeMount surfaces a week later as a confusing verify
  # failure instead of immediately, here, in the job that caused it.
  if [ ! -r /data/.backup-canary/heartbeat ]; then
    die "canary written to /canary is not visible at /data/.backup-canary/heartbeat.
       The volumeMounts are wrong: /canary must be the same PVC as /data with
       subPath '.backup-canary'. Fix the values file before trusting this backup."
  fi

  rc=0
  restic backup /data \
    --host "$HOSTTAG" \
    --tag daily \
    --no-scan \
    $LOCKOPT \
    --verbose || rc=$?

  case "$rc" in
    0) log "backup completed" ;;
    3)
      # Under "back up everything, all permissions" a partial snapshot does not
      # meet the requirement. Treating exit 3 as success is exactly how a
      # root_squash-crippled backup gets shipped unnoticed.
      die "restic exited 3 — snapshot was created but some files were unreadable.
       This almost certainly means root_squash is still active on the export.
       Check /etc/exports on the NFS server for no_root_squash.
       DO NOT downgrade this to a warning." 3
      ;;
    *) die "restic backup exited $rc" "$rc" ;;
  esac

  # ---- shrink guard ----------------------------------------------------------
  # Catches the failure neither Prometheus alert can see: the export vanishes or
  # empties while the server stays up. restic walks an empty tree, backs up
  # nothing, and exits 0. Comparing against the previous snapshot turns that
  # silent success into a loud failure at the moment it happens. It also detects
  # a root_squash regression, which shows up as a large drop in visible files.
  PREV="$(restic snapshots --host "$HOSTTAG" --tag daily --json \
          | jq -r 'if length >= 2 then .[-2].id else empty end')" \
    || { log "WARNING: could not list snapshots for the shrink guard; skipping it"; PREV=""; }
  if [ -n "${PREV:-}" ]; then
    # Both sides MUST use the same filter. An unfiltered `latest` resolves to
    # the newest snapshot in the whole repo -- including the small,
    # single-student `pre-restore` snapshots that restore-nfs writes under this
    # same host -- which would collapse NEWN and fail a perfectly good backup.
    NEWN="$(restic stats --json --host "$HOSTTAG" --tag daily latest | jq -r '.total_file_count')"
    OLDN="$(restic stats --json "$PREV"                              | jq -r '.total_file_count')"
    log "file count: previous=$OLDN current=$NEWN"
    # Guard against a garbage comparison rather than trusting jq's output.
    if ! [[ "$OLDN" =~ ^[0-9]+$ ]] || ! [[ "$NEWN" =~ ^[0-9]+$ ]]; then
      die "could not read file counts from restic stats (previous='$OLDN'
       current='$NEWN'). Refusing to silently skip the shrink guard."
    fi
    # Below this threshold the ratio is too noisy to be meaningful. Real runs are
    # in the millions; a tiny count here is itself a red flag, so say so loudly
    # rather than skipping in silence.
    if [ "$OLDN" -le 100 ]; then
      log "WARNING: previous snapshot had only ${OLDN} files — shrink guard not"
      log "         meaningful at this size. Is the export actually populated?"
    elif [ $(( NEWN * 100 / OLDN )) -lt 50 ]; then
      die "snapshot file count fell ${OLDN} -> ${NEWN} (>50% drop).
       Empty or unmounted export? root_squash regression? Investigate before
       the retention policy ages out the good snapshots."
    fi
  else
    log "no previous snapshot — skipping shrink guard (first run)"
  fi

  # External dead-man's switch. Everything in Prometheus dies with the cluster;
  # this does not. Failure to ping must not fail the backup.
  if [ -n "${HEARTBEAT_URL:-}" ]; then
    curl -fsS -m 15 --retry 3 "$HEARTBEAT_URL" >/dev/null || \
      log "WARNING: heartbeat ping failed (backup itself succeeded)"
  fi

  log "backup OK"
  ;;

# ----------------------------------------------------------------------- prune
prune)
  # Two weeks at full daily granularity (a student notices a loss within days),
  # then weekly/monthly/yearly out to academic-records timescale.
  KEEP_ARGS=(
    --keep-last 7
    --keep-daily 14
    --keep-weekly 8
    --keep-monthly 24
    --keep-yearly 10
  )
  # Pinned end-of-term snapshots that must survive all pruning. NOTE: `forget`
  # is scoped by --tag daily below, so a snapshot tagged ONLY term-<X> is never
  # a forget candidate in the first place. --keep-tag therefore matters only for
  # snapshots carrying BOTH tags -- tag end-of-term snapshots `daily` too if you
  # want this to be what protects them.
  if [ -n "${RESTIC_KEEP_TAGS:-}" ]; then
    IFS=',' read -ra TAGS <<< "$RESTIC_KEEP_TAGS"
    for t in "${TAGS[@]}"; do
      KEEP_ARGS+=(--keep-tag "$t")
    done
  fi

  # `forget` alone is cheap metadata deletion. `prune` is what reclaims space,
  # costs time, and carries risk — which is why they are never run inside the
  # backup job.
  restic forget --host "$HOSTTAG" --tag daily $LOCKOPT "${KEEP_ARGS[@]}"

  # --max-unused trades a little wasted space for far less repacking.
  # --max-repack-size bounds runtime so a monthly cliff cannot produce a
  # 12-hour job. NOTE: the FIRST prune after adopting restic 0.19.x repacks more
  # small packs than steady-state — expect one long run.
  restic prune --max-unused 5% --max-repack-size 100G $LOCKOPT

  log "prune OK"
  ;;

# ---------------------------------------------------------------------- verify
verify)
  # Rotate the bucket by ISO week so all 52 buckets are covered over a year.
  # A fixed `1/52` would re-read the SAME ~2% every week forever, leaving 98%
  # of pack data never verified -- bucket membership is a property of the pack
  # ID, not a random sample. 10# forces base 10: %V emits "08"/"09", which bash
  # would otherwise reject as invalid octal and abort under set -e.
  BUCKET=$(( (10#$(date -u +%V) - 1) % 52 + 1 ))
  log "read-data verification bucket ${BUCKET}/52 (rotates weekly)"
  restic check --read-data-subset="${BUCKET}/52" $LOCKOPT

  # Structural integrity is not restorability. Restore the canary and confirm it
  # is FRESH — this proves the whole path works end to end.
  rm -rf /verify/*
  restic restore latest \
    --host "$HOSTTAG" --tag daily \
    --target /verify \
    --include /data/.backup-canary/heartbeat \
    $LOCKOPT

  HB="/verify/data/.backup-canary/heartbeat"
  [ -f "$HB" ] || die "canary heartbeat not present in the latest snapshot.
       The backup is not capturing /data/.backup-canary — restores are unproven."

  age=$(( $(date -u +%s) - $(cat "$HB") ))
  if [ "$age" -gt 172800 ]; then
    die "restored canary is ${age}s old (>48h). Backups are stale."
  fi
  log "verify OK: canary is ${age}s old"
  ;;

*)
  die "unknown mode '$MODE' (expected: backup | prune | verify)" 64
  ;;
esac
