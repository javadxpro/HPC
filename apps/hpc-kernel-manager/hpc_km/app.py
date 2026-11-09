# -*- coding: utf-8 -*-
"""HPC Kernel Manager — GTK4 application (A/B kernel flash for Droidian)."""
import os
import threading
import time

from gi.repository import Gtk, Gio, GLib, Pango

from . import __version__, APP_NAME
from . import device
from . import flasher
from .flasher import FlashError, KERNELS


def human_kb(n):
    if n is None:
        return '?'
    if n < 1024:
        return '%d KB' % n
    if n < 1024 * 1024:
        return '%.1f MB' % (n / 1024)
    return '%.2f GB' % (n / (1024 * 1024))


class MainWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app)
        self.set_default_size(560, 720)
        self.set_title(APP_NAME)
        self.busy = False

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.append(self._build_header())
        self.content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL,
                               spacing=10)
        for m in ('top', 'bottom', 'start', 'end'):
            getattr(self.content, 'set_margin_' + m)(12)
        self.content.append(self._build_status_card())
        self.content.append(self._build_kernel_card())
        self.content.append(self._build_actions())
        self.content.append(self._build_log())
        root.append(self.content)
        self.set_child(root)

        self._add_actions()
        self.refresh_status()

    # -------------------------------------------------------------- header
    def _build_header(self):
        hb = Gtk.HeaderBar()
        hb.set_show_close_button(True)
        hb.set_title_widget(Gtk.Label(label=APP_NAME))
        btn = Gtk.MenuButton()
        btn.set_icon_name('open-menu-symbolic')
        pop = Gtk.Popover()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        for m in ('top', 'bottom', 'start', 'end'):
            getattr(box, 'set_margin_' + m)(6)
        for label, action in (('Refresh status', 'win.refresh'),
                              ('About HPC Kernel Manager', 'win.about')):
            b = Gtk.ModelButton()
            b.set_label(label)
            b.set_action_name(action)
            box.append(b)
        pop.set_child(box)
        btn.set_popover(pop)
        hb.pack_end(btn)
        return hb

    def _add_actions(self):
        for name, cb in (('refresh', self._on_refresh),
                         ('about', self._on_about)):
            a = Gtk.SimpleAction.new(name)
            a.connect('activate', lambda _a, _p, cb=cb: cb())
            self.add_action(a)

    def _on_about(self):
        d = Gtk.AboutDialog()
        d.set_transient_for(self)
        d.set_modal(True)
        d.set_program_name(APP_NAME)
        d.set_version(__version__)
        d.set_comments('A/B kernel flash manager for Droidian '
                       '(repack boot.img, flash to the other slot, '
                       'automatic rollback)')
        d.set_website('https://github.com/javadxpro/HPC')
        d.set_license_type(Gtk.License.GPL_3_0)
        d.present()

    # --------------------------------------------------------------- cards
    def _card(self, title):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.append(Gtk.Label(label=title))
        return box

    def _build_status_card(self):
        card = self._card('Status')
        grid = Gtk.Grid()
        grid.set_row_spacing(4)
        grid.set_column_spacing(10)
        self.status_labels = {}
        rows = [
            ('root', 'Root (euid)'),
            ('kernel', 'Kernel'),
            ('slot', 'Slot'),
            ('boot_a', 'boot_a'),
            ('boot_b', 'boot_b'),
            ('markboot', 'markboot'),
            ('bootctl', 'bootctl'),
        ]
        for i, (key, label) in enumerate(rows):
            l = Gtk.Label(label=label)
            l.set_xalign(0.0)
            grid.attach(l, 0, i, 1, 1)
            v = Gtk.Label(label='…')
            v.set_xalign(0.0)
            v.set_selectable(True)
            self.status_labels[key] = v
            grid.attach(v, 1, i, 1, 1)
        card.append(grid)
        self.cmdline_label = Gtk.Label(label='')
        self.cmdline_label.set_xalign(0.0)
        self.cmdline_label.set_selectable(True)
        self.cmdline_label.set_line_wrap(True)
        self.cmdline_label.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        self.cmdline_label.add_css_class('dim-label')
        card.append(self.cmdline_label)
        self.root_banner = Gtk.Label(label='')
        self.root_banner.set_line_wrap(True)
        self.root_banner.set_no_show_all(True)
        self.root_banner.add_css_class('warning')
        card.append(self.root_banner)
        return card

    def _build_kernel_card(self):
        card = self._card('Kernel to install')
        self.radio355 = Gtk.RadioButton(label=KERNELS['355']['name']
                                        + '  (%s)'
                                        % human_kb(KERNELS['355']['size']))
        self.radio355.set_active(True)
        self.radio190 = Gtk.RadioButton(label=KERNELS['190']['name']
                                        + '  (%s)'
                                        % human_kb(KERNELS['190']['size']))
        self.radio190.set_group(self.radio355)
        card.append(self.radio355)
        card.append(self.radio190)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.local_btn = Gtk.Button(label='Local file…')
        self.local_btn.connect('clicked', self._choose_local)
        self.local_lbl = Gtk.Label(label='')
        self.local_lbl.set_xalign(0.0)
        self.local_lbl.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        self.local_lbl.set_hexpand(True)
        row.append(self.local_btn)
        row.append(self.local_lbl)
        card.append(row)
        return card

    def _choose_local(self, _btn):
        dlg = Gtk.FileChooserNative(
            new_title='Select kernel Image',
            parent=self,
            action=Gtk.FileChooserAction.OPEN)
        dlg.set_accept_label('Select')
        if dlg.run() == Gtk.ResponseType.ACCEPT:
            f = dlg.get_file()
            self.local_path = f.get_path()
            self.local_lbl.set_text(self.local_path)
        dlg.destroy()

    def _build_actions(self):
        box = self._card('Actions')
        self.progress = Gtk.ProgressBar()
        self.progress.set_no_show_all(True)
        box.append(self.progress)
        self.status_lbl = Gtk.Label(label='')
        self.status_lbl.set_xalign(0.0)
        self.status_lbl.set_line_wrap(True)
        box.append(self.status_lbl)
        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.btn_backup = Gtk.Button(label='Backup')
        self.btn_backup.connect('clicked',
                                lambda *_: self._job('backup'))
        self.btn_flash = Gtk.Button(label='Flash to other slot')
        self.btn_flash.add_css_class('suggested-action')
        self.btn_flash.set_hexpand(True)
        self.btn_flash.connect('clicked', lambda *_: self._confirm_flash())
        self.btn_restore = Gtk.Button(label='Restore')
        self.btn_restore.add_css_class('destructive-action')
        self.btn_restore.connect('clicked', lambda *_: self._job('restore'))
        self.btn_mark = Gtk.Button(label='Mark OK')
        self.btn_mark.set_tooltip_text(
            'Post-boot: mark the running slot as successful (run once '
            'after a successful boot on the new kernel)')
        self.btn_mark.connect('clicked', lambda *_: self._job('markok'))
        self.btn_reboot = Gtk.Button(label='Reboot')
        self.btn_reboot.connect('clicked', lambda *_: self._job('reboot'))
        for b in (self.btn_backup, self.btn_flash, self.btn_restore,
                  self.btn_mark, self.btn_reboot):
            btns.append(b)
        box.append(btns)
        return box

    def _build_log(self):
        box = self._card('Log')
        sw = Gtk.ScrolledWindow()
        sw.set_vexpand(True)
        sw.set_min_content_height(140)
        tv = Gtk.TextView()
        tv.set_editable(False)
        tv.set_monospace(True)
        tv.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        tv.set_left_margin(6)
        tv.set_right_margin(6)
        self.log_tv = tv
        sw.set_child(tv)
        box.append(sw)
        return box

    # ------------------------------------------------------------- status
    def log(self, msg):
        def _do():
            buf = self.log_tv.get_buffer()
            stamp = time.strftime('%H:%M:%S')
            buf.insert_at_cursor('%s  %s\n' % (stamp, msg), None)
            buf.place_cursor(buf.get_end_iter())
            self.log_tv.get_window().scroll_to_mark(
                buf.get_end_iter(), 0.5, False, 0, 0)
            return False
        GLib.idle_add(_do)

    def refresh_status(self):
        def _do():
            try:
                st = device.full_status()
            except Exception as e:
                self.log('status error: %s' % e)
                return False
            L = self.status_labels
            L['root'].set_text('root' if st['root']
                               else 'USER (sudo required)')
            L['kernel'].set_text(st['kernel_release'])
            if st['slot']:
                L['slot'].set_text(
                    '%s  (other: %s, via %s)'
                    % (st['slot'], st['other'], st['slot_source']))
            else:
                L['slot'].set_text('NOT DETECTED')
            L['boot_a'].set_text(st['boot_a'] or 'NOT FOUND')
            L['boot_b'].set_text(st['boot_b'] or 'NOT FOUND')
            mb = st['markboot'] or 'NOT FOUND'
            if st['markboot'] and st['markboot_set_active']:
                mb += '  (has --set-active-boot)'
            elif st['markboot']:
                mb += '  (no --set-active-boot)'
            L['markboot'].set_text(mb)
            L['bootctl'].set_text(st['bootctl'] or 'not found')
            cl = st['cmdline']
            self.cmdline_label.set_text(
                'cmdline: ' + (cl[:300] + '…' if len(cl) > 300 else cl))
            if not st['root']:
                self.root_banner.set_text(
                    '⚠ Run as root:  sudo hpc-kernel-manager\n'
                    '(the app must be elevated to read/write the boot '
                    'partitions and call markboot)')
                self.root_banner.set_visible(True)
                self.btn_backup.set_sensitive(False)
                self.btn_flash.set_sensitive(False)
                self.btn_restore.set_sensitive(False)
                self.btn_mark.set_sensitive(False)
                self.btn_reboot.set_sensitive(False)
            else:
                self.root_banner.set_visible(False)
            return False
        GLib.idle_add(_do)

    def _on_refresh(self):
        self.log('--- refresh ---')
        self.refresh_status()

    # -------------------------------------------------------------- jobs
    def _job(self, kind):
        if self.busy:
            return
        if kind == 'flash':
            return
        self._start(lambda prog: self._run_job(kind, prog))

    def _confirm_flash(self):
        if self.busy:
            return
        local = getattr(self, 'local_path', None)
        kernel = (local if local else
                  '355' if self.radio355.get_active() else '190')
        try:
            slot, _src = device.detect_slot()
            other = device.other_slot(slot) if slot else '?'
        except Exception:
            slot, other = '?', '?'
        name = KERNELS.get(kernel, {}).get('name', local or '?')
        dlg = Gtk.MessageDialog(
            transient_for=self, modal=True,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.NONE,
            text='Flash kernel %s to slot %s?' % (name, other))
        dlg.format_secondary_text(
            'The current slot (%s) stays untouched as a fallback.\n'
            'Steps: backup → download → repack → dd to %s → markboot '
            '(attempt mode, tries=%d) → you reboot.\n'
            'If the new kernel fails to boot, the ABL rolls back '
            'automatically.' % (slot, other, flasher.TRIES))
        for lbl, resp in (('Cancel', Gtk.ResponseType.CANCEL),
                          ('Flash', Gtk.ResponseType.OK)):
            b = dlg.add_button(lbl, resp)
            if resp == Gtk.ResponseType.OK:
                b.add_css_class('suggested-action')
        dlg.connect('response', self._on_flash_response, kernel)
        dlg.present()

    def _on_flash_response(self, dlg, resp, kernel):
        dlg.destroy()
        if resp == Gtk.ResponseType.OK:
            self._start(lambda prog: self._run_job('flash', prog, kernel))

    def _start(self, worker):
        """Run worker on a background thread; it must end by calling
        _finish_job (which hops back to the GTK thread itself)."""
        self.busy = True
        self.btn_backup.set_sensitive(False)
        self.btn_flash.set_sensitive(False)
        self.btn_restore.set_sensitive(False)
        self.btn_mark.set_sensitive(False)
        self.btn_reboot.set_sensitive(False)
        self.progress.set_no_show_all(False)
        self.progress.show()
        self.progress.pulse()
        threading.Thread(target=worker, daemon=True).start()

    def _finish_job(self):
        self.busy = False
        st = device.is_root()
        self.btn_backup.set_sensitive(st)
        self.btn_flash.set_sensitive(st)
        self.btn_restore.set_sensitive(st)
        self.btn_mark.set_sensitive(st)
        self.btn_reboot.set_sensitive(st)
        self.progress.hide()
        self.progress.set_no_show_all(True)
        self.refresh_status()
        return False

    def _run_job(self, kind, prog=None, kernel='355'):
        t0 = time.time()
        try:
            if kind == 'backup':
                path, slot = flasher.backup(self.log)
                self.status_lbl.set_text('Backup saved: %s' % path)
                self.log('job done: backup (%.1fs)' % (time.time() - t0))
            elif kind == 'flash':
                res = flasher.flash(self.log, kernel, progress=prog)
                self.status_lbl.set_text(
                    'FLASHED to slot %s. Reboot now, then (once booted) '
                    'press "Mark OK". Backup: %s'
                    % (res['other'], res['backup']))
                self.log('job done: flash (%.1fs) — REBOOT'
                         % (time.time() - t0))
            elif kind == 'restore':
                flasher.restore(self.log)
                self.status_lbl.set_text('Restore done. Reboot.')
                self.log('job done: restore (%.1fs)' % (time.time() - t0))
            elif kind == 'markok':
                flasher.mark_current_successful(self.log)
                self.status_lbl.set_text(
                    'Running slot marked successful (locked).')
                self.log('job done: mark-ok')
            elif kind == 'reboot':
                self.status_lbl.set_text('Rebooting…')
                flasher.reboot(self.log)
                return
        except FlashError as e:
            self.status_lbl.set_text('FAILED at [%s]: %s' % (e.stage, e))
            self.log('FAILED at [%s]: %s' % (e.stage, e))
        except Exception as e:
            self.status_lbl.set_text('FAILED: %s' % e)
            self.log('FAILED: %s' % e)
        finally:
            GLib.idle_add(self._finish_job)


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id='sm.puri.HPCKernelManager',
                         flags=Gio.ApplicationFlags.NON_UNIQUE)

    def do_activate(self):
        win = self.props.active_window
        if win is None:
            win = MainWindow(self)
        win.present()


def main():
    import sys
    app = App()
    return app.run(sys.argv)
