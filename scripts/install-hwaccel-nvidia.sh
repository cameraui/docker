#!/usr/bin/env bash
# nvidia flavor — CUDA runtime comes from the base image; the NVENC/NVDEC driver
# libs, plus the NVIDIA OpenCL/Vulkan ICDs, are injected at runtime by the host's
# NVIDIA Container Toolkit (needs NVIDIA_DRIVER_CAPABILITIES incl. compute,graphics).
set -euo pipefail
echo "==> hwaccel: nvidia"

apt-get update

apt-get install -y --no-install-recommends \
    ocl-icd-libopencl1 \
    libvulkan1 \
    mesa-vulkan-drivers \
    vainfo clinfo vulkan-tools || true

rm -rf /tmp/* /var/tmp/*
echo "==> nvidia hwaccel done"
