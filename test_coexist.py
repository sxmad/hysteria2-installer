#!/usr/bin/env python3
"""Port separation, HTTP-01 serialization and real certificate renewal fixtures."""
import fcntl
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent

class CoexistTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        cls.certs = Path(cls.fixture.name)
        for name, days, domain in [('old', 1, 'example.com'), ('new', 90, 'example.com'), ('wrong', 90, 'wrong.example.com')]:
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', str(days),
                            '-subj', f'/CN={domain}', '-addext', f'subjectAltName=DNS:{domain}',
                            '-out', str(cls.certs / f'{name}.crt'), '-keyout', str(cls.certs / f'{name}.key')],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / 'config'
        self.cache = self.root / 'home' / 'lego' / 'certificates'
        self.state = self.root / 'state'
        self.bin = self.root / 'bin'
        for path in [self.config, self.cache, self.state, self.bin, self.root / 'units']:
            path.mkdir(parents=True, exist_ok=True)
        self.lock = self.root / 'acme.lock'
        source = (ROOT / 'install.sh').read_text().replace('\nmain "$@"\n', '\n')
        for name, path in {'CONFIG_DIR': self.config, 'HYSTERIA_HOME_DIR': self.root / 'home',
                           'STATE_DIR': self.state, 'ACME_LOCK': self.lock,
                           'RENEW_SCRIPT': self.root / 'renew.sh'}.items():
            source = re.sub(rf'^readonly {name}=.*$', f'readonly {name}={shlex.quote(str(path))}', source, flags=re.M)
        source = source.replace('/etc/systemd/system', str(self.root / 'units'))
        self.functions = self.root / 'functions.sh'
        self.functions.write_text(source)
        # No root/group or host changes: owner arguments are stripped only in tests.
        real_install = shutil.which('install')
        self.executable('install', f'''#!/usr/bin/env python3
import os, sys
args = iter(sys.argv[1:]); out = []
for arg in args:
    if arg in ('-o', '-g'): next(args)
    else: out.append(arg)
os.execv({real_install!r}, [{real_install!r}] + out)
''')
        self.executable('chown', '#!/bin/sh\nexit 0\n')
        self.executable('systemctl', '#!/bin/sh\necho "systemctl $*" >> "$TEST_ROOT/events"\n')
        self.executable('lego', '''#!/bin/bash
set -eu
printf '%s\\n' "$*" >> "$TEST_ROOT/events"
[[ ! -f "$TEST_ROOT/fail-acme" ]]
cp "$CERT_FIXTURE/new.crt" "$TEST_ROOT/home/lego/certificates/example.com.crt"
cp "$CERT_FIXTURE/new.key" "$TEST_ROOT/home/lego/certificates/example.com.key"
''')
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', TEST_ROOT=str(self.root), CERT_FIXTURE=str(self.certs))
        self.prefix = f'source {shlex.quote(str(self.functions))}; DOMAIN=example.com; EMAIL=admin@example.com; LEGO_BIN={shlex.quote(str(self.bin / "lego"))}; '

    def executable(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def run_bash(self, body, ok=True, input=None):
        r = subprocess.run(['bash', '-c', self.prefix + body], text=True, input=input, capture_output=True, env=self.env, timeout=15)
        self.assertEqual(r.returncode == 0, ok, r.stdout + r.stderr)
        return r

    def cache_pair(self, name):
        for ext in ('crt', 'key'):
            shutil.copyfile(self.certs / f'{name}.{ext}', self.cache / f'example.com.{ext}')

    def make_renewal(self):
        self.run_bash('write_renewal_service')
        subprocess.run(['bash', '-n', str(self.root / 'renew.sh')], check=True)
        (self.root / 'events').write_text('')

    def renew(self, ok=True):
        r = subprocess.run(['bash', str(self.root / 'renew.sh')], env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(r.returncode == 0, ok, r.stderr)
        self.assertNotIn('systemctl', (self.root / 'events').read_text())
        return r

    def test_custom_udp_config_has_no_tcp_443_or_internal_acme(self):
        self.run_bash('PORT=8443; PASSWORD=preserve-password; validate_install_inputs; write_config')
        text = (self.config / 'config.yaml').read_text()
        self.assertIn('listen: :8443', text)
        self.assertIn('password: \'preserve-password\'', text)
        self.assertIn('tls:\n  cert:', text)
        self.assertNotIn('acme:', text)
        self.assertNotIn('listenHTTPS', text)

    def test_optional_tcp_page_and_update_port_loading(self):
        self.run_bash('PORT=08443; HTTPS_PORT=9443; PASSWORD=preserve-password; validate_install_inputs; write_config; PORT=443; HTTPS_PORT=0; load_installed_ports; [[ "$PORT" == 8443 && "$HTTPS_PORT" == 9443 ]]')
        self.assertIn('listenHTTPS: :9443', (self.config / 'config.yaml').read_text())

    def test_rejects_invalid_ports_and_empty_explicit_password(self):
        for value in ('0', '65536', '-1', '443;id'):
            self.run_bash(f'PORT={shlex.quote(value)}; validate_install_inputs', ok=False)
        self.run_bash('HTTPS_PORT=80; validate_install_inputs', ok=False)
        self.run_bash('HTTPS_PORT=443; NO_MASQUERADE=1; validate_install_inputs', ok=False)
        self.run_bash('PASSWORD_FROM_STDIN=1; validate_install_inputs', ok=False, input='\n')

    def test_udp_preflight_does_not_check_unrequested_tcp_port(self):
        self.run_bash('''PORT=443; HTTPS_PORT=0
systemctl() { echo 0; }
ss() { [[ "$*" == *-lnup* ]] || return 90; }
check_port_available
''')
        self.run_bash('''PORT=8443
systemctl() { echo 0; }
ss() { echo 'UNCONN 0 0 *:8443 *:* users:(("other",pid=123,fd=3))'; }
check_port_available
''', ok=False)

    def test_issuance_uses_http_and_serializes_with_legacy_trojan_lock(self):
        lock = self.lock.open('w')
        self.addCleanup(lock.close)
        fcntl.flock(lock, fcntl.LOCK_EX)
        p = subprocess.Popen(['bash', '-c', self.prefix + 'port_in_use() { return 1; }; obtain_certificate'],
                             env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            time.sleep(0.15)
            self.assertIsNone(p.poll())
            self.assertFalse((self.root / 'events').exists())
            fcntl.flock(lock, fcntl.LOCK_UN)
            out, err = p.communicate(timeout=10)
            self.assertEqual(p.returncode, 0, out + err)
            events = (self.root / 'events').read_text()
            self.assertIn('--http run', events)
            self.assertNotIn('--tls', events)
            self.assertEqual((self.config / 'cert.pem').read_bytes(), (self.certs / 'new.crt').read_bytes())
        finally:
            if p.poll() is None:
                p.kill(); p.communicate()

    def test_http_timeout_stops_without_deploying_credentials(self):
        self.executable('lego', '#!/bin/sh\necho "Fetching http://example.com/test: Timeout during connect (likely firewall problem)"\nexit 1\n')
        r = self.run_bash('port_in_use() { return 1; }; obtain_certificate', ok=False)
        self.assertIn('TCP 80', r.stderr)
        self.assertFalse((self.config / 'cert.pem').exists())

    def test_renewal_uses_new_pair_without_service_restart(self):
        self.cache_pair('old')
        self.make_renewal()
        self.renew()
        self.assertIn('--http renew --days 30', (self.root / 'events').read_text())
        self.assertEqual((self.config / 'cert.pem').read_bytes(), (self.certs / 'new.crt').read_bytes())
        self.assertEqual((self.config / 'key.pem').stat().st_mode & 0o777, 0o640)

    def test_failed_acme_preserves_deployed_certificate(self):
        self.cache_pair('old')
        (self.config / 'cert.pem').write_bytes((self.certs / 'old.crt').read_bytes())
        (self.root / 'fail-acme').touch()
        self.make_renewal()
        self.renew(ok=False)
        self.assertEqual((self.config / 'cert.pem').read_bytes(), (self.certs / 'old.crt').read_bytes())

    def test_wrong_name_and_mismatched_key_are_not_deployed(self):
        self.make_renewal()
        self.cache_pair('wrong')
        (self.root / 'fail-acme').touch()
        self.renew(ok=False)
        self.assertFalse((self.config / 'cert.pem').exists())
        self.cache_pair('new')
        shutil.copyfile(self.certs / 'wrong.key', self.cache / 'example.com.key')
        self.renew(ok=False)
        self.assertFalse((self.config / 'cert.pem').exists())

    def test_cached_new_certificate_retries_deployment_after_copy_failure(self):
        self.cache_pair('new')
        self.make_renewal()
        install = self.bin / 'install'
        original = install.read_text()
        install.write_text('#!/bin/sh\nexit 1\n')
        self.renew(ok=False)
        install.write_text(original)
        self.renew()
        self.assertEqual((self.config / 'cert.pem').read_bytes(), (self.certs / 'new.crt').read_bytes())
        self.assertNotIn('--http', (self.root / 'events').read_text())

    def test_failed_reinstall_restores_only_its_own_renewal_timer(self):
        self.run_bash('pause_renewal_for_install; false', ok=False)
        events = (self.root / 'events').read_text()
        self.assertIn('stop hysteria-cert-renew.timer', events)
        self.assertIn('stop hysteria-cert-renew.service', events)
        self.assertIn('start hysteria-cert-renew.timer', events)
        self.assertNotIn('trojan.service', events)
        self.assertNotIn('hysteria-server.service', events)

if __name__ == '__main__':
    unittest.main(verbosity=2)
