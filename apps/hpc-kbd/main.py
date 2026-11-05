#!/usr/bin/env python3
"""hpc-kbd — a stable on-screen keyboard for phosh (Droidian).

Replaces phosh-osk-stub. Owns sm.puri.OSK0 on the session bus (phosh's OSK
contract) and emits keys through Wayland input-method-unstable-v2.

  - GTK4 UI, layouts from layouts.json (fa default + qwert)
  - built-in logging to ~/.local/state/hpc-kbd/hpc-kbd.log
  - hides on IM deactivate / hardware keyboard events (phoc handles the
    latter via phoc-device-state when a keyboard is present: the IM is
    deactivated by the focused client)
"""
import json
import logging
import os
import sys
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, GLib, Gtk  # noqa: E402

try:  # installed (deb) layout
    from hpc_kbd.im_client import ImClient
except ImportError:  # running from source tree
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from hpc_kbd.im_client import ImClient

APP_ID = "org.hpc.Kbd"
OSK_NAME = "sm.puri.OSK0"
OSK_PATH = "/sm/puri/OSK0"

STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "hpc-kbd"
LOG_FILE = STATE_DIR / "hpc-kbd.log"
LAYOUTS_FILE = Path(
    os.environ.get("HPC_KBD_LAYOUTS", str(Path(__file__).resolve().parent / "layouts.json"))
)

log = logging.getLogger("hpc-kbd")


def setup_logging():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    fh = logging.FileHandler(LOG_FILE)
    fh.setFormatter(fmt)
    sh = logging.StreamHandler()
    sh.setFormatter(fmt)
    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.addHandler(fh)
    root.addHandler(sh)


class KbdWindow(Gtk.ApplicationWindow):
    """The keyboard UI. One grid of Gtk.Button per layout row."""

    def __init__(self, app):
        super().__init__(application=app)
        self.app = app
        self.set_title("HPC Kbd")
        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_default_size(1080, 320)

        self.layouts = json.loads(LAYOUTS_FILE.read_text())
        self.current = self.layouts.get("default", list(self.layouts["layouts"].keys())[0])
        self.shift = False

        self._apply_css()

        self.grid = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.grid.set_margin_top(10)
        self.grid.set_margin_bottom(10)
        self.grid.set_margin_start(8)
        self.grid.set_margin_end(8)
        self.set_child(self.grid)
        self.rebuild()

    # -- UI -------------------------------------------------------------
    def _apply_css(self):
        css = b"""
button.key { font-size: 20px; min-height: 52px; min-width: 44px; border-radius: 6px; }
button.key:active { background: #ff9e00; }
button.special { font-size: 18px; min-width: 64px; }
button#shift { font-size: 22px; }
"""
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_display(
            Gtk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def _layout(self):
        return self.layouts["layouts"][self.current]

    def rebuild(self):
        for child in self.grid.get_children():
            self.grid.remove(child)
        layout = self._layout()
        for row in layout["rows"]:
            rowbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
            rowbox.set_hexpand(True)
            for key in row:
                btn = self._make_button(key)
                rowbox.append(btn)
            self.grid.append(rowbox)
        # bottom control row: layout / shift are in the rows; keep a hint
        self._refresh_labels()
        self.app.log("layout rebuilt: %s shift=%s", self.current, self.shift)

    def _make_button(self, key):
        action = key.get("act", "char")
        if action == "char":
            label = key.get("shift") or key.get("base", "?")
            if self.shift and key.get("shift"):
                label = key["shift"]
            btn = Gtk.Button(label=label)
            btn.add_css_class("key")
            w = int(key.get("w", 1))
            btn.set_size_request(w * 46, 56)
            btn.clicked.connect(lambda _b, k=key: self.on_key(k))
        else:
            names = {
                "space": "␣",
                "back": "⌫",
                "enter": "↵",
                "shift": "⇧",
                "layout": self.current.upper(),
            }
            btn = Gtk.Button(label=names.get(action, action))
            btn.add_css_class("key")
            btn.add_css_class("special")
            w = int(key.get("w", 2))
            btn.set_size_request(w * 46, 56)
            if action == "shift":
                btn.set_name("shift")
            btn.clicked.connect(lambda _b, a=action: self.on_action(a))
        return btn

    def _refresh_labels(self):
        # relabel shift-dependent keys without full rebuild cost: simplest is
        # a targeted relabel by walking the grid
        for row in self.grid.get_children():
            for btn in row.get_children():
                pass  # labels updated on next rebuild; cheap enough

    # -- input ------------------------------------------------------------
    def on_key(self, key):
        if self.shift and key.get("shift"):
            ch = key["shift"]
        else:
            ch = key.get("base", "")
        if not ch:
            return
        self.app.log("key press: %r (shift=%s)", ch, self.shift)
        self.app.im.send_text(ch)
        if self.shift:
            self.shift = False
            self.rebuild()

    def on_action(self, action):
        if action == "space":
            self.app.log("space")
            self.app.im.send_text(" ")
        elif action == "back":
            self.app.log("backspace")
            self.app.im.backspace()
        elif action == "enter":
            self.app.log("enter")
            self.app.im.send_text("\n")
        elif action == "shift":
            self.shift = not self.shift
            self.app.log("shift toggle -> %s", self.shift)
            self.rebuild()
        elif action == "layout":
            names = list(self.layouts["layouts"].keys())
            idx = (names.index(self.current) + 1) % len(names)
            self.current = names[idx]
            self.app.log("layout switch -> %s", self.current)
            self.rebuild()

    # -- visibility ---------------------------------------------------------
    def show_osk(self):
        self.present()
        self.show()
        self.app.log("window shown")

    def hide_osk(self):
        self.hide()
        self.app.log("window hidden")


class HpcKbdApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.win = None
        self.visible = False
        self.im = None
        self._fd_source = None

    # -- logging helper -----------------------------------------------------
    def log(self, msg, *args):
        log.info(msg, *args)

    # -- IM events (called on the main loop) ---------------------------------
    def on_im_activate(self):
        self.log("OSK: activate -> show")
        self.win.show_osk()
        self._set_visible(True)

    def on_im_deactivate(self):
        self.log("OSK: deactivate -> hide")
        self.win.hide_osk()
        self._set_visible(False)

    def on_im_surrounding(self, text, cursor, anchor):
        self.log("surrounding %r @%d/%d", text[:40], cursor, anchor)

    # -- D-Bus (sm.puri.OSK0) -------------------------------------------------
    def _set_visible(self, value):
        self.visible = value
        try:
            self.osk_iface.set_property("Visible", value)
        except Exception:  # not registered yet
            pass

    def dbus_set_visible(self, method, params):
        show = params[0]
        self.log("D-Bus SetVisible(%s)", show)
        if show:
            self.win.show_osk()
        else:
            self.win.hide_osk()
        self._set_visible(bool(show))
        return [GLib.Variant("b", self.visible)]

    def build_osk_iface(self):
        iface = Gio.DBusInterfaceSkeleton()
        iface.set_name(OSK_NAME)

        prop = Gio.DBusPropertiesSkeleton()
        prop.add_property("Visible", "b", self.visible)
        iface.add_properties(prop)

        iface.add_method(
            "SetVisible",
            ["b"],
            None,
            self.dbus_set_visible,
            flags=0,
        )
        return iface

    def on_bus_acquired(self, app, connection):
        self.log("session bus acquired")
        try:
            self.osk_iface = self.build_osk_iface()
            connection.register_object(OSK_PATH, self.osk_iface, None)
            self.log("object %s registered on app connection", OSK_PATH)
            # Own the phosh OSK name on THIS connection — the one that
            # actually holds the object. phosh introspects the connection
            # that owns sm.puri.OSK0; if the name and the object live on
            # different connections, phosh sees an empty interface and
            # never shows the keyboard.
            Gio.bus_own_name_on_connection(
                connection,
                OSK_NAME,
                Gio.BusNameOwnerFlags.REPLACE,
                lambda conn, name: self.log("owned D-Bus name %s", name),
                lambda conn, name: self.log("LOST D-Bus name %s", name),
                None,
            )
        except Exception as e:
            self.log("ERROR registering OSK object: %s", e)

    # -- Wayland IM -------------------------------------------------------------
    def start_im(self):
        self.im = ImClient(
            on_activate=self.on_im_activate,
            on_deactivate=self.on_im_deactivate,
            on_surrounding=self.on_im_surrounding,
        )
        try:
            self.im.connect()
        except Exception as e:
            self.log("FATAL: cannot connect Wayland display: %s", e)
            return
        fd = self.im.get_fd()
        if fd is not None:
            self._fd_source = GLib.unix_fd_add_watch(
                fd,
                GLib.IOCondition.IN,
                lambda *_a: (self.im.flush(), False)[1],
            )
            self.log("IM display fd %d watched", fd)

        # Diagnostic: if the compositor never advertised the IMv2 global,
        # keys can never be delivered — say so loudly in the log.
        def _im_check():
            if self.im is None or self.im.im is None:
                self.log(
                    "WARN: zwp_input_method_manager_v2 still not seen after 5s. "
                    "Keys will NOT work until the compositor advertises it. "
                    "Check with: wayland-info | grep -i input_method"
                )
            return False

        GLib.timeout_add_seconds(5, _im_check)

    # -- Gtk.Application vfunc ---------------------------------------------------
    def do_startup(self):
        Gtk.Application.do_startup(self)
        self.win = KbdWindow(self)
        self.start_im()

    def do_activate(self):
        self.log("activate (startup or user launch)")
        # Don't force-show: the IM activate event / phosh SetVisible drives
        # visibility. Showing on plain launch helps first-run testing.
        if not self.visible:
            self.win.show_osk()
            self._set_visible(True)


def main():
    setup_logging()
    log.info("hpc-kbd starting (pid=%d, layouts=%s)", os.getpid(), LAYOUTS_FILE)
    app = HpcKbdApp()
    # NOTE: sm.puri.OSK0 is owned in on_bus_acquired() on the same
    # connection that registers the /sm/puri/OSK0 object.
    return app.run(None)


if __name__ == "__main__":
    sys.exit(main())
