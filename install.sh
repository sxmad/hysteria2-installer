#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="hysteria2-installer"
readonly SCRIPT_VERSION="2026-10-02.1"
readonly OFFICIAL_INSTALLER_URL="https://get.hy2.sh/"
readonly CONFIG_DIR="/etc/hysteria"
readonly CONFIG_FILE="${CONFIG_DIR}/config.yaml"
readonly SERVICE="hysteria-server.service"
readonly HYSTERIA_HOME_DIR="/var/lib/hysteria"
readonly MASQUERADE_DIR="${HYSTERIA_HOME_DIR}/masquerade"
readonly STATE_DIR="/var/lib/hysteria2-installer"
readonly STATE_FILE="${STATE_DIR}/state"
readonly BACKUP_DIR="/var/backups/hysteria2-installer"
readonly DEFAULT_PORT="443"
readonly DEFAULT_EMAIL="com.gpugame@gmail.com"
readonly DEFAULT_PAGE_TEXT="asdfq"

ACTION="install"
DOMAIN=""
EMAIL="${DEFAULT_EMAIL}"
PORT="${DEFAULT_PORT}"
PASSWORD=""
PASSWORD_FROM_STDIN=0
NO_MASQUERADE=0
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
  --domain DOMAIN       Certificate domain (required for install)
  --email EMAIL         ACME email (default: com.gpugame@gmail.com)
  --port PORT           UDP/TLS port (must be 443 for automatic ACME)
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

validate_install_inputs() {
  if [[ -z "${DOMAIN}" ]] && ! read -r -p "域名: " DOMAIN; then
    die "未读取到域名，已取消。"
  fi
  [[ -n "${DOMAIN}" ]] || die "域名不能为空。"

  is_valid_domain "${DOMAIN}" || die "域名格式不正确：${DOMAIN}"
  if [[ ! "${EMAIL}" =~ ^[A-Za-z0-9.!_%+\-]+@[A-Za-z0-9.-]+$ ]]; then
    die "邮箱格式不正确：${EMAIL}"
  fi
  local email_local="${EMAIL%@*}"
  local email_domain="${EMAIL#*@}"
  [[ "${email_local}" != .* && "${email_local}" != *. && "${email_local}" != *..* ]] || die "邮箱格式不正确：${EMAIL}"
  is_valid_domain "${email_domain}" || die "邮箱域名格式不正确：${EMAIL}"
  if [[ "${PORT}" != "443" ]]; then
    die "为使用 ACME TLS-ALPN，当前安装器只支持端口 443。"
  fi
  validate_version

  if ((PASSWORD_FROM_STDIN)); then
    if ! IFS= read -r PASSWORD && [[ -z "${PASSWORD}" ]]; then
      die "未从标准输入读取到密码，已取消。"
    fi
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

check_port_available() {
  if systemctl is-active --quiet "${SERVICE}" 2>/dev/null; then
    return
  fi
  if command -v ss >/dev/null 2>&1 && ss -H -lntu | awk -v port=":${PORT}" '$4 ~ (port "$") || $5 ~ (port "$") { found=1 } END { exit !found }'; then
    die "端口 ${PORT} 已被其他进程占用。"
  fi
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

write_config() {
  install -d -m 0755 "${CONFIG_DIR}"
  local config_tmp
  config_tmp="$(mktemp "${CONFIG_DIR}/.config.yaml.XXXXXX")"
  if ! cat >"${config_tmp}" <<EOF
listen: :${PORT}

acme:
  domains:
    - ${DOMAIN}
  email: '${EMAIL}'
  ca: letsencrypt
  type: tls

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
  # Serve the same page over normal TCP HTTPS as well as HTTP/3/QUIC.
  # TCP and UDP may use the same numeric port.
  listenHTTPS: :443
  file:
    dir: ${MASQUERADE_DIR}
EOF
    then
      rm -f "${config_tmp}"
      return 1
    fi
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
  if (( NO_MASQUERADE )); then
    info "端口: ${PORT}（UDP；证书申请和续期还需要 TCP ${PORT}）"
  else
    info "端口: ${PORT}（UDP Hysteria + TCP HTTPS 静态页）"
    info "静态页: https://${DOMAIN}/"
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
  info "请保持 Google Cloud 防火墙放行 TCP ${PORT} 和 UDP ${PORT}。"
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

  if (( ! NO_MASQUERADE )); then
    info "检查本机 HTTPS 证书、域名和静态页面..."
    if ! http_code="$(curl -q --proto '=https' --tlsv1.2 --noproxy '*' \
      --silent --show-error --connect-timeout 5 --max-time 15 \
      --resolve "${DOMAIN}:${PORT}:127.0.0.1" \
      --output "${selftest_dir}/page.html" --write-out '%{http_code}' \
      "https://${DOMAIN}:${PORT}/" 2>"${selftest_dir}/https.log")"; then
      warn "本机 HTTPS 自测失败：检查证书信任、域名和 TCP ${PORT} 监听；未生成连接信息或二维码。"
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
  (( NO_MASQUERADE )) && return 1
  # New installations write listenHTTPS. If an older custom config has no
  # such setting, preserve its behavior during update rather than inventing a
  # new TCP listener unexpectedly.
  [[ ! -r "${CONFIG_FILE}" ]] && return 0
  grep -Eq '^[[:space:]]*listenHTTPS:[[:space:]]*:443([[:space:]]*(#.*)?)?$' "${CONFIG_FILE}"
}

service_tcp_port_is_listening() {
  service_masquerade_tcp_expected || return 0
  local service_pid
  service_pid="$(systemctl show -p MainPID --value "${SERVICE}" 2>/dev/null)" || return 1
  [[ "${service_pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  # TCP and UDP may share the numeric port; verify the TCP listener belongs to
  # the current Hysteria process rather than an unrelated web server.
  ss -H -ltnp 2>/dev/null | awk -v port=":${PORT}" -v owner="pid=${service_pid}," \
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
    warn "端口绑定失败：请用 ss -lntup 检查 TCP/UDP 443 占用者；脚本不会停止其他服务。"
  elif service_logs_match "${invocation_id}" 'permission denied'; then
    warn "服务权限不足：请按日志中的路径检查 hysteria 用户读取配置、写入证书目录及绑定端口的权限。"
  elif service_logs_match "${invocation_id}" 'rate.?limited|too many (requests|certificates|failed|new)|retry[- ]after'; then
    warn "证书机构要求等待：请遵守日志中的 retry after/Retry-After 时间；重装或删除证书缓存不能解除限额。"
  elif service_logs_match "${invocation_id}" 'timeout during connect|likely firewall|connection refused'; then
    warn "证书验证连接失败：请确认域名指向本机，并在 Google Cloud 和系统防火墙放行入站 TCP 443；同时放行客户端所需 UDP 443，确保规则目标包含此 VM。"
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

install_hysteria() {
  require_root
  info "安装器版本：${SCRIPT_VERSION}"
  install_prerequisites
  require_command curl
  require_command openssl
  require_command systemctl
  require_command journalctl
  require_command ss
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
  write_masquerade_page
  write_config
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
  info "正在等待 ACME 证书签发并确认 UDP ${PORT} 监听（最长约 120 秒）..."
  if ! wait_for_service_with_recovery; then
    die "服务启动后未稳定运行。"
  fi
  if ! local_connection_selftest; then
    die "本机功能自测未通过，安装未完成。服务和配置已保留，修复上述问题后可重试。"
  fi
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
  local service_active=0
  systemctl is-active --quiet "${SERVICE}" 2>/dev/null && service_active=1 || true
  backup_config
  info "更新官方 Hysteria 2 程序，保留现有配置..."
  run_official_installer
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
  if ! bash "${temp_file}" --remove; then
    rm -f "${temp_file}"
    return 1
  fi
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
