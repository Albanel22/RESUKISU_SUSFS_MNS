#!/usr/bin/env python3
import struct
import sys
from pathlib import Path

p = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/ubuntu/kiev-build/reference/boot.img")
data = p.read_bytes()
if data[:8] != b"ANDROID!":
    raise SystemExit("not an Android boot image")

def u32(off):
    return struct.unpack_from("<I", data, off)[0]

print(f"file={p}")
print(f"size={len(data)}")
print(f"kernel_size={u32(8)} kernel_addr=0x{u32(12):x}")
print(f"ramdisk_size={u32(16)} ramdisk_addr=0x{u32(20):x}")
print(f"second_size={u32(24)} second_addr=0x{u32(28):x}")
print(f"tags_addr=0x{u32(32):x} page_size={u32(36)} dt_size={u32(40)}")
name = data[48:64].split(b"\0", 1)[0]
cmdline = data[64:576].split(b"\0", 1)[0]
extra = data[608:1632].split(b"\0", 1)[0]
print(f"name={name!r}")
print(f"cmdline={cmdline.decode('utf-8', 'replace')}")
print(f"extra_cmdline={extra.decode('utf-8', 'replace')}")
page = u32(36)
ks = u32(8); rs = u32(16); ss = u32(24); ds = u32(40)
align = lambda n: (n + page - 1) // page * page
ko = page
ro = ko + align(ks)
so = ro + align(rs)
do = so + align(ss)
print(f"offsets kernel=0x{ko:x} ramdisk=0x{ro:x} second=0x{so:x} dt=0x{do:x}")
print(f"ramdisk_magic={data[ro:ro+8].hex()} dt_magic={data[do:do+8].hex()}")
print(f"trailing_bytes={len(data)-(do+align(ds))}")
