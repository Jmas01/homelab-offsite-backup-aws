#!/usr/bin/env bash
# s3-offsite-backup.sh: encrypted off-site copy of NAS-only backups to AWS S3.
#
# Usage: s3-offsite-backup.sh daily|weekly|photos [--dry-run]
#   daily   newest dump of each database          -> aws-crypt:daily/   (lifecycle: expire 30 d)
#   weekly  newest config archive + pve-host tar   -> aws-crypt:weekly/  (lifecycle: expire 57 d = 8 copies)
#   photos  Immich originals (library/upload/profile) -> aws-crypt:photos/ (lifecycle: Deep Archive, kept)
#   --dry-run  show what would be uploaded, upload nothing
#
# The S3 user (homelab-backup-writer) can upload but NOT delete. So this script only
# ever uses copy/copyto, never sync/move. Old copies are removed by the bucket's
# lifecycle rules, not by this script.
# aws-crypt = rclone crypt over aws-s3:<your-bucket>, filename encryption off
# (folder names must stay readable for the lifecycle prefixes). The crypt password
# lives in a password manager; there is no recovery if it is lost.
set -Eeuo pipefail
umask 077

MODE="${1:-}"
DRY_RUN=0
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1

RCLONE_CONF=/root/.config/rclone/rclone.conf
REMOTE="aws-crypt:"
B=/mnt/pve/data/backups
PHOTOS=/mnt/pve/data/docker/appdata/immich/upload
STATE=/var/lib/s3-offsite-backup

log()  { echo "$(date -u +%FT%TZ) [$MODE] $*"; }
fail() { log "ERROR: $*"; exit 1; }
trap 'log "ERROR: line $LINENO: command failed (exit $?)"' ERR

rc=(rclone --config "$RCLONE_CONF")
(( DRY_RUN )) && rc+=(--dry-run)

# newest <dir> <glob> <max age hours>: print the newest matching file; fail if none or too old.
newest() {
  local dir="$1" glob="$2" hours="$3" f
  f=$(find "$dir" -maxdepth 1 -type f -name "$glob" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  [[ -n "$f" ]] || fail "no file matching $glob in $dir"
  [[ -n "$(find "$f" -newermt "-$hours hours")" ]] || fail "newest $glob is older than ${hours}h: $f"
  echo "$f"
}

# up <prefix> <dir> <glob> <max age hours>: upload the newest match to aws-crypt:<prefix>/.
# copyto skips a file that is already there, so a re-run never uploads twice.
up() {
  local prefix="$1" f
  f=$(newest "$2" "$3" "$4")
  log "upload $(basename "$f") ($(du -h "$f" | cut -f1)) -> $prefix/"
  "${rc[@]}" --stats 0 copyto "$f" "${REMOTE}${prefix}/$(basename "$f")"
}

mountpoint -q /mnt/pve/data || fail "/mnt/pve/data is not mounted"
mkdir -p "$STATE"
log "start$( (( DRY_RUN )) && echo ' (dry run)' || true)"

case "$MODE" in
  daily)
    up daily "$B/databases"    'Authentik-DB-*.sql.gz'  36
    up daily "$B/databases"    'Firefly-DB-*.sql.gz'    36
    up daily "$B/databases"    'immich_db-*.sql.gz'     36
    up daily "$B/databases"    'Manyfold-DB-*.sql.gz'   36
    up daily "$B/databases"    'Warracker-DB-*.sql.gz'  36
    up daily "$B/paperless"    'paperless-*.sql.gz'     36
    # PC dumps (Docker Desktop, 17:00 UTC): 72 h so a day with the PC off doesn't alert.
    up daily "$B/pc-databases" 'n8n-*.dump'             72
    up daily "$B/pc-databases" 'romm-*.sql.gz'          72
    ;;
  weekly)
    up weekly "$B/lab_config"  'docker-config-*.tar.gz' 36
    up weekly "$B/pve-host"    'pve-host-*.tar.gz'      200
    ;;
  photos)
    # --size-only: compare by size from the bucket listing, so rclone never has to read
    # an object (they sit in Deep Archive). Originals don't change in place.
    log "copy Immich originals -> photos/"
    "${rc[@]}" copy "$PHOTOS" "${REMOTE}photos" \
      --include '/library/**' --include '/upload/**' --include '/profile/**' \
      --size-only --transfers 4 --checkers 8 \
      --stats 15m --stats-one-line --stats-log-level NOTICE \
      ${BWLIMIT:+--bwlimit "$BWLIMIT"}
    ;;
  *) echo "usage: $0 daily|weekly|photos [--dry-run]" >&2; exit 2 ;;
esac

(( DRY_RUN )) || touch "$STATE/$MODE.ok"
log "done"
