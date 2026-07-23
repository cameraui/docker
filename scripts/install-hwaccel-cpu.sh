#!/usr/bin/env bash
# cpu flavor — software transcoding, no vendor GPU stack.
set -euo pipefail
echo "==> hwaccel: cpu"

apt-get update
apt-get install -y --no-install-recommends \
    libvulkan1 \
    mesa-vulkan-drivers

rm -rf /tmp/* /var/tmp/*
echo "==> cpu hwaccel done"
