#!/usr/bin/env bash
# Integration tests use real Hysteria server/client processes and real TLS.
# Fixtures: a temporary CA, loopback-only servers, and a local HTTPS endpoint
# in place of Google's generate_204. No ACME or public-network claim is made.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/install.sh" ]]; then
  INSTALLER="${SCRIPT_DIR}/install.sh"
else
  INSTALLER="${SCRIPT_DIR}/../install.sh"
fi
: "${HYSTERIA_TEST_BINARY:?Set HYSTERIA_TEST_BINARY to an executable Hysteria 2 binary}"
[[ -x "${HYSTERIA_TEST_BINARY}" ]] || { echo 'Hysteria test binary is not executable' >&2; exit 1; }
HYSTERIA_TEST_BINARY="$(cd "$(dirname "${HYSTERIA_TEST_BINARY}")" && pwd)/$(basename "${HYSTERIA_TEST_BINARY}")"
for dependency in openssl python3 curl ss; do
  command -v "${dependency}" >/dev/null || { echo "Missing dependency: ${dependency}" >&2; exit 1; }
done

TEST_TMP="$(mktemp -d)"
SERVER_PID=""
FIXTURE_PID=""
cleanup() {
  local process
  for process in "${SERVER_PID}" "${FIXTURE_PID}"; do
    [[ -z "${process}" ]] || kill "${process}" 2>/dev/null || true
  done
  for process in "${SERVER_PID}" "${FIXTURE_PID}"; do
    [[ -z "${process}" ]] || wait "${process}" 2>/dev/null || true
  done
  rm -rf -- "${TEST_TMP}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${TEST_TMP}/ca.key" -out "${TEST_TMP}/ca.pem" \
  -subj '/CN=Hysteria installer integration test CA' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "${TEST_TMP}/server.key" \
  -out "${TEST_TMP}/server.csr" -subj '/CN=hy2-test.example.com' >/dev/null 2>&1
cat >"${TEST_TMP}/extensions.cnf" <<'EOF'
subjectAltName=DNS:hy2-test.example.com,DNS:localhost,IP:127.0.0.1
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -in "${TEST_TMP}/server.csr" -CA "${TEST_TMP}/ca.pem" \
  -CAkey "${TEST_TMP}/ca.key" -CAcreateserial -days 1 \
  -extfile "${TEST_TMP}/extensions.cnf" -out "${TEST_TMP}/server.pem" >/dev/null 2>&1
export SSL_CERT_FILE="${TEST_TMP}/ca.pem"
export CURL_CA_BUNDLE="${TEST_TMP}/ca.pem"
mkdir "${TEST_TMP}/page"
printf '<!doctype html><html><body>asdfq</body></html>\n' >"${TEST_TMP}/page/index.html"

# HTTPS fixture records successful requests so a forged status line alone
# cannot satisfy the success test.
python3 - "${TEST_TMP}" >"${TEST_TMP}/fixture.log" 2>&1 <<'PY' &
import http.server, pathlib, ssl, sys
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with (root / 'requests').open('a') as stream:
            stream.write(self.path + '\n')
        self.send_response(204 if self.path == '/generate_204' else 404)
        self.end_headers()
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(root / 'server.pem', root / 'server.key')
server.socket = context.wrap_socket(server.socket, server_side=True)
(root / 'fixture.port').write_text(str(server.server_port))
server.serve_forever()
PY
FIXTURE_PID=$!
for ((attempt=0; attempt<50; attempt++)); do
  [[ -s "${TEST_TMP}/fixture.port" ]] && break
  kill -0 "${FIXTURE_PID}" 2>/dev/null || fail 'HTTPS fixture exited'
  sleep 0.1
done
[[ -s "${TEST_TMP}/fixture.port" ]] || fail 'HTTPS fixture did not start'
FIXTURE_PORT="$(cat "${TEST_TMP}/fixture.port")"
TEST_HTTPS_TARGET="https://localhost:${FIXTURE_PORT}/generate_204"

# The production function is loaded unchanged except its binary and external
# target locations. This adaptation never writes /usr/local/bin or /etc.
python3 - "${INSTALLER}" "${TEST_TMP}/installer-functions.sh" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
source = source.replace('main "$@"', '# CLI entrypoint disabled for integration test')
source = source.replace('/usr/local/bin/hysteria', '${HYSTERIA_TEST_BINARY}')
source = source.replace('https://www.google.com/generate_204',
                        '${TEST_HTTPS_TARGET}')
pathlib.Path(sys.argv[2]).write_text(source)
PY
# shellcheck disable=SC1090
source "${TEST_TMP}/installer-functions.sh"
# Sourcing sets an ERR trap only. Restore our explicitly bounded test cleanup.
trap cleanup EXIT

# Relocate only selftest temporary directories, and record actual client PIDs.
# All ss queries and network operations remain real.
mktemp() {
  if [[ "${1:-}" == -d && "${2:-}" == /tmp/hysteria2-selftest.XXXXXXXX ]]; then
    command mktemp -d "${TEST_TMP}/hysteria2-selftest.XXXXXXXX"
  else
    command mktemp "$@"
  fi
}
eval "$(declare -f selftest_client_owns_listener | sed '1s/selftest_client_owns_listener/real_selftest_client_owns_listener/')"
selftest_client_owns_listener() {
  local config_path
  printf '%s\n' "$1" >>"${TEST_TMP}/client-pids"
  for config_path in "${TEST_TMP}"/hysteria2-selftest.*/client.yaml; do
    [[ ! -f "${config_path}" ]] || printf '%s\n' "${config_path}" >>"${TEST_TMP}/client-arguments"
  done
  # Restricted runners may deny netlink/PID ownership inspection. Opt-in
  # fallback tests the real listener and live child but DOES NOT test the
  # production ss/PID ownership check. Normal Linux CI must omit this flag.
  if [[ "${HYSTERIA_TEST_NO_PID_CHECK:-0}" == 1 ]]; then
    kill -0 "$1" 2>/dev/null || return 1
    python3 - "$2" <<'PY'
import socket, sys
try:
    with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=0.2):
        pass
except OSError:
    sys.exit(1)
PY
    return $?
  fi
  real_selftest_client_owns_listener "$@"
}

DOMAIN='hy2-test.example.com'
PASSWORD='testPassword1234'
NO_MASQUERADE=0

start_server() {
  local with_page="$1"
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=''
  fi
  PORT="$(python3 - <<'PY'
import socket
tcp = socket.socket()
tcp.bind(('127.0.0.1', 0))
port = tcp.getsockname()[1]
udp = socket.socket(type=socket.SOCK_DGRAM)
udp.bind(('127.0.0.1', port))
print(port)
PY
)"
  cat >"${TEST_TMP}/server.yaml" <<EOF
listen: 127.0.0.1:${PORT}
tls:
  cert: ${TEST_TMP}/server.pem
  key: ${TEST_TMP}/server.key
auth:
  type: password
  password: 'testPassword1234'
masquerade:
  type: file
  file:
    dir: ${TEST_TMP}/page
EOF
  if ((with_page)); then
    printf '  listenHTTPS: 127.0.0.1:%s\n' "${PORT}" >>"${TEST_TMP}/server.yaml"
  fi
  "${HYSTERIA_TEST_BINARY}" server -c "${TEST_TMP}/server.yaml" >"${TEST_TMP}/server.log" 2>&1 &
  SERVER_PID=$!
  for ((attempt=0; attempt<50; attempt++)); do
    grep -q 'server up and running' "${TEST_TMP}/server.log" && return 0
    kill -0 "${SERVER_PID}" 2>/dev/null || { cat "${TEST_TMP}/server.log" >&2; fail 'Hysteria server exited'; }
    sleep 0.1
  done
  fail 'Hysteria server did not become ready'
}

assert_cleanup() {
  local process path
  if [[ -f "${TEST_TMP}/client-pids" ]]; then
    while IFS= read -r process; do
      kill -0 "${process}" 2>/dev/null && fail "selftest client process leaked: ${process}"
    done <"${TEST_TMP}/client-pids"
  fi
  for path in "${TEST_TMP}"/hysteria2-selftest.*; do
    [[ ! -e "${path}" ]] || fail "selftest temporary directory leaked: ${path}"
  done
  : >"${TEST_TMP}/client-pids"
}

expect_success() {
  local label="$1"
  if ! local_connection_selftest >"${TEST_TMP}/result.log" 2>&1; then
    cat "${TEST_TMP}/result.log" >&2
    fail "${label}"
  fi
  grep -q 'HTTP 204' "${TEST_TMP}/result.log" || fail 'missing success marker'
  grep -qx '/generate_204' "${TEST_TMP}/requests" || fail 'proxy target was not reached'
  grep -q '/client.yaml$' "${TEST_TMP}/client-arguments" || fail 'client config lacks .yaml suffix'
  assert_cleanup
  pass "${label}"
}

expect_failure() {
  local label="$1" message="$2"
  if local_connection_selftest >"${TEST_TMP}/result.log" 2>&1; then
    fail "${label}: incorrectly accepted"
  fi
  grep -q "${message}" "${TEST_TMP}/result.log" || { cat "${TEST_TMP}/result.log" >&2; fail "${label}: expected diagnostic missing"; }
  if grep -Fq -- "${PASSWORD}" "${TEST_TMP}/result.log"; then
    fail "${label}: password leaked into diagnostic"
  fi
  assert_cleanup
  pass "${label}"
}

start_server 1
if [[ "${HYSTERIA_TEST_NO_PID_CHECK:-0}" == 1 ]]; then
  printf 'NOTE: test-only live-child/TCP readiness fallback enabled; ss/PID ownership is not verified.\n'
fi
expect_success 'real TLS + password authentication + SOCKS forwarding + HTTPS page'
PASSWORD='deliberatelyWrong'
expect_failure 'wrong password is refused' 'authentication\|认证'
PASSWORD='testPassword1234'
DOMAIN='wrong-name.example.com'
NO_MASQUERADE=1
expect_failure 'wrong QUIC TLS SNI is refused' 'certificate\|证书'
DOMAIN='hy2-test.example.com'
NO_MASQUERADE=0
start_server 0
expect_failure 'missing TCP HTTPS page is refused' 'HTTPS 自测失败'
NO_MASQUERADE=1
expect_success '--no-masquerade still verifies TLS + authentication + forwarding'
pass 'all integration tests; temporary clients/files cleaned after every result'

# Opt-in only: restricted runners may prohibit direct public egress. Failure
# of this extra check is reported separately from local integration results.
if [[ "${HYSTERIA_TEST_EXTERNAL:-0}" == 1 ]]; then
  [[ -r /etc/ssl/certs/ca-certificates.crt ]] || fail 'system CA bundle unavailable for external check'
  cat /etc/ssl/certs/ca-certificates.crt "${TEST_TMP}/ca.pem" >"${TEST_TMP}/combined-ca.pem"
  export SSL_CERT_FILE="${TEST_TMP}/combined-ca.pem"
  export CURL_CA_BUNDLE="${TEST_TMP}/combined-ca.pem"
  TEST_HTTPS_TARGET='https://www.google.com/generate_204'
  if local_connection_selftest >"${TEST_TMP}/external.log" 2>&1; then
    pass 'optional real Google HTTPS 204 through Hysteria'
  else
    printf 'UNVERIFIED: optional real Google check failed in this environment:\n'
    cat "${TEST_TMP}/external.log"
  fi
  assert_cleanup
fi
