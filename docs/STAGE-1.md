# Stage 1 — aaPanel PHP Maintenance

## Architecture

Bash controls the maintenance workflow. Embedded Python calls aaPanel's
existing App Store catalogue and task backend.

aaPanel manages installation execution and its PHP/OpenLiteSpeed coordination.

This architecture is intended for reuse across aaPanel-supported operating
systems. The current implementation supports and is validated on Ubuntu only.
It requires dpkg for version comparison and explicitly rejects other OS IDs.

## Implemented

- Installed PHP and LSPHP executable discovery.
- App Store candidate lookup and binary version comparison.
- Single-branch and bulk update submission.
- Configuration backup before submission.
- Existing-task detection to prevent duplicate branch submissions.
- Bulk submission exits after queue acceptance.
- Task monitoring and post-task binary/module/FPM configuration checks.
- Non-waiting status checks with meaningful exit codes.

## Validation

- Ubuntu lab: discovery, current-version skip, branch selection and status.
- Missing task ID: rejected without submitting an update.
- Live PHP 7.4: update completion, binary version, module loading and FPM
  configuration verified.
- Live PHP 7.3: submission and monitoring exercised.
- Bulk submission exercised across the initial server inventory.
- Five servers subsequently confirmed as relevant aaPanel environments.

Queue acceptance and completed task records do not establish website health.

## Known limitations

- LSPHP repository candidates can differ from App Store PHP candidates.
- Some LSPHP binaries remained behind after panel tasks completed.
- CURRENT means discovered binaries match the catalogue, not security
  certification or website runtime verification.
- Configuration backups do not provide PHP binary/package rollback.
- Panel backend interfaces are internal and may change between releases.
- Catalogue calls may modify panel caches and metadata.
- aaPanel's internal requests emitted TLS verification warnings.
- General server OS/repository investigation is deferred.
- Debian and RPM-based OS support is not yet validated.
