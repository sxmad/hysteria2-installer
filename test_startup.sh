#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/install.sh" ]]; then
  ROOT_DIR="${SCRIPT_DIR}"
else
  ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
INSTALLER="${ROOT_DIR}/install.sh"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${message}: expected ${expected@Q}, got ${actual@Q}"
}
# Load the installer functions without invoking its command-line entrypoint.
# All systemd, journalctl and ss interactions below are deterministic mocks.
source <(sed '/^main \"\$@\"/d' "${INSTALLER}")

TEST_TMP="$(mktemp -d)"
SS_CALLS_FILE="${TEST_TMP}/ss-calls"
trap 'rm -rf -- "${TEST_TMP}"' EXIT

FAKE_ACTIVE=1
FAKE_PID=4242
FAKE_INVOCATION="invocation-1"
FAKE_LOG=""
FAKE_SS=""
SS_CALLS=0
WAIT_CALLS=0
PROMPT_CALLS=0
RESTART_CALLS=0
SUCCESS_AFTER=0
PROMPT_RESULT=0

systemctl() {
  case "${1:-}" in
    is-active)
      ((FAKE_ACTIVE))
      ;;
    show)
      case "${*:2}" in
        *InvocationID*) printf '%s\n' "${FAKE_INVOCATION}" ;;
        *MainPID*) printf '%s\n' "${FAKE_PID}" ;;
        *) printf '\n' ;;
      esac
      ;;
    stop)
      FAKE_ACTIVE=0
      return 0
      ;;
    start|restart)
      FAKE_ACTIVE=1
      ((RESTART_CALLS += 1))
      return 0
      ;;
    reset-failed|daemon-reload|enable)
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

journalctl() {
  printf '%s\n' "${FAKE_LOG}"
}

ss() {
  local calls
  calls="$(cat "${SS_CALLS_FILE}")"
  calls=$((calls + 1))
  printf '%s' "${calls}" >"${SS_CALLS_FILE}"
  printf '%s\n' "${FAKE_SS}"
}

sleep() { :; }
show_service_diagnostics() { :; }
# The production helper reads the real config. Tests model the default
# installer path, which has TCP HTTPS masquerade enabled.
service_masquerade_tcp_expected() { return 0; }

reset_service_mocks() {
  FAKE_ACTIVE=1
  FAKE_PID=4242
  FAKE_INVOCATION="invocation-1"
  FAKE_LOG=""
  FAKE_SS=""
  SS_CALLS=0
  printf '0' >"${SS_CALLS_FILE}"
  WAIT_CALLS=0
  PROMPT_CALLS=0
  RESTART_CALLS=0
  SUCCESS_AFTER=0
  PROMPT_RESULT=0
  LAST_SERVICE_INVOCATION_ID=""
  SERVICE_STARTED_AT=""
  PORT=443
}

# Classification: a FATAL config wrapper that contains badNonce is a
# retryable ACME failure, while a reachable-network failure is not.
reset_service_mocks
FAKE_LOG='FATAL failed to load server config: obtaining certificate: badNonce from ACME server'
assert_eq acme "$(service_failure_kind "${FAKE_INVOCATION}")" 'FATAL ACME badNonce classification'
pass 'FATAL config wrapper with badNonce is retryable ACME'

FAKE_LOG='ERROR challenge failed: Timeout during connect (likely firewall problem)'
assert_eq hard "$(service_failure_kind "${FAKE_INVOCATION}")" 'TCP timeout classification'
pass 'TCP 443 timeout is a hard failure'

# The normal INFO line must not be confused with an ACME rate limit.
FAKE_LOG='INFO waiting on internal rate limiter'
kind="$(service_failure_kind "${FAKE_INVOCATION}")"
[[ "${kind}" != hard && "${kind}" != acme ]] || fail "internal rate limiter INFO misclassified as ${kind}"
pass 'internal rate limiter INFO is not treated as a rate limit'

FAKE_LOG=$'INFO certificate maintenance started\nFATAL failed to load server config: listen udp :443: bind: address already in use'
assert_eq hard "$(service_failure_kind "${FAKE_INVOCATION}")" 'bind conflict classification'
pass 'bind conflict remains hard despite certificate INFO'

# A ready log plus UDP and TCP sockets owned by the current service PID are
# required when the default HTTPS masquerade is enabled.
reset_service_mocks
FAKE_LOG='INFO server up and running'
FAKE_SS=$'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("hysteria",pid=4242,fd=4))\nUNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("hysteria",pid=4242,fd=3))'
wait_for_service_stable || fail 'current PID ready socket should pass startup stability'
assert_eq 6 "$(cat "${SS_CALLS_FILE}")" 'stable startup check count'
pass 'current PID plus ready TCP/UDP sockets passes three consecutive checks'

# A socket owned by another process must never be accepted.
reset_service_mocks
FAKE_LOG='INFO server up and running'
FAKE_SS=$'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("other",pid=9999,fd=4))\nUNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("other",pid=9999,fd=3))'
if wait_for_service_stable; then
  fail 'unrelated TCP/UDP sockets were accepted as Hysteria listeners'
fi
pass 'unrelated TCP/UDP sockets do not satisfy startup check'

# A missing TCP HTTPS listener must not be accepted when static masquerade is
# configured, even if the UDP Hysteria listener and ready log are present.
reset_service_mocks
FAKE_LOG='INFO server up and running'
FAKE_SS='UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("hysteria",pid=4242,fd=3))'
if wait_for_service_stable; then
  fail 'missing TCP HTTPS listener was accepted'
fi
pass 'missing TCP HTTPS listener does not satisfy startup check'

# A listener without a ready log is also insufficient.
reset_service_mocks
FAKE_LOG='INFO maintenance started'
FAKE_SS=$'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("hysteria",pid=4242,fd=4))\nUNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("hysteria",pid=4242,fd=3))'
if wait_for_service_stable; then
  fail 'listener without ready log was accepted'
fi
pass 'UDP listener without ready log does not satisfy startup check'

# Recovery loop mocks. The production function must stop the failed service,
# prompt once per repair, and retry at most three times.
wait_for_service_stable() {
  ((WAIT_CALLS += 1))
  ((SUCCESS_AFTER > 0 && WAIT_CALLS >= SUCCESS_AFTER))
}
service_failure_kind() { printf 'acme'; }
prompt_certificate_repair() {
  ((PROMPT_CALLS += 1))
  return "${PROMPT_RESULT}"
}

# Option 1 equivalent: repair once, restart, then succeed.
reset_service_mocks
SUCCESS_AFTER=2
PROMPT_RESULT=0
if ! wait_for_service_with_recovery; then
  fail 'one repair retry should recover'
fi
assert_eq 2 "${WAIT_CALLS}" 'one-retry wait count'
assert_eq 1 "${PROMPT_CALLS}" 'one-retry prompt count'
assert_eq 1 "${RESTART_CALLS}" 'one-retry restart count'
pass 'option 1 retry succeeds after one transient failure'

# Option 2 equivalent: abort immediately and never restart or generate a QR.
reset_service_mocks
SUCCESS_AFTER=99
PROMPT_RESULT=1
QR_CALLS=0
if wait_for_service_with_recovery; then
  fail 'option 2 should abort'
fi
((PROMPT_CALLS == 1)) || fail "option 2 prompt count: ${PROMPT_CALLS}"
((RESTART_CALLS == 0)) || fail "option 2 restart count: ${RESTART_CALLS}"
((QR_CALLS == 0)) || fail 'option 2 reached QR generation'
pass 'option 2 aborts before restart or QR generation'

# Three repair attempts are the upper bound; the fourth failure stops.
reset_service_mocks
SUCCESS_AFTER=99
PROMPT_RESULT=0
if wait_for_service_with_recovery; then
  fail 'three failed repair attempts should stop'
fi
assert_eq 4 "${WAIT_CALLS}" 'three-attempt wait count'
assert_eq 3 "${PROMPT_CALLS}" 'three-attempt prompt count'
assert_eq 3 "${RESTART_CALLS}" 'three-attempt restart count'
pass 'repair loop stops after three retries'

# Automatic passwords are exactly 16 URL-safe characters.
reset_service_mocks
DOMAIN='example.com'
EMAIL='you@example.com'
PORT=443
PASSWORD=''
PASSWORD_FROM_STDIN=0
validate_install_inputs
[[ "${PASSWORD}" =~ ^[A-Za-z0-9._-]{16}$ ]] || fail "generated password is not 16 URL-safe characters: ${PASSWORD@Q}"
pass 'automatic password is exactly 16 URL-safe characters'

# Missing identity fields are prompted individually; explicit values must
# neither prompt nor consume stdin reserved for a custom password.
(
  DOMAIN=''; EMAIL=''; PASSWORD_FROM_STDIN=0
  collect_install_identity <<< $'hy2.example.com\nyou@example.com'
  assert_eq hy2.example.com "${DOMAIN}" 'prompted domain'
  assert_eq you@example.com "${EMAIL}" 'prompted email'
)
pass 'missing domain and email are both read from input'
(
  DOMAIN='hy2.example.com'; EMAIL=''
  collect_install_identity <<< 'you@example.com'
  assert_eq hy2.example.com "${DOMAIN}" 'explicit domain preserved'
  assert_eq you@example.com "${EMAIL}" 'only missing email read'
  DOMAIN=''; EMAIL='you@example.com'
  collect_install_identity <<< 'hy2.example.com'
  assert_eq hy2.example.com "${DOMAIN}" 'only missing domain read'
  assert_eq you@example.com "${EMAIL}" 'explicit email preserved'
)
pass 'only the missing identity field is prompted'
(
  DOMAIN='hy2.example.com'; EMAIL='you@example.com'; PASSWORD_FROM_STDIN=1
  { collect_install_identity; validate_install_inputs; } <<< 'customPassword16'
  assert_eq customPassword16 "${PASSWORD}" 'identity collection preserves password stdin'
)
pass 'explicit domain/email preserve password stdin without prompting'
if (DOMAIN='hy2.example.com'; EMAIL=''; collect_install_identity </dev/null) >"${TEST_TMP}/missing-email.log" 2>&1; then
  fail 'missing email accepted without input'
fi
grep -Fq -- '--email' "${TEST_TMP}/missing-email.log" || fail 'missing email diagnostic absent'
pass 'missing email without input aborts with an explicit flag hint'

# Log redaction must treat password punctuation literally and cover every
# occurrence, not merely a JSON field named auth/password.
PASSWORD='a.b-c_d012345'
printf '%s\n' 'auth: a.b-c_d012345 repeat a.b-c_d012345' 'keep aXb-c_d012345' >"${TEST_TMP}/secret.log"
print_selftest_log "${TEST_TMP}/secret.log" 2>"${TEST_TMP}/redacted.log"
grep -Fxq 'auth: [REDACTED] repeat [REDACTED]' "${TEST_TMP}/redacted.log" || fail 'secret was not fully redacted'
grep -Fxq 'keep aXb-c_d012345' "${TEST_TMP}/redacted.log" || fail 'password was treated as a regular expression'
pass 'self-test log redaction replaces only the literal password'

# Exercise the actual install/update functions with side effects mocked.
# All paths are redirected into TEST_TMP; no real installer or systemd runs.
sed -e '/^main "\$@"/d' \
  -e "s|readonly CONFIG_DIR=\"/etc/hysteria\"|readonly CONFIG_DIR=\"${TEST_TMP}/config\"|" \
  -e "s|readonly HYSTERIA_HOME_DIR=\"/var/lib/hysteria\"|readonly HYSTERIA_HOME_DIR=\"${TEST_TMP}/home\"|" \
  -e "s|readonly STATE_DIR=\"/var/lib/hysteria2-installer\"|readonly STATE_DIR=\"${TEST_TMP}/state\"|" \
  -e 's|\[\[ -d /run/systemd/system \]\]|true|g' \
  "${INSTALLER}" >"${TEST_TMP}/workflow-installer.sh"
mkdir -p "${TEST_TMP}/state"
cat >"${TEST_TMP}/workflow-test.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$1"
MODE="$2"
EVENTS="$3"
require_root() { :; }
require_command() { :; }
install_prerequisites() { :; }
quarantine_connection_artifacts() { :; }
check_domain_resolution() { :; }
check_port_available() { :; }
backup_config() { :; }
state_owns_directory() { return 1; }
id() { return 0; }
install() { :; }
chmod() { :; }
write_masquerade_page() { :; }
write_config() { :; }
systemctl() { return 0; }
run_official_installer() { printf 'installer\n' >>"${EVENTS}"; }
wait_for_service_with_recovery() { printf 'startup\n' >>"${EVENTS}"; }
local_connection_selftest() {
  printf 'selftest\n' >>"${EVENTS}"
  [[ "${MODE}" != selftest_fail ]]
}
print_connection_info() { printf 'qr\n' >>"${EVENTS}"; }
DOMAIN=example.com
EMAIL=you@example.com
PASSWORD=Example123456789
NO_MASQUERADE=1
case "${MODE}" in
  invalid_install) VERSION=v1.3.0; install_hysteria ;;
  invalid_update) VERSION=v1.3.0; update_hysteria ;;
  missing_update) update_hysteria ;;
  *) install_hysteria ;;
esac
EOF

run_workflow_test() {
  bash "${TEST_TMP}/workflow-test.sh" "${TEST_TMP}/workflow-installer.sh" "$1" \
    "${TEST_TMP}/$1.events" >"${TEST_TMP}/$1.log" 2>&1
}
if run_workflow_test selftest_fail; then
  fail 'install accepted a failed functional self-test'
fi
assert_eq $'installer\nstartup\nselftest' "$(cat "${TEST_TMP}/selftest_fail.events")" 'failed self-test stops before QR generation'
pass 'actual install workflow cannot output credentials/QR after self-test failure'
run_workflow_test selftest_pass || fail 'successful mocked installation was rejected'
assert_eq $'installer\nstartup\nselftest\nqr' "$(cat "${TEST_TMP}/selftest_pass.events")" 'QR follows successful self-test'
pass 'actual install workflow outputs QR only after successful self-test'
for mode in invalid_install invalid_update missing_update; do
  if run_workflow_test "${mode}"; then
    fail "${mode} unexpectedly succeeded"
  fi
  [[ ! -s "${TEST_TMP}/${mode}.events" ]] || fail "${mode} reached the official installer"
done
grep -Fq 'Hysteria 2 正式版本' "${TEST_TMP}/invalid_install.log" || fail 'install did not validate explicit version'
grep -Fq 'Hysteria 2 正式版本' "${TEST_TMP}/invalid_update.log" || fail 'update did not validate explicit version'
grep -Fq '新设备请先执行 install' "${TEST_TMP}/missing_update.log" || fail 'missing installation was not identified'
pass 'invalid install/update versions and update-before-install stop before installation'

printf 'All startup tests passed.\n'
