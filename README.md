# hysteria2-installer

[English](README.md) | [简体中文](README.zh-CN.md)

Hysteria 2 installer for Google Cloud VMs and Shadowrocket. Revision **2026-10-18.2** supports custom **UDP** ports and coexistence with Trojan in either installation order.

Hysteria proxy transport is QUIC over UDP. Forwarding a TCP website connection through Hysteria does not change the outer transport to TCP. Optional ordinary HTTPS masquerading is a separate TCP listener.

## Install

Point the exact `--domain` A record at the VM public IPv4. Allow inbound **TCP 80** for certificate issuance/renewal and the selected **UDP proxy port** in both GCP and any active host firewall. Match the VM's VPC and target tag/service account. Do not leave an incorrect AAAA record or enable a domain CDN proxy.

```bash
sudo bash -c 'bash <(curl -fsSL --proto "=https" --tlsv1.2 \
  https://raw.githubusercontent.com/sxmad/hysteria2-installer/main/install.sh) install \
  --domain hy2.example.com \
  --email you@example.com \
  --port 8443'
```

Omit `--port` for UDP 443. Missing domain/email values are prompted; neither has a default. A random 16-character password is generated. Prefer a standard Debian/Ubuntu VM with systemd; `lego`, `openssl`, `python3`, `curl`, `iproute2`, `util-linux` and QR dependencies must be available from the OS repositories. The official Hysteria installer supplies the core and service.

[Unified installer](https://github.com/sxmad/mofatizi-installer): menu `1: all`, `2: trojan`, `3: hysteria2`; it preserves existing configurations by default.

## Coexistence and ports

| Function | Port | Notes |
|---|---|---|
| Hysteria proxy / HTTP/3 page | UDP `--port`, default 443 | 8443 and other values from 1–65535 are accepted. |
| Certificate issuance and renewal | TCP 80 | Independent of the UDP port; keep allowed after installation. |
| Ordinary HTTPS page | Off by default | Enable with `--https-port PORT`; TCP 80 is reserved. |
| Trojan alongside Hysteria | Its chosen TCP port | TCP 443 and UDP 443 can coexist. |

Fresh installations do not reserve TCP 443. These combinations work without stopping the other protocol:

- Trojan TCP 443 + Hysteria UDP 8443.
- Trojan TCP 8443 + Hysteria UDP 443.
- Trojan TCP 443 + Hysteria UDP 443.

Port checks distinguish TCP from UDP and reject another process using the **same transport and port**. No other service is stopped to free a port. GCP's “Allow HTTPS traffic” checkbox does not automatically allow UDP or TCP 8443.

**Legacy installations:** revision 2026-10-18.1 and earlier used built-in TLS-ALPN on TCP 443 and normally served an HTTPS page there. `update` preserves that existing configuration. When adding Trojan to such a VM, choose an unused TCP port such as 8443. To free legacy TCP 443, explicitly reinstall Hysteria with its original domain, UDP port and password using this new installer; this changes its certificate management and may briefly interrupt Hysteria. There is no silent migration or automatic shutdown of the existing protocol.

## Static page

The local page contains `asdfq` and uses English HTML metadata. By default it is served through HTTP/3 on the Hysteria UDP port; ordinary TCP HTTPS browser access is not enabled.

For an ordinary HTTPS page, explicitly choose an unused TCP port and allow it in the firewall:

```bash
sudo bash install.sh install \
  --domain hy2.example.com \
  --email you@example.com \
  --port 8443 \
  --https-port 9443
```

The page is then `https://hy2.example.com:9443/`. `--no-masquerade` omits the page and cannot be combined with `--https-port`. A working page alone does not prove proxy authentication or public UDP reachability.

## Options

| Option | Behavior |
|---|---|
| `--domain DOMAIN`, `--email EMAIL` | Required identity, prompted when omitted. |
| `--port PORT` | UDP proxy port, default 443. |
| `--https-port PORT` | Optional TCP HTTPS page; 0 disables it. Default 0; TCP 80 is reserved. |
| `--password-stdin` | Read the original/custom password, 12–128 letters, digits, `.`, `_`, `-`. Empty input is rejected. |
| `--version v2.x.y` | Request a specific stable Hysteria 2 core. |
| `--no-masquerade` | Omit the local HTTP/3/HTTPS page. |
| `--yes` | Confirm replacement of this protocol's existing config. |
| `--help` | Show help. |

Without `--password-stdin`, reinstalling generates a new password. The unified installer skips existing configurations unless `--reinstall` is supplied. To move VMs without editing client configuration, keep domain/SNI, UDP port and password, point the A record to the new VM, and obtain a valid certificate. DNS caching/reconnection can cause an interruption.

```bash
sudo bash -c '
set -e
IFS= read -r -s -p "Original Hysteria password: " hy2_password
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

## Certificates and renewal

New installs use `lego` HTTP-01, then configure Hysteria with `/etc/hysteria/cert.pem` and `/etc/hysteria/key.pem`. The private key is readable by the service group, not the public. The independent account/certificate cache is `/var/lib/hysteria/lego`.

`hysteria-cert-renew.timer` checks daily with randomized delay; it renews within 30 days of expiry. Issuance and renewal share `/run/lock/trojan-cert-renew.lock` with the Trojan installer. This existing lock name also coordinates with older Trojan renewal jobs without changing their configuration. Do not delete the lock file while either protocol is operating.

Renewal checks hostname, expiry and the certificate/key match before deployment. Invalid or failed ACME requests retain the deployed files. A cached renewed certificate is redeployed after a previous copy failure. Hysteria reads certificate files on new handshakes, so renewal does **not** restart the proxy. No periodic proxy restart is installed.

```bash
sudo systemctl status hysteria-cert-renew.timer --no-pager
sudo journalctl -u hysteria-cert-renew.service --since '7 days ago' --no-pager
```

HTTP-01 needs public TCP 80 regardless of `--port`. A timeout/refusal prints actionable DNS/firewall diagnostics and stops. The installer does not modify GCP or host firewall rules, stop another web server, or bypass certificate validation.

## Verification and Shadowrocket

Installation checks the current service process's UDP listener, the optional TCP HTTPS listener, and startup logs. It then runs a real temporary Hysteria client and requires HTTPS Google HTTP 204 through SOCKS5 before exporting credentials/QR. The temporary client and files are cleaned up. Public GCP UDP ingress and your actual Shadowrocket route still need an external client test.

Import the new QR or URI. Check Hysteria2, the selected **UDP port**, password, and SNI/Peer matching the certificate domain. A UDP-forwarding switch controls forwarded application UDP, not Hysteria's outer QUIC transport.

```bash
sudo systemctl status hysteria-server.service --no-pager
sudo journalctl -b -u hysteria-server.service --since '10 minutes ago' --no-pager
sudo ss -H -lunp 'sport = :8443'
```

## Update and operation

Download the current installer, then:

```bash
sudo bash install.sh update
sudo bash install.sh status
# Also supported: start, stop, restart
```

`update` preserves configuration, password, certificate mode, custom UDP/TCP page ports, and whether the service was stopped or running. It updates the core and managed recovery policy; it does not migrate old TLS-ALPN configurations to HTTP-01. Publishing repository changes alone does not update VMs.

The managed drop-in `/etc/systemd/system/hysteria-server.service.d/20-hysteria2-installer.conf` applies `Restart=on-failure`, `RestartSec=5s`, memory accounting, and at most 5 starts in 300 seconds. A manual stop stays stopped. After repeated failures hit the limit, fix the cause and run `systemctl reset-failed hysteria-server.service` followed by `systemctl start hysteria-server.service`. Unknown administrator drop-ins are preserved.

## Long-running memory

The installer exits; long-running memory belongs to the Hysteria core. No fixed memory ceiling, scheduled daily restart, kernel TCP BBR tuning, Nginx, Docker or third-party masquerade proxy is installed. Hysteria's own QUIC BBR is configured. Normal buffer/load fluctuations are not proof of a memory leak, and functional tests do not prove leak-free operation over days.

Collect samples across comparable load/idle periods for 24–72 hours before deciding on a restart:

```bash
sudo systemctl show hysteria-server.service \
  -p MainPID -p MemoryCurrent -p MemoryPeak -p NRestarts -p Result
proxy_pid=$(systemctl show hysteria-server.service -p MainPID --value)
ps -p "$proxy_pid" -o pid,etimes,rss,%mem,cmd
free -h
sudo journalctl -k --since '24 hours ago' | grep -Ei 'oom|out of memory|killed process'
df -h / /var/log
```

RSS is KiB; cgroup memory is bytes and can include more than process RSS. Journald/disk growth is separate from heap growth. Retain version, workload, uptime, samples and redacted logs. Upgrade a known affected core when an upstream fix exists; arbitrary restart schedules or memory limits do not repair a leak and may interrupt connections.

## Uninstall and tests

`sudo bash install.sh uninstall` removes Hysteria resources and its renewal timer, preserves configuration backups and unknown administrator files, and leaves Trojan and the shared lock untouched. Existing directories/users with unknown ownership are preserved. No VM reboot is required.

```bash
bash test_startup.sh
python3 test_service_policy.py
python3 test_coexist.py
HYSTERIA_TEST_BINARY=/path/to/hysteria bash test_proxy.sh
# Disposable systemd host only:
sudo env HYSTERIA_TEST_SYSTEMD=1 bash test_service_systemd.sh
```

Tests cover startup, port separation, custom config/update, HTTP-01 locking, real certificate fixtures, renewal failures/retries, actual TLS/authentication/forwarding, and systemd recovery. The unified repository additionally tests real Trojan/Hysteria coexistence in both start orders. They do not replace public ACME/GCP/Shadowrocket deployment checks or a multi-day soak test.

References: [Hysteria configuration](https://v2.hysteria.network/docs/advanced/Full-Server-Config/) · [HTTP-01](https://letsencrypt.org/docs/challenge-types/#http-01-challenge)
