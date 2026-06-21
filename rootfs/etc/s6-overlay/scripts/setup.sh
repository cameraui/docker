#!/bin/bash
set -u

# disable core dumps
ulimit -c 0 || true

if command -v sysctl >/dev/null 2>&1; then
    sysctl -w net.core.rmem_default=5242880 >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_max=5242880     >/dev/null 2>&1 || true
fi

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
