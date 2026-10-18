#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="hysteria2-installer"
readonly SCRIPT_VERSION="2026-10-18.2"
readonly OFFICIAL_INSTALLER_URL="https://get.hy2.sh/"
readonly CONFIG_DIR="/etc/hysteria"
readonly CONFIG_FILE="${CONFIG_DIR}/config.yaml"
readonly SERVICE="hysteria-server.service"
readonly SERVICE_DROPIN_DIR="/etc/systemd/system/${SERVICE}.d"
readonly SERVICE_POLICY_FILE="${SERVICE_DROPIN_DIR}/20-hysteria2-installer.conf"
readonly SERVICE_POLICY_MARKER="# Managed by hysteria2-installer: recovery policy"
readonly HYSTERIA_HOME_DIR="/var/lib/hysteria"
readonly MASQUERADE_DIR="${HYSTERIA_HOME_DIR}/masquerade"
readonly STATE_DIR="/var/lib/hysteria2-installer"
readonly STATE_FILE="${STATE_DIR}/state"
readonly BACKUP_DIR="/var/backups/hysteria2-installer"
readonly DEFAULT_PORT="443"
readonly CERT_FILE="${CONFIG_DIR}/cert.pem"
readonly KEY_FILE="${CONFIG_DIR}/key.pem"
readonly LEGO_DIR="${HYSTERIA_HOME_DIR}/lego"
readonly RENEW_SCRIPT="/usr/local/sbin/hysteria-renew-cert"
readonly RENEW_SERVICE="hysteria-cert-renew.service"
readonly RENEW_TIMER="hysteria-cert-renew.timer"
# Shared with both new and legacy Trojan certificate renewal jobs.
readonly ACME_LOCK="/run/lock/trojan-cert-renew.lock"
readonly DEFAULT_PAGE_TEXT="asdfq"

ACTION="install"
DOMAIN=""
EMAIL=""
PORT="${DEFAULT_PORT}"
PASSWORD=""
PASSWORD_FROM_STDIN=0
NO_MASQUERADE=0
HTTPS_PORT=0
LEGO_BIN=""
CERT_CREATED=0
RENEW_TIMER_WAS_ACTIVE=0
YES=0
VERSION=""
QR_FILE=""
LAST_SERVICE_INVOCATION_ID=""
SERVICE_STARTED_AT=""

die() {
  printf '%s: %s\n' "${SCRIPT_NAME}" "$*" >&2
  exit 1
}

warn() {
  printf '%s: warning: %s\n' "${SCRIPT_NAME}" "$*" >&2
}

info() {
  printf '%s\n' "$*"
}

usage() {
  printf 'Installer revision: %s\n\n' "${SCRIPT_VERSION}"
  cat <<'EOF'
Hysteria 2 clean installer

Usage:
  install.sh [install] [options]
  install.sh update [--version v2.x.y]
  install.sh uninstall [--yes]
  install.sh start | stop | restart | status

Install options:
  --domain DOMAIN       Certificate domain (no default; prompt if omitted)
  --email EMAIL         ACME email (no default; prompt if omitted)
  --port PORT           Hysteria UDP port (1-65535; default: 443)
  --https-port PORT      Optional TCP HTTPS page (default: disabled)
                        Certificate issuance/renewal always uses TCP 80
  --password-stdin      Read a custom 12-128-character password from stdin (default: random 16)
  --no-masquerade       Do not create the local static masquerade page
  --version VERSION     Install a specific Hysteria version
  --yes                 Do not ask before replacing an existing config
  -h, --help            Show this help

The installer does not install Nginx, Docker, panels, BBR tuning, cron jobs,
or third-party masquerade proxies. Hysteria's own BBR congestion controller
is enabled in the generated configuration.
EOF
}

on_error() {
  local line="$1"
  printf '%s: failed at line %s\n' "${SCRIPT_NAME}" "${line}" >&2
}
trap 'on_error "$LINENO"' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 运行。"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1，请先安装它。"
}

install_prerequisites() {
  local packages=()
  command -v curl >/dev/null 2>&1 || packages+=(curl)
  command -v openssl >/dev/null 2>&1 || packages+=(openssl)
  command -v lego >/dev/null 2>&1 || packages+=(lego)
  command -v flock >/dev/null 2>&1 || packages+=(util-linux)
  command -v python3 >/dev/null 2>&1 || packages+=(python3)
  command -v timeout >/dev/null 2>&1 || packages+=(coreutils)
  command -v qrencode >/dev/null 2>&1 || packages+=(qrencode)
  command -v ss >/dev/null 2>&1 || packages+=(iproute2)
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)

  ((${#packages[@]} == 0)) && return 0

  if command -v apt-get >/dev/null 2>&1; then
    info "使用 apt-get 安装必要依赖：${packages[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates "${packages[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    local package
    local rpm_packages=()
    for package in "${packages[@]}"; do
      [[ "${package}" == "iproute2" ]] && package="iproute"
      rpm_packages+=("${package}")
    done
    info "使用 dnf 安装必要依赖：${packages[*]}"
    dnf install -y ca-certificates "${rpm_packages[@]}"
  elif command -v yum >/dev/null 2>&1; then
    local package
    local rpm_packages=()
    for package in "${packages[@]}"; do
      [[ "${package}" == "iproute2" ]] && package="iproute"
      rpm_packages+=("${package}")
    done
    info "使用 yum 安装必要依赖：${packages[*]}"
    yum install -y ca-certificates "${rpm_packages[@]}"
  else
    die "无法识别 apt-get、dnf 或 yum；请先安装 curl、openssl、qrencode 和 iproute2。"
  fi
}

parse_args() {
  local arg
  while (($#)); do
    arg="$1"
    case "${arg}" in
      install)
        ACTION="install"
        ;;
      update)
        ACTION="update"
        ;;
      uninstall|remove)
        ACTION="uninstall"
        ;;
      start|stop|restart|status)
        ACTION="${arg}"
        ;;
      --domain)
        (($# >= 2)) || die "--domain 需要参数。"
        DOMAIN="$2"
        shift
        ;;
      --email)
        (($# >= 2)) || die "--email 需要参数。"
        EMAIL="$2"
        shift
        ;;
      --port)
        (($# >= 2)) || die "--port 需要参数。"
        PORT="$2"
        shift
        ;;
      --password-stdin)
        PASSWORD_FROM_STDIN=1
        ;;
      --https-port)
        (($# >= 2)) || die "--https-port 需要参数。"
        HTTPS_PORT="$2"
        shift
        ;;
      --no-masquerade)
        NO_MASQUERADE=1
        ;;
      --version)
        (($# >= 2)) || die "--version 需要参数。"
        VERSION="$2"
        shift
        ;;
      --yes|-y)
        YES=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数：${arg}。使用 --help 查看用法。"
        ;;
    esac
    shift
  done
}

collect_install_identity() {
  [[ -n "${DOMAIN}" && -n "${EMAIL}" ]] && return 0
  local input_fd=0
  # A password pipe is reserved for the password. Missing identity fields
  # must come from the terminal, never from that pipe.
  if (( PASSWORD_FROM_STDIN )); then
    if ! { exec {input_fd}</dev/tty; } 2>/dev/null; then
      die "缺少域名或邮箱且没有交互终端；使用 --password-stdin 时请同时指定 --domain 和 --email。"
    fi
  fi
  if [[ -z "${DOMAIN}" ]] && ! IFS= read -r -u "${input_fd}" -p "域名: " DOMAIN; then
    die "未读取到域名，请使用 --domain 指定，已取消。"
  fi
  if [[ -z "${EMAIL}" ]] && ! IFS= read -r -u "${input_fd}" -p "ACME 邮箱: " EMAIL; then
    die "未读取到邮箱，请使用 --email 指定，已取消。"
  fi
  if (( input_fd != 0 )); then
    exec {input_fd}<&-
  fi
  [[ -n "${DOMAIN}" ]] || die "域名不能为空。"
  [[ -n "${EMAIL}" ]] || die "邮箱不能为空。"
}

validate_install_inputs() {
  [[ -n "${DOMAIN}" ]] || die "域名不能为空。"
  [[ -n "${EMAIL}" ]] || die "邮箱不能为空。"

  is_valid_domain "${DOMAIN}" || die "域名格式不正确：${DOMAIN}"
  if [[ ! "${EMAIL}" =~ ^[A-Za-z0-9.!_%+\-]+@[A-Za-z0-9.-]+$ ]]; then
    die "邮箱格式不正确：${EMAIL}"
  fi
  local email_local="${EMAIL%@*}"
  local email_domain="${EMAIL#*@}"
  [[ "${email_local}" != .* && "${email_local}" != *. && "${email_local}" != *..* ]] || die "邮箱格式不正确：${EMAIL}"
  is_valid_domain "${email_domain}" || die "邮箱域名格式不正确：${EMAIL}"
  validate_ports
  validate_version

  if ((PASSWORD_FROM_STDIN)); then
    if ! IFS= read -r PASSWORD && [[ -z "${PASSWORD}" ]]; then
      die "未从标准输入读取到密码，已取消。"
    fi
    [[ -n "${PASSWORD}" ]] || die "指定的密码不能为空；已取消，未生成替代密码。"
  fi
  if [[ -z "${PASSWORD}" ]]; then
    # 12 random bytes produce 16 URL-safe Base64 characters (96 bits).
    PASSWORD="$(openssl rand -base64 12 | tr '+/' '-_')"
  fi
  if [[ ! "${PASSWORD}" =~ ^[A-Za-z0-9._-]{12,128}$ ]]; then
    die "密码必须为 12-128 位，只能包含字母、数字、点、下划线或短横线；自动生成的密码为 16 位。"
  fi
}

validate_version() {
  if [[ -n "${VERSION}" && ! "${VERSION}" =~ ^v2\.[0-9]+\.[0-9]+$ ]]; then
    die "版本必须是 Hysteria 2 正式版本，格式类似 v2.12.3。"
  fi
}

is_valid_domain() {
  local name="$1"
  local label
  local labels=()
  [[ "${name}" != .* && "${name}" != *. && "${name}" != *..* ]] || return 1
  ((${#name} <= 220)) || return 1
  IFS='.' read -r -a labels <<<"${name}"
  ((${#labels[@]} >= 2)) || return 1
  for label in "${labels[@]}"; do
    [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
}

check_domain_resolution() {
  if ! command -v getent >/dev/null 2>&1; then
    warn "系统没有 getent，无法预检查 ${DOMAIN} 的 DNS；ACME 申请可能失败。"
  elif ! getent ahosts "${DOMAIN}" >/dev/null 2>&1; then
    die "当前 VM 无法解析 ${DOMAIN}。请先确认 DNS 已指向本机公网 IP。"
  fi
}

validate_ports() {
  [[ "${PORT}" =~ ^[0-9]{1,5}$ ]] || die "UDP 端口必须为 1-65535。"
  PORT=$((10#${PORT}))
  ((PORT >= 1 && PORT <= 65535)) || die "UDP 端口必须为 1-65535。"
  [[ "${HTTPS_PORT}" =~ ^[0-9]{1,5}$ ]] || die "HTTPS 端口必须为 0 或 1-65535。"
  HTTPS_PORT=$((10#${HTTPS_PORT}))
  ((HTTPS_PORT >= 0 && HTTPS_PORT <= 65535 && HTTPS_PORT != 80)) || die "HTTPS 端口不能为 80 或超出范围；0 表示关闭。"
  (( ! NO_MASQUERADE || HTTPS_PORT == 0 )) || die "--no-masquerade 不能与 --https-port 同时使用。"
}

port_in_use() { [[ -n "$(ss -H -ltn "sport = :$1")" ]]; }

check_listener_available() {
  local protocol="$1" port="$2" service_pid="" listeners
  service_pid="$(systemctl show -p MainPID --value "${SERVICE}" 2>/dev/null || true)"
  listeners="$(ss -H -ln"${protocol}"p "sport = :${port}")" || die "无法检查 ${protocol}/${port} 端口。"
  [[ -n "${listeners}" ]] || return 0
  if [[ "${service_pid}" =~ ^[1-9][0-9]*$ ]] &&
    ! grep -Fv "pid=${service_pid}," <<<"${listeners}" | grep -q .; then
    return 0
  fi
  die "${protocol}/${port} 已被其他进程占用；请选择其他端口，现有服务不会被停止。"
}

check_port_available() {
  check_listener_available u "${PORT}"
  ((HTTPS_PORT == 0)) || check_listener_available t "${HTTPS_PORT}"
}

load_installed_ports() {
  local values
  values="$(python3 - "${CONFIG_FILE}" <<'PYPORT'
import re, sys
text = open(sys.argv[1]).read()
def port(key, default):
    match = re.search(r'^' + key + r':\s*[\"\']?[^\n#]*?:([0-9]+)[\"\']?\s*(?:#.*)?$', text, re.M)
    if match:
        return int(match.group(1))
    if re.search(r'^' + key + r':', text, re.M):
        raise SystemExit('Unsupported listener; inspect config before updating')
    return default
print(port('listen', 443))
print(port(r'\s+listenHTTPS', 0))
PYPORT
)" || die "无法读取现有监听端口。"
  PORT="${values%%$'\n'*}"
  HTTPS_PORT="${values##*$'\n'}"
  validate_ports
}

download_official_installer() {
  local target="$1"
  if ! curl -q --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --connect-timeout 10 --max-time 120 --retry 2 --retry-delay 2 --retry-max-time 250 \
    "${OFFICIAL_INSTALLER_URL}" -o "${target}"; then
    rm -f -- "${target}"
    warn "官方安装器下载失败。"
    return 1
  fi
  if [[ ! -s "${target}" ]]; then
    rm -f -- "${target}"
    warn "官方安装器下载为空。"
    return 1
  fi
  if ! bash -n "${target}"; then
    rm -f -- "${target}"
    warn "官方安装器未通过 Bash 语法检查。"
    return 1
  fi
}

run_official_installer() {
  local temp_file
  temp_file="$(mktemp)"
  if ! download_official_installer "${temp_file}"; then
    rm -f "${temp_file}"
    return 1
  fi
  if [[ -n "${VERSION}" ]]; then
    if ! bash "${temp_file}" --version "${VERSION}"; then
      rm -f "${temp_file}"
      return 1
    fi
  else
    if ! bash "${temp_file}"; then
      rm -f "${temp_file}"
      return 1
    fi
  fi
  rm -f "${temp_file}"
}

check_service_policy_path() {
  [[ ! -L "${SERVICE_DROPIN_DIR}" && ! -L "${SERVICE_POLICY_FILE}" ]] || \
    die "服务恢复配置路径是符号链接，拒绝覆盖：${SERVICE_POLICY_FILE}"
  [[ ! -e "${SERVICE_DROPIN_DIR}" || -d "${SERVICE_DROPIN_DIR}" ]] || \
    die "服务恢复配置目录被其他文件占用：${SERVICE_DROPIN_DIR}"
  if [[ -e "${SERVICE_POLICY_FILE}" ]] && \
    { [[ ! -f "${SERVICE_POLICY_FILE}" ]] || ! grep -Fxq -- "${SERVICE_POLICY_MARKER}" "${SERVICE_POLICY_FILE}"; }; then
    die "服务恢复配置不是本安装器管理的文件，请先备份并移走：${SERVICE_POLICY_FILE}"
  fi
}

write_service_policy() {
  check_service_policy_path
  install -d -m 0755 "${SERVICE_DROPIN_DIR}"
  local policy_tmp
  policy_tmp="$(mktemp "${SERVICE_DROPIN_DIR}/.recovery.XXXXXX")"
  if ! cat >"${policy_tmp}" <<EOF
${SERVICE_POLICY_MARKER}
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Restart=on-failure
RestartSec=5s
MemoryAccounting=true
EOF
  then
    rm -f -- "${policy_tmp}"
    return 1
  fi
  if ! chmod 0644 "${policy_tmp}" || ! mv -f -- "${policy_tmp}" "${SERVICE_POLICY_FILE}"; then
    rm -f -- "${policy_tmp}"
    return 1
  fi
}

remove_service_policy() {
  if [[ ! -L "${SERVICE_DROPIN_DIR}" && ! -L "${SERVICE_POLICY_FILE}" && -f "${SERVICE_POLICY_FILE}" ]] && \
    grep -Fxq -- "${SERVICE_POLICY_MARKER}" "${SERVICE_POLICY_FILE}"; then
    rm -f -- "${SERVICE_POLICY_FILE}"
    # Leave administrator-provided drop-ins and nonempty directories intact.
    rmdir -- "${SERVICE_DROPIN_DIR}" 2>/dev/null || true
  elif [[ -e "${SERVICE_POLICY_FILE}" || -L "${SERVICE_POLICY_FILE}" || -L "${SERVICE_DROPIN_DIR}" ]]; then
    warn "已保留非本安装器管理的服务恢复配置：${SERVICE_POLICY_FILE}"
  fi
}

backup_config() {
  [[ -f "${CONFIG_FILE}" ]] || return 0
  install -d -m 0700 "${BACKUP_DIR}"
  local backup
  backup="$(mktemp "${BACKUP_DIR}/config-XXXXXXXX.yaml")"
  cp -p "${CONFIG_FILE}" "${backup}"
  info "已备份现有配置：${backup}"
}

state_owns_directory() {
  local key="$1"
  [[ -f "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] &&
    grep -qx 'state_version=2' "${STATE_FILE}" &&
    grep -qx "${key}=1" "${STATE_FILE}"
}

write_masquerade_page() {
  ((NO_MASQUERADE)) && return 0
  install -d -o hysteria -g hysteria -m 0755 "${MASQUERADE_DIR}"
  local page
  page="$(mktemp)"
  if ! cat >"${page}" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>${DEFAULT_PAGE_TEXT}</title></head>
<body>${DEFAULT_PAGE_TEXT}</body>
</html>
EOF
  then
    rm -f "${page}"
    return 1
  fi
  if ! install -o hysteria -g hysteria -m 0644 "${page}" "${MASQUERADE_DIR}/index.html"; then
    rm -f "${page}"
    return 1
  fi
  rm -f "${page}"
}

sync_certificate() {
  local cert="${LEGO_DIR}/certificates/${DOMAIN}.crt" key="${LEGO_DIR}/certificates/${DOMAIN}.key"
  [[ -s "${cert}" && -s "${key}" ]] || die "Let’s Encrypt 证书文件不完整。"
  install -d -o root -g hysteria -m 0750 "${CONFIG_DIR}"
  install -o root -g hysteria -m 0644 "${cert}" "${CERT_FILE}.new"
  install -o root -g hysteria -m 0640 "${key}" "${KEY_FILE}.new"
  mv -f "${CERT_FILE}.new" "${CERT_FILE}"
  mv -f "${KEY_FILE}.new" "${KEY_FILE}"
}

cert_valid() {
  local cert="${LEGO_DIR}/certificates/${DOMAIN}.crt" key="${LEGO_DIR}/certificates/${DOMAIN}.key" cert_pub key_pub
  [[ -s "${cert}" && -s "${key}" ]] || return 1
  openssl x509 -in "${cert}" -noout -checkend 2592000 >/dev/null 2>&1 || return 1
  # x509 -checkhost may return success even on a hostname mismatch.
  openssl verify -trusted "${cert}" -partial_chain -verify_hostname "${DOMAIN}" "${cert}" >/dev/null 2>&1 || return 1
  cert_pub="$(openssl x509 -in "${cert}" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)" || return 1
  key_pub="$(openssl pkey -in "${key}" -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)" || return 1
  [[ -n "${cert_pub}" && "${cert_pub}" == "${key_pub}" ]]
}

obtain_certificate() {
  if ! cert_valid; then CERT_CREATED=1; fi
  (
    exec 9>"${ACME_LOCK}"
    flock -w 300 9 || die "等待另一协议的证书操作超时，请稍后重试。"
    obtain_certificate_locked
  )
}

obtain_certificate_locked() {
  install -d -o root -g root -m 0700 "${LEGO_DIR}"
  if cert_valid; then
    info "复用仍有效的 Let’s Encrypt 证书。"
    sync_certificate
    return 0
  fi
  if port_in_use 80; then
    die "TCP 80 已被其他进程占用；HTTP-01 需要此端口，安装器不会停止该进程。"
  fi
  CERT_CREATED=1
  local attempt=0 log="$(mktemp)" status=0 acme_action=run
  if [[ -s "${LEGO_DIR}/certificates/${DOMAIN}.crt" && -s "${LEGO_DIR}/certificates/${DOMAIN}.key" ]]; then
    acme_action=renew
  fi
  while ((attempt < 3)); do
    ((attempt += 1))
    if [[ "${acme_action}" == renew ]]; then
      info "续期 Let’s Encrypt HTTP-01 证书（第 ${attempt}/3 次，需要 TCP 80）..."
    else
      info "申请 Let’s Encrypt HTTP-01 证书（第 ${attempt}/3 次，需要 TCP 80）..."
    fi
    status=0
    if [[ "${acme_action}" == renew ]]; then
      timeout 180s "${LEGO_BIN}" --path "${LEGO_DIR}" --domains "${DOMAIN}" --http renew --days 30 >"${log}" 2>&1 || status=$?
    else
      timeout 180s "${LEGO_BIN}" --accept-tos --path "${LEGO_DIR}" --email "${EMAIL}" \
        --domains "${DOMAIN}" --http run >"${log}" 2>&1 || status=$?
    fi
    if ((status == 0)) && cert_valid; then
      cat "${log}"
      rm -f "${log}"
      sync_certificate
      return 0
    fi
    cat "${log}" >&2
    if grep -Eiq 'rate.?limit|too many|retry.?after' "${log}"; then
      rm -f "${log}"
      die "证书申请触发 CA 速率限制；请等待后再试，安装已中断。"
    fi
    if grep -Eiq 'Fetching http://.*(Timeout during connect|Connection refused)' "${log}"; then
      rm -f "${log}"
      warn "HTTP-01 验证连接超时或被拒绝；请核对 ${DOMAIN} 的解析与 VM 公网 IP。"
      warn "确认公网入站 TCP 80 已放行，GCP 规则匹配该 VM 的 VPC/网络标记，主机防火墙也允许；--port ${PORT} 不改变证书验证端口。"
      die "请修复 TCP 80 可达性后重新运行安装命令，避免连续申请失败；未生成连接信息。"
    fi
    if ((attempt >= 3)); then
      rm -f "${log}"
      die "证书申请连续失败 3 次，安装已中断。"
    fi
    local answer
    if [[ -t 0 ]]; then
      read -r -p "证书申请失败，请先检查并处理上面的错误。1. 重试  2. 中断: " answer || answer=2
    else
      answer=2
    fi
    [[ "${answer}" == 1 ]] || { rm -f "${log}"; die "已中断，未生成连接信息。"; }
    sleep $((attempt * 5))
  done
}

render_renewal_script() {
  printf '#!/usr/bin/env bash\nset -Eeuo pipefail\numask 077\n'
  printf '%s=%q\n' domain "${DOMAIN}" lego_dir "${LEGO_DIR}" \
    cert_file "${CERT_FILE}" key_file "${KEY_FILE}" lego_bin "${LEGO_BIN}" \
    pending_file "${STATE_DIR}/certificate-reload.pending" \
    lock_file "${ACME_LOCK}"
  # Only the header is expanded here. Runtime variables must remain literal.
  cat <<'EOF'
exec 9>"${lock_file}"
flock -w 300 9 || { echo 'HTTP-01 lock timeout; retry later' >&2; exit 1; }
cert="${lego_dir}/certificates/${domain}.crt"
key="${lego_dir}/certificates/${domain}.key"
valid_pair() {
  local seconds="$1" cert_pub key_pub
  [[ -s "${cert}" && -s "${key}" ]] || return 1
  openssl x509 -in "${cert}" -noout -checkend "${seconds}" >/dev/null 2>&1 || return 1
  openssl verify -trusted "${cert}" -partial_chain -verify_hostname "${domain}" "${cert}" >/dev/null 2>&1 || return 1
  cert_pub="$(openssl x509 -in "${cert}" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)" || return 1
  key_pub="$(openssl pkey -in "${key}" -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)" || return 1
  [[ -n "${cert_pub}" && "${cert_pub}" == "${key_pub}" ]]
}
if ! valid_pair 2592000; then
  # HTTP-01 always uses TCP 80, independent of the Hysteria UDP port.
  # Never stop either proxy to renew a certificate.
  timeout 180s "${lego_bin}" --path "${lego_dir}" --domains "${domain}" --http renew --days 30
fi
valid_pair 0 || { echo 'hysteria-cert-renew: invalid certificate/key; keeping deployed files' >&2; exit 1; }
if cmp -s "${cert}" "${cert_file}" && cmp -s "${key}" "${key_file}" && [[ ! -e "${pending_file}" ]]; then
  exit 0
fi
# Also retry deployment when lego already renewed but a previous copy/reload failed.
touch "${pending_file}"
trap 'rm -f "${cert_file}.new" "${key_file}.new"' EXIT
install -o root -g hysteria -m 0644 "${cert}" "${cert_file}.new"
install -o root -g hysteria -m 0640 "${key}" "${key_file}.new"
mv -f "${cert_file}.new" "${cert_file}"
mv -f "${key_file}.new" "${key_file}"
# Hysteria reads the TLS files on each new handshake. No service restart.
rm -f "${pending_file}"
EOF
}

write_renewal_service() {
  [[ -n "${LEGO_BIN}" && -x "${LEGO_BIN}" ]] || die "未找到 lego，可先执行 apt-get install lego。"
  render_renewal_script >"${RENEW_SCRIPT}"
  bash -n "${RENEW_SCRIPT}"
  chmod 0750 "${RENEW_SCRIPT}"
  cat >"/etc/systemd/system/${RENEW_SERVICE}" <<EOF
[Unit]
Description=Renew Hysteria TLS certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=600s
ExecStart=${RENEW_SCRIPT}
EOF
  cat >"/etc/systemd/system/${RENEW_TIMER}" <<EOF
[Unit]
Description=Daily Hysteria TLS certificate renewal check

[Timer]
OnCalendar=*-*-* 03:47:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable "${RENEW_TIMER}" >/dev/null
}

write_config() {
  install -d -m 0755 "${CONFIG_DIR}"
  local config_tmp
  config_tmp="$(mktemp "${CONFIG_DIR}/.config.yaml.XXXXXX")"
  if ! cat >"${config_tmp}" <<EOF
listen: :${PORT}

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}

auth:
  type: password
  password: '${PASSWORD}'

congestion:
  type: bbr
EOF
  then
    rm -f "${config_tmp}"
    return 1
  fi
  if (( ! NO_MASQUERADE )); then
    if ! cat >>"${config_tmp}" <<EOF

masquerade:
  type: file
  file:
    dir: ${MASQUERADE_DIR}
EOF
    then
      rm -f "${config_tmp}"
      return 1
    fi
  fi
  if ((HTTPS_PORT > 0)); then
    printf '  listenHTTPS: :%s\n' "${HTTPS_PORT}" >>"${config_tmp}"
  fi
  if ! chown root:hysteria "${config_tmp}"; then
    rm -f "${config_tmp}"
    return 1
  fi
  if ! chmod 0640 "${config_tmp}"; then
    rm -f "${config_tmp}"
    return 1
  fi
  if ! mv -f "${config_tmp}" "${CONFIG_FILE}"; then
    rm -f "${config_tmp}"
    return 1
  fi
}

print_connection_info() {
  local uri="hysteria2://${PASSWORD}@${DOMAIN}:${PORT}/?sni=${DOMAIN}#hy2"
  QR_FILE="/root/hysteria2-${DOMAIN}.png"
  printf 'Hysteria 2\nDomain: %s\nPort: %s\nPassword: %s\nSNI: %s\nURI: %s\n' \
    "${DOMAIN}" "${PORT}" "${PASSWORD}" "${DOMAIN}" "${uri}" \
    >"/root/hysteria2-${DOMAIN}.txt"
  chmod 0600 "/root/hysteria2-${DOMAIN}.txt"

  info ""
  info "服务器安装、本机证书校验和 Hysteria 代理访问测试通过。"
  warn "公网 UDP 入站及客户端连通性尚未验证，请在 Shadowrocket 中实际连接确认。"
  info "域名: ${DOMAIN}"
  info "端口: ${PORT}（UDP/QUIC；证书签发和续期需要 TCP 80）"
  if (( ! NO_MASQUERADE && HTTPS_PORT > 0)); then
    info "静态页: https://${DOMAIN}:${HTTPS_PORT}/（TCP HTTPS）"
  elif (( ! NO_MASQUERADE )); then
    info "静态页仅通过 HTTP/3 提供；未额外占用 TCP HTTPS 端口。"
  fi
  info "密码: ${PASSWORD}"
  info "SNI: ${DOMAIN}"
  info "Shadowrocket URI（可手动导入）:"
  info "${uri}"
  if command -v qrencode >/dev/null 2>&1; then
    if printf '%s' "${uri}" | qrencode -o "${QR_FILE}" -m 1 -s 4; then
      chmod 0600 "${QR_FILE}"
      info "二维码 PNG 已保存：${QR_FILE}（权限 600）"
      info "请直接放大下方终端二维码，用 Shadowrocket 扫描："
      if ! printf '%s' "${uri}" | qrencode -t UTF8 -m 1; then
        warn "终端二维码显示失败，但 PNG 和 URI 文件已保存。"
      fi
    else
      warn "二维码 PNG 生成失败；URI 已保存到 /root/hysteria2-${DOMAIN}.txt。"
    fi
  else
    warn "未找到 qrencode，无法显示二维码；URI 已保存到 /root/hysteria2-${DOMAIN}.txt。"
  fi
  info ""
  info "请保持 Google Cloud 防火墙放行 TCP 80 和 UDP ${PORT}。"
  ((HTTPS_PORT == 0)) || info "另需放行静态页 TCP ${HTTPS_PORT}。"
}

select_selftest_port() {
  local attempt candidate listeners
  # Check all bind addresses, not only loopback. A later PID ownership check
  # also protects against a port being taken between this check and bind().
  if ! listeners="$(ss -H -ltn 2>/dev/null)"; then
    return 1
  fi
  for ((attempt = 0; attempt < 40; attempt++)); do
    candidate=$((20000 + (RANDOM * 2 + RANDOM) % 40000))
    if ! awk -v port=":${candidate}" \
      '$4 ~ (port "$") || $5 ~ (port "$") { found=1 } END { exit !found }' <<<"${listeners}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

selftest_client_owns_listener() {
  local client_pid="$1" client_port="$2"
  [[ "${client_pid}" =~ ^[1-9][0-9]*$ && "${client_port}" =~ ^[0-9]+$ ]] || return 1
  ss -H -ltnp 2>/dev/null | awk -v address="127.0.0.1:${client_port}" -v owner="pid=${client_pid}," \
    '$1 == "LISTEN" && $4 == address && index($0, owner) { found=1 } END { exit !found }'
}

print_selftest_log() {
  local log_file="$1" line
  [[ -r "${log_file}" ]] || return 0
  # Replace the literal secret, including any occurrences outside JSON fields.
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -n "${PASSWORD}" ]]; then
      line="${line//"${PASSWORD}"/[REDACTED]}"
    fi
    printf '%s\n' "${line}" >&2
  done < <(tail -n 40 -- "${log_file}")
}

local_connection_selftest() (
  # A subshell keeps traps and exit handling separate from the caller's shell.
  # Every fallible step is checked explicitly: this function is called by !,
  # which disables Bash errexit even inside nested functions/subshells.
  trap - ERR
  local selftest_dir="" client_pid="" client_port="" http_code="" attempt ready=0
  cleanup_selftest() {
    local cleanup_attempt
    if [[ -n "${client_pid}" ]]; then
      kill "${client_pid}" 2>/dev/null || true
      for ((cleanup_attempt = 0; cleanup_attempt < 10; cleanup_attempt++)); do
        kill -0 "${client_pid}" 2>/dev/null || break
        sleep 0.2
      done
      kill -KILL "${client_pid}" 2>/dev/null || true
      wait "${client_pid}" 2>/dev/null || true
    fi
    [[ -z "${selftest_dir}" ]] || rm -rf -- "${selftest_dir}"
  }
  trap cleanup_selftest EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [[ ! -x /usr/local/bin/hysteria ]]; then
    warn "本机自测失败：找不到 /usr/local/bin/hysteria；未生成连接信息或二维码。"
    exit 1
  fi
  if ! selftest_dir="$(mktemp -d /tmp/hysteria2-selftest.XXXXXXXX)"; then
    warn "无法创建本机自测临时目录；未生成连接信息或二维码。"
    exit 1
  fi

  if (( ! NO_MASQUERADE && HTTPS_PORT > 0)); then
    info "检查本机 HTTPS 证书、域名和静态页面..."
    if ! http_code="$(curl -q --proto '=https' --tlsv1.2 --noproxy '*' \
      --silent --show-error --connect-timeout 5 --max-time 15 \
      --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
      --output "${selftest_dir}/page.html" --write-out '%{http_code}' \
      "https://${DOMAIN}:${HTTPS_PORT}/" 2>"${selftest_dir}/https.log")"; then
      warn "本机 HTTPS 自测失败：检查证书信任、域名和 TCP ${HTTPS_PORT} 监听；未生成连接信息或二维码。"
      print_selftest_log "${selftest_dir}/https.log"
      exit 1
    fi
    if [[ "${http_code}" != 200 ]] || ! grep -Fq -- "<body>${DEFAULT_PAGE_TEXT}</body>" "${selftest_dir}/page.html"; then
      warn "本机 HTTPS 页面自测失败（HTTP ${http_code} 或页面内容不符）；未生成连接信息或二维码。"
      exit 1
    fi
  fi

  if ! client_port="$(select_selftest_port)"; then
    warn "无法为本机自测选择空闲端口；未生成连接信息或二维码。"
    exit 1
  fi
  # The .yaml suffix is required by Hysteria's config format detection.
  if ! cat >"${selftest_dir}/client.yaml" <<EOF
server: 127.0.0.1:${PORT}
auth: '${PASSWORD}'
tls:
  sni: ${DOMAIN}
socks5:
  listen: 127.0.0.1:${client_port}
EOF
  then
    warn "无法写入本机自测配置；未生成连接信息或二维码。"
    exit 1
  fi
  info "检查本机 Hysteria 认证和代理出站（HTTPS Google 204）..."
  /usr/local/bin/hysteria client -c "${selftest_dir}/client.yaml" \
    >"${selftest_dir}/client.log" 2>&1 &
  client_pid=$!
  for ((attempt = 0; attempt < 10; attempt++)); do
    if ! kill -0 "${client_pid}" 2>/dev/null; then
      break
    fi
    if selftest_client_owns_listener "${client_pid}" "${client_port}"; then
      ready=1
      break
    fi
    sleep 1
  done
  if (( ! ready )); then
    warn "本机 Hysteria 客户端未就绪：检查下方配置、证书或认证错误；未生成连接信息或二维码。"
    print_selftest_log "${selftest_dir}/client.log"
    exit 1
  fi
  # -q ignores curlrc, and an empty noproxy prevents environment NO_PROXY
  # settings from bypassing SOCKS. DNS resolution also travels via Hysteria.
  if ! http_code="$(curl -q --proto '=https' --tlsv1.2 --noproxy '' \
    --socks5-hostname "127.0.0.1:${client_port}" \
    --silent --show-error --connect-timeout 5 --max-time 15 \
    --retry 1 --retry-delay 1 --retry-max-time 31 \
    --output /dev/null --write-out '%{http_code}' \
    https://www.google.com/generate_204 2>"${selftest_dir}/proxy.log")"; then
    warn "本机 Hysteria 代理出站失败：检查下方认证、证书、DNS 或外网访问错误；未生成连接信息或二维码。"
    print_selftest_log "${selftest_dir}/client.log"
    print_selftest_log "${selftest_dir}/proxy.log"
    exit 1
  fi
  if [[ "${http_code}" != 204 ]]; then
    warn "本机代理测试返回 HTTP ${http_code}，预期为 204；检查 VM 出站和 DNS，未生成连接信息或二维码。"
    print_selftest_log "${selftest_dir}/client.log"
    exit 1
  fi
  if ! kill -0 "${client_pid}" 2>/dev/null || \
    ! selftest_client_owns_listener "${client_pid}" "${client_port}"; then
    warn "本机自测客户端异常退出；未生成连接信息或二维码。"
    print_selftest_log "${selftest_dir}/client.log"
    exit 1
  fi
  info "本机 Hysteria 代理自测通过：HTTP 204（公网 UDP 入站仍需外部客户端验证）。"
)

service_port_is_listening() {
  local service_pid
  service_pid="$(systemctl show -p MainPID --value "${SERVICE}" 2>/dev/null)" || return 1
  [[ "${service_pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  # Verify the socket belongs to this service, not an unrelated UDP listener.
  ss -H -lunp 2>/dev/null | awk -v port=":${PORT}" -v owner="pid=${service_pid}," \
    '$1 == "UNCONN" && ($4 ~ (port "$") || $5 ~ (port "$")) && index($0, owner) { found=1 } END { exit !found }'
}

service_masquerade_tcp_expected() {
  ((HTTPS_PORT > 0))
}

service_tcp_port_is_listening() {
  service_masquerade_tcp_expected || return 0
  local service_pid
  service_pid="$(systemctl show -p MainPID --value "${SERVICE}" 2>/dev/null)" || return 1
  [[ "${service_pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  # TCP and UDP may share the numeric port; verify the TCP listener belongs to
  # the current Hysteria process rather than an unrelated web server.
  ss -H -ltnp 2>/dev/null | awk -v port=":${HTTPS_PORT}" -v owner="pid=${service_pid}," \
    '$1 == "LISTEN" && ($4 ~ (port "$") || $5 ~ (port "$")) && index($0, owner) { found=1 } END { exit !found }'
}

service_invocation_logs() {
  local invocation_id="$1"
  if [[ -n "${invocation_id}" ]]; then
    journalctl -u "${SERVICE}" _SYSTEMD_INVOCATION_ID="${invocation_id}" \
      --no-pager -n 100 2>/dev/null || true
  else
    [[ -n "${SERVICE_STARTED_AT}" ]] || return 0
    journalctl -u "${SERVICE}" --since "${SERVICE_STARTED_AT}" --no-pager -n 100 2>/dev/null || true
  fi
}

service_logs_match() {
  local invocation_id="$1"
  local pattern="$2"
  service_invocation_logs "${invocation_id}" | grep -Ei -- "${pattern}" >/dev/null
}

service_failure_kind() {
  local invocation_id="$1"
  # Match actual failures, not INFO messages such as certificate maintenance
  # or waiting on the ACME internal rate limiter. The generic config wrapper
  # must come after the underlying ACME cause.
  if service_logs_match "${invocation_id}" \
    'yaml:|yaml (parse|syntax|unmarshal)|unknown field|permission denied|address already in use|bind:|cannot bind'; then
    printf '%s' hard
  elif service_logs_match "${invocation_id}" \
    'timeout during connect|likely firewall|connection refused|no valid (a|aaaa) records|no such host|temporary failure in name resolution|network is unreachable|network unreachable|no route to host|nxdomain|servfail|dns[^[:alnum:]]*(problem|error)|(^|[^[:alnum:]])caa([^[:alnum:]]|$)|rate.?limited|too many (requests|certificates|failed|new)|retry[- ]after|rejectedidentifier|unauthorized'; then
    printf '%s' hard
  elif service_logs_match "${invocation_id}" \
    'challenge failed|authorization failed|could not get certificate|bad.?nonce|server.?internal|service.?unavailable|connection reset|i/o timeout|context deadline exceeded|http (500|502|503|504)|urn:ietf:params:acme:error:'; then
    printf '%s' acme
  elif service_logs_match "${invocation_id}" 'failed to load server config|invalid config'; then
    printf '%s' hard
  else
    printf '%s' other
  fi
}

explain_service_failure() {
  local invocation_id="$1"
  if service_logs_match "${invocation_id}" 'address already in use|bind:|cannot bind'; then
    warn "端口绑定失败：请用 ss -lntup 检查所选 TCP/UDP 端口占用者；脚本不会停止其他服务。"
  elif service_logs_match "${invocation_id}" 'permission denied'; then
    warn "服务权限不足：请按日志中的路径检查 hysteria 用户读取配置、写入证书目录及绑定端口的权限。"
  elif service_logs_match "${invocation_id}" 'rate.?limited|too many (requests|certificates|failed|new)|retry[- ]after'; then
    warn "证书机构要求等待：请遵守日志中的 retry after/Retry-After 时间；重装或删除证书缓存不能解除限额。"
  elif service_logs_match "${invocation_id}" 'timeout during connect|likely firewall|connection refused'; then
    warn "证书验证连接失败：请确认域名指向本机，并在 Google Cloud 和系统防火墙放行证书所需 TCP 80（旧 TLS-ALPN 配置仍需 TCP 443）；同时放行客户端所需 UDP ${PORT}，确保规则目标包含此 VM。"
  elif service_logs_match "${invocation_id}" 'nxdomain|servfail|dns[^[:alnum:]]*(problem|error)|no valid (a|aaaa) records|no such host|name resolution|(^|[^[:alnum:]])caa([^[:alnum:]]|$)|rejectedidentifier|unauthorized'; then
    warn "域名验证失败：检查 A/AAAA 是否指向此 VM、CAA 是否允许 letsencrypt.org，关闭域名代理；更正后再运行安装。"
  elif service_logs_match "${invocation_id}" 'network is unreachable|network unreachable|no route to host'; then
    warn "网络路由不可达：检查 VM 的公网出口、路由和出站防火墙。"
  elif [[ "$(service_failure_kind "${invocation_id}")" == acme ]]; then
    warn "证书申请遇到可能暂时的错误；可重启服务重试，并保留现有证书和 ACME 账户缓存。"
  elif service_logs_match "${invocation_id}" 'invalid config|failed to load server config|yaml:|unknown field'; then
    warn "配置加载失败：请根据上方日志修正配置；脚本不会盲目反复申请证书。"
  else
    warn "服务未就绪或缺少本服务的 UDP/TCP ${PORT} 监听；无法确认可用，停止安装。"
  fi
}

prompt_certificate_repair() {
  local attempt="$1"
  local answer="" input_fd
  if [[ -t 0 ]]; then
    exec {input_fd}<&0
  elif ! { exec {input_fd}</dev/tty; } 2>/dev/null; then
    warn "没有可交互的终端，无法选择修复；安装已中断。"
    return 1
  fi
  while :; do
    printf '请选择：1. 修复并重试（第 %s/3 次）  2. 中断: ' "${attempt}" >&2
    if ! read -r -u "${input_fd}" answer; then
      exec {input_fd}<&-
      return 1
    fi
    case "${answer}" in
      1) exec {input_fd}<&-; return 0 ;;
      2) exec {input_fd}<&-; return 1 ;;
      *) warn "请输入 1 或 2。" ;;
    esac
  done
}

wait_for_service_with_recovery() {
  local repair_attempts=0
  local failure_kind=""
  local invocation_id=""

  while :; do
    LAST_SERVICE_INVOCATION_ID=""
    if wait_for_service_stable; then
      return 0
    fi

    invocation_id="${LAST_SERVICE_INVOCATION_ID}"
    [[ -n "${invocation_id}" ]] || invocation_id="$(service_current_invocation)"
    failure_kind="$(service_failure_kind "${invocation_id}")"
    show_service_diagnostics "${invocation_id}"
    # Stop pending ACME work before asking the user or exiting.
    if ! systemctl stop "${SERVICE}"; then
      warn "无法停止失败的服务；请先手动检查 systemctl status ${SERVICE}。"
      return 1
    fi

    case "${failure_kind}" in
      hard)
        warn "该问题无法通过重试可靠修复；安装已中断。"
        return 1
        ;;
      acme)
        if ((repair_attempts >= 3)); then
          warn "证书自动修复已达到 3 次上限；安装已中断。"
          return 1
        fi
        if ! prompt_certificate_repair "$((repair_attempts + 1))"; then
          warn "已选择中断，未生成可用的连接二维码。"
          return 1
        fi
        ((repair_attempts += 1))
        info "$((repair_attempts * 5)) 秒后重启服务并重试证书申请（第 ${repair_attempts}/3 次）..."
        sleep "$((repair_attempts * 5))"
        SERVICE_STARTED_AT="$(date --iso-8601=seconds)"
        systemctl reset-failed "${SERVICE}" >/dev/null 2>&1 || true
        if ! systemctl restart "${SERVICE}"; then
          warn "服务重启请求失败，将继续读取日志判断是否还能修复。"
        fi
        ;;
      *)
        warn "未识别的服务启动失败；为避免输出可能不可用的凭据，安装已中断。"
        return 1
        ;;
    esac
  done
}

service_current_invocation() {
  local invocation_id
  invocation_id="$(systemctl show -p InvocationID --value "${SERVICE}" 2>/dev/null || true)"
  [[ "${invocation_id}" == "n/a" ]] && return 0
  printf '%s' "${invocation_id}"
}

service_has_startup_error() {
  local invocation_id="$1"
  service_invocation_logs "${invocation_id}" | grep -Ei \
    'FATAL|challenge failed|authorization failed|could not get certificate|failed to load server config|failed with result|Main process exited' >/dev/null
}

quarantine_connection_artifacts() {
  local artifact kind target suffix
  for kind in png txt; do
    artifact="/root/hysteria2-${DOMAIN}.${kind}"
    [[ -e "${artifact}" || -L "${artifact}" ]] || continue
    install -d -m 0700 "${BACKUP_DIR}"
    suffix="$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
    target="${BACKUP_DIR}/hysteria2-${DOMAIN}.stale-${suffix}.${kind}"
    while [[ -e "${target}" || -L "${target}" ]]; do
      suffix="$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
      target="${BACKUP_DIR}/hysteria2-${DOMAIN}.stale-${suffix}.${kind}"
    done
    if mv -- "${artifact}" "${target}"; then
      [[ -L "${target}" ]] || chmod 0600 "${target}"
      warn "已将旧连接文件移到 ${target}；本次安装完成前不要使用旧二维码或 URI。"
    else
      warn "无法移走旧连接文件 ${artifact}；本次安装失败时不要使用它。"
    fi
  done
}

show_service_diagnostics() {
  local invocation_id="$1"
  warn "${SERVICE} 未能通过启动检查。最近一次启动日志："
  service_invocation_logs "${invocation_id}" >&2
  explain_service_failure "${invocation_id}"
  warn "本次未生成新的连接信息或二维码。"

}

restore_renewal_timer() {
  local status="$1"
  if ((status != 0 && RENEW_TIMER_WAS_ACTIVE)); then
    systemctl start "${RENEW_TIMER}" >/dev/null 2>&1 || warn "请检查原证书续期 timer：${RENEW_TIMER}。"
  fi
}

pause_renewal_for_install() {
  RENEW_TIMER_WAS_ACTIVE=0
  if systemctl is-active --quiet "${RENEW_TIMER}"; then
    RENEW_TIMER_WAS_ACTIVE=1
  fi
  trap 'restore_renewal_timer "$?"' EXIT
  if ((RENEW_TIMER_WAS_ACTIVE)); then
    systemctl stop "${RENEW_TIMER}" || die "无法暂停本协议的证书续期 timer。"
  fi
  if systemctl is-active --quiet "${RENEW_SERVICE}"; then
    systemctl stop "${RENEW_SERVICE}" || die "无法暂停本协议正在执行的证书续期任务。"
  fi
}

install_hysteria() {
  require_root
  info "安装器版本：${SCRIPT_VERSION}"
  collect_install_identity
  install_prerequisites
  require_command curl
  require_command openssl
  require_command systemctl
  require_command journalctl
  require_command ss
  require_command lego
  require_command flock
  require_command python3
  require_command timeout
  LEGO_BIN="$(command -v lego)"
  [[ -d /run/systemd/system ]] || die "此系统没有运行 systemd；请使用 Debian/Ubuntu/Rocky 等标准 VM 镜像。"
  validate_install_inputs

  if [[ -f "${CONFIG_FILE}" && "${YES}" -ne 1 ]]; then
    if ! read -r -p "已有 ${CONFIG_FILE}，备份后覆盖？[y/N] " answer; then
      die "已取消。"
    fi
    [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消。"
  fi

  # Quarantine stale credentials before any network/port preflight can stop
  # the run, so a failed check cannot leave an old QR in the expected path.
  quarantine_connection_artifacts
  check_domain_resolution
  check_port_available
  check_service_policy_path

  backup_config
  local user_preexisted=1
  local home_owned=0
  local masquerade_owned=0
  if [[ -r "${STATE_FILE}" ]] && grep -qx 'user_preexisted=0' "${STATE_FILE}"; then
    user_preexisted=0
  elif ! id hysteria >/dev/null 2>&1; then
    user_preexisted=0
  fi
  if state_owns_directory home_owned || [[ ! -e "${HYSTERIA_HOME_DIR}" && ! -L "${HYSTERIA_HOME_DIR}" ]]; then
    home_owned=1
  fi
  if state_owns_directory masquerade_owned; then
    masquerade_owned=1
  elif (( ! NO_MASQUERADE )) && [[ ! -e "${MASQUERADE_DIR}" && ! -L "${MASQUERADE_DIR}" ]]; then
    masquerade_owned=1
  fi
  if (( ! NO_MASQUERADE && ! masquerade_owned )) && [[ -e "${MASQUERADE_DIR}/index.html" ]]; then
    die "检测到未由本安装器创建的 ${MASQUERADE_DIR}/index.html；为避免覆盖现有页面，请使用 --no-masquerade 或先自行备份/移除该文件。"
  fi
  info "安装官方程序和 systemd 服务（此阶段成功仅代表程序已安装，随后仍需启动检查）..."
  run_official_installer
  id hysteria >/dev/null 2>&1 || die "官方安装器没有创建 hysteria 服务用户。"
  install -d -m 0700 "${STATE_DIR}"
  printf 'state_version=2\nuser_preexisted=%s\nhome_owned=%s\nmasquerade_owned=%s\n' \
    "${user_preexisted}" "${home_owned}" "${masquerade_owned}" >"${STATE_FILE}"
  chmod 0600 "${STATE_FILE}"
  if ((NO_MASQUERADE && masquerade_owned)); then
    rm -rf "${MASQUERADE_DIR}"
  fi
  info "请放行公网 TCP 80（证书）和 UDP ${PORT}（Hysteria）。"
  pause_renewal_for_install
  obtain_certificate
  write_masquerade_page
  write_config
  write_renewal_service
  write_service_policy
  systemctl daemon-reload
  systemctl enable "${SERVICE}"
  SERVICE_STARTED_AT="$(date --iso-8601=seconds)"
  if systemctl is-active --quiet "${SERVICE}"; then
    if ! systemctl restart "${SERVICE}"; then
      warn "服务重启请求失败，将继续读取日志判断是否可以修复。"
    fi
  else
    if ! systemctl start "${SERVICE}"; then
      warn "服务启动请求失败，将继续读取日志判断是否可以修复。"
    fi
  fi
  info "正在确认服务稳定运行及 UDP ${PORT} 监听（最长约 120 秒）..."
  if ! wait_for_service_with_recovery; then
    die "服务启动后未稳定运行。"
  fi
  if ! local_connection_selftest; then
    die "本机功能自测未通过，安装未完成。服务和配置已保留，修复上述问题后可重试。"
  fi
  systemctl enable --now "${RENEW_TIMER}" || warn "证书续期 timer 未启动，请检查 ${RENEW_TIMER}。"
  trap - EXIT
  print_connection_info
}

update_hysteria() {
  require_root
  validate_version
  [[ -x /usr/local/bin/hysteria && -s "${CONFIG_FILE}" ]] || \
    die "未找到已安装的 Hysteria 程序和服务配置；新设备请先执行 install。"
  require_command curl
  require_command systemctl
  require_command ss
  require_command journalctl
  [[ -d /run/systemd/system ]] || die "此系统没有运行 systemd；无法更新 systemd 服务。"
  check_service_policy_path
  load_installed_ports
  local service_active=0
  systemctl is-active --quiet "${SERVICE}" 2>/dev/null && service_active=1 || true
  backup_config
  info "更新官方 Hysteria 2 程序，保留现有配置..."
  run_official_installer
  write_service_policy
  systemctl daemon-reload
  if ((service_active)); then
    SERVICE_STARTED_AT="$(date --iso-8601=seconds)"
    if ! systemctl restart "${SERVICE}"; then
      warn "更新后服务重启请求失败，将读取日志判断原因。"
    fi
    info "正在等待更新后的服务稳定运行并确认 UDP ${PORT} 监听（最长约 120 秒）..."
    if wait_for_service_with_recovery; then
      info "更新完成，本机服务检查通过；仍需客户端验证公网连通性。"
    else
      die "更新后服务未稳定运行。"
    fi
  else
    info "更新完成；服务更新前处于停止状态，未自动启动。"
  fi
}

uninstall_hysteria() {
  require_root
  require_command curl
  if [[ "${YES}" -ne 1 ]]; then
    if ! read -r -p "这会停止并删除 Hysteria 2 服务，继续？[y/N] " answer; then
      die "已取消。"
    fi
    [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消。"
  fi
  backup_config
  local temp_file
  local user_preexisted=1
  local home_owned=0
  local masquerade_owned=0
  if [[ -r "${STATE_FILE}" ]] && grep -qx 'user_preexisted=0' "${STATE_FILE}"; then
    user_preexisted=0
  fi
  if state_owns_directory home_owned; then
    home_owned=1
  fi
  if state_owns_directory masquerade_owned; then
    masquerade_owned=1
  fi
  temp_file="$(mktemp)"
  if ! download_official_installer "${temp_file}"; then
    rm -f "${temp_file}"
    return 1
  fi
  systemctl disable --now "${SERVICE}" >/dev/null 2>&1 || warn "无法禁用服务，请检查残留的开机启动链接。"
  systemctl disable --now "${RENEW_TIMER}" >/dev/null 2>&1 || true
  systemctl stop "${RENEW_SERVICE}" >/dev/null 2>&1 || true
  if ! bash "${temp_file}" --remove; then
    rm -f "${temp_file}"
    return 1
  fi
  rm -f "/etc/systemd/system/${RENEW_SERVICE}" "/etc/systemd/system/${RENEW_TIMER}" "${RENEW_SCRIPT}"
  rm -f "${CERT_FILE}" "${KEY_FILE}"
  remove_service_policy
  systemctl daemon-reload
  rm -f "${CONFIG_FILE}"
  if ((home_owned)); then
    rm -rf "${HYSTERIA_HOME_DIR}"
  elif ((masquerade_owned)); then
    rm -rf "${MASQUERADE_DIR}"
  fi
  if ((user_preexisted == 0 && home_owned)) && id hysteria >/dev/null 2>&1; then
    userdel hysteria >/dev/null 2>&1 || warn "无法删除 hysteria 用户，请手动检查。"
  fi
  if (( ! home_owned )); then
    info "已保留原有或归属未知的 ${HYSTERIA_HOME_DIR} 及服务用户，请按需手动清理。"
  fi
  rm -rf "${STATE_DIR}"
  rm -f "${temp_file}"
  info "Hysteria 2 已卸载；备份仍保留在 ${BACKUP_DIR}。"
}

service_action() {
  require_root
  systemctl "$ACTION" "${SERVICE}"
}

wait_for_service_stable() {
  local attempt stable_checks=0 invocation_id=""
  # ACME TLS-ALPN may take a few seconds. Require a live systemd process, the
  # Hysteria UDP listener, and the TCP HTTPS masquerade listener when enabled;
  # fail early when this invocation reports an ACME/configuration error. This
  # prevents a failed certificate request or missing static page listener from
  # being reported as a successful installation.
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if ! systemctl is-active --quiet "${SERVICE}"; then
      return 1
    fi
    local current_invocation
    current_invocation="$(service_current_invocation)"
    if [[ "${current_invocation}" != "${invocation_id}" ]]; then
      stable_checks=0
      invocation_id="${current_invocation}"
    fi
    LAST_SERVICE_INVOCATION_ID="${invocation_id}"
    if service_has_startup_error "${invocation_id}"; then
      return 1
    fi
    if service_port_is_listening && service_tcp_port_is_listening && \
      service_logs_match "${invocation_id}" 'server up and running'; then
      ((stable_checks += 1))
      ((stable_checks >= 3)) && return 0
    else
      stable_checks=0
    fi
    sleep 2
  done
  return 1
}

main() {
  parse_args "$@"
  case "${ACTION}" in
    install) install_hysteria ;;
    update) update_hysteria ;;
    uninstall) uninstall_hysteria ;;
    start|stop|restart|status) service_action ;;
    *) die "不支持的操作：${ACTION}" ;;
  esac
}

main "$@"
