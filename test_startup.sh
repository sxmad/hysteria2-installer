#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT_DIR}/install.sh"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${message}: expected ${expected@Q}, got ${actual@Q}"
}
assert_true() {
  "$@" || fail "assertion failed: $*"
}

# Load the installer functions without invoking its command-line entrypoint.
# All systemd, journalctl and ss interactions below are deterministic mocks.
eval "$(sed '/^main \"\$@\"/d' "${INSTALLER}")"

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

# A ready log and UDP socket owned by the current service PID are required.
reset_service_mocks
FAKE_LOG='INFO server up and running'
FAKE_SS='UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("hysteria",pid=4242,fd=3))'
wait_for_service_stable || fail 'current PID ready socket should pass startup stability'
assert_eq 3 "$(cat "${SS_CALLS_FILE}")" 'stable startup check count'
pass 'current PID plus ready log passes three consecutive checks'

# A socket owned by another process must never be accepted.
reset_service_mocks
FAKE_LOG='INFO server up and running'
FAKE_SS='UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("other",pid=9999,fd=3))'
if wait_for_service_stable; then
  fail 'unrelated UDP socket was accepted as Hysteria listener'
fi
pass 'unrelated UDP socket does not satisfy startup check'

# A listener without a ready log is also insufficient.
reset_service_mocks
FAKE_LOG='INFO maintenance started'
FAKE_SS='UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("hysteria",pid=4242,fd=3))'
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
EMAIL='com.gpugame@gmail.com'
PORT=443
PASSWORD=''
PASSWORD_FROM_STDIN=0
validate_install_inputs
[[ "${PASSWORD}" =~ ^[A-Za-z0-9._-]{16}$ ]] || fail "generated password is not 16 URL-safe characters: ${PASSWORD@Q}"
pass 'automatic password is exactly 16 URL-safe characters'

printf 'All startup tests passed.\n'
