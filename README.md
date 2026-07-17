# WireGuard Personal Proxy

A Docker container that runs a WireGuard VPN server on a Raspberry Pi, acting as a personal proxy. All traffic from connected devices exits from the Pi's public IP — indistinguishable from someone browsing directly on the Pi's network.

## Features

- **Full tunnel VPN** — all traffic (TCP, UDP, DNS, WebRTC) routed through the Pi
- **Built-in validating DNS resolver** (Unbound with DNSSEC validation) — prevents DNS leaks, detects spoofed or poisoned DNS answers, no geolocation mismatch
- **Dynamic DNS** (DuckDNS) — auto-updates every 60 seconds when your IP changes
- **Whitelist-only access** — devices must be explicitly added via CLI
- **QR code onboarding** — scan from the WireGuard mobile app to connect instantly
- **Minimal attack surface** — only UDP port 51820 exposed, no web UI

## Prerequisites

- Raspberry Pi 4 (2GB+ RAM recommended) running a 64-bit OS
- Docker Engine 25+ and Docker Compose installed (the image build uses BuildKit's checksum-verified downloads)
- A [DuckDNS](https://www.duckdns.org/) account (free)
- UDP port 51820 forwarded on your router to the Pi's LAN IP

### Install Docker on the Pi

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
sudo systemctl enable docker
# Log out and back in for group changes to take effect
```

The `systemctl enable docker` ensures the Docker daemon starts on boot (important for surviving power loss — see [Auto-Start on Boot](#auto-start-on-boot)).

## Quick Start

### 1. Clone and configure

```bash
git clone <your-repo-url> && cd proxy-container
cp .env.example .env
```

Edit `.env` with your values:

```
SERVER_URL=yourname.duckdns.org
SERVER_PORT=51820
INTERNAL_SUBNET=10.13.13.0/24
DUCKDNS_TOKEN=your-duckdns-token-here
DUCKDNS_SUBDOMAIN=yourname
TZ=Europe/Warsaw
```

| Variable | Description |
|----------|-------------|
| `SERVER_URL` | Your DuckDNS hostname (e.g., `myproxy.duckdns.org`) |
| `SERVER_PORT` | WireGuard listen port (default: `51820`). Can be changed later — see [Changing settings after first run](#changing-settings-after-first-run) |
| `INTERNAL_SUBNET` | VPN subnet (default: `10.13.13.0/24`). **Must be a /24 in the form `x.x.x.0/24`** — the container refuses first start otherwise. Change it only if this range could collide with a network your devices roam onto. **Takes effect on first run only** — see [Changing settings after first run](#changing-settings-after-first-run). The DNS resolver configures itself from it automatically. The IPv6 ULA prefix (`fd00::/64`) is fixed and not controlled by this variable |
| `DUCKDNS_TOKEN` | Your DuckDNS API token |
| `DUCKDNS_SUBDOMAIN` | Your DuckDNS subdomain (without `.duckdns.org`) |
| `TZ` | Timezone for the container (e.g., `Europe/Warsaw`) |

### 2. Start the container

```bash
docker compose up -d
```

On first run, the container generates WireGuard server keys and config automatically.

### 3. Forward the port

On your home router, forward **UDP port 51820** to your Pi's LAN IP address.

### 4. Add a device

```bash
docker exec wireguard add-peer my-phone
```

This outputs a QR code in the terminal. Open the WireGuard app on your phone and scan it.

For laptops/desktops, copy the generated config file (it contains the
device's private key, so it is root-owned and readable only with sudo):

```bash
sudo cat ./config/peers/my-phone/my-phone.conf
```

Import it into the WireGuard desktop client.

## Auto-Start on Boot

No extra setup is needed — the proxy already comes back automatically after a reboot or power loss:

1. **Docker starts on boot.** The install steps above ran `systemctl enable docker` (on Raspberry Pi OS and other Debian-based systems this is the default anyway).
2. **Docker restarts the container.** `docker-compose.yml` sets `restart: unless-stopped`. Docker stores this policy with the container, and the daemon restarts any container that was running when the system went down — including an unclean shutdown like a power cut. No user needs to be logged in; the Docker daemon is a system service.

After a power loss: the Pi boots, Docker starts the container, and within ~60 seconds DuckDNS updates your IP. Clients reconnect automatically if the public IP stayed the same; if it changed, see [IP changed and clients disconnected](#ip-changed-and-clients-disconnected).

### Verify

```bash
sudo systemctl is-enabled docker
# Should print: enabled

docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' wireguard
# Should print: unless-stopped
```

For a full end-to-end check, run `sudo reboot`, wait for the Pi to come back, then:

```bash
docker exec wireguard wg show
```

### When it will *not* auto-start

Docker deliberately does not resurrect a container you stopped yourself:

- After `docker stop wireguard` or `docker compose stop`, the container stays stopped across reboots until you start it again.
- After `docker compose down`, the container is removed entirely (its restart policy is removed with it). Run `docker compose up -d` to bring the proxy back.

## Peer Management

All management is done via SSH into the Pi, then `docker exec`:

```bash
# Add a new device (generates config + QR code)
docker exec wireguard add-peer <name>

# Remove a device
docker exec wireguard remove-peer <name>

# List all whitelisted devices and their connection status
docker exec wireguard list-peers
```

Only devices that have been explicitly added can connect. WireGuard enforces this cryptographically — there is no way to connect without a valid keypair.

## Changing settings after first run

The WireGuard server config (`./config/wg/wg0.conf`) is generated once, on first
start. After that, editing `.env` and running `docker compose up -d` has the
following effects:

| Variable | What happens |
|----------|--------------|
| `SERVER_PORT` | Applied automatically on the next start (the container updates `wg0.conf` and logs a warning). **Existing peer configs still point at the old port** — re-issue each one (`remove-peer <name>` then `add-peer <name>`) and update your router's port forward |
| `INTERNAL_SUBNET` | **Ignored** (a warning is logged). To actually change the subnet: `docker compose down`, delete `./config/wg` and `./config/peers`, `docker compose up -d`, then re-add every peer. This regenerates the server keys, so all devices must be re-onboarded |
| `SERVER_URL` | Used for peers created from now on. Already-deployed peer configs keep the old hostname — re-issue them if the hostname changed |
| `DUCKDNS_TOKEN`, `DUCKDNS_SUBDOMAIN`, `TZ` | Applied on the next `docker compose up -d` |

If clients suddenly cannot connect after you edited `.env`, check the container
logs for `[wg-init] WARNING` lines: `docker compose logs wireguard | grep WARNING`

## How It Works

```
Your Phone (abroad)              Raspberry Pi (home)         Internet
┌──────────────┐    encrypted     ┌──────────────┐          ┌─────────┐
│  WireGuard   │ ──── UDP ──────► │  WireGuard   │ ──NAT──► │ Website │
│  Client      │     tunnel       │  Server      │          │         │
│              │                  │  + Unbound   │          │ Sees    │
│ All traffic  │                  │  + DuckDNS   │          │ Pi's IP │
│ goes through │                  │              │          │         │
│ the tunnel   │                  │ MASQUERADE   │          │         │
└──────────────┘                  └──────────────┘          └─────────┘
```

1. All traffic from your device enters the encrypted WireGuard tunnel
2. The Pi decrypts it and forwards it to the internet via NAT (MASQUERADE)
3. Destination websites see the Pi's public IP — no proxy headers, no VPN fingerprint
4. DNS queries resolve via Unbound inside the container — no DNS leaks

## Anti-Detection

This setup is designed so websites cannot distinguish your traffic from someone browsing directly on the Pi's network:

- **No proxy headers** — WireGuard is a Layer 3 VPN, no application-level modification
- **No DNS leaks** — all DNS resolves on the Pi via Unbound
- **No WebRTC leaks** — full tunnel routes all protocols
- **Standard MTU** (1420) — avoids packet size fingerprinting
- **No IPv6 leaks** — client IPv6 traffic is routed into the tunnel (`::/0`) and deliberately dropped at the server by default, so it can never bypass the VPN; IPv6 DNS (`fd00::1`) still works. Working IPv6 egress is available as an opt-in — see [Enabling real IPv6 egress](#enabling-real-ipv6-egress-optional)
- **LAN isolation** — VPN clients can only reach the internet: forwarded traffic from the tunnel to private ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`) is dropped, so a lost or stolen peer config cannot be used to reach devices on your home network, and peers cannot see each other. DNS (served from inside the container) still works.

### Client-side tips

- **Timezone:** Set your device's timezone to match the Pi's location when browsing sensitive sites. Websites can detect timezone via JavaScript, and a mismatch (e.g., timezone says Tokyo but IP says Warsaw) can flag VPN usage.
- **Browser fingerprinting:** Canvas, font, and screen resolution fingerprinting is unrelated to the proxy. Use browser privacy settings if this concerns you.

### Client isolation on existing installs

`wg0.conf` is generated once, so installs created before LAN isolation keep the old
firewall block (the container logs a `[wg-init] WARNING` about it). To migrate without
re-onboarding devices: stop the container, edit `./config/wg/wg0.conf` (as root), replace
the `PostUp`/`PostDown` lines with the block a fresh install generates (see
`rootfs/usr/local/bin/wg-init` — substitute your uplink interface, normally `eth0`, for
`${DEFAULT_IFACE}`), and start the container again. Alternatively, delete `./config/wg`
and `./config/peers` and re-add every peer.

## Enabling real IPv6 egress (optional)

By default the container has no IPv6 connectivity: Docker does not give containers an
IPv6 address unless the network is explicitly IPv6-enabled. Client IPv6 traffic still
enters the tunnel (clients route `::/0` through it) but is dropped at the server — a
deliberate anti-leak sinkhole. Dual-stack apps fall back to IPv4 automatically.

To give clients working IPv6 through the tunnel, all of the following are required:

1. **IPv6 from your ISP.** The Pi must have a global IPv6 address:

   ```bash
   ip -6 addr show scope global
   # Must show an address NOT starting with fd or fe80
   ```

   If this shows nothing, stop here — leave IPv6 off. The default sinkhole is safer
   than half-working IPv6.

2. **Make Unbound resolve IPv6 DNS addresses.** Modify `rootfs/etc/unbound/unbound.conf.template` from:

   ```yaml
   do-ip6: no
   ```
   
   to:

   ```yaml
   do-ip6: yes
   ```

3. **An IPv6-enabled Docker network.** Add to the bottom of `docker-compose.yml`:

   ```yaml
   networks:
     default:
       enable_ipv6: true
   ```

   Then recreate the container: `docker compose down && docker compose up -d`.

   On Docker Engine 27 or newer (what `get.docker.com` installs) nothing else is
   needed: Docker auto-allocates a private (ULA) subnet, and its default ip6tables
   integration NATs the container's IPv6 traffic to the Pi's global address.

4. **Verify:**

   ```bash
   docker exec wireguard ping -6 -c 1 2606:4700:4700::1111
   ```

   Then from a connected client, visit https://test-ipv6.com — the IPv6 address shown
   must belong to your home ISP (same network as your IPv4).

Traffic path: client `fd00::x` → tunnel → container NAT → container's Docker ULA
address → Docker NAT → Pi's global IPv6 address. Do not enable this on a Pi without
ISP IPv6: the container would gain a dead IPv6 route and internal services would waste
time attempting IPv6 before falling back to IPv4.

## Backup and Restore

All state lives in the `./config` directory:

```bash
# Backup
tar czf proxy-backup.tar.gz config/

# Restore on a new Pi
tar xzf proxy-backup.tar.gz
docker compose up -d
```

## Troubleshooting

### Container logs

```bash
docker compose logs -f
```

### Check WireGuard status

```bash
docker exec wireguard wg show
```

### Client can't connect

1. Verify UDP port 51820 is forwarded on your router
2. Check that DuckDNS is resolving to the correct IP: `nslookup yourname.duckdns.org`
3. Check container logs for errors: `docker compose logs wireguard`
4. Verify the peer was added: `docker exec wireguard list-peers`

### IP changed and clients disconnected

The server side heals itself: within ~60 seconds the DuckDNS updater points your hostname at the new IP. Connected clients do not — WireGuard apps resolve the endpoint hostname only when a tunnel starts, so an already-running tunnel keeps sending to the old IP. (`PersistentKeepalive` keeps NAT mappings alive; it does not re-resolve DNS. This is true of the official apps on iOS, macOS, Android, and Windows.)

**Fix on any device: toggle the tunnel off and back on** in the WireGuard app — it re-resolves the DuckDNS name on activation and reconnects within seconds. A device reboot also works. Nothing needs to be done on the Pi. If you toggle within a minute or two of the IP change, DNS may still be stale — wait a minute and toggle again.

Linux laptops using `wg-quick` can automate recovery with the official [`reresolve-dns.sh`](https://git.zx2c4.com/wireguard-tools/tree/contrib/reresolve-dns) script on a cron/systemd timer.

### wg0 fails to start with "Unknown device type"

The host kernel normally autoloads the WireGuard module when the container
creates the interface. If it doesn't (typically right after a kernel upgrade,
before a reboot), reboot the Pi, or make the module load at every boot:

```bash
echo wireguard | sudo tee /etc/modules-load.d/wireguard.conf
sudo modprobe wireguard
```

While the module is unavailable the container exits and Docker restarts it in a loop (visible in `docker ps` as a recent "Restarting"/short uptime), so it recovers by itself once the module loads.

### DNS not working through the tunnel

Check that Unbound is running: `docker exec wireguard pgrep unbound`

If not, check logs: `docker compose logs wireguard | grep unbound`
