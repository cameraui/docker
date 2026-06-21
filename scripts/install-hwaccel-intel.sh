#!/usr/bin/env bash
# intel flavor — VA-API / QSV / OpenCL / Vulkan.
set -euo pipefail
echo "==> hwaccel: intel"

# enable universe + multiverse (deb822)
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    sed -i 's/^Components: .*/Components: main restricted universe multiverse/' \
        /etc/apt/sources.list.d/ubuntu.sources
fi

# Intel's GPU repo ships a newer iHD/QSV driver than Ubuntu. Opt out: INTEL_GPU_REPO=0
if [ "${INTEL_GPU_REPO:-1}" != "0" ]; then
    curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key \
        | gpg --dearmor --yes -o /usr/share/keyrings/intel-graphics.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu noble unified" \
        > /etc/apt/sources.list.d/intel-graphics.list
fi

# newer Mesa for the latest GPUs (e.g. Arc), off by default. Enable: KISAK_MESA=1
if [ -n "${KISAK_MESA:-}" ]; then
    echo "==> intel: enabling kisak-mesa PPA"
    apt-get update
    apt-get install -y --no-install-recommends software-properties-common
    add-apt-repository -y ppa:kisak/kisak-mesa
fi

apt-get update

apt-get install -y --no-install-recommends \
    intel-media-va-driver-non-free \
    i965-va-driver \
    mesa-va-drivers \
    intel-opencl-icd \
    ocl-icd-libopencl1 \
    libvulkan1 \
    mesa-vulkan-drivers \
    vainfo clinfo vulkan-tools intel-gpu-tools

# oneVPL / MediaSDK — names vary across releases, best-effort
for pkg in libvpl2 libmfxgen1 libmfx1 libmfx-gen1.2; do
    apt-get install -y --no-install-recommends "$pkg" 2>/dev/null \
        && echo "   + ${pkg}" \
        || echo "   - ${pkg} (skipped, not available)"
done

rm -rf /tmp/* /var/tmp/*
echo "==> intel hwaccel done"
