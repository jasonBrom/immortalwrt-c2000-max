#!/usr/bin/env python3
"""Build an expanded C2000-MAX SD image while preserving its boot chain."""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
import tarfile
import zlib
from dataclasses import dataclass
from pathlib import Path


SECTOR_SIZE = 512
OVERLAY_ALIGN = 64 * 1024
GPT_HEADER = struct.Struct("<8sIIIIQQQQ16sQIII")
EXPECTED_LAYOUT = {
    "bl2": (1024, 8191),
    "u-boot-env": (8192, 9215),
    "factory": (9216, 17407),
    "fip": (17408, 21503),
    "kernel": (21504, 87039),
    "rootfs": (87040, 496639),
}
PRESERVED_PARTITIONS = ("bl2", "u-boot-env", "factory", "fip")


@dataclass(frozen=True)
class Partition:
    name: str
    first_lba: int
    last_lba: int
    index: int

    @property
    def offset(self) -> int:
        return self.first_lba * SECTOR_SIZE

    @property
    def size(self) -> int:
        return (self.last_lba - self.first_lba + 1) * SECTOR_SIZE


@dataclass(frozen=True)
class GPT:
    partitions: dict[str, Partition]
    header_sector: bytes
    header_size: int
    entries: bytes
    entries_lba: int
    entry_count: int
    entry_size: int
    last_usable_lba: int


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_region(path: Path, partition: Partition) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        source.seek(partition.offset)
        remaining = partition.size
        while remaining:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                raise ValueError(f"{path} is truncated inside {partition.name}")
            digest.update(chunk)
            remaining -= len(chunk)
    return digest.hexdigest()


def read_primary_gpt(path: Path) -> GPT:
    with path.open("rb") as image:
        image.seek(SECTOR_SIZE)
        sector = image.read(SECTOR_SIZE)
        if len(sector) != SECTOR_SIZE:
            raise ValueError("image does not contain a complete GPT header")

        values = GPT_HEADER.unpack_from(sector)
        (
            signature,
            _revision,
            header_size,
            stored_header_crc,
            _reserved,
            current_lba,
            backup_lba,
            _first_usable_lba,
            last_usable_lba,
            _disk_guid,
            entries_lba,
            entry_count,
            entry_size,
            stored_entries_crc,
        ) = values

        if signature != b"EFI PART" or not 92 <= header_size <= SECTOR_SIZE:
            raise ValueError("invalid primary GPT header")

        header = bytearray(sector[:header_size])
        struct.pack_into("<I", header, 16, 0)
        if zlib.crc32(header) & 0xFFFFFFFF != stored_header_crc:
            raise ValueError("GPT header CRC32 does not match")

        # This OEM layout intentionally carries a primary-only GPT. Keep that
        # mode instead of inventing a backup table that its boot chain never had.
        if current_lba != 1 or backup_lba != 1:
            raise ValueError("unexpected GPT mode; refusing to alter this image")

        image.seek(entries_lba * SECTOR_SIZE)
        entries = image.read(entry_count * entry_size)
        if len(entries) != entry_count * entry_size:
            raise ValueError("GPT partition array is truncated")
        if zlib.crc32(entries) & 0xFFFFFFFF != stored_entries_crc:
            raise ValueError("GPT partition-array CRC32 does not match")

    partitions: dict[str, Partition] = {}
    for index in range(entry_count):
        entry = entries[index * entry_size : (index + 1) * entry_size]
        if entry[:16] == bytes(16):
            continue
        first_lba, last_lba, _attributes = struct.unpack_from("<QQQ", entry, 32)
        name = entry[56:entry_size].decode("utf-16le").split("\0", 1)[0]
        partitions[name] = Partition(name, first_lba, last_lba, index)

    return GPT(
        partitions=partitions,
        header_sector=sector,
        header_size=header_size,
        entries=entries,
        entries_lba=entries_lba,
        entry_count=entry_count,
        entry_size=entry_size,
        last_usable_lba=last_usable_lba,
    )


def validate_reference(path: Path, gpt: GPT) -> None:
    layout = {
        name: (partition.first_lba, partition.last_lba)
        for name, partition in gpt.partitions.items()
    }
    if set(layout) != set(EXPECTED_LAYOUT):
        raise ValueError(f"reference GPT layout mismatch: {layout!r}")

    for name, expected in EXPECTED_LAYOUT.items():
        actual = layout[name]
        if name == "rootfs":
            # Later C2000-MAX images already expanded rootfs_data.  Its start
            # LBA is part of the OEM boot contract; its end LBA is not.
            if actual[0] != expected[0] or actual[1] < expected[1]:
                raise ValueError(f"reference GPT layout mismatch: {layout!r}")
        elif actual != expected:
            raise ValueError(f"reference GPT layout mismatch: {layout!r}")
    if gpt.partitions["rootfs"].last_lba != gpt.last_usable_lba:
        raise ValueError("reference rootfs does not end at last-usable LBA")
    declared_size = (gpt.last_usable_lba + 1) * SECTOR_SIZE
    if path.stat().st_size < declared_size:
        raise ValueError(
            "reference image is physically truncated: "
            f"{path.stat().st_size} bytes, GPT requires {declared_size}"
        )


def read_sysupgrade(path: Path) -> tuple[bytes, bytes]:
    with tarfile.open(path, mode="r:") as archive:
        members = {member.name.rsplit("/", 1)[-1]: member for member in archive}
        try:
            kernel_member = members["kernel"]
            root_member = members["root"]
        except KeyError as error:
            raise ValueError("sysupgrade archive lacks kernel or root") from error

        kernel_file = archive.extractfile(kernel_member)
        root_file = archive.extractfile(root_member)
        if kernel_file is None or root_file is None:
            raise ValueError("sysupgrade kernel/root is not a regular file")
        kernel = kernel_file.read()
        root = root_file.read()

    if kernel[:4] != bytes.fromhex("d00dfeed"):
        raise ValueError("sysupgrade kernel is not a FIT/FDT image")
    if root[:4] != b"hsqs" or len(root) < 48:
        raise ValueError("sysupgrade root is not little-endian SquashFS")
    return kernel, root


def squashfs_overlay_offset(root: bytes) -> int:
    bytes_used = struct.unpack_from("<Q", root, 40)[0]
    if bytes_used <= 48 or bytes_used > len(root):
        raise ValueError("invalid SquashFS bytes_used value")
    offset = align_up(bytes_used, OVERLAY_ALIGN)
    if len(root) > offset:
        raise ValueError("SquashFS payload overlaps fstools rootfs_data offset")
    return offset


def build_expanded_gpt(gpt: GPT, root_last_lba: int) -> tuple[bytes, bytes]:
    rootfs = gpt.partitions["rootfs"]
    if root_last_lba < rootfs.first_lba:
        raise ValueError("expanded rootfs has an invalid end LBA")

    entries = bytearray(gpt.entries)
    root_entry_offset = rootfs.index * gpt.entry_size
    struct.pack_into("<Q", entries, root_entry_offset + 40, root_last_lba)
    entries_crc = zlib.crc32(entries) & 0xFFFFFFFF

    header_sector = bytearray(gpt.header_sector)
    struct.pack_into("<Q", header_sector, 48, root_last_lba)
    struct.pack_into("<I", header_sector, 88, entries_crc)
    struct.pack_into("<I", header_sector, 16, 0)
    header_crc = zlib.crc32(header_sector[: gpt.header_size]) & 0xFFFFFFFF
    struct.pack_into("<I", header_sector, 16, header_crc)
    return bytes(header_sector), bytes(entries)


def patch_protective_mbr(prefix: bytearray, disk_sectors: int) -> None:
    if prefix[510:512] != b"\x55\xaa":
        raise ValueError("reference MBR signature is missing")
    protective = prefix[446:462]
    if protective[4] != 0xEE or struct.unpack_from("<I", protective, 8)[0] != 1:
        raise ValueError("reference protective MBR entry is unexpected")
    struct.pack_into("<I", prefix, 458, min(disk_sectors - 1, 0xFFFFFFFF))


def verify_payload(path: Path, partition: Partition, expected: bytes) -> None:
    with path.open("rb") as image:
        image.seek(partition.offset)
        actual = image.read(len(expected))
    if actual != expected:
        raise ValueError(f"written {partition.name} payload failed verification")


def assemble(
    reference: Path,
    sysupgrade: Path,
    output: Path,
    overlay_mib: int,
) -> None:
    if overlay_mib < 64 or overlay_mib > 8192:
        raise ValueError("overlay size must be between 64 and 8192 MiB")
    if reference.resolve() == output.resolve():
        raise ValueError("output must not overwrite the reference image")

    reference_gpt = read_primary_gpt(reference)
    validate_reference(reference, reference_gpt)
    kernel, root = read_sysupgrade(sysupgrade)
    kernel_partition = reference_gpt.partitions["kernel"]
    root_partition = reference_gpt.partitions["rootfs"]
    if len(kernel) > kernel_partition.size:
        raise ValueError("kernel is larger than the fixed OEM kernel partition")

    overlay_offset = squashfs_overlay_offset(root)
    root_partition_bytes = overlay_offset + overlay_mib * 1024 * 1024
    root_partition_bytes = align_up(root_partition_bytes, SECTOR_SIZE)
    root_last_lba = root_partition.first_lba + root_partition_bytes // SECTOR_SIZE - 1
    disk_sectors = root_last_lba + 1
    disk_size = disk_sectors * SECTOR_SIZE

    new_header, new_entries = build_expanded_gpt(reference_gpt, root_last_lba)
    preserved_hashes = {
        name: sha256_region(reference, reference_gpt.partitions[name])
        for name in PRESERVED_PARTITIONS
    }

    with reference.open("rb") as source:
        prefix = bytearray(source.read(kernel_partition.offset))
    if len(prefix) != kernel_partition.offset:
        raise ValueError("reference image is truncated before the kernel partition")

    patch_protective_mbr(prefix, disk_sectors)
    prefix[SECTOR_SIZE : 2 * SECTOR_SIZE] = new_header
    entries_offset = reference_gpt.entries_lba * SECTOR_SIZE
    prefix[entries_offset : entries_offset + len(new_entries)] = new_entries

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".partial")
    try:
        with temporary.open("wb") as destination:
            destination.write(prefix)
            destination.truncate(disk_size)
            destination.seek(kernel_partition.offset)
            destination.write(kernel)
            destination.seek(root_partition.offset)
            destination.write(root)
            destination.flush()
            os.fsync(destination.fileno())
        temporary.replace(output)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise

    try:
        final_gpt = read_primary_gpt(output)
        final_rootfs = final_gpt.partitions["rootfs"]
        if final_gpt.last_usable_lba != root_last_lba:
            raise ValueError("expanded GPT last-usable LBA verification failed")
        if final_rootfs.first_lba != root_partition.first_lba:
            raise ValueError("expanded GPT moved the rootfs start LBA")
        if final_rootfs.last_lba != root_last_lba:
            raise ValueError("expanded GPT rootfs end LBA verification failed")
        if output.stat().st_size != disk_size:
            raise ValueError("assembled image size does not match expanded GPT")

        for name, expected_hash in preserved_hashes.items():
            actual_hash = sha256_region(output, final_gpt.partitions[name])
            if actual_hash != expected_hash:
                raise ValueError(
                    f"preserved partition {name} changed unexpectedly"
                )

        verify_payload(output, final_gpt.partitions["kernel"], kernel)
        verify_payload(output, final_rootfs, root)
    except Exception:
        # Never leave a post-rename image at the requested output path if any
        # independent readback check fails.
        output.unlink(missing_ok=True)
        raise

    print(f"output={output}")
    print(f"size={disk_size}")
    print(f"rootfs_partition_size={final_rootfs.size}")
    print(f"overlay_offset={overlay_offset}")
    print(f"overlay_reserved={overlay_mib * 1024 * 1024}")
    print(f"kernel_size={len(kernel)}")
    print(f"kernel_sha256={sha256_bytes(kernel)}")
    print(f"rootfs_size={len(root)}")
    print(f"rootfs_sha256={sha256_bytes(root)}")
    for name in PRESERVED_PARTITIONS:
        print(f"preserved_{name}_sha256={preserved_hashes[name]}")
    print(f"image_sha256={sha256_file(output)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path, help="V5/OEM-layout C2000-MAX SD image")
    parser.add_argument("sysupgrade", type=Path, help="OpenWrt C2000-MAX sysupgrade tar")
    parser.add_argument("output", type=Path, help="expanded raw SD image to create")
    parser.add_argument(
        "--overlay-mib",
        type=int,
        default=512,
        help="writable rootfs_data space to reserve (default: 512 MiB)",
    )
    arguments = parser.parse_args()
    assemble(arguments.reference, arguments.sysupgrade, arguments.output, arguments.overlay_mib)


if __name__ == "__main__":
    main()
