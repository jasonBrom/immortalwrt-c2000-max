#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/files/usr/sbin/c2000max-sim"
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT

fail_test() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_eq() {
	local expected="$1" actual="$2" label="$3"
	[[ "$actual" == "$expected" ]] ||
		fail_test "$label: expected '$expected', got '$actual'"
}

state_set() {
	printf '%s\n' "$2" > "$STATE_DIR/$1"
}

state_get() {
	cat "$STATE_DIR/$1"
}

card_present() {
	local channel gpio
	channel="$(state_get channel)"
	gpio="$(state_get gpio)"
	case "$channel-$gpio" in
		1-*) [[ "$(state_get card_external2)" == 1 ]] ;;
		2-0) [[ "$(state_get card_external1)" == 1 ]] ;;
		2-1) [[ "$(state_get card_internal)" == 1 ]] ;;
		*) return 1 ;;
	esac
}

reset_state() {
	local channel="$1" gpio="$2" external1="$3" external2="$4" internal="$5"
	state_set channel "$channel"
	state_set gpio "$gpio"
	state_set card_external1 "$external1"
	state_set card_external2 "$external2"
	state_set card_internal "$internal"
	state_set active "$(card_present && echo 1 || echo 0)"
	state_set fail_scichg 0
	: > "$STATE_DIR/commands"
	HUAWEI_ACTIVATION_WARNING=0
}

export C2000MAX_SIM_LIBRARY_ONLY=1
# shellcheck source=/dev/null
source "$SCRIPT"

log() {
	:
}

sleep() {
	:
}

read_gpio_mux() {
	state_get gpio
}

write_gpio_mux() {
	state_set gpio "$1"
	printf 'GPIO=%s\n' "$1" >> "$STATE_DIR/commands"
}

write_modem_power() {
	state_set power "$1"
	printf 'POWER=%s\n' "$1" >> "$STATE_DIR/commands"
}

send_at() {
	local _port="$1" command="$2"
	printf '%s\n' "$command" >> "$STATE_DIR/commands"
	case "$command" in
		'AT^SCICHG?')
			case "$(state_get channel)" in
				1) printf '^SCICHG: 0,1\r\nOK\r\n' ;;
				2) printf '^SCICHG: 1,0\r\nOK\r\n' ;;
			esac
			;;
		'AT^SCICHG=0,1')
			if [[ "$(state_get fail_scichg)" == 1 ]]; then
				printf 'ERROR\r\n'
			else
				state_set channel 1
				state_set active 0
				printf 'OK\r\n'
			fi
			;;
		'AT^SCICHG=1,0')
			if [[ "$(state_get fail_scichg)" == 1 ]]; then
				printf 'ERROR\r\n'
			else
				state_set channel 2
				state_set active 0
				printf 'OK\r\n'
			fi
			;;
		'AT^HVSST=1,0')
			if [[ "$(state_get active)" == 1 ]]; then
				state_set active 0
				printf 'OK\r\n'
			else
				printf 'ERROR\r\n'
			fi
			;;
		'AT^HVSST=1,1')
			if card_present; then
				state_set active 1
				printf 'OK\r\n'
			else
				printf 'ERROR\r\n'
			fi
			;;
		'AT+CFUN=0'|'AT+CFUN=1')
			printf 'OK\r\n'
			;;
		*)
			printf 'ERROR\r\n'
			;;
	esac
}

# Only external slot 1 has a card. Selecting empty external slot 2 must still
# complete SCICHG/GPIO routing and report an activation warning, not failure.
reset_state 2 0 1 0 0
switch_huawei /dev/mock 1 1 ||
	fail_test "external1 -> empty external2 was rejected"
assert_eq 1 "$(state_get channel)" "external2 channel"
assert_eq 1 "$(state_get gpio)" "external2 canonical GPIO"
assert_eq 1 "$HUAWEI_ACTIVATION_WARNING" "empty external2 activation warning"
mapfile -t first_commands < "$STATE_DIR/commands"
expected_first=(
	'AT^SCICHG?'
	'AT^HVSST=1,0'
	'GPIO=1'
	'AT^SCICHG=0,1'
	'AT^HVSST=1,1'
	'AT+CFUN=0'
	'AT+CFUN=1'
)
[[ "${first_commands[*]}" == "${expected_first[*]}" ]] ||
	fail_test "MT5700 command order changed: ${first_commands[*]}"

# Returning from an empty slot must tolerate HVSST=1,0 returning ERROR and
# activate the only installed card.
: > "$STATE_DIR/commands"
HUAWEI_ACTIVATION_WARNING=0
switch_huawei /dev/mock 2 0 ||
	fail_test "empty external2 -> populated external1 was rejected"
assert_eq 2 "$(state_get channel)" "external1 channel"
assert_eq 0 "$(state_get gpio)" "external1 GPIO"
assert_eq 1 "$(state_get active)" "external1 activation"
assert_eq 0 "$HUAWEI_ACTIVATION_WARNING" "populated external1 warning"

# Mirror the single-card test with the only card in external slot 2.
reset_state 1 1 0 1 0
switch_huawei /dev/mock 2 0 ||
	fail_test "external2 -> empty external1 was rejected"
assert_eq 2 "$(state_get channel)" "empty external1 channel"
assert_eq 0 "$(state_get gpio)" "empty external1 GPIO"
assert_eq 1 "$HUAWEI_ACTIVATION_WARNING" "empty external1 activation warning"

: > "$STATE_DIR/commands"
HUAWEI_ACTIVATION_WARNING=0
switch_huawei /dev/mock 1 1 ||
	fail_test "empty external1 -> populated external2 was rejected"
assert_eq 1 "$(state_get channel)" "populated external2 channel"
assert_eq 1 "$(state_get active)" "external2 activation"
assert_eq 0 "$HUAWEI_ACTIVATION_WARNING" "populated external2 warning"

# GPIO-only switching on channel 2 must also allow an empty target.
reset_state 2 0 1 0 0
switch_huawei /dev/mock 2 1 ||
	fail_test "external1 -> empty internal SIM was rejected"
assert_eq 2 "$(state_get channel)" "internal channel"
assert_eq 1 "$(state_get gpio)" "internal GPIO"
assert_eq 1 "$HUAWEI_ACTIVATION_WARNING" "empty internal activation warning"

HUAWEI_ACTIVATION_WARNING=0
switch_huawei /dev/mock 2 0 ||
	fail_test "empty internal -> populated external1 was rejected"
assert_eq 0 "$(state_get gpio)" "restored external1 GPIO"
assert_eq 1 "$(state_get active)" "restored external1 activation"
assert_eq 0 "$HUAWEI_ACTIVATION_WARNING" "restored external1 warning"

# A real SCICHG failure remains fatal and must restore the old GPIO.
reset_state 1 1 1 1 0
state_set fail_scichg 1
if switch_huawei /dev/mock 2 0; then
	fail_test "SCICHG failure was incorrectly accepted"
fi
assert_eq 1 "$(state_get channel)" "failed SCICHG channel rollback"
assert_eq 1 "$(state_get gpio)" "failed SCICHG GPIO rollback"
assert_eq 1 "$(state_get active)" "failed SCICHG SIM reactivation"

# With both external cards absent, physical selection is still a valid state.
reset_state 1 1 0 0 0
switch_huawei /dev/mock 2 0 ||
	fail_test "empty external2 -> empty external1 was rejected"
assert_eq 2 "$(state_get channel)" "all-empty target channel"
assert_eq 0 "$(state_get gpio)" "all-empty target GPIO"
assert_eq 1 "$HUAWEI_ACTIVATION_WARNING" "all-empty activation warning"

# A warm boot must remove modem power before restoring GPIO48 and may only
# power the module back on after the saved physical mux is stable.
: > "$STATE_DIR/commands"
state_set power 1
state_set gpio 1
prepare_modem_boot external1 ||
	fail_test "external1 early boot preparation failed"
mapfile -t boot_external1 < "$STATE_DIR/commands"
expected_boot_external1=(
	'POWER=0'
	'GPIO=0'
	'POWER=1'
)
[[ "${boot_external1[*]}" == "${expected_boot_external1[*]}" ]] ||
	fail_test "external1 boot power/mux order changed: ${boot_external1[*]}"

: > "$STATE_DIR/commands"
prepare_modem_boot internal ||
	fail_test "internal SIM early boot preparation failed"
mapfile -t boot_internal < "$STATE_DIR/commands"
expected_boot_internal=(
	'POWER=0'
	'GPIO=1'
	'POWER=1'
)
[[ "${boot_internal[*]}" == "${expected_boot_internal[*]}" ]] ||
	fail_test "internal boot power/mux order changed: ${boot_internal[*]}"

grep -Fq '目标卡槽未能立即激活 SIM（空槽时属于正常状态）' "$SCRIPT" ||
	fail_test "single-card success warning is missing"
grep -Fq "result.success ? value(result.message, _('SIM 卡切换成功'))" \
	"$ROOT/files/www/luci-static/resources/view/c2000max/sim_v8.js" ||
	fail_test "LuCI does not display the backend single-card warning"

echo "C2000-MAX MT5700 single-SIM switching tests passed"
