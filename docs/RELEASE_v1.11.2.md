# Hamedis Performance Core — v1.11.2 release notes

**versionCode 11102** · performance release — fixes the slow/sluggish WebUI

## Why the UI was slow (two root causes, measured)

1. **Registry scan cadence mismatch (the big one).**
   The WebUI treats the capability registry as stale after **60 s**, but the
   background service only refreshed it every **~10 ticks × 45 s ≈ 7.5 min**.
   So for ~6 min out of every 7, **every 3-second WebUI poll ran a full
   capability scan** before it could answer — seconds of latency per tick and
   constant CPU work.
2. **The scan itself forked ~2000 processes.** `km_caps_json` (called on
   every scan) ran a `sed`+`tr` pipeline 10× per capability row. Measured:
   659 ms per scan in a fast sandbox; seconds on-device.

## Fixes

1. **Aligned the two cadences** with one shared constant (`HPC_REG_TTL`,
   300 s). The registry is *structural* data (which sysfs paths exist, rw,
   risk) — it changes only on reboot / kernel-module load / ROM updates, so a
   few minutes of age is harmless. The service now refreshes at TTL−60 (240 s)
   and the CGI only falls back to a scan past TTL (300 s, i.e. only when the
   service is dead). A live 3 s poll essentially never scans again.
2. **`km_caps_json` is fork-free**: one `tr` + one `sed` pass over the whole
   TSV, then pure `printf`. Measured: **659 ms → 50 ms** per scan in the
   sandbox (≈13× faster), valid JSON verified.
3. **Two UI markup defects fixed**:
   - invalid CSS color `#5c6symbol` (dropped by browsers → header temp/version
     text in the wrong color) → `#5c6675`
   - unclosed `<span>` on the zRAM row (HTML now parses clean)

Also included from v1.11.1 (superseded by this build):
- a broken `config.conf` can no longer kill the WebUI (two-pass validation
  before sourcing; degrades to defaults, logged with the offending line)
- `hpc.sh config` / `hpc.sh config-fix` (diagnose + reseed the config)
- API bootstrap error names the config culprit

## Tests

8 suites / 232 checks, all green — including new regression checks for the
freshness window (fresh registry not rescanned, stale registry rescanned) and
the fork-free caps JSON shape.

## Install

Uninstall + install, or install over v1.11.0 (safe — no state format change).
After reboot the WebUI should update every 3 s with no visible lag; the
`km doctor` output is unchanged in shape.
