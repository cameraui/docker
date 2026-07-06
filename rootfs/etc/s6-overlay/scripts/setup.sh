#!/bin/bash
set -u

# disable core dumps
ulimit -c 0 || true

if command -v sysctl >/dev/null 2>&1; then
    sysctl -w net.core.rmem_default=5242880 >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_max=5242880     >/dev/null 2>&1 || true
fi

# Log which accelerator device nodes are visible inside the container — the
# container-side half of the hw diagnosis (host side: scripts/host/cameraui-host.sh check).
# A device missing here means it was not passed through via compose `devices:`.
hw=""
for dev in /dev/dri /dev/kfd /dev/accel /dev/apex_0 /dev/hailo0 /dev/bus/usb; do
    if [[ -e "$dev" ]]; then hw+=" ${dev} ✓ ·"; else hw+=" ${dev} ✗ ·"; fi
done
if [[ -e /dev/nvidiactl ]] || command -v nvidia-smi >/dev/null 2>&1; then
    hw+=" nvidia ✓"
else
    hw+=" nvidia ✗"
fi
echo "[setup] accelerator devices:${hw}"

if [[ "${CAMERAUI_DOCKER_AVAHI}" != "true" ]]; then
    echo "[setup] CAMERAUI_DOCKER_AVAHI != true — not managing dbus/avahi"
    exit 0
fi

if grep -qE " ((/var)?/run/dbus|(/var)?/run/avahi-daemon(/socket)?) " /proc/mounts; then
    echo "[setup] host dbus/avahi sockets are bind-mounted — leaving them alone"
    exit 0
fi

mkdir -p /var/run/dbus /var/run/avahi-daemon

rm -f /var/run/dbus.pid /var/run/dbus/pid /run/dbus/pid \
      /var/run/avahi-daemon/pid /var/run/dbus/system_bus_socket 2>/dev/null || true

chown messagebus:messagebus /var/run/dbus       2>/dev/null || true
chown avahi:avahi          /var/run/avahi-daemon 2>/dev/null || true
dbus-uuidgen --ensure

sed -i 's/.*host-name.*/#host-name=/' /etc/avahi/avahi-daemon.conf 2>/dev/null || true

echo "[setup] done"
exit 0
