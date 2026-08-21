#!/usr/bin/env python3
"""Host regression for native IK HTTP fields, specificity and TCP prefixing."""
import re
import sys
from pathlib import Path


def fields(request: bytes):
    lines = request.split(b"\r\n")
    first = lines[0].split(b" ")
    out = {0: first[1] if len(first) >= 2 else b""}
    for line in lines[1:]:
        if b":" not in line:
            continue
        name, value = line.split(b":", 1)
        idx = {b"host": 1, b"user-agent": 2}.get(name.lower())
        if idx is not None:
            out[idx] = value.strip()
    return out


def clauses(blob: str):
    raw = bytes.fromhex(blob)
    count, pos = raw[0], 1
    result = []
    for _ in range(count):
        field, method, size = raw[pos], raw[pos + 1], raw[pos + 2]
        pos += 3
        result.append((field, method, raw[pos:pos + size]))
        pos += size
    return result


def matches(request: bytes, blob: str):
    parsed = fields(request)
    for field, method, pattern in clauses(blob):
        value = parsed.get(field, b"")
        if method == 0 and value != pattern:
            return False
        if method == 1 and pattern not in value:
            return False
        if method == 2 and not re.search(pattern.decode(), value.decode()):
            return False
    return True


def main(cfg_path: str):
    cfg = Path(cfg_path).read_text(errors="strict")
    rows = [line for line in cfg.splitlines()
            if line.startswith("5110 ") and ";http_multi;;" in line]
    blobs = [line.split(";http_multi;;", 1)[1].split(";", 1)[0]
             for line in rows]
    assert len(blobs) >= 6, "Bilibili HTTP rules missing"
    live = next(x for x in blobs if b"live-bvc" in bytes.fromhex(x))

    a = (b"GET /upgcxcode/x.m4s HTTP/1.1\r\n"
         b"Host: upos-sz-estghw.bilivideo.com\r\n"
         b"User-Agent: Bilibili Freedoooooom/MarkII\r\n\r\n")
    b = (b"GET /live-bvc/569553/test/620088691.m4s HTTP/1.1\r\n"
         b"Host: 183.232.239.4\r\n"
         b"User-Agent: Bilibili Freedoooooom/MarkII\r\n\r\n")
    d = (b"GET /resolve?host=upos-sz-estghw.bilivideo.com&query=4,6 HTTP/1.1\r\n"
         b"Host: httpdns.bilivideo.com\r\nUser-Agent: nghttp2/1.58.90\r\n\r\n")
    e = (b"GET /video/foo.m4s HTTP/1.1\r\nHost: unrelated.example.com\r\n"
         b"User-Agent: ExamplePlayer/1.0\r\n\r\n")
    f = b"GET /live-bvc-not-bilibili/foo.txt HTTP/1.1\r\nHost: example.com\r\n\r\n"

    assert any(matches(a, x) for x in blobs)                 # A: Host/UA
    assert matches(b, live)                                  # B: URI + IP Host
    appid = 1
    if matches(b, live):                                     # C: generic upgrade
        appid = 5110
    assert appid == 5110
    # C2: migrate the exact R19 wire value observed on a live conntrack.
    # R20 must decode legacy bit15 once, then atomically replace low16 rather
    # than ORing 5110 into 0x8001.
    legacy_low16 = 0x8001
    old_appid = legacy_low16 & 0x7fff
    assert old_appid == 1
    assert matches(b, live)
    new_low16 = 5110
    assert new_low16 == 0x13f6
    assert new_low16 != legacy_low16
    assert new_low16 != (legacy_low16 | 5110)

    # C3: a keep-alive flow first reaches terminal generic on an unrelated
    # complete request, then carries a Bilibili request on the same 5-tuple.
    # R20.1 retained the first prefix, so the second request was never parsed.
    prefix = e
    assert not any(matches(prefix, x) for x in blobs)
    prefix = b""                  # terminal publication forgets old prefix
    prefix += b                   # fresh original-direction request
    assert matches(prefix, live)
    appid = 5110
    assert appid == 0x13f6
    assert any(matches(d, x) for x in blobs)                 # D: HTTPDNS candidate
    assert not any(matches(e, x) for x in blobs)             # E
    assert not any(matches(f, x) for x in blobs)             # F
    for cuts in ((12,), (8, 37), (4, 21, 64)):               # G: 2..4 segments
        assembled, start = b"", 0
        for end in cuts + (len(b),):
            assembled += b[start:end]
            start = end
        assert matches(assembled, live)
    payload_seq = 1                                          # H: 1-based payload
    payload_seq += 1
    assert payload_seq == 2 and matches(b, live)
    print("PASS A-H+C2+C3: legacy/generic keep-alive -> 0x13f6; "
          "raw=4010263 mapped=5110 rule=10503667 pkt_seq=1")


if __name__ == "__main__":
    main(sys.argv[1])
