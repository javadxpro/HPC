# -*- coding: utf-8 -*-
"""All dialogs for HPC Files (pure GTK4, no libadwaita dependency)."""
import os

from gi.repository import Gtk, Gio, GLib, Gdk, GdkPixbuf, Pango

from . import utils


def title_bar(hb, text):
    """GTK4-compatible header bar (new set_show_title_buttons /
    old set_show_close_button; set_title_widget needs >=4.8)."""
    if hasattr(hb, 'set_title_widget'):
        hb.set_title_widget(Gtk.Label(label=text))
    else:
        hb.set_title(text)
    if hasattr(hb, 'set_show_title_buttons'):
        hb.set_show_title_buttons(True)
    elif hasattr(hb, 'set_show_close_button'):
        hb.set_show_close_button(True)
    return hb


class Dialog(Gtk.Window):
    """A small modal window: headerbar + content + action buttons."""

    def __init__(self, parent, title, width=460):
        super().__init__()
        self.set_transient_for(parent)
        self.set_modal(True)
        self.set_title(title)
        self.set_default_size(width, -1)
        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER_ON_PARENT)
        hb = Gtk.HeaderBar()
        title_bar(hb, title)
        self.set_titlebar(hb)
        self.content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        for m in ('top', 'bottom', 'start', 'end'):
            getattr(self.content, 'set_margin_' + m)(12)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        body.append(self.content)
        self.buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.buttons.set_halign(Gtk.Align.END)
        self.buttons.set_hexpand(True)
        body.append(self.buttons)
        self.set_child(body)

    def button(self, label, cb, suggested=False):
        b = Gtk.Button(label=label)
        if suggested:
            b.add_css_class('suggested-action')
            b.set_can_default(True)

        def _clicked(*_):
            try:
                cb()
            except Exception:
                pass
            self.close()
        b.connect('clicked', _clicked)
        self.buttons.append(b)
        if suggested:
            b.grab_default()
        return b


# ------------------------------------------------------------- simple ones

def prompt(parent, title, message, default_text='', ok_label='OK', cb=None):
    d = Dialog(parent, title, 420)
    lbl = Gtk.Label(label=message)
    lbl.set_xalign(0.0)
    d.content.append(lbl)
    e = Gtk.Entry()
    e.set_text(default_text)
    d.content.append(e)

    def go():
        t = e.get_text().strip()
        if t and cb:
            cb(t)
        d.close()
    d.button('Cancel', d.close)
    d.button(ok_label, go, suggested=True)
    d.present()


def confirm(parent, message, cb, ok_label='OK'):
    d = Dialog(parent, 'Confirm', 420)
    lbl = Gtk.Label(label=message)
    lbl.set_xalign(0.0)
    lbl.set_line_wrap(True)
    d.content.append(lbl)
    d.button('Cancel', d.close)
    d.button(ok_label, cb, suggested=True)
    d.present()


def password_dialog(parent, message, cb):
    d = Dialog(parent, 'Password', 420)
    lbl = Gtk.Label(label=message)
    lbl.set_xalign(0.0)
    d.content.append(lbl)
    e = Gtk.Entry()
    e.set_visibility(False)
    e.set_placeholder_text('Password')
    d.content.append(e)

    def go():
        cb(e.get_text())
        d.close()
    d.button('Cancel', d.close)
    d.button('OK', go, suggested=True)
    d.present()


def goto_dialog(parent, cb):
    d = Dialog(parent, 'Go to', 440)
    e = Gtk.Entry()
    e.set_placeholder_text('/path/to/folder  or  /path/a.zip::inner')
    d.content.append(e)

    def go():
        t = e.get_text().strip() or '/'
        cb(t)
        d.close()
    d.button('Cancel', d.close)
    d.button('Go', go, suggested=True)
    d.present()


# ------------------------------------------------------------- properties

def _perm_str(mode):
    s = ''
    for shift in (6, 3, 0):
        s += 'r' if mode & (0o4 << shift) else '-'
        s += 'w' if mode & (0o2 << shift) else '-'
        s += 'x' if mode & (0o1 << shift) else '-'
    return s


def props_dialog(parent, path, is_dir, pane):
    d = Dialog(parent, 'Properties', 480)
    grid = Gtk.Grid()
    grid.set_row_spacing(6)
    grid.set_column_spacing(12)

    def add(label, value):
        r = grid.get_n_rows()
        l = Gtk.Label(label=label)
        l.set_xalign(0.0)
        l.add_css_class('dim-label')
        v = Gtk.Label(label=value)
        v.set_xalign(0.0)
        v.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        v.set_hexpand(True)
        v.set_selectable(True)
        grid.attach(l, 0, r, 1, 1)
        grid.attach(v, 1, r, 1, 1)

    add('Name', os.path.basename(path.rstrip('/')) or '/')
    add('Location', os.path.dirname(path) or '/')
    try:
        st = os.stat(path)
        add('Size', utils.human_size(st.st_size) if not is_dir else '— (folder)')
        add('Modified', utils.fmt_time(st.st_mtime))
        add('Permissions', oct(st.st_mode & 0o7777)[2:] +
            '   ' + _perm_str(st.st_mode))
        add('UID / GID', '%s / %s' % (st.st_uid, st.st_gid))
    except Exception as e:
        add('Error', str(e))
    try:
        info = Gio.File.new_for_path(path).query_info(
            'standard::content-type', None, None)
        ct = info.get_content_type()
        if ct:
            try:
                desc = Gio.content_type_get_description(ct)
            except Exception:
                desc = ct
            add('Type', (desc or ct))
    except Exception:
        pass
    d.content.append(grid)

    if not is_dir and os.path.isfile(path):
        ext = os.path.splitext(path)[1].lower()
        if ext in utils.IMAGE_EXTS:
            try:
                pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, 320, 320, True)
                img = Gtk.Image.new_from_paintable(Gdk.Texture.for_pixbuf(pb))
                img.set_halign(Gtk.Align.CENTER)
                d.content.append(img)
            except Exception:
                pass
        else:
            try:
                text, enc, trunc = utils.read_text(path, limit=64 * 1024)
                if text.strip() and '\x00' not in text[:2000]:
                    sw = Gtk.ScrolledWindow()
                    sw.set_size_request(-1, 180)
                    tv = Gtk.TextView()
                    tv.set_editable(False)
                    tv.set_cursor_visible(False)
                    tv.set_monospace(True)
                    tv.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
                    tv.get_buffer().set_text(text[:8000] +
                                              ('\n… (truncated)' if trunc else ''))
                    sw.set_child(tv)
                    d.content.append(sw)
            except Exception:
                pass
        cbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        cbox.append(Gtk.Label(label='Checksums:'))
        csw = Gtk.ScrolledWindow()
        csw.set_size_request(-1, 90)
        cview = Gtk.TextView()
        cview.set_editable(False)
        cview.set_monospace(True)
        cview.set_cursor_visible(False)
        csw.set_child(cview)
        cbox.append(csw)
        cbtn = Gtk.Button(label='Compute')

        def compute(*_):
            def worker():
                try:
                    res = utils.checksums(path)
                except Exception as e:
                    res = {'md5': str(e), 'sha1': '-', 'sha256': '-'}

                def put():
                    cview.get_buffer().set_text(
                        'MD5:    %s\nSHA1:   %s\nSHA256: %s' % (
                            res['md5'], res['sha1'], res['sha256']))
                    return False
                GLib.idle_add(put)
            GLib.Thread.new(None, worker, None, None)
        cbtn.connect('clicked', compute)
        cbox.append(cbtn)
        d.content.append(cbox)
    d.button('Close', d.close)
    d.present()


# ------------------------------------------------------------- permissions

def chmod_dialog(parent, paths, on_done):
    try:
        mode = os.stat(paths[0]).st_mode & 0o777
    except Exception as e:
        return
    d = Dialog(parent, 'Permissions', 420)
    bits = ((0o400, 0o200, 0o100), (0o040, 0o020, 0o004),
            (0o004, 0o002, 0o001))
    grid = Gtk.Grid()
    grid.set_row_spacing(6)
    grid.set_column_spacing(14)
    for j, who in enumerate(('Owner', 'Group', 'Others')):
        l = Gtk.Label(label=who)
        grid.attach(l, j + 1, 0, 1, 1)
    checks = {}
    for i, perm in enumerate(('Read', 'Write', 'Execute')):
        l = Gtk.Label(label=perm)
        l.set_xalign(0.0)
        grid.attach(l, 0, i + 1, 1, 1)
        for j in range(3):
            c = Gtk.CheckButton()
            c.set_active(bool(mode & bits[i][j]))
            checks[(i, j)] = c
            grid.attach(c, j + 1, i + 1, 1, 1)
    d.content.append(grid)
    obox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    obox.append(Gtk.Label(label='Octal:'))
    octl = Gtk.Entry()
    octl.set_text(oct(mode)[2:].zfill(3))
    obox.append(octl)
    d.content.append(obox)

    def apply():
        m = 0
        for i in range(3):
            for j in range(3):
                if checks[(i, j)].get_active():
                    m |= bits[i][j]
        try:
            m = int(octl.get_text(), 8) & 0o777
        except Exception:
            pass
        err = None
        for p in paths:
            try:
                os.chmod(p, m)
            except Exception as e:
                err = str(e)
        on_done(err)
    d.button('Cancel', d.close)
    d.button('Apply', apply, suggested=True)
    d.present()


# ------------------------------------------------------------- bulk rename

def bulk_rename_dialog(parent, items, on_done):
    d = Dialog(parent, 'Bulk rename (%d files)' % len(items), 520)

    def entry_row(label, placeholder=''):
        l = Gtk.Label(label=label)
        l.set_xalign(0.0)
        e = Gtk.Entry()
        e.set_placeholder_text(placeholder)
        d.content.append(l)
        d.content.append(e)
        return e

    e_find = entry_row('Find', 'text to find')
    e_rep = entry_row('Replace with')
    e_pre = entry_row('Prefix (added to the start)')
    e_suf = entry_row('Suffix (added to the end)')
    sw = Gtk.ScrolledWindow()
    sw.set_size_request(-1, 160)
    tv = Gtk.TextView()
    tv.set_editable(False)
    tv.set_monospace(True)
    tv.set_cursor_visible(False)
    sw.set_child(tv)
    d.content.append(sw)
    plan = []

    def update():
        plan.clear()
        lines = []
        for it in items:
            new = it.name
            f = e_find.get_text()
            r = e_rep.get_text()
            if f:
                new = new.replace(f, r)
            new = e_pre.get_text() + new + e_suf.get_text()
            plan.append((it.path, new))
            lines.append('%s  \u2192  %s' % (it.name, new))
        tv.get_buffer().set_text('\n'.join(lines))

    for e in (e_find, e_rep, e_pre, e_suf):
        e.connect('changed', lambda *_: update())
    update()

    def apply():
        def worker():
            n_ok = 0
            n_skip = 0
            err = None
            for old_path, new in plan:
                if not new or new in ('.', '..') or new.startswith('/'):
                    n_skip += 1
                    continue
                target = os.path.join(os.path.dirname(old_path), new)
                try:
                    if os.path.exists(target):
                        n_skip += 1
                        continue
                    os.rename(old_path, target)
                    n_ok += 1
                except Exception as e:
                    err = str(e)

            def done():
                on_done(n_ok, n_skip, err)
                return False
            GLib.idle_add(done)
        GLib.Thread.new(None, worker, None, None)
        d.close()
    d.button('Cancel', d.close)
    d.button('Rename', apply, suggested=True)
    d.present()


# ------------------------------------------------------------- checksums

def checksum_dialog(parent, paths):
    d = Dialog(parent, 'Checksums', 520)
    sw = Gtk.ScrolledWindow()
    sw.set_size_request(-1, 220)
    tv = Gtk.TextView()
    tv.set_editable(False)
    tv.set_monospace(True)
    tv.set_cursor_visible(False)
    buf = tv.get_buffer()
    sw.set_child(tv)
    d.content.append(sw)

    def worker():
        for p in paths:
            try:
                res = utils.checksums(p)
            except Exception as e:
                res = {'md5': 'error: %s' % e, 'sha1': '-', 'sha256': '-'}
            line = ('%s\n    md5:    %s\n    sha1:   %s\n    sha256: %s\n' % (
                os.path.basename(p), res['md5'], res['sha1'], res['sha256']))

            def put(l=line):
                buf.insert_at_end(l)
                return False
            GLib.idle_add(put)
    GLib.Thread.new(None, worker, None, None)
    d.button('Close', d.close)
    d.present()


# ------------------------------------------------------------- extract / compress

def extract_dialog(parent, default_dir, need_pwd, cb):
    d = Dialog(parent, 'Extract archive', 460)
    l1 = Gtk.Label(label='Extract to:')
    l1.set_xalign(0.0)
    e1 = Gtk.Entry()
    e1.set_text(default_dir)
    l2 = Gtk.Label(label='Password (if any):')
    l2.set_xalign(0.0)
    e2 = Gtk.Entry()
    e2.set_visibility(False)
    d.content.append(l1)
    d.content.append(e1)
    d.content.append(l2)
    d.content.append(e2)

    def go():
        target = e1.get_text().strip() or default_dir
        cb(target, e2.get_text())
        d.close()
    d.button('Cancel', d.close)
    d.button('Extract', go, suggested=True)
    d.present()


def compress_dialog(parent, default_name, cb):
    d = Dialog(parent, 'Create archive', 460)
    l1 = Gtk.Label(label='Archive name:')
    l1.set_xalign(0.0)
    e1 = Gtk.Entry()
    e1.set_text(default_name)
    l2 = Gtk.Label(label='Format:')
    l2.set_xalign(0.0)
    combo = Gtk.ComboBoxText()
    for f in ('zip', 'tar.gz', 'tar.xz', 'tar', 'gz', '7z'):
        combo.append_text(f)
    combo.set_active(0)
    l3 = Gtk.Label(label='Password (zip only):')
    l3.set_xalign(0.0)
    e2 = Gtk.Entry()
    e2.set_visibility(False)
    d.content.append(l1)
    d.content.append(e1)
    d.content.append(l2)
    d.content.append(combo)
    d.content.append(l3)
    d.content.append(e2)

    def go():
        name = e1.get_text().strip()
        if not name:
            return
        fmt = combo.get_active_text()
        suffix = {'zip': '.zip', 'tar.gz': '.tar.gz', 'tar.xz': '.tar.xz',
                  'tar': '.tar', 'gz': '.gz', '7z': '.7z'}[fmt]
        if not name.endswith(suffix):
            name += suffix
        cb(name, fmt, e2.get_text())
        d.close()
    d.button('Cancel', d.close)
    d.button('Create', go, suggested=True)
    d.present()


# ------------------------------------------------------------- preferences

def prefs_dialog(parent, app):
    d = Dialog(parent, 'Preferences', 500)
    g = Gtk.Grid()
    g.set_row_spacing(10)
    g.set_column_spacing(12)

    def row(label, widget, r):
        l = Gtk.Label(label=label)
        l.set_xalign(0.0)
        g.attach(l, 0, r, 1, 1)
        g.attach(widget, 1, r, 1, 1)

    chk1 = Gtk.CheckButton(label='Confirm before delete')
    chk1.set_active(bool(app.prefs.get('confirm_delete', True)))
    row('Delete', chk1, 0)
    chk2 = Gtk.CheckButton(label='Show hidden files (dotfiles)')
    chk2.set_active(bool(app.prefs.get('show_hidden', False)))
    row('Hidden files', chk2, 1)
    chk3 = Gtk.CheckButton(label='Show modification dates in the list')
    chk3.set_active(bool(app.prefs.get('show_date', True)))
    row('List', chk3, 2)
    combo_ext = Gtk.ComboBoxText()
    for t in ('Next to the archive', 'Downloads folder',):
        combo_ext.append_text(t)
    combo_ext.set_active(0 if app.prefs.get('extract_to', 'parent') == 'parent'
                         else 1)
    row('Extract to', combo_ext, 3)
    entry_term = Gtk.Entry()
    entry_term.set_text(app.prefs.get('terminal', ''))
    entry_term.set_placeholder_text('e.g. /usr/bin/gnome-terminal')
    row('Terminal command', entry_term, 4)
    combo_theme = Gtk.ComboBoxText()
    for t in ('Follow system', 'Light', 'Dark'):
        combo_theme.append_text(t)
    combo_theme.set_active({'auto': 0, 'light': 1, 'dark': 2}[
        app.prefs.get('theme', 'auto')])
    row('Theme', combo_theme, 5)
    d.content.append(g)

    def save():
        app.prefs.update({
            'confirm_delete': chk1.get_active(),
            'show_hidden': chk2.get_active(),
            'show_date': chk3.get_active(),
            'extract_to': 'parent' if combo_ext.get_active() == 0 else 'downloads',
            'terminal': entry_term.get_text().strip(),
            'theme': ('auto', 'light', 'dark')[combo_theme.get_active() or 0],
        })
        if app.prefs.get('terminal'):
            import os as _os
            _os.environ['HPC_FILES_TERMINAL'] = app.prefs['terminal']
        utils.save_json('prefs.json', app.prefs)
        app.apply_theme()
        app.sync_actions_state()
        for p in (app.pane_l, app.pane_r):
            if p is not None:
                p.refresh()
        d.close()
    d.button('Cancel', d.close)
    d.button('Save', save, suggested=True)
    d.present()


# ------------------------------------------------------------- open with

def open_with_dialog(parent, path):
    f = Gio.File.new_for_path(path)
    uri = f.get_uri()
    try:
        apps = (Gio.AppInfo.get_recommended_for_uri(uri, None) or
                Gio.AppInfo.get_all_for_uri(uri))
    except Exception:
        apps = []
    if not apps:
        return
    d = Dialog(parent, 'Open with', 380)
    lst = Gtk.ListBox()
    lst.set_selection_mode(Gtk.SelectionMode.SINGLE)
    for a in apps[:20]:
        r = Gtk.ListBoxRow()
        b = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        img = Gtk.Image()
        try:
            ic = a.get_icon()
            if ic:
                img.set_from_gicon(ic, 20)
        except Exception:
            pass
        b.append(img)
        l = Gtk.Label(label=a.get_name() or 'Application')
        l.set_xalign(0.0)
        b.append(l)
        r.set_child(b)

        def act(app=a, p=path, r=r):
            try:
                app.launch([Gio.File.new_for_path(p)], None)
            except Exception:
                pass
            d.close()
        r.connect('activated', lambda *_: act())
        lst.append(r)
    sw = Gtk.ScrolledWindow()
    sw.set_size_request(-1, 260)
    sw.set_child(lst)
    d.content.append(sw)
    d.button('Cancel', d.close)
    d.present()


# ------------------------------------------------------------- text editor

class EditorWindow(Gtk.Window):
    def __init__(self, parent, path):
        super().__init__()
        self.path = path
        self._dirty = False
        self.set_transient_for(parent)
        self.set_modal(False)
        self.set_default_size(760, 500)
        self.set_title(os.path.basename(path) + ' — HPC Files')
        hb = Gtk.HeaderBar()
        title_bar(hb, os.path.basename(path))
        self.btn_save = Gtk.Button(label='Save')
        self.btn_save.connect('clicked', self.save)
        self.chk_wrap = Gtk.CheckButton(label='Word wrap')
        self.chk_wrap.set_active(True)
        self.chk_wrap.connect('toggled', self._on_wrap)
        hb.pack_end(self.btn_save)
        hb.pack_start(self.chk_wrap)
        self.set_titlebar(hb)
        sw = Gtk.ScrolledWindow()
        self.tv = Gtk.TextView()
        self.tv.set_monospace(True)
        self.tv.set_left_margin(8)
        self.tv.set_right_margin(8)
        self.tv.set_top_margin(8)
        self.tv.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.tv.get_buffer().connect('changed', lambda *_: self._set_dirty(True))
        sw.set_child(self.tv)
        self.set_child(sw)
        self.connect('close-request', self._on_close)

        def worker():
            try:
                text, enc, trunc = utils.read_text(path)
            except Exception as e:
                text, enc, trunc = 'Error: %s' % e, 'utf-8', False

            def put():
                self.tv.get_buffer().set_text(text +
                                               ('\n… (truncated at 2 MB)'
                                                if trunc else ''))
                return False
            GLib.idle_add(put)
        GLib.Thread.new(None, worker, None, None)

    def _set_dirty(self, v):
        self._dirty = v
        base = os.path.basename(self.path)
        self.set_title(('*' if self._dirty else '') + base + ' — HPC Files')

    def _on_wrap(self, chk):
        self.tv.set_wrap_mode(
            Gtk.WrapMode.WORD_CHAR if chk.get_active()
            else Gtk.WrapMode.NONE)

    def save(self):
        b = self.tv.get_buffer()
        s, e = b.get_bounds()
        text = b.get_text(s, e, False)
        try:
            with open(self.path, 'w', encoding='utf-8') as f:
                f.write(text)
            self._set_dirty(False)
        except Exception as ex:
            d = Dialog(self, 'Save failed', 400)
            d.content.append(Gtk.Label(label=str(ex)))
            d.button('OK', d.close)
            d.present()

    def _on_close(self, w):
        if self._dirty:
            d = Dialog(self, 'Discard changes?', 380)
            d.content.append(Gtk.Label(
                label='The document has unsaved changes.\nClose anyway?'))
            d.button('Cancel', d.close)
            d.button('Close anyway', self._force_close)
            d.present()
            return True
        self.destroy()
        return True

    def _force_close(self):
        self._dirty = False
        self.destroy()


def open_editor(parent, path):
    EditorWindow(parent, path).present()


# ------------------------------------------------------------- about

def about_dialog(parent):
    a = Gtk.AboutDialog()
    a.set_transient_for(parent)
    a.set_modal(True)
    a.set_program_name(utils.APP_NAME)
    a.set_version(utils.VERSION)
    a.set_comments('Dual-pane file manager & archive tool for Linux.\n'
                   'HPC project — javadxpro')
    a.set_website(utils.HOMEPAGE)
    a.set_license_type(Gtk.License.GPL_3_0)
    a.set_logo_icon_name('system-file-manager')
    a.present()
