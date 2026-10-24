#!/usr/bin/env bash
# Read-only remote entry point. Python 3 is present on standard Ubuntu 24.04.
set -euo pipefail
command -v python3 >/dev/null || { echo 'python3 is required on target' >&2; exit 1; }
/usr/bin/python3 -I - <<'PY'
import datetime as dt
import glob
import json
import os
from pathlib import Path
import re
import socket
import subprocess

errors = []

def run(args):
    """Bound subprocess execution and retain discovery failures explicitly."""
    try:
        p = subprocess.run(args, text=True, capture_output=True, timeout=15)
        if p.returncode:
            errors.append({'command': args, 'exit_code': p.returncode, 'stderr': p.stderr[:1000]})
        return p.stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        errors.append({'command': args, 'error': str(exc)})
        return ''


def read(path):
    try:
        return Path(path).read_text(errors='replace').strip()
    except OSError as exc:
        errors.append({'path': str(path), 'error': str(exc)})
        return ''

php = []
seen = set()
patterns = ['/www/server/php/*/bin/php', '/usr/local/lsws/lsphp*/bin/php', '/usr/bin/php[0-9]*']
for pattern in patterns:
    for binary in sorted(glob.glob(pattern)):
        real = os.path.realpath(binary)
        if real in seen or not os.access(binary, os.X_OK):
            continue
        seen.add(real)
        version = run([binary, '-v'])
        match = re.search(r'^PHP (\d+\.\d+\.\d+)', version)
        php.append({'binary': binary, 'realpath': real,
                    'version': match.group(1) if match else None,
                    'version_output': version, 'ini': run([binary, '--ini']),
                    'extensions': run([binary, '-m']).splitlines(),
                    'source_hint': 'aapanel' if binary.startswith('/www/server/php/') else
                                   'lsphp' if '/lsphp' in binary else 'system',
                    'web_runtime_verified': False})

references = []
roots = ['/www/server/panel/vhost/nginx', '/www/server/panel/vhost/apache',
         '/www/server/panel/vhost/openlitespeed', '/usr/local/lsws/conf']
pattern = re.compile(r'enable-php|fastcgi_pass|SetHandler|ProxyPassMatch|lsphp|scriptHandler|extprocessor|^\s*(?:include|Include|IncludeOptional)\b')
for root in roots:
    if not Path(root).is_dir():
        continue
    def walk_error(exc):
        errors.append({'path': root, 'error': str(exc)})
    for parent, dirs, files in os.walk(root, onerror=walk_error, followlinks=False):
        for name in sorted(files):
            path = Path(parent) / name
            if path.suffix not in ('.conf', '.vhost'):
                continue
            try:
                if path.stat().st_size > 2_000_000:
                    errors.append({'path': str(path), 'error': 'Configuration too large; not inspected'})
                    continue
            except OSError as exc:
                errors.append({'path': str(path), 'error': str(exc)})
                continue
            for number, line in enumerate(read(path).splitlines(), 1):
                if not line.lstrip().startswith('#') and pattern.search(line):
                    references.append({'file': str(path), 'line': number, 'text': line[:2000]})

processes = []
for row in run(['ps', '-eo', 'pid=,ppid=,comm=,args=']).splitlines():
    parts = row.split(None, 3)
    if len(parts) < 4:
        continue
    pid, ppid, comm, args = parts
    if re.search(r'php|nginx|apache|httpd|lshttpd|litespeed', comm, re.I):
        try:
            exe = os.readlink('/proc/' + pid + '/exe')
        except OSError:
            exe = None  # Short-lived worker may have exited during discovery.
        processes.append({'pid': int(pid), 'ppid': int(ppid), 'comm': comm, 'args': args, 'exe': exe})

panel_root = Path('/www/server/panel')
panel = panel_root / 'data/version.pl'
panel_version = None
panel_version_source = None

if panel.is_file():
    panel_version = read(panel) or None
    if panel_version:
        panel_version_source = str(panel)

if panel_version is None:
    common = panel_root / 'class/common.py'
    if common.is_file():
        match = re.search(
            r'''^\s*g\.version\s*=\s*['"]([0-9]+(?:\.[0-9]+){2,3})['"]''',
            read(common),
            re.MULTILINE,
        )
        if match:
            panel_version = match.group(1)
            panel_version_source = str(common)

report = {'schema_version': 1, 'collected_at': dt.datetime.now(dt.timezone.utc).isoformat(),
          'hostname': socket.gethostname(), 'effective_uid': os.geteuid(),
          'os': read('/etc/os-release'),
          'aapanel_present': (panel_root / 'class/common.py').is_file(),
          'aapanel_version': panel_version,
          'aapanel_version_source': panel_version_source,
          'php': php, 'processes': processes, 'handler_references': references,
          'resources': {'disk': run(['df', '-h', '/']), 'memory': run(['free', '-h'])},
          'errors': errors,
          'limitations': ['Handler references are evidence, not a resolved site-to-runtime mapping.',
                         'CLI binaries do not prove the version serving HTTP requests.',
                         'No update, restart, configuration edit or vulnerability verdict performed.']}
if os.geteuid() != 0:
    errors.append({'error': 'Root privileges required for complete discovery'})
print(json.dumps(report))
PY
