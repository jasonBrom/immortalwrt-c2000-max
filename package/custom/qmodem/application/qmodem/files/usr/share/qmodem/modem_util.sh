#!/bin/sh
# Copyright (C) 2024 Tom <fjrcn@outlook.com>
. /lib/functions.sh

qmodem_at_config_section()
{
  printf '%s\n' "${modem_config:-${config_section:-}}"
}

qmodem_at_is_fibocom_mediatek()
{
  local identity value

  value="$(printf '%s' "${platform:-}" | tr 'A-Z' 'a-z')"
  [ "$value" = "mediatek" ] || return 1
  for identity in "${manufacturer:-}" "${vendor:-}" "${_Vendor:-}"; do
    value="$(printf '%s' "$identity" | tr 'A-Z' 'a-z')"
    case "$value" in
      *fibocom*) return 0 ;;
    esac
  done
  return 1
}

qmodem_at_backend()
{
  local section backend serialized

  section="$(qmodem_at_config_section)"
  backend="${QMODEM_AT_BACKEND:-}"
  [ -n "$backend" ] || [ -z "$section" ] ||
    backend="$(uci -q get "qmodem.${section}.at_backend" 2>/dev/null)"
  case "$backend" in
    ubus|sms_tool_q|tom_modem) ;;
    *) backend="auto" ;;
  esac

  if [ "$backend" = "auto" ]; then
    serialized="$(uci -q get qmodem.main.serialized_at 2>/dev/null)"
    # A modem AT channel is a request/response stream, not a datagram socket.
    # Keep one reader (ubus-at-daemon) for every automatic backend unless an
    # administrator explicitly opts out for low-level troubleshooting.
    if [ "$serialized" != "0" ]; then
      backend="ubus"
    elif qmodem_at_is_fibocom_mediatek; then
      backend="ubus"
    elif [ "$(uci -q get qmodem.main.at_tool 2>/dev/null)" = "1" ]; then
      backend="sms_tool_q"
    elif [ "${use_ubus:-}" = "1" ] || [ "${use_ubus_flag:-}" = "-u" ]; then
      backend="ubus"
    else
      backend="tom_modem"
    fi
  fi
  printf '%s\n' "$backend"
}

qmodem_at_lock_path()
{
  local port="$1" canonical name

  [ -n "$port" ] || return 1
  canonical="$(readlink -f "$port" 2>/dev/null)"
  [ -z "$canonical" ] || port="$canonical"
  name="${port##*/}"
  name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_')"
  [ -n "$name" ] || return 1
  printf '/var/lock/qmodem-at-%s.lock\n' "$name"
}

qmodem_at_lock()
{
  local lock_file

  lock_file="$(qmodem_at_lock_path "$1")" || return 1
  lock "$lock_file"
}

qmodem_at_unlock()
{
  local lock_file

  lock_file="$(qmodem_at_lock_path "$1")" || return 1
  lock -u "$lock_file"
}

qmodem_at_port_key()
{
  local path key

  path="$(qmodem_at_lock_path "$1")" || return 1
  key="${path#/var/lock/qmodem-at-}"
  printf '%s\n' "${key%.lock}"
}

qmodem_at_transaction_active()
{
  local key

  if [ "${QMODEM_AT_TRANSACTION_PORT:-}" = "$1" ] &&
    [ "${QMODEM_AT_TRANSACTION_DAEMON_LOCKED:-0}" = "1" ]; then
    return 0
  fi
  key="$(qmodem_at_port_key "$1")" || return 1
  [ -n "${QMODEM_AT_TRANSACTION_PORT_KEY:-}" ] &&
    [ "$QMODEM_AT_TRANSACTION_PORT_KEY" = "$key" ] &&
    [ "${QMODEM_AT_TRANSACTION_DAEMON_LOCKED:-0}" = "1" ]
}

# Acquire both locks once for a multi-command modem operation.  Callers such
# as a physical SIM switch can then run HVSST/SCICHG/GPIO/CFUN as one atomic AT
# transaction; nested at()/fastat() calls recognise the transaction and do not
# deadlock by taking the same locks again.
qmodem_at_transaction_begin()
{
  local port="$1" key daemon_lock

  [ -z "${QMODEM_AT_TRANSACTION_PORT_KEY:-}" ] || return 1
  key="$(qmodem_at_port_key "$port")" || return 1
  qmodem_at_lock "$port" || return 1
  daemon_lock="${QMODEM_AT_DAEMON_LOCK:-/var/lock/qmodem-at-daemon.lock}"

  # Publish partial ownership before the potentially blocking global acquire.
  # A caller's signal/EXIT cleanup can then release the port lock as well.
  QMODEM_AT_TRANSACTION_PORT="$port"
  QMODEM_AT_TRANSACTION_PORT_KEY="$key"
  QMODEM_AT_TRANSACTION_DAEMON_LOCK="$daemon_lock"
  QMODEM_AT_TRANSACTION_DAEMON_LOCKED=0
  export QMODEM_AT_TRANSACTION_PORT QMODEM_AT_TRANSACTION_PORT_KEY
  export QMODEM_AT_TRANSACTION_DAEMON_LOCK QMODEM_AT_TRANSACTION_DAEMON_LOCKED
  if ! lock "$daemon_lock"; then
    qmodem_at_transaction_end "$port"
    return 1
  fi
  QMODEM_AT_TRANSACTION_DAEMON_LOCKED=1
  export QMODEM_AT_TRANSACTION_DAEMON_LOCKED
}

qmodem_at_transaction_end()
{
  local port="${1:-${QMODEM_AT_TRANSACTION_PORT:-}}"
  local daemon_lock="${QMODEM_AT_TRANSACTION_DAEMON_LOCK:-}"

  [ -n "${QMODEM_AT_TRANSACTION_PORT_KEY:-}" ] || return 0
  if [ "${QMODEM_AT_TRANSACTION_DAEMON_LOCKED:-0}" = "1" ] &&
    [ -n "$daemon_lock" ]; then
    lock -u "$daemon_lock"
  fi
  [ -z "$port" ] || qmodem_at_unlock "$port"
  unset QMODEM_AT_TRANSACTION_PORT QMODEM_AT_TRANSACTION_PORT_KEY
  unset QMODEM_AT_TRANSACTION_DAEMON_LOCK QMODEM_AT_TRANSACTION_DAEMON_LOCKED
}

qmodem_at_transaction()
(
  local port="$1"
  shift

  trap 'qmodem_at_transaction_end "$port"' 0
  trap 'exit 128' 1 2 15
  qmodem_at_transaction_begin "$port" || exit 1
  "$@"
)

qmodem_mbim_lock_path()
{
  local device="$1" canonical name

  [ -n "$device" ] || return 1
  canonical="$(readlink -f "$device" 2>/dev/null)"
  [ -z "$canonical" ] || device="$canonical"
  name="${device##*/}"
  name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_')"
  [ -n "$name" ] || return 1
  printf '/var/lock/qmodem-mbim-%s.lock\n' "$name"
}

qmodem_mbim_run()
(
  local device="$1" lock_file
  shift

  lock_file="$(qmodem_mbim_lock_path "$device")" || exit 1
  lock "$lock_file" || exit 1
  trap 'lock -u "$lock_file"' 0
  trap 'exit 128' 1 2 15
  "$@"
)

qmodem_at_daemon_close()
{
  local port="$1"

  printf '%s' "$port" | grep -qE '^/dev/[A-Za-z0-9_.:/-]+$' || return 1
  if ! ubus call at-daemon close "{\"at_port\":\"$port\"}" >/dev/null 2>&1; then
    # No daemon is harmless; a live daemon refusing to release the port is not.
    ubus -S list at-daemon 2>/dev/null | grep -qx 'at-daemon' && return 1
  fi
  return 0
}

# Run one command while sharing the same per-port lock as at()/fastat().
# "direct" closes the daemon first so a TTY client never races its reader.
qmodem_at_run()
(
  local port="$1" mode="$2" daemon_lock=""
  shift 2

  if qmodem_at_transaction_active "$port"; then
    if [ "$mode" = "direct" ]; then
      qmodem_at_daemon_close "$port" || exit 1
    fi
    if [ "${QMODEM_AT_READY_FD:-}" = "3" ]; then
      printf '1' >&3
    fi
    "$@"
    exit $?
  fi

  qmodem_at_lock "$port" || exit 1
  trap '[ -z "$daemon_lock" ] || lock -u "$daemon_lock"; qmodem_at_unlock "$port"' 0
  if [ "$mode" = "queued" ] || [ "$mode" = "direct" ]; then
    # ubus-at-daemon currently services ubus methods synchronously on one
    # uloop thread.  Serialize before invoking it so a second modem waits here
    # instead of submitting a request that times out in the socket queue and
    # executes late after the caller has already retried.  Direct clients take
    # the same lock before asking the daemon to release its TTY.
    daemon_lock="${QMODEM_AT_DAEMON_LOCK:-/var/lock/qmodem-at-daemon.lock}"
    lock "$daemon_lock" || exit 1
  fi
  trap 'exit 128' 1 2 15
  if [ "$mode" = "direct" ]; then
    qmodem_at_daemon_close "$port" || exit 1
  fi
  # modem_scand supplies fd 3 as a one-byte readiness channel.  Signal only
  # after both locks are held so its AT deadline excludes legitimate time
  # spent behind an ongoing FM350 activation transaction.
  if [ "${QMODEM_AT_READY_FD:-}" = "3" ]; then
    printf '1' >&3
  fi
  "$@"
)

qmodem_tom_modem()
{
  local port="$1" backend
  shift

  backend="$(qmodem_at_backend)"
  if [ "$backend" = "ubus" ]; then
    qmodem_at_run "$port" queued tom_modem -u -d "$port" "$@"
  else
    qmodem_at_run "$port" direct tom_modem -d "$port" "$@"
  fi
}

qmodem_sms_tool_q()
{
  local port="$1"
  shift

  qmodem_at_run "$port" direct sms_tool_q -d "$port" "$@"
}

at_timeout()
{
  local at_port="$1"
  local new_str="${2/[$]/$}"
  local atcmd="${new_str/\"/\"}"
  local timeout_seconds="${3:-5}"
  local backend at_options rc

  case "$timeout_seconds" in
    ''|*[!0-9]*) timeout_seconds=5 ;;
  esac
  [ "$timeout_seconds" -ge 1 ] 2>/dev/null || timeout_seconds=5

  backend="$(qmodem_at_backend)"

  at_options="${options:-}"
  [ "${clear_buffer:-}" = "1" ] && at_options="$at_options -M"
  case "$backend" in
    sms_tool_q)
      qmodem_at_run "$at_port" direct \
        sms_tool_q -t "$timeout_seconds" -d "$at_port" at "$atcmd"
      rc=$?
      ;;
    ubus)
      qmodem_at_run "$at_port" queued \
        tom_modem -u -d "$at_port" -o a -c "$atcmd" \
        -t "$timeout_seconds" $at_options
      rc=$?
      ;;
    *)
      qmodem_at_run "$at_port" direct \
        tom_modem -d "$at_port" -o a -c "$atcmd" \
        -t "$timeout_seconds" $at_options
      rc=$?
      ;;
  esac
  return "$rc"
}

at()
{
  at_timeout "$1" "$2" 5
}

fastat()
{
  at_timeout "$1" "$2" 1
}

log2file()
{
	local subject="$1"
    local msg="$2"
	local path="$3"

	#打印日志
    local update_time=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${update_time}] ${subject}:${msg} " >> "${path}"
}

log2sys()
{
    local subject="$1"
    local msg="$2"
    logger -t "$subject" "$msg"
}

m_debug ()
{
	[ -z "$debug_subject" ] && subject="modem_util" || subject="$debug_subject"
	[ -n "$direct_debug" ] && echo "$subject" "$1"
	if [ -n "$log_file" ];then
		log2file "$subject" "$1" "$log_file"
	else
		log2sys "$subject" "$1"
	fi
}

qmodem_bool_enabled()
{
	case "$1" in
		1|true|TRUE|True|yes|YES|on|ON)
			return 0
			;;
	esac
	return 1
}

qmodem_lockcell_boot_hook_clear()
{
	local section="$1"

	[ -z "$section" ] && return 1
	uci -q delete "qmodem.${section}.lockcell_boot_hook_enabled"
	uci -q delete "qmodem.${section}.lockcell_boot_hook_delay"
	uci -q delete "qmodem.${section}.lockcell_boot_hook_at_cmds"
	uci commit qmodem >/dev/null 2>&1
}

qmodem_lockcell_boot_hook_save()
{
	local section="$1"
	local delay="$2"
	local cmd

	shift 2
	[ -z "$section" ] && return 1
	[ -z "$delay" ] && delay="15"

	uci -q delete "qmodem.${section}.lockcell_boot_hook_at_cmds"
	uci -q set "qmodem.${section}.lockcell_boot_hook_enabled=1" || return 1
	uci -q set "qmodem.${section}.lockcell_boot_hook_delay=${delay}" || return 1

	for cmd in "$@"; do
		if [ -n "$cmd" ]; then
			uci -q add_list "qmodem.${section}.lockcell_boot_hook_at_cmds=${cmd}" || return 1
		fi
	done

	uci commit qmodem >/dev/null 2>&1
}

qmodem_lockcell_boot_hook_add_json()
{
	local section="$1"
	local enabled delay
	local has_cmds=0

	enabled=$(uci -q get "qmodem.${section}.lockcell_boot_hook_enabled")
	delay=$(uci -q get "qmodem.${section}.lockcell_boot_hook_delay")
	[ -z "$delay" ] && delay="15"
	config_load qmodem
	config_list_foreach "$section" lockcell_boot_hook_at_cmds qmodem_lockcell_mark_list_cmd

	json_add_object "lockcell_boot_hook"
	if qmodem_bool_enabled "$enabled" && [ "$has_cmds" = "1" ]; then
		json_add_boolean "enabled" 1
	else
		json_add_boolean "enabled" 0
	fi
	json_add_string "delay" "$delay"
	json_add_array "at_cmds"
	config_list_foreach "$section" lockcell_boot_hook_at_cmds qmodem_json_add_list_string
	json_close_array
	json_close_object
}

qmodem_lockcell_mark_list_cmd()
{
	[ -n "$1" ] && has_cmds=1
}

qmodem_json_add_list_string()
{
	[ -n "$1" ] && json_add_string "" "$1"
}

qmodem_lockcell_boot_hook_sync()
{
	local section="$1"
	local en_boot_hook="$2"

	shift 2
	if qmodem_bool_enabled "$en_boot_hook"; then
		[ -z "$*" ] && qmodem_lockcell_boot_hook_clear "$section" && return
		qmodem_lockcell_boot_hook_save "$section" 15 "$@"
	else
		qmodem_lockcell_boot_hook_clear "$section"
	fi
}

update_sim_slot()
{
	. /lib/functions.sh
	board=$(board_name)
	case $board in
		HC,HC-G80*)
			sim_pin="/sys/class/gpio/sim/value"
			sim_pin_value=$(cat $sim_pin)
			[ "$sim_pin_value" == "0" ] && sim_slot="2" || sim_slot="1"
			#电平高表示SIM卡在卡槽1，电平低表示SIM卡在卡槽2
			debug "update_sim_slot:sim_slot=$sim_slot"
			;;
		ailf,gs2410|\
		huasifei,ws3006)
			sim_pin="/sys/class/gpio/dual_sim/value"
			#电平高则都在卡槽1，电平低则需要使用at查询
			[ "$(cat $sim_pin)" == "1" ] && sim_slot="1" || at_get_slot
			;;
		*)
			at_get_slot
			;;
	esac
}

at_get_slot()
{
	case $vendor in
		"quectel")
			at_res=$(at "$at_port" "AT+QUIMSLOT?" | awk -F':' '/\+(QUIMSLOT|QUSIMSLOT):/ {
				value=$2
				gsub(/[^0-9]/, "", value)
				print value
				exit
			}')
			case "$at_res" in
				"1")
					sim_slot="1"
					;;
				"2")
					sim_slot="2"
					;;
				*)
					sim_slot="1"
					;;
			esac
			;;
		"fibocom")
			at_res=$(at $at_port AT+GTDUALSIM? |grep +GTDUALSIM: |awk -F: '{print $2}')
			case $at_res in
				"0")
					sim_slot="1"
					;;
				"1")
					sim_slot="2"
					;;
				*)
					sim_slot="1"
					;;
			*)
				sim_slot="1"
				;;
			esac
			;;
		"simcom")
			at_res=$(at $at_port AT+SMSIMCFG? | grep "+SMSIMCFG:" | awk -F',' '{print $2}' | sed 's/\r//g')
			case $at_res in
				"1")
					sim_slot="1"
					;;
				"2")
					sim_slot="2"
					;;
				*)
					sim_slot="1"
					;;
			*)
				sim_slot="1"
				;;
			esac
			;;
		"meig")
			at_res=$(at $at_port AT^SIMSLOT? | grep "\^SIMSLOT:" | awk -F': ' '{print $2}' | awk -F',' '{print $2}')
			case $at_res in
				"1")
					sim_slot="1"
					;;
				"0")
					sim_slot="2"
					;;
				*)
					sim_slot="1"
					;;
			*)
				sim_slot="1"
				;;
			esac
			;;
		"neoway")
			at_res=$(at $at_port 'AT+SIMCROSS?' | grep "+SIMCROSS:" | awk -F'[ ,]' '{print $2}' | sed 's/\r//g')
			case $at_res in
				"1")
					sim_slot="1"
					;;
				"2")
					sim_slot="2"
					;;
				*)
					sim_slot="1"
					;;
			*)
				sim_slot="1"
				;;
			esac
			;;
		"telit")
			at_res=$(at $at_port AT#QSS? | grep "#QSS:" | awk -F',' '{print $3}' | sed 's/\r//g')
			case $at_res in
				"0")
					sim_slot="1"
					;;
				"1")
					sim_slot="2"
					;;
				*)
					sim_slot="1"
					;;
			*)
				sim_slot="1"
				;;
			esac
			;;
		*)
			at_q_res=$(at $at_port AT+QSIMDET? |grep +QSIMDET: |awk -F: '{print $2}')
			at_f_res=$(at $at_port AT+GTDUALSIM? |grep +GTDUALSIM: |awk -F: '{print $2}')
			[ "$at_q_res" == "1" ] && sim_slot="1" && return
			[ "$at_q_res" == "2" ] && sim_slot="2" && return
			[ "$at_f_res" == "0" ] && sim_slot="1" && return
			[ "$at_f_res" == "1" ] && sim_slot="2" && return
			sim_slot="1"
		;;

	esac
}
