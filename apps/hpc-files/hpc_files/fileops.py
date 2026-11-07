# -*- coding: utf-8 -*-
"""Background file operations with progress + cancel (off the main thread)."""
import os
import threading

from gi.repository import Gio, GLib


def _emit(app, frac, detail=''):
    def _do():
        try:
            app.progress(frac, detail)
        except Exception:
            pass
        return False
    GLib.idle_add(_do)


def _finish(app, on_done, err, cancelled):
    def _do():
        try:
            app.end_op()
        except Exception:
            pass
        try:
            on_done(err, cancelled)
        except Exception:
            pass
        return False
    GLib.idle_add(_do)


def walk_files(root):
    """All regular files under a Gio.File (directory)."""
    out = []

    def rec(f):
        try:
            t = f.query_info('standard::type', None).get_file_type()
        except Exception:
            return
        if t == Gio.FileType.DIRECTORY:
            try:
                en = f.enumerate_children('standard::type', None, None)
            except Exception:
                return
            while True:
                c = en.next_file(None)
                if c is None:
                    break
                rec(c)
        elif t == Gio.FileType.REGULAR:
            out.append(f)

    rec(root)
    return out


def _size(f):
    try:
        return f.query_info('standard::size', None).get_size()
    except Exception:
        return 0


def _copy_one(src, dest, overwrite):
    flags = Gio.FileCopyFlags.PRESERVE_ATTRIBUTES
    if overwrite:
        flags = flags | Gio.FileCopyFlags.OVERWRITE
    src.copy(dest, flags, None)


def _ensure_parent(f):
    p = f.get_parent()
    if p is not None:
        try:
            p.make_directory_with_parents(None)
        except Exception:
            pass


def _delete_recursive(f, cancel):
    try:
        t = f.query_info('standard::type', None).get_file_type()
    except Exception:
        return
    if t == Gio.FileType.DIRECTORY:
        try:
            en = f.enumerate_children('standard::type', None, None)
        except Exception:
            en = None
        if en is not None:
            while True:
                c = en.next_file(None)
                if c is None:
                    break
                if cancel.is_set():
                    return
                _delete_recursive(c, cancel)
    try:
        f.delete(None)
    except Exception:
        pass


def copy_items(app, sources, dest_dir, overwrite, on_done):
    cancel = threading.Event()
    app.begin_op('Copying…', cancel)

    def worker():
        err = None
        cancelled = False
        try:
            dest = Gio.File.new_for_path(dest_dir)
            dest.make_directory_with_parents(None)
            entries = []
            for s in sources:
                sf = Gio.File.new_for_path(s)
                t = sf.query_info('standard::type', None).get_file_type()
                entries.append((sf, t == Gio.FileType.DIRECTORY))
            total = 0
            for sf, is_dir in entries:
                if is_dir:
                    total += sum(_size(f) for f in walk_files(sf))
                else:
                    total += _size(sf)
            done = 0
            for sf, is_dir in entries:
                if cancel.is_set():
                    cancelled = True
                    break
                base = sf.get_basename()
                if is_dir:
                    for f in walk_files(sf):
                        if cancel.is_set():
                            cancelled = True
                            break
                        rel = f.get_path()[len(sf.get_path()) + 1:]
                        tgt = dest.get_child(base).get_child(rel)
                        _ensure_parent(tgt)
                        _copy_one(f, tgt, overwrite)
                        done += _size(f)
                        _emit(app, done / max(total, 1), base)
                    if cancel.is_set():
                        cancelled = True
                        break
                else:
                    tgt = dest.get_child(base)
                    _ensure_parent(tgt)
                    _copy_one(sf, tgt, overwrite)
                    done += _size(sf)
                    _emit(app, done / max(total, 1), base)
        except Exception as e:
            err = str(e)
        _finish(app, on_done, err, cancelled)

    GLib.Thread.new(None, worker, None, None)


def move_items(app, sources, dest_dir, overwrite, on_done):
    cancel = threading.Event()
    app.begin_op('Moving…', cancel)

    def worker():
        err = None
        cancelled = False
        n = len(sources)
        try:
            for i, s in enumerate(sources):
                if cancel.is_set():
                    cancelled = True
                    break
                sf = Gio.File.new_for_path(s)
                dest = Gio.File.new_for_path(dest_dir)
                target = dest.get_child(sf.get_basename())
                try:
                    flags = Gio.FileCopyFlags.PRESERVE_ATTRIBUTES
                    if overwrite:
                        flags = flags | Gio.FileCopyFlags.OVERWRITE
                    sf.move(target, flags, None)
                except Exception:
                    t = sf.query_info('standard::type', None).get_file_type()
                    if t == Gio.FileType.DIRECTORY:
                        for f in walk_files(sf):
                            if cancel.is_set():
                                cancelled = True
                                break
                            rel = f.get_path()[len(sf.get_path()) + 1:]
                            tgt = target.get_child(rel)
                            _ensure_parent(tgt)
                            _copy_one(f, tgt, overwrite)
                        if not cancelled:
                            _delete_recursive(sf, cancel)
                    else:
                        _copy_one(sf, target, overwrite)
                        sf.delete(None)
                _emit(app, (i + 1) / n, os.path.basename(s))
        except Exception as e:
            err = str(e)
        _finish(app, on_done, err, cancelled)

    GLib.Thread.new(None, worker, None, None)


def trash_items(app, paths, on_done):
    cancel = threading.Event()
    app.begin_op('Moving to trash…', cancel)

    def worker():
        err = None
        cancelled = False
        try:
            for i, p in enumerate(paths):
                if cancel.is_set():
                    cancelled = True
                    break
                Gio.File.new_for_path(p).trash(None)
                _emit(app, (i + 1) / len(paths), os.path.basename(p))
        except Exception as e:
            err = str(e)
        _finish(app, on_done, err, cancelled)

    GLib.Thread.new(None, worker, None, None)


def delete_items(app, paths, on_done):
    cancel = threading.Event()
    app.begin_op('Deleting…', cancel)

    def worker():
        err = None
        cancelled = False
        try:
            for i, p in enumerate(paths):
                if cancel.is_set():
                    cancelled = True
                    break
                f = Gio.File.new_for_path(p)
                _delete_recursive(f, cancel)
                _emit(app, (i + 1) / len(paths), os.path.basename(p))
        except Exception as e:
            err = str(e)
        _finish(app, on_done, err, cancelled)

    GLib.Thread.new(None, worker, None, None)
