#!/usr/bin/env bash
# php-patch-update.sh
# Update existing APT-managed PHP packages on Ubuntu.
# Default: dry run. Use --apply to perform updates.

set -Eeuo pipefail

# Default to planning; retain --dry-run compatibility.
MODE="--dry-run"

if (($# > 1)); then
    printf 'Usage: %s [--plan|--dry-run|--apply]\n' "$0" >&2
    exit 2
fi

case "${1:---plan}" in
    --plan|--dry-run)
        MODE="--dry-run"
        ;;
    --apply)
        MODE="--apply"
        ;;
    -h|--help)
        printf 'Usage: %s [--plan|--dry-run|--apply]\n' "$0"
        exit 0
        ;;
    *)
        printf 'Unknown argument: %s\n' "$1" >&2
        printf 'Usage: %s [--plan|--dry-run|--apply]\n' "$0" >&2
        exit 2
        ;;
esac

if (( EUID != 0 )); then
    echo "ERROR: Run as root."
    exit 1
fi

. /etc/os-release
# Support conventional PHP packages on Ubuntu and Debian.
case "${ID:-}" in
    ubuntu|debian)
        ;;
    *)
        echo "ERROR: Ubuntu or Debian required."
        exit 1
        ;;
esac

# Reject panel installations with nonstandard PHP management.
for path in /www/server/panel /usr/local/lsws \
            /usr/local/psa /usr/local/cpanel \
            /usr/local/directadmin; do
    if [[ -e "$path" ]]; then
        echo "ERROR: Nonstandard/panel-managed PHP may exist: $path"
        echo "Use that panel's supported update procedure."
        exit 1
    fi
done

# Supported modes: HestiaCP or a conventional Ubuntu
# APT-managed PHP installation.
if [[ -d /usr/local/hestia ]]; then
    PANEL="HestiaCP"
else
    PANEL="${PRETTY_NAME} APT-managed PHP"
fi

LOGDIR="/var/log/php-patch-updates"
mkdir -p "$LOGDIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/$STAMP.log"

exec > >(tee -a "$LOG") 2>&1

echo "=== PHP PATCH UPDATE ==="
echo "Host: $(hostname)"
echo "OS: ${PRETTY_NAME}"
echo "Panel: $PANEL"
echo "Mode: $MODE"
echo "Log: $LOG"

# Detect installed PHP packages, including extensions.
mapfile -t PACKAGES < <(
    dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' |
    awk '$2 ~ /^ii/ {print $1}' |
    grep -E '^php([0-9]+\.[0-9]+($|-)|-common$)' |
    grep -v ':' |
    sort -u
)

if (( ${#PACKAGES[@]} == 0 )); then
    echo "ERROR: No supported APT-managed PHP packages found."
    exit 1
fi

echo
echo "=== INSTALLED PHP BRANCHES ==="
for v in $(find /etc/php -mindepth 1 -maxdepth 1 \
    -type d -printf '%f\n' 2>/dev/null | sort -V); do
    [[ -x "/usr/bin/php$v" ]] &&
        "/usr/bin/php$v" -v | head -1 || true
done

echo
echo "=== REFRESH APT ==="
apt-get update --error-on=any

echo
echo "=== SIMULATE UPDATE ==="
SIM="$LOGDIR/$STAMP.simulation"
apt-get -s install --only-upgrade "${PACKAGES[@]}" \
    > "$SIM" 2>&1 || {
        cat "$SIM"
        echo "ERROR: APT simulation failed."
        exit 1
    }

grep -E 'upgraded,|^Inst |^Remv ' "$SIM" || true

# Reject removals and new package installations.
if grep -q '^Remv ' "$SIM"; then
    echo "ERROR: Simulation proposes package removals."
    exit 1
fi

if grep -Eq '^Inst [^ ]+ \(' "$SIM"; then
    echo "ERROR: Simulation proposes a new package."
    exit 1
fi

if ! grep -q '^Inst ' "$SIM"; then
    echo "No applicable PHP updates."
    exit 0
fi

if [[ "$MODE" == "--dry-run" ]]; then
    echo
    echo "DRY RUN COMPLETE. No packages changed."
    echo "Review: $SIM"
    echo "Apply with: $0 --apply"
    exit 0
fi

# Explicit confirmation before modifying production.
echo
read -r -p "Type UPDATE to proceed: " ANSWER
if [[ "$ANSWER" != "UPDATE" ]]; then
    echo "Cancelled."
    exit 1
fi

# Preserve PHP configuration and Hestia PHP templates.
BACKUP="$LOGDIR/php-config-$STAMP.tar.gz"
BACKUP_PATHS=()
for p in /etc/php \
         /usr/local/hestia/data/templates/web/php-fpm; do
    [[ -d "$p" ]] && BACKUP_PATHS+=("${p#/}")
done

tar -C / -czf "$BACKUP" "${BACKUP_PATHS[@]}"
echo "Configuration backup: $BACKUP"

echo
echo "=== APPLY PHP PATCH UPDATES ==="
# Do not overwrite locally modified configuration files.
DEBIAN_FRONTEND=noninteractive \
apt-get install --only-upgrade \
    -o Dpkg::Options::="--force-confold" \
    "${PACKAGES[@]}"

echo
echo "=== VERIFY PHP-FPM ==="
FAIL=0

for v in $(find /etc/php -mindepth 1 -maxdepth 1 \
    -type d -printf '%f\n' 2>/dev/null | sort -V); do

    if [[ -x "/usr/bin/php$v" ]]; then
        "/usr/bin/php$v" -v | head -1 || FAIL=1
    fi

    if [[ -x "/usr/sbin/php-fpm$v" ]]; then
        if ! "/usr/sbin/php-fpm$v" -t; then
            echo "ERROR: PHP $v FPM configuration invalid."
            FAIL=1
        fi

        if ! systemctl is-active --quiet "php$v-fpm"; then
            echo "ERROR: php$v-fpm is not active."
            FAIL=1
        fi
    fi
done

echo
if (( FAIL != 0 )); then
    echo "WARNING: PHP verification failed."
    echo "Check FPM logs and hosted websites."
    exit 1
fi

echo "PHP package update and basic FPM checks completed."
echo "Test hosted applications before closing maintenance."
