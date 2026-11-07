# HPC Files

All-purpose dual-pane file manager for Linux — GTK4 + PyGObject (no
libadwaita dependency), inspired by the best features of ZArchiver, MT
Manager, Mixplorer and Material File Manager.

## Features

- **Dual-pane browsing** (toggle with the header button or Alt+Right/Left history)
- **Archive manager**: open *inside* archives (breadcrumb into the archive),
  extract (whole or selected members, with password), create
  (`zip`, `tar`, `tar.gz`, `tar.xz`, `7z`, `gz`), password-protected zip via
  optional `pyzipper`, delete/rename members inside a zip
- **Zip-slip protection** on every extraction
- **Trash** with per-file restore and empty-trash
- **Sidebar**: Places, mounted disks with usage bars, Recent files,
  Favorites (star any folder)
- **Copy / Cut / Paste** in-app (works between panes), progress bar with cancel
- **Search** inside current folder (200 ms debounce), **sort** by
  name / size / date / type, ascending/descending, hidden files toggle
- **Bulk rename** (find & replace / prefix / suffix with live preview)
- **Permissions (chmod)** dialog: rwx grid + octal input
- **Checksums**: MD5 / SHA-1 / SHA-256 for many files at once
- **Properties** with text preview, image preview, size/date/type
- **In-app text editor** for code/config/text files (monospace, wrap, dirty guard)
- **Open with…**, **Open in terminal** (auto-detects gnome/konsole/xfce4/xterm,
  overridable in Preferences), run executables
- **Keyboard**: Ctrl+C/X/V/A, Del, F2, F5, Alt+←/→, Backspace, Ctrl+L (go to path),
  Ctrl+D… (see below), Esc
- **Dark / light / auto** theme, per-pane window geometry + location restore

## Install

```bash
cd apps/hpc-files
sudo ./build-deb.sh            # builds the .deb, or:
dpkg -i build/hpc-files_0.1.0_all.deb
```

Dependencies (all in standard distro repos):

```
python3 python3-gi gir1.2-gtk-4.0 gir1.2-gdkpixbuf-4.0
```

Optional (extra formats/features):

```
pip install pyzipper py7zr     # password zips, 7z in pure Python
sudo apt install 7zip unrar    # or use system 7z / unrar binaries
```

## Run

```bash
hpc-files
# or
python3 -m hpc_files
```

## Notes

- State (window size, pane locations, preferences, favorites, recents) lives in
  `~/.local/share/hpc-files/`.
- Set the terminal explicitly in **Menu → Preferences** (e.g. `gnome-terminal`
  or `xfce4-terminal`); the app auto-detects otherwise.
- Network locations (FTP/SMB as in Mixplorer) are intentionally out of scope
  for v0.1 — this version focuses on doing local + archive management
  extremely well.

## Build layout

```
apps/hpc-files/
├── hpc_files/
│   ├── __init__.py      # version
│   ├── __main__.py      # python3 -m hpc_files
│   ├── app.py           # application shell, actions, clipboard, progress
│   ├── pane.py          # one browsing pane (list, crumbs, menus)
│   ├── dialogs.py       # all dialogs + in-app text editor
│   ├── archive.py       # zip/tar/7z/rar/gz engine (pure-stdlib + optional)
│   ├── fileops.py       # threaded copy/move/trash/delete with progress
│   └── utils.py         # state, sizes, checksums, terminal, mounts
├── hpc-files            # launcher script
├── hpc-files.desktop
├── data/hpc-files.svg
└── build-deb.sh
```
