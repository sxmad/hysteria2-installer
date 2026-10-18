# hysteria2-installer

[English](README.md) | [简体中文](README.zh-CN.md)

修订号 **2026-10-18.2**：支持自定义 **UDP** 端口，可按任意顺序与 Trojan 共存。Hysteria 代理外层是 UDP/QUIC；转发 TCP 网站流量时，外层也不会改成 TCP。普通 HTTPS 页面使用独立的 TCP 监听。

## 一键安装

将 `--domain` 对应的 A 记录指向 VM 公网 IPv4，放行 **TCP 80（证书签发/续期）和所选 UDP 端口**。GCP 规则必须匹配 VM 的 VPC、网络标记或服务账号；主机防火墙开启时也需放行。不要留下错误 AAAA 记录或启用域名 CDN 代理。

```bash
sudo bash -c 'bash <(curl -fsSL --proto "=https" --tlsv1.2 \
  https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) install \
  --domain hy2.example.com \
  --email you@example.com \
  --port 8443'
```

不指定端口时使用 UDP 443；域名/邮箱缺失时询问；默认随机生成 16 位密码。建议使用带 systemd 的标准 Debian/Ubuntu VM，系统软件源需提供 lego、openssl、python3、curl、iproute2、util-linux 和二维码依赖。核心及基础服务由 Hysteria 官方安装器提供。

[统一安装入口](https://github.com/sxmad/mofatizi-installer)提供 `1: all`、`2: trojan`、`3: hysteria2` 菜单，默认保留已有协议配置。

## 共存与端口

| 用途 | 端口 | 说明 |
|---|---|---|
| HY2 代理与 HTTP/3 页面 | UDP `--port`，默认 443 | 可指定 8443 等 1–65535 端口。 |
| 证书签发与续期 | TCP 80 | 与 UDP 端口无关，安装后仍需放行。 |
| 普通 HTTPS 页面 | 默认关闭 TCP 监听 | 用 `--https-port PORT` 开启；不能占用 TCP 80。 |
| 同机 Trojan | 独立的 TCP 端口 | TCP 443 与 UDP 443 可以共存。 |

新安装默认不占用 TCP 443，以下组合均可：Trojan TCP 443 + HY2 UDP 8443、Trojan TCP 8443 + HY2 UDP 443，以及两者分别使用 TCP 443/UDP 443。

脚本区分 TCP/UDP，仅在同一传输协议和端口被其他程序占用时中断；不会停止其他服务抢端口。GCP 勾选 Allow HTTPS traffic 不代表已放行 UDP 或 TCP 8443。

**旧部署：** 2026-10-18.1 及更早版本用 TCP 443 做 TLS-ALPN 验证，通常还在该端口提供 HTTPS 页面。`update` 会保留旧配置。在这种 VM 上加 Trojan，可选 TCP 8443。若必须释放旧 HY2 的 TCP 443，请显式用新版重新安装 HY2，并传入原域名、UDP 端口和密码；这会改用 HTTP-01 证书管理，HY2 可能短暂中断。脚本不会静默迁移或停止已有协议。

## 页面与参数

静态页正文为 `asdfq`，HTML 元信息为英文；默认仅通过 HY2 端口的 HTTP/3 提供。如需普通浏览器 HTTPS 页面，指定空闲 TCP 端口并放行：

```bash
sudo bash install.sh install \
  --domain hy2.example.com \
  --email you@example.com \
  --port 8443 \
  --https-port 9443
```

此时页面为 `https://hy2.example.com:9443/`；`--no-masquerade` 关闭页面，不能与 `--https-port` 同用。页面可访问不等于公网 UDP 代理已验证。

| 参数 | 行为 |
|---|---|
| `--domain` / `--email` | 必填，未提供时询问。 |
| `--port` | UDP 代理端口，默认 443。 |
| `--https-port` | 可选 TCP HTTPS 页面，默认 0（关闭）；不允许 TCP 80。 |
| `--password-stdin` | 从标准输入读取原密码；12–128 位字母、数字、点、下划线、短横线；空值会拒绝。 |
| `--version v2.x.y` | 指定 Hysteria 2 正式版。 |
| `--no-masquerade` | 不创建静态页面。 |
| `--yes` | 确认覆盖此协议已有配置。 |

换 VM 时，保留域名/SNI、UDP 端口和密码，把 A 记录改到新 VM 并申请有效证书，客户端通常无需改配置；DNS 缓存和重连仍可能导致中断。不传原密码的重新安装会生成新密码。

```bash
sudo bash -c '
set -e
IFS= read -r -s -p "原 Hysteria 密码: " hy2_password
printf "\n"
[[ -n "$hy2_password" ]] || exit 1
printf "%s\n" "$hy2_password" |
  bash <(curl -fsSL --proto "=https" --tlsv1.2 \
    https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) install \
    --domain hy2.example.com \
    --email you@example.com \
    --port 8443 \
    --password-stdin
'
```

## 证书与自动续期

新安装使用 lego HTTP-01，将证书部署到 `/etc/hysteria/cert.pem` 和 `/etc/hysteria/key.pem`；私钥仅供 root/服务组读取。账号与缓存独立保存在 `/var/lib/hysteria/lego`。

`hysteria-cert-renew.timer` 每天加随机延迟检查，到期前 30 天续期。安装和续期共用 `/run/lock/trojan-cert-renew.lock`，沿用该名字也能与旧 Trojan 的续期任务协调，避免同时抢占 TCP 80。运行期间不要删除锁文件。

部署前核对证书域名、有效期和公私钥匹配；申请失败保留已部署证书；复制失败后会重试部署已缓存的新证书。HY2 在新握手读取证书，因此续期**无需重启代理服务**。不设置周期性重启。

```bash
sudo systemctl status hysteria-cert-renew.timer --no-pager
sudo journalctl -u hysteria-cert-renew.service --since '7 days ago' --no-pager
```

HTTP-01 超时/拒绝连接时，按提示排查域名、公网 TCP 80、GCP 规则目标和主机防火墙。脚本不修改防火墙、不停止其他 Web 服务，也不跳过证书校验。

## 验证、更新与运行

安装会检查本服务 PID 的 UDP 监听、可选 TCP HTTPS 监听和启动日志；再启动临时官方客户端，经 SOCKS5 访问 Google HTTPS，取得 HTTP 204 后才生成连接链接/二维码。临时进程和文件会清理。公网 UDP、防火墙和 Shadowrocket 实际线路仍需手机验证。

客户端使用 Hysteria2、实际 UDP 端口、密码和匹配域名的 SNI/Peer。“UDP 转发”选项控制应用 UDP，不改变 HY2 外层 QUIC。

```bash
sudo systemctl status hysteria-server.service --no-pager
sudo journalctl -b -u hysteria-server.service --since '10 minutes ago' --no-pager
sudo ss -H -lunp 'sport = :8443'
sudo bash install.sh update
```

下载新脚本再执行 `update`，会保留配置、密码、证书模式、自定义端口和服务原有运行/停止状态。它更新核心及恢复策略，不把旧 TLS-ALPN 配置自动迁移成 HTTP-01。仓库更新不会自动改变 VM。还支持 `start`、`stop`、`restart`、`status`。

恢复策略保存在 `/etc/systemd/system/hysteria-server.service.d/20-hysteria2-installer.conf`：异常退出 5 秒后重试，300 秒内最多启动 5 次，并开启内存记账；主动停止不会被拉起。达到限制后先修复原因，再执行 `systemctl reset-failed hysteria-server.service` 和 `systemctl start hysteria-server.service`。保留管理员自己的 drop-in。

## 长期内存与卸载

安装脚本执行完即退出，长期内存属于核心进程。默认不设置定时重启、固定内存上限、内核 TCP BBR、Nginx、Docker 或外部回落代理；配置 HY2 自身 QUIC BBR。功能测试不能证明连续多天无泄漏。

建议在相似负载/空闲条件下观察 24–72 小时：

```bash
sudo systemctl show hysteria-server.service \
  -p MainPID -p MemoryCurrent -p MemoryPeak -p NRestarts -p Result
proxy_pid=$(systemctl show hysteria-server.service -p MainPID --value)
ps -p "$proxy_pid" -o pid,etimes,rss,%mem,cmd
free -h
sudo journalctl -k --since '24 hours ago' | grep -Ei 'oom|out of memory|killed process'
df -h / /var/log
```

RSS 单位 KiB，cgroup 内存单位字节；日志/磁盘增长与堆内存泄漏不同。保留版本、负载、运行时间、采样及脱敏日志。存在上游修复时优先更新核心；任意设置重启周期或低内存上限不能修复泄漏，可能造成断线。

`sudo bash install.sh uninstall` 删除 HY2 及自己的续期任务，保留配置备份和归属未知的文件/目录，不删除 Trojan 或共享锁；不需要重启 VM。

## 测试

```bash
bash test_startup.sh
python3 test_service_policy.py
python3 test_coexist.py
HYSTERIA_TEST_BINARY=/path/to/hysteria bash test_proxy.sh
# 仅在一次性测试用 systemd 环境执行：
sudo env HYSTERIA_TEST_SYSTEMD=1 bash test_service_systemd.sh
```

覆盖启动、TCP/UDP 分离、自定义配置与更新、HTTP-01 锁、真实证书下续期和失败恢复、TLS/认证/转发及 systemd 恢复。统一仓库另有真实 Trojan/HY2 两种启动顺序共存测试。这些不能替代公网 ACME/GCP/Shadowrocket 验证或多天运行观察。
