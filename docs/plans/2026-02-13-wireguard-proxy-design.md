# WireGuard Personal Proxy — Design Document

## Purpose

A Docker container running WireGuard VPN on a Raspberry Pi 4, acting as a personal proxy for browsing and streaming from abroad. All traffic from client devices exits from the Pi's public IP with no detectable proxy fingerprint.

## Requirements

- 3-5 simultaneous client devices
- Web browsing and video streaming (including QUIC/HTTP3 over UDP)
- Destination websites must not be able to detect proxied traffic
- Whitelist-only peer management via SSH + docker exec
- Dynamic public IP with DDNS
- Minimal attack surface — no web UI, no exposed management ports

## Architecture

### Single Container Design

One Docker image based on `alpine:latest` containing:

1. **WireGuard** (`wg-quick`) — VPN server
2. **Unbound** — recursive DNS resolver on the WireGuard interface
3. **DuckDNS updater** — cron job every 1 minute
4. **s6-overlay** — process supervisor for managing all services

### Docker Compose

```yaml
services:
  wireguard:
    build: .
    container_name: wireguard
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "51820:51820/udp"
    volumes:
      - ./config:/config
    environment:
      - SERVER_URL=yourname.duckdns.org
      - SERVER_PORT=51820
      - INTERNAL_SUBNET=10.13.13.0/24
      - DUCKDNS_TOKEN=your-token-here
      - DUCKDNS_SUBDOMAIN=yourname
      - TZ=Europe/Warsaw
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
```

### Exposed Ports

- `51820/udp` — WireGuard only. Nothing else exposed.

### Volumes

- `./config` — persists WireGuard keys, peer configs, unbound config. Back up this directory to recreate the setup on any Pi.

### Required Capabilities

- `NET_ADMIN` — manage network interfaces and iptables
- `SYS_MODULE` — load WireGuard kernel module
- `/dev/net/tun` — tunnel device access

## Peer Management (Whitelist System)

WireGuard is cryptographically whitelisted by design — only peers with a valid keypair in the server config can connect.

### CLI Scripts (in container at `/usr/local/bin/`)

| Command | Description |
|---------|-------------|
| `add-peer <name>` | Generate keypair, add to WireGuard config, create client config, output QR code |
| `remove-peer <name>` | Remove peer from config, delete client files |
| `list-peers` | Show all peers with names, public keys, last handshake |

### Usage

```bash
docker exec wireguard add-peer my-phone      # generates QR code
docker exec wireguard remove-peer my-phone
docker exec wireguard list-peers
```

### Client Config Auto-Generation

Each `add-peer` generates a complete client `.conf` with:
- Client keypair
- Server public key
- Endpoint: `<DUCKDNS_SUBDOMAIN>.duckdns.org:<SERVER_PORT>`
- `AllowedIPs = 0.0.0.0/0, ::/0` (full tunnel)
- `DNS = 10.13.13.1` (Unbound)
- `PersistentKeepalive = 25`

### IP Allocation

Sequential IPs in `10.13.13.0/24` starting at `.2`. Supports up to 253 peers.

Configs saved to `/config/peers/<name>/<name>.conf`.

## Network & Anti-Detection

### WireGuard Network

- Server: `wg0` interface, `10.13.13.1/24`
- Clients: `10.13.13.2` through `10.13.13.254`
- Full tunnel: all IPv4 + IPv6 traffic routed through the tunnel

### NAT

iptables MASQUERADE on the container's `eth0`. All outbound traffic is source-NATed to the Pi's public IP. Destination websites see only the Pi's IP.

### Anti-Detection Measures

1. **Full tunnel** — all traffic (HTTP, DNS, WebRTC, ICMP) goes through the tunnel. No split tunneling.
2. **DNS via Unbound** — resolves on the Pi, so DNS geolocation matches IP geolocation.
3. **No proxy headers** — Layer 3 VPN, no application-level headers.
4. **MTU 1420** — standard WireGuard MTU, avoids unusual packet size fingerprinting.
5. **IPv6 leak prevention** — block IPv6 if not available on Pi's network, tunnel it if available.

### Not Addressed (Client-Side Responsibility)

- **Timezone mismatch** — set client device timezone to match Pi's location when needed.
- **Browser fingerprinting** (canvas, fonts, etc.) — unrelated to proxy layer.

## Dynamic DNS

### DuckDNS

- Free DDNS service
- Cron job inside the container updates DuckDNS every 1 minute
- Clients connect to `<subdomain>.duckdns.org:51820`
- DuckDNS TTL is 60 seconds

### IP Change Behavior

1. Pi gets new IP from ISP
2. Within 1 minute, DDNS cron updates DuckDNS
3. WireGuard clients re-resolve DNS via `PersistentKeepalive = 25`
4. Clients reconnect automatically — no user action needed
5. Worst-case downtime: ~1.5 minutes

## Deployment

1. Install Docker on Pi: `curl -fsSL https://get.docker.com | sh`
2. Clone repo, create `.env` with DuckDNS token and subdomain
3. `docker compose up -d`
4. Forward UDP port 51820 on router to Pi's LAN IP
5. `docker exec wireguard add-peer <device-name>` — scan QR code

## Hardware Recommendation

Raspberry Pi 4 (2GB or 4GB):
- Gigabit Ethernet for streaming throughput
- Hardware crypto support for WireGuard
- Sufficient CPU/RAM for WireGuard + Unbound + 3-5 clients
