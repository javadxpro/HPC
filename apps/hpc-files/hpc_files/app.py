# -*- coding: utf-8 -*-
"""HPC Files — application shell: window, sidebar, actions, clipboard."""
import os
import sys
import threading
from pathlib import Path

from gi.repository import Gtk, Gio, GLib, Gdk, Pango

from . import utils
from . import archive as A
from . import fileops
from . import dialogs
from .pane import PaneView


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=utils.APP_ID,
                         flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.pane_l = None
        self.pane_r = None
        self._last = None
        self.clipboard = []
        self._win = None
        self._op_cancel = None
        self._op_title = ''
        self._prog_reveal = None
        self._prog_bar = None
        self._prog_label = None
        self._toast_label = None
        self._toast_reveal = None
        self._toast_to = None
        self._save_to = None
        self.prefs = utils.load_json('prefs.json', {
            'confirm_delete': True,
            'show_hidden': False,
            'sort_key': 'name',
            'sort_desc': False,
            'extract_to': 'parent',
            'theme': 'auto',
            'terminal': '',
            'show_date': True,
        })
        self.state = utils.load_json('state.json', {})
        self.favorites = utils.load_json('favorites.json', [])
        self.recent = utils.load_json('recent.json', [])

    # ------------------------------------------------------------ lifecycle
    def do_activate(self):
        win = self.props.active_window
        if win is None:
            win = MainWindow(self)
        win.present()

    def do_shutdown(self):
        try:
            if self._win is not None:
                self._win.save_state()
        except Exception:
            pass
        utils.save_json('prefs.json', self.prefs)
        utils.save_json('favorites.json', self.favorites)
        utils.save_json('recent.json', self.recent)

    # ------------------------------------------------------------ UI state
    def set_active_pane(self, pane):
        self._last = pane

    def active_pane(self):
        if self._win is None:
            return self.pane_l
        w = self._win.get_focus()
        while w is not None:
            if isinstance(w, PaneView):
                return w
            w = w.get_parent()
        return self._last or self.pane_l

    def apply_theme(self):
        try:
            t = self.prefs.get('theme', 'auto')
            s = Gtk.Settings.get_default()
            if t == 'auto':
                s.unset_property('gtk-application-prefer-dark-theme')
            else:
                s.set_property('gtk-application-prefer-dark-theme',
                               t == 'dark')
        except Exception:
            pass

    def toast(self, text):
        if self._toast_label is None:
            return

        def _do():
            self._toast_label.set_text(str(text))
            self._toast_reveal.set_reveal_child(True)
            if self._toast_to:
                GLib.source_remove(self._toast_to)
            self._toast_to = GLib.timeout_add(
                2500, lambda: (self._toast_reveal.set_reveal_child(False),
                               False)[1])
            return False
        GLib.idle_add(_do)

    def confirm_dangerous(self, message, cb):
        d = dialogs.Dialog(self._win, 'Confirm', 420)
        lbl = Gtk.Label(label=message)
        lbl.set_xalign(0.0)
        dialogs.wrap_label(lbl)
        d.content.append(lbl)
        d.button('Cancel', d.close)
        b = d.button('Delete', cb)
        b.add_css_class('destructive-action')
        d.present()

    def schedule_save(self):
        if self._save_to:
            GLib.source_remove(self._save_to)
        self._save_to = GLib.timeout_add(
            700, lambda: (self._win.save_state() if self._win else None,
                          False)[1])

    # --------------------------------------------------------- op progress
    def begin_op(self, title, cancel_event):
        self._op_cancel = cancel_event
        self._op_title = title

        def _do():
            if self._prog_reveal is not None:
                self._prog_bar.set_fraction(0.0)
                self._prog_label.set_text(title)
                self._prog_reveal.set_reveal_child(True)
            return False
        GLib.idle_add(_do)

    def progress(self, frac, detail=''):
        def _do():
            if self._prog_bar is not None:
                self._prog_bar.set_fraction(max(0.0, min(1.0, frac)))
                if detail:
                    self._prog_label.set_text(
                        '%s %s' % (self._op_title, detail))
            return False
        GLib.idle_add(_do)

    def end_op(self):
        def _do():
            if self._prog_reveal is not None:
                self._prog_reveal.set_reveal_child(False)
            self._op_cancel = None
            return False
        GLib.idle_add(_do)

    # ------------------------------------------------------------ clipboard
    def copy_text_to_clipboard(self, text):
        try:
            # Gtk.Clipboard was removed from GTK4 in 4.16+; the
            # clipboard now lives on the display (Gdk.Clipboard).
            clip = Gdk.Display.get_default().get_clipboard()
            clip.set_text(text)
            self.toast('Copied to clipboard')
        except Exception:
            pass

    def paste_into(self, pane):
        if not self.clipboard:
            return
        dest = pane._real_dir()
        if not dest:
            self.toast('Cannot paste here')
            return
        dest = os.path.realpath(dest)
        for src, _ in self.clipboard:
            sp = os.path.realpath(src)
            if sp == dest or sp.startswith(dest + '/') or \
                    dest.startswith(sp + '/'):
                self.toast('Cannot paste into itself')
                return
        cut = self.clipboard[0][1] == 'cut'
        sources = [p for p, _ in self.clipboard]

        def on_done(err, cancelled):
            if err:
                self.toast('Error: ' + str(err))
            if cut and not cancelled:
                self.clipboard = []
            pane.refresh()
        if cut:
            fileops.move_items(self, sources, dest, True, on_done)
        else:
            fileops.copy_items(self, sources, dest, True, on_done)

    # ----------------------------------------------------------- file ops
    def trash_or_delete(self, items, permanent):
        paths = [it.path for it in items
                 if not it.in_archive and not it.trash]
        if not paths:
            return
        pane = self.active_pane()

        def on_done(err, cancelled):
            if err:
                self.toast('Delete failed: ' + str(err))
            pane.refresh()
        if permanent:
            fileops.delete_items(self, paths, on_done)
        else:
            fileops.trash_items(self, paths, on_done)

    # ---------------------------------------------------------- favorites
    def toggle_favorite(self, path):
        if path in self.favorites:
            self.favorites.remove(path)
            self.toast('Removed from favorites')
        else:
            self.favorites.insert(0, path)
            self.favorites = self.favorites[:50]
            self.toast('Added to favorites')
        utils.save_json('favorites.json', self.favorites)
        if self._win:
            self._win.rebuild_fav()
        return path in self.favorites

    # -------------------------------------------------------------- recent
    def add_recent(self, path):
        if '::' in path or path == '__trash__':
            return
        if os.path.isdir(path):
            return
        if path in self.recent:
            self.recent.remove(path)
        self.recent.insert(0, path)
        self.recent = self.recent[:100]
        utils.save_json('recent.json', self.recent)
        if self._win:
            self._win.rebuild_recent()

    # ------------------------------------------------------------ archives
    def _extract_default(self, archive_path):
        m = self.prefs.get('extract_to', 'parent')
        if m == 'downloads':
            return os.path.join(str(Path.home()), 'Downloads')
        return os.path.dirname(archive_path) or '/'

    def extract_to(self, archive_path, dest, members, password):
        def worker():
            err = None
            n = 0
            try:
                n = A.extract(archive_path, dest, password=password,
                              members=members,
                              progress=lambda i, t, name: self.progress(
                                  i / max(t, 1),
                                  os.path.basename(name)))
            except Exception as e:
                err = str(e)

            def done_cb():
                self.end_op()
                if err:
                    self.toast('Extract failed: ' + err)
                else:
                    self.toast('Extracted %d item(s) to %s' % (n, dest))
                    self.refresh_all(archive_path)
                return False
            GLib.idle_add(done_cb)
        self.begin_op('Extracting…', threading.Event())
        GLib.Thread.new(None, worker, None, None)

    def refresh_all(self, archive_path):
        for p in (self.pane_l, self.pane_r):
            if p is None:
                continue
            if p.arch and p.arch[0] == archive_path:
                p.refresh()
            elif p.path == os.path.dirname(archive_path):
                p.refresh()

    def extract_dialog(self, pane, items):
        archives = {}
        for it in items:
            if it.is_archive:
                archives[it.path] = None
            elif it.in_archive:
                ap, member = it.path.split('::', 1)
                archives.setdefault(ap, []).append(member)
        if not archives:
            self.toast('Nothing to extract')
            return
        first = next(iter(archives))
        default_dir = self._extract_default(first)

        def cb(target, password):
            for ap, members in archives.items():
                self.extract_to(ap, target, members, password)
        dialogs.extract_dialog(self._win, default_dir, False, cb)

    def compress_dialog(self, pane, items):
        def cb(name, fmt, password):
            dest = os.path.join(pane._real_dir() or str(Path.home()), name)

            def worker():
                err = None
                out = dest
                try:
                    out = A.create(dest, [it.path for it in items], fmt,
                                   password) or dest
                except Exception as e:
                    err = str(e)

                def done_cb():
                    self.end_op()
                    if err:
                        self.toast('Compress failed: ' + err)
                    else:
                        self.toast('Created ' + out)
                    pane.refresh()
                    return False
                GLib.idle_add(done_cb)
            self.begin_op('Compressing…', threading.Event())
            GLib.Thread.new(None, worker, None, None)
        default_name = items[0].name if len(items) == 1 else 'archive'
        if len(items) > 1:
            default_name = default_name.rsplit('.', 1)[0]
        dialogs.compress_dialog(self._win, default_name, cb)

    def delete_archive_members(self, pane):
        sel = pane.selected_items()
        if not sel or not pane.arch:
            return
        ap = pane.arch[0]
        if A.detect_kind(ap) != 'zip':
            self.toast('In-archive delete supports zip only')
            return
        members = set()
        for it in sel:
            if it.in_archive:
                members.add(it.path.split('::', 1)[1])
        if not members:
            return

        def worker():
            err = None
            try:
                A.delete_zip_members(ap, members)
            except Exception as e:
                err = str(e)

            def done_cb():
                self.end_op()
                self.toast('Deleted from archive' if not err else str(err))
                pane.refresh()
                return False
            GLib.idle_add(done_cb)
        self.begin_op('Updating archive…', threading.Event())
        GLib.Thread.new(None, worker, None, None)


# ---------------------------------------------------------------- window

class MainWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app)
        self.app = app
        app._win = self
        st = app.state
        self.set_default_size(int(st.get('w', 1100)), int(st.get('h', 680)))
        self.set_title(utils.APP_NAME)
        self._dual = bool(st.get('dual', True))

        overlay = Gtk.Overlay()
        main = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        overlay.set_child(main)

        main.append(self._build_header())

        self._prog_reveal = Gtk.Revealer()
        pb_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        for m in ('top', 'bottom', 'start', 'end'):
            getattr(pb_box, 'set_margin_' + m)(8)
        self._prog_label = Gtk.Label(label='')
        self._prog_bar = Gtk.ProgressBar()
        self._prog_bar.set_hexpand(True)
        btn_cancel = Gtk.Button(label='Cancel')
        btn_cancel.connect('clicked', lambda *_: self._cancel_op())
        pb_box.append(self._prog_label)
        pb_box.append(self._prog_bar)
        pb_box.append(btn_cancel)
        self._prog_reveal.set_child(pb_box)
        app._prog_reveal = self._prog_reveal
        app._prog_bar = self._prog_bar
        app._prog_label = self._prog_label
        main.append(self._prog_reveal)

        body = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        body.set_vexpand(True)
        self.sidebar = self._build_sidebar()
        body.set_start_child(self.sidebar)
        self.inner = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        self.pane_l = PaneView(app, 'l')
        self.pane_r = PaneView(app, 'r')
        app.pane_l = self.pane_l
        app.pane_r = self.pane_r
        self.inner.set_start_child(self.pane_l)
        if self._dual:
            self.inner.set_end_child(self.pane_r)
        main.append(body)

        self._toast_label = Gtk.Label(label='')
        self._toast_label.add_css_class('osd')
        tbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        tbox.set_valign(Gtk.Align.END)
        tbox.set_halign(Gtk.Align.CENTER)
        tbox.set_margin_bottom(28)
        tbox.append(self._toast_label)
        self._toast_reveal = Gtk.Revealer()
        self._toast_reveal.set_child(tbox)
        overlay.set_overlay(self._toast_reveal)
        app._toast_label = self._toast_label
        app._toast_reveal = self._toast_reveal

        self.set_child(overlay)

        self._add_actions()
        ctl = Gtk.EventControllerKey.new()
        ctl.connect('key-pressed', self.on_key)
        self.add_controller(ctl)
        self.connect('close-request', lambda *_: (self.save_state(), True)[1])

        app.apply_theme()
        self.pane_l.apply_loc(st.get('l') or os.path.expanduser('~'))
        if self._dual:
            self.pane_r.apply_loc(st.get('r') or '/')
        self._last = self.pane_l

    def _cancel_op(self):
        if self.app._op_cancel is not None:
            self.app._op_cancel.set()

    # -------------------------------------------------------------- header
    def _build_header(self):
        hb = Gtk.HeaderBar()
        if hasattr(hb, 'set_title_widget'):
            hb.set_title_widget(Gtk.Label(label=utils.APP_NAME))
        else:
            hb.set_title(utils.APP_NAME)
        if hasattr(hb, 'set_show_title_buttons'):
            hb.set_show_title_buttons(True)
        elif hasattr(hb, 'set_show_close_button'):
            hb.set_show_close_button(True)
        self.btn_side = Gtk.MenuButton()
        self.btn_side.set_icon_name('sidebar-show-symbolic')
        self.btn_side.set_tooltip_text('Sidebar')
        self.btn_side.set_popover(self._build_menu())
        hb.pack_start(self.btn_side)
        sw = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2)
        b1 = Gtk.Button(label='1')
        b1.set_tooltip_text('Left pane')
        b1.connect('clicked', lambda *_: self.app.set_active_pane(self.pane_l))
        b2 = Gtk.Button(label='2')
        b2.set_tooltip_text('Right pane')
        b2.connect('clicked', lambda *_: self.app.set_active_pane(self.pane_r))
        sw.append(b1)
        sw.append(b2)
        hb.pack_start(sw)
        btn_dual = Gtk.Button.new_from_icon_name('view-dual-symbolic')
        btn_dual.set_tooltip_text('Toggle dual pane')
        btn_dual.connect('clicked', lambda *_: self._toggle_dual())
        hb.pack_end(btn_dual)
        return hb

    def _toggle_dual(self):
        self._dual = not self._dual
        self.app.state['dual'] = self._dual
        if self._dual:
            self.inner.set_end_child(self.pane_r)
            w = self.inner.get_width()
            self.inner.set_position(max(300, w // 2))
        else:
            self.inner.set_end_child(None)
        self.app.schedule_save()

    def _toggle_sidebar(self):
        v = self.sidebar.get_visible()
        self.sidebar.set_visible(not v)
        self.app.state['sidebar'] = not v
        self.app.schedule_save()

    # --------------------------------------------------------------- menu
    def _build_menu(self):
        pop = Gtk.Popover()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        for m in ('top', 'bottom', 'start', 'end'):
            getattr(box, 'set_margin_' + m)(6)

        def mb(label, icon, action):
            m = dialogs.menu_item(label=label, icon=icon, action=action)
            box.append(m)
            return m

        mb('New folder', 'folder-new-symbolic', 'win.new-folder')
        mb('New file', 'text-x-generic-symbolic', 'win.new-file')
        mb('Refresh', 'view-refresh-symbolic', 'win.refresh')
        mb('Go to path…', 'go-jump-symbolic', 'win.goto')
        box.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
        mb('Show hidden files', 'visible-symbolic', 'win.show-hidden')
        sort_pop = Gtk.Popover()
        sbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        for m in ('top', 'bottom', 'start', 'end'):
            getattr(sbox, 'set_margin_' + m)(6)
        for key, label in (('name', 'Name'), ('size', 'Size'),
                           ('date', 'Date modified'), ('type', 'Type')):
            sbox.append(dialogs.menu_item(
                label=label, detailed='win.sort::%s' % key))
        sort_pop.set_child(sbox)
        box.append(dialogs.menu_item(
            label='Sort by', icon='view-sort-descending-symbolic',
            submenu=sort_pop))
        mb('Ascending order', 'go-up-symbolic', 'win.ascending')
        box.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
        mb('Copy path', 'edit-copy-symbolic', 'win.copy-path')
        mb('Copy name', 'edit-clipboard-symbolic', 'win.copy-name')
        mb('Copy as list', 'text-x-generic-symbolic', 'win.copy-list')
        box.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
        mb('Properties', 'document-properties-symbolic', 'win.properties')
        mb('Checksums…', 'system-search-symbolic', 'win.checksum')
        mb('Bulk rename…', 'document-edit-symbolic', 'win.bulk')
        box.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
        mb('Toggle dual pane', 'view-dual-symbolic', 'win.toggle-panes')
        mb('Toggle sidebar', 'sidebar-show-symbolic', 'win.toggle-sidebar')
        mb('Preferences', 'preferences-system-symbolic', 'win.prefs')
        mb('About HPC Files', 'help-about-symbolic', 'win.about')
        pop.set_child(box)
        return pop

    # ------------------------------------------------------------- actions
    def _pane(self, method):
        p = self.app.active_pane()
        if p is not None:
            getattr(p, method)()

    def _add_actions(self):
        def simple(name, cb, param=None):
            a = Gtk.SimpleAction.new(name, param)
            a.connect('activate', cb)
            self.add_action(a)
            return a

        simple('new-folder', lambda a, p: self._pane('new_folder'))
        simple('new-file', lambda a, p: self._pane('new_file'))
        simple('refresh', lambda a, p: self._pane('refresh'))
        simple('goto', lambda a, p: self._goto())
        self.act_hidden = simple('show-hidden', lambda a, p: self._toggle_hidden())
        self.act_sort = simple('sort', lambda a, p: self._set_sort(p.get_string()),
                               GLib.VariantType.new('s'))
        self.act_asc = simple('ascending', lambda a, p: self._toggle_asc())
        simple('copy-path', lambda a, p: self._copy_text(lambda it: it.path))
        simple('copy-name', lambda a, p: self._copy_text(lambda it: it.name))
        simple('copy-list', lambda a, p: self._copy_list())
        simple('properties', lambda a, p: self._pane('props_sel'))
        simple('checksum', lambda a, p: self._pane('checksum_sel'))
        simple('bulk', lambda a, p: self._pane('bulk_rename'))
        simple('prefs', lambda a, p: dialogs.prefs_dialog(self, self.app))
        simple('about', lambda a, p: dialogs.about_dialog(self))
        simple('toggle-panes', lambda a, p: self._toggle_dual())
        simple('toggle-sidebar', lambda a, p: self._toggle_sidebar())
        self.sync_actions_state()

    def sync_actions_state(self):
        self.act_hidden.set_state(
            GLib.Variant('b', bool(self.app.prefs.get('show_hidden'))))
        self.act_sort.set_state(
            GLib.Variant('s', self.app.prefs.get('sort_key', 'name')))
        self.act_asc.set_state(
            GLib.Variant('b', not self.app.prefs.get('sort_desc')))

    def _toggle_hidden(self):
        self.app.prefs['show_hidden'] = not self.app.prefs.get('show_hidden')
        utils.save_json('prefs.json', self.app.prefs)
        self.sync_actions_state()
        for p in (self.pane_l, self.pane_r):
            p.refresh()

    def _set_sort(self, key):
        self.app.prefs['sort_key'] = key
        utils.save_json('prefs.json', self.app.prefs)
        self.sync_actions_state()
        for p in (self.pane_l, self.pane_r):
            p.refresh()

    def _toggle_asc(self):
        self.app.prefs['sort_desc'] = bool(self.app.prefs.get('sort_desc'))
        utils.save_json('prefs.json', self.app.prefs)
        self.sync_actions_state()
        for p in (self.pane_l, self.pane_r):
            p.refresh()

    def _goto(self):
        def cb(text):
            if text == '__trash__':
                self.app.active_pane().go_trash()
                return
            if '::' in text:
                ap, inner = text.split('::', 1)
                self.app.active_pane().go(ap, arch=(ap, inner))
            elif os.path.isdir(text):
                self.app.active_pane().go(text)
            elif os.path.isfile(text):
                parent = os.path.dirname(text) or '/'
                self.app.active_pane().go(parent)
            else:
                self.app.toast('Path not found: ' + text)
        dialogs.goto_dialog(self, cb)

    def _copy_text(self, getter):
        sel = self.app.active_pane().selected_items() if \
            self.app.active_pane() else []
        if not sel:
            p = self.app.active_pane()
            if p is not None:
                self.app.copy_text_to_clipboard(p.path)
            return
        self.app.copy_text_to_clipboard('\n'.join(getter(it) for it in sel))

    def _copy_list(self):
        p = self.app.active_pane()
        if p is None:
            return
        sel = p.selected_items()
        lines = [it.path for it in sel] if sel else [p.path]
        self.app.copy_text_to_clipboard('\n'.join(lines))

    # -------------------------------------------------------------- sidebar
    def _build_sidebar(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        outer.set_size_request(215, -1)
        outer.set_visible(bool(self.app.state.get('sidebar', True)))
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sw.set_vexpand(True)
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        sw.set_child(vbox)
        outer.append(sw)
        home = str(Path.home())

        def section(title):
            l = Gtk.Label(label=title)
            l.set_xalign(0.0)
            l.set_margin_top(8)
            l.set_margin_bottom(2)
            l.set_margin_start(10)
            l.add_css_class('dim-label')
            vbox.append(l)
            lb = Gtk.ListBox()
            lb.set_selection_mode(Gtk.SelectionMode.SINGLE)
            vbox.append(lb)
            return lb

        def row(lb, icon, label, path, tooltip=None):
            r = Gtk.ListBoxRow()
            b = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            b.set_margin_top(2)
            b.set_margin_bottom(2)
            b.append(Gtk.Image.new_from_icon_name(icon))
            l = Gtk.Label(label=label)
            l.set_xalign(0.0)
            l.set_ellipsize(Pango.EllipsizeMode.END)
            b.append(l)
            r.set_child(b)
            if tooltip:
                r.set_tooltip_text(tooltip)
            r.connect('activated', lambda *_: self._open_place(path))
            lb.append(r)
            return r

        lb = section('Places')
        row(lb, 'user-home-symbolic', 'Home', home)
        for name in ('Documents', 'Downloads', 'Music', 'Pictures', 'Videos'):
            full = os.path.join(home, name)
            if os.path.isdir(full):
                row(lb, 'folder', name, full)
        row(lb, 'user-trash-symbolic', 'Trash', '__trash__')

        lb = section('Disks')
        for (mnt, label, total, used, free) in utils.list_mounts():
            r = Gtk.ListBoxRow()
            b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
            b.set_margin_start(6)
            b.set_margin_end(6)
            b.set_margin_top(2)
            b.set_margin_bottom(2)
            topb = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            topb.append(Gtk.Image.new_from_icon_name('drive-harddisk-symbolic'))
            l = Gtk.Label(label=label)
            l.set_xalign(0.0)
            l.set_ellipsize(Pango.EllipsizeMode.END)
            topb.append(l)
            b.append(topb)
            pb = Gtk.ProgressBar()
            pb.set_fraction(used / max(total, 1))
            pb.set_show_text(True)
            pb.set_text('%s / %s' % (utils.human_size(used),
                                     utils.human_size(total)))
            b.append(pb)
            r.set_child(b)
            r.set_tooltip_text(mnt)
            r.connect('activated', lambda *_: self._open_place(mnt))
            lb.append(r)

        self.recent_lb = section('Recent')
        self.recent_rows = []
        self.fav_lb = section('Favorites')
        self.fav_rows = []
        self.rebuild_recent()
        self.rebuild_fav()
        return outer

    def _open_place(self, path):
        pane = self.app.active_pane()
        if pane is None:
            return
        if path == '__trash__':
            pane.go_trash()
        else:
            pane.go(path)

    def rebuild_recent(self):
        for r in self.recent_rows:
            self.recent_lb.remove(r)
        self.recent_rows = []
        for p in self.app.recent[:30]:
            r = Gtk.ListBoxRow()
            b = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            b.append(Gtk.Image.new_from_icon_name('document-open-symbolic'))
            l = Gtk.Label(label=os.path.basename(p))
            l.set_xalign(0.0)
            l.set_ellipsize(Pango.EllipsizeMode.END)
            b.append(l)
            r.set_child(b)
            r.set_tooltip_text(p)
            r.connect('activated', lambda *_: self._open_place(p))
            self.recent_lb.append(r)
            self.recent_rows.append(r)

    def rebuild_fav(self):
        for r in self.fav_rows:
            self.fav_lb.remove(r)
        self.fav_rows = []
        for p in self.app.favorites:
            r = Gtk.ListBoxRow()
            b = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            b.append(Gtk.Image.new_from_icon_name('starred-symbolic'))
            l = Gtk.Label(label=os.path.basename(p.rstrip('/')) or '/')
            l.set_xalign(0.0)
            l.set_ellipsize(Pango.EllipsizeMode.END)
            b.append(l)
            r.set_child(b)
            r.set_tooltip_text(p)
            r.connect('activated', lambda *_: self._open_place(p))
            self.fav_lb.append(r)
            self.fav_rows.append(r)

    # ------------------------------------------------------------- keyboard
    def on_key(self, ctl, keyval, keycode, state):
        # gtk_accelerator_get_default_modmask() is a GTK3 API; on GTK4
        # the primary modifier is Ctrl.
        _m = getattr(Gtk, 'accelerator_get_default_modmask', None)
        mods = state & (_m() if _m else Gdk.Modifier4.CONTROL_MASK)
        focus = self.get_focus()
        in_text = isinstance(focus, (Gtk.Entry, Gtk.SearchEntry,
                                     Gtk.TextView))
        pane = self.app.active_pane()
        if pane is None:
            return False
        if keyval == Gdk.KEY_F5:
            pane.refresh()
            return True
        if keyval == Gdk.KEY_Delete and not in_text:
            pane.delete_items()
            return True
        if keyval == Gdk.KEY_F2 and not in_text:
            pane.rename_items()
            return True
        if keyval == Gdk.KEY_Escape and not in_text:
            pane.clear_selection()
            return True
        if keyval == Gdk.KEY_BackSpace and not in_text:
            pane.up()
            return True
        if mods & Gdk.Modifier4.ALT_MASK:
            if keyval == Gdk.KEY_Left:
                pane.back()
                return True
            if keyval == Gdk.KEY_Right:
                pane.forward()
                return True
        if mods & Gdk.Modifier4.CONTROL_MASK and not in_text:
            if keyval in (Gdk.KEY_c, Gdk.KEY_C):
                pane.copy_items()
                return True
            if keyval in (Gdk.KEY_x, Gdk.KEY_X):
                pane.cut_items()
                return True
            if keyval in (Gdk.KEY_v, Gdk.KEY_V):
                pane.paste_items()
                return True
            if keyval in (Gdk.KEY_a, Gdk.KEY_A):
                pane.select_all()
                return True
            if keyval in (Gdk.KEY_l, Gdk.KEY_L):
                self._goto()
                return True
        return False

    # ---------------------------------------------------------------- state
    def save_state(self):
        st = self.app.state
        st['w'] = self.get_width()
        st['h'] = self.get_height()
        st['l'] = self.pane_l.loc_key()
        st['r'] = self.pane_r.loc_key()
        st['dual'] = self._dual
        st['sidebar'] = self.sidebar.get_visible()
        utils.save_json('state.json', st)


def main():
    app = App()
    return app.run(sys.argv)
