#!/usr/bin/env bash
# amd flavor — Mesa VA-API + OpenCL + Vulkan. ROCm is not bundled (multi-GB);
# pass /dev/dri (and /dev/kfd for ROCm) at runtime.
set -euo pipefail
echo "==> hwaccel: amd"

if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    sed -i 's/^Components: .*/Components: main restricted universe multiverse/' \
        /etc/apt/sources.list.d/ubuntu.sources
fi

# newer Mesa (radv/VA-API), off by default. Enable: KISAK_MESA=1
if [ -n "${KISAK_MESA:-}" ]; then
    echo "==> amd: enabling kisak-mesa PPA"
    apt-get update
    apt-get install -y --no-install-recommends software-properties-common
    add-apt-repository -y ppa:kisak/kisak-mesa
fi

apt-get update
apt-get install -y --no-install-recommends \
    mesa-va-drivers \
    mesa-opencl-icd \
    ocl-icd-libopencl1 \
    libvulkan1 \
    mesa-vulkan-drivers \
    libdrm2 libdrm-amdgpu1 \
    vainfo clinfo vulkan-tools

rm -rf /tmp/* /var/tmp/*
echo "==> amd hwaccel done"
