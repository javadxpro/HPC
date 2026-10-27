# Hamedis Performance Core — v1.11.1 release notes

**versionCode 11101** · fix release for the broken-WebUI / "config.conf line … not found" symptom

## What was wrong

`config.conf` (in `/data/adb/hamedis`, survives updates) is **sourced as a
shell script** by the WebUI/API. If it contains a stray line without `=`
(a leftover word from an edit — e.g. a bare `cool` on the last line), the
shell tries to **execute** it and dies with something like:

```
sh: 104: cool: not found
```

That killed every `api.sh` process → the whole WebUI went dark. The line
number (104 on this device: the file is 101 lines + the migrated
`IO_SCHEDULER=` key + blank line) is where the stray line sits.

## What is fixed (v1.11.1)

1. **Config is validated before it is sourced** (two passes):
   - `sh -n` catches syntax errors (unbalanced quotes, ...)
   - a throwaway source in a subshell catches the stray-word class
     ("line N: … not found")
   A broken config now **degrades to the built-in defaults and is
   logged with the offending line number** — it can no longer take the
   WebUI/API/service down.
2. **New CLI**:
   - `sh hpc.sh config` — reports config.conf health, the exact error
     line, and prints the offending area with context
   - `sh hpc.sh config-fix` — backs up the broken file
     (`config.conf.broken.<ts>`) and reseeds the module defaults
     (your profile copies are untouched)
3. **API bootstrap error** now names the culprit: when the config is
   broken you get `…config.conf is broken: sh: 104: … (fix: sh
   …/hpc.sh config-fix)` instead of a generic message.
4. **Tests**: 10 new checks (valid/syntax-error/stray-word/
   degraded-load/API-answers-despite-broken-config). 8 suites /
   227 checks, all green.

## If your WebUI is dead right now

```sh
adb shell su -c 'sh /data/adb/modules/hamedis_performance_core/hpc.sh config'
```

- If it says `PROBLEM` with a line number →
  `adb shell su -c 'sh /data/adb/modules/hamedis_performance_core/hpc.sh config-fix'`
  → reboot (or re-tap the Magisk Action button). The WebUI comes back;
  your profile copies and logs are preserved, only the broken
  config.conf is replaced (a backup is kept).
- If it says `OK` → the config is fine; run
  `…/hpc.sh km doctor` and send that output instead.

Everything else from v1.11.0 (Magisk v31 detection, مجیسک tab,
DenyList management, self-update, doctor, pkill→/proc fix) is unchanged.
