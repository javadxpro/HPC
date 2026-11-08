# -*- coding: utf-8 -*-
"""HPC V2Ray — GTK4 application window (VLESS client)."""
import os
import threading
import time

from gi.repository import Gtk, Gio, GLib, Pango

from . import engine
from . import vlink
from .vlink import VLinkError
from . import __version__, APP_NAME


class MainWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app)
        self.app = app
        self.set_default_size(520, 640)
        self.set_title(APP_NAME)
        self.store = engine.ProfileStore()
        self.prefs = engine.load_json('prefs.json', {
            'socks_port': engine.DEFAULT_SOCKS_PORT,
            'http_port': engine.DEFAULT_HTTP_PORT,
            'tun_mtu': engine.DEFAULT_TUN_MTU,
            'bypass_ir': True,
            'mode': 'socks',
            'theme': 'auto',
        })
        self.rows = []          # (row, idx)
        self._status_to = None

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.append(self._build_header())

        # engine banner
        self.engine_label = Gtk.Label(label='')
        self.engine_label.set_xalign(0.0)
        self.engine_label.add_css_class('dim-label')
        self.engine_label.set_margin_top(4)
        self.engine_label.set_margin_start(10)
        self.engine_label.set_margin_end(10)
        root.append(self.engine_label)

        # profile list
        sw = Gtk.ScrolledWindow()
        sw.set_vexpand(True)
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.list = Gtk.ListBox()
        self.list.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.list.connect('row-selected', self._on_row_selected)
        sw.set_child(self.list)
        root.append(sw)

        # mode + control bar
        bar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        for m in ('top', 'bottom', 'start', 'end'):
            getattr(bar, 'set_margin_' + m)(10)

        mode_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL,
                           spacing=8)
        self.radio_local = Gtk.RadioButton(label='Local (SOCKS/HTTP)')
        self.radio_tun = Gtk.RadioButton(label='System (TUN)')
        self.radio_tun.set_group(self.radio_local)
        self.radio_local.connect('toggled', self._on_mode)
        if self.prefs.get('mode') == 'tun':
            self.radio_tun.set_active(True)
        mode_row.append(self.radio_local)
        mode_row.append(self.radio_tun)
        bar.append(mode_row)

        btn_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.btn_toggle = Gtk.Button(label='Start')
        self.btn_toggle.add_css_class('suggested-action')
        self.btn_toggle.set_hexpand(True)
        self.btn_toggle.connect('clicked', self._on_toggle)
        self.btn_add = Gtk.Button.new_from_icon_name('list-add-symbolic')
        self.btn_add.set_tooltip_text('Add profile (paste vless:// link)')
        self.btn_add.connect('clicked', self._add_profile)
        self.btn_del = Gtk.Button.new_from_icon_name('user-trash-symbolic')
        self.btn_del.set_tooltip_text('Remove selected profile')
        self.btn_del.connect('clicked', self._del_profile)
        btn_row.append(self.btn_toggle)
        btn_row.append(self.btn_add)
        btn_row.append(self.btn_del)
        bar.append(btn_row)

        self.status_label = Gtk.Label(label='')
        self.status_label.set_xalign(0.0)
        self.status_label.set_line_wrap(True)
        bar.append(self.status_label)
        root.append(bar)

        self.set_child(root)
        self._add_actions()
        self._apply_theme()
        self.refresh_profiles()
        self.refresh_status()

        if self._status_to is None:
            self._status_to = GLib.timeout_add(1000, self._tick)

    # -------------------------------------------------------------- header
    def _build_header(self):
        hb = Gtk.HeaderBar()
        hb.set_show_close_button(True)
        hb.set_title_widget(Gtk.Label(label='HPC V2Ray'))
        btn_menu = Gtk.MenuButton()
        btn_menu.set_icon_name('open-menu-symbolic')
        pop = Gtk.Popover()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        for m in ('top', 'bottom', 'start', 'end'):
            getattr(box, 'set_margin_' + m)(6)

        def mb(label, action):
            b = Gtk.ModelButton()
            b.set_label(label)
            b.set_action_name(action)
            box.append(b)

        mb('Preferences', 'win.prefs')
        mb('Refresh engine info', 'win.refresh-engine')
        mb('About HPC V2Ray', 'win.about')
        pop.set_child(box)
        btn_menu.set_popover(pop)
        hb.pack_end(btn_menu)
        return hb

    # -------------------------------------------------------------- prefs
    def _add_actions(self):
        def simple(name, cb):
            a = Gtk.SimpleAction.new(name)
            a.connect('activate', cb)
            self.add_action(a)

        simple('prefs', lambda a: self._prefs_dialog())
        simple('refresh-engine', lambda a: self.refresh_status())
        simple('about', lambda a: self._about())

    def _prefs_dialog(self):
        d = Gtk.Window()
        d.set_transient_for(self)
        d.set_modal(True)
        d.set_default_size(360, -1)
        d.set_title('Preferences')
        hb = Gtk.HeaderBar()
        hb.set_show_close_button(True)
        hb.set_title_widget(Gtk.Label(label='Preferences'))
        d.set_titlebar(hb)
        grid = Gtk.Grid()
        for m in ('top', 'bottom', 'start', 'end'):
            getattr(grid, 'set_margin_' + m)(12)
        grid.set_row_spacing(8)
        grid.set_column_spacing(8)

        e_socks = Gtk.Entry(text=str(self.prefs.get('socks_port', 10808)))
        e_http = Gtk.Entry(text=str(self.prefs.get('http_port', 10809)))
        e_mtu = Gtk.Entry(text=str(self.prefs.get('tun_mtu', 1500)))
        chk_ir = Gtk.CheckButton(label='Bypass Iran domains directly '
                                       '(geosite:category-ir)')
        chk_ir.set_active(bool(self.prefs.get('bypass_ir', True)))
        radio_auto = Gtk.RadioButton(label='Auto')
        radio_light = Gtk.RadioButton(label='Light')
        radio_light.set_group(radio_auto)
        radio_dark = Gtk.RadioButton(label='Dark')
        radio_dark.set_group(radio_auto)
        t = self.prefs.get('theme', 'auto')
        {'light': radio_light, 'dark': radio_dark}.get(t, radio_auto) \
            .set_active(True)

        def row(i, label, w):
            l = Gtk.Label(label=label)
            l.set_xalign(0.0)
            grid.attach(l, 0, i, 1, 1)
            grid.attach(w, 1, i, 1, 1)

        row(0, 'SOCKS port', e_socks)
        row(1, 'HTTP port', e_http)
        row(2, 'TUN MTU', e_mtu)
        grid.attach(chk_ir, 0, 3, 2, 1)
        trow = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        for w in (radio_auto, radio_light, radio_dark):
            trow.append(w)
        row(4, 'Theme', trow)

        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        for m in ('top', 'bottom', 'start', 'end'):
            getattr(btns, 'set_margin_' + m)(10)
        ok = Gtk.Button(label='Save')
        ok.add_css_class('suggested-action')
        cancel = Gtk.Button(label='Cancel')
        cancel.connect('clicked', lambda *_: d.close())

        def do_save(_=None):
            try:
                self.prefs['socks_port'] = int(e_socks.get_text().strip()
                                               or 10808)
                self.prefs['http_port'] = int(e_http.get_text().strip()
                                              or 10809)
                self.prefs['tun_mtu'] = int(e_mtu.get_text().strip() or 1500)
            except ValueError:
                pass
            self.prefs['bypass_ir'] = chk_ir.get_active()
            self.prefs['theme'] = ('light' if radio_light.get_active()
                                   else 'dark' if radio_dark.get_active()
                                   else 'auto')
            engine.save_json('prefs.json', self.prefs)
            self._apply_theme()
            d.close()
        ok.connect('clicked', do_save)
        btns.append(cancel)
        btns.append(ok)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(grid)
        box.append(btns)
        d.set_child(box)
        d.present()

    def _about(self):
        a = Gtk.AboutDialog()
        a.set_transient_for(self)
        a.set_modal(True)
        a.set_program_name('HPC V2Ray')
        a.set_version(__version__)
        a.set_comments('VLESS client for Linux — HPC project')
        a.set_website('https://github.com/javadxpro/HPC')
        a.set_license_type(Gtk.License.GPL_3_0)
        a.present()

    def _apply_theme(self):
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

    # ------------------------------------------------------------ profiles
    def refresh_profiles(self):
        for r, _ in self.rows:
            self.list.remove(r)
        self.rows = []
        ps = self.store.profiles()
        for i, p in enumerate(ps):
            r = Gtk.ListBoxRow()
            box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            box.set_margin_top(4)
            box.set_margin_bottom(4)
            ico = Gtk.Image.new_from_icon_name('network-transmit-symbolic')
            box.append(ico)
            name = Gtk.Label(label=p.name or p.address)
            name.set_xalign(0.0)
            name.set_ellipsize(Pango.EllipsizeMode.END)
            name.set_hexpand(True)
            box.append(name)
            badge = Gtk.Label(label='%s/%s' % (p.type, p.security))
            badge.add_css_class('dim-label')
            box.append(badge)
            r.set_child(box)
            r.set_tooltip_text(p.summary())
            self.list.append(r)
            self.rows.append((r, i))
        active = self.store.data.get('active', 0)
        if 0 <= active < len(self.rows):
            self.list.select_row(self.rows[active][0])

    def _on_row_selected(self, lst, row):
        for r, i in self.rows:
            if r is row:
                self.store.set_active(i)
                break
        self.refresh_status()

    def _add_profile(self):
        d = Gtk.Window()
        d.set_transient_for(self)
        d.set_modal(True)
        d.set_default_size(480, 360)
        d.set_title('Add profile')
        hb = Gtk.HeaderBar()
        hb.set_show_close_button(True)
        hb.set_title_widget(Gtk.Label(label='Add VLESS profile(s)'))
        d.set_titlebar(hb)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        for m in ('top', 'bottom', 'start', 'end'):
            getattr(box, 'set_margin_' + m)(12)
        l = Gtk.Label(label='Paste one or more vless:// links '
                            '(subscriptions work too — multiple lines)')
        l.set_xalign(0.0)
        l.set_line_wrap(True)
        box.append(l)
        sw = Gtk.ScrolledWindow()
        sw.set_vexpand(True)
        tv = Gtk.TextView()
        tv.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        sw.set_child(tv)
        box.append(sw)
        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        ok = Gtk.Button(label='Add')
        ok.add_css_class('suggested-action')
        cancel = Gtk.Button(label='Cancel')
        cancel.connect('clicked', lambda *_: d.close())
        msg = Gtk.Label(label='')
        msg.set_xalign(0.0)

        def do_add(_=None):
            b = tv.get_buffer()
            s, e = b.get_bounds()
            text = b.get_text(s, e, False)
            ps = vlink.parse_subscription(text)
            if not ps:
                msg.set_text('No valid vless:// links found')
                return
            for p in ps:
                self.store.add(p)
            self.refresh_profiles()
            self.refresh_status()
            d.close()
        ok.connect('clicked', do_add)
        btns.append(msg)
        btns.append(cancel)
        btns.append(ok)
        box.append(btns)
        d.set_child(box)
        d.present()

    def _del_profile(self):
        sel = self.list.get_selected_row()
        for r, i in self.rows:
            if r is sel:
                self.store.remove(i)
                self.refresh_profiles()
                self.refresh_status()
                break

    def _on_mode(self, radio):
        if radio.get_active():
            self.prefs['mode'] = 'tun' if radio is self.radio_tun else 'socks'
            engine.save_json('prefs.json', self.prefs)

    # -------------------------------------------------------------- engine
    def _on_toggle(self, _btn):
        st = engine.current_status()
        if st['running']:
            self._do(engine.stop)
        else:
            p = self.store.active()
            if p is None:
                self.status_label.set_text('Add a profile first')
                return
            mode = 'tun' if self.radio_tun.get_active() else 'socks'
            if mode == 'tun' and os.geteuid() != 0:
                self.status_label.set_text(
                    'TUN mode needs root. Start as root, or use Local mode. '
                    '(The core is launched with your privileges.)')
                return
            args = dict(
                mode=mode,
                socks_port=self.prefs.get('socks_port'),
                http_port=self.prefs.get('http_port'),
                tun_mtu=self.prefs.get('tun_mtu'),
                bypass_ir=self.prefs.get('bypass_ir', True),
            )
            self._do(lambda: engine.start(p, **args))

    def _do(self, fn):
        self.btn_toggle.set_sensitive(False)
        self.status_label.set_text('…')

        def worker():
            ok, msg = (False, 'unknown error')
            try:
                ok, msg = fn()
            except Exception as e:
                msg = str(e)

            def done():
                self.btn_toggle.set_sensitive(True)
                self.refresh_status()
                self.status_label.set_text(
                    ('OK: ' if ok else 'ERROR: ') + msg)
                return False
            GLib.idle_add(done)
        threading.Thread(target=worker, daemon=True).start()

    def refresh_status(self):
        st = engine.current_status()
        v2ray = engine.find_binary()
        parts = []
        if v2ray:
            ver = engine.version(v2ray)
            parts.append('engine: %s' % (ver if ver
                                         else os.path.basename(v2ray)))
            if not engine.geo_available(v2ray):
                parts.append('geo files missing (rules limited)')
        else:
            parts.append('NO v2ray binary found (set HPC_V2RAY_BIN)')
        self.engine_label.set_text('   |   '.join(parts))
        if st['running']:
            self.btn_toggle.set_label('Stop')
            self.btn_toggle.remove_css_class('suggested-action')
            self.btn_toggle.add_css_class('destructive-action')
            mode = 'TUN' if st['mode'] == 'tun' else 'Local'
            run = engine.load_json('run.json', {})
            up = time.strftime('%H:%M:%S',
                               time.gmtime(max(0, st['uptime'])))
            self.status_label.set_text(
                'RUNNING — %s [%s] up %s — socks 127.0.0.1:%s http :%s'
                % (st['profile'] or '?', mode, up,
                   run.get('socks', 10808), run.get('http', 10809)))
        else:
            self.btn_toggle.set_label('Start')
            self.btn_toggle.remove_css_class('destructive-action')
            self.btn_toggle.add_css_class('suggested-action')
            p = self.store.active()
            self.status_label.set_text(
                'Stopped — %d profile(s)' % len(self.store.profiles()) +
                (' (active: %s)' % p.name if p else ''))

    def _tick(self):
        self.refresh_status()
        return True


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id='sm.puri.HPCV2Ray',
                         flags=Gio.ApplicationFlags.NON_UNIQUE)
        self._win = None

    def do_activate(self):
        win = self.props.active_window
        if win is None:
            win = MainWindow(self)
            self._win = win
        win.present()


def main():
    import sys
    app = App()
    return app.run(sys.argv)
