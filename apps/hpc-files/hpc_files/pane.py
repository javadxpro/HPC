# -*- coding: utf-8 -*-
"""One browsing pane: breadcrumbs, list, selection, quick actions, menus."""
import os

from gi.repository import Gtk, Gio, GLib, Pango

from . import utils
from . import archive as A
from . import fileops
from . import dialogs

ATTRS = ('standard::display-name,standard::size,standard::time-modified,'
         'standard::type,standard::content-type')


class FileItem(object):
    __slots__ = ('name', 'path', 'is_dir', 'is_archive', 'size', 'mtime',
                 'trash')

    def __init__(self):
        self.name = ''
        self.path = ''
        self.is_dir = False
        self.is_archive = False
        self.size = 0
        self.mtime = 0
        self.trash = False

    @property
    def in_archive(self):
        return '::' in self.path


def _icon_for(it):
    if it.is_dir:
        return 'folder'
    if it.is_archive:
        return 'folder-archive'
    n = it.name.lower()
    ext = os.path.splitext(n)[1]
    if ext in utils.IMAGE_EXTS:
        return 'image-x-generic'
    if ext in utils.AUDIO_EXTS:
        return 'audio-x-generic'
    if ext in utils.VIDEO_EXTS:
        return 'video-x-generic'
    if ext in utils.EXEC_EXTS:
        return 'application-x-executable'
    if ext in utils.TEXT_EXTS:
        return 'text-x-generic'
    if not it.in_archive and not it.trash:
        try:
            if os.access(it.path, os.X_OK) and not os.path.isdir(it.path):
                return 'application-x-executable'
        except Exception:
            pass
    return 'unknown'


class FileRow(Gtk.ListBoxRow):
    def __init__(self, pane, it):
        super().__init__()
        self.item = it
        self.pane = pane
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        box.set_margin_top(3)
        box.set_margin_bottom(3)
        img = Gtk.Image.new_from_icon_name(_icon_for(it))
        img.set_pixel_size(22)
        box.append(img)
        lbl = Gtk.Label(label=it.name)
        lbl.set_hexpand(True)
        lbl.set_xalign(0.0)
        lbl.set_ellipsize(Pango.EllipsizeMode.END)
        lbl.set_tooltip_text(it.path)
        box.append(lbl)
        if not it.is_dir:
            sz = Gtk.Label(label=utils.human_size(it.size))
            sz.set_xalign(1.0)
            box.append(sz)
        if pane.app.prefs.get('show_date', True):
            dt = Gtk.Label(label=utils.fmt_time(it.mtime))
            dt.set_xalign(1.0)
            box.append(dt)
        self.set_child(box)
        ctl = Gtk.EventControllerButtonPress.new()
        ctl.connect('pressed', self._on_press)
        self.add_controller(ctl)

    def _on_press(self, ctl, x, y):
        if ctl.get_current_button() == 3:
            self.pane.show_context(self.item)
            return True
        return False


class PaneView(Gtk.Box):
    def __init__(self, app, side):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.app = app
        self.side = side
        self.path = os.path.expanduser('~')
        self.arch = None          # (archive_path, inner) or None
        self.is_trash = False
        self.items = []
        self.rows = []
        self.history = []
        self.hindex = -1
        self._search = ''
        self._search_to = None
        self._build()

    # ------------------------------------------------------------------ UI
    def _build(self):
        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        top.set_margin_top(4)
        top.set_margin_start(6)
        top.set_margin_end(6)
        self.btn_back = Gtk.Button.new_from_icon_name('go-previous-symbolic')
        self.btn_fwd = Gtk.Button.new_from_icon_name('go-next-symbolic')
        self.btn_back.set_tooltip_text('Back (Alt+Left)')
        self.btn_fwd.set_tooltip_text('Forward (Alt+Right)')
        self.btn_back.connect('clicked', lambda *_: self.back())
        self.btn_fwd.connect('clicked', lambda *_: self.forward())
        self.crumb = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        self.crumb.set_hexpand(True)
        self.search_entry = Gtk.SearchEntry()
        self.search_entry.set_placeholder_text('Search this folder…')
        self.search_entry.connect('search-changed', self._on_search)
        self.search_reveal = Gtk.Revealer()
        self.search_reveal.set_child(self.search_entry)
        self.search_reveal.set_transition_type(Gtk.TransitionType.CROSSFADE)
        self.btn_search = Gtk.Button.new_from_icon_name('edit-find-symbolic')
        self.btn_search.set_tooltip_text('Search')
        self.btn_search.connect('clicked', lambda *_: self._toggle_search())
        self.btn_refresh = Gtk.Button.new_from_icon_name('view-refresh-symbolic')
        self.btn_refresh.set_tooltip_text('Refresh (F5)')
        self.btn_refresh.connect('clicked', lambda *_: self.refresh())
        top.append(self.btn_back)
        top.append(self.btn_fwd)
        top.append(self.crumb)
        top.append(self.search_reveal)
        top.append(self.btn_search)
        top.append(self.btn_refresh)
        self.append(top)

        qa = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2)
        qa.set_margin_start(6)
        qa.set_margin_end(6)
        qa.set_margin_bottom(2)
        self._qbtn(qa, 'folder-new-symbolic', 'New folder', self.new_folder)
        self._qbtn(qa, 'package-x-generic-symbolic', 'Compress…', self.compress)
        self._qbtn(qa, 'folder-open-symbolic', 'Extract…', self.extract_sel)
        self._qbtn(qa, 'edit-copy-symbolic', 'Copy (Ctrl+C)', self.copy_items)
        self._qbtn(qa, 'edit-cut-symbolic', 'Cut (Ctrl+X)', self.cut_items)
        self._qbtn(qa, 'edit-paste-symbolic', 'Paste (Ctrl+V)', self.paste_items)
        self._qbtn(qa, 'document-edit-symbolic', 'Rename (F2)', self.rename_items)
        self._qbtn(qa, 'document-properties-symbolic', 'Properties',
                   self.props_sel)
        self._qbtn(qa, 'user-trash-symbolic', 'Delete (Del)', self.delete_items)
        self.append(qa)

        self.scrolled = Gtk.ScrolledWindow()
        self.scrolled.set_vexpand(True)
        self.scrolled.set_policy(Gtk.PolicyType.NEVER,
                                 Gtk.PolicyType.AUTOMATIC)
        self.list = Gtk.ListBox()
        self.list.set_selection_mode(Gtk.SelectionMode.MULTIPLE)
        self.list.connect('row-activated', self._on_activate)
        self.list.connect('row-selected', lambda *_: self.update_status())
        self.list.connect('row-unselected', lambda *_: self.update_status())
        self.scrolled.set_child(self.list)
        self.append(self.scrolled)

        self.status = Gtk.Label(label='')
        self.status.set_xalign(0.0)
        self.status.set_hexpand(True)
        self.status.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        self.status.set_margin_start(6)
        self.status.set_margin_end(6)
        self.status.set_margin_bottom(4)
        self.append(self.status)

    def _qbtn(self, box, icon, tip, cb):
        b = Gtk.Button.new_from_icon_name(icon)
        b.set_tooltip_text(tip)
        b.connect('clicked', lambda *_: cb())
        box.append(b)
        return b

    def _root(self):
        w = self
        while w is not None and not isinstance(w, Gtk.Window):
            w = w.get_parent()
        return w

    # ------------------------------------------------------------- location
    def loc_key(self):
        if self.is_trash:
            return '__trash__'
        if self.arch:
            return self.arch[0] + '::' + self.arch[1]
        return self.path

    def _real_dir(self):
        if self.is_trash:
            return None
        if self.arch:
            return os.path.dirname(self.arch[0])
        return self.path

    def apply_loc(self, key):
        if not key:
            return
        if key == '__trash__':
            self.go_trash()
        elif '::' in key:
            ap, inner = key.split('::', 1)
            self.go(ap, arch=(ap, inner), push_history=False)
        else:
            self.go(key, push_history=False)

    def go(self, path, arch=None, push_history=True):
        self.is_trash = False
        self.arch = arch
        self.path = path
        self._search = ''
        self.search_entry.set_text('')
        self._list_location()
        if push_history:
            key = self.loc_key()
            self.history = self.history[:self.hindex + 1]
            self.history.append(key)
            self.hindex = len(self.history) - 1
        else:
            if not self.history:
                self.history = [self.loc_key()]
            self.hindex = 0
        self.update_crumb()
        self.btn_back.set_sensitive(self.hindex > 0)
        self.btn_fwd.set_sensitive(self.hindex < len(self.history) - 1)
        self.app.set_active_pane(self)
        self.app.schedule_save()

    def go_trash(self):
        self.is_trash = True
        self.arch = None
        self.path = '__trash__'
        self._search = ''
        self.search_entry.set_text('')
        self._list_location()
        self.history = ['__trash__']
        self.hindex = 0
        self.update_crumb()
        self.btn_back.set_sensitive(False)
        self.btn_fwd.set_sensitive(False)
        self.app.set_active_pane(self)

    def back(self):
        if self.hindex > 0:
            self.hindex -= 1
            self.apply_loc(self.history[self.hindex])
            self._sync_nav()

    def forward(self):
        if self.hindex < len(self.history) - 1:
            self.hindex += 1
            self.apply_loc(self.history[self.hindex])
            self._sync_nav()

    def _sync_nav(self):
        self.update_crumb()
        self.btn_back.set_sensitive(self.hindex > 0)
        self.btn_fwd.set_sensitive(self.hindex < len(self.history) - 1)
        self.app.set_active_pane(self)
        self.app.schedule_save()

    def up(self):
        if self.arch:
            ap, inner = self.arch
            parts = [p for p in inner.split('/') if p]
            new_inner = '/'.join(parts[:-1])
            self.go(ap, arch=(ap, new_inner))
        elif self.is_trash:
            return
        else:
            parent = os.path.dirname(self.path.rstrip('/')) or '/'
            self.go(parent)

    def refresh(self):
        if self.is_trash:
            self.go_trash()
        elif self.arch:
            self.go(self.path, arch=self.arch, push_history=False)
            self._sync_nav()
        else:
            self.go(self.path, push_history=False)
            self._sync_nav()

    # -------------------------------------------------------------- listing
    def _list_location(self):
        items = []
        if self.is_trash:
            items = self._list_trash()
        elif self.arch:
            items = self._list_archive(self.arch[0], self.arch[1])
        else:
            items = self._list_dir(self.path)
        items.sort(key=lambda it: self._sort_key(it),
                   reverse=bool(self.app.prefs.get('sort_desc')))
        self.items = items
        self._rebuild_rows()
        self.update_status()

    def _list_dir(self, path):
        items = []
        f = Gio.File.new_for_path(path)
        try:
            en = f.enumerate_children(ATTRS, Gio.FileQueryInfoFlags.NONE, None)
        except Exception as e:
            self.app.toast('Cannot open folder: %s' % e)
            return items
        show_hidden = self.app.prefs.get('show_hidden')
        while True:
            child, info = en.next_file(None)
            if child is None:
                break
            try:
                name = info.get_display_name()
                if not show_hidden and name.startswith('.'):
                    continue
                if self._search and \
                        self._search.lower() not in name.lower():
                    continue
                it = FileItem()
                it.name = name
                it.path = child.get_path()
                it.is_dir = info.get_file_type() == Gio.FileType.DIRECTORY
                it.is_archive = A.is_archive(it.path)
                it.size = info.get_size()
                mt = info.get_modification_time()
                it.mtime = mt.to_unix_time() if mt else 0
                items.append(it)
            except Exception:
                continue
        return items

    def _list_archive(self, archive_path, inner):
        items = []
        try:
            kind, entries, handle = A.list_archive(archive_path)
        except Exception as e:
            self.app.toast('Cannot open archive: %s' % e)
            return items
        try:
            base = inner.rstrip('/')
            for e in entries:
                if base:
                    if not e.name.startswith(base + '/'):
                        continue
                display = e.name[len(base) + 1:] if base else e.name
                if not display or display.startswith('/'):
                    continue
                if '/' in display:
                    continue
                if display in ('.', '..'):
                    continue
                if not self.app.prefs.get('show_hidden') \
                        and display.startswith('.'):
                    continue
                if self._search and \
                        self._search.lower() not in display.lower():
                    continue
                it = FileItem()
                it.name = display
                it.path = archive_path + '::' + e.name
                it.is_dir = e.is_dir
                it.size = 0 if e.is_dir else (e.size or 0)
                it.mtime = e.mtime
                items.append(it)
        finally:
            if handle is not None and hasattr(handle, 'close'):
                try:
                    handle.close()
                except Exception:
                    pass
        return items

    def _list_trash(self):
        items = []
        try:
            vm = Gio.VolumeMonitor.get()
        except Exception:
            return items
        for v in vm.get_volumes():
            try:
                if not v.is_trash():
                    continue
                mount = v.get_mount()
                if mount is None:
                    continue
                files_dir = mount.get_root().get_child('files')
                en = files_dir.enumerate_children(ATTRS, None, None)
            except Exception:
                continue
            while True:
                child, info = en.next_file(None)
                if child is None:
                    break
                try:
                    it = FileItem()
                    it.name = info.get_display_name()
                    it.path = child.get_path()
                    it.is_dir = False
                    it.is_archive = A.is_archive(it.path)
                    it.size = info.get_size()
                    mt = info.get_modification_time()
                    it.mtime = mt.to_unix_time() if mt else 0
                    it.trash = True
                    items.append(it)
                except Exception:
                    continue
        return items

    def _sort_key(self, it):
        k = self.app.prefs.get('sort_key', 'name')
        if k == 'size':
            return (0 if it.is_dir else 1, -(it.size or 0), it.name.lower())
        if k == 'date':
            return (0 if it.is_dir else 1, -(it.mtime or 0), it.name.lower())
        if k == 'type':
            ext = ''
            if not it.is_dir:
                i = it.name.rfind('.')
                ext = it.name[i + 1:] if i >= 0 else ''
            return (0 if it.is_dir else 1, ext.lower(), it.name.lower())
        return (0 if it.is_dir else 1, it.name.lower())

    def _rebuild_rows(self):
        for row, _ in self.rows:
            self.list.remove(row)
        self.rows = []
        for it in self.items:
            row = FileRow(self, it)
            self.list.append(row)
            self.rows.append((row, it))

    # ------------------------------------------------------------- crumbs
    def update_crumb(self):
        for c in self.crumb.get_children():
            self.crumb.remove(c)

        def add_btn(label, target):
            b = Gtk.Button(label=label)
            b.set_relief(Gtk.ReliefStyle.NONE)
            b.set_can_focus(False)
            b.set_valign(Gtk.Align.CENTER)
            b.connect('clicked', lambda *_: target())
            self.crumb.append(b)

        def add_sep():
            s = Gtk.Label(label='  /  ')
            s.set_valign(Gtk.Align.CENTER)
            s.add_css_class('dim-label')
            self.crumb.append(s)

        if self.is_trash:
            add_btn('Trash', lambda: self.go_trash())
            return
        if self.arch:
            ap, inner = self.arch
            parent = os.path.dirname(ap) or '/'
            add_btn(os.path.basename(parent) or '/',
                    lambda: self.go(parent))
            add_sep()
            add_btn(os.path.basename(ap),
                    lambda: self.go(ap, arch=(ap, '')))
            parts = [p for p in inner.split('/') if p]
            for i, part in enumerate(parts):
                add_sep()
                sub = '/'.join(parts[:i + 1])

                def _t(s=sub):
                    self.go(self.arch[0], arch=(self.arch[0], s))
                add_btn(part, _t)
            return
        add_btn('/', lambda: self.go('/'))
        comps = [c for c in self.path.split('/') if c]
        for i, c in enumerate(comps):
            add_sep()
            sub = '/' + '/'.join(comps[:i + 1])

            def _t(s=sub):
                self.go(s)
            add_btn(c, _t)

    # ---------------------------------------------------------- selection
    def selected_items(self):
        out = []
        sel = self.list.get_selected_rows()
        for i in range(sel.get_n_items()):
            row = sel.get_item(i)
            if isinstance(row, FileRow):
                out.append(row.item)
        return out

    def select_all(self):
        for row, _ in self.rows:
            self.list.select_row(row, False)

    def clear_selection(self):
        try:
            self.list.unselect_all()
        except Exception:
            pass
        self.update_status()

    def update_status(self):
        sel = self.selected_items()
        msg = '%d items' % len(self.items)
        if sel:
            tot = sum(it.size for it in sel if not it.is_dir)
            msg += ' — %d selected' % len(sel)
            if tot:
                msg += ' (%s)' % utils.human_size(tot)
        if self.is_trash:
            loc = 'Trash'
        elif self.arch:
            loc = os.path.basename(self.arch[0]) + \
                (('/' + self.arch[1]) if self.arch[1] else '')
        else:
            loc = self.path
        self.status.set_text('%s   %s' % (msg, loc))

    # -------------------------------------------------------------- search
    def _toggle_search(self):
        v = not self.search_reveal.get_reveal_child()
        self.search_reveal.set_reveal_child(v)
        if v:
            self.search_entry.grab_focus()

    def _on_search(self, entry):
        self._search = entry.get_text().strip()
        if self._search_to:
            GLib.source_remove(self._search_to)
        self._search_to = GLib.timeout_add(200, self._do_search)

    def _do_search(self):
        self._search_to = None
        self._list_location()
        return False

    # ----------------------------------------------------------- activate
    def _on_activate(self, lst, row):
        if isinstance(row, FileRow):
            self.open_item(row.item)

    def open_item(self, it):
        if it.trash:
            f = Gio.File.new_for_path(it.path)
            try:
                Gio.AppInfo.launch_default_for_uri(f.get_uri(), None)
            except Exception as e:
                self.app.toast('Open failed: %s' % e)
            return
        if it.is_dir:
            if self.arch:
                member = it.path.split('::', 1)[1]
                self.go(self.path, arch=(self.arch[0], member))
            else:
                self.go(it.path)
        elif it.is_archive:
            self.go(it.path, arch=(it.path, ''))
        else:
            if self.arch:
                member = it.path.split('::', 1)[1]
                self.app.add_recent(it.path)
                self.app.extract_to(self.arch[0],
                                    self.app._extract_default(self.arch[0]),
                                    [member], None)
            else:
                self.app.add_recent(it.path)
                f = Gio.File.new_for_path(it.path)
                try:
                    Gio.AppInfo.launch_default_for_uri(f.get_uri(), None)
                except Exception as e:
                    self.app.toast('Open failed: %s' % e)

    # ---------------------------------------------------------- open with
    def _open_terminal(self, path):
        if utils.open_in_terminal(path):
            self.app.toast('Opened in terminal')
        else:
            self.app.toast('No terminal found (set it in Preferences)')

    # -------------------------------------------------------------- menus
    def show_context(self, it):
        pop = Gtk.Popover(relative_to=self.scrolled)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        box.set_margin_top(6)
        box.set_margin_bottom(6)
        box.set_margin_start(6)
        box.set_margin_end(6)

        def add(label, icon, cb, sensitive=True):
            mb = dialogs.menu_item(label=label, icon=icon, cb=cb,
                                   sensitive=sensitive)
            box.append(mb)

        if it.trash:
            add('Open', 'document-open-symbolic', lambda: self.open_item(it))
            add('Restore', 'edit-undo-symbolic', lambda: self.restore_item(it))
            add('Delete permanently', 'user-trash-full-symbolic',
                lambda: self.delete_permanent())
            add('Properties', 'document-properties-symbolic',
                lambda: dialogs.props_dialog(self._root(), it.path, False, self))
        else:
            add('Open', 'document-open-symbolic', lambda: self.open_item(it))
            if not self.arch:
                add('Open with…', 'application-x-executable-symbolic',
                    lambda: dialogs.open_with_dialog(self._root(), it.path),
                    sensitive=not it.is_dir)
                if not it.is_dir and \
                        os.path.splitext(it.name.lower())[1] in utils.TEXT_EXTS:
                    add('Edit in HPC Editor', 'text-editor-symbolic',
                        lambda: dialogs.open_editor(self._root(), it.path))
                add('Open in terminal', 'utilities-terminal-symbolic',
                    lambda: self._open_terminal(
                        it.path if it.is_dir
                        else (os.path.dirname(it.path) or '/')),
                    sensitive=True)
            if it.is_archive or self.arch:
                add('Extract…', 'folder-open-symbolic',
                    lambda: self.app.extract_dialog(self, [it]))
            add('Compress…', 'package-x-generic-symbolic', self.compress,
                sensitive=not self.arch)
            add('Copy', 'edit-copy-symbolic', self.copy_items)
            add('Cut', 'edit-cut-symbolic', self.cut_items)
            add('Paste', 'edit-paste-symbolic', self.paste_items,
                sensitive=bool(self.app.clipboard) and not self.is_trash)
            add('New folder', 'folder-new-symbolic', self.new_folder,
                sensitive=not self.arch and not self.is_trash)
            add('Rename…', 'document-edit-symbolic', self.rename_items,
                sensitive=not self.arch and not self.is_trash)
            add('Properties', 'document-properties-symbolic',
                lambda: dialogs.props_dialog(self._root(), it.path,
                                             it.is_dir, self))
            add('Checksums…', 'system-search-symbolic', self.checksum_sel,
                sensitive=not it.is_dir and not self.arch and not it.trash)
            if it.is_dir and not self.arch:
                add('Set permissions…', 'changes-prevent-symbolic',
                    lambda: dialogs.chmod_dialog(
                        self._root(), [it.path],
                        lambda e: self.app.toast(
                            'Permissions updated' if not e else str(e))))
            add('Delete', 'user-trash-symbolic', self.delete_items)
            if not it.is_dir and not self.arch and not self.is_trash:
                add('Delete permanently', 'user-trash-full-symbolic',
                    self.delete_permanent)
        pop.set_child(box)
        pop.present()

    # ------------------------------------------------------------- actions
    def new_folder(self):
        if self.arch or self.is_trash:
            self.app.toast('Not possible here')
            return
        dialogs.prompt(self._root(), 'New folder', 'Name:', 'New Folder',
                       ok_label='Create', cb=lambda n: self._mk(n, False))

    def new_file(self):
        if self.arch or self.is_trash:
            self.app.toast('Not possible here')
            return
        dialogs.prompt(self._root(), 'New file', 'Name:', 'new.txt',
                       ok_label='Create', cb=lambda n: self._mk(n, True))

    def _mk(self, name, file_mode):
        try:
            p = os.path.join(self._real_dir() or self.path, name)
            if file_mode:
                open(p, 'a').close()
            else:
                os.makedirs(p)
            self.refresh()
        except Exception as e:
            self.app.toast(str(e))

    def copy_items(self):
        sel = self.selected_items()
        if not sel:
            return
        self.app.clipboard = [(it.path, 'copy') for it in sel]
        self.app.toast('Copied %d item(s)' % len(sel))

    def cut_items(self):
        if self.is_trash:
            self.app.toast('Cut is not available in Trash')
            return
        sel = self.selected_items()
        if not sel:
            return
        self.app.clipboard = [(it.path, 'cut') for it in sel]
        self.app.toast('Cut %d item(s)' % len(sel))

    def paste_items(self):
        if self.app.clipboard:
            self.app.paste_into(self)

    def rename_items(self):
        if self.arch or self.is_trash:
            self.app.toast('Not possible here')
            return
        sel = self.selected_items()
        if len(sel) != 1:
            self.app.toast('Select exactly one item to rename')
            return
        it = sel[0]
        base = os.path.basename(it.path.rstrip('/'))
        parent = os.path.dirname(it.path)
        dialogs.prompt(self._root(), 'Rename', 'New name:', base,
                       ok_label='Rename',
                       cb=lambda n: self._rename(it.path, parent, n))

    def _rename(self, old, parent, new):
        new = new.strip()
        if not new or new.startswith('/'):
            return
        try:
            os.rename(old, os.path.join(parent, new))
            self.refresh()
        except Exception as e:
            self.app.toast(str(e))

    def props_sel(self):
        sel = self.selected_items()
        if sel:
            it = sel[0]
            dialogs.props_dialog(self._root(), it.path, it.is_dir, self)
        elif not self.arch and not self.is_trash:
            dialogs.props_dialog(self._root(), self.path, True, self)

    def checksum_sel(self):
        sel = [it for it in self.selected_items()
               if not it.is_dir and not it.in_archive and not it.trash]
        if not sel:
            self.app.toast('Select files first')
            return
        dialogs.checksum_dialog(self._root(), [it.path for it in sel])

    def bulk_rename(self):
        sel = [it for it in self.selected_items()
               if not it.is_dir and not it.in_archive and not self.arch
               and not it.trash]
        if len(sel) < 2:
            self.app.toast('Select 2 or more files to bulk rename')
            return

        def done(n_ok, n_skip, err):
            self.app.toast('Renamed %d (skipped %d)%s' % (
                n_ok, n_skip, ' — ' + err if err else ''))
            self.refresh()
        dialogs.bulk_rename_dialog(self._root(), sel, done)

    def compress(self):
        if self.arch or self.is_trash:
            self.app.toast('Not possible here')
            return
        sel = self.selected_items()
        if not sel:
            self.app.toast('Select files to compress first')
            return
        self.app.compress_dialog(self, sel)

    def extract_sel(self):
        sel = self.selected_items()
        if not sel:
            if self.arch:
                sel = self.items[:1] if self.items else []
            if not sel:
                self.app.toast('Nothing to extract')
                return
        self.app.extract_dialog(self, sel)

    def delete_items(self):
        sel = self.selected_items()
        if not sel:
            return
        if self.is_trash:
            self.app.confirm_dangerous(
                'Permanently delete %d item(s) from trash?' % len(sel),
                lambda: self._trash_permanent(sel))
            return
        if self.arch:
            self.app.delete_archive_members(self)
            return

        def go():
            self.app.trash_or_delete(sel, False)
        if self.app.prefs.get('confirm_delete', True):
            self.app.confirm_dangerous(
                'Move %d item(s) to trash?' % len(sel), go)
        else:
            go()

    def delete_permanent(self):
        sel = self.selected_items()
        if not sel or self.arch:
            return
        self.app.confirm_dangerous(
            'PERMANENTLY delete %d item(s)? This cannot be undone.' % len(sel),
            lambda: self.app.trash_or_delete(sel, True))

    def _trash_permanent(self, sel):
        paths = [it.path for it in sel]

        def on_done(err, cancelled):
            self.app.toast('Deleted' if not err else str(err))
            self.refresh()
        fileops.delete_items(self.app, paths, on_done)

    def restore_item(self, it):
        info_dir = os.path.join(os.path.dirname(it.path), '..', 'info')
        ti = os.path.join(info_dir, it.name + '.trashinfo')
        orig = None
        try:
            with open(ti, 'r', encoding='utf-8', errors='replace') as f:
                for line in f:
                    if line.startswith('Path='):
                        orig = line[5:].strip()
        except Exception:
            pass
        if not orig:
            orig = os.path.join(os.path.expanduser('~'), it.name)
        parent = os.path.dirname(orig)

        def on_done(err, cancelled):
            if not err:
                try:
                    Gio.File.new_for_path(it.path).delete(None)
                    self.app.toast('Restored to ' + (parent or '/'))
                except Exception as e:
                    self.app.toast(str(e))
            else:
                self.app.toast('Restore failed: ' + str(err))
            self.refresh()
        fileops.copy_items(self.app, [it.path], parent, True, on_done)
