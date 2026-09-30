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

Google Web SSH 通常以普通用户登录，请先执行 `sudo -i` 进入 root shell。下列安装和管理命令均在 root shell 中运行。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh)
```

脚本默认会：

- 安装官方 Hysteria 2 程序和 systemd 服务；
- 使用端口 `443`；
- 使用 Let’s Encrypt ACME TLS-ALPN 自动申请免费证书；
- 默认邮箱为 `com.gpugame@gmail.com`；
- 生成 16 位随机密码，并在终端显示一次（使用 `--password-stdin` 时仍兼容 12-128 位自定义密码）；
- 生成本机静态伪装页面，页面内容为 `asdfq`；
- 使用 Hysteria 自己的 `bbr` 拥塞控制器。
- 安装 `qrencode`，在 Web SSH 终端显示可扫描二维码，并保存 PNG 和受保护的 URI 文本。

为保证 TLS-ALPN 证书验证成功，当前安装器只接受端口 `443`；传入其他端口会直接拒绝。

脚本不会安装 Nginx、Docker、面板、BBR 内核调优、定时任务或第三方伪装代理，也不会修改 Google Cloud VPC 防火墙。

## 安装前必须准备

1. 准备一个直接解析到 VM 公网 IP 的域名。不要把域名放在 Cloudflare 橙云代理后面。
2. 在 Google Cloud VPC 防火墙放行 **TCP 443 和 UDP 443**。TCP 443 用于 ACME TLS-ALPN 证书申请和续期，UDP 443 用于 Hysteria 流量。
3. 推荐使用带 systemd 的 Debian 12/13 或 Ubuntu LTS 官方镜像。脚本使用系统自带的 `apt-get` 安装缺失依赖；入口命令本身需要 `curl`，若提示找不到它，先运行 `apt-get update && apt-get install -y curl ca-certificates`。Rocky 等 RPM 系发行版仅提供依赖安装分支，需自行确认仓库有 `qrencode`（可能需要 EPEL），并放行系统防火墙。

进入 root shell 并运行命令后，全新安装只需输入域名；脚本会自动生成随机密码。脚本不会重启 VM，也不会自动修改系统或云端防火墙。

## 运行方式

不带参数时会交互式询问域名；邮箱和端口使用上面的默认值，密码自动生成：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh)
```

也可以显式指定域名：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email com.gpugame@gmail.com
```

服务启动后，脚本会同时输出（仍需客户端验证公网连通性）：

- Shadowrocket 可用的 `hysteria2://` URI；
- 终端 Unicode 二维码，适合直接在 Google Web SSH 页面放大后扫码；
- `/root/hysteria2-域名.png` 二维码图片；
- `/root/hysteria2-域名.txt` 连接信息文件，权限为 `600`。

安装器不会仅根据 `systemctl is-active` 就报告成功：它会等待当前服务完成 ACME 证书处理、确认本机 UDP 443 正在监听，并检查本次启动日志中的证书或配置错误。只有证书申请成功、服务稳定运行且 UDP 443 在本机监听时，才会输出 URI 和二维码。

如果日志显示的是 ACME 的临时错误（例如 CA 服务错误、bad nonce 或连接重置），脚本会先打印原因并提供选择：`1` 修复并重启重试，`2` 中断；最多允许 3 次修复重试。明确的 TCP 443 超时/拒绝、防火墙或 DNS/CAA 问题、证书速率限制、端口占用、配置错误和 UDP 443 未监听无法由脚本可靠修复，会直接说明问题并中断。云端 UDP 防火墙是否允许入站流量无法从 VM 内可靠自测，因此仍需在 Google Cloud 中预先放行 TCP 443 和 UDP 443。

首次申请证书时每次检查最多等待约 120 秒；期间不要启动多个安装进程。重装开始时，同域旧的二维码和 URI 会移到 `/var/backups/hysteria2-installer/`，避免失败后误用旧凭据。

二维码内容只包含连接 URI，其中包含密码。不要把终端截图或 PNG 发给不需要连接的人。

密码不会放在命令行参数中。自动化部署可通过标准输入传入密码：

```bash
printf '%s\n' 'your-safe-password' | \
  bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --password-stdin
```

其他操作：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) update
systemctl status hysteria-server.service
systemctl restart hysteria-server.service
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) uninstall
```

更新前会备份现有配置。重装已有配置时会要求确认是否覆盖，并备份到 `/var/backups/hysteria2-installer/`；使用 `--yes` 可跳过确认。

卸载只清理状态记录明确归本安装器创建的用户和数据目录；已有或归属不明的目录会保留。不要在本安装器创建的 `/var/lib/hysteria` 中存放其他文件。配置备份和 `/root/hysteria2-域名.{txt,png}` 会保留供恢复使用，其中含有凭据，需要时请自行删除。

如果检测到已有且归属不明的伪装页面，安装器会拒绝覆盖；请使用 `--no-masquerade`，或先手工备份并移除该页面。

如果不需要静态伪装页面，可以使用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --no-masquerade
```

## 关于 Nginx 和 BBR

不需要 Nginx。Hysteria 2 自己处理 ACME、TLS、HTTP/3 伪装和静态页面；安装 Nginx 还可能抢占 443 端口。

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
- 不使用固定密码、虚假默认邮箱或外部 Bing 代理。
- 配置文件写入权限为 `root:hysteria`、`0640`；密码只在安装完成时显示。
- 脚本不会自动读取或上传 GCP 凭据、域名密码或 Hysteria 配置。
- 官方安装器会查询版本 API，并发送系统类型和 CPU 架构用于选择版本；这是更新检查，不是流量统计。

验证范围：已通过 `bash -n install.sh`、`bash install.sh --help`、自动密码校验，以及 `test_startup.sh` 中的启动状态、进程归属、证书错误分类和恢复路径模拟测试。尚未在真实 GCP VM 和域名上完成 ACME 签发、Shadowrocket 扫码及公网端到端测试；`systemctl is-active` 不能单独证明这些步骤成功。连接失败时先检查 `journalctl -u hysteria-server.service -n 100 --no-pager`，再检查 DNS、云端/系统防火墙及客户端 UDP 连通性。

安装前如需审阅脚本：

```bash
curl -fsSLo /tmp/hysteria2-install.sh \
  https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh
less /tmp/hysteria2-install.sh
bash /tmp/hysteria2-install.sh --help
```

## License

MIT
