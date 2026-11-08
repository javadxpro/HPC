# HPC V2Ray

VLESS client for Linux — GTK4 + PyGObject, wrapping the official signed
**V2Fly v2ray core (v5.53.0)**. Built for the Droidian phone (arm64),
runs on any GTK4 Linux.

## Features

- **Profiles**: add via pasted `vless://` links, multi-link subscriptions,
  select/delete, dedup by uuid+host+port
- **Transports** (v5 config format of core v5.53.0): `tcp`, `ws`, `kcp`,
  `h2`, `quic`, `grpc`, `hysteria2`; security `none`, `tls`, `reality`
  (pbk/sid/spx/fp), `xtls-rprx-vision` flow
- **Local mode**: SOCKS5 `127.0.0.1:10808` + HTTP `127.0.0.1:10809`
  (no root needed) — point any browser/app at them
- **System mode**: v2fly v5 **TUN service** (gvisor stack) for
  system-wide routing — needs root (the core must open `/dev/net/tun`).
  The app creates/uses interface `hpcv2ray` (10.0.0.2/24, default via
  10.0.0.1), restores your previous default route on stop, and never
  loops the proxy server address through the TUN
- **Routing**: `geoip:private` → direct always; `geosite:category-ir`
  → direct (toggle in Preferences); everything else → proxy
- Status banner (engine version, geo availability), running profile,
  uptime, ports; dark/light/auto theme
- Everything persisted in `~/.local/state/hpc-v2ray/`

## Install (Droidian / arm64)

```bash
wget -O hpc-v2ray.deb "https://raw.githubusercontent.com/javadxpro/HPC/arena/37022f35-hpc/apps/hpc-v2ray/hpc-v2ray_0.1.0_arm64.deb"
sudo dpkg -i hpc-v2ray.deb
```

## Run

```bash
hpc-v2ray            # Local mode (no root)
sudo hpc-v2ray       # enables System (TUN) mode
```

Add your `vless://...` link → **Start** → local ports come up.

## Build

```bash
git clone --depth 1 https://github.com/v2ray/dist /tmp/v2ray-dist   # core
DIST_DIR=/tmp/v2ray-dist ./build-deb.sh
```

The core + geo data inside the .deb are the **official signed** V2Fly
artifacts (sha256-verified against the signed `Release` file).

## Verified in CI-like sandbox (x86 core, same version)

- vless over tcp **and** ws: real traffic HTTP 200 through
  engine-generated client config (`curl --socks5`)
- 22/22 generated configs pass `v2ray test`
  (tcp,ws,grpc,kcp,h2,quic,hysteria2 × none,tls,reality × socks,tun)
- TUN: config (gvisor `services.tun`) validates; runtime needs a real
  TUN-capable machine (root) — kernel-side setup is automated in the app

## Notes / limits (honest)

- **`httpupgrade` links**: parsed fine, but the v5 config format of
  v5.53.0 does not include that transport (it exists in the binary only
  for the newer v6-format config). The app rejects them with a clear
  message — use tcp/ws/grpc/kcp/hysteria2 servers or a newer core.
- Traffic up/down live counters: not in v0.1 (access log on disk at
  `~/.local/state/hpc-v2ray/access.log`)
- Reality handshake needs your real server reachable — config
  generation is validated; reachability is yours to test
