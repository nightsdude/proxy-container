# WireGuard Personal Proxy

A Docker container that runs a WireGuard VPN server on a Raspberry Pi, acting as a personal proxy. All traffic from connected devices exits from the Pi's public IP — indistinguishable from someone browsing directly on the Pi's network.

## Features

- **Full tunnel VPN** — all traffic (TCP, UDP, DNS, WebRTC) routed through the Pi
- **Built-in DNS resolver** (Unbound) — prevents DNS leaks, no geolocation mismatch
- **Dynamic DNS** (DuckDNS) — auto-updates every 60 seconds when your IP changes
- **Whitelist-only access** — devices must be explicitly added via CLI
- **QR code onboarding** — scan from the WireGuard mobile app to connect instantly
- **Minimal attack surface** — only UDP port 51820 exposed, no web UI

## Prerequisites

- Raspberry Pi 4 (2GB+ RAM recommended) running a 64-bit OS
- Docker and Docker Compose installed
- A [DuckDNS](https://www.duckdns.org/) account (free)
- UDP port 51820 forwarded on your router to the Pi's LAN IP

### Install Docker on the Pi

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Log out and back in for group changes to take effect
```

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
| `SERVER_PORT` | WireGuard listen port (default: `51820`) |
| `INTERNAL_SUBNET` | VPN subnet (default: `10.13.13.0/24`) |
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

For laptops/desktops, copy the generated config file:

```bash
# The config is saved at:
# ./config/peers/my-phone/my-phone.conf
```

Import it into the WireGuard desktop client.

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

## How It Works

```
Your Phone (abroad)           Raspberry Pi (home)          Internet
┌─────────────┐     encrypted     ┌──────────────┐          ┌─────────┐
│  WireGuard   │ ──── UDP ──────► │  WireGuard   │ ──NAT──► │ Website │
│  Client      │    tunnel        │  Server      │          │         │
│             │                  │  + Unbound   │          │ Sees    │
│ All traffic  │                  │  + DuckDNS   │          │ Pi's IP │
│ goes through │                  │              │          │         │
│ the tunnel   │                  │ MASQUERADE   │          │         │
└─────────────┘                  └──────────────┘          └─────────┘
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
- **IPv6 leak prevention** — blocked if not available on the Pi's network

### Client-side tips

- **Timezone:** Set your device's timezone to match the Pi's location when browsing sensitive sites. Websites can detect timezone via JavaScript, and a mismatch (e.g., timezone says Tokyo but IP says Warsaw) can flag VPN usage.
- **Browser fingerprinting:** Canvas, font, and screen resolution fingerprinting is unrelated to the proxy. Use browser privacy settings if this concerns you.

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

Clients reconnect automatically within ~1.5 minutes. The DuckDNS updater runs every 60 seconds, and WireGuard clients re-resolve the endpoint DNS periodically via `PersistentKeepalive`.

### DNS not working through the tunnel

Check that Unbound is running: `docker exec wireguard pgrep unbound`

If not, check logs: `docker compose logs wireguard | grep unbound`
