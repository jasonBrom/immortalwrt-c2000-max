#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP="$(cd "$ROOT/../../.." && pwd)"
SIM="$ROOT/files/usr/sbin/c2000max-sim"
SIM_INIT="$ROOT/files/etc/init.d/c2000max-sim"
FAN_INIT="$ROOT/files/etc/init.d/c2000max-fan"
LEDS="$ROOT/files/usr/sbin/c2000max-leds"
MT5700="$TOP/package/custom/mt5700-web-go/src/main.go"
AT_DAEMON_INIT="$TOP/package/custom/qmodem/application/ubus_at_daemon/files/etc/init.d/ubus-at-daemon"
DTS="$TOP/target/linux/mediatek/dts/mt7987a-nradio-c2000-max.dts"
DEFAULTS="$ROOT/files/etc/uci-defaults/99-c2000max-defaults"

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

! grep -Eq '\$\(INSTALL_(BIN|DATA)\).*c2000max-service-worker' "$ROOT/Makefile" ||
	fail 'retired NetBird/package polling worker is still installed'

grep -Fq 'get c2000max.fan.enabled' "$FAN_INIT" ||
	fail 'disabled fan still starts its polling daemon'
grep -q '^START=18$' "$FAN_INIT" ||
	fail 'fan does not start early enough to cover boot-time thermal load'
grep -A2 -F "config fan 'fan'" "$ROOT/files/etc/config/c2000max" |
	grep -Fq "option enabled '1'" ||
	fail 'safe smart-fan factory default is not enabled'
grep -Fq "cpufreq.default_governor=schedutil" "$DTS" ||
	fail 'board kernel command line still pins the CPU to performance'
grep -Fq 'ramoops@5ff80000' "$DTS" ||
	fail 'board has no persistent kernel crash log reservation'
sed -n '/ramoops@5ff80000/,/};/p' "$DTS" | grep -Fq 'no-map;' ||
	fail 'ramoops memory can still be allocated as ordinary DDR'
grep -Fq "interval=15" "$LEDS" ||
	fail 'RGB status poll is not reduced to 15 seconds'
grep -Fq "*) tcpcca='bbr' ;;" "$DEFAULTS" &&
	grep -Fq 'turboacc.config.tcpcca="$tcpcca"' "$DEFAULTS" ||
	fail 'fresh installations do not default TCP congestion control to BBR'

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
