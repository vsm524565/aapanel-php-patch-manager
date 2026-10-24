# aaPanel PHP Patch Manager

Temporary operations project: run locally on Ubuntu, discover and eventually patch remote aaPanel Ubuntu hosts over SSH. Python orchestrates a Bash backend. Standard library only; Python 3.10+ and OpenSSH required locally, Python 3 and Bash required remotely.

## Current milestone: read-only inventory

Implemented: explicit single-host selection, strict SSH host-key validation, key/agent authentication, noninteractive sudo, bounded remote commands, JSON evidence, private report permissions and local tests. The collector runs no installer and writes no remote project files. Normal SSH/sudo activity can generate system logs.

Not implemented yet: patch selection, resolved website mappings, backups, updates, service restarts, HTTP runtime probes, rollback or production rollout. Do not treat the inventory as proof that a server is patched. No fixed-version security policy is embedded yet; validate vendor releases and backports before implementing it.

## Local setup

Extract this directory into ~/projects, then:

```bash
cd ~/projects/aapanel-php-patch-manager
python3 -m venv .venv
source .venv/bin/activate
cp inventory.example.json inventory.local.json
chmod 600 inventory.local.json
python3 -m unittest discover -s tests -v
```

No pip dependencies are needed. If venv support is missing, install Ubuntu's python3-venv package first. Keep passwords and private keys out of this project.

## Verify SSH before discovery

```bash
ssh -i ~/.ssh/devops_lab_ed25519 -p 2202 dssa-test@192.168.56.110
```

Verify any new host fingerprint against the VM console before accepting it. If reinstalling the VM changes its key, verify the replacement at the console before updating known_hosts. The application never disables host-key checks.

On the VM, verify the existing sudo policy:

```bash
sudo -n true
```

Inventory requires root read access. The non-root automation user needs an existing passwordless sudo policy permitting `sudo -n bash -s`; `sudo -n true` is only an initial check, not proof of that permission. Do not grant unrestricted production sudo merely to satisfy this scaffold. If sudo is password protected or policy blocks the collector, stop and choose the production authentication/privilege approach explicitly. Root SSH is also supported by setting user to root; authentication is key/agent only in this milestone.

Run from your laptop:

```bash
python3 patch_manager.py inventory --server dssaubuntu24
```

The example uses the last recorded VM endpoint 192.168.56.110:2202. Confirm the VM still uses it. A bare VM should report no aaPanel and no PHP; this is valid baseline discovery. After installing aaPanel and the test stack, repeat discovery and compare reports.

Exit codes: 0 = discovery finished without recorded collection errors; 1 = configuration/SSH/transport/report failure; 2 = report saved with incomplete discovery. Zero does not mean security compliance or website health. Inspect the JSON limitations. Reports include topology, process arguments and handler configuration lines: review before sharing. Reports and the local inventory are excluded from Git.

## Test sequence

1. Local unit tests (no SSH or remote changes).
2. Bare dssaubuntu24 discovery: confirm OS, privileges and absence of panel.
3. Install aaPanel manually on the VM; match production webserver/PHP branches.
4. Configure a disposable PHP/database website and snapshot the VM.
5. Repeat inventory, including multiple PHP branches and an unused branch.
6. Confirm wrong host key, unreachable SSH and denied sudo stop cleanly.
7. Build vendor-specific update path from the discovered installation method.
8. Test same-branch update, extension/config preservation, worker replacement and HTTP runtime checks.
9. Test failed update/health check and recovery on the VM.
10. Roll out to one explicitly selected production server, verify, then continue serially.

Never install an untrusted vulnerable build just to exercise an upgrade. An already current server must eventually produce a no-op update plan. Production work requires an available recovery backup and a reviewed target plan. The updater must stop on failed verification; configuration copies alone cannot roll back PHP binaries or extension ABI changes.

## Planned structure

- patch_manager.py: local SSH orchestration and report storage
- backend/discover.sh: remote read-only evidence collector
- inventory.example.json: test target template
- tests/test_manager.py: validation, SSH failure and report privacy checks
- reports/: ignored local evidence

Keep this project separate from DSSA. When initializing Git use user.name vsm524565 and user.email vsm524565@gmail.com. No repository has been created or pushed by this scaffold.
