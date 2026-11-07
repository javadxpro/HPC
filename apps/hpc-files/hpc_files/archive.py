# -*- coding: utf-8 -*-
"""Archive support: list / extract / create / modify.

stdlib first (zip, tar, gzip/bz2/lzma); 7z via py7zr or the 7z CLI;
rar via unrar CLI. GTK-free on purpose (testable headless).
"""
import os
import re
import shutil
import subprocess
import tarfile
import time
import zipfile


class Entry(object):
    __slots__ = ('name', 'size', 'is_dir', 'mtime')

    def __init__(self, name, size, is_dir, mtime):
        self.name = name
        self.size = size
        self.is_dir = is_dir
        self.mtime = mtime


def detect_kind(path):
    p = path.lower()
    if p.endswith('.tar.gz') or p.endswith('.tgz'):
        return 'tar.gz'
    if p.endswith('.tar.bz2') or p.endswith('.tbz2'):
        return 'tar.bz2'
    if p.endswith('.tar.xz') or p.endswith('.txz'):
        return 'tar.xz'
    if p.endswith('.tar'):
        return 'tar'
    if p.endswith('.zip'):
        return 'zip'
    if p.endswith('.7z'):
        return '7z'
    if p.endswith('.rar'):
        return 'rar'
    if p.endswith('.gz'):
        return 'gz'
    if p.endswith('.bz2'):
        return 'bz2'
    if p.endswith('.xz'):
        return 'xz'
    return None


def is_archive(path):
    return detect_kind(path) is not None


def _strip(name):
    return name[2:] if name.startswith('./') else name


def _safe_join(dest, name):
    """Join with zip-slip protection."""
    dest = os.path.realpath(dest)
    target = os.path.realpath(os.path.join(dest, name))
    if target != dest and not target.startswith(dest + os.sep):
        raise ValueError('unsafe path in archive: %s' % name)
    return target


def _find_bin(names):
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    return None


# ---------------------------------------------------------------- listing

def _list_zip(path, password):
    zf = zipfile.ZipFile(path)
    entries = []
    if password:
        try:
            zf.setpassword(password.encode('utf-8'))
        except Exception:
            pass
    for info in zf.infolist():
        name = _strip(info.filename)
        if not name:
            continue
        dt = info.date_time
        entries.append(Entry(
            name, info.file_size, info.filename.endswith('/'),
            time.mktime(dt + (0, 0, -1)) if dt else 0))
    return 'zip', entries, zf


def _list_tar(path):
    tf = tarfile.open(path)
    entries = []
    for m in tf.getmembers():
        name = _strip(m.name)
        if not name:
            continue
        entries.append(Entry(name, m.size, m.isdir(), m.mtime))
    kind = 'tar'
    try:
        with open(path, 'rb') as fh:
            magic = fh.read(6)
        if magic[:2] == b'\x1f\x8b':
            kind = 'tar.gz'
        elif magic[:6] == b'\xfd7zXZ\x00':
            kind = 'tar.xz'
        elif magic[:3] == b'BZh':
            kind = 'tar.bz2'
    except Exception:
        pass
    return kind, entries, tf


def _list_7z(path):
    try:
        import py7zr
        a = py7zr.SevenZipFile(path)
        entries = []
        for f in a.files.values():
            name = f.get('filename', '')
            entries.append(Entry(
                name, f.get('uncompressed', 0) or 0,
                bool(f.get('is_dir', False)), f.get('create_time', 0) or 0))
        return '7z', entries, a
    except ImportError:
        pass
    bin7z = _find_bin(('7z', '7za', '7zr', '7zz'))
    if bin7z:
        out = subprocess.run([bin7z, 'l', '-slt', path],
                             capture_output=True, text=True, timeout=120).stdout
        entries = []
        cur = None
        for line in out.splitlines():
            line = line.strip()
            if line.startswith('Path ='):
                if cur is not None and cur.get('p'):
                    entries.append(Entry(
                        cur['p'], int(cur.get('s') or 0),
                        cur['p'].endswith('/'), cur.get('t', 0)))
                cur = {'p': line[6:].strip()}
            elif line.startswith('Size =') and cur is not None:
                cur['s'] = line[6:].strip()
            elif line.startswith('Date/Time =') and cur is not None:
                try:
                    cur['t'] = int(time.mktime(
                        time.strptime(line[11:].strip()[:19],
                                      '%Y-%m-%d %H:%M:%S')))
                except Exception:
                    pass
        if cur is not None and cur.get('p'):
            entries.append(Entry(
                cur['p'], int(cur.get('s') or 0),
                cur['p'].endswith('/'), cur.get('t', 0)))
        return '7z', entries, None
    raise RuntimeError('7z support not available (install 7zip or py7zr)')


def _list_rar(path):
    binunrar = _find_bin(('unrar',))
    if not binunrar:
        raise RuntimeError('rar support not available (install unrar)')
    out = subprocess.run([binunrar, 'l', path],
                         capture_output=True, text=True, timeout=120).stdout
    entries = []
    pat = re.compile(
        r'^\s*[\d,\-]+\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s+(.*\S)\s*$')
    for line in out.splitlines():
        m = pat.match(line)
        if m:
            name = m.group(1)
            entries.append(Entry(name, 0,
                                 name.endswith('\\') or name.endswith('/'), 0))
    if not entries:
        raise RuntimeError('could not list rar file')
    return 'rar', entries, None


def _list_single(path, kind):
    base = os.path.basename(path)
    for ext in ('.gz', '.bz2', '.xz'):
        if base.lower().endswith(ext):
            base = base[:-len(ext)]
            break
    return kind, [Entry(base, 0, False, os.path.getmtime(path))], None


def list_archive(path, password=None):
    """Return (kind, entries, handle). Close handle if it has .close()."""
    kind = detect_kind(path)
    if kind == 'zip':
        return _list_zip(path, password)
    if kind in ('tar', 'tar.gz', 'tar.bz2', 'tar.xz'):
        return _list_tar(path)
    if kind == '7z':
        return _list_7z(path)
    if kind == 'rar':
        return _list_rar(path)
    if kind in ('gz', 'bz2', 'xz'):
        # a .gz may also be a gzipped tar
        if kind == 'gz':
            try:
                tf = tarfile.open(path)
                tf.close()
                return _list_tar(path)
            except Exception:
                pass
        return _list_single(path, kind)
    raise ValueError('not a supported archive')


# ---------------------------------------------------------------- extract

def _extract_zip(path, dest, password=None, members=None, progress=None):
    zf = zipfile.ZipFile(path)
    if password:
        zf.setpassword(password.encode('utf-8'))
    sel = []
    for info in zf.infolist():
        name = _strip(info.filename)
        if not name:
            continue
        if members is not None and name not in members:
            continue
        sel.append((info, name))
    total = len(sel)
    for i, (info, name) in enumerate(sel):
        if progress:
            progress(i, total, name)
        target = _safe_join(dest, name)
        if info.filename.endswith('/'):
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with zf.open(info) as src, open(target, 'wb') as out:
            shutil.copyfileobj(src, out, 1024 * 1024)
    return total


def _extract_tar(path, dest, members=None, progress=None):
    tf = tarfile.open(path)
    sel = []
    for m in tf.getmembers():
        name = _strip(m.name)
        if not name:
            continue
        if members is not None and name not in members:
            continue
        sel.append((m, name))
    total = len(sel)
    for i, (m, name) in enumerate(sel):
        if progress:
            progress(i, total, name)
        target = _safe_join(dest, name)
        if m.isdir():
            os.makedirs(target, exist_ok=True)
        elif m.isfile():
            os.makedirs(os.path.dirname(target), exist_ok=True)
            f = tf.extractfile(m)
            if f is None:
                continue
            with f, open(target, 'wb') as out:
                shutil.copyfileobj(f, out, 1024 * 1024)
        elif m.issym():
            os.makedirs(os.path.dirname(target), exist_ok=True)
            try:
                os.symlink(m.linkname, target)
            except FileExistsError:
                pass
    return total


def _extract_7z(path, dest, password=None):
    try:
        import py7zr
        with py7zr.SevenZipFile(path, 'r') as a:
            if password:
                a.setpassword(password)
            a.extractall(path=dest)
        return 1
    except ImportError:
        pass
    bin7z = _find_bin(('7z', '7za', '7zr', '7zz'))
    if not bin7z:
        raise RuntimeError('7z support not available')
    cmd = [bin7z, 'x', '-y', '-o' + dest, path]
    if password:
        cmd.append('-p' + password)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if r.returncode not in (0, 1):
        raise RuntimeError('7z extract failed: '
                           + (r.stderr or r.stdout)[-300:])
    return 1


def _extract_rar(path, dest, password=None):
    binunrar = _find_bin(('unrar',))
    if not binunrar:
        raise RuntimeError('rar support not available (install unrar)')
    cmd = [binunrar, 'x', '-y', path, dest + os.sep]
    if password:
        cmd.insert(3, '-p' + password)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        raise RuntimeError('unrar failed: ' + (r.stderr or r.stdout)[-300:])
    return 1


def _extract_single(path, dest):
    import bz2
    import gzip
    import lzma
    base = os.path.basename(path)
    for ext in ('.gz', '.bz2', '.xz'):
        if base.lower().endswith(ext):
            base = base[:-len(ext)]
            break
    target = _safe_join(dest, base or 'data')
    opener = {'gz': gzip.open, 'bz2': bz2.open, 'xz': lzma.open}[detect_kind(path)]
    with opener(path, 'rb') as src, open(target, 'wb') as out:
        shutil.copyfileobj(src, out, 1024 * 1024)
    return 1


def extract(path, dest, password=None, members=None, progress=None):
    """Extract an archive (or selected members) into dest. Returns count."""
    kind = detect_kind(path)
    os.makedirs(dest, exist_ok=True)
    if kind == 'zip':
        return _extract_zip(path, dest, password, members, progress)
    if kind in ('tar', 'tar.gz', 'tar.bz2', 'tar.xz'):
        return _extract_tar(path, dest, members, progress)
    if kind == '7z':
        return _extract_7z(path, dest, password)
    if kind == 'rar':
        return _extract_rar(path, dest, password)
    if kind in ('gz', 'bz2', 'xz'):
        if kind == 'gz':
            try:
                tf = tarfile.open(path)
                tf.close()
                return _extract_tar(path, dest, members, progress)
            except Exception:
                pass
        return _extract_single(path, dest)
    raise ValueError('not a supported archive')


# ---------------------------------------------------------------- create

def _add_tree(zf, src, arcname):
    if os.path.isfile(src):
        zf.write(src, arcname)
    else:
        parent = os.path.dirname(src.rstrip('/')) or '.'
        for root, dirs, files in os.walk(src):
            rel = os.path.relpath(root, parent)
            for d in dirs:
                zf.write(os.path.join(root, d),
                         os.path.join(rel, d) + '/')
            for fn in files:
                zf.write(os.path.join(root, fn), os.path.join(rel, fn))


def create(dest, sources, fmt, password=None):
    """Create an archive. fmt: zip | tar | tar.gz | tar.xz | 7z | gz."""
    out_path = dest
    e = {'zip': '.zip', 'tar': '.tar', 'tar.gz': '.tar.gz',
         'tar.xz': '.tar.xz', '7z': '.7z', 'gz': '.gz'}.get(fmt)
    if e and not out_path.lower().endswith(e):
        out_path += e
    if fmt == 'zip':
        if password:
            try:
                import pyzipper
            except ImportError:
                raise RuntimeError(
                    'password-protected zip needs pyzipper (pip install pyzipper)')
            zf = pyzipper.AESZipFile(out_path, 'w',
                                     compression=pyzipper.WZ_AES)
            zf.setpassword(password.encode('utf-8'))
            try:
                for s in sources:
                    _add_tree(zf, s, os.path.basename(s.rstrip('/')))
            finally:
                zf.close()
        else:
            with zipfile.ZipFile(out_path, 'w',
                                 zipfile.ZIP_DEFLATED) as zf:
                for s in sources:
                    _add_tree(zf, s, os.path.basename(s.rstrip('/')))
    elif fmt in ('tar', 'tar.gz', 'tar.xz'):
        mode = {'tar': 'w', 'tar.gz': 'w:gz', 'tar.xz': 'w:xz'}[fmt]
        with tarfile.open(out_path, mode) as tf:
            for s in sources:
                tf.add(s, arcname=os.path.basename(s.rstrip('/')))
    elif fmt == '7z':
        bin7z = _find_bin(('7z', '7za', '7zr'))
        if not bin7z:
            raise RuntimeError('7z not available')
        cmd = [bin7z, 'a', out_path] + list(sources)
        if password:
            cmd.append('-p' + password)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            raise RuntimeError('7z create failed: '
                               + (r.stderr or r.stdout)[-300:])
    elif fmt == 'gz':
        import gzip
        if len(sources) == 1 and os.path.isfile(sources[0]):
            s = sources[0]
            with open(s, 'rb') as fsrc, gzip.open(out_path, 'wb') as fdst:
                shutil.copyfileobj(fsrc, fdst, 1024 * 1024)
        else:
            # several sources: gzipped tar
            tar_path = out_path + '.tar'
            with tarfile.open(tar_path, 'w') as tf:
                for s in sources:
                    tf.add(s, arcname=os.path.basename(s.rstrip('/')))
            with open(tar_path, 'rb') as fsrc, \
                    gzip.open(out_path, 'wb') as fdst:
                shutil.copyfileobj(fsrc, fdst, 1024 * 1024)
            os.remove(tar_path)
    else:
        raise ValueError('unsupported format: %s' % fmt)
    return out_path


def zip_has_password(path):
    try:
        zf = zipfile.ZipFile(path)
        try:
            for info in zf.infolist():
                if info.flag_bits & 0x1:
                    return True
            return False
        finally:
            zf.close()
    except Exception:
        return False


# ---------------------------------------------------------------- modify (zip)

def _open_zip(path, password):
    if password:
        try:
            import pyzipper
            zf = pyzipper.AESZipFile(path)
            zf.setpassword(password.encode('utf-8'))
            return zf
        except ImportError:
            pass
        zf = zipfile.ZipFile(path)
        zf.setpassword(password.encode('utf-8'))
        return zf
    return zipfile.ZipFile(path)


def _new_zip(path, password):
    if password:
        try:
            import pyzipper
            zf = pyzipper.AESZipFile(path, 'w', compression=pyzipper.WZ_AES)
            zf.setpassword(password.encode('utf-8'))
            return zf
        except ImportError:
            pass
    return zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED)


def _rewrite_zip(path, password, keep):
    """keep(info, name) -> (new_name or None). None drops the entry."""
    tmp = path + '.hpc-tmp.zip'
    src = _open_zip(path, password)
    dst = _new_zip(tmp, password)
    try:
        for info in src.infolist():
            name = _strip(info.filename)
            r = keep(info, name)
            if r is None:
                continue
            if info.filename.endswith('/'):
                dst.writestr(r if isinstance(r, str) else info.filename, b'')
            else:
                dst.writestr(r if isinstance(r, str) else info.filename,
                             src.read(info))
        dst.close()
    except Exception:
        for z in (dst, src):
            try:
                z.close()
            except Exception:
                pass
        try:
            os.remove(tmp)
        except Exception:
            pass
        raise
    src.close()
    os.replace(tmp, path)


def delete_zip_members(path, members, password=None):
    _rewrite_zip(path, password,
                 lambda info, name: None if name in members else info.filename)


def rename_zip_member(path, old, new, password=None):
    def keep(info, name):
        if name == old:
            return new
        return info.filename
    _rewrite_zip(path, password, keep)
