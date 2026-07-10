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
| `FLAVOR` | `cpu` | `cpu`, `intel`, `amd` or `nvidia` (experimental) — picks the image flavor |
| `IMAGE` | `ghcr.io/cameraui/camera.ui` | image repo |
| `GPU_PASSTHROUGH` | `1` when flavor ≠ cpu | pass `/dev/dri` into the container |
| `TZ` | host timezone | container timezone |

- GPU passthrough (`/dev/dri`, Intel/AMD VA-API) works in the unprivileged container via Proxmox device passthrough — no privileged mode needed.
- **NVIDIA in an LXC is experimental** (`FLAVOR=nvidia`): requires a working host driver (`.run --dkms` + `pve-headers`, `nvidia-smi` must work). The script passes the `/dev/nvidia*` nodes through, installs the matching user-space driver + NVIDIA Container Toolkit (`no-cgroups=true`) inside the container, and adds a boot-time sync service that re-installs the matching user space after host driver updates. The recommended path is still a VM with PCIe passthrough — see the [docs](https://docs.cameraui.com/install/proxmox). Reports and PRs welcome.
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
