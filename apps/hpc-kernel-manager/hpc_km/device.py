# -*- coding: utf-8 -*-
"""device — Droidian/Android A/B device introspection (read-only)."""
import os
import re
import shutil
import struct
import subprocess
import sys
import platform

# Android-style locations that may hold the A/B tooling even when they
# are not in the normal user PATH.
EXTRA_PATHS = ('/system/bin', '/vendor/bin', '/system/xbin', '/odm/bin',
               '/apex/com.android.runtime/bin')

# Standard sbin dirs. GUI apps (Phosh/GNOME) often get a minimal PATH
# without /usr/sbin, so tools like markboot can be missed by
# shutil.which() — always check these explicitly.
TOOL_DIRS = ('/usr/local/sbin', '/usr/local/bin', '/usr/sbin', '/usr/bin',
             '/sbin', '/bin')

BOOTDEV = '/dev/block/bootdevice/by-name'


class DeviceError(Exception):
    pass


def _try_cmd(cmd, timeout=5):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout)
        return r.returncode, r.stdout.strip()
    except Exception:
        return None, ''


def read_cmdline():
    try:
        with open('/proc/cmdline', 'r') as f:
            return f.read().strip()
    except Exception:
        return ''


def detect_slot(cmdline=None):
    """Detect the running A/B slot. Returns (slot, source) where
    slot is 'a'/'b' or None and source describes how it was found.

    Methods, in order:
      1. Android getprop (ro.boot_slot / ro.boot.slot_suffix)
      2. /proc/cmdline slot_suffix / androidboot.slot_suffix
      3. bootctl get-current-slot (only if it actually runs here —
         /system/bin/bootctl is a bionic binary and usually cannot)
      4. partition label of the device mounted at /system or /
         (e.g. system_a -> slot a) via lsblk / sysfs uevent
      5. root= in /proc/cmdline (PARTLABEL=... or /dev/... device)
    """
    cmdline = cmdline if cmdline is not None else read_cmdline()
    for name, cmd in (('getprop ro.boot_slot', ['getprop', 'ro.boot_slot']),
                      ('getprop ro.boot.slot_suffix',
                       ['getprop', 'ro.boot.slot_suffix'])):
        rc, out = _try_cmd(cmd)
        if rc == 0 and out:
            m = re.search(r'[ab]\s*$', out)
            if m:
                return m.group(0), name
    m = re.search(r'slot_suffix=_([ab])\b', cmdline)
    if m:
        return m.group(1), '/proc/cmdline (slot_suffix)'
    m = re.search(r'androidboot\.slot_suffix=_([ab])\b', cmdline)
    if m:
        return m.group(1), '/proc/cmdline (androidboot.slot_suffix)'
    bc = find_tool('bootctl')
    if bc:
        rc, out = _try_cmd([bc, 'get-current-slot'], timeout=5)
        if rc == 0 and out.strip() in ('0', '1'):
            return ('a' if out.strip() == '0' else 'b'), \
                'bootctl get-current-slot'
    slot, src = _slot_from_mounts()
    if slot:
        return slot, src
    slot, src = _slot_from_cmdline_root(cmdline)
    if slot:
        return slot, src
    return None, 'not found'


def other_slot(slot):
    if slot == 'a':
        return 'b'
    if slot == 'b':
        return 'a'
    return None


def boot_partitions():
    """Locate boot_a / boot_b block devices.
    Returns dict {'a': path or None, 'b': path or None, 'base': base
    dir or None, 'entries': [names present]}.

    On Droidian (systemd-udev) the GPT labels appear as symlinks in
    /dev/disk/by-partlabel/ — the Android ueventd layout
    (/dev/block/bootdevice/by-name) does not exist there.
    """
    out = {'a': None, 'b': None, 'base': None, 'entries': []}
    bases = [BOOTDEV,
             '/dev/disk/by-partlabel',
             '/dev/disk/by-name',
             '/dev/block/by-name',
             '/dev/block/platform/soc/1d84000.ufshc/by-name',
             '/dev/block/platform/soc/7824900.sdhci/by-name']
    for base in bases:
        try:
            if os.path.isdir(base):
                names = sorted(os.listdir(base))
                if 'boot_a' in names or 'boot_b' in names:
                    out['base'] = base
                    out['entries'] = names
                    for s in ('a', 'b'):
                        p = os.path.join(base, 'boot_' + s)
                        if os.path.exists(p):
                            out[s] = p
                    if out['a'] and out['b']:
                        return out
        except Exception:
            pass
    # lsblk by GPT PARTLABEL (works on any Debian/Droidian userland)
    labels = lsblk_labels()
    for s in ('a', 'b'):
        key = 'boot_' + s
        if key in labels and not out[s]:
            out[s] = labels[key]
    if labels:
        out['entries'] = sorted(labels)
        if not out['base']:
            out['base'] = 'lsblk'
    if not out['a']:
        # last resort: glob any Android-style by-name dir
        try:
            for d in (x for x in os.listdir('/dev/block')
                      if x.startswith('platform')):
                cand = os.path.join('/dev/block', d, 'by-name')
                if os.path.isdir(cand):
                    names = os.listdir(cand)
                    if 'boot_a' in names and 'boot_b' in names:
                        out['base'] = cand
                        out['a'] = os.path.join(cand, 'boot_a')
                        out['b'] = os.path.join(cand, 'boot_b')
                        out['entries'] = sorted(names)
                        break
        except Exception:
            pass
    return out


def lsblk_labels():
    """{GPT PARTLABEL: device path} via lsblk, or {} if unavailable."""
    rc, out = _try_cmd(['lsblk', '-P', '-o', 'PATH,PARTLABEL'])
    res = {}
    if rc != 0 or not out:
        return res
    for line in out.splitlines():
        path = label = None
        for tok in line.split():
            if tok.startswith('PATH='):
                path = tok[5:].strip('"')
            elif tok.startswith('PARTLABEL='):
                label = tok[10:].strip('"')
        if path and label:
            res[label] = path
    return res


def _partname_of(device_path):
    """GPT PARTNAME for a device path via sysfs uevent, or None."""
    base = os.path.basename(device_path or '')
    if not base:
        return None
    try:
        with open('/sys/class/block/%s/uevent' % base) as f:
            for line in f:
                if line.startswith('PARTNAME='):
                    return line.strip().split('=', 1)[1]
    except Exception:
        pass
    return None


def _label_of_device(device_path):
    """GPT label for a device path (lsblk first, sysfs uevent fallback)."""
    base = os.path.basename(device_path or '')
    if not base:
        return None
    for label, path in lsblk_labels().items():
        if os.path.basename(path) == base:
            return label
    return _partname_of(device_path)


def _slot_from_mounts():
    """Infer the slot from the partition mounted at /system or /.
    Returns (slot, source) or (None, None)."""
    try:
        mounts = {}
        with open('/proc/mounts') as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    mounts[parts[1]] = parts[0]
    except Exception:
        return None, None
    for mp in ('/system', '/'):
        dev = mounts.get(mp)
        if not dev:
            continue
        label = _label_of_device(dev)
        if label:
            m = re.search(r'_([ab])$', label)
            if m:
                return m.group(1), '/proc/mounts %s (%s)' % (mp, label)
    return None, None


def _slot_from_cmdline_root(cmdline):
    """Infer the slot from root= in /proc/cmdline.
    Returns (slot, source) or (None, None)."""
    m = re.search(r'\broot=([^\s]+)', cmdline or '')
    if not m:
        return None, None
    root = m.group(1)
    if root.startswith('PARTLABEL='):
        label = root.split('=', 1)[1]
        mm = re.search(r'_([ab])$', label)
        if mm:
            return mm.group(1), '/proc/cmdline (root=PARTLABEL=%s)' % label
        return None, None
    if root.startswith('/dev/'):
        label = _label_of_device(root)
        if label:
            mm = re.search(r'_([ab])$', label)
            if mm:
                return mm.group(1), '/proc/cmdline (root=%s)' % label
    return None, None


def misc_partition():
    """Locate the misc partition (holds the A/B BootControlBlock)."""
    for base in ('/dev/disk/by-partlabel', '/dev/block/by-name', BOOTDEV,
                 '/dev/disk/by-name'):
        p = os.path.join(base, 'misc')
        if os.path.exists(p):
            return p
    return lsblk_labels().get('misc')


# ---------------------------------------------------------------- BCB
# A/B BootControlBlock (AOSP libboot_control), 64 bytes at offset 0 of
# the misc partition:
#   u32 magic (0x4243424C), u32 version (1), u32 nb_slots (2),
#   u32 max_tries (5), SlotMetadata slot_info[2], u8 reserved[...]
#   SlotMetadata: u8 priority, u8 tries_remaining,
#                 u8 successful_boot, u8 verity_state, u8 reserved[4]
# slot_info[0] at byte 16, slot_info[1] at byte 24.
BCB_MAGIC = 0x4243424C
BCB_SIZE = 64


def _bcb_read(misc):
    """Read + validate the A/B BCB. Returns bytearray or None.
    Needs root (block devices are root-only); fails soft otherwise."""
    try:
        fd = os.open(misc, os.O_RDONLY)
        try:
            data = os.read(fd, BCB_SIZE)
        finally:
            os.close(fd)
    except Exception:
        return None
    if len(data) < 32:
        return None
    magic, _version, nb_slots, _mt = struct.unpack('<IIII', data[:16])
    if magic != BCB_MAGIC or nb_slots != 2:
        return None
    return bytearray(data)


def _bcb_write(misc, data):
    fd = os.open(misc, os.O_WRONLY)
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, bytes(data))
        os.fsync(fd)
    finally:
        os.close(fd)


def _bcb_update(misc, slot, priority=None, tries=None, successful=None,
                log=None):
    """Read-modify-write one slot's metadata in the A/B BCB.
    Only the slot_info bytes are touched; everything else is preserved."""
    log = log or (lambda m: None)
    data = _bcb_read(misc)
    if data is None:
        raise DeviceError('BCB not readable/valid at %s (magic check '
                          'failed; need root)' % misc)
    off = 16 + (0 if slot == 'a' else 1) * 8
    old = tuple(data[off:off + 4])
    if priority is not None:
        data[off] = priority
    if tries is not None:
        data[off + 1] = tries
    if successful is not None:
        data[off + 2] = successful
    log('BCB %s slot %s: (prio,tries,ok,verity) %s -> %s'
        % (misc, slot, old, tuple(data[off:off + 4])))
    _bcb_write(misc, data)


def _run_checked(args, log, what):
    rc, out = run_root(args, log=log)
    if rc != 0:
        raise DeviceError('%s failed (rc=%s): %s'
                          % (what, rc, out[-300:]))


def boot_control_prepare(slot, tries=5, log=None):
    """Put slot into first-boot-attempt mode: clear-successful,
    tries_remaining=tries, priority=15. Returns backend name.
    Tries markboot first, then the BCB fallback. Raises DeviceError."""
    log = log or (lambda m: None)
    mb = find_tool('markboot')
    if mb:
        _run_checked([mb, '--clear-successful', 'boot_' + slot], log,
                     'markboot --clear-successful')
        _run_checked([mb, '--set-tries', 'boot_' + slot, str(tries)], log,
                     'markboot --set-tries')
        log('boot-control via markboot: slot %s prepared (tries=%d)'
            % (slot, tries))
        return 'markboot'
    misc = misc_partition()
    if misc:
        _bcb_update(misc, slot, priority=15, tries=tries, successful=0,
                    log=log)
        log('boot-control via BCB (%s): slot %s prepared (tries=%d)'
            % (misc, slot, tries))
        return 'bcb'
    raise DeviceError('no boot-control backend (markboot not found, '
                      'no misc partition for BCB fallback)')


def boot_control_set_active(slot, log=None):
    """Make slot the next boot target (priority 15, other 14).
    Tries markboot --set-active-boot, then a runnable bootctl, then
    the BCB fallback. Returns backend name. Raises DeviceError."""
    log = log or (lambda m: None)
    caps = markboot_caps()
    if caps['markboot'] and caps['set_active']:
        _run_checked([caps['markboot'], '--set-active-boot',
                      'boot_' + slot], log, 'markboot --set-active-boot')
        log('boot-control via markboot: slot %s set active' % slot)
        return 'markboot'
    if caps['bootctl_runs']:
        n = '0' if slot == 'a' else '1'
        _run_checked([caps['bootctl'], 'set-active-boot-slot', n], log,
                     'bootctl set-active-boot-slot')
        log('boot-control via bootctl: slot %s set active' % slot)
        return 'bootctl'
    misc = misc_partition()
    if misc:
        _bcb_update(misc, slot, priority=15, log=log)
        other = other_slot(slot)
        if other:
            _bcb_update(misc, other, priority=14, log=log)
        log('boot-control via BCB (%s): slot %s set active'
            % (misc, slot))
        return 'bcb'
    raise DeviceError('no way to set the active slot (need markboot '
                      '--set-active-boot, a runnable bootctl, or a misc '
                      'partition for BCB fallback)')


def boot_control_mark_successful(slot, log=None):
    """Mark slot as successfully booted (locks it in).
    Tries markboot, then the BCB fallback. Returns backend name.
    Raises DeviceError."""
    log = log or (lambda m: None)
    mb = find_tool('markboot')
    if mb:
        _run_checked([mb, '--set-successful', 'boot_' + slot], log,
                     'markboot --set-successful')
        log('boot-control via markboot: slot %s marked successful' % slot)
        return 'markboot'
    misc = misc_partition()
    if misc:
        _bcb_update(misc, slot, successful=1, log=log)
        log('boot-control via BCB (%s): slot %s marked successful'
            % (misc, slot))
        return 'bcb'
    raise DeviceError('no boot-control backend to mark slot successful')


def find_tool(name):
    """Find a binary in PATH, standard sbin dirs, and Android system
    dirs (GUI apps may have a PATH without /usr/sbin)."""
    p = shutil.which(name)
    if p:
        return p
    for d in TOOL_DIRS + EXTRA_PATHS:
        cand = os.path.join(d, name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def markboot_caps(run_as_root=False):
    """Probe markboot / bootctl. Returns dict:
    markboot: path, set_active: bool, bootctl: path,
    bootctl_runs: bool (actually executes on this userland),
    bootctl_slot: '0'/'1' from get-current-slot if runnable.

    --help never needs root, so it is always probed directly (no sudo
    password prompt in a GUI app)."""
    out = {'markboot': None, 'set_active': False, 'bootctl': None,
           'bootctl_runs': False, 'bootctl_slot': None}
    mb = find_tool('markboot')
    out['markboot'] = mb
    if mb:
        try:
            r = subprocess.run([mb, '--help'], capture_output=True,
                               text=True, timeout=8)
            out['set_active'] = 'set-active-boot' in (r.stdout + r.stderr)
        except Exception:
            pass
    bc = find_tool('bootctl')
    out['bootctl'] = bc
    if bc:
        rc, o = _try_cmd([bc, 'get-current-slot'], timeout=5)
        if rc == 0 and o.strip() in ('0', '1'):
            out['bootctl_runs'] = True
            out['bootctl_slot'] = o.strip()
    return out


def kernel_info():
    return {
        'release': platform.release(),
        'version': read_version_line(),
        'cmdline': read_cmdline(),
    }


def read_version_line():
    try:
        with open('/proc/version', 'r') as f:
            return f.read().strip()[:200]
    except Exception:
        return ''


def is_root():
    try:
        return os.geteuid() == 0
    except Exception:
        return False


def root_prefix():
    """Command prefix for elevated commands: [] if already root,
    ['sudo'] if sudo exists, else raise DeviceError."""
    if is_root():
        return []
    if find_tool('sudo'):
        return ['sudo']
    if find_tool('su'):
        return ['su', '-c']
    raise DeviceError('no root access (sudo/su not found)')


def run_root(args, log=None, timeout=None):
    """Run a command with root elevation. args is a list.
    If the prefix is 'su -c' the args are joined into a shell string.
    Returns (rc, output_tail). Raises DeviceError on spawn failure."""
    log = log or (lambda m: None)
    pre = root_prefix()
    if pre == ['su', '-c']:
        cmd = pre + [' '.join(_shellquote(a) for a in args)]
    else:
        cmd = pre + list(args)
    log('$ ' + ' '.join(cmd))
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout)
        out = (r.stdout or '') + (r.stderr or '')
        return r.returncode, out.strip()[-800:]
    except Exception as e:
        raise DeviceError('failed to run: %s' % e)


def _shellquote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def disk_free_mb(path):
    try:
        s = os.statvfs(path)
        return (s.f_bavail * s.f_frsize) // (1024 * 1024)
    except Exception:
        return None


def full_status():
    """One-shot read-only snapshot for the status card / diagnostics."""
    slot, src = detect_slot()
    parts = boot_partitions()
    tools = markboot_caps(run_as_root=not is_root())
    k = kernel_info()
    return {
        'root': is_root(),
        'slot': slot,
        'slot_source': src,
        'other': other_slot(slot),
        'kernel_release': k['release'],
        'kernel_version': k['version'],
        'cmdline': k['cmdline'],
        'boot_a': parts['a'],
        'boot_b': parts['b'],
        'boot_base': parts['base'],
        'boot_entries': parts['entries'],
        'partlabels': sorted(lsblk_labels()),
        'misc': misc_partition(),
        'markboot': tools['markboot'],
        'markboot_set_active': tools['set_active'],
        'bootctl': tools['bootctl'],
        'bootctl_runs': tools['bootctl_runs'],
        'bootctl_slot': tools['bootctl_slot'],
        'python': sys.version.split()[0],
    }
