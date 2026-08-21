#!/bin/sh

set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SRC="$HERE/../src/oaf"
OUT="${TMPDIR:-/tmp}/oaf-ik-regex-host-test"

cc -std=c11 -Wall -Wextra -Wno-sign-compare \
	-I"$HERE/host-compat" -I"$SRC" -include "$HERE/host-compat/compat.h" \
	"$SRC/ik_regex.c" "$HERE/ik_regex_host_test.c" -o "$OUT"
"$OUT"
