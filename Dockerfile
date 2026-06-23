# syntax=docker/dockerfile:1.7
# camera.ui — one Dockerfile, four flavors (build-args FLAVOR + BASE_IMAGE):
#   cpu     ubuntu:24.04                                    (amd64, arm64)
#   intel   ubuntu:24.04                                    (amd64)
#   nvidia  nvidia/cuda:12.6.2-cudnn-runtime-ubuntu24.04    (amd64)
#   amd     ubuntu:24.04                                    (amd64)

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG FLAVOR=cpu
ARG NODE_VERSION=24
ARG S6_OVERLAY_VERSION=3.2.1.0
ARG TARGETARCH

LABEL org.opencontainers.image.title="camera.ui" \
      org.opencontainers.image.description="camera.ui — self-hosted NVR / camera management (flavor: ${FLAVOR})" \
      org.opencontainers.image.authors="seydx" \
      org.opencontainers.image.source="https://github.com/cameraui/docker" \
      org.opencontainers.image.licenses="GPL-3.0"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    # --- camera.ui ---
    CAMERA_UI_HOME_PATH=/data \
    CAMERA_UI_RUNMODE=docker \
    CAMERAUI_DOCKER_AVAHI=true \
    DISABLE_OPENCOLLECTIVE=true \
    # avoid node preferring broken local IPv6 (npm registry, RTSP, etc.)
    NODE_OPTIONS=--dns-result-order=ipv4first \
    # --- s6-overlay ---
    S6_KEEP_ENV=1 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2

COPY scripts/ /opt/build/scripts/

# 1) base runtime (node, python, mDNS, ffmpeg/VA libs, s6)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    NODE_VERSION="${NODE_VERSION}" \
    S6_OVERLAY_VERSION="${S6_OVERLAY_VERSION}" \
    TARGETARCH="${TARGETARCH}" \
    bash /opt/build/scripts/install-base.sh

# 2) hwaccel layer per flavor (cpu = no-op). Toggles: KISAK_MESA=1, INTEL_GPU_REPO=0
ARG KISAK_MESA=
ARG INTEL_GPU_REPO=
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    KISAK_MESA="${KISAK_MESA}" \
    INTEL_GPU_REPO="${INTEL_GPU_REPO}" \
    bash "/opt/build/scripts/install-hwaccel-${FLAVOR}.sh"

# 3) launcher (public camera.ui3; installs @camera.ui/server at runtime).
ARG CAMERA_UI_VERSION=latest
RUN --mount=type=cache,target=/root/.npm \
    npm install -g --omit=dev "camera.ui3@${CAMERA_UI_VERSION}" \
    && node -v && npm -v

# 4) s6 services + avahi config
COPY rootfs/ /
RUN find /etc/s6-overlay/s6-rc.d -type f \( -name run -o -name up \) -exec chmod 0755 {} + \
    && chmod 0755 /etc/s6-overlay/scripts/*.sh \
    && rm -rf /opt/build

ENV FLAVOR=${FLAVOR}

# UI + go2rtc ports (informational; host networking recommended)
EXPOSE 3443/tcp 2000/tcp 2001/tcp 2002/tcp 2003/tcp 2004/tcp 2004/udp

# generous start-period — first boot installs the server
HEALTHCHECK --interval=30s --timeout=10s --start-period=240s --retries=5 \
    CMD curl -fsSk https://localhost:3443/api/health >/dev/null || exit 1

ENTRYPOINT ["/init"]
