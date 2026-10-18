#!/usr/bin/env python3
"""Existing HTTP service, webroot permissions, renewal persistence and early failure."""
import functools
import http.server
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parent
if not (ROOT / 'install.sh').exists():
    ROOT = ROOT.parent
IS_HY2 = 'readonly SCRIPT_NAME="hysteria2-installer"' in (ROOT / 'install.sh').read_text()


class QuietHTTP(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


class WebrootTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        cls.certs = Path(cls.fixture.name)
        for name, days in [('old', 1), ('new', 90)]:
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', str(days),
                            '-subj', '/CN=example.com', '-addext', 'subjectAltName=DNS:example.com',
                            '-out', str(cls.certs / f'{name}.crt'), '-keyout', str(cls.certs / f'{name}.key')],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.webroot = self.base / 'website with spaces'
        self.webroot.mkdir(mode=0o755)
        (self.webroot / 'index.html').write_text('existing website')
        self.config = self.base / 'config'
        self.cache = self.base / 'home' / 'lego' / 'certificates'
        self.bin = self.base / 'bin'
        for p in [self.config, self.cache, self.bin, self.base / 'state']:
            p.mkdir(parents=True)
        self.http = http.server.ThreadingHTTPServer(('127.0.0.1', 0),
                        functools.partial(QuietHTTP, directory=str(self.webroot)))
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_http)
        source = (ROOT / 'install.sh').read_text().replace('\nmain "$@"\n', '\n')
        for name, value in {'CONFIG_DIR': self.config, 'HOME_DIR': self.base / 'home',
                            'HYSTERIA_HOME_DIR': self.base / 'home', 'STATE_DIR': self.base / 'state',
                            'ACME_LOCK': self.base / 'lock', 'BINARY': self.bin / 'trojan',
                            'RENEW_SCRIPT': self.base / 'renew.sh'}.items():
            source = re.sub(rf'^readonly {name}=.*$', f'readonly {name}={shlex.quote(str(value))}', source, flags=re.M)
        source = source.replace('[[ -d /run/systemd/system ]]', 'true')
        self.functions = self.base / 'functions.sh'
        self.functions.write_text(source)
        real_install = shutil.which('install')
        self.executable('install', f'''#!/usr/bin/env python3
import os, sys
args=iter(sys.argv[1:]); out=[]
for arg in args:
    if arg in ('-o', '-g'): next(args)
    else: out.append(arg)
os.execv({real_install!r}, [{real_install!r}] + out)
''')
        self.executable('systemctl', '#!/bin/sh\necho "$*" >> "$TEST_ROOT/services"\n')
        self.executable('trojan', '#!/bin/sh\nexit 0\n')
        self.executable('lego', '''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys, urllib.request
args=sys.argv[1:]
root=pathlib.Path(os.environ['TEST_ROOT'])
with (root/'calls').open('a') as f: f.write(json.dumps(args)+'\\n')
assert '--http' in args and '--tls' not in args
webroot=pathlib.Path(args[args.index('--http.webroot')+1])
assert webroot == root/'website with spaces'
token=webroot/'.well-known/acme-challenge/test-token'
token.write_text('public-challenge')
try:
    assert token.stat().st_mode & 0o004
    assert token.parent.stat().st_mode & 0o005 == 0o005
    request=urllib.request.Request(os.environ['HTTP_URL']+'/.well-known/acme-challenge/test-token', headers={'Host':'example.com'})
    with urllib.request.urlopen(request, timeout=3) as response:
        assert response.read() == b'public-challenge'
finally:
    token.unlink()
for ext in ('crt','key'):
    shutil.copyfile(pathlib.Path(os.environ['FIXTURES'])/('new.'+ext), root/'home/lego/certificates'/('example.com.'+ext))
''')
        self.url = f'http://127.0.0.1:{self.http.server_port}'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        TEST_ROOT=str(self.base), FIXTURES=str(self.certs), HTTP_URL=self.url)
        self.prefix = f'source {shlex.quote(str(self.functions))}; DOMAIN=example.com; EMAIL=admin@example.com; LEGO_BIN={shlex.quote(str(self.bin / "lego"))}; '

    def close_http(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(timeout=3)

    def executable(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o755)

    def shell(self, body, ok=True):
        r = subprocess.run(['bash', '-c', self.prefix + body], env=self.env, text=True,
                           capture_output=True, timeout=15)
        self.assertEqual(r.returncode == 0, ok, r.stdout + r.stderr)
        return r

    def test_webroot_issuance_and_future_renewal_keep_existing_http_service(self):
        quoted = shlex.quote(str(self.webroot))
        self.shell(f'parse_args --acme-webroot {quoted}; port_in_use() {{ return 0; }}; preflight_certificate; obtain_certificate; render_renewal_script > "$TEST_ROOT/renew.sh"')
        self.assertEqual((self.config / 'cert.pem').read_bytes(), (self.certs / 'new.crt').read_bytes())
        for ext in ('crt', 'key'):
            shutil.copyfile(self.certs / f'old.{ext}', self.cache / f'example.com.{ext}')
        r = subprocess.run(['bash', str(self.base / 'renew.sh')], env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = [json.loads(x) for x in (self.base / 'calls').read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertIn('run', calls[0])
        self.assertIn('renew', calls[1])
        for call in calls:
            self.assertEqual(call[call.index('--http.webroot') + 1], str(self.webroot))
        self.assertEqual((self.config / 'cert.pem').read_bytes(), (self.certs / 'new.crt').read_bytes())
        self.assertEqual((self.base / 'home/lego').stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.config / 'key.pem').stat().st_mode & 0o777, 0o640)
        with urllib.request.urlopen(self.url, timeout=3) as response:
            self.assertEqual(response.read(), b'existing website')
        events = (self.base / 'services').read_text() if (self.base / 'services').exists() else ''
        self.assertNotIn('nginx', events)
        self.assertNotIn('stop ', events)
        self.assertNotIn('restart ', events)

    def test_busy_standalone_preflight_is_actionable_and_no_ca_request(self):
        r = self.shell('port_in_use() { return 0; }; preflight_certificate', ok=False)
        self.assertIn('--acme-webroot', r.stderr)
        self.assertIn('ss -ltnp', r.stderr)
        self.assertFalse((self.base / 'calls').exists())
        self.assertFalse((self.config / 'cert.pem').exists())

    def test_missing_webroot_during_renewal_preserves_certificate(self):
        for ext in ('crt', 'key'):
            shutil.copyfile(self.certs / f'old.{ext}', self.cache / f'example.com.{ext}')
        (self.config / 'cert.pem').write_bytes((self.certs / 'old.crt').read_bytes())
        self.shell(f'ACME_WEBROOT={shlex.quote(str(self.webroot))}; render_renewal_script > "$TEST_ROOT/renew.sh"')
        self.webroot.rename(self.base / 'removed-website')
        r = subprocess.run(['bash', str(self.base / 'renew.sh')], env=self.env, capture_output=True, text=True, timeout=15)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('webroot missing', r.stderr)
        self.assertFalse((self.base / 'calls').exists())
        self.assertEqual((self.config / 'cert.pem').read_bytes(), (self.certs / 'old.crt').read_bytes())

    def test_invalid_webroot_rejected(self):
        for value in ['', 'relative/path', str(self.base / 'missing'), '/tmp\ninvalid']:
            self.shell(f'parse_args --acme-webroot {shlex.quote(value)}; validate_acme_webroot', ok=False)

    @unittest.skipUnless(IS_HY2, 'Hysteria official installer creates a sample config')
    def test_hysteria_busy_http_stops_before_official_sample_config(self):
        r = self.shell('''
require_root() { :; }
install_prerequisites() { :; }
require_command() { :; }
quarantine_connection_artifacts() { :; }
check_domain_resolution() { :; }
check_port_available() { :; }
port_in_use() { return 0; }
run_official_installer() { touch "$TEST_ROOT/official-ran"; }
install_hysteria
''', ok=False)
        self.assertIn('--acme-webroot', r.stderr)
        self.assertFalse((self.base / 'official-ran').exists())
        self.assertFalse((self.config / 'config.yaml').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
