FROM alpine:3.21

ARG S6_OVERLAY_VERSION=3.2.0.2
ARG TARGETARCH

# Install s6-overlay (map Docker arch names to s6-overlay arch names)
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && rm /tmp/s6-overlay-noarch.tar.xz

RUN case "${TARGETARCH}" in \
      arm64) S6_ARCH="aarch64" ;; \
      amd64) S6_ARCH="x86_64" ;; \
      *)     S6_ARCH="${TARGETARCH}" ;; \
    esac && \
    wget -q "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" -O /tmp/s6-overlay-arch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz && \
    rm /tmp/s6-overlay-arch.tar.xz

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

# WireGuard port
EXPOSE 51820/udp

ENTRYPOINT ["/init"]
