#!/usr/bin/env python3
"""Run the appropriate PHP maintenance backend on the current server."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request


REPOSITORY = "vsm524565/aapanel-php-patch-manager"

# Filled locally from the committed, tested backend checkpoint.
BACKEND_REVISION = '4939dc3958a6790124037bd2658545e45f18f069'
BACKEND_SHA256 = {'aapanel_php_update.sh': 'bd67b2eb75eb960474481b12c241119f09c9fced1829db31e9d9b0a99e899013', 'cyberpanel_php_update.sh': 'c20507386d1aedcc95b41a2d74732ec099919bec585b4d973af84dc251504c2a', 'cpanel_php_update.sh': 'd93497254244c220663133b02553100164b559b202bd5d0d77c93fd22bdd3784', 'ubuntu_php_update.sh': '72eec51593c168f73e3b0f9350464d8e4b2db05ba6cedc0496ae746b7b0e2d2c', 'dnf_php_update.sh': '19f49b02958d83721de0a8f96c3d53a04c3d0226f3904601d7b143662042f4b0'}

PANEL_MARKERS = {
    "aapanel": Path("/www/server/panel"),
    "cyberpanel": Path("/usr/local/CyberCP"),
    "cpanel": Path("/usr/local/cpanel"),
    "hestia": Path("/usr/local/hestia"),
    "plesk": Path("/usr/local/psa"),
    "directadmin": Path("/usr/local/directadmin"),
}

BACKEND_GROUPS = {
    "aapanel": ("aapanel_php_update.sh",),
    "cyberpanel": ("cyberpanel_php_update.sh",),
    "cpanel": ("cpanel_php_update.sh",),
    "conventional": (
        "ubuntu_php_update.sh",
        "dnf_php_update.sh",
    ),
}


# Parse the requested component and execution mode.
def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Select and run a server-local patch backend."
    )
    parser.add_argument(
        "--component",
        choices=("php",),
        default="php",
    )
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--plan",
        action="store_const",
        const="plan",
        dest="mode",
    )
    modes.add_argument(
        "--apply",
        action="store_const",
        const="apply",
        dest="mode",
    )
    parser.set_defaults(mode="plan")
    return parser.parse_args()


# Require root and an available Bash interpreter.
def preflight():
    if os.geteuid() != 0:
        raise RuntimeError("Run this launcher as root.")

    bash = shutil.which("bash")
    if not bash:
        raise RuntimeError("Bash is not available.")

    if not BACKEND_REVISION or not BACKEND_SHA256:
        raise RuntimeError("Backend revision and checksums are not configured.")

    return bash


# Detect panels before choosing any conventional PHP route.
def detect_panel():
    detected = [
        name for name, marker in PANEL_MARKERS.items()
        if marker.exists()
    ]

    if len(detected) > 1:
        raise RuntimeError(
            "Conflicting panel markers: " + ", ".join(detected)
        )

    return detected[0] if detected else "none"


# Select a backend group using the component and panel.
def select_backend(component, panel):
    if component != "php":
        raise RuntimeError("Unsupported component.")

    if panel in ("aapanel", "cyberpanel", "cpanel"):
        return panel

    if panel in ("hestia", "none"):
        return "conventional"

    raise RuntimeError(f"Unsupported panel: {panel}")


# Retrieve only pinned backend files and verify their exact bytes.
def download_backend(filename, directory):
    expected = BACKEND_SHA256.get(filename)
    if not expected:
        raise RuntimeError(f"Missing checksum for {filename}")

    url = (
        f"https://raw.githubusercontent.com/{REPOSITORY}/"
        f"{BACKEND_REVISION}/backend/{filename}"
    )

    request = urllib.request.Request(
        url,
        headers={"User-Agent": "server-local-patch-manager"},
    )

    with urllib.request.urlopen(request, timeout=60) as response:
        if not response.geturl().startswith("https://"):
            raise RuntimeError("Non-HTTPS download refused.")

        data = response.read(2_000_001)

    if len(data) > 2_000_000:
        raise RuntimeError(f"Backend exceeds size limit: {filename}")

    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError(f"Checksum verification failed: {filename}")

    destination = directory / filename
    with destination.open("xb") as stream:
        stream.write(data)
    destination.chmod(0o600)

    return destination


# Let Bash select the conventional package-manager handler.
def build_command(bash, group, files, mode):
    if group == "conventional":
        dispatcher = """
set -eu
if command -v apt-get >/dev/null 2>&1; then
    exec "$1" "$2" "$4"
elif command -v dnf >/dev/null 2>&1; then
    exec "$1" "$3" "$4"
else
    printf 'ERROR: No supported package manager found.\\n' >&2
    exit 1
fi
"""
        return [
            bash, "-c", dispatcher, "php-backend-dispatch",
            bash,
            str(files["ubuntu_php_update.sh"]),
            str(files["dnf_php_update.sh"]),
            f"--{mode}",
        ]

    filename = BACKEND_GROUPS[group][0]
    command = [bash, str(files[filename]), f"--{mode}"]

    if group == "aapanel":
        command.append("--all")

    return command


# Execute with inherited terminal streams so backend prompts remain usable.
def run_backend(command):
    result = subprocess.run(command, check=False)
    if result.returncode < 0:
        return 128 + abs(result.returncode)
    return result.returncode


# Select, download, execute and clean up without removing persistent logs.
def main():
    args = parse_arguments()

    try:
        bash = preflight()
        panel = detect_panel()
        group = select_backend(args.component, panel)

        print(f"Component: {args.component}", flush=True)
        print(f"Panel: {panel}", flush=True)
        print(f"Backend group: {group}", flush=True)
        print(f"Mode: {args.mode}", flush=True)
        print(f"Backend revision: {BACKEND_REVISION}", flush=True)

        # TemporaryDirectory removes downloads on normal return,
        # exceptions and an ordinary terminal Ctrl+C.
        with tempfile.TemporaryDirectory(
            prefix="php-patch-backend-"
        ) as temporary:
            directory = Path(temporary)
            files = {}

            for filename in BACKEND_GROUPS[group]:
                print(f"Retrieving: {filename}", flush=True)
                files[filename] = download_backend(filename, directory)

            command = build_command(bash, group, files, args.mode)
            result = run_backend(command)

        print("Temporary backend files removed.", flush=True)
        print(f"Backend exit status: {result}", flush=True)
        return result

    except KeyboardInterrupt:
        print(
            "\nInterrupted; temporary files cleaned up. "
            "Inspect package-manager or aaPanel task state before retrying.",
            file=sys.stderr,
        )
        return 130
    except (RuntimeError, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
