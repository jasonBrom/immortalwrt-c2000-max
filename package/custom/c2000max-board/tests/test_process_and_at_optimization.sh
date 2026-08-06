#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP="$(cd "$ROOT/../../.." && pwd)"
WORKER="$ROOT/files/usr/sbin/c2000max-service-worker"
SIM="$ROOT/files/usr/sbin/c2000max-sim"
FAN_INIT="$ROOT/files/etc/init.d/c2000max-fan"
LEDS="$ROOT/files/usr/sbin/c2000max-leds"
MT5700="$TOP/package/custom/mt5700-web-go/src/main.go"

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

grep -Fq 'at_timeout "$port" "$command" 10' "$SIM" ||
	fail 'SIM switching bypasses the QModem AT queue'
grep -Fq 'begin_at_transaction "$at_port"' "$SIM" ||
	fail 'SIM command sequence is not wrapped in one AT transaction'
! grep -Eq 'tom_modem[[:space:]]+-d' "$SIM" ||
	fail 'SIM switching still opens the modem serial port directly'

grep -Fq 'newQModemQueuedBackend' "$MT5700" ||
	fail 'MT5700 panel does not use the QModem queue backend'
! grep -Fq 'syscall.Open' "$MT5700" ||
	fail 'MT5700 panel still opens the AT serial device directly'
grep -Fq 'WSIdleTimeout' "$MT5700" ||
	fail 'MT5700 stale WebSocket cleanup is missing'
grep -Fq 'rotatingLogWriter' "$MT5700" ||
	fail 'MT5700 bounded log rotation is missing'

echo 'C2000-MAX process and AT optimization tests passed'
