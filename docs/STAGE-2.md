# Stage 2: Package-managed PHP updates

## Architecture

Standalone Bash handlers grouped by PHP management mechanism:

- ubuntu_php_update.sh: conventional Ubuntu/Debian APT PHP packages,
  including Hestia installations.
- cyberpanel_php_update.sh: CyberPanel LSPHP packages.
- cpanel_php_update.sh: cPanel EasyApache PHP through APT or DNF.
- dnf_php_update.sh: conventional Rocky/AlmaLinux DNF PHP packages.

Original live-used scripts remain preserved under backend/reference/.

## Validation completed — 2026-10-26

| Environment | Evidence |
|---|---|
| Debian 13, conventional APT | Actual PHP 8.4.24 to 8.4.27 upgrade; 10 packages; backup created; recorded configuration hashes and module lists matched; FPM configuration valid and service active; repeat plan found no updates |
| Ubuntu 24, cPanel APT | Actual PHP 8.3.35 to 8.3.36 upgrade; 21 packages; backup created; recorded configuration hashes and module lists matched; PHP 8.2 package versions unchanged; repeat plan found no updates; Apache active |
| AlmaLinux 10, cPanel DNF | Actual PHP 8.3.35 to 8.3.36 upgrade; 21 packages; backup created; recorded configuration hashes and module lists matched; full package inventory comparison showed only expected changes; repeat plan found no updates; Apache active |
| Rocky 10, conventional DNF | Actual PHP 8.3.33 to 8.3.36 upgrade; seven packages; target RPM versions verified; configuration matched backup; module lists matched; FPM configuration, restart and active checks passed; repeat apply returned successfully without changes |
| Ubuntu 26, Hestia | No-update planning passed; PHP 8.4 FPM configuration returned zero and service was active; actual upgrade pending because checked repositories and cache contained only current packages |
| Ubuntu 22, CyberPanel | No-update planning passed; PHP 8.3 CLI and LSAPI extension probes passed; web service active; actual upgrade pending because checked repositories and cache contained only current packages |

## Findings

- Both cPanel labs had no configured FPM pools before upgrade testing.
  Package/CLI checks passed; FPM application serving was not tested.
- CyberPanel PHP 8.1 previously reported a missing timezonedb extension.
  Passing PHP 8.3 checks does not resolve or validate that branch.
- The LSAPI executable printed usage for -m while returning zero.
  Verification must inspect meaningful output or execute a PHP probe.
- Rocky's missing tar dependency correctly blocked execution at preflight.
  Installing tar allowed the upgrade test to proceed.

## Remaining work

- Complete automatic transaction scope and upgrade-boundary safeguards.
  DNF apply currently requires interactive transaction review.
- Improve reporting of pre-existing service failures and unconfigured FPM.
- Correct outdated planning messages in the conventional DNF handler.
- Test application requests through the configured web/PHP runtime.
- Exercise further failure cases and verify exit statuses.
- Exercise actual Hestia and CyberPanel upgrades when suitable versions exist.

These results establish the tested cases above, not universal production
compatibility or a numerical success probability.
