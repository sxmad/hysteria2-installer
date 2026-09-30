# hysteria2-installer

[简体中文](README.md) | [English](README.en.md)

A clean, minimal Hysteria 2 installer for Google Cloud VMs. It uses UDP/TCP 443 by default and is suitable for Shadowrocket.

## Recommended Google Cloud VM

For up to 15 users with speed as the priority:

- **Machine type:** `e2-standard-2`, 2 vCPUs and 8 GB RAM. It is better suited to sustained video traffic than shared-core machines.
- **OS:** Debian 13. Debian 12 also works. Google Cloud's Debian images include the guest environment required for browser-based SSH.
- **Disk:** 30 GB `pd-balanced`. Hysteria does not store proxy traffic, so Local SSD is unnecessary.
- **Network:** Premium Tier and a reserved static external IPv4 address. Choose the region using real client latency, packet loss, and YouTube throughput tests.

If 10–15 users will frequently stream 4K video or download large files at the same time, use **`e2-standard-4`** with 4 vCPUs and 16 GB RAM. `e2-medium` is suitable for a small, light-use personal node. Avoid `e2-micro` and `e2-small` when sustained speed matters because they use shared CPU.

| Workload | Machine type | CPU / RAM | Disk |
|---|---|---:|---:|
| 1–5 users | `e2-medium` | 1 shared vCPU / 4 GB | 20–30 GB `pd-balanced` |
| 5–15 users, normal web and video | `e2-standard-2` | 2 vCPUs / 8 GB | 30 GB `pd-balanced` |
| 10–15 users, frequent 4K or downloads | `e2-standard-4` | 4 vCPUs / 16 GB | 30–50 GB `pd-balanced` |

## One-click installation

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh)
```

The installer will:

- install the official Hysteria 2 binary and systemd service;
- use port `443` by default;
- request a free Let’s Encrypt certificate through ACME TLS-ALPN and renew it automatically;
- use `com.gpugame@gmail.com` as the default ACME email;
- generate a strong random password and display it once at the end;
- create a local static masquerade page whose content is `asdfq`;
- enable Hysteria’s own `bbr` congestion controller;
- install `qrencode`, print a scannable terminal QR code in Google Web SSH, and save a PNG and protected URI text file.

It does not install Nginx, Docker, panels, Linux TCP BBR sysctl tuning, cron jobs, or third-party masquerade proxies. It does not modify Google Cloud VPC firewall rules.

## Required preparation

1. Point a domain directly to the VM’s public IP. Do not put it behind Cloudflare’s orange-cloud proxy.
2. Allow **TCP 443 and UDP 443** in the Google Cloud VPC firewall. TCP 443 is required for ACME TLS-ALPN validation and renewal; UDP 443 carries Hysteria traffic.
3. Use Debian 12/13, Ubuntu LTS, Rocky, or another standard systemd-based image. On Debian and Ubuntu, the installer runs `apt-get update` and installs missing `curl`, `openssl`, `qrencode`, `iproute2`, and CA certificates. It does not install Nginx.

After opening Google Web SSH, enter only the domain. The password is generated automatically. A VM reboot is normally unnecessary; the installer never reboots the VM by itself.

## Usage

Without arguments, the script asks for the domain and uses the default email and port:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh)
```

You can also specify the domain explicitly:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email com.gpugame@gmail.com
```

On success, the script prints:

- a `hysteria2://` URI for Shadowrocket;
- a Unicode QR code for scanning from the Google Web SSH page;
- `/root/hysteria2-domain.png`, the QR image;
- `/root/hysteria2-domain.txt`, the connection information with mode `600`.

The QR code contains the connection URI and therefore the password. Keep the terminal screenshot and PNG private.

For automated deployments, provide a custom password through standard input:

```bash
printf '%s\n' 'your-safe-password' | \
  bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --password-stdin
```

Other operations:

```bash
install.sh update
install.sh status
install.sh restart
install.sh uninstall
```

Updates keep the existing configuration. If an installation finds an existing configuration, it creates a backup under `/var/backups/hysteria2-installer/` before asking to overwrite it. Use `--yes` to skip that prompt.

To omit the static masquerade page:

```bash
install.sh install --domain hy2.example.com --no-masquerade
```

## Nginx and BBR

Nginx is unnecessary. Hysteria 2 handles ACME, TLS, HTTP/3 masquerading, and the static page itself; installing Nginx could also take over port 443.

The installer does not change Linux TCP BBR sysctl settings. Hysteria 2 uses QUIC, and `congestion.type: bbr` is Hysteria’s own congestion controller. Extra TCP BBR tuning does not guarantee faster Hysteria or YouTube traffic and adds system changes.

Actual speed depends more on the VM region, the route to clients, UDP packet loss, and Google Cloud firewall rules.

Google Cloud VPC firewall rules are external cloud resources. A normal VM-side Bash script cannot reliably change them without separate cloud IAM permissions, so create the TCP and UDP rules in the console or with `gcloud` before running the installer.

## Security and auditability

- All installer behavior is in `install.sh`; the official Hysteria installer URL is explicit at the top of the file.
- The official installer is downloaded over HTTPS and then downloads the Hysteria binary from official GitHub Releases.
- No fixed password, fake default email, or external Bing masquerade proxy is used.
- The configuration is written as `root:hysteria` with mode `0640`; the generated URI text file is mode `0600`.
- The script does not read or upload GCP credentials, domain credentials, or the Hysteria configuration.
- The official installer checks a version API and sends OS and CPU architecture information to select a release; it does not collect proxy traffic.

Review the installer before running it:

```bash
curl -fsSLo /tmp/hysteria2-install.sh \
  https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh
less /tmp/hysteria2-install.sh
bash /tmp/hysteria2-install.sh --help
```

## License

MIT
