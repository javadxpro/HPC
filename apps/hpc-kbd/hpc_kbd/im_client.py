"""Wayland input-method-unstable-v2 client for hpc-kbd.

Uses a second Wayland connection (independent of the GTK window) purely to
speak the IM protocol with the compositor (phoc):

  - binds zwp_input_method_manager_v2
  - creates a dummy wl_surface for get_input_method (the visible UI is the
    GTK4 window; the raw surface only anchors the IM session)
  - receives activate / deactivate / surrounding_text
  - sends enter_text / delete_surrounding_text / commit

Wire integration with GLib: call display.dispatch(block=False) whenever the
display fd is readable (main.py installs the IO watch).
"""
import logging

log = logging.getLogger("hpc-kbd.im")

try:
    from pywayland import Display
except ImportError as e:  # pragma: no cover
    raise SystemExit(
        "pywayland is required (Debian package: python3-pywayland): %s" % e
    )

IM_MANAGER = "zwp_input_method_manager_v2"
IM_IFACE = "zwp_input_method_v2"


class ImClient:
    def __init__(self, on_activate=None, on_deactivate=None, on_surrounding=None):
        self.on_activate = on_activate
        self.on_deactivate = on_deactivate
        self.on_surrounding = on_surrounding

        self.im = None
        self.surface = None
        self.display = None
        self.active = False
        self.surrounding = ""
        self.cursor = 0
        self.anchor = 0
        self._connected = False

    # -- setup ---------------------------------------------------------
    def connect(self):
        self.display = Display()
        self.display.connect()
        reg = self.display.get_registry()

        def global_found(proxy, name, iface, version):
            if iface == IM_MANAGER:
                self._bind_manager(proxy, name, version)

        reg.event["global"] = global_found
        self.display.dispatch(block=False)
        self._connected = True
        log.info("wayland display connected, waiting for %s", IM_MANAGER)

    def _bind_manager(self, reg_proxy, name, version):
        manager = reg_proxy.bind(name, IM_MANAGER, min(version, 3))

        def manager_ready(proxy):
            log.info("input method manager ready (version %d)", version)
            compositor = self.display.get_compositor()
            # dummy surface anchoring the IM session (UI is the GTK window)
            self.surface = compositor.create_surface()
            self.im = manager.request("get_input_method", self.surface)
            self.im.event["activate"] = self._on_activate
            self.im.event["deactivate"] = self._on_deactivate
            self.im.event["surrounding_text"] = self._on_surrounding
            self.im.event["enter"] = lambda p: None
            self.im.event["leave"] = lambda p: None
            self.im.event["preedit"] = lambda p, t, a, b: None
            log.info("input method session established")

        manager.event["input_method"] = manager_ready
        self.display.dispatch(block=False)

    # -- events from the compositor ------------------------------------
    def _on_activate(self, proxy, surface):
        self.active = True
        log.info("IM activate")
        if self.on_activate:
            self.on_activate()

    def _on_deactivate(self, proxy):
        self.active = False
        log.info("IM deactivate")
        if self.on_deactivate:
            self.on_deactivate()

    def _on_surrounding(self, proxy, text, cursor, anchor):
        self.surrounding = text
        self.cursor = cursor
        self.anchor = anchor
        log.info("surrounding_text: %r cursor=%d anchor=%d", text, cursor, anchor)
        if self.on_surrounding:
            self.on_surrounding(text, cursor, anchor)

    # -- requests to the compositor ------------------------------------
    def _require(self):
        if not self.active or self.im is None:
            log.warning("text send ignored: IM not active")
            return False
        return True

    def send_text(self, text):
        if not self._require():
            return
        self.im.request("enter_text", text)
        self.display.dispatch(block=False)
        log.info("enter_text: %r", text)

    def backspace(self):
        if not self._require():
            return
        self.im.request("delete_surrounding_text", self.cursor, 1)
        self.display.dispatch(block=False)
        log.info("delete_surrounding_text(cursor=%d, 1)", self.cursor)

    def commit(self):
        if not self._require():
            return
        # commit needs a serial; phoc accepts 0 for client-driven commits
        self.im.request("commit", 0)
        self.display.dispatch(block=False)

    # -- GLib integration ----------------------------------------------
    def get_fd(self):
        return self.display.get_fd() if self.display else None

    def flush(self):
        if self.display and self._connected:
            self.display.dispatch(block=False)
            self.display.flush()
