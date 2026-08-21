#!/usr/bin/env python3
"""Validate the complete OpenWrt fwtool metadata CRC on a sysupgrade image."""

import argparse
import json
import struct
import sys
import zlib
from pathlib import Path


FWIMAGE_MAGIC = 0x46577830  # "FWx0"
FWIMAGE_INFO = 1
TRAILER = struct.Struct(">IIB3xI")
HEADER_SIZE = 8


def fail(message: str) -> None:
    raise ValueError(message)


def crc_before_trailer(path: Path, length: int) -> int:
    crc = 0
    remaining = length
    with path.open("rb") as stream:
        while remaining:
            block = stream.read(min(1024 * 1024, remaining))
            if not block:
                fail("firmware ended before its fwtool trailer")
            crc = zlib.crc32(block, crc)
            remaining -= len(block)

    # fwtool's crc32_block starts from ~0 and does not apply a final xor.  This
    # is the complement of Python/zlib's conventional crc32 result.
    return crc ^ 0xFFFFFFFF


def validate(path: Path) -> dict:
    size = path.stat().st_size
    if size < TRAILER.size:
        fail("image is shorter than an fwtool trailer")

    with path.open("rb") as stream:
        stream.seek(-TRAILER.size, 2)
        trailer = stream.read(TRAILER.size)

    magic, stored_crc, chunk_type, chunk_size = TRAILER.unpack(trailer)
    if magic != FWIMAGE_MAGIC:
        fail("fwtool metadata trailer magic is missing")
    if chunk_type != FWIMAGE_INFO:
        fail(f"last fwtool chunk is type {chunk_type}, not metadata")
    if chunk_size < HEADER_SIZE + TRAILER.size or chunk_size > size:
        fail(f"invalid fwtool metadata chunk size {chunk_size}")

    calculated_crc = crc_before_trailer(path, size - TRAILER.size)
    if calculated_crc != stored_crc:
        fail(
            "fwtool CRC mismatch: "
            f"stored={stored_crc:08x}, calculated={calculated_crc:08x}"
        )

    payload_size = chunk_size - HEADER_SIZE - TRAILER.size
    payload_offset = size - chunk_size + HEADER_SIZE
    with path.open("rb") as stream:
        stream.seek(payload_offset)
        raw_metadata = stream.read(payload_size)
    try:
        metadata = json.loads(raw_metadata)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"fwtool metadata JSON is invalid: {error}")

    if not isinstance(metadata, dict):
        fail("fwtool metadata is not a JSON object")
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    args = parser.parse_args()

    try:
        metadata = validate(args.image)
    except (OSError, ValueError) as error:
        print(f"FAIL: {args.image}: {error}", file=sys.stderr)
        return 1

    devices = metadata.get("supported_devices", [])
    print(
        f"PASS: {args.image}: fwtool CRC and metadata are valid; "
        f"supported_devices={devices}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
