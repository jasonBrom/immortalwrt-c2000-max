#!/usr/bin/env bash

set -euo pipefail

QMODEM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UTIL="$QMODEM_ROOT/files/usr/share/qmodem/modem_util.sh"
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT
LOG="$STATE_DIR/calls.log"

# Host tests do not have OpenWrt's /lib/functions.sh.  Remove only that source
# line; all AT locking functions under test remain byte-for-byte identical.
sed 's#^\. /lib/functions[.]sh$#:#' "$UTIL" > "$STATE_DIR/modem_util.sh"
# shellcheck source=/dev/null
source "$STATE_DIR/modem_util.sh"

uci()
{
	if [[ "$*" == "-q get qmodem.main.serialized_at" ]]; then
		printf '1\n'
		return 0
	fi
	return 1
}

lock()
{
	printf 'lock %s\n' "$*" >> "$LOG"
	if [[ "${FAIL_DAEMON_LOCK:-0}" == 1 && "$*" == /var/lock/qmodem-at-daemon.lock ]]; then
		return 1
	fi
}

tom_modem()
{
	printf 'tom_modem %s\n' "$*" >> "$LOG"
	printf 'AT\r\nOK\r\n'
}

[[ "$(qmodem_at_backend)" == ubus ]] || {
	echo 'automatic AT backend is not serialized ubus' >&2
	exit 1
}

qmodem_at_transaction_begin /dev/mock-at
QMODEM_AT_BACKEND=ubus at_timeout /dev/mock-at AT+CSQ 8 >/dev/null
QMODEM_AT_BACKEND=ubus at_timeout /dev/mock-at AT+CPIN? 8 >/dev/null
qmodem_at_transaction_end /dev/mock-at

# The two nested AT calls must reuse one per-port lock and one daemon lock.
[[ "$(grep -c '^lock /var/lock/qmodem-at-mock-at[.]lock$' "$LOG")" == 1 ]]
[[ "$(grep -c '^lock /var/lock/qmodem-at-daemon[.]lock$' "$LOG")" == 1 ]]
[[ "$(grep -c '^lock -u /var/lock/qmodem-at-mock-at[.]lock$' "$LOG")" == 1 ]]
[[ "$(grep -c '^lock -u /var/lock/qmodem-at-daemon[.]lock$' "$LOG")" == 1 ]]
[[ "$(grep -c '^tom_modem -u -d /dev/mock-at' "$LOG")" == 2 ]]

# If the global daemon lock cannot be acquired, the already-held per-port lock
# must still be released and no spurious global unlock may be attempted.
: > "$LOG"
FAIL_DAEMON_LOCK=1
export FAIL_DAEMON_LOCK
if qmodem_at_transaction_begin /dev/mock-failed; then
	echo 'transaction unexpectedly succeeded with a failed daemon lock' >&2
	exit 1
fi
unset FAIL_DAEMON_LOCK
[[ "$(grep -c '^lock /var/lock/qmodem-at-mock-failed[.]lock$' "$LOG")" == 1 ]]
[[ "$(grep -c '^lock -u /var/lock/qmodem-at-mock-failed[.]lock$' "$LOG")" == 1 ]]
[[ "$(grep -c '^lock /var/lock/qmodem-at-daemon[.]lock$' "$LOG")" == 1 ]]
[[ "$(grep -c '^lock -u /var/lock/qmodem-at-daemon[.]lock$' "$LOG" || true)" == 0 ]]

echo 'QModem serialized AT transaction tests passed'
