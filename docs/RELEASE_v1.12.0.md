# Hamedis Performance Core — v1.12.0 release notes

**versionCode 11200** · feature release — the curated 7-profile set + graphics renderer control

## Profile set (exactly these seven, nothing else)

| Profile | What it does |
|---|---|
| **overclock** (new) | Everything at the **stock hardware limit**: CPU floor = ceiling = max on every policy, GPU performance governor at max with clocks forced, tightest scheduler latency, Vulkan, 20 s thermal polling |
| **gaming120** | High-refresh gaming (unchanged) |
| **gaming90** | 90 Hz gaming (unchanged) |
| **performance** | Sustained responsiveness (unchanged) |
| **balanced** | Default (unchanged) |
| **battery_saver** | Maximum battery life (unchanged) |
| **longevity** | **For damaged or degrading hardware** — low clocks, charge-limit 80%, low battery-temp ceiling (this is the "موبایل آسیب دیده" profile) |

Removed: `cool`, `silent`, `multitasking`, `standby`.

### Honest scope of "overclock"
The stock 4.14 kernel's frequency table is fixed at factory time — there is
**no sysfs knob above it**, and HPC will not try to exceed it (that's how
phones get bricked). `overclock` = the maximum the stock hardware allows:
pinned to the top step. The **kernel's thermal governor still has final
authority** and will throttle under sustained load — expect that; it is a
safety feature. HPC's own ease-off ladder (68/76/82 C) fires before the
kernel has to slam. GPU kernel throttling stays forced ON. Use it like a
turbo button, not all day.

### What changed under the hood
- **Seeded-copy bookkeeping**: built-in profiles are copied to
  `/data/adb/hamedis/profiles` with a SHA-1 manifest. On update, a seeded
  copy of a profile that no longer ships is removed — but **only if the
  user never edited it** (a modified copy is treated as a user profile and
  kept). So your old `cool` etc. disappear from the WebUI on the first
  boot of v1.12.0, and user-created profiles are never touched.
- **Low-battery protection** now forces `battery_saver` (was `cool`).
- CLI dispatch, API profile whitelist, WebUI labels (اورکلاک (تا ته) /
  گیمینگ ۱۲ / گیمینگ ۹۰ / عملکرد / متعادل / ذخیره باتری / موبایل
  آسیب دیده) all follow the new set.

## Graphics renderer control (new)

The HWUI renderer (the thing behind Developer Options → "Set GPU
Renderer") is now a first-class control:

- **WebUI**: تنظیم دستی → «رندرر گرافیکی (HWUI)» — current state,
  Vulkan driver presence, and buttons for **Vulkan / OpenGL (Skia) /
  Legacy OpenGL / حالت پیش‌فرض**.
- **CLI**: `hpc.sh renderer [vulkan|gles|legacy|default]`
- **API**: `action=renderer` (report) / `action=renderer&value=<mode>`
- Same safety machinery as every HPC write: the original value is backed
  up before the first change and **restored on uninstall**
  (`gfx_restore_props`).
- `default` restores the device's pre-HPC value (or deletes the property
  so the ROM default applies).
- HPC reports the truth about this knob: HWUI reads the property when an
  **app process starts**, so the change affects apps launched afterwards.
  The UI says so. HPC does **not** force-stop your apps on its behalf.

## Tests

8 suites / 262 checks, all green, including:
- curated-set assertions (the 7 present, the 4 removed absent)
- overclock content (floor=100, GPU throttling still ON)
- seed-cleanup: untouched stale seed removed, user-modified stale copy
  kept
- renderer: report shape, bad-mode rejection, gles/legacy/default
  apply (against a `resetprop` stub that records the writes), Vulkan
  refused without a driver, applied with one

## Install

Uninstall + install, or install over v1.11.x (safe — no state format
break; the stale-profile cleanup runs automatically on first boot).
