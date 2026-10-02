# hysteria2-installer

[简体中文](README.md) | [English](README.en.md)

一个面向 Google Cloud VM 的纯净 Hysteria 2 安装器，默认使用 UDP/TCP 443，适合 Shadowrocket。

[一键安装](#一键安装) · [安装前准备](#安装前必须准备) · [参数](#安装参数) · [管理服务](#服务管理与更新) · [卸载重测](#卸载与重新测试) · [排错](#常见问题与排查) · [验证范围](#验证范围)

## 推荐的 Google Cloud VM

以下是面向不超过 15 人的配置起点，不是并发人数或网速保证；请根据实际 CPU、内存和线路表现调整：

- **机型：`e2-standard-2`**，2 vCPU、8 GB 内存；它比共享核心机型更适合持续的视频流量。
- **系统：Debian 13**；Debian 12 也可以。Google Cloud 的 Debian 镜像已包含 SSH-in-browser 所需的 Guest 环境。
- **磁盘：** 30 GB `pd-balanced`（Balanced Persistent Disk，平衡永久性磁盘）；本配置不记录流量内容，不需要 Local SSD。`pd-balanced` 与 `pd-extreme` 是不同磁盘类型。
- **网络：** 使用 Premium Tier，并为 VM 保留静态外部 IPv4；地区选择应以客户端实测延迟、丢包和 YouTube 速度为准。

如果 10-15 人经常同时进行 4K 视频或大文件下载，升级到 **`e2-standard-4`（4 vCPU、16 GB）**；普通网页、1080p 视频和少量并发不需要它。只供少量个人连接、更加节省费用时，可以使用 `e2-medium`。不建议把 `e2-micro` 或 `e2-small` 作为速度优先的长期节点，因为它们是共享核心，持续 CPU 和吞吐能力有限。Google Cloud 将 E2 共享核心定位为小型、非资源密集型工作负载。

推荐配置表：

| 使用强度 | 机型 | CPU / 内存 | 磁盘 |
|---|---|---:|---:|
| 1-5 人 | `e2-medium` | 2 个共享 vCPU，合计持续配额约 1 核 / 4 GB | 20-30 GB `pd-balanced` |
| 5-15 人，普通网页和视频 | `e2-standard-2` | 2 vCPU / 8 GB | 30 GB `pd-balanced` |
| 10-15 人，经常同时 4K 或下载 | `e2-standard-4` | 4 vCPU / 16 GB | 30-50 GB `pd-balanced` |

## 一键安装

安装器修订号：`2026-10-02.2`。启动时会显示该编号，可确认当前下载版本。

Google Web SSH 通常以普通用户登录，请先执行 `sudo -i` 进入 root shell。下列安装和管理命令均在 root shell 中运行。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email you@example.com
```

请将示例域名和邮箱替换为自己的值。域名和邮箱均无默认值；同时指定两项后，全新安装无需再输入这两项。

脚本默认会：

- 安装官方 Hysteria 2 程序和 systemd 服务；
- 使用端口 `443`；
- 使用 Let’s Encrypt ACME TLS-ALPN 自动申请免费证书，并由运行中的 Hysteria 自动续期；
- 自动启动 `hysteria-server.service` 并启用开机启动；
- 使用安装时指定或输入的域名和 ACME 邮箱；
- 生成 16 位随机密码，并在终端显示一次（使用 `--password-stdin` 时仍兼容 12-128 位自定义密码）；
- 生成本机静态伪装页面，页面内容为 `asdfq`，并由 Hysteria 同时通过 HTTP/3（UDP 443）和普通 HTTPS（TCP 443）提供；
- 使用 Hysteria 自己的 `bbr` 拥塞控制器；
- 安装 `qrencode`，在 Web SSH 终端显示可扫描二维码，并保存 PNG 和受保护的 URI 文本。

为保证 TLS-ALPN 证书验证成功，当前安装器只接受端口 `443`；传入其他端口会直接拒绝。

脚本不会安装 Nginx、Docker、面板、BBR 内核调优、定时任务或第三方伪装代理，也不会修改 Google Cloud VPC 防火墙。

## 安装前必须准备

1. 为新 VM 准备独立域名或子域名，A 记录直接指向该 VM 的固定公网 IPv4。若有 AAAA 记录，必须指向本机可用的公网 IPv6；否则删除旧 AAAA。不要把域名放在 Cloudflare 橙云代理后面。脚本的 DNS 预检只确认能解析，不证明解析目标就是本机。
2. 在 Google Cloud VPC 防火墙放行 **TCP 443 和 UDP 443**。TCP 443 用于 ACME TLS-ALPN 证书申请、续期和普通浏览器访问静态页；UDP 443 用于 Hysteria/HTTP3 流量。
3. 推荐使用带 systemd 的 Debian 12/13 或 Ubuntu LTS 官方镜像。脚本使用系统自带的 `apt-get` 安装缺失依赖；入口命令本身需要 `curl`，若提示找不到它，先运行 `apt-get update && apt-get install -y curl ca-certificates`。Rocky 等 RPM 系发行版仅提供依赖安装分支，需自行确认仓库有 `qrencode`（可能需要 EPEL），并放行系统防火墙。

**防火墙规则必须实际匹配这台 VM 所在的 VPC、目标网络标记或目标服务账号。** 仅勾选“允许 HTTPS 流量”不能代替检查 UDP 443 规则；源地址范围也必须覆盖实际客户端，TCP 443 还须允许证书机构进行验证。本配置不使用 HTTP 80 或负载均衡器健康检查。VM 的 DNS 解析和访问 GitHub、证书机构及 Google 的出站连接也必须可用。

进入 root shell 并运行命令后，脚本只询问未通过参数提供的域名或邮箱，并自动生成随机密码。安装成功后无需重启 VM。脚本不会重启 VM，也不会自动修改系统或云端防火墙。

## 运行方式

不带参数时会交互式询问域名和邮箱；两者均须填写，端口默认为 443，密码自动生成：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh)
```

一键部署时同时指定域名和邮箱；只指定其中一项时，仅询问缺少的另一项。缺失项未能读取到输入时会报错停止：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email you@example.com
```

服务启动并通过本机代理自测后，正常情况下会生成以下连接信息（仍需客户端验证公网连通性）：

- Shadowrocket 可用的 `hysteria2://` URI；
- 终端 Unicode 二维码，适合直接在 Google Web SSH 页面放大后扫码；
- `/root/hysteria2-域名.png` 二维码图片；
- `/root/hysteria2-域名.txt` 连接信息文件；PNG 和文本文件权限均为 `600`。

若二维码生成或显示失败，脚本会告警；可使用已输出的 URI 导入。二维码显示失败本身不代表代理服务失败。

安装器不会仅根据 `systemctl is-active` 就报告成功：它会等待当前服务完成 ACME 证书处理、确认本机 UDP 443 正在监听；默认静态伪装还会确认本机 TCP 443 由当前 Hysteria 进程监听，并检查本次启动日志中的证书或配置错误。确认服务已成功加载证书、稳定运行且所需监听均正常后，还会自动检查本机 HTTPS 页面，并启动临时官方 Hysteria 客户端，通过 SOCKS5 访问 `https://www.google.com/generate_204`。只有返回 HTTP 204 才输出 URI 和二维码；失败打印原因并返回非零状态。临时配置固定使用 `.yaml` 后缀，密码不放入进程命令行，自测结束清理临时客户端和文件。

安装完成后，普通浏览器可以直接访问 `https://你的域名/`，看到页面内容 `asdfq`。Shadowrocket 使用 Hysteria 的 UDP 443 连接；浏览器静态页使用 TCP 443，两者可以共用端口号。如果使用 `--no-masquerade`，则不会创建静态页，也不会启用 TCP HTTPS 伪装。

如果日志显示的是 ACME 的临时错误（例如 CA 服务错误、bad nonce 或连接重置），脚本会先打印原因并提供选择：`1` 修复并重启重试，`2` 中断；最多允许 3 次修复重试。“修复”保留现有证书和 ACME 账户缓存，只重启服务重试；它不会更改 DNS 或云防火墙。无交互终端时无法选择修复，会中断；`--yes` 也不会自动选择修复。明确的 TCP 443 超时/拒绝、防火墙或 DNS/CAA 问题、证书速率限制、端口占用、配置错误和 UDP 443 未监听无法由脚本可靠修复，会直接说明问题并中断。云端 UDP 防火墙是否允许入站流量无法从 VM 内可靠自测，因此仍需在 Google Cloud 中预先放行 TCP 443 和 UDP 443。

首次申请证书时每次检查最多等待约 120 秒；期间不要启动多个安装进程。重装开始时，同域旧的二维码和 URI 会移到 `/var/backups/hysteria2-installer/`，避免失败后误用旧凭据。

发布新版脚本不会修改已部署的服务；本次域名和邮箱输入方式的调整只在后续运行安装命令时生效。

二维码内容只包含连接 URI，其中包含密码。不要把终端截图或 PNG 发给不需要连接的人。

密码不会放在命令行参数中。自动化部署可通过标准输入传入密码：

```bash
printf '%s\n' 'your-safe-password' | \
  bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email you@example.com --password-stdin
```

## 安装参数

| 参数 | 行为 |
|---|---|
| `--domain DOMAIN` | 无默认值，缺少时在安装开始时询问。 |
| `--email EMAIL` | 无默认值，缺少时在安装开始时询问 ACME 邮箱。 |
| `--port PORT` | 默认为 `443`；当前只支持 `443`。 |
| `--password-stdin` | 从标准输入读取自定义密码，12–128 位，仅字母、数字、`.`、`_`、`-`；不指定则随机生成 16 位。 |
| `--no-masquerade` | 不创建静态页面；证书申请、续期仍需 TCP 443。 |
| `--version v2.x.y` | 安装/更新指定 Hysteria 正式版本；省略时由官方安装器选择最新版本。这不是安装器修订号。 |
| `--yes` / `-y` | 跳过覆盖现有配置或卸载的确认；不跳过输入、自测或证书故障处理。 |
| `--help` | 显示帮助及安装器修订号。 |

自动化部署请同时指定域名和邮箱。使用密码管道重装已有配置时还需明确加上 `--yes`，否则仍会要求覆盖确认。若 `--password-stdin` 与缺失域名/邮箱同时出现，身份信息只从交互终端读取，避免消耗密码管道；没有终端则停止。

## 服务管理与更新

查询状态：

```bash
systemctl --no-pager --full status hysteria-server.service
systemctl is-enabled hysteria-server.service
systemctl is-active hysteria-server.service
```

按需更新程序：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) update
```

按需重启服务：

```bash
systemctl restart hysteria-server.service
```

正常安装后，`is-enabled` 应为 `enabled`，`is-active` 应为 `active`。它们只表示自启和进程状态；完整验收还需客户端实际连接。脚本也支持 `start`、`stop`、`restart`、`status` 子命令。

`update` 只接受已有 Hysteria 程序和配置的机器，更新前会备份配置，并保留现有配置和密码；不会自动迁移旧配置。原先运行的服务会重启并检查启动状态，原先停止的服务继续保持停止。`update` 不运行安装时的完整代理自测，也不重新生成二维码；更新后请用现有节点验证连接。新 VM 请使用 `install`。

重新运行 `install` 会备份并覆盖配置，默认生成新密码，需要导入新二维码；覆盖前会要求确认，`--yes` 可跳过该确认。发布新版仓库文件本身不会更新已有服务。

## 卸载与重新测试

以下命令在 root shell 中执行。卸载会中断当前连接，提示时输入 `y`：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) uninstall
```

卸载会停止并禁用服务、调用官方卸载程序移除程序和服务文件，并删除正式配置 `/etc/hysteria/config.yaml`。

用户和数据目录只在安装器状态记录确认归其创建、且满足相应清理条件时删除。若记录确认 `/var/lib/hysteria` 由安装器创建，会删除整个目录，包括其中的证书缓存和静态页；不要在其中存放其他文件。已有或归属不明的目录会保留并提示。

以下内容会保留：配置备份 `/var/backups/hysteria2-installer/`、`/root/hysteria2-域名.{txt,png}`、系统依赖包，以及 DNS 和 Google Cloud 防火墙规则。备份及连接文件含凭据，可按需自行删除；它们不会自动恢复到新配置。

确认卸载完成后，不带参数重装可验证域名和邮箱交互输入：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh)
```

也可使用[一键安装](#一键安装)中的双参数命令。确认版本号，填写自己的域名和邮箱，等待启动及本机代理自测通过，再用**新二维码**导入 Shadowrocket。安装和卸载均无需重启 VM。

卸载重装不等于全新系统测试：依赖包及归属不明的目录可能仍存在。要验证第一次安装依赖及申请证书的完整流程，应使用新 VM 或全新系统；不要仅为重复测试而反复删除证书缓存。证书机构限额不能靠重装解除。

如果检测到已有且归属不明的伪装页面，安装器会拒绝覆盖；请使用 `--no-masquerade`，或先手工备份并移除该页面。

## 可选：关闭静态页

如果不需要静态伪装页面，可以使用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email you@example.com --no-masquerade
```

## Shadowrocket 首次连接

扫码导入后，确认类型为 Hysteria2，端口为 443，密码与本次安装输出一致，TLS SNI/Peer 为当前域名。客户端把 `sni` 显示为 `peer` 本身不代表错误。首次测试选择新节点，将全局路由临时设为“代理”，通过后再恢复自己的分流规则。浏览器能打开静态页只证明 TCP HTTPS 正常，不证明 UDP 代理可达。

## 常见问题与排查

| 现象 | 优先检查 |
|---|---|
| `apt-get` 显示 `Get`、`Hit`、`Reading package lists... Done` | 正常依赖处理日志，不代表整个安装已经完成；等待最终自测和连接信息。 |
| 证书申请 `Timeout during connect` / `likely firewall problem` | 域名 A/AAAA、入站 TCP 443、规则目标是否包含此 VM；修正后重试。 |
| `rate limited` / `Retry-After` | 按日志要求等待，重装或删除缓存不会解除限制。 |
| 服务 `active`，手机连接后无网 | 检查云端及系统 UDP 443、当前二维码密码、SNI/Peer、Shadowrocket 选中节点和路由，再换手机网络测试。 |
| 能访问 `asdfq`，代理仍不通 | 静态页仅证明 TCP HTTPS；继续检查 UDP 和客户端连接。 |
| 本机代理测试不是 HTTP 204 | 按错误检查服务认证、证书、VM 的 DNS 和出站连接；脚本不会输出新二维码。 |
| 自定义客户端配置出现 `Unsupported Config Type` | 配置文件应使用 `.yaml` 后缀；这类错误不代表协议过旧。 |
| 提示缺少 root 权限 | 先执行 `sudo -i`，再运行命令。 |

读取当前服务与最近日志（这些命令不直接读取配置文件；日志可能含客户端地址或敏感认证信息，分享前检查并脱敏）：

```bash
systemctl --no-pager --full status hysteria-server.service
journalctl -b -u hysteria-server.service --since '10 minutes ago' --no-pager
ss -H -ltnup 'sport = :443'
```

启动检查失败时，安装器会尝试停止未就绪服务后报错；本机功能自测失败时，服务与配置会保留供排查。两种情况都不会生成新的连接信息/二维码。先处理明确错误，再重试安装；单纯重启 VM 不能修复 DNS 或云防火墙规则。

## 关于 Nginx 和 BBR

不需要 Nginx。Hysteria 2 自己处理 ACME、TLS、HTTP/3、TCP HTTPS 伪装和静态页面；安装 Nginx 还可能抢占 TCP 443 端口。

这里没有默认修改 Linux TCP BBR 的 sysctl。Hysteria 2 使用 QUIC，配置中的 `congestion.type: bbr` 是 Hysteria 自己的拥塞控制器，与 Linux TCP BBR 是两回事。额外安装或修改 TCP BBR 不保证提升 Hysteria 或 YouTube 速度，也会增加系统改动，因此保持关闭。

客户端未填写带宽提示时使用 BBR；若 Shadowrocket 配置了上传或下载带宽，对应方向可能改用 Brutal。因此这里的配置并不强制所有客户端始终使用 BBR。

实际速度更受 VM 所在地区、到客户端的线路、UDP 丢包和 Google Cloud 防火墙影响。

Google Cloud VPC 防火墙属于 VM 外部的云资源，需在控制台或 `gcloud` 中预先放行 TCP/UDP 443；运行脚本前也必须完成域名解析。不能仅勾选“允许 HTTPS 流量”而遗漏 UDP 443。

## 安全与可审计性

- 所有安装器行为写在 `install.sh` 中；官方 Hysteria 安装器地址也在文件顶部明确列出。
- 下载官方安装器时强制使用 HTTPS；官方安装器随后从 Hysteria 官方 GitHub Release 下载程序。
- 官方安装器地址是动态脚本，未在本项目中固定 SHA256；对供应链可复现性要求较高时，应先按下面的命令审阅下载内容。
- 下载失败、空文件或 Bash 语法检查失败时会拒绝执行官方安装器；这些检查不能代替签名或可信哈希验证。`--version` 也不会固定官方安装器脚本内容。
- 一键命令使用 GitHub `main` 分支，生产环境可将 URL 中的 `main` 替换为你审阅过的固定 commit。
- 不使用固定密码、默认域名、默认邮箱或外部 Bing 代理。
- 配置文件写入权限为 `root:hysteria`、`0640`；密码只在安装完成时显示。
- 脚本不读取 GCP 或域名账号凭据，也不上传本机 Hysteria 配置；它会在本机读取、备份和检查服务配置。
- 官方安装器会查询版本 API，并发送系统类型和 CPU 架构用于选择版本；这是更新检查，不是流量统计。

## 验证范围

**2026-10-02 部署反馈：维护者已确认当前版本 `2026-10-02.2` 的完整流程验证通过。** 此前已反馈 Google Cloud Debian 13 新 VM 及 Shadowrocket 实际连接可用。这是维护者的部署反馈，不是对所有发行版、地区、运营商或客户端版本的兼容性保证。

代码测试：`bash -n install.sh`、`bash install.sh --help`、`bash test_startup.sh` 覆盖语法、域名/邮箱参数与缺参输入、密码管道、16 位密码、启动监听归属、证书恢复和失败不输出二维码的流程。`test_proxy.sh` 使用真实 Hysteria 程序及隔离的测试证书/HTTPS 目标，验证本机认证、TLS、SOCKS 转发和失败时的清理；测试证书仅用于测试，不写入安装配置。这些测试不等于新 GCP VM 的 ACME 签发或手机公网验收；安装时会在你的 VM 上再运行真实 Google HTTP 204 自测。公网 UDP 防火墙、客户端网络和 Shadowrocket 仍需外部连接验证。

本次真实程序测试使用 Hysteria v2.12.3。受限测试环境不能查询 netlink/PID，因此仅在测试脚本中显式启用了 `HYSTERIA_TEST_NO_PID_CHECK=1`，监听进程归属另外通过模拟测试覆盖；生产安装器没有此跳过选项。该测试环境的 Google 测试因 DNS 出站受限未通过；上面的真实部署反馈单独记录，不与本地测试混为一谈。在仓库目录内、具备测试脚本所需依赖的普通 Linux 环境可运行：

```bash
bash test_startup.sh
HYSTERIA_TEST_BINARY=/usr/local/bin/hysteria bash test_proxy.sh
```

安装前如需审阅脚本：

```bash
curl -fsSLo /tmp/hysteria2-install.sh \
  https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh
less /tmp/hysteria2-install.sh
bash /tmp/hysteria2-install.sh --help
```

## 官方参考

- [Hysteria 服务端配置：ACME、拥塞控制及静态伪装](https://hysteria.network/docs/advanced/Full-Server-Config/)
- [Google Cloud VPC 防火墙](https://docs.cloud.google.com/firewall/docs/firewalls)
- [Google Cloud 永久性磁盘类型](https://docs.cloud.google.com/compute/docs/disks/persistent-disks)

## License

MIT
