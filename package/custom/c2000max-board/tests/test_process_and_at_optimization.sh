#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP="$(cd "$ROOT/../../.." && pwd)"
WORKER="$ROOT/files/usr/sbin/c2000max-service-worker"
SIM="$ROOT/files/usr/sbin/c2000max-sim"
SIM_INIT="$ROOT/files/etc/init.d/c2000max-sim"
FAN_INIT="$ROOT/files/etc/init.d/c2000max-fan"
LEDS="$ROOT/files/usr/sbin/c2000max-leds"
MT5700="$TOP/package/custom/mt5700-web-go/src/main.go"
AT_DAEMON_INIT="$TOP/package/custom/qmodem/application/ubus_at_daemon/files/etc/init.d/ubus-at-daemon"
DTS="$TOP/target/linux/mediatek/dts/mt7987a-nradio-c2000-max.dts"

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

grep -Fq 'C2000MAX_WORKER_INTERVAL:-30' "$WORKER" ||
	fail 'service worker is not on the 30-second default interval'
! grep -Fq "tr '\\000' ' ' < \"\$proc/cmdline\"" "$WORKER" ||
	fail 'service worker still forks tr once per process'
grep -Fq "kill \"\$sleeper\"" "$WORKER" ||
	fail 'USR1 wake-up can leave orphan sleep processes'

grep -Fq 'get c2000max.fan.enabled' "$FAN_INIT" ||
	fail 'disabled fan still starts its polling daemon'
grep -Fq "interval=15" "$LEDS" ||
	fail 'RGB status poll is not reduced to 15 seconds'

grep -Fq 'C2000MAX_SIM_AT_BACKEND:-ubus' "$SIM" ||
	fail 'SIM switching bypasses the QModem AT queue'
grep -Fq 'begin_at_transaction "$at_port"' "$SIM" ||
	fail 'SIM command sequence is not wrapped in one AT transaction'
! grep -Eq 'tom_modem[[:space:]]+-d' "$SIM" ||
	fail 'SIM switching still opens the modem serial port directly'
grep -q '^START=12$' "$SIM_INIT" ||
	fail 'saved SIM mux/power preparation does not run early in rc.d'
grep -Fq 'boot-prepare' "$SIM_INIT" ||
	fail 'early SIM startup does not separate GPIO preparation from AT verification'
grep -Fq 'C2000MAX_SIM_SKIP_BOOT_PREPARE=1' "$SIM_INIT" ||
	fail 'normal AT verification can still repeat the modem power cycle'
! grep -Fq 'C2000MAX_SIM_AT_BACKEND=tom_modem' "$SIM_INIT" ||
	fail 'boot restore still bypasses the serialized ubus AT backend'
grep -Fq 'boot-restore' "$SIM_INIT" ||
	fail 'SIM init service does not restore the saved slot at boot'
! grep -Fq 'sleep 10; exec /usr/sbin/c2000max-sim apply' "$SIM_INIT" ||
	fail 'old asynchronous SIM/QModem startup race is still present'
grep -q '^START=79$' "$AT_DAEMON_INIT" ||
	fail 'ubus-at-daemon still starts after QModem scanners/dialers'
sed -n '/modem-power {/,/};/p' "$DTS" | grep -Fq 'gpio-export,output = <1>;' ||
	fail 'kernel does not keep the active-low modem supply at raw physical high/off before mux restore'

grep -Fq 'newQModemQueuedBackend' "$MT5700" ||
	fail 'MT5700 panel does not use the QModem queue backend'
! grep -Fq 'syscall.Open' "$MT5700" ||
	fail 'MT5700 panel still opens the AT serial device directly'
grep -Fq 'WSIdleTimeout' "$MT5700" ||
	fail 'MT5700 stale WebSocket cleanup is missing'
grep -Fq 'rotatingLogWriter' "$MT5700" ||
	fail 'MT5700 bounded log rotation is missing'

echo 'C2000-MAX process and AT optimization tests passed'
