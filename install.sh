#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="hysteria2-installer"
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
  --password-stdin      Read the Hysteria password from stdin
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
  if [[ -n "${VERSION}" && ! "${VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "版本必须类似 v2.7.2。"
  fi

  if ((PASSWORD_FROM_STDIN)); then
    if ! IFS= read -r PASSWORD && [[ -z "${PASSWORD}" ]]; then
      die "未从标准输入读取到密码，已取消。"
    fi
  fi
  if [[ -z "${PASSWORD}" ]]; then
    PASSWORD="$(openssl rand -hex 24)"
  fi
  if [[ ! "${PASSWORD}" =~ ^[A-Za-z0-9._-]{12,128}$ ]]; then
    die "密码必须为 12-128 位，只能包含字母、数字、点、下划线或短横线。"
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
  if command -v ss >/dev/null 2>&1 && ss -H -lntu | awk -v port=":${PORT}" '$5 ~ port "$" { found=1 } END { exit !found }'; then
    die "端口 ${PORT} 已被其他进程占用。"
  fi
}

download_official_installer() {
  local target="$1"
  if ! curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
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
  info "安装完成。"
  info "域名: ${DOMAIN}"
  info "端口: ${PORT}（UDP；证书续期还需要 TCP ${PORT}）"
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
  info "Google Cloud 防火墙请放行 TCP ${PORT} 和 UDP ${PORT}。"
}

install_hysteria() {
  require_root
  install_prerequisites
  require_command curl
  require_command openssl
  require_command systemctl
  [[ -d /run/systemd/system ]] || die "此系统没有运行 systemd；请使用 Debian/Ubuntu/Rocky 等标准 VM 镜像。"
  validate_install_inputs
  check_domain_resolution
  check_port_available

  if [[ -f "${CONFIG_FILE}" && "${YES}" -ne 1 ]]; then
    if ! read -r -p "已有 ${CONFIG_FILE}，备份后覆盖？[y/N] " answer; then
      die "已取消。"
    fi
    [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消。"
  fi

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
  info "安装官方 Hysteria 2 程序和 systemd 服务..."
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
  if systemctl is-active --quiet "${SERVICE}"; then
    if ! systemctl restart "${SERVICE}"; then
      journalctl --no-pager -u "${SERVICE}" -n 50 >&2 || true
      die "服务重启失败。"
    fi
  else
    if ! systemctl start "${SERVICE}"; then
      journalctl --no-pager -u "${SERVICE}" -n 50 >&2 || true
      die "服务启动失败。"
    fi
  fi
  if ! systemctl is-active --quiet "${SERVICE}"; then
    journalctl --no-pager -u "${SERVICE}" -n 50 >&2 || true
    die "服务启动失败。"
  fi
  print_connection_info
}

update_hysteria() {
  require_root
  require_command curl
  require_command systemctl
  [[ -d /run/systemd/system ]] || die "此系统没有运行 systemd；无法更新 systemd 服务。"
  local service_active=0
  systemctl is-active --quiet "${SERVICE}" 2>/dev/null && service_active=1 || true
  backup_config
  info "更新官方 Hysteria 2 程序，保留现有配置..."
  run_official_installer
  if ((service_active)); then
    if ! systemctl restart "${SERVICE}"; then
      journalctl --no-pager -u "${SERVICE}" -n 50 >&2 || true
      die "更新后服务重启失败。"
    fi
    if systemctl is-active --quiet "${SERVICE}" 2>/dev/null; then
      info "更新完成。"
    else
      journalctl --no-pager -u "${SERVICE}" -n 50 >&2 || true
      die "更新后服务未运行。"
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
