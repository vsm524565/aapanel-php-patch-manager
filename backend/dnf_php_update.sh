#!/usr/bin/env bash
# Inspect conventional PHP package updates on Rocky Linux and AlmaLinux.
# This stage supports planning only.

set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

# Stop with a clear error.
fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Accept planning arguments without changing packages.
# Select planning or interactive apply mode.
parse_arguments() {
    (($# <= 1)) || fail "Accepts one argument."
    MODE="plan"

    case "${1:---plan}" in
        --plan|--dry-run) ;;
        --apply) MODE="apply" ;;
        -h|--help)
            printf 'Usage: %s [--plan|--dry-run|--apply]\n' "$0"
            exit 0
            ;;
        *) fail "Unsupported argument: $1" ;;
    esac
}

# Verify the OS and reject installations needing a panel-specific handler.
preflight() {
    ((EUID == 0)) || fail "Run as root."

    source /etc/os-release

    case "${ID:-}" in
        rocky|almalinux) ;;
        *) fail "Rocky Linux or AlmaLinux required." ;;
    esac

    local path cmd
    for path in \
        /www/server/panel \
        /usr/local/cpanel \
        /usr/local/CyberCP \
        /usr/local/lsws \
        /usr/local/psa \
        /usr/local/directadmin; do
        [[ ! -e "$path" ]] ||
            fail "Use the dedicated handler for installation: $path"
    done

    for cmd in dnf rpm awk sort tee mktemp tar systemctl; do
        command -v "$cmd" >/dev/null ||
            fail "Missing command: $cmd"
    done
}

# Keep each planning run in a separate directory.
start_logging() {
    local log_root="/var/log/dnf-php-updates"

    install -d -m 700 "$log_root"
    RUN_DIR="$(mktemp -d "$log_root/run-XXXXXXXX")"
    exec > >(tee -a "$RUN_DIR/output.log") 2>&1

    printf '=== CONVENTIONAL DNF PHP UPDATER ===\n'
    printf 'Host: %s\n' "$(hostname)"
    printf 'OS: %s\n' "$PRETTY_NAME"
    printf 'Mode: %s\n' "$MODE"
    printf 'Results: %s\n' "$RUN_DIR"
}

# Discover conventional PHP RPMs while retaining their architecture.
discover_packages() {
    local records
    records="$(rpm -qa --qf '%{NAME}\t%{ARCH}\t%{VERSION}-%{RELEASE}\n')" ||
        fail "Cannot read the RPM package database."

    printf '%s\n' "$records" |
        awk -F '\t' '$1 == "php" || $1 ~ /^php-/ {
            print $1 "\t" $2 "\t" $3
        }' |
        sort -u > "$RUN_DIR/installed.tsv"

    mapfile -t PACKAGES < <(
        awk -F '\t' '{print $1 "." $2}' "$RUN_DIR/installed.tsv"
    )

    ((${#PACKAGES[@]} > 0)) ||
        fail "No conventional PHP packages found."

    printf '\n=== INSTALLED PHP PACKAGES ===\n'
    cat "$RUN_DIR/installed.tsv"

    printf '\n=== INSTALLED PHP VERSION ===\n'
    if [[ -x /usr/bin/php ]]; then
        /usr/bin/php -v
    else
        printf 'PHP CLI executable is not installed.\n'
    fi
}

# Resolve an upgrade transaction without accepting it.
plan_updates() {
    printf '\n=== REFRESH DNF METADATA ===\n'
    dnf makecache --refresh ||
        fail "DNF metadata refresh failed."

    printf '\n=== SIMULATE PHP UPDATES ===\n'
    local simulation="$RUN_DIR/simulation.log"
    local result=0

    dnf --setopt=obsoletes=0 upgrade --assumeno \
        "${PACKAGES[@]}" > "$simulation" 2>&1 || result=$?

    cat "$simulation"

    # A declined transaction can return nonzero.
    # Only recognize explicit no-change or declined-transaction results.
    if ((result == 0)) &&
        grep -q '^Nothing to do\.' "$simulation"; then
        printf '\nNo applicable PHP updates.\n'
    elif grep -q '^Operation aborted\.' "$simulation" &&
        grep -q '^Transaction Summary' "$simulation"; then
        printf '\nUpdates proposed; transaction was declined.\n'
        printf 'Dependency scope and PHP branch checks remain to be implemented.\n'
    else
        fail "Unrecognized or failed DNF simulation; inspect $simulation"
    fi

    printf 'PLAN COMPLETE. No packages changed.\n'
    printf 'Results: %s\n' "$RUN_DIR"
}
# Apply exact same-branch candidates after reviewing DNF's transaction.
apply_updates() {
    local name arch version release epoch installed_version
    local installed_branch candidate_branch answer
    local -a targets=()
    local -a backup_paths=()

    # Query upgrade candidates for the installed PHP package set.
    dnf -q repoquery --upgrades \
        --qf '%{name}|%{arch}|%{version}|%{release}|%{epoch}' \
        "${PACKAGES[@]}" > "$RUN_DIR/candidates.txt" ||
        fail "Cannot query DNF upgrade candidates."

    while IFS='|' read -r name arch version release epoch; do
        [[ -n "$name" ]] || continue

        [[ "$name" == "php" || "$name" == php-* ]] ||
            fail "Unexpected candidate record: $name"

        installed_version="$(
            rpm -q --qf '%{VERSION}' "$name.$arch"
        )" || fail "Candidate is not an installed package: $name.$arch"

        # This conventional handler accepts X.Y.Z package versions.
        # Independently versioned extensions require separate handling.
        [[ "$installed_version" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]] ||
            fail "Unsupported installed version: $name $installed_version"
        installed_branch="${BASH_REMATCH[1]}"

        [[ "$version" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]] ||
            fail "Unsupported candidate version: $name $version"
        candidate_branch="${BASH_REMATCH[1]}"

        [[ "$installed_branch" == "$candidate_branch" ]] ||
            fail "PHP branch change refused: $name $installed_version -> $version"

        [[ "$epoch" =~ ^[0-9]+$ ]] ||
            fail "Unexpected RPM epoch: $name $epoch"

        targets+=("$name-$epoch:$version-$release.$arch")
    done < "$RUN_DIR/candidates.txt"

    if ((${#targets[@]} == 0)); then
        printf 'No applicable PHP updates. No packages changed.\n'
        return 0
    fi

    printf '\n=== EXACT UPGRADE TARGETS ===\n'
    printf '%s\n' "${targets[@]}" |
        tee "$RUN_DIR/targets.txt"

    # Establish runtime health before modifying packages.
    /usr/bin/php -v
    /usr/bin/php -m > "$RUN_DIR/modules-before.txt"
    /usr/sbin/php-fpm -t ||
        fail "FPM configuration is invalid before update."
    systemctl is-active --quiet php-fpm ||
        fail "PHP-FPM is not active before update."

    printf '\nReview DNF transactions for PHP-only upgrades.\n'
    printf 'Decline transactions containing unrelated changes.\n'
    read -r -p "Type UPDATE to continue: " answer
    [[ "$answer" == "UPDATE" ]] || fail "Cancelled."

    for name in /etc/php.ini /etc/php.d /etc/php-fpm.conf /etc/php-fpm.d; do
        [[ -e "$name" ]] && backup_paths+=("${name#/}")
    done

    ((${#backup_paths[@]} > 0)) ||
        fail "No PHP configuration paths found."

    tar -C / -czf "$RUN_DIR/php-config.tar.gz" \
        "${backup_paths[@]}"
    printf 'Configuration backup: %s/php-config.tar.gz\n' "$RUN_DIR"

    # Keep DNF interactive for final dependency transaction review.
    # Exact targets preserve the candidate versions inspected above.
    dnf --setopt=obsoletes=0 upgrade "${targets[@]}" ||
        fail "DNF upgrade did not complete."

    # Verify exact RPM versions after the transaction.
    while IFS='|' read -r name arch version release epoch; do
        [[ -n "$name" ]] || continue

        installed_version="$(
            rpm -q --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' "$name.$arch"
        )" || fail "Package missing after update: $name.$arch"

        [[ "$installed_version" == "$epoch:$version-$release" ]] ||
            fail "Installed version differs from target: $name.$arch"
    done < "$RUN_DIR/candidates.txt"

    /usr/bin/php -v
    /usr/bin/php -m > "$RUN_DIR/modules-after.txt"
    /usr/sbin/php-fpm -t ||
        fail "FPM configuration failed after update."

    # Restart the previously active FPM service to load updated code.
    systemctl restart php-fpm ||
        fail "PHP-FPM restart failed."
    systemctl is-active --quiet php-fpm ||
        fail "PHP-FPM is not active after restart."

    diff -u "$RUN_DIR/modules-before.txt" "$RUN_DIR/modules-after.txt" ||
        fail "Loaded module list changed; inspect the results."

    printf 'PASS: Target RPM versions, module list and FPM checks.\n'
    printf 'Application requests still require verification.\n'
    printf 'Results: %s\n' "$RUN_DIR"
}
# Run discovery, planning and the requested apply step.
main() {
    parse_arguments "$@"
    preflight
    start_logging
    discover_packages
    plan_updates

    if [[ "$MODE" == "apply" ]]; then
        apply_updates
    fi
}

main "$@"
