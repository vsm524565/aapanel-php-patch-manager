# PHP Patch Manager Architecture

## Execution model

An administrator runs the Python launcher on the target server.

Python selects by component and panel.
Bash owns OS validation, package-manager selection and patch maintenance.

## Python launcher responsibilities

local_patch_manager.py:

- Parse component and plan/apply mode.
- Require root privileges and Bash.
- Detect panel installation markers.
- Reject conflicting panel markers or unsupported detected panels.
- Select an explicitly registered backend group.
- Retrieve backends from a pinned Git commit over HTTPS.
- Verify downloaded bytes against configured SHA-256 checksums.
- Run Bash with inherited terminal streams.
- Preserve backend exit status.
- Clean up temporary backend files.

The launcher does not manage SSH connections or fleet inventory.

## Bash backend responsibilities

- Validate supported environments and required commands.
- Discover installed PHP packages or panel-managed installations.
- Obtain package or catalogue candidates.
- Display plans and retain existing confirmations.
- Back up configuration before applicable update operations.
- Perform backend-specific updates and verification.
- Retain logs, backups and task records.

Validation depth differs by backend. See stage documentation.

## Routing

| Panel | Backend group |
|---|---|
| aaPanel | aaPanel |
| CyberPanel | CyberPanel |
| cPanel | cPanel |
| Hestia | Conventional |
| No detected panel | Conventional |

Conventional routing downloads the APT and DNF handlers.
A Bash dispatcher selects the handler using available package-manager commands.

The cPanel backend selects APT or DNF internally.

Detecting a package manager does not establish OS compatibility.
The selected backend must accept the environment.

## Backend interface

Common launcher operations:
- --plan
- --apply

For aaPanel, the launcher also supplies --all.

Backend-specific status/watch operations are not currently exposed
through the launcher.

Interactive confirmation and DNF transaction review remain in the backends.

## Backend distribution

Backend revision:
4939dc3958a6790124037bd2658545e45f18f069

Expected SHA-256 hashes are stored in the launcher.
A backend change requires updating the pinned revision and checksums.

Temporary directories are private and backend files are downloaded before
execution. Failed downloads or checksum mismatches prevent execution.

Checksums verify consistency with the trusted launcher. They do not
independently authenticate a compromised launcher.

## Lifecycle

1. Detect and select.
2. Download and verify.
3. Execute the selected backend.
4. Return its result.
5. Remove temporary backend files.

Persistent maintenance records are retained.
aaPanel queued tasks continue independently after successful submission.

Forced termination or power loss can leave temporary files.
Subprocess logging through tee can make final output appear out of order.

## Extension model

A future component adds:
- Its Bash backend.
- Component/panel routing entries.
- Required argument translation.
- Distribution checksums and validation documentation.

PHP is the only implemented component in this release scope.

## Retained earlier tooling

patch_manager.py and backend/discover.sh implement the earlier SSH-based
discovery workflow. They remain separate from the server-local launcher.

## Validation boundary

The recorded evidence distinguishes:
- Planning integration.
- Already-current apply integration.
- Actual backend package upgrades.
- Configuration, module and available service checks.

Deferred checks and known limitations are documented in STAGE-1.md,
STAGE-2.md and STAGE-3.md. Application deployment is outside scope.