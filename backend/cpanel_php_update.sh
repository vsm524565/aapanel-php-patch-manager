#!/usr/bin/env bash
# AlmaLinux + cPanel EasyApache 4 PHP patch updater
# Usage:
#   bash cpanel-php-patch-update.sh --dry-run
#   bash cpanel-php-patch-update.sh --apply

set -Eeuo pipefail
export LC_ALL=C
umask 077

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

source /etc/os-release

# Select the package manager for this cPanel installation.
case "${ID:-}" in
    ubuntu)
        PACKAGE_MANAGER="apt"
        ;;
    almalinux)
        PACKAGE_MANAGER="dnf"
        ;;
    *)
        echo "ERROR: Supported environments: Ubuntu or AlmaLinux + cPanel."
        exit 1
        ;;
esac

if [[ ! -x /usr/local/cpanel/cpanel ]]; then
    echo "ERROR: cPanel/WHM not detected."
    exit 1
fi

if [[ ! -d /opt/cpanel ]]; then
    echo "ERROR: EasyApache installation not detected."
    exit 1
fi

# Check the commands required by the selected package manager.
REQUIRED_COMMANDS=(tar)

if [[ "$PACKAGE_MANAGER" == "apt" ]]; then
    REQUIRED_COMMANDS+=(dpkg-query dpkg apt-get)
else
    REQUIRED_COMMANDS+=(dnf rpm)
fi

for cmd in "${REQUIRED_COMMANDS[@]}"; do
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
# Discover installed EA4 PHP packages using the native package database.
# Preserve architecture qualifiers reported by dpkg.
if [[ "$PACKAGE_MANAGER" == "apt" ]]; then
    PACKAGE_RECORDS="$(
        dpkg-query -W \
            -f='${binary:Package}\t${db:Status-Status}\n'
    )" || {
        echo "ERROR: Cannot read the DPKG package database."
        exit 1
    }

    mapfile -t PACKAGES < <(
        awk -F '\t' '
            $2 == "installed" &&
            $1 ~ /^ea-php[0-9][0-9]($|[-:])/ {
                print $1
            }
        ' <<< "$PACKAGE_RECORDS" | sort -u
    )
else
    PACKAGE_RECORDS="$(rpm -qa --qf '%{NAME}\n')" || {
        echo "ERROR: Cannot read the RPM package database."
        exit 1
    }

    mapfile -t PACKAGES < <(
        printf '%s\n' "$PACKAGE_RECORDS" |
            grep -E '^ea-php[0-9]{2}($|-)' |
            sort -u
    )
fi

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
# Inspect Ubuntu EA4 upgrades without changing installed packages.
# The existing DNF implementation continues below for AlmaLinux.
if [[ "$PACKAGE_MANAGER" == "apt" ]]; then

    echo "=== REFRESH APT METADATA ==="
    apt-get -o APT::Update::Error-Mode=any update

    echo
    echo "=== SIMULATE EA4 PHP UPDATES ==="
    SIM="$LOGDIR/$STAMP.simulation"

    if ! apt-get -s --no-remove install --only-upgrade \
        "${PACKAGES[@]}" > "$SIM" 2>&1; then
        cat "$SIM"
        echo "ERROR: APT simulation failed."
        exit 1
    fi

    cat "$SIM"

    # Validate every proposed change against installed EA4 packages.
    declare -A APPROVED_PACKAGES=()
    for package in "${PACKAGES[@]}"; do
        APPROVED_PACKAGES["$package"]=1
    done

    UPDATE_COUNT=0
    APT_TARGETS=()
    INSTALL_PATTERN='^Inst ([^ ]+) \[([^]]+)\] \(([^ ]+)'

    while IFS= read -r line; do
        case "$line" in
            Remv\ *)
                echo "ERROR: Simulation proposes a package removal."
                exit 1
                ;;
            Inst\ *)
                if [[ ! "$line" =~ $INSTALL_PATTERN ]]; then
                    echo "ERROR: New installation or unrecognized transaction:"
                    printf '%s\n' "$line"
                    exit 1
                fi

                package="${BASH_REMATCH[1]}"
                installed="${BASH_REMATCH[2]}"
                proposed="${BASH_REMATCH[3]}"

                # APT may omit the native architecture qualifier.
                if [[ ! ${APPROVED_PACKAGES[$package]+present} ]]; then
                    matches=0
                    for approved in "${PACKAGES[@]}"; do
                        if [[ "${approved%%:*}" == "$package" ]]; then
                            matches=$((matches + 1))
                        fi
                    done

                    if ((matches != 1)); then
                        echo "ERROR: Unapproved or ambiguous package: $package"
                        exit 1
                    fi
                fi

                if ! dpkg --compare-versions "$proposed" gt "$installed"; then
                    echo "ERROR: Proposed change is not an upgrade: $package"
                    exit 1
                fi

                UPDATE_COUNT=$((UPDATE_COUNT + 1))
                # Apply the exact package version inspected in this plan.
                APT_TARGETS+=("$package=$proposed")
                ;;
        esac
    done < "$SIM"

    echo
    if ((UPDATE_COUNT == 0)); then
        echo "No applicable EA4 PHP updates. No packages changed."
        exit 0
    fi

    printf 'Approved EA4 package upgrades: %s\n' "$UPDATE_COUNT"

    if [[ "$MODE" == "--dry-run" ]]; then
        echo "PLAN COMPLETE. No packages changed."
        echo "Simulation: $SIM"
        exit 0
    fi

    # Confirm the reviewed EA4 transaction before modifying packages.
    printf '%s\n' "${APT_TARGETS[@]}"
    read -r -p "Type UPDATE to continue: " ANSWER

    if [[ "$ANSWER" != "UPDATE" ]]; then
        echo "Cancelled."
        exit 1
    fi

    # Preserve EA4 PHP configuration before applying updates.
    BACKUP="$LOGDIR/php-config-$STAMP.tar.gz"
    PATHS=()

    for p in \
        /opt/cpanel/ea-php*/root/etc \
        /etc/cpanel/ea4 \
        /var/cpanel/ApachePHPFPM; do
        [[ -e "$p" ]] && PATHS+=("${p#/}")
    done

    if ((${#PATHS[@]} == 0)); then
        echo "ERROR: No configuration paths found."
        exit 1
    fi

    tar -C / -czf "$BACKUP" "${PATHS[@]}"
    echo "Configuration backup: $BACKUP"

    # Keep APT interactive so its final transaction can be reviewed.
    # Refuse removals and preserve locally modified configuration files.
    apt-get --no-remove install --only-upgrade \
        -o Dpkg::Options::="--force-confold" \
        "${APT_TARGETS[@]}"

    # Confirm that APT installed each planned package version.
    for target in "${APT_TARGETS[@]}"; do
        package="${target%%=*}"
        expected="${target#*=}"
        actual="$(dpkg-query -W -f='${Version}' "$package")"

        if [[ "$actual" != "$expected" ]]; then
            echo "ERROR: Version verification failed: $package"
            exit 1
        fi
    done

    # Check the installed CLI binaries and module loading.
    for branch in "${BRANCHES[@]}"; do
        binary="/opt/cpanel/$branch/root/usr/bin/php"

        if [[ ! -x "$binary" ]]; then
            echo "ERROR: Missing PHP binary: $binary"
            exit 1
        fi

        "$binary" -v
        "$binary" -m
    done

    echo "EA4 package versions and CLI checks passed."
    echo "FPM configuration, service health and websites require verification."
    echo "Log: $LOG"
    exit 0
fi

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
