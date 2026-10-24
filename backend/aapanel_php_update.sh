#!/usr/bin/env bash

# Maintain existing Ubuntu + aaPanel PHP through its App Store backend.
# Bash controls the workflow.
# Embedded Python will bridge to aaPanel's catalogue and task queue.

set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077
ALL_BRANCHES=0
PANEL_ROOT="/www/server/panel"
PANEL_PYTHON="$PANEL_ROOT/pyenv/bin/python3"
MODE="plan"
SELECTED_BRANCH=""
WATCH_TASK_ID=""
WATCH_TIMEOUT=3600

# Stop execution with a clear explanation.
fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}


# Verify the supported environment and required commands.
preflight() {
    [[ "$EUID" -eq 0 ]] || fail "Run this script as root."
    [[ -r /etc/os-release ]] || fail "OS information unavailable."

    local os_id command_name

    os_id="$(sed -n 's/^ID=//p' /etc/os-release)"
    os_id="${os_id//\"/}"

    [[ "$os_id" == "ubuntu" ]] ||
        fail "This script currently supports Ubuntu + aaPanel."

    [[ -x "$PANEL_PYTHON" ]] ||
        fail "aaPanel Python interpreter not found."

    [[ -f "$PANEL_ROOT/class_v2/panel_plugin_v2.py" ]] ||
        fail "aaPanel App Store backend not found."

    for command_name in hostname sed timeout readlink dpkg flock tar mktemp; do
        command -v "$command_name" >/dev/null ||
            fail "Required command missing: $command_name"
    done

    printf 'Host: %s\n' "$(hostname)"
    printf 'Environment: Ubuntu + aaPanel\n'
    printf 'Stage: PHP update planning\n'
}


# Retrieve and display catalogue information without submitting updates.
# Plan first; submit only an eligible, explicitly confirmed branch.
main_single() (
    parse_arguments "$@"
    preflight
    acquire_lock

    local work_dir branch installed candidate task
    local blocked=0 installed_count=0
    local selected_action="" selected_candidate=""
    local answer task_id

    work_dir="$(mktemp -d)" ||
        fail "Cannot create temporary directory."

    trap 'rm -rf -- "$work_dir"' EXIT
    if [[ "$MODE" == "watch" ]]; then
        monitor_php_task "$WATCH_TASK_ID" "$SELECTED_BRANCH" "$work_dir"
        verify_php_branch "$SELECTED_BRANCH" "$work_dir" ""
        return 0
    fi
    printf 'Mode: %s\n' "$MODE"
    printf '\nRetrieving App Store catalogue; panel caches may change.\n'

    fetch_php_catalogue "$work_dir/catalogue.tsv" ||
        fail "Catalogue retrieval failed."

    while IFS=$'\t' read -r branch installed candidate task; do
        if [[ -n "$SELECTED_BRANCH" &&
              "$branch" != "$SELECTED_BRANCH" ]]; then
            continue
        fi

        if [[ "$installed" != "yes" ]]; then
            printf 'IGNORE PHP %s: not installed.\n' "$branch"
            continue
        fi

        installed_count=$((installed_count + 1))

        printf '\nPHP %s | Candidate: %s | Task: %s\n' \
            "$branch" "$candidate" "$task"

        inspect_php_branch "$branch" "$candidate" "$task"
        printf 'Action: %s\n' "$BRANCH_ACTION"

        if [[ "$BRANCH_ACTION" == "BLOCKED" ]]; then
            blocked=1
        fi

        if [[ "$branch" == "$SELECTED_BRANCH" ]]; then
            selected_action="$BRANCH_ACTION"
            selected_candidate="$candidate"

            printf '%s\n' "${BRANCH_BINARIES[@]}" \
                > "$work_dir/expected-binaries"
        fi
    done < "$work_dir/catalogue.tsv"

    ((installed_count > 0)) ||
        fail "No matching installed PHP branches reported by aaPanel."

    if [[ "$MODE" == "plan" ]]; then
        printf '\nPlan complete. No update tasks submitted.\n'
        ((blocked == 0)) || return 1
        return 0
    fi

    case "$selected_action" in
        SKIP)
            printf '\nSelected branch already matches the catalogue.\n'
            return 0
            ;;
        UPDATE)
            ;;
        *)
            fail "Selected branch is blocked. No task submitted."
            ;;
    esac

    printf '\nSubmit PHP %s update; catalogue candidate: %s\n' \
        "$SELECTED_BRANCH" "$selected_candidate"
    printf 'aaPanel may rebuild PHP and restart affected services.\n'

    read -r -p "Type UPDATE-$SELECTED_BRANCH to proceed: " answer ||
        fail "Confirmation input unavailable."

    [[ "$answer" == "UPDATE-$SELECTED_BRANCH" ]] ||
        fail "Cancelled."

    backup_php_configuration "$SELECTED_BRANCH"

    submit_php_update \
        "$SELECTED_BRANCH" "$work_dir/submitted-task" ||
        fail "Submission failed or uncertain. Inspect App Store before retrying."

    task_id="$(cat "$work_dir/submitted-task")"
    [[ "$task_id" =~ ^[0-9]+$ ]] ||
        fail "Invalid task ID; inspect App Store before retrying."

    printf '\nPHP %s submitted as task %s.\n' \
        "$SELECTED_BRANCH" "$task_id"
    printf 'aaPanel manages execution.\n'
    monitor_php_task "$task_id" "$SELECTED_BRANCH" "$work_dir"
    verify_php_branch \
        "$SELECTED_BRANCH" "$work_dir" "$work_dir/expected-binaries"
)



# Retrieve PHP catalogue entries through aaPanel's existing backend.
# Panel debug output stays on screen; structured records use a separate file.
fetch_php_catalogue() {
    local output_file="$1"

    "$PANEL_PYTHON" -B - "$output_file" <<'PY'

import os
import re
import sys
from pathlib import Path

output_file = Path(sys.argv[1])

os.chdir("/www/server/panel")
for directory in (
    "/www/server/panel",
    "/www/server/panel/class",
    "/www/server/panel/class_v2",
):
    sys.path.insert(0, directory)

from BTPanel import app
import public
import panel_plugin_v2

records = []

with app.test_request_context("/"):
    args = public.dict_obj()
    args.query = "php"
    args.type = "0"
    args.p = "1"
    args.limit = "100"

    result = panel_plugin_v2.panelPlugin().get_soft_list(args)

    if not isinstance(result, dict) or result.get("status") != 0:
        raise SystemExit("ERROR: aaPanel catalogue retrieval failed.")

    entries = result["message"]["list"]["data"]

    for entry in entries:
        name = entry.get("name", "")
        if not re.fullmatch(r"php-\d+\.\d+", name):
            continue

        branch = name.removeprefix("php-")
        candidates = [
            item.get("full_version", "")
            for item in entry.get("versions", [])
            if item.get("m_version") == branch
        ]

        if not candidates or any(
            not re.fullmatch(r"\d+\.\d+\.\d+", version)
            or not version.startswith(branch + ".")
            for version in candidates
        ):
            raise SystemExit(
                f"ERROR: Invalid or missing candidate for {name}."
            )

        candidate = max(
            candidates,
            key=lambda version: tuple(map(int, version.split("."))),
        )

        installed = "yes" if entry.get("setup") else "no"
        task = str(entry.get("task", ""))

        if not re.fullmatch(r"-?\d+", task):
            raise SystemExit(f"ERROR: Invalid task state for {name}.")

        records.append(
            f"{branch}\t{installed}\t{candidate}\t{task}"
        )

if not records:
    raise SystemExit("ERROR: No PHP catalogue entries returned.")

output_file.write_text("\n".join(records) + "\n")
PY
}
# Compare every discovered executable for one installed PHP branch.
# Set BRANCH_ACTION for the caller; never update or restart anything.
inspect_php_branch() {
    local branch="$1"
    local candidate="$2"
    local task="$3"
    local compact="${branch//./}"
    local binary resolved output version
    local found=0
    local -A seen=()

    BRANCH_ACTION="SKIP"
    BRANCH_BINARIES=()

    for binary in \
        "/www/server/php/$compact/bin/php" \
        "/usr/local/lsws/lsphp$compact/bin/php" \
        "/usr/local/lsws/lsphp$compact/bin/lsphp"; do

        [[ -e "$binary" || -L "$binary" ]] || continue
        found=1

        if ! resolved="$(readlink -f -- "$binary")" ||
            [[ ! -x "$resolved" ]]; then
            printf '  ERROR: Unusable executable: %s\n' "$binary"
            BRANCH_ACTION="BLOCKED"
            continue
        fi

        [[ -z "${seen[$resolved]:-}" ]] || continue
        seen["$resolved"]=1
        BRANCH_BINARIES+=("$resolved")

        if ! output="$(timeout 15 "$resolved" -n -v 2>&1)"; then
            printf '  ERROR: Version check failed: %s\n' "$resolved"
            BRANCH_ACTION="BLOCKED"
            continue
        fi

        version="$(
            sed -nE \
                's/^PHP ([0-9]+\.[0-9]+\.[0-9]+)([[:space:]].*)?$/\1/p' \
                <<< "$output"
        )"

        if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ||
              "$version" != "$branch".* ]]; then
            printf '  ERROR: Unexpected version %s: %s\n' \
                "$version" "$resolved"
            BRANCH_ACTION="BLOCKED"
            continue
        fi

        printf '  %-12s %s\n' "$version" "$resolved"

        if dpkg --compare-versions "$version" gt "$candidate"; then
            printf '  BLOCKED: Binary is newer than catalogue.\n'
            BRANCH_ACTION="BLOCKED"
        elif dpkg --compare-versions "$version" lt "$candidate"; then
            if [[ "$BRANCH_ACTION" != "BLOCKED" ]]; then
                BRANCH_ACTION="UPDATE"
            fi
        fi
    done

    if ((found == 0)); then
        printf '  BLOCKED: Panel reports installed; no executable found.\n'
        BRANCH_ACTION="BLOCKED"
    fi

    if [[ "$task" != "1" ]]; then
        printf '  BLOCKED: Existing or unrecognized task state: %s\n' "$task"
        BRANCH_ACTION="BLOCKED"
    fi
}
# Accept preview mode and optional branch selection.
# Apply will be enabled after backup and task submission are implemented.
# Default to preview; require an explicit branch for real updates.
parse_arguments() {
    local mode_seen=0

    while (($#)); do
        case "$1" in
            --plan|--apply)
                ((mode_seen == 0)) ||
                    fail "Specify only one mode."
                MODE="${1#--}"
                mode_seen=1
                shift
                ;;
            --watch)
                ((mode_seen == 0)) ||
                    fail "Specify only one mode."
                (($# >= 2)) || fail "--watch requires a task ID."
                MODE="watch"
                WATCH_TASK_ID="$2"
                mode_seen=1
                shift 2
                ;;
            --timeout)
                (($# >= 2)) || fail "--timeout requires seconds."
                WATCH_TIMEOUT="$2"
                shift 2
                ;;
            --all)
                ALL_BRANCHES=1
                shift
                ;;
            --branch)
                (($# >= 2)) || fail "--branch requires X.Y."
                SELECTED_BRANCH="$2"
                shift 2
                ;;
            -h|--help)
                printf 'Usage: %s [--plan|--apply|--watch ID] [--all|--branch X.Y] [--timeout SECONDS]\n' "$0"
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                ;;
        esac
    done

    [[ -z "$SELECTED_BRANCH" ||
       "$SELECTED_BRANCH" =~ ^[0-9]+\.[0-9]+$ ]] ||
        fail "Invalid PHP branch: $SELECTED_BRANCH"

    if ((ALL_BRANCHES)) && [[ -n "$SELECTED_BRANCH" ]]; then
        fail "Use either --all or --branch, not both."
    fi

    if [[ "$MODE" == "apply" &&
          -z "$SELECTED_BRANCH" && "$ALL_BRANCHES" == 0 ]]; then
        fail "--apply requires --all or --branch X.Y."
    fi

    if [[ "$MODE" == "watch" ]]; then
        [[ -n "$SELECTED_BRANCH" && "$ALL_BRANCHES" == 0 ]] ||
            fail "--watch requires one --branch."
    fi

    [[ "$WATCH_TIMEOUT" =~ ^[1-9][0-9]{0,6}$ ]] ||
        fail "Invalid monitoring timeout."

    if [[ "$MODE" == "watch" ]]; then
        [[ "$WATCH_TASK_ID" =~ ^[0-9]+$ ]] ||
            fail "Invalid task ID."
    fi
}


# Prevent overlapping runs of this maintenance script.
# aaPanel's own task queue remains independent.
acquire_lock() {
    exec 9>/run/aapanel-php-update.lock
    flock -n 9 ||
        fail "Another instance of this maintenance script is running."
}
# Preserve configuration before submitting an update.
# This backup does not provide PHP binary/package rollback.
backup_php_configuration() {
    local branch="$1"
    local compact="${branch//./}"
    local backup_dir="/var/backups/aapanel-php-updates"
    local backup_file path
    local -a paths=(
        "www/server/php/$compact/etc"
        "www/server/panel/vhost"
    )

    if [[ -d "/usr/local/lsws/lsphp$compact/etc" ]]; then
        paths+=("usr/local/lsws/lsphp$compact/etc")
    fi

    for path in "${paths[@]}"; do
        [[ -d "/$path" ]] ||
            fail "Expected configuration directory missing: /$path"
    done

    mkdir -p "$backup_dir" ||
        fail "Cannot create backup directory."
    chmod 700 "$backup_dir" ||
        fail "Cannot secure backup directory."

    backup_file="$(
        mktemp "$backup_dir/php-$compact-XXXXXXXX.tar.gz"
    )" || fail "Cannot create backup file."

    if ! tar -C / -czf "$backup_file" "${paths[@]}"; then
        rm -f -- "$backup_file"
        fail "Configuration backup failed."
    fi

    printf 'Configuration backup: %s\n' "$backup_file"
}


# Submit one branch through aaPanel's App Store backend.
# Recheck unfinished tasks immediately before submitting.
# Write the new task ID separately from panel debug output.
submit_php_update() {
    local branch="$1"
    local task_file="$2"

    "$PANEL_PYTHON" -B - "$branch" "$task_file" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

branch = sys.argv[1]
task_file = Path(sys.argv[2])

if not re.fullmatch(r"\d+\.\d+", branch):
    raise SystemExit("ERROR: Invalid PHP branch.")

os.chdir("/www/server/panel")
for directory in (
    "/www/server/panel",
    "/www/server/panel/class",
    "/www/server/panel/class_v2",
):
    sys.path.insert(0, directory)

from BTPanel import app
import public
import panel_plugin_v2


# Read task records without changing their state.
def read_tasks():
    rows = public.M("tasks").field("id,name,status").select()
    if not isinstance(rows, list) or any(
        not isinstance(row, dict) for row in rows
    ):
        raise RuntimeError("Cannot read panel task records.")
    return rows


# Match this branch independently of other queued PHP updates.
def matches_branch(task):
    return f"[php-{branch}]" in str(task.get("name", ""))


with app.test_request_context("/"):
    before = read_tasks()

    unfinished = [
        task for task in before
        if matches_branch(task) and str(task.get("status")) != "1"
    ]
    if unfinished:
        print(json.dumps(unfinished, indent=2))
        raise SystemExit(
            "ERROR: This branch already has an unfinished task."
        )

    old_ids = {str(task["id"]) for task in before}

    args = public.dict_obj()
    args.sName = f"php-{branch}"
    args.version = branch
    args.type = "0"
    args.upgrade = "1"

    response = panel_plugin_v2.panelPlugin().install_plugin(args)
    print("Panel response:", json.dumps(response, default=str))

    new_tasks = [
        task for task in read_tasks()
        if matches_branch(task) and str(task["id"]) not in old_ids
    ]

    if len(new_tasks) != 1:
        raise SystemExit(
            "ERROR: Cannot uniquely identify the submitted task. "
            "Inspect the App Store before retrying."
        )

    task_id = str(new_tasks[0]["id"])
    if not task_id.isdigit():
        raise SystemExit("ERROR: Invalid submitted task ID.")

    task_file.write_text(task_id + "\n")
    print("Submitted task:", json.dumps(new_tasks[0], default=str))
PY
}
# Read one exact task without changing its state.
read_php_task() {
    local task_id="$1"
    local branch="$2"
    local output_file="$3"

    "$PANEL_PYTHON" -B - "$task_id" "$branch" "$output_file" <<'PY'
import os
import sys
from pathlib import Path

task_id, branch, output_file = sys.argv[1:]

os.chdir("/www/server/panel")
for directory in (
    "/www/server/panel",
    "/www/server/panel/class",
    "/www/server/panel/class_v2",
):
    sys.path.insert(0, directory)

from BTPanel import app
import public

with app.test_request_context("/"):
    task = public.M("tasks").where(
        "id=?", (int(task_id),)
    ).field("id,name,status").find()

    if not isinstance(task, dict) or str(task.get("id")) != task_id:
        raise SystemExit("ERROR: Task not found; do not resubmit blindly.")

    if f"[php-{branch}]" not in str(task.get("name", "")):
        raise SystemExit("ERROR: Task does not match the selected PHP branch.")

    status = str(task.get("status", ""))
    if status not in ("0", "-1", "1"):
        raise SystemExit(f"ERROR: Unrecognized task state: {status!r}")

    Path(output_file).write_text(status + "\n")
PY
}


# Observe aaPanel's task; timeout never cancels or resubmits it.
monitor_php_task() {
    local task_id="$1"
    local branch="$2"
    local work_dir="$3"
    local state previous=""
    local deadline=$((SECONDS + WATCH_TIMEOUT))

    printf '\nMonitoring PHP %s task %s.\n' "$branch" "$task_id"
    printf 'Stopping this monitor does not cancel the aaPanel task.\n'

    while :; do
        read_php_task "$task_id" "$branch" "$work_dir/task-state" ||
            fail "Cannot read task. Inspect App Store before retrying."

        state="$(cat "$work_dir/task-state")"

        if [[ "$state" != "$previous" ]]; then
            printf 'Task %s status: %s\n' "$task_id" "$state"
            previous="$state"
        fi

        if [[ "$state" == "1" ]]; then
            printf 'Panel task finished. Binary verification is still required.\n'
            return 0
        fi

        if ((SECONDS >= deadline)); then
            printf 'Resume: sudo bash %s --branch %s --watch %s\n' \
                "$0" "$branch" "$task_id"
            fail "Monitoring timed out. The aaPanel task was not cancelled."
        fi

        sleep 10
    done
}
# Verify actual binaries after aaPanel finishes its task.
# This does not prove that website workers use the updated runtime.
verify_php_branch() {
    local branch="$1"
    local work_dir="$2"
    local expected_file="$3"
    local candidate="" task="" installed=""
    local item_branch item_installed item_candidate item_task
    local binary compact="${1//./}"
    local fpm="/www/server/php/${1//./}/sbin/php-fpm"

    fetch_php_catalogue "$work_dir/verify-catalogue.tsv" ||
        fail "Cannot retrieve catalogue for verification."

    while IFS=$'\t' read -r \
        item_branch item_installed item_candidate item_task; do

        [[ "$item_branch" == "$branch" ]] || continue

        installed="$item_installed"
        candidate="$item_candidate"
        task="$item_task"
        break
    done < "$work_dir/verify-catalogue.tsv"

    [[ "$installed" == "yes" && -n "$candidate" ]] ||
        fail "Selected PHP branch is missing from installed catalogue entries."

    printf '\nVerifying PHP %s against current catalogue %s.\n' \
        "$branch" "$candidate"

    inspect_php_branch "$branch" "$candidate" "$task"

    [[ "$BRANCH_ACTION" == "SKIP" ]] ||
        fail "Task finished, but binary versions or task state failed verification."

    # Ensure executables present before submission have not disappeared.
    if [[ -n "$expected_file" ]]; then
        while IFS= read -r binary; do
            [[ -x "$binary" ]] ||
                fail "Previously discovered executable missing: $binary"
        done < "$expected_file"
    fi

    for binary in "${BRANCH_BINARIES[@]}"; do
        printf 'Checking module loading: %s\n' "$binary"
        timeout 30 "$binary" -m >/dev/null ||
            fail "PHP module loading failed: $binary"
    done

    if [[ -x "$fpm" ]]; then
        timeout 30 "$fpm" -t ||
            fail "PHP-FPM configuration validation failed."
    fi

    printf '\nPASS: Binary versions, module loading and available FPM configuration verified.\n'
    printf 'Website runtime and service health still require verification.\n'
}
# Queue all eligible branches, then monitor each submitted task.
# Isolate branch failures so other results can still be reported.
apply_all_branches() (
    preflight
    acquire_lock

    local work_dir branch installed candidate task answer task_id
    local run_dir manifest summary branch_dir
    local failures=0 count=0
    local -a eligible=()

    work_dir="$(mktemp -d)" ||
        fail "Cannot create temporary directory."
    trap 'rm -rf -- "$work_dir"' EXIT

    fetch_php_catalogue "$work_dir/catalogue.tsv" ||
        fail "Catalogue retrieval failed."

    mkdir -p /var/log/aapanel-php-updates ||
        fail "Cannot create results directory."

    run_dir="$(
        mktemp -d /var/log/aapanel-php-updates/run-XXXXXXXX
    )" || fail "Cannot create run directory."

    manifest="$run_dir/tasks.tsv"
    summary="$run_dir/results.tsv"
    : > "$manifest"
    : > "$summary"

    printf 'Results directory: %s\n' "$run_dir"

    while IFS=$'\t' read -r branch installed candidate task; do
        [[ "$installed" == "yes" ]] || continue
        count=$((count + 1))

        printf '\nPHP %s | Candidate: %s | Task: %s\n' \
            "$branch" "$candidate" "$task"

        inspect_php_branch "$branch" "$candidate" "$task"
        printf 'Action: %s\n' "$BRANCH_ACTION"

        case "$BRANCH_ACTION" in
            UPDATE)
                eligible+=("$branch")
                branch_dir="$run_dir/$branch"
                mkdir -p "$branch_dir"
                printf '%s\n' "${BRANCH_BINARIES[@]}" \
                    > "$branch_dir/expected-binaries"
                ;;
            SKIP)
                printf '%s\tALREADY-CURRENT\n' "$branch" >> "$summary"
                ;;
            *)
                printf '%s\tBLOCKED-OR-EXISTING-TASK\n' \
                    "$branch" >> "$summary"
                failures=1
                ;;
        esac
    done < "$work_dir/catalogue.tsv"

    ((count > 0)) || fail "No installed branches found."

    if ((${#eligible[@]} == 0)); then
        printf '\nNo eligible updates to submit.\n'
        cat "$summary"
        return "$failures"
    fi

    printf '\nBranches to queue:\n'
    printf '  PHP %s\n' "${eligible[@]}"
    printf 'aaPanel controls execution and affected service actions.\n'

    read -r -p "Type UPDATE-ALL to queue these branches: " answer ||
        fail "Confirmation input unavailable."
    [[ "$answer" == "UPDATE-ALL" ]] || fail "Cancelled."

    # Submit all eligible branches before entering monitoring.
    for branch in "${eligible[@]}"; do
        branch_dir="$run_dir/$branch"

        if ! (backup_php_configuration "$branch"); then
            printf '%s\tBACKUP-FAILED\n' "$branch" >> "$summary"
            failures=1
            continue
        fi

        if ! (
            submit_php_update "$branch" "$branch_dir/task-id" ||
                exit 1
        ); then
            printf '%s\tSUBMISSION-FAILED-OR-UNCERTAIN\n' \
                "$branch" >> "$summary"
            printf 'Inspect PHP %s in App Store before retrying.\n' "$branch"
            failures=1
            continue
        fi

        task_id="$(cat "$branch_dir/task-id")"
        if [[ ! "$task_id" =~ ^[0-9]+$ ]]; then
            printf '%s\tSUBMISSION-UNCERTAIN\n' "$branch" >> "$summary"
            failures=1
            continue
        fi

        printf '%s\t%s\n' "$branch" "$task_id" >> "$manifest"
        printf 'Queued PHP %s as task %s.\n' "$branch" "$task_id"
    done

    printf '\nSubmitted task IDs saved in: %s\n' "$manifest"
    printf 'Disconnecting does not cancel aaPanel tasks.\n'

    printf '\nQueue submission complete. No monitoring performed.\n'
    printf 'aaPanel manages the submitted tasks independently.\n'

    printf '\nSubmitted branches and task IDs:\n'
    cat "$manifest"

    printf '\nBranches skipped or requiring attention:\n'
    cat "$summary"

    printf '\nTask manifest: %s\nResults: %s\n' "$manifest" "$summary"
    printf 'Submission confirms queue acceptance, not update success.\n'

    return "$failures"

    printf '\nBranch results:\n'
    cat "$summary"
    printf '\nTask manifest: %s\nResults: %s\n' "$manifest" "$summary"
)


# Preserve single-branch/watch modes and add explicit bulk application.
main() {
    parse_arguments "$@"

    if [[ "$MODE" == "apply" && "$ALL_BRANCHES" == 1 ]]; then
        apply_all_branches
    else
        main_single "$@"
    fi
}
main "$@"