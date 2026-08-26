#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
DEFAULTS="$ROOT/files/etc/uci-defaults/99-c2000max-defaults"
DEFS="$ROOT/../../mtk/applications/mtwifi-cfg-ucode/files/usr/share/schema/mtwifi/dat-defs.json"
CONVERTER="$ROOT/../../mtk/applications/mtwifi-cfg-ucode/files/usr/share/ucode/mtwifi/converter.uc"
MTKDAT="$ROOT/../../mtk/drivers/wifi-profile/files/unified_script/mtkdat.lua"
HOSTAPD="$ROOT/../../mtk/drivers/wifi-profile/files/unified_script/hostapd.lua"
VIEW="$ROOT/../../mtk/applications/luci-app-mtwifi-cfg/root/usr/share/luci-app-mtwifi-cfg/wireless-mtk.js"

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

python3 -m json.tool "$DEFS" >/dev/null || fail "DAT encryption definitions are invalid JSON"
grep -Fq '"owe+gcmp256": [ "OWE", "GCMP256" ]' "$DEFS" ||
	fail "OWE+GCMP-256 falls back to OPEN/NONE in the ucode converter"
grep -Fq 'set_token("Mrsno_En", strict_bool(c.rsn_override));' "$CONVERTER" ||
	fail "RSN Override is not forwarded to the vendor profile"

grep -Fq 'auth == "OWE" and encr == "GCMP256"' "$MTKDAT" &&
grep -Fq 'encryption = "owe+gcmp256"' "$MTKDAT" &&
grep -Fq 'encryption == "owe+gcmp256"' "$MTKDAT" &&
grep -Fq "hostapd_cfg.rsn_pairwise = 'GCMP-256'" "$MTKDAT" ||
	fail "DAT/hostapd OWE+GCMP-256 round-trip is incomplete"
grep -Fq 'iface.mrsno_enable = token_get(cfg.Mrsno_En, i, "0")' "$MTKDAT" ||
	fail "hostapd path does not read the vendor RSN Override token"

grep -Fq '["name"] = "owe+gcmp256"' "$HOSTAPD" &&
grep -Fq '["pairwise"] = {"gcmp256"}' "$HOSTAPD" &&
grep -Fq '["ieee80211w"] = "2"' "$HOSTAPD" ||
	fail "hostapd OWE+GCMP-256/PMF template is missing"

grep -Fq "'_owe_cipher'" "$VIEW" &&
grep -Fq "o.value('gcmp256', _('Force GCMP-256 (AES)'))" "$VIEW" ||
	fail "LuCI cannot select or preserve the OWE GCMP-256 cipher"

grep -Fq 'set "wireless.$iface.encryption=owe+gcmp256"' "$DEFAULTS" &&
grep -Fq 'set "wireless.$iface.ieee80211w=2"' "$DEFAULTS" &&
grep -Fq 'set "wireless.$iface.rsn_override=0"' "$DEFAULTS" &&
grep -Fq "wifi_owe_gcmp256_v1='1'" "$DEFAULTS" ||
	fail "factory defaults or preserved-upgrade migration do not enable OWE+GCMP-256 safely"

python3 - "$DEFAULTS" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
start = text.index('if [ "$(uci -q get c2000max.migration.wifi_owe_gcmp256_v1)"')
end = text.index('\nfi\n', start) + 4
block = text[start:end]
required = (
    'ImmortalWrt-2.4G|ImmortalWrt-5G',
    'none|owe',
    '[ -z "$(uci -q get wireless.$iface.key)" ] || continue',
)
if not all(item in block for item in required):
    raise SystemExit('FAIL: OWE migration is not restricted to keyless factory SSIDs')
PY

if command -v node >/dev/null 2>&1; then
	node --check "$VIEW" >/dev/null
fi

echo 'C2000-MAX OWE+GCMP-256 mapping and migration tests passed'
