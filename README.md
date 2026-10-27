# Hamedis Performance Core (HPC)

Adaptive performance + kernel manager + cleaner & speed booster as a
Magisk module for Android.
Auto-detects CPU/GPU/thermal/battery interfaces, never disables thermal
protection, never pins clocks, fully reversible.

- **Version:** v1.12.0 (versionCode 11200)
- **WebUI:** `http://127.0.0.1:1111` — loopback only, started by the
  Magisk **Action** button (`action.sh`) or at boot (`WEBUI_AUTOSTART=1`)
- **CLI:** `sh /data/adb/modules/hamedis_performance_core/hpc.sh [command]`

## What it does

- **Profiles** — a curated set of seven (v1.12.0): `overclock`
  (everything at the stock hardware limit), `gaming120`, `gaming90`,
  `performance`, `balanced`, `battery_saver`, `longevity` (for damaged
  or degrading hardware). Each is a set of percentage-based hints
  (CPU/GPU frequency window, governor preference, scheduler latency, VM
  tuning, thermal thresholds) translated into verified sysfs writes.
  `overclock` never exceeds the kernel's stock frequency table and
  thermal protection is never disabled, in any profile.
- **Graphics renderer (v1.12.0)** — switch the HWUI backend
  (Vulkan / OpenGL-Skia / legacy) from the WebUI or
  `hpc.sh renderer`, with the original value backed up and restored on
  uninstall. Applies to apps launched after the change.
- **Game detection** — cheap `/proc` scan (no `dumpsys`) for configured
  packages; switches to the gaming profile while the game runs and
  restores the previous profile on exit.
- **Thermal management** — gradual step ladder (100/90/78/65%) that only
  ever *lowers* the ceiling HPC itself set, with hysteresis to prevent
  flapping. The kernel's thermal governor remains the authority.
- **Battery awareness** — downgrades the profile at low charge and limits
  performance when the battery itself runs hot.
- **Kernel manager (v1.10/v1.11 platform)** — discovery-driven
  capability registry (what this kernel exposes, read vs writable),
  validated typed writes with kernel-list enums and hw frequency
  limits, transactions with automatic partial-failure rollback,
  audited change log + `km rollback`, read-only health/bench/report/
  diag with redacted exports, a local rule-based assistant (observed
  vs inferred, AI backend off by default), an on-device self-check
  (`km doctor`), and a plugin system for device adapters.
  Full details in `docs/kernel_platform.md`.
- **Magisk system integration (v1.11)** — detects the new Magisk
  (v31+, Rust core) environment: version/version-code via the official
  CLI, tmpfs path, Zygisk state, DenyList status + add/remove through
  `magisk --denylist` (strict package-name validation), module
  inventory, and the httpd backend actually available to the WebUI.
  WebUI tab «مجیسک» + `hpc.sh magisk …`. Module self-update from
  `/data/local/tmp` via `magisk --install-module` (HPC zips only).
- **Cleaner** — root cleanup of regenerable system junk (tmp files, ANR /
  tombstone reports, cache partition, thumbnail caches, ART cache in deep
  mode). The target list is hardcoded in `cleaner.sh`; user data is never
  touched. One-tap RAM housekeeping (logcat clear + drop clean page
  caches).
- **Speed booster** — one-tap speed mode: performance profile (via the
  profile engine, so the service keeps authority) + I/O scheduler
  `none` for UFS + VM speed values (swappiness/cache pressure) +
  system animation scales off + MIUI "memory extension" off (probed,
  best-effort). Fully reversible: "speed off" restores every original
  value and the baseline profile.
- **Session monitor** — opt-in CSV recording of gaming sessions with
  report and side-by-side comparison, so tuning is judged on data.
- **WebUI** — Persian (RTL) PWA served by busybox httpd on 127.0.0.1,
  JSON API where every endpoint is a thin, whitelisted wrapper over the
  same functions the CLI uses.

## Safety guarantees

- Every sysfs write goes through `safe_write()`: existence check,
  writability check, one-time backup of the original value, write, verify.
- `uninstall.sh` restores every backed-up value, releases any charge hold,
  and keeps the user's config and logs.
- The WebUI is bound to loopback only (bind + access-control list) and
  validates/whitelists every input; profile names and tunable keys are
  checked against fixed lists.
- HPC never limits charging current or caps the charge level: a healthy
  cell charges at the vendor default, and SoC thermal management (which
  the kernel keeps as the final authority) is what protects the hardware.

## Repository layout

```
module.prop            module metadata (id, name, version)
post-fs-data.sh        early boot: creates /data/adb/hamedis, clears stale state
service.sh             background service: poll loop (game, thermal, charge)
action.sh              Magisk Action button: starts the WebUI
hpc.sh                 full CLI (status, profiles, limit, monitor, ...)
uninstall.sh           restores every value the module changed
system.prop            conservative overlay properties (resetprop)
config/config.conf     default main config (seeded to /data/adb/hamedis)
config/profiles/       default profiles (seeded, user-editable copies)
plugins/               device adapters (e.g. adapter_xiaomi_vayu.sh)
tests/                 shell test suites (fake sysfs, no root needed)
docs/                  architecture notes (kernel_platform.md)
scripts/               shell libraries: detection, profiles, thermal,
                       battery, RAM, graphics, kernel, safety, monitor,
                       game detection, logger, WebUI control
webroot/               WebUI: index.html (PWA), cgi-bin/api.sh (JSON API),
                       httpd.conf, service worker, icons
```

Runtime state, logs, the live `config.conf` and user copies of the
profiles live under `/data/adb/hamedis` (survives module updates).

## CLI quick reference

```
status             show current state (default)
overclock|gaming120|gaming90|performance|balanced|battery_saver|longevity
                   switch profile
renderer [mode]    show/set graphics renderer (vulkan|gles|legacy|default)
game|stop-game     force/leave gaming profile
kernel             kernel tunables and battery health
webui|webstop      start/stop the web interface
monitor [min]      start recording a gaming session (default 20 min)
report [NAME]      summarise a session
sessions|save|compare   list / save / compare sessions
reload|reset       re-apply config / restore all original values
log [N]            show recent log lines
caps               detected hardware capabilities
```

## Building the module zip

The repository root *is* the module. To package it:

```sh
zip -r hamedis_performance_core.zip . -x '.git/*'
```
