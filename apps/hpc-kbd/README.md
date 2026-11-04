# hpc-kbd — stable on-screen keyboard for phosh (Droidian Vayu)

Replaces `phosh-osk-stub`. `.deb` (Architecture: all, pure Python):

- GTK4 UI, layouts in `layouts.json` (fa = standard Persian/IRAN, qwert)
- key emission via **Wayland input-method-unstable-v2** (pywayland client;
  bindings generated from Droidian's own wlroots protocol XML, kept in
  `hpc_kbd/wl/`)
- owns **sm.puri.OSK0** on the session bus (phosh OSK contract:
  `SetVisible(b)` + `Visible` property), xdg autostart,
  `X-GNOME-Provides=inputmethod`, `X-GNOME-AutoRestart`
- built-in logging: `~/.local/state/hpc-kbd/hpc-kbd.log`

Build: `./build-deb.sh` -> `hpc-kbd_0.1.0_all.deb`
Install on Droidian: `dpkg -i hpc-kbd_0.1.0_all.deb` (deps: python3-gi,
gir1.2-gtk-4.0, python3-pywayland)
