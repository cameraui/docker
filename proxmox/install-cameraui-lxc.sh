#!/usr/bin/env bash
# Create an LXC on a Proxmox host and run the camera.ui Docker image in it.
# Run on the Proxmox host (uses pct/pveam). Tunables (env):
#   CTID              container id            (default: next free id)
#   CT_HOSTNAME       container hostname      (default: cameraui)
#   CORES             vCPUs                   (default: 4)
#   RAM_MB            memory in MB            (default: 4096)
#   DISK_GB           rootfs size in GB       (default: 16)
#   BRIDGE            network bridge          (default: vmbr0)
#   STORAGE           rootfs storage          (default: auto-detect)
#   TEMPLATE_STORAGE  template store           (default: local)
#   FLAVOR            cpu|intel|amd|nvidia    (default: cpu; nvidia is EXPERIMENTAL)
#   IMAGE             image repo              (default: ghcr.io/cameraui/camera.ui)
#   GPU_PASSTHROUGH   1 to pass GPU devices   (default: 1 when FLAVOR!=cpu)
#   TZ                container timezone      (default: the host's timezone)
set -euo pipefail

CTID="${CTID:-$(pvesh get /cluster/nextid)}"
CT_HOSTNAME="${CT_HOSTNAME:-cameraui}"
CORES="${CORES:-4}"
RAM_MB="${RAM_MB:-4096}"
DISK_GB="${DISK_GB:-16}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
FLAVOR="${FLAVOR:-cpu}"
IMAGE="${IMAGE:-ghcr.io/cameraui/camera.ui}"
GPU_PASSTHROUGH="${GPU_PASSTHROUGH:-$([ "$FLAVOR" = cpu ] && echo 0 || echo 1)}"
TZ="${TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

command -v pct >/dev/null || { echo "This script must run on a Proxmox VE host." >&2; exit 1; }

case "$FLAVOR" in
    cpu|intel|amd) ;;
    nvidia)
        echo "==> FLAVOR=nvidia in an LXC is EXPERIMENTAL."
        echo "    The container's NVIDIA user space must match the host driver version."
        echo "    This script installs it and adds a boot-time sync service that re-installs"
        echo "    the matching version after host driver updates (best effort, needs the"
        echo "    installer to exist on download.nvidia.com). The recommended path is still"
        echo "    a VM with PCIe passthrough: https://docs.cameraui.com/install/proxmox"
        ;;
    *)
        echo "unknown FLAVOR '${FLAVOR}' (expected cpu, intel, amd or nvidia)" >&2
        exit 1 ;;
esac

# An LXC shares the host's GPU driver — verify the host side before creating
# anything. Missing device nodes usually mean the GPU is bound to vfio-pci or
# its driver blacklisted from an earlier VM-passthrough setup.
if [ "$GPU_PASSTHROUGH" = "1" ]; then
    if [ "$FLAVOR" = "nvidia" ]; then
        NVIDIA_DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
        [ -n "$NVIDIA_DRIVER_VERSION" ] || {
            echo "FLAVOR=nvidia needs a working NVIDIA driver on the Proxmox host first" >&2
            echo "(.run installer with --dkms plus pve-headers; nvidia-smi must work)." >&2
            exit 1
        }
        # nvidia-uvm only appears after first CUDA use — load it so it can be passed
        if [ ! -e /dev/nvidia-uvm ]; then
            modprobe nvidia-uvm 2>/dev/null || true
            nvidia-modprobe -u -c0 2>/dev/null || true
        fi
        for node in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm; do
            [ -e "$node" ] || { echo "missing ${node} on the host — driver not fully initialized." >&2; exit 1; }
        done
        # The container gets the same driver version from NVIDIA's archive; without
        # that installer the user space cannot be matched to the host.
        NVIDIA_RUN_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
        curl -fsIL -o /dev/null "$NVIDIA_RUN_URL" || {
            echo "host driver ${NVIDIA_DRIVER_VERSION} has no installer on download.nvidia.com:" >&2
            echo "  ${NVIDIA_RUN_URL}" >&2
            echo "Install a host driver version that exists there, or use a VM instead." >&2
            exit 1
        }
    elif [ ! -e /dev/dri/renderD128 ]; then
        echo "GPU passthrough requested but /dev/dri/renderD128 does not exist on this host." >&2
        echo "If the GPU was configured for VM passthrough (vfio-pci binding, blacklisted" >&2
        echo "i915/amdgpu), revert that first — or run with GPU_PASSTHROUGH=0." >&2
        exit 1
    fi
fi

# --- resolve a rootfs-capable storage ----------------------------------------
# `local-lvm` is the PVE default on LVM-thin installs but is absent on ZFS
# installs (there it's `local-zfs`) and custom layouts, where
# `pct create --rootfs local-lvm:...` fails with "storage 'local-lvm' does not
# exist". Resolve against storages that actually support a container rootfs
# (content type rootdir) and are active, instead of assuming a name.
rootdir_storages() {
    pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'
}
if [ -n "$STORAGE" ]; then
    rootdir_storages | grep -qx "$STORAGE" || {
        echo "storage '$STORAGE' does not exist or cannot hold a container rootfs." >&2
        echo "rootfs-capable storages: $(rootdir_storages | paste -sd' ' -)" >&2
        exit 1
    }
else
    for candidate in local-lvm local-zfs local; do
        if rootdir_storages | grep -qx "$candidate"; then STORAGE="$candidate"; break; fi
    done
    [ -z "$STORAGE" ] && STORAGE="$(rootdir_storages | head -1)"
    [ -z "$STORAGE" ] && {
        echo "no active storage supports a container rootfs (content type 'rootdir')." >&2
        echo "Add or enable one under Datacenter > Storage, or pass STORAGE=<name>." >&2
        exit 1
    }
    echo "==> using rootfs storage '$STORAGE'"
fi

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

# GPU passthrough via pct device passthrough — works for unprivileged
# containers (PVE >= 8.2). Intel/AMD: renderD128 covers VA-API and OpenCL,
# card0 goes along for software that falls back to the card node. NVIDIA:
# every /dev/nvidia* node incl. the caps nodes newer drivers require.
if [ "$GPU_PASSTHROUGH" = "1" ]; then
    DEV_IDX=0
    add_dev() {
        pct set "$CTID" --dev${DEV_IDX} "path=$1,mode=0666"
        DEV_IDX=$((DEV_IDX + 1))
    }
    if [ "$FLAVOR" = "nvidia" ]; then
        echo "==> adding /dev/nvidia* passthrough"
        for node in /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools \
                    /dev/nvidia-modeset /dev/nvidia-caps/nvidia-cap1 /dev/nvidia-caps/nvidia-cap2; do
            if [ -e "$node" ]; then add_dev "$node"; fi
        done
    else
        echo "==> adding /dev/dri passthrough"
        add_dev /dev/dri/renderD128
        if [ -e /dev/dri/card0 ]; then add_dev /dev/dri/card0; fi
    fi
fi

pct start "$CTID"
echo "==> waiting for network..."
NET_OK=0
for _ in $(seq 1 30); do
    if pct exec "$CTID" -- bash -lc 'getent hosts download.docker.com >/dev/null 2>&1'; then NET_OK=1; break; fi
    sleep 2
done
[ "$NET_OK" = 1 ] || {
    echo "container ${CTID} has no network/DNS after 60s — check DHCP on bridge '${BRIDGE}'." >&2
    exit 1
}

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

# --- NVIDIA (EXPERIMENTAL): user space + container toolkit + boot-time sync ---
# The sync script derives the required version from /sys/module/nvidia/version
# (sysfs comes from the host kernel), so it self-heals after host driver
# updates as long as the matching installer exists on download.nvidia.com.
if [ "$FLAVOR" = "nvidia" ]; then
    echo "==> installing NVIDIA user space ${NVIDIA_DRIVER_VERSION} + container toolkit"
    pct exec "$CTID" -- bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive

cat > /usr/local/sbin/cameraui-nvidia-sync <<"SYNC"
#!/usr/bin/env bash
set -euo pipefail
host_ver="$(cat /sys/module/nvidia/version 2>/dev/null || true)"
if [ -z "$host_ver" ]; then
    echo "cameraui-nvidia-sync: no nvidia kernel module loaded on the host, nothing to do"
    exit 0
fi
# nvidia-smi succeeding means user space and host module already match
if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
    exit 0
fi
echo "cameraui-nvidia-sync: installing NVIDIA user space ${host_ver} (matching the host)"
tmp="$(mktemp -d)"
trap "rm -rf $tmp" EXIT
curl -fsSLo "$tmp/nvidia.run" "https://download.nvidia.com/XFree86/Linux-x86_64/${host_ver}/NVIDIA-Linux-x86_64-${host_ver}.run"
sh "$tmp/nvidia.run" --silent --no-kernel-module
SYNC
chmod +x /usr/local/sbin/cameraui-nvidia-sync

cat > /etc/systemd/system/cameraui-nvidia-sync.service <<"UNIT"
[Unit]
Description=Match the NVIDIA user space to the host driver version
Before=docker.service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cameraui-nvidia-sync
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable cameraui-nvidia-sync.service
/usr/local/sbin/cameraui-nvidia-sync

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -o /etc/apt/keyrings/nvidia-container-toolkit.asc
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.asc] https://#g" \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
apt-get install -y --no-install-recommends nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
# an unprivileged LXC cannot manage device cgroups — the toolkit must not try
nvidia-ctk config --set nvidia-container-cli.no-cgroups=true --output /etc/nvidia-container-runtime/config.toml
systemctl restart docker
nvidia-smi -L
'
fi

echo "==> deploying camera.ui (${FLAVOR})"
TAG="$([ "$FLAVOR" = cpu ] && echo latest || echo "$FLAVOR")"
GPU_ENV=""
GPU_YAML=""
if [ "$GPU_PASSTHROUGH" = "1" ]; then
    if [ "$FLAVOR" = "nvidia" ]; then
        GPU_ENV=$'      - NVIDIA_VISIBLE_DEVICES=all\n      - NVIDIA_DRIVER_CAPABILITIES=all'
        GPU_YAML=$'    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu, compute, video, utility]'
    else
        GPU_YAML=$'    devices:\n      - /dev/dri:/dev/dri'
    fi
fi
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
      - TZ=${TZ}
      - CAMERAUI_DOCKER_AVAHI=true
${GPU_ENV}
    volumes:
      - cameraui-data:/data
${GPU_YAML}
volumes:
  cameraui-data:
YML
cd /opt/cameraui && docker compose up -d
"

IP="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" || true)"
echo ""
echo "==> camera.ui is starting in LXC ${CTID}"
if [ "$FLAVOR" = "nvidia" ]; then
    echo ""
    echo "    NVIDIA in an LXC is EXPERIMENTAL. After a host driver update the container"
    echo "    re-syncs its user space at next boot (cameraui-nvidia-sync.service)."
    echo "    Verify anytime with:  pct exec ${CTID} -- docker exec cameraui nvidia-smi"
fi
echo "    First boot downloads the server — give it a few minutes, then open:"
echo "    https://${IP:-<container-ip>}:3443"
echo ""
echo "    Recordings default to the container volume. For a dedicated disk/NAS,"
echo "    bind-mount it and set the NVR storage path to it. A FUSE mount"
echo "    (mergerfs/rclone) on the host must be mounted BEFORE the container"
echo "    starts and shared into it, or the container sees an empty mountpoint on"
echo "    the root disk. Verify inside the container with:  df -h <storage-path>"
echo "    Storage guide: https://docs.cameraui.com/install/proxmox"
