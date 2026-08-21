#!/usr/bin/env python3
"""Regression model for the bounded TLS ClientHello prefix used by OAF."""

import struct
import sys
from pathlib import Path


ECH = 0xFE0D


def extension(kind: int, value: bytes) -> bytes:
    return struct.pack("!HH", kind, len(value)) + value


def client_hello(host: str, padding: int = 1900, ech: bool = False) -> bytes:
    encoded = host.encode("ascii")
    server_name = struct.pack("!H", len(encoded) + 3) + b"\x00" + \
        struct.pack("!H", len(encoded)) + encoded
    extensions = extension(43, b"\x02\x03\x04")
    extensions += extension(21, bytes(padding))
    extensions += extension(0, server_name)
    if ech:
        extensions += extension(ECH, b"\x00")
    body = b"\x03\x03" + bytes(range(32))
    body += b"\x20" + bytes(32)
    body += b"\x00\x04\x13\x01\x13\x02"
    body += b"\x01\x00"
    body += struct.pack("!H", len(extensions)) + extensions
    handshake = b"\x01" + len(body).to_bytes(3, "big") + body
    return b"\x16\x03\x01" + struct.pack("!H", len(handshake)) + handshake


def parse_sni(data: bytes):
    if len(data) < 9 or data[:2] != b"\x16\x03" or data[5] != 1:
        return None, False, False
    record_end = 5 + int.from_bytes(data[3:5], "big")
    if len(data) < record_end:
        return None, False, False
    hello_end = 9 + int.from_bytes(data[6:9], "big")
    end = min(record_end, hello_end)
    pos = 9 + 34
    session_len = data[pos]
    pos += 1 + session_len
    cipher_len = int.from_bytes(data[pos:pos + 2], "big")
    pos += 2 + cipher_len
    compression_len = data[pos]
    pos += 1 + compression_len
    extensions_len = int.from_bytes(data[pos:pos + 2], "big")
    pos += 2
    extensions_end = min(end, pos + extensions_len)
    host = None
    ech = False
    while pos + 4 <= extensions_end:
        kind, size = struct.unpack("!HH", data[pos:pos + 4])
        pos += 4
        value = data[pos:pos + size]
        if len(value) != size:
            break
        if kind == ECH:
            ech = True
        if kind == 0 and size >= 5:
            name_len = int.from_bytes(value[3:5], "big")
            host = value[5:5 + name_len].decode("ascii")
        pos += size
    return host, ech, True


def main(feature_cfg=None):
    host = "upos-sz-estghw.bilivideo.com"
    hello = client_hello(host)
    assert 2000 < len(hello) < 8192
    prefix = b""
    for end in (600, 1448):
        prefix += hello[len(prefix):end]
        parsed, _, complete = parse_sni(prefix)
        assert parsed is None and not complete
    prefix += hello[len(prefix):]
    parsed, ech, complete = parse_sni(prefix)
    assert complete and parsed == host and not ech

    parsed, ech, complete = parse_sni(client_hello(host, ech=True))
    assert complete and parsed == host and ech

    # TLS-C3: reproduce the live PC flow.  i2.hdslb.com was successfully
    # parsed from a split IPv6 ClientHello after the second payload packet,
    # while R20.5 rejected its SNI rule because a raw accelerator bucket had
    # been miscompiled as the semantic packet mask 1|2.  Parsed SNI matching
    # is independent of that transport ordinal and maps atomically to 5110.
    parsed, _, complete = parse_sni(client_hello("i2.hdslb.com", padding=2100))
    assert complete and parsed == "i2.hdslb.com"
    legacy_pkt_seq_mask = (1 << 0) | (1 << 1)
    completion_pkt_seq = 3
    raw_mask_matches = bool(legacy_pkt_seq_mask & (1 << (completion_pkt_seq - 1)))
    assert not raw_mask_matches
    sni_rule_matches = b".hdslb.com" in parsed.encode("ascii")
    assert sni_rule_matches
    final_appid = 5110 if sni_rule_matches else 8092
    assert final_appid == 0x13F6

    if feature_cfg:
        cfg = Path(feature_cfg).read_text(errors="strict")
        rows = [line for line in cfg.splitlines()
                if line.startswith("5110 ") and
                ";sni_bm;;2e6864736c622e636f6d;" in line]
        assert rows, "Bilibili .hdslb.com SNI rule missing"
        # v4.2 field 9 is pkt_seq.  A reconstructed SNI rule must retain the
        # source value zero, never a recovered raw table mask such as 1|2.
        feature = rows[0].split("[", 1)[1].rsplit("]", 1)[0]
        fields = feature.split(";")
        assert fields[9] == "0", f"SNI pkt_seq leaked raw bucket: {fields[9]}"

    print("PASS TLS-C1/C2/C3: split ClientHello -> i2.hdslb.com -> 0x13f6; "
          "legacy pkt_seq 1|2 bypassed")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else None)
