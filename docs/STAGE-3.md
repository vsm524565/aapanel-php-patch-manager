# Stage 3: Server-local patch launcher

## Design

- Python checks root privileges and detects the panel.
- Python retrieves the selected backend group from pinned commit
  4939dc3958a6790124037bd2658545e45f18f069.
- Downloaded backends are checked against SHA-256 hashes.
- Bash owns OS validation, package-manager selection and PHP maintenance.
- Backend prompts and terminal output remain interactive.
- Temporary backends are removed after execution.
- Logs and backups remain on the server.

## Verified

Debian 13:
- No-panel detection and conventional APT routing passed.
- Backend retrieval and checksum verification passed.
- Repository verification failure propagated as exit status 100.
- Temporary backends were cleaned up after failure.
- After time synchronization was configured, planning passed with exit 0.
- Cleanup completed after successful execution.

## Requirements and limitations

- Python 3, CA certificates and backend dependencies are required.
- Correct system time is required for repository and TLS verification.
- Forced termination or power loss can leave temporary files.
- Conventional routing currently downloads both APT and DNF handlers.
- Existing backend limitations remain documented in STAGE-2.md.

## Resume next session

Run launcher planning checks on:
- Ubuntu 22 + CyberPanel
- Ubuntu 26 + Hestia
- Ubuntu 24 + cPanel
- AlmaLinux 10 + cPanel
- Rocky 10 conventional PHP

Verify aaPanel launcher routing separately.
No repeat downgrade/upgrade tests are planned.
## Launcher integration results — 2026-10-27

Planning completed with backend and launcher exit status 0 for:

| Environment | Selected route |
|---|---|
| Debian 13, no panel | Conventional → APT |
| Ubuntu 22, CyberPanel | CyberPanel |
| Ubuntu 26, Hestia | Conventional → APT |
| Ubuntu 24, cPanel | cPanel → APT |
| AlmaLinux 10, cPanel | cPanel → DNF |
| Rocky 10, no panel | Conventional → DNF |
| Ubuntu, aaPanel — existing live server | aaPanel → plan all branches |

Temporary backend cleanup was reported for every route.
No updates were applied during these launcher planning checks.
The previous resume checklist is now complete.

Existing limitations observed:
- CyberPanel: missing PHP 7.4 executable and PHP 8.1 timezonedb warning.
- aaPanel: PHP 8.1 catalogue/runtime mismatch for LSPHP remains unresolved.
- aaPanel's catalogue client emits an unverified HTTPS warning.
- Backend logging through tee can cause final messages to appear out of order.

These tests validate launcher planning integration.
Actual backend upgrade evidence remains recorded in STAGE-2.md.
