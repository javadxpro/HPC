# Hamedis Performance Core — v1.11.0 release notes

**versionCode 11100** · POCO X3 Pro (vayu) / Xiaomi, Android 14+ (minimum Android 7), Magisk 24–31.x, KernelSU/APatch tolerated
Zip: `hamedis_performance_core_v1.11.0.zip` (Google Drive folder)

## What is new — Magisk v31 system integration + compatibility fix

Built on top of v1.10 (kernel management platform, unchanged).

### The Magisk update, explained (source-verified)

Magisk 31.x rewrote its core in Rust. For modules the layout is the
same (`/data/adb/magisk/busybox` still exists — it is a hard boot
requirement), but the busybox **applet** directory is no longer put on
the module script PATH, so module scripts now resolve utilities from
the system toybox. Two of our `pkill -f` lines were already dead on
Android (toybox has no pkill) and are now replaced by a portable
`/proc` cmdline scan. `toybox httpd` was checked and rejected as a
WebUI fallback (it is an inetd-only static file server: no CGI, no
listener).

### New features

1. **Magisk environment detection** (`scripts/magisk_sys.sh`)
   Version + version code via the official CLI (daemon-mediated),
   tmpfs path, Zygisk state (env or magisk.db), DenyList enforcement
   state, module count, and the httpd backend the WebUI can actually
   use — all registered as read-only capabilities and shown in the
   Capabilities tab.
2. **WebUI tab «مجیسک»** (tab 12)
   - Environment card: version, code, tmpfs, Zygisk, DenyList,
     module count, httpd backend, WebUI state
   - DenyList management: current entries + add/remove with strict
     Android package-name validation, executed through
     `magisk --denylist` (Magisk owns the database; HPC never touches
     it directly)
   - Module inventory table
   - **Module self-update**: push a new HPC zip to
     `/data/local/tmp`, enter the path, install via
     `magisk --install-module`. Only zips whose embedded
     `module.prop` declares `id=hamedis_performance_core` are
     accepted. Reboot required after install.
3. **CLI**: `hpc.sh magisk [info|modules|denylist|deny-add <pkg>|
   deny-rm <pkg>|update <zip>]`
4. **API**: `mgsk&value=info|modules|denylist|denyadd&pkg=|denyrmm&pkg=|update&zip=`
5. **Doctor**: two new checks — Magisk version detected, httpd
   backend available (FAIL if no busybox httpd can be found, which is
   exactly the symptom to report when the WebUI won't start).
6. **WebUI robustness**: `pkill -f` replaced by `web_kill_cmdline`
   (pure /proc scan) in webui.sh and uninstall.sh.

## Unchanged / preserved

- Everything from v1.10 (kernel platform, profiles, cleaner, speed
  booster, doctor, redacted reports, plugin system).
- Safety posture: thermal protection only observed, no voltage
  manipulation, loopback-only WebUI, typed validated writes, denylist
  changes through the official Magisk CLI only, self-update restricted
  to HPC zips in `/data/local/tmp`.

## Update instructions

Same as before: Magisk → Modules → install from storage (update over
v1.10.0), reboot. Runtime state in `/data/adb/hamedis` is preserved.

**After updating Magisk itself** (not this module): if `su` from
`adb shell` suddenly fails, grant the shell user in Magisk app →
Superuser tab first — v31.1 removed reactive superuser prompts
(app behaviour, unrelated to HPC).

## Verify on device

1. `sh /data/adb/modules/hamedis_performance_core/hpc.sh km doctor`
   — now includes `PASS magisk version …` and `PASS httpd backend …`
   lines. Send this output if anything looks off.
2. `hpc.sh magisk info` and the «مجیسک» WebUI tab.
3. DenyList: `hpc.sh magisk denylist` (read), and add/remove from the
   WebUI tab (validated).
4. Self-update (optional): `adb push <new.zip> /data/local/tmp/` then
   WebUI tab or `hpc.sh magisk update /data/local/tmp/<new.zip>`.

## Known limitations

- DenyList add/remove require the Magisk daemon to be running (always
  true after boot; during the first seconds of post-fs-data the CLI
  may not answer — state shows as "unknown", not as an error).
- The `--denylist exec` namespace isolation feature is intentionally
  not exposed (root-level namespace manipulation is outside HPC's
  scope).
- GPU write controls remain on-device-verification gated (see v1.10
  notes). Benchmarks remain directional userspace loops.
