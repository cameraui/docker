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

# --- legacy OpenCL runtime for Gen8-Gen11 iGPUs (Broadwell..Comet Lake) -------
# NEO >= 24.39 dropped pre-Xe GPUs, so the intel-opencl-icd above (25.x) exposes
# no OpenCL device on e.g. a UHD 630 and OpenVINO silently falls back to CPU.
# Intel ships co-installable legacy1 builds only as GitHub debs (no apt package
# for noble). The 24.35 legacy branch also contains the kernel >= 6.8 fix
# without which Gen9 devices disappear from OpenCL on current Proxmox/Ubuntu
# kernels. Both ICDs register with the loader; each claims only its platforms.
if [ "$(uname -m)" = "x86_64" ]; then
    echo "==> intel: legacy OpenCL runtime (Gen8-Gen11, e.g. UHD 6xx)"
    NEO_LEGACY_VERSION=24.35.30872.36
    LZ_LEGACY_VERSION=1.5.30872.36
    IGC_LEGACY_VERSION=1.0.17537.24

    mkdir -p /tmp/neo-legacy && cd /tmp/neo-legacy
    curl -fsSLO "https://github.com/intel/compute-runtime/releases/download/${NEO_LEGACY_VERSION}/intel-opencl-icd-legacy1_${NEO_LEGACY_VERSION}_amd64.deb"
    curl -fsSLO "https://github.com/intel/compute-runtime/releases/download/${NEO_LEGACY_VERSION}/intel-level-zero-gpu-legacy1_${LZ_LEGACY_VERSION}_amd64.deb"
    curl -fsSLO "https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC_LEGACY_VERSION}/intel-igc-core_${IGC_LEGACY_VERSION}_amd64.deb"
    curl -fsSLO "https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC_LEGACY_VERSION}/intel-igc-opencl_${IGC_LEGACY_VERSION}_amd64.deb"
    apt-get install -y --no-install-recommends ./*.deb
    cd / && rm -rf /tmp/neo-legacy
fi

# --- Intel NPU (Core Ultra) user-space driver ---------------------------------
# OpenVINO's NPU plugin dlopens libze_loader -> libze_intel_vpu; neither ships
# with the openvino pip wheel, so they must live in the image. The kernel driver
# (intel_vpu) + firmware stay on the host — pass /dev/accel at runtime.
if [ "$(uname -m)" = "x86_64" ]; then
    echo "==> intel: NPU user-space driver (Level Zero + UMD)"
    LEVEL_ZERO_VERSION=1.24.2
    NPU_VERSION=1.23.0
    NPU_VERSION_DATE=20250827-17270089246

    mkdir -p /tmp/npu && cd /tmp/npu
    curl -fsSLO "https://github.com/oneapi-src/level-zero/releases/download/v${LEVEL_ZERO_VERSION}/level-zero_${LEVEL_ZERO_VERSION}+u24.04_amd64.deb"
    curl -fsSLO "https://github.com/intel/linux-npu-driver/releases/download/v${NPU_VERSION}/linux-npu-driver-v${NPU_VERSION}.${NPU_VERSION_DATE}-ubuntu2404.tar.gz"
    tar xzf "linux-npu-driver-v${NPU_VERSION}.${NPU_VERSION_DATE}-ubuntu2404.tar.gz"
    rm -f ./*fw-npu*.deb "linux-npu-driver-v${NPU_VERSION}.${NPU_VERSION_DATE}-ubuntu2404.tar.gz" # firmware is host-only
    apt-get install -y --no-install-recommends libtbb12 ./*.deb
    cd / && rm -rf /tmp/npu
fi

rm -rf /tmp/* /var/tmp/*
echo "==> intel hwaccel done"
