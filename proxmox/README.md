# camera.ui on Proxmox VE

Two ways to run camera.ui on Proxmox VE.

## Docker inside an LXC (recommended — reuses this image)

Run the helper **on the Proxmox host**:

```bash
bash install-cameraui-lxc.sh
```

It creates an Ubuntu 24.04 container, installs Docker + Compose, drops in the camera.ui compose file and starts it. Optional env tunables at the top of the script: `CTID`, `HOSTNAME`, `CORES`, `RAM_MB`, `DISK_GB`, `BRIDGE`, `STORAGE`, `FLAVOR`.

- The container is **privileged** so it can pass through `/dev/dri` (hardware transcode) and nest Docker. Make it unprivileged if you don't need GPU — see the script comments.
- mDNS/avahi and WebRTC need the LXC on a **bridged** network (default `vmbr0`), not NAT.

## Bare-metal inside an LXC (no Docker)

In a plain Ubuntu 24.04 LXC:

```bash
apt-get update && apt-get install -y curl
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs python3 python3-venv python3-pip
npm install -g camera.ui
cameraui install --user cameraui
```

Installs a `cameraui.service` like any Linux host install; the launcher handles updates. Lighter than Docker-in-LXC.

---

Both paths store data under the home path's `volume` directory (`/data/volume` in Docker, `~cameraui/.camera.ui/volume` bare-metal).
