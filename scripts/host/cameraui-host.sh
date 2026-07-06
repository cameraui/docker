#!/usr/bin/env bash
# camera.ui host helper — diagnose and prepare a Linux host for hardware
# acceleration with the camera.ui docker image.
#
#   cameraui-host.sh check     probe drivers, docker runtime and device nodes (read-only)
#   cameraui-host.sh nvidia    install the NVIDIA Container Toolkit (needs the GPU driver first)
#   cameraui-host.sh hailo     build + install the Hailo PCIe kernel driver + firmware
#   cameraui-host.sh coral     install the gasket/apex kernel driver for PCIe/M.2 Coral TPUs
#
# `check` is the host-side half of the hw diagnosis; the container logs its own
# half on boot ("[setup] accelerator devices: ..."). Together they answer:
# "what does the host have?" and "what actually arrives in the container?"
#
# Supported: Ubuntu 22.04 / 24.04 (and Debian-based derivatives, best effort).
set -euo pipefail

DOCS_URL="https://github.com/cameraui/docs"
HAILO_VERSION="4.21.0" # must match the hailort wheel pinned in the camera-ui-hailo plugin
# feranick's fork — Google's gasket-dkms no longer builds on kernels >= 6.13
# (no_llseek removed, MODULE_IMPORT_NS signature change).
GASKET_DKMS_VERSION="1.0-18.4"
GASKET_DKMS_URL="https://github.com/feranick/gasket-driver/releases/download/${GASKET_DKMS_VERSION}/gasket-dkms_${GASKET_DKMS_VERSION}_all.deb"

# --- helpers -----------------------------------------------------------------

if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_MISS=$'\033[31m'; C_WARN=$'\033[33m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_MISS=""; C_WARN=""; C_OFF=""
fi

ok()   { echo "  ${C_OK}✓${C_OFF} $1"; }
miss() { echo "  ${C_MISS}✗${C_OFF} $1"; [[ -n "${2:-}" ]] && echo "      → $2"; }
warn() { echo "  ${C_WARN}!${C_OFF} $1"; }
head_() { echo; echo "$1"; }

need_root() {
    if [[ "$(id -u)" != "0" ]]; then
        echo "This command must run as root: sudo $0 $1" >&2
        exit 1
    fi
}

confirm() {
    read -r -p "$1 (y/n) " yn
    [[ "$yn" == [Yy]* ]]
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    fi
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
}

# --- check -------------------------------------------------------------------

cmd_check() {
    detect_os
    echo "camera.ui host check — ${OS_ID} ${OS_VERSION}, kernel $(uname -r), $(uname -m)"

    head_ "Docker"
    if command -v docker >/dev/null 2>&1; then
        ok "docker installed ($(docker --version 2>/dev/null | sed 's/,.*//'))"
    else
        miss "docker not installed" "https://docs.docker.com/engine/install/"
    fi

    head_ "NVIDIA (nvidia flavor)"
    if [[ -f /proc/driver/nvidia/version ]] || command -v nvidia-smi >/dev/null 2>&1; then
        ok "GPU driver loaded ($(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1 || echo 'nvidia-smi unavailable'))"
        if command -v nvidia-ctk >/dev/null 2>&1; then
            ok "container toolkit installed ($(nvidia-ctk --version 2>/dev/null | head -1))"
        else
            miss "container toolkit not installed" "run: sudo $0 nvidia"
        fi
        if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
            ok "nvidia runtime registered in docker"
        else
            miss "nvidia runtime not registered in docker" "run: sudo $0 nvidia"
        fi
    else
        miss "no NVIDIA GPU driver loaded (skip if you have no NVIDIA GPU)" \
             "install the driver first (e.g. 'sudo ubuntu-drivers install'), then: sudo $0 nvidia"
    fi

    head_ "Intel / AMD GPU (intel / amd flavor)"
    if [[ -d /dev/dri ]]; then
        ok "/dev/dri present ($(ls /dev/dri 2>/dev/null | tr '\n' ' '))"
    else
        miss "/dev/dri missing (skip if you have no Intel/AMD GPU)" \
             "iGPU disabled in BIOS, or no i915/amdgpu kernel driver"
    fi
    if [[ -e /dev/kfd ]]; then
        ok "/dev/kfd present (AMD ROCm compute available)"
    fi
    if [[ -d /dev/accel ]]; then
        ok "/dev/accel present (Intel NPU available)"
    fi

    head_ "Hailo-8 / Hailo-8L"
    if lsmod 2>/dev/null | grep -q '^hailo_pci'; then
        ok "hailo_pci kernel module loaded"
    elif lspci 2>/dev/null | grep -qi hailo; then
        miss "Hailo device on PCIe but hailo_pci module not loaded" "run: sudo $0 hailo"
    else
        echo "  - no Hailo device detected (skip if you have none)"
    fi
    if compgen -G '/dev/hailo*' >/dev/null; then
        ok "$(echo /dev/hailo*) present"
    elif lsmod 2>/dev/null | grep -q '^hailo_pci'; then
        miss "hailo_pci loaded but no /dev/hailo0" "reboot to load the firmware, check dmesg | grep -i hailo"
    fi

    head_ "Coral Edge TPU"
    if compgen -G '/dev/apex_*' >/dev/null; then
        ok "$(echo /dev/apex_*) present (PCIe/M.2 TPU ready)"
    elif lspci 2>/dev/null | grep -qi 'global unichip\|coral'; then
        miss "Coral on PCIe but no /dev/apex_0 (gasket driver missing)" "run: sudo $0 coral"
    fi
    if command -v lsusb >/dev/null 2>&1 && lsusb 2>/dev/null | grep -qE '1a6e:089a|18d1:9302'; then
        ok "Coral USB TPU detected (pass /dev/bus/usb to the container)"
    elif ! compgen -G '/dev/apex_*' >/dev/null && ! lspci 2>/dev/null | grep -qi 'global unichip\|coral'; then
        echo "  - no Coral device detected (skip if you have none)"
    fi

    echo
    echo "Next: pass the matching devices to the container (see the commented"
    echo "'devices:' section in docker-compose.yml) and verify the container's"
    echo "boot log line: '[setup] accelerator devices: ...'"
}

# --- nvidia: container toolkit -----------------------------------------------

cmd_nvidia() {
    need_root nvidia
    detect_os

    if [[ ! -f /proc/driver/nvidia/version ]] && ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "No NVIDIA GPU driver loaded. Install the driver first, e.g.:"
        echo "  sudo ubuntu-drivers install"
        echo "then reboot and re-run: sudo $0 nvidia"
        exit 1
    fi

    if [[ "${OS_ID}" != "ubuntu" && "${OS_ID}" != "debian" ]]; then
        echo "Unsupported distro '${OS_ID}' — follow NVIDIA's official guide instead:"
        echo "  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
        exit 1
    fi

    echo "This will add NVIDIA's apt repository and install the NVIDIA Container Toolkit."
    confirm "Continue?" || exit 1

    echo "==> adding NVIDIA container toolkit repository"
    apt-get update -q
    apt-get install -y --no-install-recommends curl gnupg ca-certificates
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    echo "==> installing nvidia-container-toolkit"
    apt-get update -q
    apt-get install -y nvidia-container-toolkit

    echo "==> registering the nvidia runtime with docker"
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    echo
    echo "Done. Verify with: $0 check"
    echo "Then start camera.ui with the nvidia overlay:"
    echo "  docker compose -f docker-compose.yml -f docker-compose.nvidia.yml up -d"
}

# --- hailo: PCIe kernel driver + firmware --------------------------------------

cmd_hailo() {
    need_root hailo
    detect_os

    if ! lspci 2>/dev/null | grep -qi hailo; then
        warn "no Hailo device visible on PCIe — installing anyway (device may be added later)."
    fi

    echo "This will build and install the Hailo PCIe kernel driver v${HAILO_VERSION}"
    echo "(kernel headers + build tools required) and download the firmware."
    confirm "Continue?" || exit 1

    echo "==> installing build dependencies"
    apt-get update -q
    apt-get install -y --no-install-recommends \
        build-essential git wget ca-certificates "linux-headers-$(uname -r)"

    workdir="$(mktemp -d)"
    trap 'rm -rf "${workdir}"' EXIT
    cd "${workdir}"

    echo "==> building hailort-drivers v${HAILO_VERSION}"
    git clone --depth 1 --branch "v${HAILO_VERSION}" https://github.com/hailo-ai/hailort-drivers.git
    cd hailort-drivers/linux/pcie
    make all
    make install

    if ! modprobe hailo_pci; then
        echo "Unable to load the hailo_pci module. Common causes:" >&2
        echo "  - Secure Boot rejects the unsigned module (disable or sign it)" >&2
        echo "  - kernel headers do not match the running kernel (reboot and retry)" >&2
        exit 1
    fi

    echo "==> installing firmware"
    cd ../..
    ./download_firmware.sh
    mkdir -p /lib/firmware/hailo
    mv hailo8_fw.*.bin /lib/firmware/hailo/hailo8_fw.bin

    echo "==> installing udev rules"
    cp ./linux/pcie/51-hailo-udev.rules /etc/udev/rules.d/
    udevadm control --reload-rules && udevadm trigger

    echo
    echo "Done — reboot to load the firmware, then verify with: $0 check"
    echo "Pass the device to the container in docker-compose.yml:"
    echo "  devices:"
    echo "    - /dev/hailo0:/dev/hailo0"
}

# --- coral: gasket/apex kernel driver (PCIe/M.2 only; USB Coral needs no driver) --

cmd_coral() {
    need_root coral
    detect_os

    if compgen -G '/dev/apex_*' >/dev/null; then
        echo "$(echo /dev/apex_*) already present — nothing to do."
        exit 0
    fi
    if ! lspci 2>/dev/null | grep -qi 'global unichip\|coral'; then
        warn "no PCIe Coral detected — installing anyway (USB Corals need no driver, only /dev/bus/usb passthrough)."
    fi

    echo "This will install DKMS and the gasket/apex kernel driver v${GASKET_DKMS_VERSION}"
    echo "(feranick's fork — Google's original package fails to build on kernels >= 6.13)."
    confirm "Continue?" || exit 1

    echo "==> installing build dependencies"
    apt-get update -q
    apt-get install -y --no-install-recommends \
        dkms wget ca-certificates "linux-headers-$(uname -r)"

    echo "==> installing gasket-dkms ${GASKET_DKMS_VERSION}"
    workdir="$(mktemp -d)"
    trap 'rm -rf "${workdir}"' EXIT
    wget -qO "${workdir}/gasket-dkms.deb" "${GASKET_DKMS_URL}"
    # On Secure Boot systems this walks through MOK enrollment (password + reboot).
    dpkg -i "${workdir}/gasket-dkms.deb"

    echo "==> loading modules + enabling autoload"
    modprobe gasket
    modprobe apex
    grep -qx gasket /etc/modules 2>/dev/null || echo gasket >> /etc/modules
    grep -qx apex   /etc/modules 2>/dev/null || echo apex   >> /etc/modules

    echo
    if compgen -G '/dev/apex_*' >/dev/null; then
        echo "Done — $(echo /dev/apex_*) is ready. Pass it to the container in docker-compose.yml:"
        echo "  devices:"
        echo "    - /dev/apex_0:/dev/apex_0"
    else
        echo "Modules loaded but no /dev/apex_0 yet — reboot and verify with: $0 check"
    fi
}

# --- main ----------------------------------------------------------------------

case "${1:-}" in
    check)  cmd_check ;;
    nvidia) cmd_nvidia ;;
    hailo)  cmd_hailo ;;
    coral)  cmd_coral ;;
    *)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
