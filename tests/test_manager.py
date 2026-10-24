import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import patch_manager as app

class ManagerTests(unittest.TestCase):
    def target(self):
        return {'host': '192.168.56.110', 'port': 2202, 'user': 'dssa-test', 'environment': 'test'}

    def test_host_key_and_noninteractive_sudo_required(self):
        cmd = app.ssh_command(self.target())
        self.assertIn('StrictHostKeyChecking=yes', cmd)
        self.assertIn('BatchMode=yes', cmd)
        self.assertEqual(cmd[-1], 'sudo -n /usr/local/lib/adversity/php-discover')

    def test_root_does_not_require_sudo(self):
        target = self.target()
        target['user'] = 'root'
        self.assertEqual(app.ssh_command(target)[-1], '/usr/local/lib/adversity/php-discover')

    def test_untrusted_inventory_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'inventory.json'
            for field, value in [('host', '-oProxyCommand=id'), ('user', 'root;id'), ('port', 0), ('port', True)]:
                target = self.target()
                target[field] = value
                path.write_text(json.dumps({'servers': {'test': target}}))
                with self.assertRaises(ValueError):
                    app.load_target(path, 'test')

    def test_incomplete_report_rejected(self):
        with self.assertRaises(ValueError):
            app.validate_report({'schema_version': 1})

    def test_ssh_failure_is_not_success(self):
        result = type('Result', (), {'returncode': 255, 'stderr': 'host key mismatch', 'stdout': ''})()
        with patch('patch_manager.subprocess.run', return_value=result):
            with self.assertRaisesRegex(RuntimeError, '255'):
                app.inventory(self.target(), 30)

    def test_report_permissions_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = app.save_report(directory, 'test', {'status': 'test'})
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

if __name__ == '__main__':
    unittest.main()
