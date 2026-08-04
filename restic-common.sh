#!/usr/bin/env bash
# Shared helpers for backup-nfs and restore-nfs.
#
# Sourced, never executed. Installed at /usr/lib/backup-tools/restic-common.sh.
#
# The scripts are deliberately backend-agnostic: restic selects its backend from
# the RESTIC_REPOSITORY URL scheme, and this file only VALIDATES that choice and
# prepares any files it needs. It never constructs RESTIC_REPOSITORY -- restic's
# URL scheme is already that abstraction, and re-implementing it would create a
# second source of truth that can disagree with restic's own parser.

# ---------------------------------------------------------------- logging ----
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FATAL: $*" >&2; exit "${2:-1}"; }

# Global restic options, applied to EVERY restic invocation. Built by
# restic_setup(). Includes --retry-lock and any -o backend tuning.
ROPTS=()

# ------------------------------------------------------------ backend id ----
# Echo a short backend name derived from the RESTIC_REPOSITORY URL scheme.
# Mirrors restic's own dispatch (see its "Preparing a new repository" docs).
backend_of() {
  local r="${RESTIC_REPOSITORY:-}"
  case "$r" in
    s3:*)     echo s3     ;;
    b2:*)     echo b2     ;;
    azure:*)  echo azure  ;;
    gs:*)     echo gs     ;;
    swift:*)  echo swift  ;;
    sftp:*)   echo sftp   ;;
    rest:*)   echo rest   ;;
    rclone:*) echo rclone ;;
    "")       echo none   ;;
    *)        echo local  ;;
  esac
}

# Fail unless at least one of the named variables is set and non-empty.
_need_any() {
  local backend="$1" hint="$2"; shift 2
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] && return 0
  done
  die "RESTIC_REPOSITORY selects the '${backend}' backend, but none of these are
       set: $*
       ${hint}
       These are projected from the Vault secret via envFrom -- add the missing
       key there rather than to the values file."
}

# --------------------------------------------------------- backend files ----
# Backends needing a FILE rather than an env var. envFrom cannot deliver files,
# so these arrive as a mounted Secret volume.
prepare_backend_files() {
  local backend="$1"

  if [ "$backend" = "sftp" ]; then
    # restic REFUSES sftp.command and sftp.args together ("cannot specify both").
    # So if the caller supplies either via RESTIC_EXTRA_OPTS -- a jump host, an
    # ssh wrapper, a custom subsystem -- they own the connection entirely and we
    # must not inject our own args on top.
    local user_managed=false
    case " ${RESTIC_EXTRA_OPTS:-} " in
      *sftp.command=*|*sftp.args=*) user_managed=true ;;
    esac

    local d="${TMPDIR:-/tmp}/.restic-ssh"
    local key="${RESTIC_SSH_KEY:-}"

    # Copy the key whenever one is supplied, even in user-managed mode: a custom
    # sftp.command usually still needs it, and the permission fix below applies
    # either way.
    if [ -n "$key" ]; then
      [ -r "$key" ] || die "RESTIC_SSH_KEY='${key}' is not readable by uid $(id -u).
       Check the Secret volume is mounted and its defaultMode allows this uid."
      # ssh REFUSES a private key that is group- or world-readable. Kubernetes
      # mounts Secrets read-only owned by root, and restore-student runs as uid
      # 1337 -- so the key cannot be used in place. Copy it somewhere private to
      # whatever uid we happen to be and lock it down.
      mkdir -p "$d" && chmod 700 "$d"
      cp "$key" "$d/id" && chmod 600 "$d/id"
    fi

    if [ "$user_managed" = true ]; then
      log "sftp: connection managed via RESTIC_EXTRA_OPTS (sftp.command/sftp.args);
       not injecting defaults, since restic rejects both together. You are
       responsible for authentication and host-key verification."
      return 0
    fi

    [ -n "$key" ] || die "the sftp backend needs RESTIC_SSH_KEY set to the path of a
       mounted SSH private key (e.g. /secrets/ssh/id_ed25519).
       Alternatively supply your own sftp.command or sftp.args via
       RESTIC_EXTRA_OPTS and manage the connection yourself."

    local kh="${RESTIC_SSH_KNOWN_HOSTS:-}"
    [ -n "$kh" ] && [ -r "$kh" ] || die "the sftp backend needs RESTIC_SSH_KNOWN_HOSTS
       pointing at a readable known_hosts file, so the server's host key is
       PINNED. Generate it once with:
         ssh-keyscan -t ed25519 <host> > known_hosts
       and store it alongside the key. This is deliberately required: disabling
       host-key checking would let anything that can spoof DNS or occupy the
       route receive your backups."
    cp "$kh" "$d/known_hosts" && chmod 644 "$d/known_hosts"

    # Passed through to ssh by restic. BatchMode makes a missing/rejected key
    # fail immediately instead of hanging on a password prompt in a CronJob.
    ROPTS+=(-o "sftp.args=-i ${d}/id -o UserKnownHostsFile=${d}/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o IdentitiesOnly=yes")
    log "sftp: using key ${key} with pinned host keys from ${kh}"
  fi

  if [ "$backend" = "gs" ] && [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
    [ -r "$GOOGLE_APPLICATION_CREDENTIALS" ] || die "GOOGLE_APPLICATION_CREDENTIALS='${GOOGLE_APPLICATION_CREDENTIALS}'
       is not readable by uid $(id -u). It must be a mounted Secret volume, not
       an env var -- it is a path to a JSON key file."
  fi
}

# ------------------------------------------------------------- preflight ----
# Fail early and specifically, rather than letting restic fail obscurely or --
# far worse -- letting a misconfigured repository silently initialise a new
# empty one and report success.
preflight() {
  local backend; backend="$(backend_of)"

  [ -n "${RESTIC_REPOSITORY:-}" ] \
    || die "RESTIC_REPOSITORY is not set. It selects both the location AND the
       backend; see the NFS section of README.md for the format per backend."

  [ -n "${RESTIC_PASSWORD:-}${RESTIC_PASSWORD_FILE:-}${RESTIC_PASSWORD_COMMAND:-}" ] \
    || die "no repository password: set RESTIC_PASSWORD, RESTIC_PASSWORD_FILE or
       RESTIC_PASSWORD_COMMAND. Without it restic cannot read or write anything."

  case "$backend" in
    s3)
      _need_any s3 "S3-compatible targets (AWS, Hetzner Object Storage, Cloudflare R2, Backblaze B2's S3 API, MinIO, Wasabi) all use the AWS_* names." \
        AWS_ACCESS_KEY_ID
      _need_any s3 "" AWS_SECRET_ACCESS_KEY
      ;;
    b2)
      _need_any b2 "This is B2's NATIVE backend. To use B2 via its S3 API instead, use an s3: URL and AWS_* credentials." \
        B2_ACCOUNT_ID
      _need_any b2 "" B2_ACCOUNT_KEY
      ;;
    azure)
      _need_any azure "" AZURE_ACCOUNT_NAME
      _need_any azure "Provide either an account key or a SAS token." \
        AZURE_ACCOUNT_KEY AZURE_ACCOUNT_SAS
      ;;
    gs)
      _need_any gs "" GOOGLE_PROJECT_ID
      _need_any gs "GOOGLE_APPLICATION_CREDENTIALS is a PATH to a mounted JSON key file, not the JSON itself." \
        GOOGLE_APPLICATION_CREDENTIALS GOOGLE_ACCESS_TOKEN
      ;;
    swift)
      _need_any swift "Keystone v3 uses OS_AUTH_URL; v1 uses ST_AUTH." \
        OS_AUTH_URL ST_AUTH
      ;;
    rest)
      [ -n "${RESTIC_REST_USERNAME:-}" ] || [ -n "${RESTIC_REST_PASSWORD:-}" ] \
        || log "WARNING: rest backend with no RESTIC_REST_USERNAME/PASSWORD -- fine
         only if the server is unauthenticated or credentials are in the URL."
      ;;
    rclone)
      command -v rclone >/dev/null 2>&1 || die "RESTIC_REPOSITORY selects the rclone
       backend, but rclone is not installed in this image. Use a native backend
       (s3:, b2:, azure:, gs:, swift:, sftp:, rest:) or add rclone to the image."
      ;;
    sftp|local) : ;;   # sftp validated in prepare_backend_files; local needs nothing
    none) die "RESTIC_REPOSITORY is empty" ;;
  esac

  prepare_backend_files "$backend"
  log "backend=${backend} repository=$(redact_repo)"
}

# Repository URLs can embed credentials (rest:https://user:pass@host). Never log
# them verbatim.
redact_repo() {
  echo "${RESTIC_REPOSITORY:-}" | sed -E 's#(//[^:/@]+):[^@]*@#\1:***@#'
}

# ----------------------------------------------------------- global opts ----
restic_setup() {
  ROPTS=(--retry-lock "${RESTIC_RETRY_LOCK:-30m}")

  # Free-form passthrough for backend tuning, e.g.
  #   RESTIC_EXTRA_OPTS="s3.connections=10 sftp.connections=8"
  # Deliberately unvalidated: restic rejects unknown keys itself, and keeping a
  # local allowlist would go stale every time restic adds an option.
  if [ -n "${RESTIC_EXTRA_OPTS:-}" ]; then
    local o
    for o in $RESTIC_EXTRA_OPTS; do ROPTS+=(-o "$o"); done
  fi

  preflight
}

# --------------------------------------------------------------- repo init ---
# Auto-init is gated. `restic cat config` fails for THREE different reasons --
# the repository does not exist, the password is wrong, or the backend is
# unreachable -- and restic cannot distinguish them. Without this gate a typo in
# RESTIC_REPOSITORY silently creates a brand-new empty repository, backs up into
# it, and reports success; the shrink guard cannot catch it either, because it
# reports "no previous snapshot -- first run".
ensure_repo() {
  if restic "${ROPTS[@]}" cat config >/dev/null 2>&1; then
    return 0
  fi
  if [ "${ALLOW_REPO_INIT:-false}" != "true" ]; then
    die "cannot open the repository at $(redact_repo).
       This means ONE of: it does not exist yet, RESTIC_PASSWORD is wrong, or
       the backend is unreachable. restic cannot tell these apart.

       If you are genuinely creating this repository for the first time, re-run
       once with ALLOW_REPO_INIT=true, then REMOVE that setting.

       Refusing to auto-create, because a typo in RESTIC_REPOSITORY would
       otherwise start a fresh empty backup history that reports success."
  fi
  log "ALLOW_REPO_INIT=true and no readable repository -- running restic init"
  restic "${ROPTS[@]}" init
}

# Clear locks left by a crashed job. NOT `unlock --remove-all`, which would break
# a concurrently running one. Note this is not purely a "stale lock" operation:
# restic removes ANY lock older than 30 minutes regardless of host or liveness,
# and only does a same-host process-liveness check below that age. Never fatal --
# an object-store hiccup must not fail a read-only command.
try_unlock() { restic "${ROPTS[@]}" unlock || log "WARNING: restic unlock failed; continuing"; }
