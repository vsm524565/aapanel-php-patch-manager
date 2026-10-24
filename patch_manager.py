#!/usr/bin/env python3
"""Local SSH orchestrator. Milestone 1 deliberately supports inventory only."""
import argparse
import datetime as dt
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent


def load_target(path, name):
    """Validate a named SSH target; inventory never accepts shell commands."""
    data = json.loads(Path(path).read_text())
    target = data['servers'][name]
    host = target['host']
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*', host):
            raise ValueError('Invalid host')
    if not re.fullmatch(r'[a-z_][a-z0-9_-]*', target['user']):
        raise ValueError('Invalid SSH user')
    port = target['port']
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('Invalid SSH port')
    if target.get('environment') not in ('test', 'production'):
        raise ValueError('environment must be test or production')
    return target


def ssh_command(target):
    """Use OpenSSH keys/agent and require an already verified host key."""
    command = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
               '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15',
               '-o', 'ServerAliveCountMax=2', '-p', str(target['port'])]
    if target.get('identity_file'):
        command += ['-i', str(Path(target['identity_file']).expanduser()),
                    '-o', 'IdentitiesOnly=yes']
    command += [target['user'] + '@' + target['host'],
                '/usr/local/lib/adversity/php-discover' if target['user'] == 'root' else 'sudo -n /usr/local/lib/adversity/php-discover']
    return command


def validate_report(report):
    """Reject incomplete or unrelated SSH output rather than claiming success."""
    if not isinstance(report, dict) or report.get('schema_version') != 1:
        raise ValueError('Invalid discovery report schema')
    for field in ('hostname', 'os', 'php', 'processes', 'handler_references', 'errors'):
        if field not in report:
            raise ValueError('Incomplete discovery report: ' + field)
    return report


def inventory(target, timeout):
    """Invoke the installed root-owned collector over SSH without stdin."""
    result = subprocess.run(ssh_command(target), stdin=subprocess.DEVNULL,
                            text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'SSH/discovery exited {result.returncode}: {result.stderr.strip()}')
    return validate_report(json.loads(result.stdout))


def save_report(directory, name, report):
    """Write reports privately because topology and website names are sensitive."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    path = directory / f'{name}-{stamp}.json'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(report, stream, indent=2)
        stream.write('\n')
    return path


def main():
    """Run one explicitly selected host and return a nonzero status on failure."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['inventory'])
    parser.add_argument('--inventory', default=str(ROOT / 'inventory.local.json'))
    parser.add_argument('--server', required=True)
    parser.add_argument('--output', default=str(ROOT / 'reports'))
    parser.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args()
    try:
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', args.server):
            raise ValueError('Invalid server name')
        target = load_target(args.inventory, args.server)
        report = inventory(target, args.timeout)
        report['target'] = {'name': args.server, 'host': target['host'],
                            'port': target['port'], 'environment': target['environment']}
        path = save_report(args.output, args.server, report)
        print(f"Report: {path}\naaPanel: {report.get('aapanel_version')}\nPHP installations: {len(report['php'])}")
        if report['errors']:
            print('Discovery incomplete: inspect errors in report.', file=sys.stderr)
            return 2
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
