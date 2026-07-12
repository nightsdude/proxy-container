# Requires BuildKit (default since Docker 23; ADD --checksum needs Engine >= 25)
ARG S6_OVERLAY_VERSION=3.2.0.2

# Per-arch s6-overlay tarballs with pinned checksums (BuildKit verifies at
# download time). Only the stage matching TARGETARCH is fetched. When bumping
# S6_OVERLAY_VERSION, update the checksums from the release's .sha256 files.
FROM scratch AS s6-arm64
ARG S6_OVERLAY_VERSION
ADD --checksum=sha256:8b22a2eaca4bf0b27a43d36e65c89d2701738f628d1abd0cea5569619f66f785 \
    https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-aarch64.tar.xz \
    /s6-overlay-arch.tar.xz

FROM scratch AS s6-amd64
ARG S6_OVERLAY_VERSION
ADD --checksum=sha256:59289456ab1761e277bd456a95e737c06b03ede99158beb24f12b165a904f478 \
    https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz \
    /s6-overlay-arch.tar.xz

# Select the stage matching the build platform (TARGETARCH is set by BuildKit)
FROM s6-${TARGETARCH} AS s6-arch

FROM alpine:3.21
ARG S6_OVERLAY_VERSION

# Install s6-overlay
ADD --checksum=sha256:6dbcde158a3e78b9bb141d7bcb5ccb421e563523babbe2c64470e76f4fd02dae \
    https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz \
    /tmp/s6-overlay-noarch.tar.xz
COPY --from=s6-arch /s6-overlay-arch.tar.xz /tmp/s6-overlay-arch.tar.xz
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz && \
    rm /tmp/s6-overlay-noarch.tar.xz /tmp/s6-overlay-arch.tar.xz

# Install packages
RUN apk add --no-cache \
    wireguard-tools \
    iptables \
    ip6tables \
    unbound \
    bash \
    curl \
    libqrencode-tools \
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

# WireGuard port. Documentation only — the published port actually follows
# SERVER_PORT in docker-compose.yml.
EXPOSE 51820/udp

# If any s6-rc service fails to start (e.g. init-wireguard), stop the container
# so Docker's restart policy retries instead of leaving a dead-but-"Up" container.
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# Surface VPN health in `docker ps`: tunnel up AND resolver alive (a dead
# Unbound means clients have a tunnel but no DNS). Visibility only: Docker
# does NOT restart unhealthy containers — the restart path is
# S6_BEHAVIOUR_IF_STAGE2_FAILS above. svc-duckdns is deliberately excluded:
# it self-skips when unconfigured and its failures are transient and logged.
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s --retries=3 \
    CMD wg show wg0 && pgrep unbound || exit 1

ENTRYPOINT ["/init"]
