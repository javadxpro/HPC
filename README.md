# Hamedis Performance Core (HPC)

Adaptive performance + kernel manager + cleaner & speed booster as a
Magisk module for Android.
Auto-detects CPU/GPU/thermal/battery interfaces, never disables thermal
protection, never pins clocks, fully reversible.

- **Version:** v1.9.0 (versionCode 10900)
- **WebUI:** `http://127.0.0.1:1111` — loopback only, started by the
  Magisk **Action** button (`action.sh`) or at boot (`WEBUI_AUTOSTART=1`)
- **CLI:** `sh /data/adb/modules/hamedis_performance_core/hpc.sh [command]`

## What it does

- **Profiles** — `cool`, `balanced`, `performance`, `gaming90`,
  `gaming120`. Each is a set of percentage-based hints
  (CPU/GPU frequency window, governor preference, scheduler latency, VM
  tuning, thermal thresholds) translated into verified sysfs writes.
- **Game detection** — cheap `/proc` scan (no `dumpsys`) for configured
  packages; switches to the gaming profile while the game runs and
  restores the previous profile on exit.
- **Thermal management** — gradual step ladder (100/90/78/65%) that only
  ever *lowers* the ceiling HPC itself set, with hysteresis to prevent
  flapping. The kernel's thermal governor remains the authority.
- **Battery awareness** — downgrades the profile at low charge and limits
  performance when the battery itself runs hot.
- **Kernel manager** — I/O scheduler, TCP congestion control, zRAM
  reporting, read-only battery health / charge-rate reporting.
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
cool|balanced|...  switch profile
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
