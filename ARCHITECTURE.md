# PHP Patch Manager

Purpose: inventory and patch PHP on Adversity Solutions' aaPanel servers.

Execution:
Local Python → SSH → as-automation → restricted sudo command → JSON report.

Discovery:
- Remote entry point: /usr/local/lib/adversity/php-discover
- Collector: /usr/local/lib/adversity/php-discover.sh
- Both files are root-owned and writable only by root.
- Automation cannot run arbitrary commands through passwordless sudo.
- The administrator installs or updates privileged scripts.
- Private SSH keys remain on the laptop.
- Local inventory and reports are excluded from Git.

Scope:
- Update within existing PHP branches.
- Identify the runtime used by websites before choosing an update method.
- Test on dssaubuntu24 before production.
- Update production servers serially.
- Stop rollout if update or verification fails.

Verification:
- Existing local unit tests.
- Test VM discovery and one representative update.
- Verify runtime version, worker replacement and website response.
- Record per-server results.

Discovery alone does not establish patch compliance.
