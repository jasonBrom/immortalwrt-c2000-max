#!/bin/bash

set -euo pipefail

BOARD_ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
CORE_ACL="$BOARD_ROOT/files/usr/share/rpcd/acl.d/c2000max.json"
NETBIRD_ACL="$BOARD_ROOT/files/usr/share/rpcd/acl.d/zzzz-c2000max-netbird.json"
MENU="$BOARD_ROOT/files/usr/share/luci/menu.d/zzzz-c2000max-netbird.json"
RPC="$BOARD_ROOT/files/usr/libexec/rpcd/c2000max"
VIEW="$BOARD_ROOT/files/www/luci-static/resources/view/c2000max/netbird_async_v353.js"

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

python3 -m json.tool "$CORE_ACL" >/dev/null ||
	fail "core board ACL is invalid JSON"
python3 -m json.tool "$NETBIRD_ACL" >/dev/null ||
	fail "dedicated NetBird ACL is invalid JSON"
python3 -m json.tool "$MENU" >/dev/null ||
	fail "NetBird menu is invalid JSON"

python3 - "$CORE_ACL" "$NETBIRD_ACL" <<'PY'
import copy
import json
import sys

core_path, netbird_path = sys.argv[1:]

with open(core_path, encoding="utf-8") as stream:
    core = json.load(stream)
with open(netbird_path, encoding="utf-8") as stream:
    dedicated = json.load(stream)

required = {
    "read": {"netbird_status", "netbird_job_status"},
    "write": {"netbird_job_start"},
}


def granted(acls):
    result = {"read": set(), "write": set()}
    for acl in acls:
        group = acl.get("c2000max", {})
        for permission in result:
            result[permission].update(
                group.get(permission, {})
                .get("ubus", {})
                .get("c2000max", [])
            )
    return result


def check(label, acls):
    actual = granted(acls)
    for permission, methods in required.items():
        missing = methods - actual[permission]
        if missing:
            raise SystemExit(
                f"{label}: missing {permission} methods: {sorted(missing)}"
            )


# Normal package state.
check("normal ACL union", [core, dedicated])

# Reproduce the V35.3 image regression: an older rootfs overwrites the main
# board ACL after the new package has been selected. The dedicated additive
# ACL must retain every NetBird permission on its own.
stale_core = copy.deepcopy(core)
for permission, methods in required.items():
    values = (
        stale_core["c2000max"]
        .get(permission, {})
        .get("ubus", {})
        .get("c2000max", [])
    )
    stale_core["c2000max"][permission]["ubus"]["c2000max"] = [
        value for value in values if value not in methods
    ]
check("stale core ACL union", [stale_core, dedicated])
PY

grep -Fq '"acl": [ "c2000max" ]' "$MENU" ||
	fail "NetBird menu is not bound to the c2000max ACL group"
for method in netbird_status netbird_job_status netbird_job_start; do
	grep -Fq "\"$method\"" "$RPC" ||
		fail "RPC backend does not expose $method"
	grep -Fq "method: '$method'" "$VIEW" ||
		fail "LuCI view does not call $method"
done

grep -Fq 'zzzz-c2000max-netbird.json $(1)/usr/share/rpcd/acl.d/zzzz-c2000max-netbird.json' \
	"$BOARD_ROOT/Makefile" ||
	fail "dedicated NetBird ACL is not installed by the board package"

echo 'C2000-MAX NetBird ACL regression tests passed'
