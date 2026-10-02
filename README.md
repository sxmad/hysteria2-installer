# hysteria2-installer

[简体中文](README.md) | [English](README.en.md)

一个面向 Google Cloud VM 的纯净 Hysteria 2 安装器，默认使用 UDP/TCP 443，适合 Shadowrocket。

## 推荐的 Google Cloud VM

对于不超过 15 人、速度优先的使用场景，建议：

- **机型：`e2-standard-2`**，2 vCPU、8 GB 内存；它比共享核心机型更适合持续的视频流量。
- **系统：Debian 13**；Debian 12 也可以。Google Cloud 的 Debian 镜像已包含 SSH-in-browser 所需的 Guest 环境。
- **磁盘：** 30 GB `pd-balanced`；Hysteria 不保存代理流量，不需要 Local SSD。
- **网络：** 使用 Premium Tier，并为 VM 保留静态外部 IPv4；地区选择应以客户端实测延迟、丢包和 YouTube 速度为准。

如果 10-15 人经常同时进行 4K 视频或大文件下载，升级到 **`e2-standard-4`（4 vCPU、16 GB）**；普通网页、1080p 视频和少量并发不需要它。只供少量个人连接、更加节省费用时，可以使用 `e2-medium`。不建议把 `e2-micro` 或 `e2-small` 作为速度优先的长期节点，因为它们是共享核心，持续 CPU 和吞吐能力有限。Google Cloud 将 E2 共享核心定位为小型、非资源密集型工作负载。

推荐配置表：

| 使用强度 | 机型 | CPU / 内存 | 磁盘 |
|---|---|---:|---:|
| 1-5 人 | `e2-medium` | 2 个共享 vCPU，合计持续配额约 1 核 / 4 GB | 20-30 GB `pd-balanced` |
| 5-15 人，普通网页和视频 | `e2-standard-2` | 2 vCPU / 8 GB | 30 GB `pd-balanced` |
| 10-15 人，经常同时 4K 或下载 | `e2-standard-4` | 4 vCPU / 16 GB | 30-50 GB `pd-balanced` |

## 一键安装

安装器修订号：`2026-10-02.2`。启动时会显示该编号，可确认下载到了本次修复版。

Google Web SSH 通常以普通用户登录，请先执行 `sudo -i` 进入 root shell。下列安装和管理命令均在 root shell 中运行。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email you@example.com
```

请将示例域名和邮箱替换为自己的值。域名和邮箱均无默认值；同时指定两项后，全新安装无需再输入这两项。

脚本默认会：

- 安装官方 Hysteria 2 程序和 systemd 服务；
- 使用端口 `443`；
- 使用 Let’s Encrypt ACME TLS-ALPN 自动申请免费证书；
- 使用安装时指定或输入的域名和 ACME 邮箱；
- 生成 16 位随机密码，并在终端显示一次（使用 `--password-stdin` 时仍兼容 12-128 位自定义密码）；
- 生成本机静态伪装页面，页面内容为 `asdfq`，并由 Hysteria 同时通过 HTTP/3（UDP 443）和普通 HTTPS（TCP 443）提供；
- 使用 Hysteria 自己的 `bbr` 拥塞控制器。
- 安装 `qrencode`，在 Web SSH 终端显示可扫描二维码，并保存 PNG 和受保护的 URI 文本。

为保证 TLS-ALPN 证书验证成功，当前安装器只接受端口 `443`；传入其他端口会直接拒绝。

脚本不会安装 Nginx、Docker、面板、BBR 内核调优、定时任务或第三方伪装代理，也不会修改 Google Cloud VPC 防火墙。

## 安装前必须准备

1. 为新 VM 准备独立域名或子域名，A 记录直接指向该 VM 的固定公网 IPv4。若有 AAAA 记录，必须指向本机可用的公网 IPv6；否则删除旧 AAAA。不要把域名放在 Cloudflare 橙云代理后面。脚本的 DNS 预检只确认能解析，不证明解析目标就是本机。
2. 在 Google Cloud VPC 防火墙放行 **TCP 443 和 UDP 443**。TCP 443 用于 ACME TLS-ALPN 证书申请、续期和普通浏览器访问静态页；UDP 443 用于 Hysteria/HTTP3 流量。
3. 推荐使用带 systemd 的 Debian 12/13 或 Ubuntu LTS 官方镜像。脚本使用系统自带的 `apt-get` 安装缺失依赖；入口命令本身需要 `curl`，若提示找不到它，先运行 `apt-get update && apt-get install -y curl ca-certificates`。Rocky 等 RPM 系发行版仅提供依赖安装分支，需自行确认仓库有 `qrencode`（可能需要 EPEL），并放行系统防火墙。

进入 root shell 并运行命令后，脚本只询问未通过参数提供的域名或邮箱，并自动生成随机密码。脚本不会重启 VM，也不会自动修改系统或云端防火墙。

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

服务启动并通过本机代理自测后，脚本会同时输出（仍需客户端验证公网连通性）：

- Shadowrocket 可用的 `hysteria2://` URI；
- 终端 Unicode 二维码，适合直接在 Google Web SSH 页面放大后扫码；
- `/root/hysteria2-域名.png` 二维码图片；
- `/root/hysteria2-域名.txt` 连接信息文件，权限为 `600`。

安装器不会仅根据 `systemctl is-active` 就报告成功：它会等待当前服务完成 ACME 证书处理、确认本机 UDP 443 正在监听；默认静态伪装还会确认本机 TCP 443 由当前 Hysteria 进程监听，并检查本次启动日志中的证书或配置错误。确认服务已成功加载证书、稳定运行且所需监听均正常后，还会自动检查本机 HTTPS 页面，并启动临时官方 Hysteria 客户端，通过 SOCKS5 访问 `https://www.google.com/generate_204`。只有返回 HTTP 204 才输出 URI 和二维码；失败打印原因并返回非零状态。临时配置固定使用 `.yaml` 后缀，密码不放入进程命令行，自测结束清理临时客户端和文件。

安装完成后，普通浏览器可以直接访问 `https://你的域名/`，看到页面内容 `asdfq`。Shadowrocket 使用 Hysteria 的 UDP 443 连接；浏览器静态页使用 TCP 443，两者可以共用端口号。如果使用 `--no-masquerade`，则不会创建静态页，也不会启用 TCP HTTPS 伪装。

如果日志显示的是 ACME 的临时错误（例如 CA 服务错误、bad nonce 或连接重置），脚本会先打印原因并提供选择：`1` 修复并重启重试，`2` 中断；最多允许 3 次修复重试。明确的 TCP 443 超时/拒绝、防火墙或 DNS/CAA 问题、证书速率限制、端口占用、配置错误和 UDP 443 未监听无法由脚本可靠修复，会直接说明问题并中断。云端 UDP 防火墙是否允许入站流量无法从 VM 内可靠自测，因此仍需在 Google Cloud 中预先放行 TCP 443 和 UDP 443。

首次申请证书时每次检查最多等待约 120 秒；期间不要启动多个安装进程。重装开始时，同域旧的二维码和 URI 会移到 `/var/backups/hysteria2-installer/`，避免失败后误用旧凭据。

发布新版脚本不会修改已部署的服务；本次域名和邮箱输入方式的调整只在后续运行安装命令时生效。

二维码内容只包含连接 URI，其中包含密码。不要把终端截图或 PNG 发给不需要连接的人。

密码不会放在命令行参数中。自动化部署可通过标准输入传入密码：

```bash
printf '%s\n' 'your-safe-password' | \
  bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email you@example.com --password-stdin
```

其他操作：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) update
systemctl status hysteria-server.service
systemctl restart hysteria-server.service
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) uninstall
```

`update` 只接受已有 Hysteria 程序和配置的机器，并保留配置；它不会把旧配置自动转换成新版，也不会重置现有密码。新 VM 请使用 `install`。更新前会备份现有配置。重装已有配置时会要求确认是否覆盖，并备份到 `/var/backups/hysteria2-installer/`；使用 `--yes` 可跳过确认。

卸载只清理状态记录明确归本安装器创建的用户和数据目录；已有或归属不明的目录会保留。不要在本安装器创建的 `/var/lib/hysteria` 中存放其他文件。配置备份和 `/root/hysteria2-域名.{txt,png}` 会保留供恢复使用，其中含有凭据，需要时请自行删除。

如果检测到已有且归属不明的伪装页面，安装器会拒绝覆盖；请使用 `--no-masquerade`，或先手工备份并移除该页面。

如果不需要静态伪装页面，可以使用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email you@example.com --no-masquerade
```

## Shadowrocket 首次连接

扫码导入后，确认类型为 Hysteria2，端口为 443，密码与本次安装输出一致，TLS SNI/Peer 为当前域名。客户端把 `sni` 显示为 `peer` 本身不代表错误。首次测试选择新节点，将全局路由临时设为“代理”，通过后再恢复自己的分流规则。浏览器能打开静态页只证明 TCP HTTPS 正常，不证明 UDP 代理可达。

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
- 脚本不会自动读取或上传 GCP 凭据、域名密码或 Hysteria 配置。
- 官方安装器会查询版本 API，并发送系统类型和 CPU 架构用于选择版本；这是更新检查，不是流量统计。

验证范围：`bash -n install.sh`、`bash install.sh --help`、`bash test_startup.sh` 覆盖语法、16 位密码、启动监听归属和证书恢复路径。`test_proxy.sh` 使用真实 Hysteria 程序及隔离的测试证书/HTTPS 目标，验证本机认证、TLS、SOCKS 转发和失败时的清理；测试证书仅用于测试，不写入安装配置。这些测试不等于新 GCP VM 的 ACME 签发或手机公网验收；安装时会在你的 VM 上再运行真实 Google HTTP 204 自测。公网 UDP 防火墙、客户端网络和 Shadowrocket 仍需外部连接验证。

本次真实程序测试使用 Hysteria v2.12.3。受限测试环境不能查询 netlink/PID，因此仅在测试脚本中显式启用了 `HYSTERIA_TEST_NO_PID_CHECK=1`，监听进程归属另外通过模拟测试覆盖；生产安装器没有此跳过选项。本环境的 Google 测试因 DNS 出站受限未通过，不能据此声称公网验收成功。普通 Linux 可运行：

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

## License

MIT
