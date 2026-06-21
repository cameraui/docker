# camera.ui — Docker

Docker images for [camera.ui](https://github.com/cameraui/camera.ui), one per hardware target, on Ubuntu 24.04.

## Quick start

```bash
docker compose up -d
# then open https://<host>:3443   (self-signed cert on first start)
```

First boot installs the server and comes up after a few minutes — follow it with `docker compose logs -f`.

## Image flavors

| Flavor | Tag      | Hardware acceleration        | Arch          |
| ------ | -------- | ---------------------------- | ------------- |
| CPU    | `latest` | software                     | amd64 + arm64 |
| Intel  | `intel`  | Quick Sync / VA-API + OpenCL | amd64         |
| NVIDIA | `nvidia` | NVENC / NVDEC + CUDA         | amd64         |
| AMD    | `amd`    | Mesa VA-API + OpenCL         | amd64         |

Pick the flavor for your machine via its compose override (`docker-compose.{intel,nvidia,amd}.yml`).

## Networking

Host networking (the compose default) is recommended — camera.ui uses it for mDNS/Bonjour (HomeKit pairing, ONVIF discovery) and WebRTC live view.

## Data

All state lives in the `/data` volume (config, database, recordings, TLS certs). Back up the `cameraui-data` volume.

## Proxmox

See [`proxmox/`](./proxmox) to run camera.ui in a Proxmox LXC.

## Ports

| Port | Proto   | Purpose        |
| ---- | ------- | -------------- |
| 3443 | tcp     | HTTPS UI / API |
| 2000 | tcp     | go2rtc         |
| 2001 | tcp     | RTSP           |
| 2002 | tcp     | SRTP           |
| 2003 | tcp     | RTMP           |
| 2004 | tcp/udp | WebRTC         |
