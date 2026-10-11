#!/usr/bin/env python3
"""Resize the first window of a process by pid (macOS Accessibility API).

    resize.py <pid> <dw> <dh>

System Events can't be used for this: it refers to processes by name, so with
the terminal under test also running as your everyday terminal it picks the
wrong process. Needs Accessibility permission for the app running this.
"""

import ctypes
import sys

AX = ctypes.cdll.LoadLibrary(
    "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
)
CF = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

UTF8 = 0x08000100
AX_VALUE_CGSIZE = 2
AX_ERROR_API_DISABLED = -25211


class CGSize(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


CF.CFStringCreateWithCString.restype = ctypes.c_void_p
CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
CF.CFArrayGetCount.restype = ctypes.c_long
CF.CFArrayGetCount.argtypes = [ctypes.c_void_p]
CF.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
CF.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
AX.AXUIElementCreateApplication.restype = ctypes.c_void_p
AX.AXUIElementCreateApplication.argtypes = [ctypes.c_int]
AX.AXUIElementCopyAttributeValue.restype = ctypes.c_int32
AX.AXUIElementCopyAttributeValue.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_void_p),
]
AX.AXUIElementSetAttributeValue.restype = ctypes.c_int32
AX.AXUIElementSetAttributeValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
AX.AXValueGetValue.restype = ctypes.c_bool
AX.AXValueGetValue.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p]
AX.AXValueCreate.restype = ctypes.c_void_p
AX.AXValueCreate.argtypes = [ctypes.c_uint32, ctypes.c_void_p]


def cfstr(text):
    return CF.CFStringCreateWithCString(None, text.encode(), UTF8)


def copy_attribute(element, name):
    value = ctypes.c_void_p()
    err = AX.AXUIElementCopyAttributeValue(element, cfstr(name), ctypes.byref(value))
    if err == AX_ERROR_API_DISABLED:
        raise RuntimeError("no Accessibility permission")
    if err or not value.value:
        raise RuntimeError(f"cannot read {name} (AXError {err})")
    return value.value


def resize(pid, dw, dh):
    app = AX.AXUIElementCreateApplication(pid)
    windows = copy_attribute(app, "AXWindows")
    if CF.CFArrayGetCount(windows) == 0:
        raise RuntimeError(f"process {pid} has no windows")
    window = CF.CFArrayGetValueAtIndex(windows, 0)

    size = CGSize()
    AX.AXValueGetValue(copy_attribute(window, "AXSize"), AX_VALUE_CGSIZE, ctypes.byref(size))
    new_size = CGSize(size.width + dw, size.height + dh)
    value = AX.AXValueCreate(AX_VALUE_CGSIZE, ctypes.byref(new_size))
    err = AX.AXUIElementSetAttributeValue(window, cfstr("AXSize"), value)
    if err:
        raise RuntimeError(f"cannot set AXSize (AXError {err})")


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        resize(int(argv[1]), float(argv[2]), float(argv[3]))
    except RuntimeError as err:
        print(err, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
