#!/usr/bin/env python3
"""hpc-kbd 0.2.0 — on-screen keyboard for Droidian/Phosh (uinput backend).

A dep-free on-screen keyboard: emits keys through a Linux uinput
virtual keyboard device. Only needs python3-gi + stdlib (no
pywayland/cffi), so it installs with `dpkg -i` even when the Debian
repositories are unreachable.

Privilege: needs write access to /dev/uinput. Run as root
(`sudo -E hpc-kbd`) or tap "Run as root" in the app (pkexec; a
polkit rule shipped in the deb allows passwordless exec of hpc-kbd).

Layouts: EN (QWERTY), FA (Persian — output follows the system input
source, set it to Persian in Settings > Region & Language), symbols.
"""
import os
import sys
from pathlib import Path

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Gio

try:
    from hpc_kbd.uinput_kbd import UinputKeyboard, UinputError
    from hpc_kbd import layouts
except ImportError:  # running from the source tree
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from hpc_kbd.uinput_kbd import UinputKeyboard, UinputError
    from hpc_kbd import layouts

APP_ID = "org.hpc.Kbd"
APP_NAME = "HPC Keyboard"


def fix_wayland_env():
    """When re-exec'd as root (pkexec/sudo), WAYLAND_DISPLAY may be
    missing. Recover it from /run/user/*/wayland-* sockets."""
    if os.environ.get("WAYLAND_DISPLAY"):
        return
    import glob
    for sock in sorted(glob.glob("/run/user/*/wayland-*")):
        d = os.path.dirname(sock)
        os.environ["XDG_RUNTIME_DIR"] = d
        os.environ["WAYLAND_DISPLAY"] = os.path.basename(sock)
        break


class KbdWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app)
        self.set_title(APP_NAME)
        self.set_default_size(560, 440)
        self.kbd = None
        self.latched = set()
        self.layout_name = "en"
        self.page = "letters"  # or "symbols"
        self.mod_buttons = {}  # modifier code -> button

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        root.append(self._build_header())
        self.grid = Gtk.Grid()
        self.grid.set_column_spacing(4)
        self.grid.set_row_spacing(4)
        for m in ("top", "bottom", "start", "end"):
            getattr(self.grid, "set_margin_" + m)(6)
        root.append(self.grid)
        self.set_child(root)
        self._load_css()
        self._rebuild()
        self.connect("close-request", self._on_close)
        self._open_uinput()

    def _build_header(self):
        hb = Gtk.HeaderBar()
        hb.set_title_widget(Gtk.Label(label=APP_NAME))
        if hasattr(hb, "set_show_title_buttons"):
            hb.set_show_title_buttons(True)
        return hb

    def _load_css(self):
        css = b"""
        button.latched { background-color: #3584e4; color: white; }
        button { font-size: 15px; min-height: 44px; }
        """
        prov = Gtk.CssProvider()
        prov.load_from_data(css)
        disp = Gtk.Display.get_default()
        if disp is not None:
            Gtk.StyleContext.add_provider_for_display(
                disp, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    # ------------------------------------------------------------ layout
    def _current_rows(self):
        if self.page == "symbols":
            return layouts.SYMBOLS
        return layouts.LAYOUTS[self.layout_name]

    def _rebuild(self):
        child = self.grid.get_first_child()
        while child is not None:
            nxt = child.get_next_sibling()
            self.grid.remove(child)
            child = nxt
        self.mod_buttons = {}
        for r, row in enumerate(self._current_rows()):
            col = 0
            for key in row:
                w = key.get("w", 2)
                btn = Gtk.Button(label=key["label"])
                btn.set_hexpand(True)
                btn.set_vexpand(True)
                if "mod" in key:
                    code = key["mod"]
                    self.mod_buttons[code] = btn
                    if code in self.latched:
                        btn.add_css_class("latched")
                    btn.connect("clicked", self._on_modifier, code)
                elif "action" in key:
                    btn.connect("clicked", self._on_action, key["action"])
                else:
                    btn.connect("clicked", self._on_key, key)
                self.grid.attach(btn, col, r, w, 1)
                col += w

    # -------------------------------------------------------------- input
    def _open_uinput(self):
        kbd = UinputKeyboard()
        try:
            kbd.open(layouts.all_keycodes())
            self.kbd = kbd
        except PermissionError:
            self._ask_root("Permission denied opening /dev/uinput.")
        except UinputError as e:
            self._fatal(str(e))
        except OSError as e:
            self._fatal("Cannot open /dev/uinput: %s" % e)

    def _ask_root(self, detail):
        # Gtk.AlertDialog (GTK 4.18 API): new(msg), set_detail(),
        # set_buttons(), choose() -> choose_finish() returns int index.
        dlg = Gtk.AlertDialog.new("Keyboard needs root")
        dlg.set_detail(
            detail + "\n\nThe on-screen keyboard creates a virtual "
            "keyboard device (/dev/uinput), which needs root.\n"
            "Tap 'Run as root', or run in a terminal:\n"
            "  sudo -E hpc-kbd")
        dlg.set_buttons(["Quit", "Run as root"])
        dlg.set_cancel_button(0)
        dlg.set_default_button(1)
        dlg.choose(self, None, self._on_root_choice, None)

    def _on_root_choice(self, dlg, result, _data):
        try:
            idx = dlg.choose_finish(result)
        except Exception:
            idx = -1
        dlg.destroy()
        if idx == 1:
            self._reexec_root()
        else:
            self.close()

    def _reexec_root(self):
        exe = "/usr/bin/hpc-kbd"
        if os.path.exists(exe):
            cmd = ["pkexec", exe]
        else:
            cmd = ["pkexec", sys.executable, os.path.abspath(sys.argv[0])]
        try:
            os.execvp(cmd[0], cmd)
        except Exception as e:
            self._fatal("pkexec failed: %s" % e)

    def _fatal(self, msg):
        dlg = Gtk.AlertDialog.new(APP_NAME)
        dlg.set_detail(msg)
        dlg.set_buttons(["OK"])
        dlg.set_default_button(0)
        dlg.choose(self, None, lambda d, r, _u: d.destroy(), None)

    def _on_close(self, _win):
        if self.kbd is not None:
            self.kbd.close()
            self.kbd = None
        return False

    def _on_modifier(self, btn, code):
        if self.kbd is None:
            return
        if code in self.latched:
            self.latched.discard(code)
            self.kbd.release(code)
            btn.remove_css_class("latched")
        else:
            self.latched.add(code)
            self.kbd.press(code)
            btn.add_css_class("latched")

    def _on_action(self, _btn, action):
        if action == "page":
            self.page = "symbols" if self.page == "letters" else "letters"
        elif action == "layout":
            self.layout_name = "fa" if self.layout_name == "en" else "en"
        self._rebuild()

    def _on_key(self, _btn, key):
        if self.kbd is None:
            return
        codes = key.get("codes", [])
        # press any modifiers this key needs that are not already latched
        temp = [c for c in codes
                if c in layouts.MODIFIERS and c not in self.latched]
        for c in temp:
            self.kbd.press(c)
        for c in codes:
            if c not in layouts.MODIFIERS:
                self.kbd.tap(c)
        for c in reversed(temp):
            self.kbd.release(c)
        # one-shot: release latched modifiers after a key
        if self.latched:
            for c in list(self.latched):
                self.kbd.release(c)
            self.latched.clear()
            for btn in self.mod_buttons.values():
                btn.remove_css_class("latched")


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID,
                         flags=Gio.ApplicationFlags.NON_UNIQUE)

    def do_activate(self):
        win = self.props.active_window
        if win is None:
            win = KbdWindow(self)
        win.present()


def main():
    fix_wayland_env()
    app = App()
    return app.run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
