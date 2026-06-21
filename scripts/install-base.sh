#!/usr/bin/env bash
# Base runtime shared by every flavor: node, python, mDNS, ffmpeg/go2rtc libs, s6.
set -euo pipefail

: "${NODE_VERSION:=24}"
: "${S6_OVERLAY_VERSION:=3.2.1.0}"
: "${TARGETARCH:=amd64}"

echo "==> camera.ui base: node ${NODE_VERSION}, s6 ${S6_OVERLAY_VERSION}, arch ${TARGETARCH}"

# Keep downloaded .debs in the BuildKit cache mount across layers.
rm -f /etc/apt/apt.conf.d/docker-clean
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg xz-utils \
    tzdata locales \
    procps psmisc lsof net-tools iproute2 iputils-ping \
    jq nano openssl tini \
    dbus avahi-daemon avahi-utils libnss-mdns libavahi-compat-libdnssd-dev \
    python3 python3-venv python3-pip python3-dev \
    build-essential pkg-config \
    libva2 libva-drm2 libdrm2 \
    libgomp1 libglib2.0-0t64

# --- locale -----------------------------------------------------------------
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen en_US.UTF-8
ln -snf /usr/share/zoneinfo/Etc/UTC /etc/localtime

# --- Node.js (NodeSource) ---------------------------------------------------
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install -y --no-install-recommends nodejs

# allow pip installs into plugin venvs (PEP-668)
rm -f /usr/lib/python3*/EXTERNALLY-MANAGED || true

# --- s6-overlay -------------------------------------------------------------
case "${TARGETARCH}" in
    amd64) S6_ARCH=x86_64  ;;
    arm64) S6_ARCH=aarch64 ;;
    arm)   S6_ARCH=armhf   ;;
    *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;;
esac

cd /tmp
curl -fsSLO "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz"
curl -fsSLO "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz"
tar -C / -Jxpf "/tmp/s6-overlay-noarch.tar.xz"
tar -C / -Jxpf "/tmp/s6-overlay-${S6_ARCH}.tar.xz"
rm -f /tmp/s6-overlay-*.tar.xz

# --- cleanup ----------------------------------------------------------------
rm -rf /tmp/* /var/tmp/*

echo "==> base install done"
