# Hamedis Performance Core — v1.12.2 release notes

**versionCode 11202** · migration fix — the profile list is now
guaranteed to be exactly the seven curated profiles after updating
from v1.11.x.

## What was wrong

v1.12.0 removed `cool`, `silent`, `multitasking` and `standby`. The
cleanup for their seeded copies relied on the seed manifest
(`state/profiles_seed.txt`) — but that manifest is a v1.12+ concept.
On a device that ran v1.11.x, those four profiles had been seeded into
`/data/adb/hamedis/profiles` **without** any manifest entry, so v1.12.0
simply never saw them and they stayed in the profile list as ghosts.

## The fix

`hpc_init_config` now also compares the four retired v1.11 built-ins
against the exact SHA-1 of the v1.11.0–v1.11.2 built-in files:

- copy hash **matches** → pristine seeded copy → removed
- copy hash differs → you had edited it → **stashed** to
  `state/retired_profiles_v11/` (never deleted, restorable) so the
  listed set is still exactly the seven

The generic manifest rule is unchanged for everything else: a
user-modified seeded copy of any future removed profile is kept.
Idempotent — on later boots the files are simply gone.

## Tests

8 suites / 268 checks green, including a new migration section that
reproduces the exact v1.11.x state (real old built-in file contents):
pristine copy removed, modified copy stashed with the edit preserved,
listed set exactly 7, second boot a no-op.
