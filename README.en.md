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
| 1–5 users | `e2-medium` | 2 shared vCPUs, about 1 core sustained aggregate quota / 4 GB | 20–30 GB `pd-balanced` |
| 5–15 users, normal web and video | `e2-standard-2` | 2 vCPUs / 8 GB | 30 GB `pd-balanced` |
| 10–15 users, frequent 4K or downloads | `e2-standard-4` | 4 vCPUs / 16 GB | 30–50 GB `pd-balanced` |

Installer revision: `2026-10-02.1`. The installer prints this revision at startup.

## One-click installation

Google Web SSH normally signs in as a regular user. Run `sudo -i` first to enter a root shell. Run the installation and management commands below in that root shell.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh)
```

The installer will:

- install the official Hysteria 2 binary and systemd service;
- use port `443` by default;
- request a free Let’s Encrypt certificate through ACME TLS-ALPN and renew it automatically;
- use `com.gpugame@gmail.com` as the default ACME email;
- generate a 16-character random password and display it once at the end (`--password-stdin` still accepts a custom 12–128-character password);
- create a local static masquerade page whose content is `asdfq`, served by Hysteria over both HTTP/3 (UDP 443) and ordinary HTTPS (TCP 443);
- enable Hysteria’s own `bbr` congestion controller;
- install `qrencode`, print a scannable terminal QR code in Google Web SSH, and save a PNG and protected URI text file.

To keep TLS-ALPN certificate validation working, this installer accepts only port `443` and rejects other values.

It does not install Nginx, Docker, panels, Linux TCP BBR sysctl tuning, cron jobs, or third-party masquerade proxies. It does not modify Google Cloud VPC firewall rules.

## Required preparation

1. Use a separate domain/subdomain for the new VM. Point its A record directly to this VM’s static external IPv4. Keep an AAAA record only if it points to this VM’s working public IPv6; remove stale records. Do not use Cloudflare’s orange-cloud proxy. DNS preflight checks resolution only, not ownership of the resolved IP.
2. Allow **TCP 443 and UDP 443** in the Google Cloud VPC firewall. TCP 443 is required for ACME TLS-ALPN validation, renewal, and ordinary browser access to the static page; UDP 443 carries Hysteria/HTTP3 traffic.
3. Use an official Debian 12/13 or Ubuntu LTS image with systemd. The installer uses the existing `apt-get` to install missing dependencies. The entry command itself requires `curl`; if missing, first run `apt-get update && apt-get install -y curl ca-certificates`. RPM distributions such as Rocky have a dependency-installation branch only: ensure `qrencode` is available (EPEL might be required), and configure the OS firewall yourself.

After entering a root shell and running the command, a fresh installation asks only for the domain and generates the password automatically. The installer does not reboot the VM or modify OS or cloud firewall rules.

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

After startup and the local proxy test pass, the script prints the following (public connectivity still needs a client test):

- a `hysteria2://` URI for Shadowrocket;
- a Unicode QR code for scanning from the Google Web SSH page;
- `/root/hysteria2-domain.png`, the QR image;
- `/root/hysteria2-domain.txt`, the connection information with mode `600`.

The installer does not declare success from `systemctl is-active` alone. It waits for ACME certificate processing to finish, confirms that the local UDP 443 listener is present, confirms the TCP 443 listener belongs to the current Hysteria process when static masquerading is enabled, and checks the current service invocation for certificate or configuration errors. It then verifies the local HTTPS page and starts a temporary official Hysteria client, accessing `https://www.google.com/generate_204` through SOCKS5. A URI/QR is exported only after HTTP 204; failures print diagnostics and return a nonzero status. The temporary client config ends in `.yaml`; the password is not a command-line argument. Its process and files are cleaned up on exit.

After installation, an ordinary browser can open `https://your-domain/` and see the `asdfq` page. Shadowrocket uses Hysteria over UDP 443; the browser page uses TCP 443, and both can share the same port number. With `--no-masquerade`, no static page or TCP HTTPS masquerade is created.

For a transient ACME error such as a CA server error, bad nonce, or connection reset, the installer prints the cause and offers `1` to repair and restart, or `2` to abort; it allows at most three repair retries. A TCP 443 timeout/refusal, firewall or DNS/CAA problem, certificate rate limit, port conflict, configuration error, or missing UDP 443 listener cannot be reliably repaired by the installer, so it explains the issue and stops. Cloud UDP firewall reachability cannot be reliably tested from inside the VM, so create both the TCP 443 and UDP 443 rules in Google Cloud first.

Each first certificate attempt can wait for up to about 120 seconds; do not start multiple installer processes during that wait. At the start of a reinstall, same-domain QR and URI files are moved to `/var/backups/hysteria2-installer/` so a failed run cannot leave an old credential looking usable.

The QR code contains the connection URI and therefore the password. Keep the terminal screenshot and PNG private.

For automated deployments, provide a custom password through standard input:

```bash
printf '%s\n' 'your-safe-password' | \
  bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --password-stdin
```

Other operations:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) update
systemctl status hysteria-server.service
systemctl restart hysteria-server.service
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) uninstall
```

Updates back up the current configuration first. Reinstalling over an existing configuration asks for confirmation and saves a backup under `/var/backups/hysteria2-installer/`. Use `--yes` to skip that prompt.

Uninstall only removes users and data directories explicitly recorded as created by this installer. Pre-existing directories and those with unknown ownership history are preserved. Do not store unrelated files in an installer-created `/var/lib/hysteria`. Configuration backups and `/root/hysteria2-domain.{txt,png}` remain for recovery; they contain credentials and can be removed manually when no longer needed.

If an existing masquerade page has unknown ownership, the installer refuses to overwrite it. Use `--no-masquerade`, or back up and remove the page manually first.

To omit the static masquerade page:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --no-masquerade
```

## First Shadowrocket connection

Import the QR and confirm Hysteria2, port 443, the current generated password, and TLS SNI/Peer matching the domain. Displaying `sni` as `peer` is not by itself an error. Select the new node and temporarily use global Proxy routing for the first test; restore your routing rules afterwards. A working browser page verifies TCP HTTPS, not public UDP proxy reachability.

`update` requires an existing Hysteria executable and configuration. It preserves the configuration/password rather than migrating it. Use `install` on a new VM.

## Nginx and BBR

Nginx is unnecessary. Hysteria 2 handles ACME, TLS, HTTP/3, TCP HTTPS masquerading, and the static page itself; installing Nginx could also take over TCP port 443.

The installer does not change Linux TCP BBR sysctl settings. Hysteria 2 uses QUIC, and `congestion.type: bbr` is Hysteria’s own congestion controller. Extra TCP BBR tuning does not guarantee faster Hysteria or YouTube traffic and adds system changes.

BBR is used when the client omits bandwidth hints. Configuring upload or download bandwidth in Shadowrocket can select Brutal for that direction, so the server setting does not force every client to use BBR at all times.

Actual speed depends more on the VM region, the route to clients, UDP packet loss, and Google Cloud firewall rules.

Google Cloud VPC firewall rules are external cloud resources. A normal VM-side Bash script cannot reliably change them without separate cloud IAM permissions, so create the TCP and UDP rules in the console or with `gcloud` before running the installer.

## Security and auditability

- All installer behavior is in `install.sh`; the official Hysteria installer URL is explicit at the top of the file.
- The official installer is downloaded over HTTPS and then downloads the Hysteria binary from official GitHub Releases.
- The official installer endpoint is a dynamic script and is not pinned to a SHA256 in this repository. Review the downloaded script before use when reproducibility is critical.
- Failed downloads, empty files, and Bash syntax errors prevent execution of the official installer. These checks do not replace signature or trusted-hash verification. `--version` does not pin the official installer script.
- The one-click command uses GitHub’s mutable `main` branch. For production, replace `main` with a commit that you have reviewed.
- No fixed password, fake default email, or external Bing masquerade proxy is used.
- The configuration is written as `root:hysteria` with mode `0640`; the generated URI text file is mode `0600`.
- The script does not read or upload GCP credentials, domain credentials, or the Hysteria configuration.
- The official installer checks a version API and sends OS and CPU architecture information to select a release; it does not collect proxy traffic.

Validation scope: `bash -n install.sh`, `bash install.sh --help`, and `bash test_startup.sh` cover syntax, 16-character passwords, listener ownership, and certificate recovery. `test_proxy.sh` uses a real Hysteria binary with isolated test certificates and an HTTPS target to verify TLS, authentication, SOCKS forwarding, and failure cleanup. Test certificates are never used by the installer. These tests are not a fresh GCP/systemd/ACME installation or phone/public-network test; installation runs the real Google HTTP 204 test again on your VM. Cloud UDP firewall and client-network reachability still require an external client test.

This review used Hysteria v2.12.3. The restricted test runner required explicit `HYSTERIA_TEST_NO_PID_CHECK=1` because netlink/PID inspection is unavailable; ownership checks were separately covered by mocks. The production installer has no bypass flag. The optional Google test could not pass because this runner blocks outbound DNS, so Internet validation is unverified. On a normal Linux host, run:

```bash
bash test_startup.sh
HYSTERIA_TEST_BINARY=/usr/local/bin/hysteria bash test_proxy.sh
```


Review the installer before running it:

```bash
curl -fsSLo /tmp/hysteria2-install.sh \
  https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh
less /tmp/hysteria2-install.sh
bash /tmp/hysteria2-install.sh --help
```

## License

MIT
