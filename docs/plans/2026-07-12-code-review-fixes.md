# Code Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all findings from the 2026-07-12 code review — input validation, startup failure semantics, healthcheck coverage, DNSSEC anchor verification, idempotent firewall rules with LAN/peer isolation, and peer-script robustness.

**Architecture:** All changes are shell scripts and config files inside the `rootfs/` overlay plus the Dockerfile. No new services, no new dependencies. The generated `wg0.conf` firewall block changes shape (idempotent `-C || -A` rules, RFC1918/ULA DROP rules); everything else is defensive hardening at existing boundaries.

**Tech Stack:** bash, s6-overlay v3, wireguard-tools, iptables/ip6tables, Unbound, Docker/BuildKit.

## Global Constraints

- There is **no test suite**. Per project CLAUDE.md, verification is: `docker build` the image, then exercise the affected path with targeted `docker run` commands. Every task below carries its own verify steps with expected output — run them exactly.
- Verification image tag: always `docker build -q -t wg-test .` from the repo root, then run checks against `wg-test`. Docker 29.x is installed locally and can build and run the image (Linux VM kernel; `wg genkey`, `iptables` with `--cap-add NET_ADMIN`, and container default routes all work — only `wg-quick up` needs the WireGuard kernel module and is *expected to fail* locally, which two tasks exploit deliberately).
- **wg0.conf is the source of truth** once it exists. Env vars shape the first run only, with the documented exception that `SERVER_PORT` is synced on restart. Don't add new env re-reads on the existing-config path.
- **Key hygiene:** `umask 077` stays at the top of every script that writes under `/config`; key files and `wg0.conf` stay chmod 600, key dirs 700.
- **IPv6 sinkhole:** every generated `ip6tables` rule must carry `|| true` so missing IPv6 support never breaks startup. Do not remove the sinkhole.
- **Anti-detection:** MTU stays 1420, full tunnel stays `0.0.0.0/0, ::/0`, no new exposed ports.
- **Dockerfile chmod rule:** any new script or s6 `run`/`finish`/`up` file must be added to the Dockerfile `chmod +x` line. (The new `timeout-up` file in Task 5 is a *data* file — it must NOT be chmod'd and the existing `find -name "up"` pattern does not match it, which is correct.)
- **Peer data contract:** the `# Peer: <name>` comment format in `wg0.conf` is load-bearing (`remove-peer`'s awk depends on it). Do not change it.
- Work on branch `code-review-fixes`. One commit per task, message style matching `git log` (imperative, no prefix tags).

---

### Task 1: Branch and track CLAUDE.md

`CLAUDE.md` is untracked but documents real contracts (the `# Peer:` comment format, the chmod rule). Commit it first so later tasks can amend it.

**Files:**
- Commit (already exists, untracked): `CLAUDE.md`

- [ ] **Step 1: Create the working branch**

```bash
git checkout -b code-review-fixes
```

Expected: `Switched to a new branch 'code-review-fixes'`

- [ ] **Step 2: Commit CLAUDE.md**

```bash
git add CLAUDE.md
git commit -m "Track CLAUDE.md documenting the repo's contracts"
```

Expected: 1 file changed, clean `git status` afterwards.

---

### Task 2: Validate SERVER_PORT and INTERNAL_SUBNET in wg-init

**Review findings 3 + 4.** A malformed `INTERNAL_SUBNET` currently writes a broken `wg0.conf` that persists across restarts (self-inflicted brick). An unvalidated `SERVER_PORT` is interpolated into a `sed` replacement that can corrupt a known-good config. Additionally, the whole stack silently assumes a /24 (`add-peer` allocates only in the last octet, `svc-unbound` builds its ACL as `x.x.x.0/<prefix>`), so /24 is validated as a hard requirement.

**Files:**
- Modify: `rootfs/usr/local/bin/wg-init`
- Modify: `README.md` (INTERNAL_SUBNET row of the variables table)

**Interfaces:**
- Produces: wg-init exits 1 with `[wg-init] ERROR:` on stderr for invalid `SERVER_PORT` (always) or invalid `INTERNAL_SUBNET` (first run only). Later tasks rely on nothing new here.

- [ ] **Step 1: Add SERVER_PORT validation (applies on every start)**

In `rootfs/usr/local/bin/wg-init`, directly after these existing lines:

```bash
SERVER_PORT="${SERVER_PORT:-51820}"
INTERNAL_SUBNET="${INTERNAL_SUBNET:-10.13.13.0/24}"
```

insert:

```bash
# SERVER_PORT is honored on every start (first-run config + the sync sed
# below) — reject garbage before it can end up inside wg0.conf.
if ! [[ "${SERVER_PORT}" =~ ^[0-9]+$ ]] || [ "${SERVER_PORT}" -lt 1 ] || [ "${SERVER_PORT}" -gt 65535 ]; then
    echo "[wg-init] ERROR: SERVER_PORT must be a port number 1-65535 (got: '${SERVER_PORT}')" >&2
    exit 1
fi
```

- [ ] **Step 2: Add INTERNAL_SUBNET validation (first run only)**

Inside the first-run branch, directly after this existing line:

```bash
    echo "[wg-init] First run — generating server keys and config"
```

insert:

```bash
    # The stack assumes a /24: add-peer allocates in the last octet and
    # svc-unbound derives its ACL as x.x.x.0/24. Reject anything else
    # before a broken wg0.conf gets persisted. Existing installs are not
    # re-validated — INTERNAL_SUBNET is ignored after first run anyway.
    if ! [[ "${INTERNAL_SUBNET}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.0/24$ ]] ||
       [ "${BASH_REMATCH[1]}" -gt 255 ] || [ "${BASH_REMATCH[2]}" -gt 255 ] || [ "${BASH_REMATCH[3]}" -gt 255 ]; then
        echo "[wg-init] ERROR: INTERNAL_SUBNET must be a /24 in the form x.x.x.0/24 (got: '${INTERNAL_SUBNET}')" >&2
        exit 1
    fi
```

- [ ] **Step 3: Build and verify rejection + acceptance**

```bash
docker build -q -t wg-test .
docker run --rm -e INTERNAL_SUBNET=10.13.13.0 --entrypoint bash wg-test /usr/local/bin/wg-init; echo "exit=$?"
docker run --rm -e SERVER_PORT=notaport --entrypoint bash wg-test /usr/local/bin/wg-init; echo "exit=$?"
docker run --rm --entrypoint bash wg-test /usr/local/bin/wg-init; echo "exit=$?"
```

Expected, in order:
1. `[wg-init] ERROR: INTERNAL_SUBNET must be a /24 ...` then `exit=1`
2. `[wg-init] ERROR: SERVER_PORT must be a port number ...` then `exit=1`
3. First-run log lines ending in `[wg-init] WireGuard initialization complete` then `exit=0`

(Note: wg-init is invoked as `bash /path` here to bypass the `with-contenv` shebang, which needs the s6 environment.)

- [ ] **Step 4: Update the README variables table**

In `README.md`, in the `INTERNAL_SUBNET` row of the variables table, change the beginning of the description from:

```
VPN subnet (default: `10.13.13.0/24`). Change it only if
```

to:

```
VPN subnet (default: `10.13.13.0/24`). **Must be a /24 in the form `x.x.x.0/24`** — the container refuses first start otherwise. Change it only if
```

- [ ] **Step 5: Commit**

```bash
git add rootfs/usr/local/bin/wg-init README.md
git commit -m "Validate SERVER_PORT and INTERNAL_SUBNET before they can brick wg0.conf"
```

---

### Task 3: Warn when regenerating server keys with leftover peer directories

**Minor finding B.** First run with a leftover `./config/peers/` (user wiped `wg/` only) silently regenerates server keys, invalidating every existing peer config.

**Files:**
- Modify: `rootfs/usr/local/bin/wg-init`

- [ ] **Step 1: Add the warning**

Inside the first-run branch of `rootfs/usr/local/bin/wg-init`, directly after the INTERNAL_SUBNET validation block added in Task 2 (or, if executing this task standalone, directly after `echo "[wg-init] First run — generating server keys and config"`), insert:

```bash
    if [ -n "$(ls -A "${CONFIG_DIR}/peers" 2>/dev/null)" ]; then
        echo "[wg-init] WARNING: found existing peer directories but no server config — new server keys will be generated"
        echo "[wg-init] WARNING: every existing peer config is now invalid; run remove-peer then add-peer for each device"
    fi
```

- [ ] **Step 2: Build and verify**

```bash
docker build -q -t wg-test .
docker run --rm --entrypoint sh wg-test -c 'mkdir -p /config/peers/old-phone && bash /usr/local/bin/wg-init'
```

Expected: output contains both `WARNING: found existing peer directories` lines and still ends with `WireGuard initialization complete` (warning, not error).

Also verify the warning does NOT fire on a clean first run:

```bash
docker run --rm --entrypoint bash wg-test /usr/local/bin/wg-init | grep -c "peer directories" || echo "no-warning-ok"
```

Expected: `0` then `no-warning-ok` (grep -c prints 0 and exits nonzero when there is no match).

- [ ] **Step 3: Commit**

```bash
git add rootfs/usr/local/bin/wg-init
git commit -m "Warn when first run finds leftover peer directories"
```

---

### Task 4: Rework the generated firewall block — idempotent rules + LAN/peer isolation

**Finding 6 (user decision: strict proxy-only) + minor finding A.** Two changes to the `PostUp`/`PostDown` block that `wg-init` writes into new configs:

1. Every `PostUp` add becomes `-C` (check) `|| -A` (add), so an unclean interface loss (where `wg-quick down` never ran `PostDown`) no longer accumulates duplicate rules within a container lifetime.
2. Forwarded traffic from `wg0` to private destinations (RFC1918 v4, ULA v6) is dropped **before** the ACCEPT — VPN clients get internet-only. DNS is unaffected: client queries go to the server's own wg0 address (`x.x.x.1` / `fd00::1`), which is INPUT, not FORWARD.

**Scope limitation (deliberate):** wg0.conf is the persisted source of truth, so this only shapes *newly generated* configs. Existing installs get a startup WARNING plus README migration instructions — no automatic rewrite of a persisted firewall block (too risky for a one-off migration).

**Files:**
- Modify: `rootfs/usr/local/bin/wg-init` (heredoc + existing-config warning)
- Modify: `README.md` (Anti-Detection section)
- Modify: `CLAUDE.md` (Design Constraints)

**Interfaces:**
- Produces: generated `wg0.conf` PostUp block where each v4 rule is `iptables -C ... 2>/dev/null || iptables -A ...` and each v6 rule additionally ends in `|| true`. Task 9's end-to-end check greps for `-d 10.0.0.0/8`.

- [ ] **Step 1: Replace the PostUp/PostDown block in the heredoc**

In `rootfs/usr/local/bin/wg-init`, inside the `cat > "${WG_CONF}" <<EOF` heredoc, replace these exact lines:

```
PostUp = iptables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE || true
PostUp = ip6tables -A FORWARD -i wg0 -j ACCEPT || true
PostUp = ip6tables -A FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT || true
PostDown = iptables -t nat -D POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE || true
PostDown = ip6tables -D FORWARD -i wg0 -j ACCEPT || true
PostDown = ip6tables -D FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT || true
```

with (line order is load-bearing — DROPs must be appended before the ACCEPT):

```
PostUp = iptables -t nat -C POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostUp = iptables -C FORWARD -i wg0 -d 10.0.0.0/8 -j DROP 2>/dev/null || iptables -A FORWARD -i wg0 -d 10.0.0.0/8 -j DROP
PostUp = iptables -C FORWARD -i wg0 -d 172.16.0.0/12 -j DROP 2>/dev/null || iptables -A FORWARD -i wg0 -d 172.16.0.0/12 -j DROP
PostUp = iptables -C FORWARD -i wg0 -d 192.168.0.0/16 -j DROP 2>/dev/null || iptables -A FORWARD -i wg0 -d 192.168.0.0/16 -j DROP
PostUp = iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -C FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp = ip6tables -t nat -C POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE || true
PostUp = ip6tables -C FORWARD -i wg0 -d fc00::/7 -j DROP 2>/dev/null || ip6tables -A FORWARD -i wg0 -d fc00::/7 -j DROP || true
PostUp = ip6tables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -i wg0 -j ACCEPT || true
PostUp = ip6tables -C FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT || true
PostDown = iptables -t nat -D POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -d 10.0.0.0/8 -j DROP
PostDown = iptables -D FORWARD -i wg0 -d 172.16.0.0/12 -j DROP
PostDown = iptables -D FORWARD -i wg0 -d 192.168.0.0/16 -j DROP
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE || true
PostDown = ip6tables -D FORWARD -i wg0 -d fc00::/7 -j DROP || true
PostDown = ip6tables -D FORWARD -i wg0 -j ACCEPT || true
PostDown = ip6tables -D FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT || true
```

- [ ] **Step 2: Warn existing installs that predate isolation**

In the `else` branch of `wg-init` (existing config found), directly after the three `WARNING: INTERNAL_SUBNET ...` lines' closing `fi`, insert:

```bash
    # Configs generated before LAN isolation existed still allow VPN
    # clients into the home LAN — detect by the absence of the DROP rule.
    if ! grep -q -- '-d 10\.0\.0\.0/8' "${WG_CONF}"; then
        echo "[wg-init] WARNING: wg0.conf predates LAN isolation — VPN clients can reach the home LAN and each other"
        echo "[wg-init] WARNING: see README 'Client isolation' for how to migrate the firewall block"
    fi
```

- [ ] **Step 3: Build and verify rule generation, ordering, and idempotency**

```bash
docker build -q -t wg-test .
docker run --rm --cap-add NET_ADMIN --entrypoint sh wg-test -c '
  bash /usr/local/bin/wg-init >/dev/null
  # Execute the PostUp commands twice, as two interface flaps would
  grep "^PostUp" /config/wg/wg0.conf | sed "s/^PostUp = //" | while read -r c; do sh -c "$c" || true; done
  grep "^PostUp" /config/wg/wg0.conf | sed "s/^PostUp = //" | while read -r c; do sh -c "$c" || true; done
  iptables -S FORWARD'
```

Expected `iptables -S FORWARD` output — each rule exactly ONCE, DROPs before ACCEPT:

```
-P FORWARD ...
-A FORWARD -i wg0 -d 10.0.0.0/8 -j DROP
-A FORWARD -i wg0 -d 172.16.0.0/12 -j DROP
-A FORWARD -i wg0 -d 192.168.0.0/16 -j DROP
-A FORWARD -i wg0 -j ACCEPT
-A FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

(iptables may print `-d` before `-i`; order of flags within a line doesn't matter — rule order and uniqueness do.)

Also verify the legacy warning fires on an old-style config:

```bash
docker run --rm --entrypoint sh wg-test -c '
  mkdir -p /config/wg
  printf "[Interface]\nAddress = 10.13.13.1/24, fd00::1/64\nListenPort = 51820\nPrivateKey = x\nPostUp = iptables -A FORWARD -i wg0 -j ACCEPT\n" > /config/wg/wg0.conf
  bash /usr/local/bin/wg-init' | grep -c "predates LAN isolation"
```

Expected: `2` (both warning lines).

- [ ] **Step 4: Document in README**

In `README.md`, add a bullet to the Anti-Detection list after the `**No IPv6 leaks**` bullet:

```markdown
- **LAN isolation** — VPN clients can only reach the internet: forwarded traffic from the tunnel to private ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`) is dropped, so a lost or stolen peer config cannot be used to reach devices on your home network, and peers cannot see each other. DNS (served from inside the container) still works.
```

Then add a new subsection at the end of the Anti-Detection section (before `## Enabling real IPv6 egress`):

```markdown
### Client isolation on existing installs

`wg0.conf` is generated once, so installs created before LAN isolation keep the old
firewall block (the container logs a `[wg-init] WARNING` about it). To migrate without
re-onboarding devices: stop the container, edit `./config/wg/wg0.conf` (as root), replace
the `PostUp`/`PostDown` lines with the block a fresh install generates (see
`rootfs/usr/local/bin/wg-init` — substitute your uplink interface, normally `eth0`, for
`${DEFAULT_IFACE}`), and start the container again. Alternatively, delete `./config/wg`
and `./config/peers` and re-add every peer.
```

- [ ] **Step 5: Document the constraint in CLAUDE.md**

In `CLAUDE.md`, add a bullet to the `## Design Constraints` list after the anti-detection bullet:

```markdown
- **Client isolation**: generated configs DROP forwarded traffic from wg0 to RFC1918/ULA destinations before the ACCEPT rule — VPN clients are internet-only. All PostUp rules use `-C ... || -A ...` so interface flaps don't duplicate them. Preserve both properties when touching the firewall block.
```

- [ ] **Step 6: Commit**

```bash
git add rootfs/usr/local/bin/wg-init README.md CLAUDE.md
git commit -m "Isolate VPN clients from the LAN and make firewall rules idempotent"
```

---

### Task 5: Fail startup instead of hanging when wg0 cannot come up

**Finding 1.** `svc-wireguard` is a longrun with a `notification-fd` and no `timeout-up`, so s6-rc waits for readiness forever while s6-supervise restarts a failing `wg-quick up` in a loop — the container sits "Up" but broken, and `S6_BEHAVIOUR_IF_STAGE2_FAILS=2` never fires. A `timeout-up` of 60s (healthy startup takes <5s) makes stage2 fail, the container exit, and Docker's restart policy take over — matching the documented failure model.

**Files:**
- Create: `rootfs/etc/s6-overlay/s6-rc.d/svc-wireguard/timeout-up` (data file — do NOT add to the Dockerfile chmod line)
- Modify: `README.md` ("Unknown device type" troubleshooting section)
- Modify: `CLAUDE.md` (s6 service graph section)

- [ ] **Step 1: Create the timeout-up file**

Create `rootfs/etc/s6-overlay/s6-rc.d/svc-wireguard/timeout-up` with exactly this content (milliseconds, no trailing spaces):

```
60000
```

- [ ] **Step 2: Build and verify the container now exits on persistent wg-quick failure**

Locally, `docker run` without `--cap-add NET_ADMIN` makes `wg-quick up` fail persistently — exactly the failure mode being fixed:

```bash
docker build -q -t wg-test .
docker run -d --name wg-timeout-test wg-test
docker wait wg-timeout-test
docker logs wg-timeout-test 2>&1 | tail -5
docker rm wg-timeout-test
```

Expected: `docker wait` returns (unblocks) after ~60–90 seconds and prints a **non-zero** exit code; the logs show repeated `wg-quick` permission errors followed by an s6-rc timeout/failure message. Before this fix, `docker wait` would block forever (if it's still blocked after 3 minutes, the fix isn't working — kill it with `docker rm -f wg-timeout-test` and debug).

- [ ] **Step 3: Update README**

In `README.md`, in the `### wg0 fails to start with "Unknown device type"` section, after the paragraph ending `before a reboot), reboot the Pi, or make the module load at every boot:` — append this sentence to that paragraph:

```
While the module is unavailable the container exits and Docker restarts it in a loop (visible in `docker ps` as a recent "Restarting"/short uptime), so it recovers by itself once the module loads.
```

- [ ] **Step 4: Update CLAUDE.md**

In `CLAUDE.md`, in the `### s6 service graph` section, after the sentence explaining `S6_BEHAVIOUR_IF_STAGE2_FAILS=2`, append:

```
`svc-wireguard` has a 60s `timeout-up`, so a persistently failing `wg-quick up` (e.g. missing kernel module) fails stage2 and kills the container instead of hanging it in a supervised crash-loop forever.
```

- [ ] **Step 5: Commit**

```bash
git add rootfs/etc/s6-overlay/s6-rc.d/svc-wireguard/timeout-up README.md CLAUDE.md
git commit -m "Fail startup after 60s instead of hanging when wg0 cannot come up"
```

---

### Task 6: Extend the healthcheck to cover the DNS resolver

**Finding 2 + minor finding C.** The healthcheck only watches `wg0`; a dead Unbound means clients have a tunnel but no DNS — effectively broken — while `docker ps` reports healthy. `svc-duckdns` is deliberately excluded (it self-skips when unconfigured and its failures are transient and logged).

**Files:**
- Modify: `Dockerfile` (HEALTHCHECK + EXPOSE comment)

- [ ] **Step 1: Update the HEALTHCHECK**

In `Dockerfile`, replace:

```dockerfile
# Surface VPN health in `docker ps`. Visibility only: Docker does NOT restart
# unhealthy containers — the restart path is S6_BEHAVIOUR_IF_STAGE2_FAILS above.
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s --retries=3 \
    CMD wg show wg0 || exit 1
```

with:

```dockerfile
# Surface VPN health in `docker ps`: tunnel up AND resolver alive (a dead
# Unbound means clients have a tunnel but no DNS). Visibility only: Docker
# does NOT restart unhealthy containers — the restart path is
# S6_BEHAVIOUR_IF_STAGE2_FAILS above. svc-duckdns is deliberately excluded:
# it self-skips when unconfigured and its failures are transient and logged.
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s --retries=3 \
    CMD wg show wg0 && pgrep unbound || exit 1
```

- [ ] **Step 2: Clarify the EXPOSE line**

In `Dockerfile`, replace:

```dockerfile
# WireGuard port
EXPOSE 51820/udp
```

with:

```dockerfile
# WireGuard port. Documentation only — the published port actually follows
# SERVER_PORT in docker-compose.yml.
EXPOSE 51820/udp
```

- [ ] **Step 3: Build and verify**

```bash
docker build -q -t wg-test .
docker inspect --format '{{json .Config.Healthcheck.Test}}' wg-test
docker run --rm --entrypoint sh wg-test -c 'wg show wg0 && pgrep unbound; echo "healthcheck-exit=$?"'
```

Expected: inspect prints `["CMD-SHELL","wg show wg0 && pgrep unbound || exit 1"]` (or the same with literal `&&`); the run prints a wg error and `healthcheck-exit=` with a **non-zero** value (nothing is running, so the check correctly fails).

- [ ] **Step 4: Commit**

```bash
git add Dockerfile
git commit -m "Extend healthcheck to cover the DNS resolver"
```

---

### Task 7: Verify the DNSSEC root anchor instead of blindly continuing

**Minor finding D.** `unbound-anchor ... || true` is required (exit 1 legitimately means "anchor created/updated") but it also masks genuine failures. Replace blind masking with a concrete post-condition: the anchor file must exist and be non-empty, or the service fails loudly (crash-looping visibly, and now caught by the Task 6 healthcheck as unhealthy DNS).

**Files:**
- Modify: `rootfs/etc/s6-overlay/s6-rc.d/svc-unbound/run`

- [ ] **Step 1: Add the post-condition**

In `rootfs/etc/s6-overlay/s6-rc.d/svc-unbound/run`, replace:

```bash
# unbound-anchor exits 1 when it (re)creates the anchor from its builtin
# keys or the IANA certificate fallback — that is success, not an error.
unbound-anchor -a /var/lib/unbound/root.key || true
```

with:

```bash
# unbound-anchor exits 1 when it (re)creates the anchor from its builtin
# keys or the IANA certificate fallback — that is success, not an error.
# The real post-condition is a usable anchor file, checked below.
unbound-anchor -a /var/lib/unbound/root.key || true
if [ ! -s /var/lib/unbound/root.key ]; then
    echo "[unbound] ERROR: DNSSEC root trust anchor was not created — refusing to start without validation" >&2
    exit 1
fi
```

- [ ] **Step 2: Build and verify both paths**

```bash
docker build -q -t wg-test .
# Happy path: anchor gets created (works offline via unbound-anchor's builtin keys)
docker run --rm --entrypoint sh wg-test -c '
  mkdir -p /var/lib/unbound
  unbound-anchor -a /var/lib/unbound/root.key || true
  test -s /var/lib/unbound/root.key && echo ANCHOR-OK'
# Failure path: simulate a missing anchor and check the guard logic
docker run --rm --entrypoint sh wg-test -c '
  test -s /nonexistent/root.key || { echo "[unbound] ERROR: DNSSEC root trust anchor was not created" >&2; exit 1; }' \
  ; echo "guard-exit=$?"
# Syntax check of the edited run script
docker run --rm --entrypoint bash wg-test -n /etc/s6-overlay/s6-rc.d/svc-unbound/run && echo SYNTAX-OK
```

Expected: `ANCHOR-OK`, then the ERROR line with `guard-exit=1`, then `SYNTAX-OK`.

- [ ] **Step 3: Commit**

```bash
git add rootfs/etc/s6-overlay/s6-rc.d/svc-unbound/run
git commit -m "Refuse to start unbound without a DNSSEC root trust anchor"
```

---

### Task 8: Harden the peer scripts — locking, atomic updates, tolerant removal

**Finding 5 + minor finding E.** Three related robustness fixes:
1. `remove-peer` aborts (`set -e`) on a missing `public.key`, leaving partially-created peers unremovable — it should clean up anyway and just skip the live-interface removal.
2. `add-peer` appends to `wg0.conf` non-atomically — an interrupt mid-append leaves a dangling half block. Use the same tmp+`mv` pattern `remove-peer` already uses.
3. Concurrent `add-peer`/`remove-peer` runs race on IP allocation and the conf rewrite — serialize with `flock` (busybox provides it).

**Files:**
- Modify: `rootfs/usr/local/bin/add-peer`
- Modify: `rootfs/usr/local/bin/remove-peer`

**Interfaces:**
- Produces: lock file `/config/.peers.lock` (created with umask 077). Peer data contract (`# Peer: <name>` comment, per-peer directory layout) is unchanged.

- [ ] **Step 1: Confirm flock exists in the image**

```bash
docker build -q -t wg-test . && docker run --rm --entrypoint sh wg-test -c 'command -v flock && flock --help 2>&1 | head -1'
```

Expected: a path (e.g. `/usr/bin/flock`) and a usage line. If flock is somehow absent, STOP and flag it — do not silently skip the locking part.

- [ ] **Step 2: Add locking to add-peer**

In `rootfs/usr/local/bin/add-peer`, directly after this existing block:

```bash
if [ ! -f "${WG_CONF}" ]; then
    echo "Error: WireGuard server config not found at ${WG_CONF}"
    echo "  The container may not have finished initializing. Check: docker compose logs"
    exit 1
fi
```

insert:

```bash
# Serialize peer operations — add-peer and remove-peer both rewrite wg0.conf
# and concurrent runs would race on IP allocation.
exec 9>"${CONFIG_DIR}/.peers.lock"
flock -x 9
```

- [ ] **Step 3: Make the add-peer config append atomic**

In `rootfs/usr/local/bin/add-peer`, replace:

```bash
# Add peer to server config
cat >> "${WG_CONF}" <<EOF

# Peer: ${PEER_NAME}
[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
PresharedKey = ${PEER_PRESHARED_KEY}
AllowedIPs = ${PEER_IP}/32, ${PEER_IP6}/128
EOF
```

with:

```bash
# Add peer to server config (write-then-rename so an interrupted run can
# never leave a half-appended [Peer] block behind)
cp "${WG_CONF}" "${WG_CONF}.tmp"
cat >> "${WG_CONF}.tmp" <<EOF

# Peer: ${PEER_NAME}
[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
PresharedKey = ${PEER_PRESHARED_KEY}
AllowedIPs = ${PEER_IP}/32, ${PEER_IP6}/128
EOF
mv "${WG_CONF}.tmp" "${WG_CONF}"
```

- [ ] **Step 4: Add locking and missing-key tolerance to remove-peer**

In `rootfs/usr/local/bin/remove-peer`, replace:

```bash
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
```

with:

```bash
# Check if peer exists
if [ ! -d "${PEER_DIR}" ]; then
    echo "Error: peer '${PEER_NAME}' not found"
    exit 1
fi

# Serialize peer operations — add-peer and remove-peer both rewrite wg0.conf
# and concurrent runs would race on IP allocation.
exec 9>"${CONFIG_DIR}/.peers.lock"
flock -x 9

# Read peer public key. It can be missing if add-peer was interrupted —
# still clean up the config entry and directory; only skip the live removal.
PEER_PUBLIC_KEY=$(cat "${PEER_DIR}/public.key" 2>/dev/null || true)
if [ -z "${PEER_PUBLIC_KEY}" ]; then
    echo "[remove-peer] WARNING: ${PEER_DIR}/public.key is missing — skipping live interface removal"
fi

# Remove peer from running WireGuard if active
if [ -n "${PEER_PUBLIC_KEY}" ] && ip link show wg0 > /dev/null 2>&1; then
    wg set wg0 peer "${PEER_PUBLIC_KEY}" remove
    echo "[remove-peer] Peer removed from running WireGuard interface"
fi
```

- [ ] **Step 5: Build and verify the partial-peer recovery path**

```bash
docker build -q -t wg-test .
docker run --rm --entrypoint sh wg-test -c '
  set -e
  mkdir -p /config/wg /config/peers/ghost
  cat > /config/wg/wg0.conf <<EOF
[Interface]
Address = 10.13.13.1/24, fd00::1/64
ListenPort = 51820
PrivateKey = x

# Peer: ghost
[Peer]
PublicKey = fake
AllowedIPs = 10.13.13.2/32
EOF
  remove-peer ghost
  ! grep -q "# Peer: ghost" /config/wg/wg0.conf
  test ! -d /config/peers/ghost
  echo PARTIAL-PEER-REMOVED-OK'
```

Expected: the `WARNING: ... public.key is missing` line, `Peer 'ghost' removed successfully.`, then `PARTIAL-PEER-REMOVED-OK`.

- [ ] **Step 6: Verify concurrent adds allocate distinct IPs**

```bash
docker run --rm -e SERVER_URL=example.duckdns.org --entrypoint sh wg-test -c '
  bash /usr/local/bin/wg-init >/dev/null
  add-peer phone >/dev/null 2>&1 & add-peer laptop >/dev/null 2>&1 & wait
  grep "^AllowedIPs" /config/wg/wg0.conf | grep -oE "10\.13\.13\.[0-9]+" | sort'
```

Expected: exactly two lines, `10.13.13.2` and `10.13.13.3` (distinct — no duplicate allocation).

- [ ] **Step 7: Commit**

```bash
git add rootfs/usr/local/bin/add-peer rootfs/usr/local/bin/remove-peer
git commit -m "Harden peer scripts: serialize runs, atomic config updates, tolerate partial peers"
```

---

### Task 9: Final end-to-end verification

Everything together on a fresh build: first run, add/list/remove peers, isolation rules present, docs consistent.

**Files:** none (verification only)

- [ ] **Step 1: Full build via the project's canonical command**

```bash
docker compose build
```

Expected: builds without error.

- [ ] **Step 2: End-to-end peer lifecycle inside the image**

```bash
docker build -q -t wg-test .
docker run --rm -e SERVER_URL=example.duckdns.org --entrypoint sh wg-test -c '
  set -e
  bash /usr/local/bin/wg-init
  grep -q -- "-d 10.0.0.0/8" /config/wg/wg0.conf          # isolation rules generated
  grep -qc "iptables -C" /config/wg/wg0.conf               # idempotent form generated
  add-peer phone >/dev/null
  add-peer laptop >/dev/null
  list-peers
  remove-peer phone >/dev/null
  ! grep -q "# Peer: phone" /config/wg/wg0.conf
  grep -q "# Peer: laptop" /config/wg/wg0.conf
  stat -c "%a" /config/wg/wg0.conf | grep -qx 600          # perms preserved
  echo E2E-PASS'
```

Expected: first-run log, a two-row `list-peers` table (phone + laptop, handshake `never`), then `E2E-PASS`.

- [ ] **Step 3: Review the diff as a whole**

```bash
git log --oneline main..HEAD
git diff main..HEAD --stat
```

Expected: 8 commits (Tasks 1–8), touching only: `CLAUDE.md`, `README.md`, `Dockerfile`, `rootfs/usr/local/bin/{wg-init,add-peer,remove-peer}`, `rootfs/etc/s6-overlay/s6-rc.d/svc-unbound/run`, `rootfs/etc/s6-overlay/s6-rc.d/svc-wireguard/timeout-up`. Anything else is scope creep — investigate before finishing.

- [ ] **Step 4: Deployment note for the user (do not perform — just surface it)**

Two changes only apply to the user's real Pi deployment after action on their side:
- The LAN-isolation firewall block applies to **newly generated** configs; their existing `wg0.conf` logs a `[wg-init] WARNING` and keeps LAN access until migrated (README "Client isolation on existing installs").
- On the Pi, `docker compose build && docker compose up -d` picks up the new image.

---

## Review-Finding → Task Coverage

| Finding | Task |
|---|---|
| 1. Longrun startup hang (no `timeout-up`) | 5 |
| 2. Healthcheck ignores Unbound | 6 |
| 3. `INTERNAL_SUBNET` unvalidated / /24 assumption | 2 |
| 4. `SERVER_PORT` sed injection | 2 |
| 5. `remove-peer` stuck on partial peers | 8 |
| 6. LAN/peer access (decision: block) | 4 |
| A. iptables rule accumulation on flap | 4 |
| B. Leftover-peers regeneration warning | 3 |
| C. Hardcoded `EXPOSE` (comment) | 6 |
| D. `unbound-anchor \|\| true` masking | 7 |
| E. Concurrent add-peer race | 8 |
| F. Untracked CLAUDE.md | 1 |
