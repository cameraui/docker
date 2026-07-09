# camera.ui on Proxmox VE

Two ways to run camera.ui on Proxmox VE. Full guide: [docs.cameraui.com/install/proxmox](https://docs.cameraui.com/install/proxmox)

## Docker inside an LXC (recommended — reuses this image)

Run the helper **on the Proxmox host**:

```bash
bash install-cameraui-lxc.sh
```

It downloads an Ubuntu 24.04 template, creates an **unprivileged** container with nesting (required for Docker; on current Proxmox releases a privileged LXC can no longer load Docker's AppArmor profile), installs Docker + Compose inside it, drops in the camera.ui compose file and starts it.

Env tunables (see the script header):

| Variable | Default | Meaning |
|---|---|---|
| `CTID` | next free ID | container ID |
| `CT_HOSTNAME` | `cameraui` | container hostname |
| `CORES` / `RAM_MB` / `DISK_GB` | `4` / `4096` / `16` | container resources |
| `BRIDGE` | `vmbr0` | network bridge (IP via DHCP) |
| `STORAGE` | auto-detect | rootfs storage (first active storage that can hold a container rootfs) |
| `TEMPLATE_STORAGE` | `local` | where the LXC template is stored |
| `FLAVOR` | `cpu` | `cpu`, `intel` or `amd` — picks the image flavor |
| `IMAGE` | `ghcr.io/cameraui/camera.ui` | image repo |
| `GPU_PASSTHROUGH` | `1` when flavor ≠ cpu | pass `/dev/dri` into the container |
| `TZ` | host timezone | container timezone |

- GPU passthrough (`/dev/dri`, Intel/AMD VA-API) works in the unprivileged container via Proxmox device passthrough — no privileged mode needed.
- For **NVIDIA** use a VM with PCIe passthrough instead of an LXC (the script rejects `FLAVOR=nvidia`).
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
