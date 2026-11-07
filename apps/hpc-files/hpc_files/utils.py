# -*- coding: utf-8 -*-
"""Shared helpers for HPC Files. GTK-free on purpose (testable headless)."""
import hashlib
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

APP_ID = 'sm.puri.HPCFiles'
APP_NAME = 'HPC Files'
VERSION = '0.1.0'
HOMEPAGE = 'https://github.com/javadxpro/HPC'

TEXT_EXTS = {'.txt', '.md', '.markdown', '.rst', '.log', '.json', '.yaml', '.yml',
             '.toml', '.ini', '.cfg', '.conf', '.sh', '.bash', '.py', '.pl', '.js',
             '.ts', '.c', '.h', '.cpp', '.hpp', '.java', '.kt', '.go', '.rs', '.rb',
             '.php', '.css', '.html', '.htm', '.xml', '.csv', '.tsv', '.tex', '.mk',
             '.cmake', '.patch', '.diff', '.desktop', '.service', '.socket', '.udev',
             '.rules', '.env', '.properties', '.gradle', '.sql', '.lua'}
IMAGE_EXTS = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.ico', '.svg',
              '.tiff', '.tif', '.avif'}
AUDIO_EXTS = {'.mp3', '.ogg', '.oga', '.flac', '.wav', '.m4a', '.aac', '.opus',
              '.wma', '.mid'}
VIDEO_EXTS = {'.mp4', '.mkv', '.webm', '.avi', '.mov', '.mpg', '.mpeg', '.ts',
              '.m4v', '.3gp'}
EXEC_EXTS = {'.sh', '.bash', '.py', '.pl', '.appimage'}


def state_dir():
    base = os.environ.get('XDG_DATA_HOME') or os.path.join(str(Path.home()), '.local', 'share')
    d = Path(base) / 'hpc-files'
    d.mkdir(parents=True, exist_ok=True)
    return d


def load_json(name, default):
    try:
        with open(state_dir() / name, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return default


def save_json(name, data):
    try:
        p = state_dir() / name
        tmp = p.with_name(name + '.tmp')
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
        os.replace(tmp, p)
    except Exception:
        pass


def human_size(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return ''
    if n < 0:
        return ''
    for unit in ('B', 'KB', 'MB', 'GB', 'TB', 'PB'):
        if n < 1024.0 or unit == 'PB':
            if unit == 'B':
                return '%d %s' % (int(n), unit)
            return '%.1f %s' % (n, unit)
        n /= 1024.0
    return ''


def fmt_time(ts):
    if not ts:
        return ''
    now = time.localtime()
    d = time.localtime(ts)
    if d.tm_year == now.tm_year:
        return time.strftime('%d %b %H:%M', d)
    return time.strftime('%d %b %Y', d)


def detect_encoding(data):
    for enc in ('utf-8', 'latin-1'):
        try:
            data.decode(enc)
            return enc
        except UnicodeDecodeError:
            continue
    return 'latin-1'


def read_text(path, limit=2 * 1024 * 1024):
    """Return (text, encoding, truncated)."""
    with open(path, 'rb') as f:
        data = f.read(limit + 1)
    truncated = len(data) > limit
    if truncated:
        data = data[:limit]
    enc = detect_encoding(data)
    return data.decode(enc, errors='replace'), enc, truncated


def _hash_file(path, algo):
    h = hashlib.new(algo)
    with open(path, 'rb') as f:
        while True:
            b = f.read(1024 * 1024)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def checksums(path):
    return {
        'md5': _hash_file(path, 'md5'),
        'sha1': _hash_file(path, 'sha1'),
        'sha256': _hash_file(path, 'sha256'),
    }


TERMINALS = ['gnome-terminal', 'konsole', 'xfce4-terminal', 'mate-terminal',
             'x-terminal-emulator', 'xterm', 'foot', 'alacritty', 'kitty', 'st',
             'lxterminal']


def find_terminal():
    env = os.environ.get('HPC_FILES_TERMINAL')
    if env:
        return env.split()
    for t in TERMINALS:
        p = shutil.which(t)
        if p:
            return [p]
    return None


def open_in_terminal(path):
    t = find_terminal()
    if not t:
        return False
    exe = os.path.basename(t[0])
    if exe in ('gnome-terminal', 'konsole', 'xfce4-terminal', 'mate-terminal',
               'lxterminal'):
        cmd = t + ['--working-directory=' + path]
    else:
        cmd = list(t)
    try:
        subprocess.Popen(cmd, cwd=path, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        return True
    except Exception:
        return False


_SKIP_FS = {'tmpfs', 'devtmpfs', 'devpts', 'proc', 'sysfs', 'cgroup', 'cgroup2',
            'pstore', 'securityfs', 'debugfs', 'tracefs', 'fusectl', 'configfs',
            'mqueue', 'hugetlbfs', 'bpf', 'autofs', 'rpc_pipefs', 'nsfs',
            'squashfs', 'ramfs', 'efivarfs', 'binfmt_misc'}


def list_mounts():
    """Return [(mountpoint, label, total, used, free)] for real filesystems."""
    out = []
    seen = set()
    try:
        with open('/proc/mounts', 'r', encoding='utf-8', errors='replace') as f:
            lines = f.read().splitlines()
    except Exception:
        return out
    for line in lines:
        parts = line.split()
        if len(parts) < 3:
            continue
        dev, mnt, fstype = parts[0], parts[1], parts[2]
        mnt = mnt.replace('\\040', ' ')
        if mnt in seen or fstype in _SKIP_FS:
            continue
        if mnt.startswith(('/proc', '/sys', '/dev', '/run')):
            continue
        if mnt in ('/boot/efi', '/sdcard', '/var/tmp'):
            continue
        if not (dev.startswith('/dev/') or dev.startswith('/storage')
                or mnt in ('/', '/data', '/home')):
            continue
        try:
            st = os.statvfs(mnt)
        except Exception:
            continue
        total = st.f_blocks * st.f_frsize
        if total <= 0:
            continue
        seen.add(mnt)
        label = 'System' if mnt == '/' else mnt
        used = total - st.f_bavail * st.f_frsize
        out.append((mnt, label, total, used, st.f_bavail * st.f_frsize))
    out.sort(key=lambda x: x[0])
    return out
