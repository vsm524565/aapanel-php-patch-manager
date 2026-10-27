#!/usr/bin/env bash
# CyberPanel / Ubuntu LiteSpeed PHP patch updater
# Default: dry-run
# Apply:   bash script.sh --apply

set -Eeuo pipefail

MODE="${1:---dry-run}"
[[ "$MODE" == "--dry-run" || "$MODE" == "--apply" ]] || {
    echo "Usage: $0 [--dry-run|--apply]"
    exit 2
}

(( EUID == 0 )) || {
    echo "ERROR: Run as root"
    exit 1
}

source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || {
    echo "ERROR: Ubuntu required"
    exit 1
}

[[ -d /usr/local/CyberCP && -d /usr/local/lsws ]] || {
    echo "ERROR: CyberPanel / LiteSpeed not detected"
    exit 1
}

for cmd in apt-get dpkg-query tar; do
    command -v "$cmd" >/dev/null || exit 1
done

LOGDIR="/var/log/cyberpanel-php-updates"
mkdir -p "$LOGDIR"
chmod 700 "$LOGDIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/$STAMP.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== CYBERPANEL PHP PATCH UPDATE ==="
echo "Host: $(hostname)"
echo "OS: $PRETTY_NAME"
echo "Mode: $MODE"

# Collect only installed LiteSpeed PHP packages.
mapfile -t PACKAGES < <(
    dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' |
    awk '$2 == "ii" {print $1}' |
    grep -E '^lsphp[0-9]{2}($|-)' |
    grep -v ':' |
    sort -u
)

(( ${#PACKAGES[@]} > 0 )) || {
    echo "ERROR: No installed APT-managed LSPHP packages"
    exit 1
}

mapfile -t BRANCHES < <(
    printf '%s\n' "${PACKAGES[@]}" |
    grep -oE '^lsphp[0-9]{2}' |
    sort -u
)

echo
echo "=== INSTALLED PHP VERSIONS ==="
for branch in "${BRANCHES[@]}"; do
    binary="/usr/local/lsws/$branch/bin/lsphp"
    if [[ -x "$binary" ]]; then
        "$binary" -v | head -1
    else
        echo "WARNING: $branch executable missing"
    fi
done

echo
echo "=== REFRESH PACKAGE METADATA ==="
apt-get update --error-on=any

echo
echo "=== SIMULATE PATCH UPDATE ==="
SIM="$LOGDIR/$STAMP.simulation"

apt-get -s install --only-upgrade "${PACKAGES[@]}" \
    > "$SIM" 2>&1 || {
        cat "$SIM"
        echo "ERROR: APT simulation failed"
        exit 1
    }

grep -E 'upgraded,|^Inst |^Remv ' "$SIM" || true

# Refuse removal or new installation.
if grep -q '^Remv ' "$SIM"; then
    echo "ERROR: Package removal proposed"
    exit 1
fi

if grep -Eq '^Inst [^ ]+ \(' "$SIM"; then
    echo "ERROR: New package installation proposed"
    exit 1
fi

# Refuse upgrades outside the installed LSPHP namespace.
while read -r action pkg rest; do
    [[ "$action" == "Inst" ]] || continue
    case "$pkg" in
        lsphp[0-9][0-9]|lsphp[0-9][0-9]-*) ;;
        *)
            echo "ERROR: Unexpected package: $pkg"
            exit 1
            ;;
    esac
done < "$SIM"

if ! grep -q '^Inst ' "$SIM"; then
    echo "No available LiteSpeed PHP updates"
    exit 0
fi

if [[ "$MODE" == "--dry-run" ]]; then
    echo
    echo "DRY RUN COMPLETE"
    echo "No changes applied"
    echo "Simulation: $SIM"
    exit 0
fi

echo
read -r -p "Type UPDATE to proceed: " ANSWER
[[ "$ANSWER" == "UPDATE" ]] || {
    echo "Cancelled"
    exit 1
}

echo
echo "=== BACKUP PHP CONFIGURATION ==="
BACKUP="$LOGDIR/php-config-$STAMP.tar.gz"
PATHS=()

for branch in "${BRANCHES[@]}"; do
    for dir in \
        "/usr/local/lsws/$branch/etc" \
        "/usr/local/lsws/$branch/lib"; do
        if [[ -d "$dir" && "$dir" == */etc ]]; then
            PATHS+=("${dir#/}")
        fi
    done
done

[[ -d /usr/local/lsws/conf ]] &&
    PATHS+=("usr/local/lsws/conf")

(( ${#PATHS[@]} > 0 )) || {
    echo "ERROR: No configuration directories found"
    exit 1
}

tar -C / -czf "$BACKUP" "${PATHS[@]}"
echo "Backup: $BACKUP"

echo
echo "=== APPLY PHP PATCH UPDATES ==="

# Keep modified local configuration files.
DEBIAN_FRONTEND=noninteractive \
apt-get install --only-upgrade \
    -o Dpkg::Options::="--force-confold" \
    "${PACKAGES[@]}"

echo
echo "=== VERIFY PHP BINARIES ==="
FAIL=0

for branch in "${BRANCHES[@]}"; do
    binary="/usr/local/lsws/$branch/bin/lsphp"

    if [[ -x "$binary" ]]; then
        "$binary" -v | head -1 || FAIL=1
        "$binary" -m >/dev/null || FAIL=1
    else
        echo "ERROR: Missing $binary"
        FAIL=1
    fi
done

echo
echo "=== WEB SERVER STATUS ==="
systemctl is-active lsws || FAIL=1

echo
if (( FAIL != 0 )); then
    echo "WARNING: Verification failed"
    echo "Check LiteSpeed and website error logs"
    exit 1
fi

echo "PHP package updates completed"
echo "Verify websites and CyberPanel PHP assignments"
echo "Log: $LOG"
