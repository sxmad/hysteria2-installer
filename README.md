# hysteria2-installer

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
| 1-5 人 | `e2-medium` | 1 个共享 vCPU / 4 GB | 20-30 GB `pd-balanced` |
| 5-15 人，普通网页和视频 | `e2-standard-2` | 2 vCPU / 8 GB | 30 GB `pd-balanced` |
| 10-15 人，经常同时 4K 或下载 | `e2-standard-4` | 4 vCPU / 16 GB | 30-50 GB `pd-balanced` |

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh)
```

脚本默认会：

- 安装官方 Hysteria 2 程序和 systemd 服务；
- 使用端口 `443`；
- 使用 ACME TLS-ALPN 自动申请证书；
- 默认邮箱为 `com.gpugame@gmail.com`；
- 生成随机密码，并在终端显示一次；
- 生成本机静态伪装页面，页面内容为 `asdfq`；
- 使用 Hysteria 自己的 `bbr` 拥塞控制器。
- 安装 `qrencode`，在 Web SSH 终端显示可扫描二维码，并保存 PNG 和受保护的 URI 文本。

脚本不会安装 Nginx、Docker、面板、BBR 内核调优、定时任务或第三方伪装代理，也不会修改 Google Cloud VPC 防火墙。

## 安装前必须准备

1. 准备一个直接解析到 VM 公网 IP 的域名。不要把域名放在 Cloudflare 橙云代理后面。
2. 在 Google Cloud VPC 防火墙放行 **TCP 443 和 UDP 443**。TCP 443 用于 ACME TLS-ALPN 证书申请和续期，UDP 443 用于 Hysteria 流量。
3. 确认 VM 使用 Debian 12/13、Ubuntu LTS 或 Rocky 等带 systemd 的常见 Linux 发行版。Debian/Ubuntu 上脚本会自动执行 `apt-get update` 并安装 `curl`、`openssl`、`qrencode`、`iproute2` 和证书包；不会安装 Nginx。

进入 Google Web SSH 后只需要输入域名；脚本会自动生成随机密码并在完成时显示。脚本不要求重启 VM；如果系统镜像或管理员策略要求重启，脚本会在检查阶段直接报告，而不会擅自重启。

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

安装成功后，脚本会同时输出：

- Shadowrocket 可用的 `hysteria2://` URI；
- 终端 Unicode 二维码，适合直接在 Google Web SSH 页面放大后扫码；
- `/root/hysteria2-域名.png` 二维码图片；
- `/root/hysteria2-域名.txt` 连接信息文件，权限为 `600`。

二维码内容只包含连接 URI，其中包含密码。不要把终端截图或 PNG 发给不需要连接的人。

密码不会放在命令行参数中。自动化部署可通过标准输入传入密码：

```bash
printf '%s\n' 'your-safe-password' | \
  bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --password-stdin
```

其他操作：

```bash
install.sh update
install.sh status
install.sh restart
install.sh uninstall
```

更新会保留现有配置。安装时发现已有配置，会先备份到 `/var/backups/hysteria2-installer/`，然后要求确认是否覆盖；使用 `--yes` 可跳过确认。

如果不需要静态伪装页面，可以使用：

```bash
install.sh install --domain hy2.example.com --no-masquerade
```

## 关于 Nginx 和 BBR

不需要 Nginx。Hysteria 2 自己处理 ACME、TLS、HTTP/3 伪装和静态页面；安装 Nginx 还可能抢占 443 端口。

这里没有默认修改 Linux TCP BBR 的 sysctl。Hysteria 2 使用 QUIC，配置中的 `congestion.type: bbr` 是 Hysteria 自己的拥塞控制器，与 Linux TCP BBR 是两回事。额外安装或修改 TCP BBR 不保证提升 Hysteria 或 YouTube 速度，也会增加系统改动，因此保持关闭。

实际速度更受 VM 所在地区、到客户端的线路、UDP 丢包和 Google Cloud 防火墙影响。

Google Cloud VPC 防火墙属于 VM 外部的云资源，普通 VM 内的 Bash 脚本不能可靠地替你修改它；因此这是创建 VM 时唯一需要在控制台或 `gcloud` 中预先完成的步骤。TCP/UDP 端口规则必须分别放行。

## 安全与可审计性

- 所有安装器行为写在 `install.sh` 中；官方 Hysteria 安装器地址也在文件顶部明确列出。
- 下载官方安装器时强制使用 HTTPS；官方安装器随后从 Hysteria 官方 GitHub Release 下载程序。
- 不使用固定密码、虚假默认邮箱或外部 Bing 代理。
- 配置文件写入权限为 `root:hysteria`、`0640`；密码只在安装完成时显示。
- 脚本不会自动读取或上传 GCP 凭据、域名密码或 Hysteria 配置。
- 官方安装器会查询版本 API，并发送系统类型和 CPU 架构用于选择版本；这是更新检查，不是流量统计。

安装前如需审阅脚本：

```bash
curl -fsSLo /tmp/hysteria2-install.sh \
  https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh
less /tmp/hysteria2-install.sh
bash /tmp/hysteria2-install.sh --help
```

## License

MIT
