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
	printf '%s\n' "$*" >> "$STATE_DIR/log"
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

uci() {
	local args="$*" value
	case "$args" in
		*"get c2000max.sim.slot"*)
			if [[ -s "$STATE_DIR/uci_slot" ]]; then
				state_get uci_slot
			else
				printf '%s\n' "${FAKE_UCI_SLOT:-external2}"
			fi
			;;
		*"set c2000max.sim.slot="*)
			value="${args##*c2000max.sim.slot=}"
			state_set uci_slot "$value"
			;;
		*"commit c2000max"*|*"delete c2000max.sim."*) return 0 ;;
		*) return 1 ;;
	esac
}

fw_printenv() {
	[[ "$1" == -n && "$2" == "$UBOOT_SLOT_KEY" ]] || return 2
	[[ "${FAKE_FW_PRINT_FAIL:-0}" == 0 ]] || return 1
	state_get uboot_slot
}

fw_setenv() {
	[[ "$1" == "$UBOOT_SLOT_KEY" ]] || return 2
	[[ "${FAKE_FW_SET_FAIL:-0}" == 0 ]] || return 1
	state_set uboot_slot "$2"
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

# U-Boot environment survives an upgrade that discards the overlay, so it
# must override the reset image's UCI default. Invalid data falls back safely.
state_set uboot_slot external1
FAKE_UCI_SLOT=external2
assert_eq external1 "$(saved_boot_slot)" "U-Boot slot overrides reset UCI"
state_set uboot_slot sim2
assert_eq external2 "$(saved_boot_slot)" "legacy U-Boot slot normalization"
state_set uboot_slot invalid
FAKE_UCI_SLOT=internal
assert_eq internal "$(saved_boot_slot)" "invalid U-Boot slot fallback"
FAKE_FW_PRINT_FAIL=1
FAKE_UCI_SLOT=sim1
assert_eq external1 "$(saved_boot_slot)" "unreadable U-Boot slot fallback"
FAKE_FW_PRINT_FAIL=0

# A fresh overlay starts with external2, but the first boot attempt must seed
# UCI from the persistent external1 selection before modem enumeration. This
# prevents a delayed retry from overwriting the valid environment with slot 2.
rm -f "$STATE_DIR/uci_slot"
state_set uboot_slot external1
FAKE_UCI_SLOT=external2
sync_configured_slot "$(saved_boot_slot)" ||
	fail_test "persistent slot did not seed reset UCI"
assert_eq external1 "$(state_get uci_slot)" "reset UCI seeded from U-Boot"

# Persistence writes only canonical values. A flash write failure is recorded
# but cannot roll back the physical switch that was already verified.
FAKE_FW_SET_FAIL=0

# A successful write is not enough: unreadable/invalid readback must prevent a
# no-data upgrade from being reported as safely persistent.
: > "$STATE_DIR/log"
state_set uboot_slot external1
FAKE_FW_PRINT_FAIL=1
if persist_physical_slot external2; then
	fail_test "unverifiable U-Boot persistence was accepted"
fi
grep -Fq '读回校验失败' "$STATE_DIR/log" ||
	fail_test "U-Boot readback failure was not recorded"
FAKE_FW_PRINT_FAIL=0
state_set uboot_slot invalid
persist_physical_slot sim1 || fail_test "canonical slot persistence failed"
assert_eq external1 "$(state_get uboot_slot)" "persisted canonical slot"
: > "$STATE_DIR/log"
FAKE_FW_SET_FAIL=1
if persist_physical_slot internal; then
	fail_test "fw_setenv failure was incorrectly reported as success"
fi
assert_eq external1 "$(state_get uboot_slot)" "failed persistence changed prior slot"
grep -Fq '本次成功状态不会回滚' "$STATE_DIR/log" ||
	fail_test "fw_setenv failure was not recorded"
FAKE_FW_SET_FAIL=0

grep -Fq '目标卡槽未能立即激活 SIM（空槽时属于正常状态）' "$SCRIPT" ||
	fail_test "single-card success warning is missing"
grep -Fq "result.success ? value(result.message, _('SIM 卡切换成功'))" \
	"$ROOT/files/www/luci-static/resources/view/c2000max/sim_v8.js" ||
	fail_test "LuCI does not display the backend single-card warning"

DTS="$ROOT/../../../target/linux/mediatek/dts/mt7987a-nradio-c2000-max.dts"
sed -n '/modem-power {/,/};/p' "$DTS" | grep -Fq 'gpio-export,output = <0>;' ||
	fail_test "active-low modem power is not deasserted at GPIO export"
grep -Fq '+uboot-envtools' "$ROOT/Makefile" ||
	fail_test "board package does not depend on U-Boot environment tools"
FWENV="$ROOT/../../../package/boot/uboot-tools/uboot-envtools/files/mediatek_filogic"
grep -Fq 'nradio,c2000-max' "$FWENV" ||
	fail_test "C2000-MAX U-Boot environment partition is not configured"
INIT="$ROOT/files/etc/init.d/c2000max-sim"
if grep -Fq '/usr/sbin/c2000max-sim apply >"$state"' "$INIT"; then
	fail_test "boot retry can still fall back to reset UCI slot"
fi
grep -Fq '/usr/sbin/c2000max-sim boot-restore >"$state"' "$INIT" ||
	fail_test "boot retry does not reuse the persistent slot"
DEFAULTS="$ROOT/files/etc/uci-defaults/99-c2000max-defaults"
grep -Fq 'fw_printenv -n c2000max_sim_slot' "$DEFAULTS" ||
	fail_test "first boot defaults do not import the persistent slot"
grep -Fq 'find_mmc_part u-boot-env' "$DEFAULTS" ||
	fail_test "first boot does not repair an empty fw_env.config"
grep -Fq '[ "$size" = 1024 ]' "$SCRIPT" ||
	fail_test "runtime fw_env repair does not verify the 512 KiB partition"
PLATFORM="$ROOT/../../../target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
grep -Fq '/usr/sbin/c2000max-sim persist' "$PLATFORM" ||
	fail_test "sysupgrade does not persist the current slot before erasing UCI"
grep -Fq '/usr/sbin/c2000max-sim persist >/dev/null 2>&1 || exit 1' \
	"$ROOT/Makefile" ||
	fail_test "live board APK install does not seed SIM persistence"

echo "C2000-MAX MT5700 single-SIM switching tests passed"
