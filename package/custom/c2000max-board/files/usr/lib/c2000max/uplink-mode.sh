#!/bin/sh

C2000_WAN_MODE_ONLY="${C2000_WAN_MODE_ONLY:-ethernet_only}"
C2000_WAN_MODE_BALANCE="${C2000_WAN_MODE_BALANCE:-ethernet_5g_balance}"
C2000_MWAN_ETH_MEMBER="${C2000_MWAN_ETH_MEMBER:-c2000_eth_member}"
C2000_MWAN_CELL_MEMBER="${C2000_MWAN_CELL_MEMBER:-c2000_cell_member}"
C2000_MWAN_POLICY="${C2000_MWAN_POLICY:-c2000_balanced}"
C2000_MWAN_RULE="${C2000_MWAN_RULE:-c2k_default_v4}"
C2000_UPLINK_ERROR=""

c2000_valid_uci_name()
{
	case "$1" in
		''|*[!A-Za-z0-9_]*)
			return 1
			;;
	esac
	return 0
}

c2000_wan_settings_valid()
{
	local mode="$1" ethernet_weight="$2" cellular_weight="$3" modem="$4"

	case "$mode" in
		"$C2000_WAN_MODE_ONLY"|"$C2000_WAN_MODE_BALANCE") ;;
		*) return 1 ;;
	esac
	case "$ethernet_weight:$cellular_weight" in
		*[!0-9:]*|:*|*:) return 1 ;;
	esac
	[ "$ethernet_weight" -ge 1 ] 2>/dev/null &&
		[ "$ethernet_weight" -le 99 ] 2>/dev/null &&
		[ "$cellular_weight" -ge 1 ] 2>/dev/null &&
		[ "$cellular_weight" -le 99 ] 2>/dev/null &&
		[ $((ethernet_weight + cellular_weight)) -eq 100 ] 2>/dev/null ||
		return 1
	[ "$modem" = auto ] || c2000_valid_uci_name "$modem"
}

c2000_modem_sections()
{
	uci -q show qmodem 2>/dev/null |
		sed -n 's/^qmodem\.\([^.=]*\)=modem-device$/\1/p' |
		sort
}

c2000_modem_enabled()
{
	local section="$1" state enabled devices saved

	state="$(uci -q get "qmodem.${section}.state")"
	devices="$(uci -q get c2000max.ethernet.qmodem_overridden_devices)"
	if c2000_list_has "$devices" "$section"; then
		saved="$(uci -q get "c2000max.ethernet.qmodem_saved_${section}")"
		[ "$saved" = __unset__ ] && enabled="" || enabled="$saved"
	else
		enabled="$(uci -q get "qmodem.${section}.enable_dial")"
	fi
	# QModem treats a missing per-device enable_dial as enabled; only an
	# explicit zero disables that modem.
	[ "$state" != disabled ] && [ "$enabled" != 0 ]
}

c2000_modem_interface()
{
	local section="$1" interface

	interface="$(uci -q get "qmodem.${section}.alias")"
	[ -n "$interface" ] || interface="$section"
	c2000_valid_uci_name "$interface" || return 1
	printf '%s\n' "$interface"
}

c2000_cell_interface_safe()
{
	local modem="$1" interface="$2" type owner

	case "$interface" in
		lan|wan|wan6|loopback|br_lan|"$C2000_WAN4"|"$C2000_WAN6"|\
		"$C2000_MWAN_ETH_MEMBER"|"$C2000_MWAN_CELL_MEMBER"|\
		"$C2000_MWAN_POLICY"|"$C2000_MWAN_RULE")
			return 1
			;;
	esac
	type="$(uci -q get "network.${interface}")"
	[ -n "$type" ] || return 0
	owner="$(uci -q get "network.${interface}.modem_config")"
	[ "$type" = interface ] && [ "$owner" = "$modem" ]
}

c2000_modem_is_up()
{
	local interface="$1"

	ubus call "network.interface.${interface}" status 2>/dev/null |
		jsonfilter -e '@.up' 2>/dev/null |
		grep -qx true
}

c2000_select_modem()
{
	local requested="$1" section interface candidate="" up_candidate=""
	local count=0 up_count=0

	if [ "$requested" != auto ]; then
		[ "$(uci -q get "qmodem.${requested}")" = modem-device ] &&
			c2000_modem_enabled "$requested" || return 1
		interface="$(c2000_modem_interface "$requested")" || return 1
		printf '%s|%s\n' "$requested" "$interface"
		return 0
	fi

	for section in $(c2000_modem_sections); do
		c2000_modem_enabled "$section" || continue
		interface="$(c2000_modem_interface "$section")" || continue
		count=$((count + 1))
		candidate="${section}|${interface}"
		if c2000_modem_is_up "$interface"; then
			up_count=$((up_count + 1))
			up_candidate="$candidate"
		fi
	done

	[ "$count" -gt 0 ] || return 1
	if [ "$count" -eq 1 ]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	if [ "$up_count" -eq 1 ]; then
		printf '%s\n' "$up_candidate"
		return 0
	fi
	return 2
}

c2000_gcd()
{
	local a="$1" b="$2" t

	while [ "$b" -ne 0 ]; do
		t=$((a % b))
		a="$b"
		b="$t"
	done
	printf '%s\n' "$a"
}

c2000_mwan_owned()
{
	[ "$(uci -q get "mwan3.${1}.c2000max_managed")" = 1 ]
}

c2000_mwan_collision_free()
{
	local section="$1"

	[ -z "$(uci -q get "mwan3.${section}")" ] || c2000_mwan_owned "$section"
}

c2000_mwan_remove_owned()
{
	local section

	for section in $(uci -q show mwan3 2>/dev/null |
		sed -n 's/^mwan3\.\([^.=]*\)=.*$/\1/p' | sort -u); do
		c2000_mwan_owned "$section" || continue
		uci -q delete "mwan3.${section}" || return 1
	done
	return 0
}

c2000_find_ipv4_default_rule()
{
	local section family dest src dest_port src_port proto
	local src_iface ipset

	for section in $(uci -q show mwan3 2>/dev/null |
		sed -n 's/^mwan3\.\([^.=]*\)=rule$/\1/p'); do
		family="$(uci -q get "mwan3.${section}.family")"
		dest="$(uci -q get "mwan3.${section}.dest_ip")"
		src="$(uci -q get "mwan3.${section}.src_ip")"
		dest_port="$(uci -q get "mwan3.${section}.dest_port")"
		src_port="$(uci -q get "mwan3.${section}.src_port")"
		proto="$(uci -q get "mwan3.${section}.proto")"
		src_iface="$(uci -q get "mwan3.${section}.src_iface")"
		ipset="$(uci -q get "mwan3.${section}.ipset")"
		case "$family" in ''|ipv4) ;; *) continue ;; esac
		case "$dest" in ''|0.0.0.0/0) ;; *) continue ;; esac
		[ -z "$src" ] && [ -z "$dest_port" ] && [ -z "$src_port" ] &&
			[ -z "$src_iface" ] && [ -z "$ipset" ] ||
			continue
		case "$proto" in ''|all) ;; *) continue ;; esac
		printf '%s\n' "$section"
		return 0
	done
	return 1
}

c2000_capture_mwan_rule()
{
	local rule policy members last_resort

	[ "$(uci -q get c2000max.ethernet.mwan_override_active)" = 1 ] &&
		return 0
	rule="$(c2000_find_ipv4_default_rule 2>/dev/null || true)"
	if [ -n "$rule" ]; then
		policy="$(uci -q get "mwan3.${rule}.use_policy")"
		[ -n "$policy" ] || return 1
		[ "$(uci -q get "mwan3.${policy}")" = policy ] || return 1
		members="$(uci -q get "mwan3.${policy}.use_member")"
		last_resort="$(uci -q get "mwan3.${policy}.last_resort")"
		uci -q set c2000max.ethernet.mwan_rule_section="$rule" &&
			uci -q set c2000max.ethernet.mwan_policy_section="$policy" &&
			uci -q set c2000max.ethernet.mwan_saved_members="${members:-__unset__}" &&
			uci -q set c2000max.ethernet.mwan_saved_last_resort="${last_resort:-__unset__}" &&
			uci -q set c2000max.ethernet.mwan_created_rule='0' ||
			return 1
	else
		c2000_mwan_collision_free "$C2000_MWAN_RULE" || return 1
		c2000_mwan_collision_free "$C2000_MWAN_POLICY" || return 1
		uci -q set c2000max.ethernet.mwan_rule_section="$C2000_MWAN_RULE" &&
			uci -q set c2000max.ethernet.mwan_policy_section="$C2000_MWAN_POLICY" &&
			uci -q set c2000max.ethernet.mwan_saved_members='__unset__' &&
			uci -q set c2000max.ethernet.mwan_saved_last_resort='__unset__' &&
			uci -q set c2000max.ethernet.mwan_created_rule='1' ||
			return 1
	fi
	uci -q set c2000max.ethernet.mwan_override_active='1'
}

c2000_restore_mwan_rule()
{
	local rule policy members last_resort created member policy_type restore=0

	[ "$(uci -q get c2000max.ethernet.mwan_override_active)" = 1 ] ||
		return 0
	rule="$(uci -q get c2000max.ethernet.mwan_rule_section)"
	policy="$(uci -q get c2000max.ethernet.mwan_policy_section)"
	members="$(uci -q get c2000max.ethernet.mwan_saved_members)"
	last_resort="$(uci -q get c2000max.ethernet.mwan_saved_last_resort)"
	created="$(uci -q get c2000max.ethernet.mwan_created_rule)"
	if [ "$created" = 1 ]; then
		c2000_mwan_owned "$rule" &&
			uci -q delete "mwan3.${rule}" || true
		c2000_mwan_owned "$policy" &&
			uci -q delete "mwan3.${policy}" || true
	else
		policy_type="$(uci -q get "mwan3.${policy}")"
		if [ -z "$policy_type" ]; then
			# The saved policy disappeared while balanced mode was active.
			# Recreate only the original policy shell so exiting the mode
			# never traps the user in a board-owned configuration.
			uci -q set "mwan3.${policy}=policy" || return 1
			restore=1
		elif [ "$policy_type" = policy ] &&
		     [ "$(uci -q get "mwan3.${policy}.c2000max_policy_override")" = 1 ]; then
			restore=1
		fi
		if [ "$restore" = 1 ]; then
			uci -q delete "mwan3.${policy}.use_member" || true
			if [ "$members" != __unset__ ]; then
				for member in $members; do
					uci -q add_list "mwan3.${policy}.use_member=$member" ||
						return 1
				done
			fi
			if [ "$last_resort" = __unset__ ]; then
				uci -q delete "mwan3.${policy}.last_resort" || true
			else
				uci -q set "mwan3.${policy}.last_resort=$last_resort" ||
					return 1
			fi
		fi
		uci -q delete "mwan3.${policy}.c2000max_policy_override" || true
	fi
	uci -q delete c2000max.ethernet.mwan_override_active || true
	uci -q delete c2000max.ethernet.mwan_rule_section || true
	uci -q delete c2000max.ethernet.mwan_policy_section || true
	uci -q delete c2000max.ethernet.mwan_saved_members || true
	uci -q delete c2000max.ethernet.mwan_saved_last_resort || true
	uci -q delete c2000max.ethernet.mwan_created_rule || true
}

c2000_stage_mwan_balance()
{
	local cell_interface="$1" ethernet_weight="$2" cellular_weight="$3"
	local divisor eth_member_weight cell_member_weight rule policy created section
	local saved_members member member_interface member_family managed_interface

	[ "$cell_interface" != "$C2000_WAN4" ] || {
		C2000_UPLINK_ERROR="5G 接口名与板载 WAN 接口冲突"
		return 1
	}
	c2000_capture_mwan_rule || {
		C2000_UPLINK_ERROR="无法保存现有 mwan3 IPv4 默认策略"
		return 1
	}
	rule="$(uci -q get c2000max.ethernet.mwan_rule_section)"
	policy="$(uci -q get c2000max.ethernet.mwan_policy_section)"
	created="$(uci -q get c2000max.ethernet.mwan_created_rule)"

	for section in "$C2000_WAN4" "$cell_interface" \
		"$C2000_MWAN_ETH_MEMBER" "$C2000_MWAN_CELL_MEMBER"; do
		c2000_mwan_collision_free "$section" || {
			C2000_UPLINK_ERROR="mwan3 节 ${section} 已由用户配置占用"
			return 1
		}
	done
	if [ "$created" = 1 ]; then
		for section in "$C2000_MWAN_POLICY" "$C2000_MWAN_RULE"; do
			c2000_mwan_collision_free "$section" || {
				C2000_UPLINK_ERROR="mwan3 节 ${section} 已由用户配置占用"
				return 1
			}
		done
	fi
	c2000_mwan_remove_owned || return 1

	divisor="$(c2000_gcd "$ethernet_weight" "$cellular_weight")"
	eth_member_weight=$((ethernet_weight / divisor))
	cell_member_weight=$((cellular_weight / divisor))

	for managed_interface in "$C2000_WAN4" "$cell_interface"; do
		uci -q set "mwan3.${managed_interface}=interface" &&
			uci -q set "mwan3.${managed_interface}.enabled=1" &&
			uci -q set "mwan3.${managed_interface}.family=ipv4" &&
			uci -q set "mwan3.${managed_interface}.initial_state=online" &&
			uci -q set "mwan3.${managed_interface}.track_method=ping" &&
			uci -q set "mwan3.${managed_interface}.reliability=1" &&
			uci -q set "mwan3.${managed_interface}.count=1" &&
			uci -q set "mwan3.${managed_interface}.timeout=2" &&
			uci -q set "mwan3.${managed_interface}.interval=5" &&
			uci -q set "mwan3.${managed_interface}.down=3" &&
			uci -q set "mwan3.${managed_interface}.up=3" &&
			uci -q set "mwan3.${managed_interface}.c2000max_managed=1" &&
			uci -q add_list "mwan3.${managed_interface}.track_ip=1.1.1.1" &&
			uci -q add_list "mwan3.${managed_interface}.track_ip=223.5.5.5" ||
			return 1
	done

	uci -q set "mwan3.${C2000_MWAN_ETH_MEMBER}=member" &&
		uci -q set "mwan3.${C2000_MWAN_ETH_MEMBER}.interface=$C2000_WAN4" &&
		uci -q set "mwan3.${C2000_MWAN_ETH_MEMBER}.metric=1" &&
		uci -q set "mwan3.${C2000_MWAN_ETH_MEMBER}.weight=$eth_member_weight" &&
		uci -q set "mwan3.${C2000_MWAN_ETH_MEMBER}.c2000max_managed=1" &&
		uci -q set "mwan3.${C2000_MWAN_CELL_MEMBER}=member" &&
		uci -q set "mwan3.${C2000_MWAN_CELL_MEMBER}.interface=$cell_interface" &&
		uci -q set "mwan3.${C2000_MWAN_CELL_MEMBER}.metric=1" &&
		uci -q set "mwan3.${C2000_MWAN_CELL_MEMBER}.weight=$cell_member_weight" &&
		uci -q set "mwan3.${C2000_MWAN_CELL_MEMBER}.c2000max_managed=1" ||
		return 1

	if [ "$created" = 1 ]; then
		uci -q set "mwan3.${policy}=policy" &&
			uci -q add_list "mwan3.${policy}.use_member=$C2000_MWAN_ETH_MEMBER" &&
			uci -q add_list "mwan3.${policy}.use_member=$C2000_MWAN_CELL_MEMBER" &&
			uci -q set "mwan3.${policy}.last_resort=default" &&
			uci -q set "mwan3.${policy}.c2000max_managed=1" &&
			uci -q set "mwan3.${rule}=rule" &&
			uci -q set "mwan3.${rule}.family=ipv4" &&
			uci -q set "mwan3.${rule}.dest_ip=0.0.0.0/0" &&
			uci -q set "mwan3.${rule}.proto=all" &&
			uci -q set "mwan3.${rule}.use_policy=$policy" &&
			uci -q set "mwan3.${rule}.c2000max_managed=1" ||
			return 1
	else
		saved_members="$(uci -q get c2000max.ethernet.mwan_saved_members)"
		uci -q delete "mwan3.${policy}.use_member" || true
		uci -q add_list "mwan3.${policy}.use_member=$C2000_MWAN_ETH_MEMBER" &&
			uci -q add_list "mwan3.${policy}.use_member=$C2000_MWAN_CELL_MEMBER" ||
			return 1
		if [ "$saved_members" != __unset__ ]; then
			for member in $saved_members; do
				member_interface="$(uci -q get "mwan3.${member}.interface")"
				member_family="$(uci -q get "mwan3.${member_interface}.family")"
				[ "$member_family" = ipv6 ] || continue
				uci -q add_list "mwan3.${policy}.use_member=$member" ||
					return 1
			done
		fi
		uci -q set "mwan3.${policy}.last_resort=default" &&
			uci -q set "mwan3.${policy}.c2000max_policy_override=1" ||
			return 1
	fi
	return 0
}

c2000_capture_qmodem()
{
	local saved

	[ "$(uci -q get c2000max.ethernet.qmodem_override_active)" = 1 ] &&
		return 0
	saved="$(uci -q get qmodem.main.enable_dial)"
	uci -q set c2000max.ethernet.qmodem_saved_enable_dial="${saved:-__unset__}" &&
		uci -q set c2000max.ethernet.qmodem_override_active='1'
}

c2000_stage_qmodem()
{
	local enabled="$1"

	c2000_capture_qmodem || return 1
	[ -n "$(uci -q get qmodem.main)" ] ||
		uci -q set qmodem.main='main' || return 1
	uci -q set "qmodem.main.enable_dial=$enabled"
}

c2000_capture_qmodem_device()
{
	local section="$1" devices saved option

	c2000_valid_uci_name "$section" || return 1
	devices="$(uci -q get c2000max.ethernet.qmodem_overridden_devices)"
	c2000_list_has "$devices" "$section" && return 0
	saved="$(uci -q get "qmodem.${section}.enable_dial")"
	option="qmodem_saved_${section}"
	uci -q set "c2000max.ethernet.${option}=${saved:-__unset__}" &&
		uci -q add_list "c2000max.ethernet.qmodem_overridden_devices=$section"
}

c2000_stage_qmodem_balance()
{
	local selected="$1" section enabled

	c2000_stage_qmodem 1 || return 1
	for section in $(c2000_modem_sections); do
		c2000_valid_uci_name "$section" || return 1
		c2000_capture_qmodem_device "$section" || return 1
		enabled=0
		[ "$section" = "$selected" ] && enabled=1
		uci -q set "qmodem.${section}.enable_dial=$enabled" || return 1
	done
	return 0
}

c2000_restore_qmodem_devices()
{
	local devices section option saved

	devices="$(uci -q get c2000max.ethernet.qmodem_overridden_devices)"
	for section in $devices; do
		c2000_valid_uci_name "$section" || return 1
		option="qmodem_saved_${section}"
		saved="$(uci -q get "c2000max.ethernet.${option}")"
		if [ "$saved" = __unset__ ]; then
			uci -q delete "qmodem.${section}.enable_dial" || true
		else
			if [ "$(uci -q get "qmodem.${section}")" = modem-device ]; then
				uci -q set "qmodem.${section}.enable_dial=$saved" ||
					return 1
			fi
		fi
		uci -q delete "c2000max.ethernet.${option}" || true
	done
	uci -q delete c2000max.ethernet.qmodem_overridden_devices || true
	return 0
}

c2000_restore_qmodem()
{
	local saved

	[ "$(uci -q get c2000max.ethernet.qmodem_override_active)" = 1 ] ||
		return 0
	c2000_restore_qmodem_devices || return 1
	saved="$(uci -q get c2000max.ethernet.qmodem_saved_enable_dial)"
	if [ "$saved" = __unset__ ]; then
		uci -q delete qmodem.main.enable_dial || true
	else
		uci -q set "qmodem.main.enable_dial=$saved" || return 1
	fi
	uci -q delete c2000max.ethernet.qmodem_override_active || true
	uci -q delete c2000max.ethernet.qmodem_saved_enable_dial || true
}

c2000_stage_uplink_mode()
{
	local role="$1" mode="$2" ethernet_weight="$3" cellular_weight="$4"
	local requested_modem="$5" frozen_modem="${6:-}"
	local selected modem interface select_rc

	C2000_UPLINK_ERROR=""
	case "$role" in
		lan)
			c2000_mwan_remove_owned &&
				c2000_restore_mwan_rule &&
				c2000_restore_qmodem || return 1
			uci -q delete c2000max.ethernet.resolved_cellular_modem || true
			uci -q delete c2000max.ethernet.cellular_interface || true
			return
			;;
		wan) ;;
		*) return 1 ;;
	esac

	c2000_wan_settings_valid "$mode" "$ethernet_weight" \
		"$cellular_weight" "$requested_modem" || {
		C2000_UPLINK_ERROR="WAN 模式或分流比例无效"
		return 1
	}
	case "$mode" in
		"$C2000_WAN_MODE_ONLY")
			c2000_stage_qmodem 0 &&
				c2000_restore_qmodem_devices &&
				c2000_mwan_remove_owned &&
				c2000_restore_mwan_rule &&
				uci -q set c2000max.ethernet.cellular_modem="$requested_modem" ||
				return 1
			uci -q delete c2000max.ethernet.resolved_cellular_modem || true
			uci -q delete c2000max.ethernet.cellular_interface || true
			;;
		"$C2000_WAN_MODE_BALANCE")
			if [ -n "$frozen_modem" ]; then
				[ "$(uci -q get "qmodem.${frozen_modem}")" = modem-device ] &&
					c2000_modem_enabled "$frozen_modem" || {
					C2000_UPLINK_ERROR="预选的 QModem 5G 模块已不可用"
					return 1
				}
				interface="$(c2000_modem_interface "$frozen_modem")" ||
					return 1
				selected="${frozen_modem}|${interface}"
				select_rc=0
			else
				selected="$(c2000_select_modem "$requested_modem")"
				select_rc=$?
			fi
			if [ "$select_rc" -ne 0 ]; then
				if [ "$select_rc" -eq 2 ]; then
					C2000_UPLINK_ERROR="检测到多个可用 5G 模块，请明确选择模块"
				else
					C2000_UPLINK_ERROR="没有找到可拨号的 QModem 5G 模块"
				fi
				return 1
			fi
			modem="${selected%%|*}"
			interface="${selected#*|}"
			c2000_cell_interface_safe "$modem" "$interface" || {
				C2000_UPLINK_ERROR="所选 5G 接口名与受管网络命名空间冲突"
				return 1
			}
			c2000_stage_qmodem_balance "$modem" &&
				c2000_stage_mwan_balance "$interface" \
					"$ethernet_weight" "$cellular_weight" &&
				uci -q set c2000max.ethernet.resolved_cellular_modem="$modem" &&
				uci -q set c2000max.ethernet.cellular_interface="$interface"
			;;
	esac
}

c2000_uplink_config_matches()
{
	local role="$1" mode="$2" ethernet_weight="$3" cellular_weight="$4"
	local requested_modem="${5:-auto}" modem interface divisor
	local policy created members rule section expected actual

	if [ "$role" = lan ]; then
		[ "$(uci -q get c2000max.ethernet.qmodem_override_active)" != 1 ] &&
			[ "$(uci -q get c2000max.ethernet.mwan_override_active)" != 1 ] &&
			! uci -q show mwan3 2>/dev/null |
				grep -Eq "\\.(c2000max_managed|c2000max_policy_override)='1'$"
		return
	fi
	[ "$role" = wan ] || return 1
	[ "$(uci -q get c2000max.ethernet.wan_mode)" = "$mode" ] &&
		[ "$(uci -q get c2000max.ethernet.ethernet_weight)" = "$ethernet_weight" ] &&
		[ "$(uci -q get c2000max.ethernet.cellular_weight)" = "$cellular_weight" ] ||
		return 1
	[ "$(uci -q get c2000max.ethernet.cellular_modem)" = "$requested_modem" ] ||
		return 1
	case "$mode" in
		"$C2000_WAN_MODE_ONLY")
			[ "$(uci -q get qmodem.main.enable_dial)" = 0 ] &&
				[ "$(uci -q get c2000max.ethernet.qmodem_override_active)" = 1 ] &&
				[ -z "$(uci -q get c2000max.ethernet.qmodem_overridden_devices)" ] &&
				[ "$(uci -q get c2000max.ethernet.mwan_override_active)" != 1 ] &&
				! uci -q show mwan3 2>/dev/null |
					grep -Eq "\\.(c2000max_managed|c2000max_policy_override)='1'$"
			;;
		"$C2000_WAN_MODE_BALANCE")
			modem="$(uci -q get c2000max.ethernet.resolved_cellular_modem)"
			interface="$(uci -q get c2000max.ethernet.cellular_interface)"
			policy="$(uci -q get c2000max.ethernet.mwan_policy_section)"
			created="$(uci -q get c2000max.ethernet.mwan_created_rule)"
			rule="$(uci -q get c2000max.ethernet.mwan_rule_section)"
			[ -n "$modem" ] && [ -n "$interface" ] &&
				{ [ "$requested_modem" = auto ] ||
					[ "$modem" = "$requested_modem" ]; } &&
				[ "$(c2000_modem_interface "$modem" 2>/dev/null)" = "$interface" ] &&
				c2000_cell_interface_safe "$modem" "$interface" &&
				[ "$(uci -q get qmodem.main.enable_dial)" = 1 ] &&
				[ "$(uci -q get "qmodem.${modem}.enable_dial")" = 1 ] &&
				[ "$(uci -q get c2000max.ethernet.mwan_override_active)" = 1 ] &&
				[ "$(uci -q get c2000max.ethernet.qmodem_override_active)" = 1 ] &&
				[ "$(uci -q get "mwan3.${interface}")" = interface ] &&
				[ "$(uci -q get "mwan3.${interface}.c2000max_managed")" = 1 ] &&
				[ "$(uci -q get "mwan3.${interface}.enabled")" = 1 ] &&
				[ "$(uci -q get "mwan3.${interface}.family")" = ipv4 ] &&
				[ "$(uci -q get "mwan3.${C2000_WAN4}")" = interface ] &&
				[ "$(uci -q get "mwan3.${C2000_WAN4}.c2000max_managed")" = 1 ] ||
				return 1
			for section in $(c2000_modem_sections); do
				actual="$(uci -q get "qmodem.${section}.enable_dial")"
				expected=0
				[ "$section" = "$modem" ] && expected=1
				[ "$actual" = "$expected" ] || return 1
			done
			[ "$(uci -q get "mwan3.${C2000_MWAN_ETH_MEMBER}")" = member ] &&
				[ "$(uci -q get "mwan3.${C2000_MWAN_ETH_MEMBER}.interface")" = "$C2000_WAN4" ] &&
				[ "$(uci -q get "mwan3.${C2000_MWAN_ETH_MEMBER}.metric")" = 1 ] &&
				[ "$(uci -q get "mwan3.${C2000_MWAN_ETH_MEMBER}.c2000max_managed")" = 1 ] &&
				[ "$(uci -q get "mwan3.${C2000_MWAN_CELL_MEMBER}")" = member ] &&
				[ "$(uci -q get "mwan3.${C2000_MWAN_CELL_MEMBER}.interface")" = "$interface" ] &&
				[ "$(uci -q get "mwan3.${C2000_MWAN_CELL_MEMBER}.metric")" = 1 ] &&
				[ "$(uci -q get "mwan3.${C2000_MWAN_CELL_MEMBER}.c2000max_managed")" = 1 ] ||
				return 1
			if [ "$created" = 1 ]; then
				[ "$(uci -q get "mwan3.${policy}.c2000max_managed")" = 1 ] ||
					return 1
				[ "$(uci -q get "mwan3.${rule}")" = rule ] &&
					[ "$(uci -q get "mwan3.${rule}.family")" = ipv4 ] &&
					[ "$(uci -q get "mwan3.${rule}.dest_ip")" = 0.0.0.0/0 ] &&
					[ "$(uci -q get "mwan3.${rule}.use_policy")" = "$policy" ] &&
					[ "$(uci -q get "mwan3.${rule}.c2000max_managed")" = 1 ] ||
					return 1
			else
				[ "$(uci -q get "mwan3.${policy}.c2000max_policy_override")" = 1 ] ||
					return 1
				[ "$(uci -q get "mwan3.${rule}")" = rule ] &&
					[ "$(uci -q get "mwan3.${rule}.use_policy")" = "$policy" ] ||
					return 1
			fi
			[ "$(uci -q get "mwan3.${policy}")" = policy ] || return 1
			members="$(uci -q get "mwan3.${policy}.use_member")"
			c2000_list_has "$members" "$C2000_MWAN_ETH_MEMBER" &&
				c2000_list_has "$members" "$C2000_MWAN_CELL_MEMBER" ||
				return 1
			divisor="$(c2000_gcd "$ethernet_weight" "$cellular_weight")"
			[ "$(uci -q get "mwan3.${C2000_MWAN_ETH_MEMBER}.weight")" = \
				$((ethernet_weight / divisor)) ] &&
				[ "$(uci -q get "mwan3.${C2000_MWAN_CELL_MEMBER}.weight")" = \
					$((cellular_weight / divisor)) ]
			;;
		*) return 1 ;;
	esac
}
