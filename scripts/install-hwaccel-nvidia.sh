#!/usr/bin/env bash
# nvidia flavor — CUDA runtime comes from the base image; the NVENC/NVDEC driver
# libs are injected at runtime by the host's NVIDIA Container Toolkit.
set -euo pipefail
echo "==> hwaccel: nvidia"

apt-get update
apt-get install -y --no-install-recommends vainfo clinfo || true

rm -rf /tmp/* /var/tmp/*
echo "==> nvidia hwaccel done"
