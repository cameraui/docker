#!/usr/bin/env bash
# Create an LXC on a Proxmox host and run the camera.ui Docker image in it.
# Run on the Proxmox host (uses pct/pveam). Tunables (env):
#   CTID              container id            (default: next free id)
#   CT_HOSTNAME       container hostname      (default: cameraui)
#   CORES             vCPUs                   (default: 4)
#   RAM_MB            memory in MB            (default: 4096)
#   DISK_GB           rootfs size in GB       (default: 16)
#   BRIDGE            network bridge          (default: vmbr0)
#   STORAGE           rootfs storage          (default: local-lvm)
#   TEMPLATE_STORAGE  template store           (default: local)
#   FLAVOR            cpu|intel|nvidia|amd    (default: cpu)
#   IMAGE             image repo              (default: ghcr.io/cameraui/camera.ui)
#   GPU_PASSTHROUGH   1 to bind /dev/dri      (default: 1 when FLAVOR!=cpu)
set -euo pipefail

CTID="${CTID:-$(pvesh get /cluster/nextid)}"
CT_HOSTNAME="${CT_HOSTNAME:-cameraui}"
CORES="${CORES:-4}"
RAM_MB="${RAM_MB:-4096}"
DISK_GB="${DISK_GB:-16}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
FLAVOR="${FLAVOR:-cpu}"
IMAGE="${IMAGE:-ghcr.io/cameraui/camera.ui}"
GPU_PASSTHROUGH="${GPU_PASSTHROUGH:-$([ "$FLAVOR" = cpu ] && echo 0 || echo 1)}"

command -v pct >/dev/null || { echo "This script must run on a Proxmox VE host." >&2; exit 1; }

# --- ensure an Ubuntu 24.04 template is available ----------------------------
echo "==> ensuring Ubuntu 24.04 LXC template"
pveam update >/dev/null 2>&1 || true
TEMPLATE="$(pveam available --section system | awk '/ubuntu-24.04-standard/ {print $2}' | sort -V | tail -1)"
[ -z "$TEMPLATE" ] && { echo "no ubuntu-24.04 template found via pveam" >&2; exit 1; }
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
    # pveam download can fail without a non-zero exit (e.g. DNS errors) — verify.
    pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE" \
        || { echo "template download failed: ${TEMPLATE}" >&2; exit 1; }
fi

# --- create the container ----------------------------------------------------
# Unprivileged + nesting: Docker needs nesting, and on PVE 9 a *privileged* LXC
# can no longer load Docker's AppArmor profile (apparmor_parser: access denied),
# while unprivileged + nesting works. Verified on PVE 9.2.
echo "==> creating LXC ${CTID} (${CT_HOSTNAME})"
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM_MB" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --features "nesting=1,keyctl=1" \
    --unprivileged 1 \
    --onboot 1

# GPU passthrough (Intel/AMD VA-API) via pct device passthrough — works for
# unprivileged containers (PVE >= 8.2). NVIDIA needs extra host driver setup.
if [ "$GPU_PASSTHROUGH" = "1" ]; then
    echo "==> adding /dev/dri passthrough"
    pct set "$CTID" --dev0 "path=/dev/dri/renderD128,mode=0666"
fi

pct start "$CTID"
echo "==> waiting for network..."
for _ in $(seq 1 30); do pct exec "$CTID" -- bash -lc 'getent hosts deb.debian.org >/dev/null 2>&1' && break; sleep 2; done

# --- install Docker + camera.ui ---------------------------------------------
echo "==> installing Docker inside the container"
pct exec "$CTID" -- bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
'

echo "==> deploying camera.ui (${FLAVOR})"
TAG="$([ "$FLAVOR" = cpu ] && echo latest || echo "$FLAVOR")"
pct exec "$CTID" -- bash -lc "
set -e
mkdir -p /opt/cameraui
cat > /opt/cameraui/docker-compose.yml <<YML
name: cameraui
services:
  cameraui:
    image: ${IMAGE}:${TAG}
    container_name: cameraui
    restart: unless-stopped
    network_mode: host
    environment:
      - TZ=Europe/Berlin
      - CAMERAUI_DOCKER_AVAHI=true
    volumes:
      - cameraui-data:/data
$([ "$GPU_PASSTHROUGH" = 1 ] && printf '    devices:\n      - /dev/dri:/dev/dri\n')
volumes:
  cameraui-data:
YML
cd /opt/cameraui && docker compose up -d
"

IP="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" || true)"
echo ""
echo "==> camera.ui is starting in LXC ${CTID}"
echo "    First boot downloads the server — give it a few minutes, then open:"
echo "    https://${IP:-<container-ip>}:3443"
