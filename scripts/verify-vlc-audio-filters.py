#!/usr/bin/env python3
"""Inspect libVLC modules and EQ band metadata, without a player, media or audio signal."""
import ctypes
import json
import math
import sys

library = ctypes.CDLL(sys.argv[1])


class Module(ctypes.Structure):
    pass


Module._fields_ = [(name, ctypes.c_char_p) for name in ("name", "short_name", "long_name", "help")] + [
    ("next", ctypes.POINTER(Module))
]
library.libvlc_new.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)]
library.libvlc_new.restype = ctypes.c_void_p
library.libvlc_release.argtypes = [ctypes.c_void_p]
library.libvlc_audio_filter_list_get.argtypes = [ctypes.c_void_p]
library.libvlc_audio_filter_list_get.restype = ctypes.POINTER(Module)
library.libvlc_module_description_list_release.argtypes = [ctypes.POINTER(Module)]
library.libvlc_audio_equalizer_get_band_count.restype = ctypes.c_uint
library.libvlc_audio_equalizer_get_band_frequency.argtypes = [ctypes.c_uint]
library.libvlc_audio_equalizer_get_band_frequency.restype = ctypes.c_float
options = (ctypes.c_char_p * 2)(b"--ignore-config", b"--no-metadata-network-access")
instance = library.libvlc_new(len(options), options)
if not instance:
    raise RuntimeError("The packaged VLC library could not initialize for module inspection")
try:
    head = library.libvlc_audio_filter_list_get(instance)
    try:
        current, available = head, set()
        for _ in range(512):
            if not current:
                break
            if current.contents.name:
                available.add(current.contents.name.decode("utf-8"))
            current = current.contents.next
        missing = {"compressor", "equalizer"} - available
        if missing:
            raise RuntimeError("The package is missing required audio filters: " + ", ".join(sorted(missing)))
        count = library.libvlc_audio_equalizer_get_band_count()
        if not 1 <= count <= 64:
            raise RuntimeError("VLC reported an invalid equalizer band count")
        frequencies = [library.libvlc_audio_equalizer_get_band_frequency(i) for i in range(count)]
        if not all(math.isfinite(hz) and hz > 0 for hz in frequencies):
            raise RuntimeError("VLC reported invalid equalizer frequencies")
        print(json.dumps(dict(compressor=True, equalizer=True, bandFrequenciesHz=frequencies,
                              playersCreated=0, mediaOpened=False)))
    finally:
        if head:
            library.libvlc_module_description_list_release(head)
finally:
    library.libvlc_release(instance)
