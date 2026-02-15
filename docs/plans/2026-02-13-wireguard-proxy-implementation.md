# WireGuard Personal Proxy — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a single Docker container running WireGuard VPN + Unbound DNS + DuckDNS on a Raspberry Pi 4 for personal proxy use.

**Architecture:** Alpine-based container with s6-overlay managing WireGuard, Unbound, and a DuckDNS cron updater. Peer management via CLI scripts executed through `docker exec`. Full tunnel with NAT masquerading.

**Tech Stack:** Alpine Linux, s6-overlay v3, WireGuard (wg-quick), Unbound, DuckDNS API, iptables, bash, qrencode

---

### Task 1: Project Scaffolding

**Files:**
- Create: `.gitignore`
- Create: `.env.example`
- Create: `Dockerfile` (empty placeholder)
- Create: `docker-compose.yml` (empty placeholder)

**Step 1: Create .gitignore**

```
config/
.env
*.swp
*.swo
```

**Step 2: Create .env.example**

```
SERVER_URL=yourname.duckdns.org
SERVER_PORT=51820
INTERNAL_SUBNET=10.13.13.0/24
DUCKDNS_TOKEN=your-duckdns-token-here
DUCKDNS_SUBDOMAIN=yourname
TZ=Europe/Warsaw
```

**Step 3: Create empty Dockerfile and docker-compose.yml placeholders**

`Dockerfile`:
```dockerfile
# WireGuard Personal Proxy
# Built in subsequent tasks
```

`docker-compose.yml`:
```yaml
# WireGuard Personal Proxy
# Built in subsequent tasks
```

**Step 4: Commit**

```bash
git add .gitignore .env.example Dockerfile docker-compose.yml
git commit -m "chore: scaffold project structure"
```

---

### Task 2: Dockerfile Base with s6-overlay

**Files:**
- Modify: `Dockerfile`

**Step 1: Write the Dockerfile with Alpine base and s6-overlay**

```dockerfile
FROM alpine:3.21

ARG S6_OVERLAY_VERSION=3.2.0.2
ARG TARGETARCH

# Install s6-overlay
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && rm /tmp/s6-overlay-noarch.tar.xz

ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${TARGETARCH}.tar.xz /tmp
RUN tar -C / -Jxpf /tmp/s6-overlay-${TARGETARCH}.tar.xz && rm /tmp/s6-overlay-${TARGETARCH}.tar.xz

# Install packages
RUN apk add --no-cache \
    wireguard-tools \
    iptables \
    ip6tables \
    unbound \
    bash \
    curl \
    qrencode \
    tzdata

# Config volume
VOLUME /config

# WireGuard port
EXPOSE 51820/udp

ENTRYPOINT ["/init"]
```

**Step 2: Verify it builds**

Run: `docker build --platform linux/arm64 -t wireguard-proxy:test .`
Expected: Build completes successfully.

**Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Dockerfile with Alpine base and s6-overlay"
```

---

### Task 3: WireGuard Init Script

This script runs once on first start to generate server keys and the base WireGuard config. On subsequent starts, it reuses existing keys from the config volume.

**Files:**
- Create: `rootfs/etc/s6-overlay/s6-rc.d/init-wireguard/type`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/init-wireguard/up`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/init-wireguard/dependencies.d/base`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/init-wireguard`
- Create: `rootfs/usr/local/bin/wg-init`
- Modify: `Dockerfile`

**Step 1: Create the s6 oneshot service definition**

`rootfs/etc/s6-overlay/s6-rc.d/init-wireguard/type`:
```
oneshot
```

`rootfs/etc/s6-overlay/s6-rc.d/init-wireguard/up`:
```
/usr/local/bin/wg-init
```

`rootfs/etc/s6-overlay/s6-rc.d/init-wireguard/dependencies.d/base` (empty file — depends on s6 base bundle).

`rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/init-wireguard` (empty file — registers with user bundle).

**Step 2: Write the init script**

`rootfs/usr/local/bin/wg-init`:
```bash
#!/bin/bash
set -euo pipefail

CONFIG_DIR="/config"
WG_DIR="${CONFIG_DIR}/wg"
WG_CONF="${WG_DIR}/wg0.conf"

SERVER_PORT="${SERVER_PORT:-51820}"
INTERNAL_SUBNET="${INTERNAL_SUBNET:-10.13.13.0/24}"

# Derive server IP from subnet (first usable: x.x.x.1)
SERVER_IP="${INTERNAL_SUBNET%.*}.1"
SUBNET_MASK="${INTERNAL_SUBNET#*/}"

mkdir -p "${WG_DIR}"
mkdir -p "${CONFIG_DIR}/peers"

if [ ! -f "${WG_CONF}" ]; then
    echo "[wg-init] First run — generating server keys and config"

    # Generate server keypair
    SERVER_PRIVATE_KEY=$(wg genkey)
    SERVER_PUBLIC_KEY=$(echo "${SERVER_PRIVATE_KEY}" | wg pubkey)

    echo "${SERVER_PRIVATE_KEY}" > "${WG_DIR}/server_private.key"
    echo "${SERVER_PUBLIC_KEY}" > "${WG_DIR}/server_public.key"
    chmod 600 "${WG_DIR}/server_private.key"

    # Detect default outbound interface
    DEFAULT_IFACE=$(ip -o -4 route show default | awk '{print $5}' | head -1)

    # Write server config
    cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${SERVER_IP}/${SUBNET_MASK}
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}
MTU = 1420
PostUp = iptables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF

    echo "[wg-init] Server config created at ${WG_CONF}"
    echo "[wg-init] Server public key: ${SERVER_PUBLIC_KEY}"
else
    echo "[wg-init] Existing config found at ${WG_CONF}"
fi

# Track next available IP for peer allocation
if [ ! -f "${CONFIG_DIR}/next_ip" ]; then
    echo "2" > "${CONFIG_DIR}/next_ip"
fi

echo "[wg-init] WireGuard initialization complete"
```

**Step 3: Add COPY to Dockerfile**

Add before the ENTRYPOINT line in the Dockerfile:

```dockerfile
# Copy rootfs overlay
COPY rootfs/ /

# Make scripts executable
RUN chmod +x /usr/local/bin/wg-init
```

**Step 4: Verify build**

Run: `docker build --platform linux/arm64 -t wireguard-proxy:test .`
Expected: Build completes successfully.

**Step 5: Commit**

```bash
git add rootfs/ Dockerfile
git commit -m "feat: add WireGuard init script with first-run key generation"
```

---

### Task 4: WireGuard s6 Long-Running Service

**Files:**
- Create: `rootfs/etc/s6-overlay/s6-rc.d/svc-wireguard/type`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/svc-wireguard/run`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/svc-wireguard/finish`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/svc-wireguard/dependencies.d/init-wireguard`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/svc-wireguard`

**Step 1: Create the s6 longrun service**

`rootfs/etc/s6-overlay/s6-rc.d/svc-wireguard/type`:
```
longrun
```

`rootfs/etc/s6-overlay/s6-rc.d/svc-wireguard/run`:
```bash
#!/command/with-contenv bash
set -euo pipefail

echo "[wireguard] Starting WireGuard interface wg0"

# Bring up WireGuard
wg-quick up /config/wg/wg0.conf

# Keep the service running — s6 needs a foreground process
# Monitor the interface and exit if it goes down
while ip link show wg0 > /dev/null 2>&1; do
    sleep 5
done

echo "[wireguard] Interface wg0 is down, exiting"
```

`rootfs/etc/s6-overlay/s6-rc.d/svc-wireguard/finish`:
```bash
#!/command/with-contenv bash
echo "[wireguard] Stopping WireGuard interface wg0"
wg-quick down /config/wg/wg0.conf 2>/dev/null || true
```

`rootfs/etc/s6-overlay/s6-rc.d/svc-wireguard/dependencies.d/init-wireguard` (empty file).

`rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/svc-wireguard` (empty file).

**Step 2: Make run and finish scripts executable in Dockerfile**

Update the `chmod` line in Dockerfile to:

```dockerfile
RUN chmod +x /usr/local/bin/wg-init && \
    find /etc/s6-overlay/s6-rc.d -name "run" -o -name "finish" -o -name "up" | xargs chmod +x
```

**Step 3: Verify build**

Run: `docker build --platform linux/arm64 -t wireguard-proxy:test .`
Expected: Build completes successfully.

**Step 4: Commit**

```bash
git add rootfs/ Dockerfile
git commit -m "feat: add WireGuard s6 longrun service"
```

---

### Task 5: Unbound DNS Resolver

**Files:**
- Create: `rootfs/etc/s6-overlay/s6-rc.d/svc-unbound/type`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/svc-unbound/run`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/svc-unbound/dependencies.d/svc-wireguard`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/svc-unbound`
- Create: `rootfs/etc/unbound/unbound.conf`

**Step 1: Create Unbound configuration**

`rootfs/etc/unbound/unbound.conf`:
```yaml
server:
    verbosity: 1
    interface: 10.13.13.1
    port: 53
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes

    # Access control — only WireGuard clients
    access-control: 10.13.13.0/24 allow
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse

    # Privacy
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes

    # Performance
    num-threads: 2
    msg-cache-size: 8m
    rrset-cache-size: 16m
    cache-min-ttl: 300
    cache-max-ttl: 86400
    prefetch: yes

    # Logging
    log-queries: no
    log-replies: no
```

**Step 2: Create the s6 longrun service**

`rootfs/etc/s6-overlay/s6-rc.d/svc-unbound/type`:
```
longrun
```

`rootfs/etc/s6-overlay/s6-rc.d/svc-unbound/run`:
```bash
#!/command/with-contenv bash
set -euo pipefail

echo "[unbound] Starting Unbound DNS resolver on 10.13.13.1:53"

# Run in foreground (-d)
exec unbound -d -c /etc/unbound/unbound.conf
```

`rootfs/etc/s6-overlay/s6-rc.d/svc-unbound/dependencies.d/svc-wireguard` (empty file — starts after WireGuard so the interface exists).

`rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/svc-unbound` (empty file).

**Step 3: Verify build**

Run: `docker build --platform linux/arm64 -t wireguard-proxy:test .`
Expected: Build completes successfully.

**Step 4: Commit**

```bash
git add rootfs/
git commit -m "feat: add Unbound DNS resolver with WireGuard-only access"
```

---

### Task 6: DuckDNS Updater

**Files:**
- Create: `rootfs/usr/local/bin/duckdns-update`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/svc-duckdns/type`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/svc-duckdns/run`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/svc-duckdns/dependencies.d/base`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/svc-duckdns`

**Step 1: Create the DuckDNS update script**

`rootfs/usr/local/bin/duckdns-update`:
```bash
#!/bin/bash
set -euo pipefail

DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-}"
DUCKDNS_SUBDOMAIN="${DUCKDNS_SUBDOMAIN:-}"

if [ -z "${DUCKDNS_TOKEN}" ] || [ -z "${DUCKDNS_SUBDOMAIN}" ]; then
    echo "[duckdns] DUCKDNS_TOKEN or DUCKDNS_SUBDOMAIN not set, skipping update"
    exit 0
fi

RESPONSE=$(curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=")

if [ "${RESPONSE}" = "OK" ]; then
    echo "[duckdns] Update successful"
else
    echo "[duckdns] Update failed: ${RESPONSE}"
fi
```

**Step 2: Create the s6 longrun service (runs as a loop with 60s sleep)**

`rootfs/etc/s6-overlay/s6-rc.d/svc-duckdns/type`:
```
longrun
```

`rootfs/etc/s6-overlay/s6-rc.d/svc-duckdns/run`:
```bash
#!/command/with-contenv bash
set -euo pipefail

echo "[duckdns] Starting DuckDNS updater (every 60 seconds)"

while true; do
    /usr/local/bin/duckdns-update
    sleep 60
done
```

`rootfs/etc/s6-overlay/s6-rc.d/svc-duckdns/dependencies.d/base` (empty file).

`rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/svc-duckdns` (empty file).

**Step 3: Add chmod for new script in Dockerfile**

Update the chmod line to also include `duckdns-update`:

```dockerfile
RUN chmod +x /usr/local/bin/wg-init /usr/local/bin/duckdns-update && \
    find /etc/s6-overlay/s6-rc.d -name "run" -o -name "finish" -o -name "up" | xargs chmod +x
```

**Step 4: Verify build**

Run: `docker build --platform linux/arm64 -t wireguard-proxy:test .`
Expected: Build completes successfully.

**Step 5: Commit**

```bash
git add rootfs/ Dockerfile
git commit -m "feat: add DuckDNS updater with 60-second refresh"
```

---

### Task 7: add-peer Script

**Files:**
- Create: `rootfs/usr/local/bin/add-peer`
- Modify: `Dockerfile` (add to chmod)

**Step 1: Write the add-peer script**

`rootfs/usr/local/bin/add-peer`:
```bash
#!/bin/bash
set -euo pipefail

PEER_NAME="${1:-}"

if [ -z "${PEER_NAME}" ]; then
    echo "Usage: add-peer <name>"
    echo "  name: alphanumeric identifier for the peer (e.g., my-phone)"
    exit 1
fi

# Validate name
if ! [[ "${PEER_NAME}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: peer name must be alphanumeric (with hyphens/underscores)"
    exit 1
fi

CONFIG_DIR="/config"
WG_CONF="${CONFIG_DIR}/wg/wg0.conf"
PEER_DIR="${CONFIG_DIR}/peers/${PEER_NAME}"
SERVER_URL="${SERVER_URL:-}"
SERVER_PORT="${SERVER_PORT:-51820}"
INTERNAL_SUBNET="${INTERNAL_SUBNET:-10.13.13.0/24}"
SUBNET_BASE="${INTERNAL_SUBNET%.*}"

# Check if peer already exists
if [ -d "${PEER_DIR}" ]; then
    echo "Error: peer '${PEER_NAME}' already exists"
    echo "  Config: ${PEER_DIR}/${PEER_NAME}.conf"
    exit 1
fi

# Get next available IP
NEXT_IP_NUM=$(cat "${CONFIG_DIR}/next_ip")
if [ "${NEXT_IP_NUM}" -gt 254 ]; then
    echo "Error: no more IPs available in subnet"
    exit 1
fi
PEER_IP="${SUBNET_BASE}.${NEXT_IP_NUM}"

# Generate peer keypair
PEER_PRIVATE_KEY=$(wg genkey)
PEER_PUBLIC_KEY=$(echo "${PEER_PRIVATE_KEY}" | wg pubkey)
PEER_PRESHARED_KEY=$(wg genpsk)

# Read server public key
SERVER_PUBLIC_KEY=$(cat "${CONFIG_DIR}/wg/server_public.key")

# Create peer directory
mkdir -p "${PEER_DIR}"

# Save peer keys
echo "${PEER_PRIVATE_KEY}" > "${PEER_DIR}/private.key"
echo "${PEER_PUBLIC_KEY}" > "${PEER_DIR}/public.key"
echo "${PEER_PRESHARED_KEY}" > "${PEER_DIR}/preshared.key"
chmod 600 "${PEER_DIR}/private.key" "${PEER_DIR}/preshared.key"

# Generate client config
cat > "${PEER_DIR}/${PEER_NAME}.conf" <<EOF
[Interface]
PrivateKey = ${PEER_PRIVATE_KEY}
Address = ${PEER_IP}/32
DNS = ${SUBNET_BASE}.1
MTU = 1420

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${PEER_PRESHARED_KEY}
Endpoint = ${SERVER_URL}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

# Add peer to server config
cat >> "${WG_CONF}" <<EOF

# Peer: ${PEER_NAME}
[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
PresharedKey = ${PEER_PRESHARED_KEY}
AllowedIPs = ${PEER_IP}/32
EOF

# Increment next IP
echo $(( NEXT_IP_NUM + 1 )) > "${CONFIG_DIR}/next_ip"

# Live-add peer if WireGuard is running
if ip link show wg0 > /dev/null 2>&1; then
    wg set wg0 peer "${PEER_PUBLIC_KEY}" \
        preshared-key <(echo "${PEER_PRESHARED_KEY}") \
        allowed-ips "${PEER_IP}/32"
    echo "[add-peer] Peer added to running WireGuard interface"
fi

echo ""
echo "========================================="
echo "  Peer '${PEER_NAME}' created"
echo "========================================="
echo "  IP:     ${PEER_IP}"
echo "  Config: ${PEER_DIR}/${PEER_NAME}.conf"
echo "========================================="
echo ""

# Show QR code for mobile scanning
echo "Scan this QR code with the WireGuard mobile app:"
echo ""
qrencode -t ansiutf8 < "${PEER_DIR}/${PEER_NAME}.conf"
```

**Step 2: Update Dockerfile chmod line**

```dockerfile
RUN chmod +x /usr/local/bin/wg-init /usr/local/bin/duckdns-update /usr/local/bin/add-peer && \
    find /etc/s6-overlay/s6-rc.d -name "run" -o -name "finish" -o -name "up" | xargs chmod +x
```

**Step 3: Verify build**

Run: `docker build --platform linux/arm64 -t wireguard-proxy:test .`
Expected: Build completes successfully.

**Step 4: Commit**

```bash
git add rootfs/ Dockerfile
git commit -m "feat: add add-peer script with QR code generation"
```

---

### Task 8: remove-peer Script

**Files:**
- Create: `rootfs/usr/local/bin/remove-peer`
- Modify: `Dockerfile` (add to chmod)

**Step 1: Write the remove-peer script**

`rootfs/usr/local/bin/remove-peer`:
```bash
#!/bin/bash
set -euo pipefail

PEER_NAME="${1:-}"

if [ -z "${PEER_NAME}" ]; then
    echo "Usage: remove-peer <name>"
    exit 1
fi

CONFIG_DIR="/config"
WG_CONF="${CONFIG_DIR}/wg/wg0.conf"
PEER_DIR="${CONFIG_DIR}/peers/${PEER_NAME}"

# Check if peer exists
if [ ! -d "${PEER_DIR}" ]; then
    echo "Error: peer '${PEER_NAME}' not found"
    exit 1
fi

# Read peer public key
PEER_PUBLIC_KEY=$(cat "${PEER_DIR}/public.key")

# Remove peer from running WireGuard if active
if ip link show wg0 > /dev/null 2>&1; then
    wg set wg0 peer "${PEER_PUBLIC_KEY}" remove
    echo "[remove-peer] Peer removed from running WireGuard interface"
fi

# Remove peer section from server config
# Uses awk to remove the "# Peer: name" comment, the [Peer] block, and all
# lines until the next section or EOF
awk -v name="${PEER_NAME}" '
    /^# Peer: / && $3 == name { skip=1; next }
    /^\[Peer\]/ && skip { next }
    /^$/ && skip { next }
    /^(\[|# Peer:)/ && skip { skip=0 }
    !skip { print }
' "${WG_CONF}" > "${WG_CONF}.tmp"
mv "${WG_CONF}.tmp" "${WG_CONF}"

# Remove peer directory
rm -rf "${PEER_DIR}"

echo ""
echo "Peer '${PEER_NAME}' removed successfully."
```

**Step 2: Update Dockerfile chmod line**

```dockerfile
RUN chmod +x /usr/local/bin/wg-init /usr/local/bin/duckdns-update \
              /usr/local/bin/add-peer /usr/local/bin/remove-peer && \
    find /etc/s6-overlay/s6-rc.d -name "run" -o -name "finish" -o -name "up" | xargs chmod +x
```

**Step 3: Verify build**

Run: `docker build --platform linux/arm64 -t wireguard-proxy:test .`
Expected: Build completes successfully.

**Step 4: Commit**

```bash
git add rootfs/ Dockerfile
git commit -m "feat: add remove-peer script"
```

---

### Task 9: list-peers Script

**Files:**
- Create: `rootfs/usr/local/bin/list-peers`
- Modify: `Dockerfile` (add to chmod)

**Step 1: Write the list-peers script**

`rootfs/usr/local/bin/list-peers`:
```bash
#!/bin/bash
set -euo pipefail

CONFIG_DIR="/config"
PEER_DIR="${CONFIG_DIR}/peers"

if [ ! -d "${PEER_DIR}" ] || [ -z "$(ls -A "${PEER_DIR}" 2>/dev/null)" ]; then
    echo "No peers configured."
    exit 0
fi

# Get live handshake data if WireGuard is running
declare -A HANDSHAKES
if ip link show wg0 > /dev/null 2>&1; then
    while IFS=$'\t' read -r pubkey _ _ _ handshake _; do
        if [ "${handshake}" != "0" ]; then
            HANDSHAKES["${pubkey}"]=$(date -d "@${handshake}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "${handshake}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
        fi
    done < <(wg show wg0 dump | tail -n +2)
fi

printf "%-20s %-16s %-44s %s\n" "NAME" "IP" "PUBLIC KEY" "LAST HANDSHAKE"
printf "%-20s %-16s %-44s %s\n" "----" "--" "----------" "--------------"

for peer_dir in "${PEER_DIR}"/*/; do
    [ -d "${peer_dir}" ] || continue
    name=$(basename "${peer_dir}")
    pubkey=$(cat "${peer_dir}/public.key" 2>/dev/null || echo "unknown")

    # Extract IP from client config
    ip=$(grep -oP 'Address = \K[0-9.]+' "${peer_dir}/${name}.conf" 2>/dev/null || echo "unknown")

    handshake="${HANDSHAKES[${pubkey}]:-never}"

    printf "%-20s %-16s %-44s %s\n" "${name}" "${ip}" "${pubkey}" "${handshake}"
done
```

**Step 2: Update Dockerfile chmod line**

```dockerfile
RUN chmod +x /usr/local/bin/wg-init /usr/local/bin/duckdns-update \
              /usr/local/bin/add-peer /usr/local/bin/remove-peer \
              /usr/local/bin/list-peers && \
    find /etc/s6-overlay/s6-rc.d -name "run" -o -name "finish" -o -name "up" | xargs chmod +x
```

**Step 3: Verify build**

Run: `docker build --platform linux/arm64 -t wireguard-proxy:test .`
Expected: Build completes successfully.

**Step 4: Commit**

```bash
git add rootfs/ Dockerfile
git commit -m "feat: add list-peers script with live handshake data"
```

---

### Task 10: docker-compose.yml

**Files:**
- Modify: `docker-compose.yml`

**Step 1: Write the compose file**

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
      - "${SERVER_PORT:-51820}:${SERVER_PORT:-51820}/udp"
    volumes:
      - ./config:/config
    env_file:
      - .env
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
```

**Step 2: Verify compose config is valid**

Run: `docker compose config`
Expected: Outputs the resolved compose config without errors (may warn about missing .env which is expected).

**Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add docker-compose.yml with environment and capabilities"
```

---

### Task 11: Final Dockerfile Assembly and Build Verification

Review the complete Dockerfile, ensure all pieces are correctly integrated, and do a final build test.

**Files:**
- Modify: `Dockerfile` (final review and cleanup)

**Step 1: Verify the final Dockerfile is complete and correct**

The final Dockerfile should look like:

```dockerfile
FROM alpine:3.21

ARG S6_OVERLAY_VERSION=3.2.0.2
ARG TARGETARCH

# Install s6-overlay
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && rm /tmp/s6-overlay-noarch.tar.xz

ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${TARGETARCH}.tar.xz /tmp
RUN tar -C / -Jxpf /tmp/s6-overlay-${TARGETARCH}.tar.xz && rm /tmp/s6-overlay-${TARGETARCH}.tar.xz

# Install packages
RUN apk add --no-cache \
    wireguard-tools \
    iptables \
    ip6tables \
    unbound \
    bash \
    curl \
    qrencode \
    tzdata

# Copy rootfs overlay
COPY rootfs/ /

# Make scripts executable
RUN chmod +x /usr/local/bin/wg-init /usr/local/bin/duckdns-update \
              /usr/local/bin/add-peer /usr/local/bin/remove-peer \
              /usr/local/bin/list-peers && \
    find /etc/s6-overlay/s6-rc.d -name "run" -o -name "finish" -o -name "up" | xargs chmod +x

# Config volume
VOLUME /config

# WireGuard port
EXPOSE 51820/udp

ENTRYPOINT ["/init"]
```

**Step 2: Full build test**

Run: `docker build --platform linux/arm64 -t wireguard-proxy:test .`
Expected: Build completes successfully with all layers.

**Step 3: Verify image size**

Run: `docker images wireguard-proxy:test`
Expected: Image should be under 100MB.

**Step 4: Commit any final adjustments**

```bash
git add Dockerfile
git commit -m "chore: finalize Dockerfile assembly"
```

---

### Task 12: Setup and Usage Documentation

**Files:**
- Create: `README.md`

**Step 1: Write the README**

`README.md`:
````markdown
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
````

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add setup and usage documentation"
```

---

### Task 13: Integration Smoke Test

Build the image on the local machine (not the Pi) and verify services initialize correctly.

**Step 1: Create a test .env file**

```bash
cp .env.example .env
# Edit values (DUCKDNS can be dummy values for testing)
```

**Step 2: Build and start the container**

Run: `docker compose up --build -d`

Note: On a non-Pi machine without WireGuard kernel module, the WireGuard service may fail. This is expected. Verify that:
- The container starts
- s6-overlay initializes
- The init script runs and generates keys in `./config/wg/`
- Unbound attempts to start (may fail without the wg0 interface)
- DuckDNS updater runs (will skip if dummy token)

**Step 3: Verify config volume is populated**

Run: `ls -la ./config/wg/`
Expected: `wg0.conf`, `server_private.key`, `server_public.key` exist.

**Step 4: Test peer management (config generation only)**

Run: `docker exec wireguard add-peer test-device`
Expected: Generates config and QR code (may fail if WireGuard isn't running, but should create the config files).

Run: `docker exec wireguard list-peers`
Expected: Shows the test-device peer.

Run: `docker exec wireguard remove-peer test-device`
Expected: Removes the peer.

**Step 5: Clean up**

Run: `docker compose down && rm -rf ./config .env`

**Step 6: Commit any fixes discovered during smoke testing**

```bash
git add -A
git commit -m "fix: adjustments from integration smoke test"
```
