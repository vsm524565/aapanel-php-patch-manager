# aaPanel PHP Patch Manager

PHP inventory and security patch management for aaPanel servers, developed as an Adversity Solutions infrastructure project.

The application runs on a local Ubuntu machine and connects to remote servers over SSH. Python handles orchestration and reporting; Bash provides the remote discovery entry point.

## Current status

**Implemented and verified on the test VM:**

- Explicit single-server selection.
- SSH key authentication with strict host-key checking.
- A dedicated `as-automation` account.
- Restricted passwordless sudo for the discovery command.
- Root-owned remote discovery scripts.
- Detection of aaPanel presence and version.
- Discovery of PHP binaries, extensions and configuration paths.
- Collection of running webserver/PHP processes and handler references.
- Local JSON reports with file permissions `600`.
- Six passing local unit tests.
- Successful remote discovery and denial of arbitrary root Bash execution.

**Not implemented yet:**

- Automated account and collector bootstrap.
- Resolved website-to-PHP runtime mappings.
- Patch selection and update planning.
- Backup and recovery integration.
- PHP updates and worker restarts.
- HTTP runtime and application health verification.
- Production rollout.

Discovery does not establish that a server is patched or that its websites are healthy.

## Architecture

Local Python application → SSH → automation account → restricted sudo command → remote collector → JSON report.

| Component | Responsibility |
|---|---|
| `patch_manager.py` | Validate inventory, invoke SSH and save reports |
| `backend/discover.sh` | Collect remote PHP, panel and process evidence |
| `inventory.example.json` | Provide a sample target configuration |
| `inventory.local.json` | Store actual connection details; excluded from Git |
| `reports/` | Store local discovery reports; contents excluded from Git |
| `tests/test_manager.py` | Check inventory validation, SSH behaviour and report permissions |

The remote administrator installs two root-owned files:

- `/usr/local/lib/adversity/php-discover`: fixed entry point.
- `/usr/local/lib/adversity/php-discover.sh`: discovery collector.

The entry point rejects arguments, changes its working directory to `/`, and invokes the collector with a clean environment. The collector uses isolated Python execution.

The application invokes the installed collector. It does not stream executable code into a privileged remote shell.

## Requirements

### Local machine

- Python 3.10 or later.
- OpenSSH client.
- Access to the target server.
- A verified SSH host key.
- An SSH private key, loaded into an SSH agent if passphrase protected.

### Remote server

- Ubuntu with Bash and Python 3.
- SSH public-key authentication.
- The installed root-owned discovery entry point and collector.
- A sudo rule permitting the automation account to execute only the discovery entry point without arguments.

No third-party Python packages are required.

## Local setup

Clone the repository:

```bash
git clone git@github.com:vsm524565/aapanel-php-patch-manager.git
cd aapanel-php-patch-manager
```

Create and activate a virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

Create the local inventory:

```bash
cp inventory.example.json inventory.local.json
chmod 600 inventory.local.json
```

Edit `inventory.local.json` with the actual server address, SSH port, username and private-key path.

Example structure:

```json
{
  "servers": {
    "test-server": {
      "host": "192.0.2.10",
      "port": 2202,
      "user": "as-automation",
      "identity_file": "~/.ssh/example_ed25519",
      "environment": "test"
    }
  }
}
```

The address and key path above are placeholders. Supported environment labels are `test` and `production`; the label records context and does not itself enforce deployment restrictions.

## Remote access setup

An administrator must provision the automation account, install its SSH public key, and deploy the root-owned discovery files before inventory can run.

The automation account does not require membership in the `sudo` group.

Its discovery permission is:

```sudoers
as-automation ALL=(root) NOPASSWD: /usr/local/lib/adversity/php-discover ""
```

The trailing `""` restricts the command to execution without arguments.

Validate the rule with `visudo` before using it. The entry point, collector and their parent directories must not be writable by the automation account.

Automated provisioning is planned. The current repository is not a complete bootstrap installer.

## Verify SSH access

From the local machine, using actual connection details:

```bash
ssh -i ~/.ssh/example_ed25519 \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -p 2202 \
    as-automation@192.0.2.10 \
    'hostname; id'
```

Verify a new host fingerprint against the server console before trusting it. If a server is rebuilt, verify its replacement host key before updating `known_hosts`.

The application does not disable host-key validation.

## Run discovery

Select the target by its inventory name:

```bash
python3 patch_manager.py inventory --server test-server
```

For the existing local lab inventory:

```bash
python3 patch_manager.py inventory --server dssaubuntu24
```

The application executes:

```bash
sudo -n /usr/local/lib/adversity/php-discover
```

It does not request permission to run arbitrary Bash commands as root.

`sudo -n true` may be denied even when discovery is correctly authorized. Test the permitted discovery command to verify its specific sudo rule.

## Discovery report

Reports are written to `reports/` with timestamps and file permissions `600`.

They contain:

- Target name, address and environment.
- Remote hostname, operating system and effective user ID.
- aaPanel presence, version and version evidence source.
- Detected PHP binaries and versions.
- PHP configuration paths and loaded extensions.
- Running webserver and PHP processes.
- Handler configuration references.
- Disk and memory information.
- Collection errors and limitations.

Reports can contain infrastructure details, process arguments and configuration excerpts. Review them before sharing.

### Interpretation limits

- A configuration reference does not prove that a PHP branch is installed or active.
- A CLI binary version does not prove which version serves HTTP requests.
- Installed webservers may not be running or serving websites.
- An unknown aaPanel version is different from an absent panel.
- An empty error list indicates no recorded collection failures; it does not prove complete runtime coverage.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Discovery completed without recorded collection errors |
| `1` | Inventory, SSH, execution or report-processing failure |
| `2` | Report saved with collection errors |

Exit code `0` does not indicate security compliance.

## Validation

Run the existing local tests:

```bash
python3 -m unittest discover -s tests -v
```

Check the Bash entry script syntax:

```bash
bash -n backend/discover.sh
```

Local tests cover input validation, required SSH options, root/non-root command selection, SSH failure handling, incomplete report rejection and report permissions.

Remote smoke checks have confirmed that the permitted collector runs as root and an arbitrary root Bash command is denied.

Update and application health tests remain pending implementation.

## Planned update workflow

1. Discover installed runtimes and website handler mappings.
2. Generate and display a same-branch patch plan.
3. Confirm recovery readiness and require explicit `APPLY`.
4. Execute the reviewed plan on the test server.
5. Verify configuration, extensions, worker replacement and website behaviour.
6. Resolve failures before proceeding to production.
7. Update one production server at a time and record results.

Already current installations should produce a no-op plan. Failed update or health verification must stop further rollout.

PHP branches must not be migrated automatically. Vendor release and backport evidence must be verified before marking a runtime patched.

## Project workflow

Requirements → Architecture → Implementation → Testing → Break/fix → Documentation → GitHub → Portfolio.

Changes are implemented manually with focused review. Lightweight syntax and smoke checks support implementation; consolidated testing follows the completed functionality.

This project is separate from the Developer Server Setup Assistant and InfraGuard.