# PHP Patch Manager

Server-local PHP patch maintenance using a Python launcher and Bash backends.

Python checks root access, detects the control panel, retrieves verified
backend scripts and executes them. Bash handles environment validation,
package-manager selection, PHP discovery and patch operations.

## Scope

Maintain existing PHP installations within the supported environments.
This project does not deploy applications or perform PHP branch migrations.

| Validated environment | Backend |
|---|---|
| Ubuntu + aaPanel | aapanel_php_update.sh |
| Ubuntu 22 + CyberPanel | cyberpanel_php_update.sh |
| Ubuntu 26 + Hestia | ubuntu_php_update.sh |
| Debian 13 conventional PHP | ubuntu_php_update.sh |
| Ubuntu 24 + cPanel | cpanel_php_update.sh — APT |
| AlmaLinux 10 + cPanel | cpanel_php_update.sh — DNF |
| Rocky 10 conventional PHP | dnf_php_update.sh |

This table records tested environments, not universal compatibility.

## Requirements

- Root access on the target server.
- Python 3 and Bash.
- CA certificates and outbound HTTPS access to GitHub.
- curl for the download command below.
- Correct system time.
- Backend-specific commands and configured package repositories.
- For aaPanel: its existing panel Python environment and App Store backend.

The launcher uses Python's standard library.

## Download and run

Version 1.0.0:

```bash
curl -fL https://raw.githubusercontent.com/vsm524565/aapanel-php-patch-manager/v1.0.0/local_patch_manager.py -o patch-manager.py
```

Plan:

```bash
sudo python3 patch-manager.py --plan
```

Apply:

```bash
sudo python3 patch-manager.py --apply
```

PHP is the default component. It can also be selected explicitly:

```bash
sudo python3 patch-manager.py --component php --plan
```

Apply retains the backend's confirmation prompts. DNF transactions require
interactive review. This version is intended for supervised operation.

Planning can refresh repository metadata or aaPanel catalogue caches.

## Execution

1. Check root privileges.
2. Detect panel markers and reject conflicting or unsupported panels.
3. Select the PHP backend group.
4. Download backends from a pinned Git commit.
5. Verify their SHA-256 checksums.
6. Execute Bash with inherited terminal input and output.
7. Remove temporary backend downloads and return the backend exit status.

Python does not choose the package manager from OS information.

For conventional PHP, a Bash dispatcher selects APT or DNF.
The cPanel backend selects its own APT or DNF route.
Every backend retains its own supported-environment checks.

aaPanel requests are translated to --plan --all or --apply --all.
A queued aaPanel update is not proof of completed installation.

## Downloads and retained data

The downloaded Python launcher remains available for reuse.

Bash backends are downloaded into a private temporary directory and removed
after execution, including ordinary errors and terminal interruption.
Forced termination or power loss can leave temporary files.

Backend-generated logs, configuration backups and task records remain.
Configuration backups do not provide complete package or server rollback.

Backends are pinned to commit:
4939dc3958a6790124037bd2658545e45f18f069

The development launcher URL can change; backend versions remain pinned
until the launcher's revision and checksums are deliberately updated.

## Validation

- Launcher planning passed on all seven environments listed above.
- Launcher already-current apply passed on Debian APT and Rocky DNF.
- Actual backend upgrades passed on Debian APT, Ubuntu cPanel APT,
  AlmaLinux cPanel DNF and Rocky conventional DNF.
- aaPanel backend updates were exercised on existing live servers.
- Repository refresh failure propagated through the launcher as exit 100.

Detailed evidence and limitations:
- docs/STAGE-1.md
- docs/STAGE-2.md
- docs/STAGE-3.md

## Limitations

- Actual upgrades on the Hestia and CyberPanel test environments remain
  pending because the checked repositories/cache contained only current versions.
- cPanel labs had no configured FPM pools; FPM application serving was not tested.
- CyberPanel had an existing missing PHP 7.4 executable and a PHP 8.1
  timezonedb warning.
- aaPanel's PHP 8.1 LSPHP/catalogue mismatch remains unresolved.
- aaPanel's catalogue client emits an unverified HTTPS warning.
- Automatic dependency-scope rejection is incomplete in DNF routes;
  operators must review the final transaction.
- Application deployment and application-request testing are outside
  the agreed validation scope.
- Existing backend checks do not cover every failure or repository layout.

A successful exit describes the selected backend operation. It does not
establish website health, complete security compliance or a numerical
production success probability.

## Exit status

The launcher returns the backend exit status.

- 0: backend completed its requested operation.
- 1: launcher failure, or a backend-defined failure.
- 130: launcher interrupted through Ctrl+C.

Other backend codes are preserved, including APT failures such as 100.
Consult backend output because codes can have different meanings by backend.

## Earlier SSH discovery tooling

The repository retains the earlier remote inventory workflow:

- patch_manager.py
- backend/discover.sh
- inventory.example.json
- tests/test_manager.py

It is separate from local_patch_manager.py and is not required for the
server-local patch workflow. Its tests cover the discovery tool, not the
new launcher or all maintenance backends.

Original live-used updater baselines are preserved in backend/reference/.