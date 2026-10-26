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
