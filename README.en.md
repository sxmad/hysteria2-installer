# hysteria2-installer

[简体中文](README.md) | [English](README.en.md)

A clean, minimal Hysteria 2 installer for Google Cloud VMs. It uses UDP/TCP 443 by default and is suitable for Shadowrocket.

[Install](#one-click-installation) · [Preparation](#required-preparation) · [Options](#installation-options) · [Manage](#service-management-and-updates) · [Uninstall and retest](#uninstall-and-retest) · [Troubleshooting](#troubleshooting) · [Validation](#validation-scope)

## Recommended Google Cloud VM

These are starting configurations for up to 15 users, not guarantees of concurrency or speed. Adjust them using actual CPU, memory, and network measurements:

- **Machine type:** `e2-standard-2`, 2 vCPUs and 8 GB RAM. It is better suited to sustained video traffic than shared-core machines.
- **OS:** Debian 13. Debian 12 also works. Google Cloud's Debian images include the guest environment required for browser-based SSH.
- **Disk:** 30 GB `pd-balanced` (Balanced Persistent Disk). This configuration does not record traffic contents, so Local SSD is unnecessary. `pd-balanced` and `pd-extreme` are different disk types.
- **Network:** Premium Tier and a reserved static external IPv4 address. Choose the region using real client latency, packet loss, and YouTube throughput tests.

If 10–15 users will frequently stream 4K video or download large files at the same time, use **`e2-standard-4`** with 4 vCPUs and 16 GB RAM. `e2-medium` is suitable for a small, light-use personal node. Avoid `e2-micro` and `e2-small` when sustained speed matters because they use shared CPU.

| Workload | Machine type | CPU / RAM | Disk |
|---|---|---:|---:|
| 1–5 users | `e2-medium` | 2 shared vCPUs, about 1 core sustained aggregate quota / 4 GB | 20–30 GB `pd-balanced` |
| 5–15 users, normal web and video | `e2-standard-2` | 2 vCPUs / 8 GB | 30 GB `pd-balanced` |
| 10–15 users, frequent 4K or downloads | `e2-standard-4` | 4 vCPUs / 16 GB | 30–50 GB `pd-balanced` |

Installer revision: `2026-10-02.2`. The installer prints this revision at startup.

## One-click installation

Google Web SSH normally signs in as a regular user. Run `sudo -i` first to enter a root shell. Run the installation and management commands below in that root shell.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email you@example.com
```

Replace the example domain and email with your own values. Neither has a default. Providing both avoids these prompts on a fresh installation.

The installer will:

- install the official Hysteria 2 binary and systemd service;
- use port `443` by default;
- request a free Let’s Encrypt certificate through ACME TLS-ALPN and renew it automatically while Hysteria is running;
- start `hysteria-server.service` and enable it at boot;
- use the domain and ACME email supplied as arguments or entered during installation;
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

**Firewall rules must actually match this VM’s VPC, target network tags, or target service account.** Selecting “Allow HTTPS traffic” does not replace checking the UDP 443 rule. Source ranges must cover the clients; TCP 443 must also accept certificate validation traffic. This configuration does not use HTTP port 80 or load-balancer health checks. The VM also needs working DNS and outbound access to GitHub, the certificate authority, and Google.

After entering a root shell and running the command, the installer asks only for the domain or email missing from the arguments and generates the password automatically. A successful installation requires no VM reboot. The installer does not reboot the VM or modify OS or cloud firewall rules.

## Usage

Without arguments, the script asks for both the domain and email; both are required. The port defaults to 443, and the password is generated automatically:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh)
```

For one-command deployment, specify both the domain and email. If only one is provided, the installer asks only for the missing value. If a missing value cannot be read from input, the installer reports an error and stops:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email you@example.com
```

After startup and the local proxy test pass, the following are normally generated (public connectivity still needs a client test):

- a `hysteria2://` URI for Shadowrocket;
- a Unicode QR code for scanning from the Google Web SSH page;
- `/root/hysteria2-domain.png`, the QR image;
- `/root/hysteria2-domain.txt`, the connection information; both PNG and text files use mode `600`.

If QR generation or display fails, the installer warns you; import the printed URI instead. A QR display failure alone does not mean the proxy service failed.

The installer does not declare success from `systemctl is-active` alone. It waits for ACME certificate processing to finish, confirms that the local UDP 443 listener is present, confirms the TCP 443 listener belongs to the current Hysteria process when static masquerading is enabled, and checks the current service invocation for certificate or configuration errors. It then verifies the local HTTPS page and starts a temporary official Hysteria client, accessing `https://www.google.com/generate_204` through SOCKS5. A URI/QR is exported only after HTTP 204; failures print diagnostics and return a nonzero status. The temporary client config ends in `.yaml`; the password is not a command-line argument. Its process and files are cleaned up on exit.

After installation, an ordinary browser can open `https://your-domain/` and see the `asdfq` page. Shadowrocket uses Hysteria over UDP 443; the browser page uses TCP 443, and both can share the same port number. With `--no-masquerade`, no static page or TCP HTTPS masquerade is created.

For a transient ACME error such as a CA server error, bad nonce, or connection reset, the installer prints the cause and offers `1` to repair and restart, or `2` to abort; it allows at most three repair retries. “Repair” preserves existing certificate/account caches and restarts the service; it does not change DNS or cloud firewall rules. Without an interactive terminal, repair selection is unavailable and installation stops. `--yes` does not automatically select repair. A TCP 443 timeout/refusal, firewall or DNS/CAA problem, certificate rate limit, port conflict, configuration error, or missing UDP 443 listener cannot be reliably repaired by the installer, so it explains the issue and stops. Cloud UDP firewall reachability cannot be reliably tested from inside the VM, so create both the TCP 443 and UDP 443 rules in Google Cloud first.

Each first certificate attempt can wait for up to about 120 seconds; do not start multiple installer processes during that wait. At the start of a reinstall, same-domain QR and URI files are moved to `/var/backups/hysteria2-installer/` so a failed run cannot leave an old credential looking usable.

Publishing a new installer does not modify existing deployments. The revised domain and email prompts apply only to future installation runs.

The QR code contains the connection URI and therefore the password. Keep the terminal screenshot and PNG private.

For automated deployments, provide a custom password through standard input:

```bash
printf '%s\n' 'your-safe-password' | \
  bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email you@example.com --password-stdin
```

## Installation options

| Option | Behavior |
|---|---|
| `--domain DOMAIN` | No default; prompted at the start of installation if omitted. |
| `--email EMAIL` | No default; the ACME email is prompted at the start if omitted. |
| `--port PORT` | Defaults to `443`; only `443` is supported. |
| `--password-stdin` | Read a custom 12–128-character password from stdin: letters, digits, `.`, `_`, or `-` only. Otherwise generate 16 random characters. |
| `--no-masquerade` | Omit the static page; certificate issuance/renewal still requires TCP 443. |
| `--version v2.x.y` | Install/update a specific stable Hysteria release. If omitted, the official installer selects the latest release. This is not the installer revision. |
| `--yes` / `-y` | Skip confirmation for overwriting an existing config or uninstalling; does not bypass input, self-tests, or certificate error handling. |
| `--help` | Show help and the installer revision. |

Specify both domain and email for automation. When piping a password to reinstall over an existing config, also explicitly add `--yes`; otherwise overwrite confirmation is still required. With `--password-stdin`, missing domain/email values are read only from an interactive terminal so the password pipe is preserved; no terminal means the installer stops.

## Service management and updates

Check status:

```bash
systemctl --no-pager --full status hysteria-server.service
systemctl is-enabled hysteria-server.service
systemctl is-active hysteria-server.service
```

Update the program when needed:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) update
```

Restart the service when needed:

```bash
systemctl restart hysteria-server.service
```

After a normal installation, `is-enabled` should report `enabled` and `is-active` should report `active`. These describe boot and process state only; acceptance still requires a real client connection. The script also supports `start`, `stop`, `restart`, and `status` subcommands.

`update` requires an existing Hysteria binary and configuration. It backs up and preserves the current config/password without migrating old settings. A previously running service is restarted and checked for startup readiness; a previously stopped service remains stopped. `update` does not run the full installation proxy self-test or regenerate QR codes; test your existing client node afterwards. Use `install` on a new VM.

Running `install` again backs up and replaces the configuration and generates a new password by default, so import the new QR. It asks before overwriting; `--yes` skips that confirmation. Publishing new repository files alone does not update an existing deployment.

## Uninstall and retest

Run these commands in a root shell. Uninstall interrupts existing connections; enter `y` at the prompt:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) uninstall
```

Uninstall stops and disables the service, calls the official uninstaller to remove the program/service files, and deletes the active `/etc/hysteria/config.yaml`.

Users and data directories are removed only when installer state records ownership and the relevant cleanup conditions are met. If `/var/lib/hysteria` is recorded as installer-created, the entire directory is removed, including its certificate cache and static page; do not put unrelated files there. Pre-existing directories or those with unknown ownership history are retained with a message.

The following remain: backups under `/var/backups/hysteria2-installer/`, `/root/hysteria2-domain.{txt,png}`, dependency packages, DNS records, and Google Cloud firewall rules. Backups and connection files contain credentials and can be removed manually when no longer needed; they are not automatically restored into a new config.

After uninstall completes, reinstall without arguments to test the domain/email prompts:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh)
```

Alternatively, use the two-argument command under [One-click installation](#one-click-installation). Confirm the revision, provide your own domain/email, wait for startup and local proxy tests, then import the **new QR** into Shadowrocket. Neither installation nor uninstall requires a VM reboot.

Reinstalling is not a fresh-OS test: dependencies and directories with unknown ownership may remain. Use a new VM or a fresh OS to test initial dependency installation and certificate issuance. Avoid repeatedly deleting certificate caches just to retest; reinstalling cannot remove certificate-authority rate limits.

If an existing masquerade page has unknown ownership, the installer refuses to overwrite it. Use `--no-masquerade`, or back up and remove the page manually first.

## Optional: disable the static page

To omit the static masquerade page:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) \
  install --domain hy2.example.com --email you@example.com --no-masquerade
```

## First Shadowrocket connection

Import the QR and confirm Hysteria2, port 443, the current generated password, and TLS SNI/Peer matching the domain. Displaying `sni` as `peer` is not by itself an error. Select the new node and temporarily use global Proxy routing for the first test; restore your routing rules afterwards. A working browser page verifies TCP HTTPS, not public UDP proxy reachability.

## Troubleshooting

| Symptom | Check first |
|---|---|
| `apt-get` prints `Get`, `Hit`, or `Reading package lists... Done` | Normal dependency logs, not completion of the whole installation; wait for final self-tests and connection information. |
| ACME `Timeout during connect` / `likely firewall problem` | Domain A/AAAA, inbound TCP 443, and whether the rule targets this VM. Correct these before retrying. |
| `rate limited` / `Retry-After` | Wait as instructed; reinstalling or deleting caches does not remove limits. |
| Service is `active`, but the phone has no Internet | Check cloud/OS UDP 443 rules, the current QR password, SNI/Peer, selected Shadowrocket node and routing, then test another phone network. |
| The `asdfq` page works but the proxy does not | The page verifies TCP HTTPS only; check UDP and the client connection. |
| Local proxy test does not return HTTP 204 | Follow the error to check authentication, certificates, VM DNS, and outbound access. No new QR is exported. |
| Custom client config reports `Unsupported Config Type` | Use a `.yaml` config suffix. This error does not indicate an outdated protocol. |
| Root permission error | Run `sudo -i`, then retry the command. |

Read service status and recent logs (these commands do not directly read the config; logs can contain client addresses or sensitive authentication information, so review and redact before sharing):

```bash
systemctl --no-pager --full status hysteria-server.service
journalctl -b -u hysteria-server.service --since '10 minutes ago' --no-pager
ss -H -ltnup 'sport = :443'
```

If startup checks fail, the installer attempts to stop the unready service before reporting failure. If the local functional self-test fails, the service/config are retained for diagnosis. Neither failure exports new connection information or QR codes. Fix the reported cause before retrying installation; a VM reboot alone cannot repair DNS or cloud firewall rules.

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
- No fixed password, default domain, default email, or external Bing masquerade proxy is used.
- The configuration is written as `root:hysteria` with mode `0640`; the generated URI text file is mode `0600`.
- The script does not read GCP/domain account credentials or upload the local Hysteria configuration. It does read, back up, and check the configuration locally.
- The official installer checks a version API and sends OS and CPU architecture information to select a release; it does not collect proxy traffic.

## Validation scope

**Deployment feedback, 2026-10-02: the maintainer confirmed that the complete workflow for revision `2026-10-02.2` passed testing.** Earlier feedback confirmed a fresh Google Cloud Debian 13 VM and working Shadowrocket connections. This is maintainer-reported deployment evidence, not a guarantee for every distribution, region, ISP, or client version.

Code tests: `bash -n install.sh`, `bash install.sh --help`, and `bash test_startup.sh` cover syntax, explicit/missing domain and email input, password stdin, 16-character passwords, listener ownership, certificate recovery, and withholding QR output on failure. `test_proxy.sh` uses a real Hysteria binary with isolated test certificates and an HTTPS target to verify TLS, authentication, SOCKS forwarding, and failure cleanup. Test certificates are never used by the installer. These tests are not a fresh GCP/systemd/ACME installation or phone/public-network test; installation runs the real Google HTTP 204 test again on your VM. Cloud UDP firewall and client-network reachability still require an external client test.

This review used Hysteria v2.12.3. The restricted test runner required explicit `HYSTERIA_TEST_NO_PID_CHECK=1` because netlink/PID inspection is unavailable; ownership checks were separately covered by mocks. The production installer has no bypass flag. The Google test could not pass in that runner because outbound DNS is blocked; the real deployment feedback above is recorded separately. From the repository directory on a normal Linux host with the test scripts’ dependencies installed, run:

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

## Official references

- [Hysteria server configuration: ACME, congestion control, and masquerading](https://hysteria.network/docs/advanced/Full-Server-Config/)
- [Google Cloud VPC firewall rules](https://docs.cloud.google.com/firewall/docs/firewalls)
- [Google Cloud Persistent Disk types](https://docs.cloud.google.com/compute/docs/disks/persistent-disks)

## License

MIT
