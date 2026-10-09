#!/usr/bin/env python3
import hashlib
import os
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(os.environ.get("ROOT", Path.cwd()))
REFERENCE = Path(os.environ.get("REFERENCE_BOOT", ROOT / "reference" / "boot.img"))
KERNEL = Path(os.environ.get("KERNEL_IMAGE", ROOT / "kernel" / "out" / "arch" / "arm64" / "boot" / "Image.gz"))
MODULE_ROOT = Path(os.environ.get("MODULE_ROOT", ROOT / "kernel" / "out"))
OUTPUT = Path(os.environ.get("OUTPUT_BOOT", ROOT / "boot-resukisu-susfs.img"))
PAGE_SIZE = 4096
TARGET_SIZE = REFERENCE.stat().st_size


def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def put_u32(buf, off, value):
    struct.pack_into("<I", buf, off, value)


def align(value, page=PAGE_SIZE):
    return (value + page - 1) // page * page


def run(cmd, cwd=None, stdin=None, stdout=None):
    print("+", " ".join(str(x) for x in cmd))
    subprocess.run(cmd, cwd=cwd, stdin=stdin, stdout=stdout, check=True)


def make_ramdisk(tmp):
    old_gz = Path(tmp) / "ramdisk.old.gz"
    old_cpio = Path(tmp) / "ramdisk.old.cpio"
    ramdisk_dir = Path(tmp) / "ramdisk"
    old = REFERENCE.read_bytes()
    old_kernel_size = u32(old, 8)
    old_ramdisk_size = u32(old, 16)
    old_ramdisk_off = PAGE_SIZE + align(old_kernel_size)
    old_gz.write_bytes(old[old_ramdisk_off:old_ramdisk_off + old_ramdisk_size])
    with old_cpio.open("wb") as out:
        run(["gzip", "-dc", str(old_gz)], stdout=out)
    ramdisk_dir.mkdir()
    run(["cpio", "-idmuv"], cwd=ramdisk_dir, stdin=old_cpio.open("rb"))

    modules = sorted(MODULE_ROOT.rglob("*.ko"))
    if not modules:
        raise SystemExit("No kernel modules found")
    module_dir = ramdisk_dir / "lib" / "modules" / os.environ.get("MODULE_RELEASE", "4.19.325-resukisu-susfs")
    module_dir.mkdir(parents=True, exist_ok=True)
    manifest = []
    for module in modules:
        rel = module.relative_to(MODULE_ROOT)
        dest = module_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(module, dest)
        manifest.append(str(Path("lib/modules/4.19.325-resukisu-susfs") / rel))
    (module_dir / "modules.order").write_text("\n".join(manifest) + "\n")
    (module_dir / "modules.load").write_text("\n".join(manifest) + "\n")

    new_cpio = Path(tmp) / "ramdisk.new.cpio"
    new_gz = Path(tmp) / "ramdisk.new.gz"
    with new_cpio.open("wb") as out:
        run(["cpio", "--null", "-o", "-H", "newc"], cwd=ramdisk_dir,
            stdin=subprocess.Popen(["find", ".", "-print0"], cwd=ramdisk_dir, stdout=subprocess.PIPE).stdout,
            stdout=out)
    with new_gz.open("wb") as out:
        run(["gzip", "-9", "-c", str(new_cpio)], stdout=out)
    return new_gz.read_bytes(), len(modules), sum(x.stat().st_size for x in modules)


def main():
    if not REFERENCE.is_file() or not KERNEL.is_file():
        raise SystemExit("Reference boot.img or compiled Image.gz is missing")
    original = REFERENCE.read_bytes()
    if original[:8] != b"ANDROID!":
        raise SystemExit("Reference is not an Android boot image")
    original_kernel_size = u32(original, 8)
    original_ramdisk_size = u32(original, 16)
    original_second_size = u32(original, 24)
    page = u32(original, 36) or PAGE_SIZE
    if page != PAGE_SIZE:
        raise SystemExit(f"Unsupported page size: {page}")
    old_kernel_off = page
    old_ramdisk_off = old_kernel_off + align(original_kernel_size, page)
    old_second_off = old_ramdisk_off + align(original_ramdisk_size, page)
    old_tail_off = old_second_off + align(original_second_size, page)
    old_ramdisk_end = old_ramdisk_off + original_ramdisk_size
    if old_tail_off < old_ramdisk_end:
        raise SystemExit("Invalid boot image layout")
    tail = original[old_tail_off:]

    with tempfile.TemporaryDirectory(prefix="boot-repack-", dir=ROOT) as tmp:
        ramdisk, module_count, module_bytes = make_ramdisk(tmp)

    kernel = KERNEL.read_bytes()
    header = bytearray(original[:page])
    put_u32(header, 8, len(kernel))
    put_u32(header, 16, len(ramdisk))
    # Android bootimg v0 uses the first 20 bytes of id for a component digest.
    digest = hashlib.sha1(kernel + ramdisk + tail).digest()
    header[576:596] = digest
    header[596:608] = b"\0" * 12

    image = bytearray(header)
    image += kernel
    image += b"\0" * (align(len(image), page) - len(image))
    image += ramdisk
    image += b"\0" * (align(len(image), page) - len(image))
    image += tail
    if len(image) < TARGET_SIZE:
        image += b"\0" * (TARGET_SIZE - len(image))
    OUTPUT.write_bytes(image)

    print(f"output={OUTPUT}")
    print(f"size={len(image)} bytes ({len(image) / 1048576:.2f} MiB)")
    print(f"kernel={len(kernel)} bytes")
    print(f"ramdisk={len(ramdisk)} bytes")
    print(f"modules={module_count} files, {module_bytes} uncompressed bytes")
    print(f"sha256={hashlib.sha256(image).hexdigest()}")
    print(f"original_size={TARGET_SIZE} bytes")


if __name__ == "__main__":
    main()
