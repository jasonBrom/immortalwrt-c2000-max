#!/usr/bin/env bash

set -euo pipefail

QMODEM_PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$QMODEM_PACKAGE_DIR/files/usr/share/qmodem/vendor/huawei.sh"

# Load only the DS flow helpers and network_info; sourcing the complete vendor
# file would require OpenWrt's generic runtime on the host.
eval "$(sed -n '/^function huawei_dsflow_payload()/,/^function _get_lockband_nr()/p' "$VENDOR" | sed '$d')"

inline='^DSFLOWQRY: 0000002D,0000000000019A01,0000000000736A52,0000002D,0000000000019A01,0000000000736A52
OK'
newline='^DSFLOWQRY:
0000003A,0000000000015863,0000000000834B41,0000003A,0000000000015863,0000000000834B41
OK'

[[ "$(printf '%s\n' "$inline" | huawei_dsflow_payload)" == \
	'0000002D,0000000000019A01,0000000000736A52,0000002D,0000000000019A01,0000000000736A52' ]]
[[ "$(printf '%s\n' "$newline" | huawei_dsflow_payload)" == \
	'0000003A,0000000000015863,0000000000834B41,0000003A,0000000000015863,0000000000834B41' ]]
[[ "$(huawei_hex_flow_to_dec 0000000000736A52)" == 7563858 ]]

STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT
QMODEM_SPEED_STATE_DIR="$STATE_DIR"
config_section=mt5700_test
pdp_index=1
at_port=/dev/mock-at
AT_RESPONSE='^DSFLOWQRY:
00000001,00000000000003E8,00000000000007D0,00000001,00000000000003E8,00000000000007D0
OK'
SPEED_ENTRIES=

at()
{
	printf '%s\n' "$AT_RESPONSE"
}

add_speed_entry()
{
	SPEED_ENTRIES="${SPEED_ENTRIES}${1}=${2} "
}

QMODEM_SPEED_NOW=100 network_info
[[ "$SPEED_ENTRIES" == 'rx=0 tx=0 ' ]]

AT_RESPONSE='^DSFLOWQRY: 00000003,00000000000005DC,0000000000000DAC,00000003,00000000000005DC,0000000000000DAC
OK'
SPEED_ENTRIES=
QMODEM_SPEED_NOW=102 network_info
[[ "$SPEED_ENTRIES" == 'rx=750 tx=250 ' ]]

printf 'PASS: Huawei MT5700 speed uses DSFLOWQRY cumulative byte deltas\n'
