# Hamedis Performance Core — v1.10.0 release notes

**versionCode 11000** · POCO X3 Pro (vayu) / Xiaomi, Android 11+, Magisk 24+
Zip: `hamedis_performance_core_v1.10.0.zip` (Google Drive folder, 160,570 B)

## What is new — comprehensive kernel management platform

Built incrementally on top of v1.9.0 (cleaner + speed booster unchanged).
Everything is capability-discovery driven: the platform scans the real
kernel interfaces at boot and only exposes what the kernel actually
exposes — read vs writable, valid values straight from the kernel's own
lists, hardware frequency limits. Nothing is hardcoded per device in the
core (device-specific knowledge goes in `plugins/` adapters).

New subsystems (all behind the existing `safe_write` backup/verify layer):

1. **Capability discovery + registry** (`km_discover.sh`, `km_registry.sh`)
   49+ capabilities on the vayu fixture: CPU governor/speeds, I/O
   scheduler, TCP CC, zRAM, thermal zones + their limits, GPU pwrlevels/
   clocks, battery charge-control candidates (enabled only when a verified
   interface is discovered), net queues, disk writeback, loaded modules,
   kernel-log filters. Registry refreshes at most every 60 s.
2. **Transactional changes** (`km_control.sh`)
   `km tx` / `kmctl` write multiple capabilities atomically: backup →
   write → verify → commit; any failed step rolls the whole transaction
   back automatically. Every change is recorded with value, source
   (web/cli/service/plugin) and tx id → `km history`, `km rollback [tx]`.
3. **Read-only monitor** (`km_monitor.sh`) — 14 JSON endpoints:
   status, cpu, gpu, mem, thermal, battery, net, disk, sched, procs,
   modules, klog (filtered), health, caps.
4. **Audit events** (`km_events.sh`) — change/rollback/error/thermal/
   boot/scan/profile events, queryable from WebUI + CLI.
5. **Micro-benchmarks** (`km_bench.sh`) — integer, memory bandwidth,
   copy, clock jitter, synthetic IO + A/B comparison. Directional only
   (userspace loops, stated as such in the UI).
6. **Diagnostics + advisor** (`km_diag.sh`) — redacted diagnostic report
   (addresses/paths/pids/UUIDs redacted before any export) and a local
   rule-based advisor that labels every statement *observed* vs
   *inferred*. Remote AI endpoint exists but is **off by default**
   (`HPC_AI_ENDPOINT`); redaction applies to anything that would leave
   the device.
7. **Profiles v2** (`km_profiles.sh`) — compare / export / duplicate /
   delete / import (base64), plus 4 new profiles: `battery_saver`,
   `silent`, `multitasking`, `standby`. Profiles are still validated
   against the live capability registry before applying — never applied
   blindly.
8. **Plugin system** (`plugin_loader.sh`, `plugins/adapter_xiaomi_vayu.sh`)
   — device adapters can register extra capabilities and advise rules.
9. **WebUI** — 7 new JSON endpoints (`km`, `kmctl`, `kmrollback`,
   `kmprof`, `kmbench`, `kmadvise`, `kmreport`) and 8 new RTL Persian
   tabs: Kernel overview, Capabilities, Changes & rollback, Events,
   Benchmarks, Advisor, Diagnostics + profile management inside the
   profiles tab.
10. **CLI** — `hpc.sh km {scan|ls|show|set|tx|rollback|history|events|
    status|health|caps|bench|advise|diagnose|report}`.

## Unchanged / preserved

- Cleaner + speed booster + session monitor + all v1.9.0 endpoints.
- All existing WebUI tabs, profile set (original 6), config format.
- Safety posture: thermal protection is only ever *observed* (never
  disabled), no voltage manipulation, no clock pinning, loopback-only
  WebUI, whitelisted inputs, typed validated writes only.

## Update instructions

1. Download the new zip from the Drive folder.
2. Magisk → Modules → install from storage (update over v1.9.0).
   Runtime state, your profile copies, logs and `config.conf` live in
   `/data/adb/hamedis` and survive the update.
3. Reboot.
4. First boot triggers a capability scan (~1 s); force a rescan any time:
   `hpc.sh km scan`.

## Verify on device

1. **First:** `sh /data/adb/modules/hamedis_performance_core/hpc.sh km doctor`
   (or the "خودآزمایی" button on the WebUI Diagnostics tab).
   It re-checks the capability registry, all 14 monitor JSON
   endpoints, the audit trail, WebUI assets, and performs one guarded
   no-op write+readback on a writable capability — without changing
   anything. If anything is off, the text of this output is all we
   need to help.
2. `hpc.sh km ls` — capability table with states
   (`writable` / `read_only` / `absent` / `inaccessible`).
3. WebUI: Kernel tab shows live status + health.
4. `hpc.sh km set cpu0.governor performance` then
   `hpc.sh km rollback` — write + revert through the transaction layer.
5. `hpc.sh km report` — redacted diagnostic report in
   `/data/local/tmp/hpc_exports` (the WebUI Diagnostics tab shows the
   same data live).

## Known limitations (honest)

- GPU write controls: the write paths exist but are inert until a real
  device confirms the GPU sysfs responds — discovery gates them.
- Battery charge limiting: only enabled if a verified interface is
  discovered; otherwise the feature is hidden.
- Advisor is a local rule engine; the remote AI endpoint is disabled by
  default and would only ever send redacted data.
- Benchmarks are userspace directional loops, not a full kernel bench.

Full architecture: `docs/kernel_platform.md`.
