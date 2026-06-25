#!/usr/bin/env bash
# =============================================================================
# Build (and optionally push) the camera.ui image flavors with buildx.
#
#   ./build.sh                 # build all flavors for the host arch, load locally
#   ./build.sh cpu intel       # build only these flavors
#   PUSH=1 ./build.sh          # build all flavors multi-arch and push
#   IMAGE=ghcr.io/you/camera.ui TAG=v1 PUSH=1 ./build.sh
#
# Env:
#   IMAGE      target repo            (default: ghcr.io/cameraui/camera.ui)
#   TAG        tag for the cpu flavor (default: latest)
#   PUSH       1 = multi-arch + push; otherwise single-arch + --load
#   PLATFORMS  override platforms (e.g. linux/amd64)
#   NVIDIA_BASE / NODE_VERSION / S6_OVERLAY_VERSION  base overrides
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${IMAGE:-ghcr.io/cameraui/camera.ui}"
TAG="${TAG:-latest}"
PUSH="${PUSH:-0}"
NVIDIA_BASE="${NVIDIA_BASE:-nvidia/cuda:12.6.2-cudnn-runtime-ubuntu24.04}"

# flavor -> base image
declare -A BASE=(
    [cpu]="ubuntu:24.04"
    [intel]="ubuntu:24.04"
    [nvidia]="${NVIDIA_BASE}"
    [amd]="ubuntu:24.04"
)
# flavor -> default multi-arch platforms (push only)
declare -A PLAT=(
    [cpu]="linux/amd64,linux/arm64"
    [intel]="linux/amd64"
    [nvidia]="linux/amd64"
    [amd]="linux/amd64"
)

flavors=("$@")
[ ${#flavors[@]} -eq 0 ] && flavors=(cpu intel nvidia amd)

builder=cameraui-builder
if ! docker buildx inspect "$builder" >/dev/null 2>&1; then
    docker buildx create --name "$builder" --driver docker-container --use >/dev/null
fi
docker buildx use "$builder"

extra_build_args=()
[ -n "${NODE_VERSION:-}" ]       && extra_build_args+=(--build-arg "NODE_VERSION=${NODE_VERSION}")
[ -n "${S6_OVERLAY_VERSION:-}" ] && extra_build_args+=(--build-arg "S6_OVERLAY_VERSION=${S6_OVERLAY_VERSION}")
[ -n "${KISAK_MESA:-}" ]         && extra_build_args+=(--build-arg "KISAK_MESA=${KISAK_MESA}")
[ -n "${INTEL_GPU_REPO:-}" ]     && extra_build_args+=(--build-arg "INTEL_GPU_REPO=${INTEL_GPU_REPO}")

if [ -n "${CAMERA_UI_VERSION:-}" ]; then
    extra_build_args+=(--build-arg "CAMERA_UI_VERSION=${CAMERA_UI_VERSION}")
else
    extra_build_args+=(--build-arg "CAMERAUI_CACHE_BUST=$(date +%s)")
fi

for flavor in "${flavors[@]}"; do
    base="${BASE[$flavor]:-}"
    [ -z "$base" ] && { echo "unknown flavor: $flavor" >&2; exit 1; }

    if [ "$flavor" = "cpu" ]; then
        tags=(-t "${IMAGE}:${TAG}" -t "${IMAGE}:cpu")
    else
        tags=(-t "${IMAGE}:${flavor}")
    fi

    platarg=()
    if [ "$PUSH" = "1" ]; then
        out=(--push)
        platforms="${PLATFORMS:-${PLAT[$flavor]}}"
        platarg=(--platform "$platforms")
    else
        out=(--load)   # local single-arch (buildx --load can't do multi-arch)
        [ -n "${PLATFORMS:-}" ] && platarg=(--platform "${PLATFORMS}")
    fi

    echo ""
    echo "==> ${IMAGE} [${flavor}]  base=${base}  push=${PUSH}"
    docker buildx build \
        "${platarg[@]}" \
        --build-arg "BASE_IMAGE=${base}" \
        --build-arg "FLAVOR=${flavor}" \
        "${extra_build_args[@]}" \
        "${tags[@]}" \
        "${out[@]}" \
        .
done

echo ""
echo "==> done: ${flavors[*]}"
