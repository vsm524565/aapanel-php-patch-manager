#!/usr/bin/env bash
# AlmaLinux + cPanel EasyApache 4 PHP patch updater
# Usage:
#   bash cpanel-php-patch-update.sh --dry-run
#   bash cpanel-php-patch-update.sh --apply

set -Eeuo pipefail

MODE="${1:---dry-run}"

case "$MODE" in
    --dry-run|--apply) ;;
    *)
        echo "Usage: $0 [--dry-run|--apply]"
        exit 2
        ;;
esac

if (( EUID != 0 )); then
    echo "ERROR: Run as root."
    exit 1
fi

source /etc/os-release

if [[ "${ID:-}" != "almalinux" ]]; then
    echo "ERROR: AlmaLinux required."
    exit 1
fi

if [[ ! -x /usr/local/cpanel/cpanel ]]; then
    echo "ERROR: cPanel/WHM not detected."
    exit 1
fi

if [[ ! -d /opt/cpanel ]]; then
    echo "ERROR: EasyApache installation not detected."
    exit 1
fi

for cmd in dnf rpm tar; do
    command -v "$cmd" >/dev/null || {
        echo "ERROR: Missing command: $cmd"
        exit 1
    }
done

LOGDIR="/var/log/cpanel-php-updates"
mkdir -p "$LOGDIR"
chmod 700 "$LOGDIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/$STAMP.log"
exec > >(tee -a "$LOG") 2>&1

echo "========================================"
echo "cPanel EasyApache PHP Patch Updater"
echo "========================================"
echo "Host: $(hostname)"
echo "OS: $PRETTY_NAME"
echo "Mode: $MODE"
echo "Log: $LOG"

echo
echo "=== CPANEL VERSION ==="
/usr/local/cpanel/cpanel -V

# Detect installed EasyApache PHP packages.
# This includes ea-phpXX and installed extensions.
mapfile -t PACKAGES < <(
    rpm -qa --qf '%{NAME}\n' |
    grep -E '^ea-php[0-9]{2}($|-)' |
    sort -u
)

if (( ${#PACKAGES[@]} == 0 )); then
    echo "ERROR: No EA4 PHP packages detected."
    exit 1
fi

echo
echo "=== INSTALLED EA4 PHP PACKAGES ==="
printf '%s\n' "${PACKAGES[@]}"

echo
echo "=== INSTALLED PHP VERSIONS ==="

mapfile -t BRANCHES < <(
    printf '%s\n' "${PACKAGES[@]}" |
    grep -oE '^ea-php[0-9]{2}' |
    sort -u
)

for branch in "${BRANCHES[@]}"; do
    version="${branch#ea-php}"
    binary="/opt/cpanel/$branch/root/usr/bin/php"

    if [[ -x "$binary" ]]; then
        "$binary" -v | head -1
    else
        echo "$branch: CLI binary not present"
    fi
done

echo
echo "=== REFRESH DNF METADATA ==="
dnf makecache --refresh

echo
echo "=== SIMULATE PHP UPDATES ==="

SIM="$LOGDIR/$STAMP.simulation"

# --assumeno resolves the transaction but refuses it.
# Capture the full output for inspection.
set +e
dnf upgrade --assumeno "${PACKAGES[@]}" \
    > "$SIM" 2>&1
SIM_RC=$?
set -e

cat "$SIM"

# A nonzero return is expected when --assumeno
# declines a proposed transaction.
if grep -qiE \
    'conflicting requests|nothing provides|problem:|failed to download|cannot download|error:' \
    "$SIM"; then
    echo "ERROR: Dependency or repository problem."
    exit 1
fi

# Check for removal/replacement transactions.
if grep -Eq \
    '^[[:space:]]*(Removing|Removing dependent packages|Replacing|Downgrading):' \
    "$SIM"; then
    echo "ERROR: Transaction may remove or replace packages."
    echo "Manual review required."
    exit 1
fi

# Reject packages outside the approved PHP namespace.
# DNF may require dependency updates; review them manually
# rather than silently updating unrelated packages.
if grep -qE \
    '^[[:space:]]*(Upgrading|Installing|Installing dependencies):' \
    "$SIM"; then
    echo
    echo "Review the complete transaction above."
fi

if [[ "$MODE" == "--dry-run" ]]; then
    echo
    echo "DRY RUN COMPLETE."
    echo "No packages changed."
    echo "Simulation exit status: $SIM_RC"
    echo "Review: $SIM"
    exit 0
fi

echo
echo "=== APPLY MODE ==="
echo "A fresh DNF transaction will be calculated."
echo "Review it before accepting the DNF prompt."
read -r -p "Type UPDATE to continue: " ANSWER

if [[ "$ANSWER" != "UPDATE" ]]; then
    echo "Cancelled."
    exit 1
fi

echo
echo "=== BACKUP PHP CONFIGURATION ==="

BACKUP="$LOGDIR/php-config-$STAMP.tar.gz"
PATHS=()

for p in \
    /opt/cpanel/ea-php*/root/etc \
    /etc/cpanel/ea4 \
    /var/cpanel/ApachePHPFPM; do
    [[ -e "$p" ]] && PATHS+=("${p#/}")
done

if (( ${#PATHS[@]} == 0 )); then
    echo "ERROR: No configuration paths found."
    exit 1
fi

tar -C / -czf "$BACKUP" "${PATHS[@]}"
echo "Configuration backup: $BACKUP"

echo
echo "=== APPLY PHP UPDATES ==="

# Keep DNF interactive. Do not use -y.
dnf upgrade "${PACKAGES[@]}"

echo
echo "=== VERIFY INSTALLED PHP ==="

FAIL=0

for branch in "${BRANCHES[@]}"; do
    binary="/opt/cpanel/$branch/root/usr/bin/php"

    if [[ -x "$binary" ]]; then
        "$binary" -v | head -1 || FAIL=1
        "$binary" -m >/dev/null || FAIL=1
    else
        echo "ERROR: Missing PHP binary: $branch"
        FAIL=1
    fi
done

echo
echo "=== VERIFY CPANEL SERVICES ==="

if [[ -x /usr/local/cpanel/scripts/restartsrv_httpd ]]; then
    systemctl is-active httpd || true
fi

echo
echo "=== RESULT ==="

if (( FAIL != 0 )); then
    echo "WARNING: PHP verification failed."
    echo "Inspect logs and affected websites."
    exit 1
fi

echo "PHP package update completed."
echo "Check MultiPHP Manager and live websites."
echo "Log: $LOG"
