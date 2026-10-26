# SPDX-License-Identifier: GPL-3.0-or-later
"""Sonda X11 do smoke test: roda DENTRO da VM, como o usuário live.

Lê do servidor X (DISPLAY do ambiente) o que o gerenciador de janelas
publica pela EWMH e imprime marcadores para o smoke-test.sh:

  BWM_X11_<TAG>_WM=<nome>        _NET_WM_NAME da janela _NET_SUPPORTING_WM_CHECK
  BWM_X11_<TAG>_CLIENTS=<lista>  WM_CLASS (classe) de cada _NET_CLIENT_LIST,
                                 separados por vírgula, como id:classe

Só a libX11 (via ctypes), presente em qualquer sessão Xorg: não depende de
xprop, wmctrl nem python-xlib.
"""
import ctypes
import ctypes.util
import re
import sys

tag = sys.argv[1] if len(sys.argv) > 1 else "X"
if not re.fullmatch(r"[A-Z0-9]{1,16}", tag):
    sys.exit(2)


def emit(key, value):
    value = re.sub(r"[^A-Za-z0-9_.:,+-]", "_", value) or "-"
    print("BWM" + "_X11_%s_%s=%s" % (tag, key, value), flush=True)


libx11 = ctypes.util.find_library("X11") or "libX11.so.6"
x = ctypes.cdll.LoadLibrary(libx11)
c_ulong_p = ctypes.POINTER(ctypes.c_ulong)
x.XOpenDisplay.restype = ctypes.c_void_p
x.XOpenDisplay.argtypes = [ctypes.c_char_p]
x.XDefaultRootWindow.restype = ctypes.c_ulong
x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x.XInternAtom.restype = ctypes.c_ulong
x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x.XGetWindowProperty.restype = ctypes.c_int
x.XGetWindowProperty.argtypes = [
    ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long,
    ctypes.c_int, ctypes.c_ulong, c_ulong_p, ctypes.POINTER(ctypes.c_int),
    c_ulong_p, c_ulong_p, ctypes.POINTER(ctypes.c_void_p)]
x.XFree.argtypes = [ctypes.c_void_p]
# Uma janela que some no meio da leitura gera BadWindow: o tratador padrão
# encerraria o processo.
HANDLER = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
ignore_errors = HANDLER(lambda display, event: 0)
x.XSetErrorHandler(ignore_errors)

display = x.XOpenDisplay(None)
if not display:
    emit("WM", "sem-display")
    emit("CLIENTS", "")
    sys.exit(0)
root = x.XDefaultRootWindow(display)


def atom(name):
    return x.XInternAtom(display, name.encode(), 0)


def get_property(window, name):
    """(formato, bytes) da propriedade, ou (0, b"")."""
    actual_type = ctypes.c_ulong()
    actual_format = ctypes.c_int()
    count = ctypes.c_ulong()
    after = ctypes.c_ulong()
    data = ctypes.c_void_p()
    status = x.XGetWindowProperty(display, window, atom(name), 0, 65536, 0, 0,
                                  ctypes.byref(actual_type), ctypes.byref(actual_format),
                                  ctypes.byref(count), ctypes.byref(after), ctypes.byref(data))
    if status != 0 or not data.value:
        return 0, b""
    # Formato 32 chega como "long" do C (8 bytes no x86_64).
    size = {8: 1, 16: ctypes.sizeof(ctypes.c_short), 32: ctypes.sizeof(ctypes.c_long)}.get(
        actual_format.value, 0) * count.value
    raw = ctypes.string_at(data.value, size)
    x.XFree(data)
    return actual_format.value, raw


def windows(window, name):
    fmt, raw = get_property(window, name)
    if fmt != 32:
        return []
    step = ctypes.sizeof(ctypes.c_long)
    return [int.from_bytes(raw[i:i + step], sys.byteorder) for i in range(0, len(raw), step)]


check = windows(root, "_NET_SUPPORTING_WM_CHECK")
wm_name = ""
if check:
    for prop in ("_NET_WM_NAME", "WM_NAME"):
        fmt, raw = get_property(check[0], prop)
        if fmt == 8 and raw:
            wm_name = raw.decode("utf-8", "replace")
            break
emit("WM", wm_name)

clients = []
for window in windows(root, "_NET_CLIENT_LIST"):
    fmt, raw = get_property(window, "WM_CLASS")
    parts = raw.split(b"\0") if fmt == 8 else []
    klass = parts[1].decode("utf-8", "replace") if len(parts) > 1 else "?"
    clients.append("%x:%s" % (window, klass))
emit("CLIENTS", ",".join(clients))
