#!/usr/bin/env bash
# Opt-in integration test. Uses a unique disposable unit, never the proxy service.
set -Eeuo pipefail
[[ "${HYSTERIA_TEST_SYSTEMD:-0}" == 1 && "${EUID}" == 0 && -d /run/systemd/system ]] || {
  echo 'Requires root, running systemd, and HYSTERIA_TEST_SYSTEMD=1 (use a disposable CI VM).' >&2
  exit 1
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMP="$(mktemp -d)"
TEST_UNIT="hy2-installer-recovery-$(basename "${TEST_TMP}").service"
TEST_UNIT_FILE="/run/systemd/system/${TEST_UNIT}"
TEST_DROPIN_DIR="${TEST_UNIT_FILE}.d"
[[ ! -e "${TEST_UNIT_FILE}" && ! -e "${TEST_DROPIN_DIR}" ]] || exit 1
cleanup() {
  systemctl stop "${TEST_UNIT}" >/dev/null 2>&1 || true
  systemctl reset-failed "${TEST_UNIT}" >/dev/null 2>&1 || true
  rm -f -- "${TEST_UNIT_FILE}" "${TEST_DROPIN_DIR}/20-hysteria2-installer.conf"
  rmdir -- "${TEST_DROPIN_DIR}" 2>/dev/null || true
  systemctl daemon-reload
  rm -rf -- "${TEST_TMP}"
}
trap cleanup EXIT

# Generate the real policy into the disposable unit's directory.
python3 - "${SCRIPT_DIR}/install.sh" "${TEST_TMP}/functions.sh" "${TEST_DROPIN_DIR}" <<'PY'
from pathlib import Path
import shlex, sys
source = Path(sys.argv[1]).read_text().replace('\nmain "$@"\n', '\n')
source = source.replace('readonly SERVICE_DROPIN_DIR="/etc/systemd/system/${SERVICE}.d"',
                        'readonly SERVICE_DROPIN_DIR=' + shlex.quote(sys.argv[3]))
Path(sys.argv[2]).write_text(source)
PY
bash -c 'source "$1"; write_service_policy' _ "${TEST_TMP}/functions.sh"
cat >"${TEST_UNIT_FILE}" <<'EOF'
[Unit]
Description=Disposable Hysteria installer recovery test
[Service]
Type=simple
ExecStart=/bin/sh -c 'exit 42'
EOF
systemctl daemon-reload
systemctl start "${TEST_UNIT}"
for ((attempt=0; attempt<45; attempt++)); do
  [[ "$(systemctl show "${TEST_UNIT}" -p Result --value)" == start-limit-hit ]] && break
  sleep 1
done
[[ "$(systemctl show "${TEST_UNIT}" -p Result --value)" == start-limit-hit ]]
[[ "$(systemctl show "${TEST_UNIT}" -p NRestarts --value)" -ge 4 ]]
[[ "$(systemctl show "${TEST_UNIT}" -p MemoryAccounting --value)" == yes ]]
printf 'PASS: failed process is retried and repeated failures reach the start limit\n'

sed -i "s|ExecStart=.*|ExecStart=/bin/sleep infinity|" "${TEST_UNIT_FILE}"
systemctl daemon-reload
systemctl reset-failed "${TEST_UNIT}"
systemctl start "${TEST_UNIT}"
systemctl is-active --quiet "${TEST_UNIT}"
systemctl stop "${TEST_UNIT}"
sleep 6
[[ "$(systemctl show "${TEST_UNIT}" -p ActiveState --value)" == inactive ]]
[[ "$(systemctl show "${TEST_UNIT}" -p NRestarts --value)" == 0 ]]
printf 'PASS: manual stop remains stopped beyond the restart delay\n'
