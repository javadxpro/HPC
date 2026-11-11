# -*- coding: utf-8 -*-
"""layouts — on-screen keyboard layouts as Linux input key codes.

Each layout is a list of rows; each row is a list of key dicts:
  {'label': str, 'codes': [int, ...], 'w': int}   regular key (tap)
  {'label': str, 'mod': int, 'w': int}            latching modifier
  {'label': str, 'action': str, 'w': int}         UI action key
'w' is the grid column span (each row sums to COLS; default 2).

NOTE: uinput sends key *codes*, not characters. The character a code
produces comes from the system keymap, so the FA layout only outputs
Persian when the system input source is set to Persian (Settings >
Region & Language > Input Sources > add Persian). EN works with the
default US keymap.
"""

COLS = 20

# --- key codes (linux/input-event-codes.h) ---
KEY_ESC = 1
KEY_1, KEY_2, KEY_3, KEY_4, KEY_5 = 2, 3, 4, 5, 6
KEY_6, KEY_7, KEY_8, KEY_9, KEY_0 = 7, 8, 9, 10, 11
KEY_MINUS, KEY_EQUAL = 12, 13
KEY_BACKSPACE, KEY_TAB = 14, 15
KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T = 16, 17, 18, 19, 20
KEY_Y, KEY_U, KEY_I, KEY_O, KEY_P = 21, 22, 23, 24, 25
KEY_LEFTBRACE, KEY_RIGHTBRACE = 26, 27
KEY_ENTER = 28
KEY_LEFTCTRL = 29
KEY_A, KEY_S, KEY_D, KEY_F, KEY_G = 30, 31, 32, 33, 34
KEY_H, KEY_J, KEY_K, KEY_L = 35, 36, 37, 38
KEY_SEMICOLON, KEY_APOSTROPHE, KEY_GRAVE = 39, 40, 41
KEY_LEFTSHIFT = 42
KEY_BACKSLASH = 43
KEY_Z, KEY_X, KEY_C, KEY_V, KEY_B = 44, 45, 46, 47, 48
KEY_N, KEY_M = 49, 50
KEY_COMMA, KEY_DOT, KEY_SLASH = 51, 52, 53
KEY_LEFTALT = 56
KEY_SPACE = 57
KEY_HOME, KEY_UP = 102, 103
KEY_LEFT, KEY_RIGHT = 105, 106
KEY_END, KEY_DOWN = 107, 108
KEY_INSERT, KEY_DELETE = 110, 111

MODIFIERS = {KEY_LEFTSHIFT, KEY_LEFTCTRL, KEY_LEFTALT}


def K(label, *codes, **kw):
    d = {'label': label, 'codes': list(codes)}
    d.update(kw)
    return d


def M(label, code, **kw):
    d = {'label': label, 'mod': code}
    d.update(kw)
    return d


def A(label, action, **kw):
    d = {'label': label, 'action': action}
    d.update(kw)
    return d


def _numbers():
    return [K('1', KEY_1), K('2', KEY_2), K('3', KEY_3), K('4', KEY_4),
            K('5', KEY_5), K('6', KEY_6), K('7', KEY_7), K('8', KEY_8),
            K('9', KEY_9), K('0', KEY_0)]


def _nav():
    return [K('Tab', KEY_TAB), K('Esc', KEY_ESC), K('←', KEY_LEFT),
            K('↑', KEY_UP), K('↓', KEY_DOWN), K('→', KEY_RIGHT),
            K('Home', KEY_HOME), K('End', KEY_END), K('Del', KEY_DELETE),
            K('Ins', KEY_INSERT)]


def _bottom(layout_label):
    return [M('Ctrl', KEY_LEFTCTRL, w=3), M('Alt', KEY_LEFTALT, w=3),
            K('Space', KEY_SPACE, w=6), K('Enter', KEY_ENTER, w=4),
            A('?123', 'page', w=2), A(layout_label, 'layout', w=2)]


EN = [
    _numbers(),
    [K('q', KEY_Q), K('w', KEY_W), K('e', KEY_E), K('r', KEY_R),
     K('t', KEY_T), K('y', KEY_Y), K('u', KEY_U), K('i', KEY_I),
     K('o', KEY_O), K('p', KEY_P)],
    [K('a', KEY_A), K('s', KEY_S), K('d', KEY_D), K('f', KEY_F),
     K('g', KEY_G), K('h', KEY_H), K('j', KEY_J), K('k', KEY_K),
     K('l', KEY_L), K(';', KEY_SEMICOLON)],
    [M('Shift', KEY_LEFTSHIFT, w=3), K('z', KEY_Z), K('x', KEY_X),
     K('c', KEY_C), K('v', KEY_V), K('b', KEY_B), K('n', KEY_N),
     K('m', KEY_M), K('⌫', KEY_BACKSPACE, w=3)],
    _bottom('FA'),
    _nav(),
]

FA = [
    _numbers(),
    [K('ض', KEY_Q), K('ص', KEY_W), K('ث', KEY_E), K('ق', KEY_R),
     K('ف', KEY_T), K('غ', KEY_Y), K('ع', KEY_U), K('ه', KEY_I),
     K('خ', KEY_O), K('ح', KEY_P)],
    [K('ش', KEY_A), K('س', KEY_S), K('ی', KEY_D), K('ب', KEY_F),
     K('ل', KEY_G), K('ا', KEY_H), K('ت', KEY_J), K('ن', KEY_K),
     K('م', KEY_L), K('ک', KEY_SEMICOLON)],
    [M('Shift', KEY_LEFTSHIFT, w=3), K('ظ', KEY_Z), K('ط', KEY_X),
     K('ز', KEY_C), K('ر', KEY_V), K('ذ', KEY_B), K('د', KEY_N),
     K('ئ', KEY_M), K('⌫', KEY_BACKSPACE, w=3)],
    _bottom('EN'),
    _nav(),
]

SYMBOLS = [
    [K('-', KEY_MINUS), K('/', KEY_SLASH),
     K(':', KEY_LEFTSHIFT, KEY_SEMICOLON), K(';', KEY_SEMICOLON),
     K('(', KEY_LEFTSHIFT, KEY_9), K(')', KEY_LEFTSHIFT, KEY_0),
     K('$', KEY_LEFTSHIFT, KEY_4), K('&', KEY_LEFTSHIFT, KEY_7),
     K('@', KEY_LEFTSHIFT, KEY_2), K('"', KEY_LEFTSHIFT, KEY_APOSTROPHE)],
    [K('.', KEY_DOT), K(',', KEY_COMMA),
     K('?', KEY_LEFTSHIFT, KEY_SLASH), K('!', KEY_LEFTSHIFT, KEY_1),
     K("'", KEY_APOSTROPHE), K('\\', KEY_BACKSLASH),
     K('|', KEY_LEFTSHIFT, KEY_BACKSLASH), K('~', KEY_LEFTSHIFT, KEY_GRAVE),
     K('^', KEY_LEFTSHIFT, KEY_6), K('*', KEY_LEFTSHIFT, KEY_8)],
    [K('+', KEY_LEFTSHIFT, KEY_EQUAL), K('=', KEY_EQUAL),
     K('<', KEY_LEFTSHIFT, KEY_COMMA), K('>', KEY_LEFTSHIFT, KEY_DOT),
     K('[', KEY_LEFTBRACE), K(']', KEY_RIGHTBRACE),
     K('{', KEY_LEFTSHIFT, KEY_LEFTBRACE),
     K('}', KEY_LEFTSHIFT, KEY_RIGHTBRACE), K('#', KEY_LEFTSHIFT, KEY_3),
     K('%', KEY_LEFTSHIFT, KEY_5)],
    [M('Shift', KEY_LEFTSHIFT, w=3), K('`', KEY_GRAVE, w=3),
     K('_', KEY_LEFTSHIFT, KEY_MINUS, w=3), K('⌫', KEY_BACKSPACE, w=4),
     K('Enter', KEY_ENTER, w=4), A('ABC', 'page', w=3)],
]

LAYOUTS = {'en': EN, 'fa': FA, 'symbols': SYMBOLS}


def all_keycodes():
    """Every key code used by any layout (for uinput device setup)."""
    codes = set()
    for rows in LAYOUTS.values():
        for row in rows:
            for key in row:
                for c in key.get('codes', []):
                    codes.add(c)
                if 'mod' in key:
                    codes.add(key['mod'])
    return sorted(codes)
