# HPC Kernel Manager

A/B **kernel flash manager** for Droidian (POCO X3 Pro / vayu) —
GTK4 + PyGObject. Runs the whole HPC kernel flash flow with a GUI:
status/diagnostics → backup → download → repack → flash to the other
slot → boot-control (attempt mode with automatic rollback) → reboot.

## Run (two ways)

**Way 1 — normal user (recommended):**

```bash
hpc-kernel-manager
```

Each privileged action (backup/flash/restore/mark-ok/reboot) is
executed via **pkexec**, which shows the Phosh polkit
authorization prompt once per action.

**Way 2 — as root:**

```bash
sudo -E hpc-kernel-manager
```

Note the **`-E`**: without it `sudo` strips the Wayland session
environment and GTK cannot initialize
("Authorization required, but no authorization protocol specified" /
"Gtk couldn't be initialized").

If neither pkexec nor a working `sudo -E` session is available, the
app shows a banner and disables the actions (status/diagnostics
still work).

## What it does (safe by construction)

- Detects the running A/B slot (getprop → `/proc/cmdline` slot_suffix)
  and the boot partitions, and shows markboot/bootctl availability —
  this doubles as the diagnostic panel
- **Backup** the current slot's boot image to `~/hpc-kernel/`
- **Flash**: download the kernel Image (exact size + ARM64 magic
  verified), repack the boot image (kernel swap only — ramdisk/dtb/
  cmdline/header preserved, self-verified before writing), dd to the
  **OTHER** slot, then boot-control: `clear-successful(OTHER)`,
  `set-tries(OTHER, 5)`, `set-active-boot(OTHER)` (markboot
  `--set-active-boot`, with `bootctl set-active-boot-slot` fallback;
  refuses to continue if neither exists)
- If the new kernel fails to boot, the ABL **automatically rolls back**
  to the untouched current slot after the tries expire
- **Restore**: write the backup back to the other slot and re-pin the
  current slot as active+successful (manual safety net)
- **Mark OK**: after a successful boot on the new kernel, run this
  once to lock the new slot as successful
- **Reboot**

## Kernels

- `4.14.355 LTS` (47,661,056 B) — recommended
- `4.14.190` (61,335,144 B) — current base
- any local `Image` file (ARM64, `make Image` output)

Both are the HPC artifacts from this repo (branch
`arena/37022f35-hpc`), downloaded from raw.githubusercontent.com.

## Install

```bash
sudo dpkg -i hpc-kernel-manager_0.1.0_arm64.deb
```

## Build

```bash
./build-deb.sh   # no root needed
```

## Notes / limits (honest)

- The repack engine is the tested `tools/repack-boot.py` (verified on
  the real 190/355 boot images + synthetic v0/v1/v2/vm suite)
- Boot-control uses whatever the device provides (markboot or
  bootctl); if neither can set the active slot, the app stops BEFORE
  reboot and tells you exactly what to send back
- The GUI itself is untested in the headless build sandbox (same as
  the other HPC apps); the engine logic (repack, detection,
  validation) is unit-tested
