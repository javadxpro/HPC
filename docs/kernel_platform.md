# Kernel Management Platform — v1.10 architecture

This document describes the kernel management layer added in v1.10.
It is written to be honest about what is measured, what is inferred,
and what is not yet implemented.

## Design principles

1. **Capability-driven, never assumption-driven.** The core discovers
   what the running kernel actually exposes (policies, governors, GPU
   nodes, block devices, thermal zones, battery supplies) and records
   each capability with its access rights (`r` / `rw` / absent). No
   device-specific path is hardcoded in the core; device quirks live in
   plugins (`plugins/adapter_*.sh`).
2. **Typed, validated values only.** Every write goes through
   `km_ctl_validate`, which checks against *this* kernel's own lists
   (available governors, hw frequency limits, numeric ranges) and
   rejects shell metacharacters outright.
3. **Transactional, reversible, audited.** Multi-setting changes are
   transactions: validate everything first, apply, and roll back the
   already-applied part if any write fails. Every attempt — success,
   failure, rejection, protection hit — is recorded in
   `state/change_log.tsv`, and `km_rollback` restores from it.
4. **Thermal protection is never touched.** Thermal zone mode,
   thresholds, and the GPU throttling/force-clock bypass knobs are on
   the protected-path list inside the engine itself (`km_protected`);
   a write through the engine to these paths is refused and logged.
   The kernel's thermal governor remains the authority.
5. **No voltage, no clock pinning, no arbitrary root commands.** The
   engine only writes nodes that discovery marked writable, with
   values validated for that node's type.

## Layers (scripts)

| Script | Role |
|---|---|
| `scripts/km_discover.sh` | Discovery. Builds `state/caps2/registry.tsv` (id, name, path, kind, rw, risk, type, confidence, value, detail) and `summary.json`. Detects capability loss between scans (`cap_lost` events). Also defines the shared JSON helpers (`km_jesc`, `km_jnum`, `km_now_ms`). |
| `scripts/km_registry.sh` | Change engine: `km_ctl_validate`, `km_ctl_paths` (registry-first path resolution), `km_ctl_set` (single control, all matching nodes), `km_txn_*` (transactions), `km_rollback`, `km_history`, `km_protected`, the change log. `HPC_PROC_SYS` makes /proc/sys location overridable for tests. |
| `scripts/km_events.sh` | Append-only event timeline (`state/events.tsv`, ring-bounded by `KM_EVENTS_MAX`, default 500, env-overridable) + `km_event_tick` which the service loop calls: boot detection, thermal/battery/game transition events. |
| `scripts/km_monitor.sh` | Read-only JSON snapshots for the WebUI: status, cpu, gpu, mem, thermal, battery, net, disk, sched, procs (two-sample CPU delta), modules, klog tail. |
| `scripts/km_bench.sh` | Benchmarks: `cpu` (multi-core integer loop), `io` (dd write/read into a scratch dir, `KM_BENCH_SCRATCH` overridable), `mem` (kernel memcpy). Results stored in `state/bench/` with the exact config they were measured under (profile/governor/scheduler + temps). A/B profile comparison with automatic restore. |
| `scripts/km_diag.sh` | Health score (transparent formula in the JSON), capability summary, full text report, and **redacted export** to `/data/local/tmp/hpc_exports/`: IPs, MACs, serials, and all UUIDs (incl. boot_id) are stripped before leaving the device directory. |
| `scripts/km_advise.sh` | Local rule engine (the "assistant"). Facts always carry a source; findings are labelled `observed` vs `inferred`; every suggestion carries a `valid` flag computed against the discovered kernel lists. The optional remote AI backend is **off by default** and only activates with an explicit `HPC_AI_ENDPOINT`; the local engine is the fallback and the default. |
| `scripts/km_profiles.sh` | Profile CRUD: list (with per-device compatibility note for the governor preference), show, compare, export, import (strict line validation: known keys, types, ranges, metachars, length), duplicate, delete (user profiles only). Import never auto-activates. |
| `scripts/plugin_loader.sh` | Plugin system: header metadata (`name`, `version`, `min_core`, `perms`), `km_plugin_register` (control registration into the engine), per-plugin tick hooks called from the service loop, error isolation (one broken plugin never breaks the module), `PLUGIN_<name>=0` disable switch, device match via the adapter's own check. |
| `plugins/adapter_xiaomi_vayu.sh` | Example adapter (POCO X3 Pro / SM8250): registers vendor-specific controls only when the device matches. |

## State layout (`/data/adb/hamedis/`)

```
config.conf                 user config (kept on uninstall)
profiles/                   user-imported profiles
state/
  caps2/registry.tsv        discovered capabilities (the registry)
  caps2/summary.json        JSON snapshot for the WebUI
  change_log.tsv            every attempted change (auditable)
  events.tsv                event timeline (ring-bounded)
  event_kv                  transition flags for km_event_tick
  bench/                    benchmark runs
  reports/                  diagnostic reports
  mon/                      monitor samples (proc deltas)
  txn_active                transaction scratch (removed on end)
  km_lock                   mkdir-based single-writer lock
```

`uninstall.sh` removes the whole `state/` tree (and
`/data/local/tmp/hpc_exports`), keeping config + logs.

## WebUI endpoints (new in v1.10)

```
km&value=status|cpu|gpu|mem|thermal|battery|net|disk|sched|procs|modules|klog|caps|events|health|history
kmctl&id=<id>&value=<v>&src=<ui|cli|profile>
kmrollback&value=N|all
kmprof&value=list|show:N|compare:A,B|export:N|duplicate:S,D|delete:N|import&name=<n>&b64=<b64>
kmbench&value=list|run:NAME|ab:NAME:PA:PB
kmadvise&value=full|explain:ID
kmreport&value=run|file:NAME|doctor  (NAME must match report_[0-9]*_redacted.txt)
```

`kmreport&value=doctor` runs the on-device self-check (`km_doctor`) and
returns the multi-line report as a single string. The check is read-only
except one guarded no-op write round-trip (a writable capability's current
value is written back to itself and read back), so it exercises the real
write path without changing anything.

All handlers run inside the existing loopback-only CGI server;
profile names are restricted to `[a-z0-9_]` (no traversal), base64
import is restricted to the base64 alphabet and 8 KiB.

## CLI

```
hpc.sh km [status|cpu|gpu|mem|thermal|battery|net|disk|sched|procs|
             modules|klog|caps|events|health|history|
             rollback [N|all]|set <id> <value>|get <id>|
             prof <list|show N|compare A B|export N>|
             bench <list|run NAME>|advise|report|doctor]
```

`hpc.sh km doctor` prints one line per check
(`PASS|WARN|FAIL  <area> <detail>`) and a final
`DOCTOR RESULT: PASS|DEGRADED|FAIL (p w f)` line — the same text the
WebUI Diagnostics tab shows. It is the recommended first thing to run on
a device after installing or updating, and the text to send back when
reporting a problem.

## Testing

`sh tests/run_tests.sh` runs seven suites (169 checks) against a
fake sysfs tree in `mktemp` — **no root, no device needed**:

- discovery (full tree, missing interfaces, read-only detection,
  capability-loss events)
- registry engine (validation against kernel lists, hw limits,
  injection rejection, protected paths, history, rollback,
  transactions incl. partial-failure rollback, single-writer lock)
- profiles (list/show/compare, strict import validation incl.
  metachars, duplicate/delete rules, export)
- bench/diag (bench runs + event emission, health score, redaction
  of ip/mac/serial/uuid, report + redacted export)
- advise/events (JSON honesty: sourced facts, flagged suggestions,
  klog rules, ring trim, explain)
- plugins (registration, tick hooks, disable switch, error
  isolation, device matching)
- API (routing, injection attempts, traversal rejection,
  backward-compatible endpoints)

Known environment limitation: the suites run under the host shell's
`/proc` (load, memory, process lists) where a device would use its
own; the kernel-controlled state (cpufreq, gpu, thermal, block,
power supply) is fully faked.

## Honest limitations / remaining work

- **GPU write controls are not enabled on any device yet.** GPU
  governor/min/max discovery works; the adapter plugin exists but is
  inert until a vendor interface is verified on-device (kgsl node
  semantics differ per SoC/ROM — nothing is assumed).
- **Charge-limit control is discovery-gated**: it only appears when
  the ROM exposes a writable limit node. On most stock Xiaomi ROMs
  it does not, so the feature is absent rather than faked.
- **The assistant is a local rule engine** with an optional,
  disabled-by-default remote backend. It has no model weights and
  makes no statistical claims; every output is labelled
  observed/inferred and suggestions are validated against the
  kernel's own lists.
- **Benchmarks measure the current configuration only.** The CPU
  bench is a userspace integer loop, not a CPU-bound kernel
  workload; treat A/B results as directional (the UI says so).
- **Per-core / per-big-LITTLE-cluster tuning** is exposed as
  separate cluster controls (cpu1.*, cpu2.*) rather than as a
  unified "big cluster" abstraction — the mapping is by discovery
  order, which matches the kernel's policy enumeration.
- **SELinux contexts on user-added plugin files** are not enforced
  beyond the module's own domain; plugin scripts run inside the
  module's service context.
