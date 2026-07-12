# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A single Docker container that runs a WireGuard VPN server (personal proxy) on a Raspberry Pi: WireGuard + Unbound (validating DNS resolver) + DuckDNS updater, supervised by s6-overlay. Everything is shell scripts and config files — there is no application code, package manager, or test suite. Design and implementation plans live in `docs/plans/`.

## Commands

```bash
docker compose build              # verify the image builds (the closest thing to CI)
docker compose up -d              # run (target platform is a Raspberry Pi; needs NET_ADMIN + host wireguard kernel module)
docker compose logs -f            # inspect startup; init problems log as "[wg-init] WARNING/ERROR"

# Peer management (inside the running container)
docker exec wireguard add-peer <name>
docker exec wireguard remove-peer <name>
docker exec wireguard list-peers
docker exec wireguard wg show     # live tunnel status
```

There are no automated tests. Verification is manual: build the image, run it, and exercise the affected path (README "Troubleshooting" has the checks).

## Architecture

### rootfs overlay

`rootfs/` is copied verbatim onto the image root (`COPY rootfs/ /`). Scripts go in `rootfs/usr/local/bin/`, s6 services in `rootfs/etc/s6-overlay/s6-rc.d/`. **Any new script or s6 `run`/`finish`/`up` file must be added to the `chmod +x` line in the Dockerfile** — the files are tracked in git without the execute bit (mode 100644), so the Dockerfile chmod is what makes them runnable.

### s6 service graph

```
init-wireguard (oneshot: wg-init — generates/repairs wg0.conf)
  └─> svc-wireguard (longrun: wg-quick up, signals readiness on fd 3, then watches the interface)
        └─> svc-unbound (longrun: renders unbound.conf from wg0.conf, runs Unbound)
svc-duckdns (longrun, independent: updates DuckDNS every 60s)
```

`S6_BEHAVIOUR_IF_STAGE2_FAILS=2` in the Dockerfile means a failed service start kills the whole container so Docker's `restart: unless-stopped` retries it — init scripts should `exit 1` on unrecoverable errors rather than limp along. The HEALTHCHECK is visibility-only; Docker does not restart unhealthy containers.

`svc-wireguard` has a 60s `timeout-up`, so a persistently failing `wg-quick up` (e.g. missing kernel module) fails stage2 and kills the container instead of hanging it in a supervised crash-loop forever.

### Config lifecycle: wg0.conf is the source of truth

Environment variables from `.env` shape the **first run only**. Once `/config/wg/wg0.conf` exists (persisted in the `./config` volume), it is the single source of truth: `add-peer` and `svc-unbound` derive the subnet, server IP, and port by parsing `wg0.conf`, not from env vars. Two deliberate exceptions in `wg-init`:

- `SERVER_PORT` changes are synced into `wg0.conf` on restart (with warnings — existing peer configs keep the old port).
- `INTERNAL_SUBNET` changes are ignored with a warning; changing it requires wiping `./config/wg` and `./config/peers`.

Keep this pattern when adding config: parse the persisted state, don't re-read env vars that only apply at first run.

### Peer data contract

Each peer is stored in two places that must stay in sync:

- A `[Peer]` block in `wg0.conf` preceded by a `# Peer: <name>` comment — `remove-peer`'s awk script depends on this exact comment format to delete the block.
- A `/config/peers/<name>/` directory holding `private.key`, `public.key`, `preshared.key`, and `<name>.conf` (the client config).

Both `add-peer` and `remove-peer` also live-update the running interface via `wg set wg0` when it's up, so changes take effect without a restart. Peer IPs are allocated by scanning `AllowedIPs` in `wg0.conf` for the lowest free host number starting at `.2` (IPv6 mirrors it as `fd00::<n>`).

### IPv6 is a deliberate sinkhole

Clients route `::/0` into the tunnel, but the container has no IPv6 egress by default, so client IPv6 traffic is intentionally dropped at the server — this prevents IPv6 leaks. The `fd00::/64` ULA prefix is hardcoded (not derived from `INTERNAL_SUBNET`), and all `ip6tables` rules in generated configs carry `|| true` so missing IPv6 support never breaks startup. Real IPv6 egress is an opt-in documented in the README. Don't "fix" the sinkhole.

## Design Constraints

- **Anti-detection is a core requirement**: traffic must be indistinguishable from direct browsing on the Pi's network. No proxy headers, DNS resolves only via Unbound inside the container, MTU stays at 1420, full-tunnel (`AllowedIPs = 0.0.0.0/0, ::/0`).
- **Client isolation**: generated configs DROP forwarded traffic from wg0 to RFC1918/ULA destinations before the ACCEPT rule — VPN clients are internet-only. All PostUp rules use `-C ... || -A ...` so interface flaps don't duplicate them. Preserve both properties when touching the firewall block.
- **Minimal attack surface**: only UDP 51820 exposed; no web UI or management ports. Management happens via `docker exec` only.
- **Key hygiene**: scripts set `umask 077`; key files and `wg0.conf` are chmod 600, key directories 700. Preserve this in any script that touches `/config`.
- **Supply-chain pinning**: s6-overlay downloads use `ADD --checksum` with per-arch build stages selected by `TARGETARCH`. When bumping `S6_OVERLAY_VERSION`, update all three sha256 checksums from the release's `.sha256` files.
- `./config/` and `.env` are runtime state, gitignored — never commit them.
