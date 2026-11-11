# -*- coding: utf-8 -*-
"""uinput_kbd — minimal Linux uinput virtual keyboard (stdlib only).

Creates a virtual keyboard via /dev/uinput and injects key events.
No third-party dependencies: ctypes + fcntl + os only, so the
keyboard installs with `dpkg -i` even when the Debian repositories
are unreachable.

Needs write access to /dev/uinput (root, or membership of the
'input' group). Raises PermissionError / UinputError otherwise.
"""
import ctypes
import fcntl
import os

EV_SYN = 0
EV_KEY = 1


def _IOW(nr):
    # _IOC(_IOC_WRITE=1, 'U', nr, sizeof(int)=4)
    return (1 << 30) | (4 << 16) | (ord('U') << 8) | nr


def _IO(nr):
    return (ord('U') << 8) | nr


UI_SET_EVBIT = _IOW(100)
UI_SET_KEYBIT = _IOW(101)
UI_DEV_CREATE = _IO(1)
UI_DEV_DESTROY = _IO(2)


class _InputId(ctypes.Structure):
    _fields_ = [('bustype', ctypes.c_ushort), ('vendor', ctypes.c_ushort),
                ('product', ctypes.c_ushort), ('version', ctypes.c_ushort)]


class _UinputUserDev(ctypes.Structure):
    _fields_ = [('name', ctypes.c_char * 80), ('id', _InputId),
                ('ff_effects_max', ctypes.c_uint),
                ('absmax', ctypes.c_int * 64), ('absmin', ctypes.c_int * 64),
                ('absfuzz', ctypes.c_int * 64), ('absflat', ctypes.c_int * 64)]


class _InputEvent(ctypes.Structure):
    _fields_ = [('tv_sec', ctypes.c_long), ('tv_usec', ctypes.c_long),
                ('type', ctypes.c_ushort), ('code', ctypes.c_ushort),
                ('value', ctypes.c_int)]


class UinputError(Exception):
    pass


class UinputKeyboard:
    """A virtual keyboard backed by a /dev/uinput device."""

    def __init__(self, name='HPC Keyboard', path='/dev/uinput'):
        self.name = name
        self.path = path
        self.fd = None

    def open(self, keycodes):
        """Create the device supporting the given key codes."""
        if not os.path.exists(self.path):
            raise UinputError(
                '%s not found (uinput module not loaded?)' % self.path)
        self.fd = os.open(self.path, os.O_WRONLY)
        try:
            fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_SYN)
            fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
            for code in keycodes:
                fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
            dev = _UinputUserDev()
            dev.name = self.name.encode('utf-8', 'replace')[:79]
            dev.id.bustype = 0x03  # BUS_USB
            dev.id.vendor = 0x1234
            dev.id.product = 0x5678
            dev.id.version = 1
            os.write(self.fd, bytes(dev))
            fcntl.ioctl(self.fd, UI_DEV_CREATE)
        except Exception:
            self.close()
            raise
        return self

    def _emit(self, code, value):
        os.write(self.fd, bytes(_InputEvent(0, 0, EV_KEY, code, value)))
        os.write(self.fd, bytes(_InputEvent(0, 0, EV_SYN, 0, 0)))

    def press(self, code):
        self._emit(code, 1)

    def release(self, code):
        self._emit(code, 0)

    def tap(self, code):
        self.press(code)
        self.release(code)

    def close(self):
        if self.fd is not None:
            try:
                fcntl.ioctl(self.fd, UI_DEV_DESTROY)
            except Exception:
                pass
            try:
                os.close(self.fd)
            except Exception:
                pass
            self.fd = None
