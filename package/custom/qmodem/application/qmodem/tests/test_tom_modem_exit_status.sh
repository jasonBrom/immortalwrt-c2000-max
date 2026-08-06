#!/bin/sh

set -eu

ROOT="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/tom_modem/src"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cp -a "$SOURCE/." "$TMP/"
make -C "$TMP" -j2 >/dev/null

python3 - "$TMP/tom_modem" <<'PY'
import os
import pty
import subprocess
import sys

binary = sys.argv[1]
master, slave = pty.openpty()
try:
    result = subprocess.run(
        [
            binary,
            "-d", os.ttyname(slave),
            "-o", "a",
            "-c", "AT+CGACT?",
            "-t", "1",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=False,
    )
finally:
    os.close(master)
    os.close(slave)

if result.returncode == 0:
    raise SystemExit("tom_modem reported success for a timed-out AT transaction")
PY

if "$TMP/tom_modem" >/dev/null 2>&1; then
	echo "tom_modem accepted missing arguments" >&2
	exit 1
fi

echo "tom_modem exit-status regression passed"
