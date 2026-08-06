#!/bin/bash

set -euo pipefail

HUAWEI="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)/qmodem/application/qmodem/files/usr/share/qmodem/vendor/huawei.sh"
config_section="fixture_$$"
at_port=/dev/fake
CACHE_FILE="/tmp/cache_c2000max_huawei_detail_${config_section}"
CALL_LOG="/tmp/c2000max_huawei_detail_calls_$$"
trap 'rm -f "$CACHE_FILE" "$CALL_LOG"' EXIT

# The production script's generic QModem include is not installed on the host
# running this fixture.  Its function definitions are still loaded.
. "$HUAWEI" 2>/dev/null || true
declare -F _c2000max_huawei_detail_load >/dev/null

at()
{
	printf '%s\n' "$2" >> "$CALL_LOG"
	case "$2" in
		"AT^HFREQINFO?")
			printf '%s\r\n' \
				'^HFREQINFO: 0,7,41,504990,2524950,100000,504990,2524950,100000,41,500000,2500000,80000,500000,2500000,40000' \
				'OK'
			;;
		"AT^DSAMBR=8")
			printf '%s\r\n' '^DSAMBR: 8,1000000,200000' 'OK'
			;;
		"AT+CGEQOSRDP=8")
			printf '%s\r\n' '+CGEQOSRDP: 8,9,0,0' 'OK'
			;;
		*)
			printf '%s\r\n' 'ERROR'
			;;
	esac
}

_c2000max_huawei_detail_load 7
[[ "$c2000max_detail_band" == 41 ]]
[[ "$c2000max_detail_dl_fcn" == 504990 ]]
[[ "$c2000max_detail_dlbw" == 100000 ]]
[[ "$c2000max_detail_band1" == 41 ]]
[[ "$c2000max_detail_dlbw1" == 80000 ]]
[[ "$c2000max_detail_ulbw1" == 40000 ]]
[[ "$c2000max_detail_cqi" == 9 ]]
[[ "$c2000max_detail_ambr_dl" == 1000000 ]]
[[ "$c2000max_detail_ambr_ul" == 200000 ]]
[[ "$(wc -l < "$CALL_LOG")" == 3 ]]

at()
{
	printf '%s\n' "unexpected:$2" >> "$CALL_LOG"
	return 1
}
_c2000max_huawei_detail_reset
_c2000max_huawei_detail_load 7
[[ "$c2000max_detail_band" == 41 ]]
[[ "$c2000max_detail_cqi" == 9 ]]
[[ "$(wc -l < "$CALL_LOG")" == 3 ]]

echo "PASS: Huawei APP-detail parser uses official fields and a 60-second cache"
