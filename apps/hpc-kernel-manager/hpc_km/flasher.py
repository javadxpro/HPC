# -*- coding: utf-8 -*-
"""flasher — A/B kernel flash orchestration.

Flow (safe by construction):
  1. detect running slot; the NEW kernel goes to the OTHER slot only
  2. backup the current slot's boot image to $WORK
  3. fetch the kernel Image (download or local file) + validate
     (exact size + ARM64 magic)
  4. repack the boot image (kernel swap, self-verified)
  5. dd the new boot image to the OTHER slot
  6. boot-control: clear-successful(OTHER), set-tries(OTHER, 5),
     make OTHER the active boot slot (markboot --set-active-boot or
     bootctl set-active-boot-slot)
  -> if the new kernel fails to boot, the ABL automatically falls
     back to the untouched current slot after the tries expire.
"""
import json
import os
import time
import urllib.request

from . import device
from .bootimg import BootImgError, repack, is_arm64_image

BRANCH = 'arena/37022f35-hpc'
RAW = 'https://raw.githubusercontent.com/javadxpro/HPC/' + BRANCH

KERNELS = {
    '355': {
        'name': '4.14.355 LTS (recommended)',
        'url': RAW + '/artifacts/kernel-4.14.355/Image',
        'size': 47661056,
    },
    '190': {
        'name': '4.14.190 (current base)',
        'url': RAW + '/artifacts/kernel-4.14.190-vayu/Image',
        'size': 61335144,
    },
}

TRIES = 5


class FlashError(Exception):
    def __init__(self, stage, msg):
        super().__init__(msg)
        self.stage = stage


def default_workdir():
    d = os.path.join(os.path.expanduser('~'), 'hpc-kernel')
    os.makedirs(d, exist_ok=True)
    return d


def _log_or_raise(stage, rc, out, err_msg=None):
    if rc != 0:
        raise FlashError(stage, (err_msg or 'command failed (rc=%s)'
                                 % rc) + ' :: ' + out[-500:])


def dd(log, ifpath, ofpath, stage):
    out = os.path.realpath(ofpath)
    _log_or_raise(stage, *device.run_root(
        ['dd', 'if=' + ifpath, 'of=' + out, 'bs=4M'], log=log),
        'dd failed ' + ifpath + ' -> ' + out)


def backup(log, workdir):
    """Backup the current slot's boot image. Returns (path, slot)."""
    slot, src = device.detect_slot()
    if not slot:
        raise FlashError('detect-slot',
                         'cannot detect the running slot (no getprop and '
                         'no slot_suffix in /proc/cmdline). cmd: ' +
                         device.read_cmdline()[:300])
    parts = device.boot_partitions()
    if not parts[slot]:
        raise FlashError('find-partition',
                         'boot_%s not found under %s (entries: %s)'
                         % (slot, parts['base'],
                            ', '.join(parts['entries'][:20]) or 'none'))
    dst = os.path.join(workdir, 'boot_backup_%s.img' % slot)
    free = device.disk_free_mb(workdir)
    if free is not None and free < 150:
        raise FlashError('disk', 'not enough disk space (%d MB free, '
                         'need ~150)' % free)
    log('backup: %s -> %s' % (parts[slot], dst))
    dd(log, parts[slot], dst, 'backup')
    size = os.path.getsize(dst)
    if size < 10 * 1024 * 1024:
        raise FlashError('backup', 'backup suspiciously small (%d bytes)'
                         % size)
    log('backup OK: %d bytes' % size)
    return dst, slot


def fetch_kernel(key_or_path, workdir, log, progress=None):
    """Download (or copy local) the kernel Image. Returns path.
    key: '355' | '190' | absolute path to a local Image file."""
    if key_or_path in KERNELS:
        meta = KERNELS[key_or_path]
        dst = os.path.join(workdir, 'Image.' + key_or_path)
        log('download: %s' % meta['url'])
        req = urllib.request.Request(meta['url'],
                                     headers={'User-Agent': 'hpc-km'})
        with urllib.request.urlopen(req, timeout=30) as r:
            total = int(r.headers.get('Content-Length') or 0)
            got = 0
            with open(dst, 'wb') as f:
                while True:
                    chunk = r.read(1024 * 256)
                    if not chunk:
                        break
                    f.write(chunk)
                    got += len(chunk)
                    if progress:
                        progress(got, total if total else got)
        log('downloaded %d bytes' % got)
        expected = meta['size']
    else:
        dst = os.path.join(workdir, 'Image.local')
        log('local kernel: %s' % key_or_path)
        with open(key_or_path, 'rb') as src, open(dst, 'wb') as f:
            while True:
                chunk = src.read(1024 * 1024)
                if not chunk:
                    break
                f.write(chunk)
        expected = None

    size = os.path.getsize(dst)
    if expected is not None and size != expected:
        raise FlashError('verify-kernel',
                         'size mismatch: got %d, expected %d — the '
                         'download may be incomplete or the artifact '
                         'changed' % (size, expected))
    with open(dst, 'rb') as f:
        head = f.read(64)
    if not is_arm64_image(head):
        raise FlashError('verify-kernel',
                         'file is not an ARM64 kernel Image '
                         '(bad magic at offset 56)')
    log('kernel verified: %d bytes, ARM64 magic OK' % size)
    return dst


def _set_active(log, other):
    """Make the OTHER slot the next boot target. Raises FlashError if
    no supported backend exists (callers must NOT reboot in that case).
    Backends, in order: markboot --set-active-boot, runnable bootctl,
    direct A/B BCB write to the misc partition (device.py)."""
    try:
        device.boot_control_set_active(other, log=log)
    except device.DeviceError as e:
        raise FlashError('set-active', str(e))


def flash(log, kernel_key, workdir=None, progress=None):
    """Full flash flow. Returns dict with slot info."""
    workdir = workdir or default_workdir()
    slot, src = device.detect_slot()
    if not slot:
        raise FlashError('detect-slot',
                         'cannot detect the running slot. cmdline: ' +
                         device.read_cmdline()[:300])
    other = device.other_slot(slot)
    parts = device.boot_partitions()
    if not parts[slot] or not parts[other]:
        raise FlashError('find-partition',
                         'need both boot_%s and boot_%s (found: a=%s '
                         'b=%s, base=%s, entries=%s)'
                         % (slot, other, parts['a'], parts['b'],
                            parts['base'],
                            ', '.join(parts['entries'][:20]) or 'none'))
    log('current slot: %s (via %s) -> flashing to %s'
        % (slot, src, other))

    bak_path, _ = backup(log, workdir)
    img_path = fetch_kernel(kernel_key, workdir, log, progress=progress)
    new_boot = os.path.join(workdir, 'boot_new.img')
    log('repack: swapping kernel inside the boot image')
    try:
        repack(bak_path, img_path, new_boot, log=log)
    except BootImgError as e:
        raise FlashError('repack', str(e))
    log('dd new boot -> %s' % parts[other])
    dd(log, new_boot, parts[other], 'flash')

    log('boot-control: preparing slot %s (attempt mode, tries=%d)'
        % (other, TRIES))
    try:
        device.boot_control_prepare(other, tries=TRIES, log=log)
    except device.DeviceError as e:
        raise FlashError('boot-control', str(e))
    _set_active(log, other)

    try:
        device.run_root(['markboot', '--dump'], log=log)
    except Exception:
        pass
    return {'slot': slot, 'other': other, 'backup': bak_path,
            'new_boot': new_boot}


def restore(log, workdir=None):
    """Put the backup back into the OTHER slot and re-pin the CURRENT
    slot as active+successful (manual safety net)."""
    workdir = workdir or default_workdir()
    slot, src = device.detect_slot()
    if not slot:
        raise FlashError('detect-slot', 'cannot detect the running slot')
    other = device.other_slot(slot)
    parts = device.boot_partitions()
    bak = os.path.join(workdir, 'boot_backup_%s.img' % slot)
    if not os.path.isfile(bak):
        raise FlashError('restore', 'backup not found: ' + bak)
    if not parts[other]:
        raise FlashError('find-partition',
                         'boot_%s not found (base=%s)' % (other,
                                                          parts['base']))
    log('restore: %s -> %s' % (bak, parts[other]))
    dd(log, bak, parts[other], 'restore')
    try:
        device.boot_control_set_active(slot, log=log)
        device.boot_control_mark_successful(slot, log=log)
    except device.DeviceError as e:
        raise FlashError('boot-control', str(e))
    log('restore OK: current slot %s re-pinned as active+successful'
        % slot)


def mark_current_successful(log):
    """Post-boot: mark the now-running slot as successful (locks it)."""
    slot, src = device.detect_slot()
    if not slot:
        raise FlashError('mark-successful', 'cannot detect the slot')
    try:
        device.boot_control_mark_successful(slot, log=log)
    except device.DeviceError as e:
        raise FlashError('mark-successful', str(e))
    log('slot %s marked successful (locked)' % slot)


def reboot(log):
    log('rebooting…')
    try:
        os.execvp('reboot', ['reboot'])
    except Exception:
        device.run_root(['reboot'], log=log)


def probe_root():
    """Read-only probe for the elevated worker (or direct when root)."""
    import platform
    return {
        'euid': os.geteuid(),
        'kernel': platform.release(),
        'slot': device.detect_slot()[0],
        'misc': device.misc_partition(),
        'partlabels': sorted(device.lsblk_labels()),
        'markboot': device.markboot_caps(run_as_root=False),
        'python': platform.python_version(),
    }


def _run_pkexec(action, args, log):
    """Run one job as root through pkexec (single polkit prompt)."""
    import subprocess
    import sys
    pk = device.find_tool('pkexec')
    if not pk:
        raise FlashError('privilege',
                         'pkexec not found. Alternative: run the whole '
                         'app as root with:  sudo -E hpc-kernel-manager')
    import json
    cmd = [pk, sys.executable, '-m', 'hpc_km.elevated', action,
           json.dumps(args or {})]
    log('$ ' + ' '.join(cmd))
    log('(waiting for the authorization prompt…)'
        if action != 'reboot' else '(authorization prompt…)')
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    tail = []
    for line in p.stdout:
        line = line.rstrip()
        if line:
            log(line)
            tail.append(line)
    rc = p.wait()
    if rc != 0:
        last = next((l for l in reversed(tail) if l.startswith('FAILED')),
                    tail[-1] if tail else 'exit code %d' % rc)
        stage = 'job'
        if last.startswith('FAILED [') and ']' in last:
            stage = last[8:last.index(']')]
            last = last[last.index(']') + 2:]
        raise FlashError(stage, last)
    return rc


class Job(object):
    """One privileged operation. Runs directly when the app is root,
    otherwise through pkexec (one authorization prompt per job).
    All log lines are delivered to the callback (main GTK thread)."""

    def __init__(self, action, args=None, log=None):
        self.action = action
        self.args = args or {}
        self.log = log or (lambda m: None)

    def run(self):
        """Blocking. Raises FlashError on failure."""
        if device.is_root():
            self._run_direct()
        else:
            _run_pkexec(self.action, self.args, self.log)

    def _run_direct(self):
        log = self.log
        a, args = self.action, self.args
        workdir = args.get('workdir')
        if a == 'probe':
            log('probe: ' + json.dumps(probe_root()))
        elif a == 'backup':
            backup(log, workdir)
        elif a == 'flash':
            flash(log, args.get('kernel', '355'), workdir=workdir,
                  progress=None)
        elif a == 'restore':
            restore(log, workdir)
        elif a == 'markok':
            mark_current_successful(log)
        elif a == 'reboot':
            reboot(log)
        else:
            raise FlashError('unknown-action', a)
