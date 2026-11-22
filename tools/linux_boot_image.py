#!/usr/bin/env python3
"""Linux helpers for compacting the kernel ELF and creating its FAT16 ESP."""

from __future__ import annotations

import argparse
import math
import struct
from pathlib import Path


def compact_elf(path: Path) -> None:
    data = bytearray(path.read_bytes())
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError("expected a little-endian ELF64 kernel")
    phoff = struct.unpack_from("<Q", data, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 54)
    if phentsize < 56 or phnum == 0 or phoff + phentsize * phnum > len(data):
        raise ValueError("kernel has an invalid program-header table")

    max_file_end = 0
    compacted = False
    for index in range(phnum):
        off = phoff + index * phentsize
        kind, flags = struct.unpack_from("<II", data, off)
        if kind != 1:
            continue
        file_off, file_size, memory_size = struct.unpack_from("<QQQ", data, off + 8)[0], struct.unpack_from("<Q", data, off + 32)[0], struct.unpack_from("<Q", data, off + 40)[0]
        # The kernel's dedicated writable BSS load segment is pure zero-fill.
        if flags == 6 and memory_size > 32 * 1024 * 1024 and file_size == memory_size:
            struct.pack_into("<Q", data, off + 8, 0)
            struct.pack_into("<Q", data, off + 32, 0)
            file_size = 0
            compacted = True
        if file_size:
            end = file_off + file_size
            if end > len(data):
                raise ValueError("kernel load segment extends past the file")
            max_file_end = max(max_file_end, end)
    if not compacted:
        raise ValueError("could not find the large zero-fill BSS load segment")

    # The boot ELF is loaded through program headers only; discard stale section metadata.
    struct.pack_into("<Q", data, 40, 0)  # e_shoff
    struct.pack_into("<H", data, 60, 0)  # e_shnum
    struct.pack_into("<H", data, 62, 0)  # e_shstrndx
    path.write_bytes(data[:max_file_end])
    print(f"Compacted kernel ELF to {max_file_end / (1024 * 1024):.1f} MiB")


def put16(buf: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<H", buf, offset, value & 0xFFFF)


def put32(buf: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<I", buf, offset, value & 0xFFFFFFFF)


def set_entry(buf: bytearray, offset: int, name: str, attributes: int, cluster: int, size: int) -> None:
    raw_name = name.encode("ascii")[:11].ljust(11, b" ")
    buf[offset : offset + 11] = raw_name
    buf[offset + 11] = attributes
    put16(buf, offset + 26, cluster)
    put32(buf, offset + 28, size)


def make_esp(efi_path: Path, kernel_path: Path, output_path: Path) -> None:
    sector_size, total_sectors = 512, 64000
    sectors_per_cluster, fat_sectors, root_entries = 8, 48, 512
    root_sectors = 32
    data_start = 1 + 2 * fat_sectors + root_sectors
    cluster_bytes = sector_size * sectors_per_cluster
    data_clusters = (total_sectors - data_start) // sectors_per_cluster
    if not (4085 <= data_clusters < 65525):
        raise ValueError("EFI volume does not fit FAT16 cluster limits")

    efi = efi_path.read_bytes()
    kernel = kernel_path.read_bytes()
    efi_clusters = math.ceil(len(efi) / cluster_bytes)
    kernel_clusters = math.ceil(len(kernel) / cluster_bytes)
    kernel_start = 4 + efi_clusters
    if efi_clusters + kernel_clusters + 2 > data_clusters:
        raise ValueError("EFI loader and kernel do not fit in the ESP")

    image = bytearray(total_sectors * sector_size)
    image[0:3] = b"\xeb\x3c\x90"
    image[3:11] = b"AETHEROS"
    put16(image, 11, sector_size)
    image[13] = sectors_per_cluster
    put16(image, 14, 1)
    image[16] = 2
    put16(image, 17, root_entries)
    put32(image, 32, total_sectors)
    image[21] = 0xF8
    put16(image, 22, fat_sectors)
    put16(image, 24, 18)
    put16(image, 26, 2)
    image[38] = 0x29
    put32(image, 39, 0x41544852)
    image[43:54] = b"AETHEROS   "
    image[54:62] = b"FAT16   "
    image[510:512] = b"\x55\xaa"

    fat = bytearray(fat_sectors * sector_size)
    def set_fat(cluster: int, value: int) -> None:
        put16(fat, cluster * 2, value)

    set_fat(0, 0xFFF8)
    set_fat(1, 0xFFFF)
    set_fat(2, 0xFFFF)
    set_fat(3, 0xFFFF)
    for i in range(efi_clusters):
        set_fat(4 + i, 0xFFFF if i + 1 == efi_clusters else 5 + i)
    for i in range(kernel_clusters):
        set_fat(kernel_start + i, 0xFFFF if i + 1 == kernel_clusters else kernel_start + i + 1)
    for copy in range(2):
        start = (1 + copy * fat_sectors) * sector_size
        image[start : start + len(fat)] = fat

    root_offset = (1 + 2 * fat_sectors) * sector_size
    set_entry(image, root_offset, "EFI", 0x10, 2, 0)
    set_entry(image, root_offset + 32, "KERNEL  ELF", 0x20, kernel_start, len(kernel))
    data_offset = data_start * sector_size
    set_entry(image, data_offset, ".", 0x10, 2, 0)
    set_entry(image, data_offset + 32, "..", 0x10, 0, 0)
    set_entry(image, data_offset + 64, "BOOT", 0x10, 3, 0)
    boot_dir = data_offset + cluster_bytes
    set_entry(image, boot_dir, ".", 0x10, 3, 0)
    set_entry(image, boot_dir + 32, "..", 0x10, 2, 0)
    set_entry(image, boot_dir + 64, "BOOTX64 EFI", 0x20, 4, len(efi))

    def write_chain(content: bytes, first_cluster: int) -> None:
        start = data_offset + (first_cluster - 2) * cluster_bytes
        image[start : start + len(content)] = content

    write_chain(efi, 4)
    write_chain(kernel, kernel_start)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(image)
    print(f"Created EFI system image: {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    compact = sub.add_parser("compact")
    compact.add_argument("kernel", type=Path)
    esp = sub.add_parser("esp")
    esp.add_argument("--efi", required=True, type=Path)
    esp.add_argument("--kernel", required=True, type=Path)
    esp.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "compact":
        compact_elf(args.kernel)
    else:
        make_esp(args.efi, args.kernel, args.output)


if __name__ == "__main__":
    main()
