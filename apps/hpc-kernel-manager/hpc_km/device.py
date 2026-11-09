# -*- coding: utf-8 -*-
"""device — Droidian/Android A/B device introspection (read-only)."""
import os
import re
import shutil
import subprocess
import sys
import platform

# Android-style locations that may hold the A/B tooling even when they
# are not in the normal user PATH.
EXTRA_PATHS = ('/system/bin', '/vendor/bin', '/system/xbin', '/odm/bin',
               '/apex/com.android.runtime/bin')

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
    slot is 'a'/'b' or None and source describes how it was found."""
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
    dir or None, 'entries': [names present]}."""
    out = {'a': None, 'b': None, 'base': None, 'entries': []}
    bases = [BOOTDEV,
             '/dev/block/platform/soc/1d84000.ufshc/by-name',
             '/dev/block/platform/soc/7824900.sdhci/by-name',
             '/dev/block/mmcblk0bp_']
    try:
        if os.path.isdir(BOOTDEV):
            out['base'] = BOOTDEV
            out['entries'] = sorted(os.listdir(BOOTDEV))
            for s in ('a', 'b'):
                p = os.path.join(BOOTDEV, 'boot_' + s)
                if os.path.exists(p):
                    out[s] = p
    except Exception:
        pass
    if not out['a']:
        # last resort: glob any by-name dir
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


def find_tool(name):
    """Find a binary in PATH and in Android system dirs."""
    p = shutil.which(name)
    if p:
        return p
    for d in EXTRA_PATHS:
        cand = os.path.join(d, name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def markboot_caps(run_as_root=False):
    """Probe markboot / bootctl. Returns dict:
    markboot: path, set_active: bool, bootctl: path."""
    out = {'markboot': None, 'set_active': False, 'bootctl': None}
    mb = find_tool('markboot')
    out['markboot'] = mb
    if mb:
        try:
            cmd = (['sudo', mb, '--help'] if run_as_root
                   else [mb, '--help'])
            r = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=8)
            out['set_active'] = 'set-active-boot' in (r.stdout + r.stderr)
        except Exception:
            pass
    out['bootctl'] = find_tool('bootctl')
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
        'markboot': tools['markboot'],
        'markboot_set_active': tools['set_active'],
        'bootctl': tools['bootctl'],
        'python': sys.version.split()[0],
    }
