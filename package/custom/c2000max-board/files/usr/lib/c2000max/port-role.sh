#!/bin/sh

C2000_PORT_DEVICE="${C2000_PORT_DEVICE:-eth1}"
C2000_PPE_DEVICE="${C2000_PPE_DEVICE:-eth0}"
C2000_RX_PPD_DEVICE="${C2000_RX_PPD_DEVICE:-rxppd}"
C2000_WAN4="${C2000_WAN4:-c2000_wan}"
C2000_WAN6="${C2000_WAN6:-c2000_wan6}"
C2000_SWITCHING="${C2000_SWITCHING:-/var/run/c2000max-port-role.switching}"
C2000_DEGRADED="${C2000_DEGRADED:-/var/run/c2000max-port-role.degraded}"
C2000_SYS_CLASS_NET="${C2000_SYS_CLASS_NET:-/sys/class/net}"
C2000_HNAT_DIR="${C2000_HNAT_DIR:-/sys/kernel/debug/hnat}"
C2000_HNAT_TOPOLOGY="${C2000_HNAT_TOPOLOGY:-$C2000_HNAT_DIR/hnat_topology}"

c2000_list_has()
{
	case " $1 " in
		*" $2 "*) return 0 ;;
	esac
	return 1
}

c2000_find_lan_bridge()
{
	local section

	for section in $(uci -q show network |
		sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
		[ "$(uci -q get "network.${section}.type")" = "bridge" ] || continue
		[ "$(uci -q get "network.${section}.name")" = "br-lan" ] || continue
		printf '%s\n' "$section"
		return 0
	done
	return 1
}

c2000_port_in_lan()
{
	local bridge

	bridge="$(c2000_find_lan_bridge)" || return 1
	c2000_list_has "$(uci -q get "network.${bridge}.ports")" "$C2000_PORT_DEVICE"
}

c2000_managed_wan_complete()
{
	[ "$(uci -q get "network.${C2000_WAN4}")" = "interface" ] &&
		[ "$(uci -q get "network.${C2000_WAN4}.device")" = "$C2000_PORT_DEVICE" ] &&
		[ "$(uci -q get "network.${C2000_WAN4}.proto")" = "dhcp" ] &&
		[ "$(uci -q get "network.${C2000_WAN4}.c2000max_managed")" = "1" ] &&
		[ "$(uci -q get "network.${C2000_WAN6}")" = "interface" ] &&
		[ "$(uci -q get "network.${C2000_WAN6}.device")" = "@${C2000_WAN4}" ] &&
		[ "$(uci -q get "network.${C2000_WAN6}.proto")" = "dhcpv6" ] &&
		[ "$(uci -q get "network.${C2000_WAN6}.c2000max_managed")" = "1" ]
}

c2000_managed_wan_absent()
{
	[ -z "$(uci -q get "network.${C2000_WAN4}")" ] &&
		[ -z "$(uci -q get "network.${C2000_WAN6}")" ]
}

c2000_token_refs_port()
{
	case "$1" in
		"$C2000_PORT_DEVICE"|"$C2000_PORT_DEVICE".*|"$C2000_PORT_DEVICE":*)
			return 0
			;;
	esac
	return 1
}

c2000_token_refs_device()
{
	local device="$1" token="$2"

	case "$token" in
		"$device"|"$device".*|"$device":*)
			return 0
			;;
	esac
	return 1
}

c2000_network_refs_device()
{
	local device="$1" section option value token

	for section in $(uci -q show network |
		sed -n 's/^network\.\([^.=]*\)=[^=]*$/\1/p'); do
		for option in device ifname ports name; do
			value="$(uci -q get "network.${section}.${option}")"
			for token in $value; do
				c2000_token_refs_device "$device" "$token" && return 0
			done
		done
	done
	return 1
}

c2000_ppe_device_unused()
{
	! c2000_network_refs_device "$C2000_PPE_DEVICE"
}

c2000_no_foreign_port_refs()
{
	local role="$1" lan_bridge section section_type option value token allowed

	lan_bridge="$(c2000_find_lan_bridge 2>/dev/null)"
	for section in $(uci -q show network |
		sed -n 's/^network\.\([^.=]*\)=[^=]*$/\1/p'); do
		section_type="$(uci -q get "network.${section}")"
		for option in device ifname ports name; do
			value="$(uci -q get "network.${section}.${option}")"
			for token in $value; do
				c2000_token_refs_port "$token" || continue
				allowed=0
				if [ "$role" = lan ] &&
				   [ "$section_type" = device ] &&
				   [ "$section" = "$lan_bridge" ] &&
				   [ "$option" = ports ] &&
				   [ "$token" = "$C2000_PORT_DEVICE" ]; then
					allowed=1
				elif [ "$role" = wan ] &&
				     [ "$section_type" = interface ] &&
				     [ "$section" = "$C2000_WAN4" ] &&
				     [ "$option" = device ] &&
				     [ "$token" = "$C2000_PORT_DEVICE" ]; then
					allowed=1
				fi
				[ "$allowed" = 1 ] || return 1
			done
		done
	done
	return 0
}

c2000_actual_role()
{
	local lan=0 wan=0 absent=0

	c2000_port_in_lan && lan=1
	c2000_managed_wan_complete && wan=1
	c2000_managed_wan_absent && absent=1

	if [ "$lan" = 1 ] && [ "$wan" = 0 ] && [ "$absent" = 1 ] &&
	   c2000_no_foreign_port_refs lan; then
		printf '%s\n' lan
	elif [ "$lan" = 0 ] && [ "$wan" = 1 ] &&
	     c2000_no_foreign_port_refs wan; then
		printf '%s\n' wan
	else
		printf '%s\n' inconsistent
	fi
}

c2000_effective_fastpath()
{
	local role="$1" requested="${2:-disabled}"

	case "$role" in
		lan)
			# Only the LAN topology has a verified C2000-MAX HNAT data path.
			# Keep the user's TurboACC preference intact so returning from WAN
			# to LAN can restore HNAT without rewriting that preference.
			case "$requested" in
				mediatek_hnat) printf '%s\n' mediatek_hnat ;;
				flow_offloading) printf '%s\n' flow_offloading ;;
				disabled|*) printf '%s\n' disabled ;;
			esac
			;;
		wan)
			# Never attempt the experimental WAN PPE endpoint mapping. A saved
			# MediaTek HNAT preference falls back to the generic nft software
			# flowtable, while an explicit Disable selection stays disabled.
			# Hardware flow offload remains disabled independently.
			case "$requested" in
				mediatek_hnat|flow_offloading)
					printf '%s\n' flow_offloading
					;;
				disabled|*) printf '%s\n' disabled ;;
			esac
			;;
		*)
			printf '%s\n' disabled
			;;
	esac
}

c2000_netdev_master()
{
	local device="$1"

	[ -L "$C2000_SYS_CLASS_NET/$device/master" ] || return 1
	basename "$(readlink -f "$C2000_SYS_CLASS_NET/$device/master")"
}

c2000_netdev_is_up()
{
	local device="$1" flags

	flags="$(cat "$C2000_SYS_CLASS_NET/$device/flags" 2>/dev/null)"
	case "$flags" in
		0x*) [ $((flags & 1)) -ne 0 ] 2>/dev/null ;;
		*) return 1 ;;
	esac
}

c2000_is_mtk_gmac()
{
	local device="$1" compatible

	[ -d "$C2000_SYS_CLASS_NET/$device" ] || return 1
	for compatible in \
		"$C2000_SYS_CLASS_NET/$device/of_node/compatible" \
		"$C2000_SYS_CLASS_NET/$device/device/of_node/compatible"; do
		[ -r "$compatible" ] || continue
		grep -aFq 'mediatek,eth-mac' "$compatible" && return 0
	done
	return 1
}

c2000_ppe_runtime_unowned()
{
	local master

	[ -d "$C2000_SYS_CLASS_NET/$C2000_PPE_DEVICE" ] || return 1
	master="$(c2000_netdev_master "$C2000_PPE_DEVICE" 2>/dev/null || true)"
	[ -z "$master" ]
}

c2000_runtime_wifi_member()
{
	local device="$1" state

	[ -e "$C2000_SYS_CLASS_NET/br-lan/brif/$device" ] || return 1
	case "$device" in
		ra*|rax*|wlan*|phy*-ap*|ap*) ;;
		*) [ -d "$C2000_SYS_CLASS_NET/$device/wireless" ] || return 1 ;;
	esac
	c2000_netdev_is_up "$device" || return 1
	state="$(cat "$C2000_SYS_CLASS_NET/$device/operstate" 2>/dev/null)"
	case "$state" in
		up|unknown) return 0 ;;
	esac
	return 1
}

c2000_runtime_wifi_members()
{
	local path device

	for path in "$C2000_SYS_CLASS_NET/br-lan/brif/"*; do
		[ -e "$path" ] || continue
		device="${path##*/}"
		c2000_runtime_wifi_member "$device" || continue
		printf '%s\n' "$device"
	done
}

c2000_has_runtime_wifi_member()
{
	[ -n "$(c2000_runtime_wifi_members)" ]
}

c2000_whnat_has_device()
{
	local wanted="$1" index device

	[ -n "$wanted" ] || return 1
	[ -r "$C2000_HNAT_DIR/whnat_interface" ] || return 1
	while IFS=: read -r index device; do
		case "$index" in
			''|*[!0-9]*) continue ;;
		esac
		[ "$device" = "$wanted" ] && return 0
	done < "$C2000_HNAT_DIR/whnat_interface"
	return 1
}

c2000_whnat_ready()
{
	local device found=0

	[ -r "$C2000_HNAT_DIR/whnat_interface" ] || return 1
	for device in $(c2000_runtime_wifi_members); do
		found=1
		c2000_whnat_has_device "$device" || return 1
	done
	[ "$found" = 1 ]
}

c2000_register_whnat_member()
{
	local device="$1"

	[ -n "$device" ] || return 1
	[ -e "$C2000_HNAT_DIR/whnat_interface" ] || return 1
	# The vendor ABI accepts "<netdev> 1" even though older kernels expose the
	# debugfs node with mode 0444. The controller runs as root and the driver
	# validates the netdev before publishing it in wifi_hook_if[].
	printf '%s 1\n' "$device" > "$C2000_HNAT_DIR/whnat_interface"
}

c2000_sync_whnat()
{
	local device found=0 failed=0

	for device in $(c2000_runtime_wifi_members); do
		found=1
		c2000_whnat_has_device "$device" && continue
		c2000_register_whnat_member "$device" || failed=1
	done
	[ "$found" = 1 ] || return 2
	[ "$failed" = 0 ] || return 1
	c2000_whnat_ready
}

c2000_rxppd_ready()
{
	local master

	[ -d "$C2000_SYS_CLASS_NET/$C2000_RX_PPD_DEVICE" ] || return 1
	c2000_netdev_is_up "$C2000_RX_PPD_DEVICE" || return 1
	master="$(c2000_netdev_master "$C2000_RX_PPD_DEVICE" 2>/dev/null || true)"
	[ "$master" = br-lan ]
}

c2000_expected_hnat_endpoint()
{
	local role="$1" endpoint="$2"

	case "$role:$endpoint" in
		lan:wan|lan:lan2)
			printf '%s\n' /
			;;
		lan:lan|lan:ppd)
			printf '%s\n' "$C2000_PORT_DEVICE"
			;;
		wan:wan)
			printf '%s\n' "$C2000_PORT_DEVICE"
			;;
		wan:lan)
			printf '%s\n' br-lan
			;;
		wan:ppd)
			printf '%s\n' "$C2000_PPE_DEVICE"
			;;
		wan:lan2)
			printf '%s\n' /
			;;
		*)
			return 1
			;;
	esac
}

c2000_expected_hnat_topology()
{
	local role="$1" wan lan lan2 ppd

	wan="$(c2000_expected_hnat_endpoint "$role" wan)" || return 1
	lan="$(c2000_expected_hnat_endpoint "$role" lan)" || return 1
	lan2="$(c2000_expected_hnat_endpoint "$role" lan2)" || return 1
	ppd="$(c2000_expected_hnat_endpoint "$role" ppd)" || return 1
	printf 'wan=%s lan=%s lan2=%s ppd=%s\n' "$wan" "$lan" "$lan2" "$ppd"
}

c2000_hnat_topology_read()
{
	local topology extra

	[ -r "$C2000_HNAT_TOPOLOGY" ] || return 1
	{
		# The atomic ABI guarantees exactly one canonical, newline-terminated
		# line. Reject truncated or multi-line readback rather than parsing a
		# potentially staged/legacy representation.
		IFS= read -r topology || return 1
		if IFS= read -r extra; then
			return 1
		fi
	} < "$C2000_HNAT_TOPOLOGY"
	printf '%s\n' "$topology"
}

c2000_hnat_endpoint_value()
{
	local endpoint="$1" topology field key

	case "$endpoint" in
		wan|lan|lan2|ppd) ;;
		*) return 1 ;;
	esac
	key="${endpoint}="
	topology="$(c2000_hnat_topology_read)" || return 1
	for field in $topology; do
		case "$field" in
			"$key"*)
				printf '%s\n' "${field#"$key"}"
				return 0
				;;
		esac
	done
	return 1
}

c2000_hnat_endpoints_match()
{
	local role="$1" expected actual

	# hnat_topology is the only writable ABI. The four legacy endpoint nodes
	# are deliberately never used as a partial-write fallback.
	[ -r "$C2000_HNAT_TOPOLOGY" ] &&
		[ -w "$C2000_HNAT_TOPOLOGY" ] || return 1
	expected="$(c2000_expected_hnat_topology "$role")" || return 1
	actual="$(c2000_hnat_topology_read)" || return 1
	[ "$actual" = "$expected" ] || return 1

	# The legacy PPD node remains read-only and is useful solely to verify the
	# resolved kernel references, including the static RX reinjection device.
	grep -qx "g_ppdev=$(c2000_expected_hnat_endpoint "$role" ppd)" \
		"$C2000_HNAT_DIR/hnat_ppd_if" || return 1
	grep -qx "g_rx_ppdev=$C2000_RX_PPD_DEVICE" \
		"$C2000_HNAT_DIR/hnat_ppd_if" || return 1
	return 0
}

c2000_hnat_hook_enabled()
{
	[ -r "$C2000_HNAT_DIR/hook_toggle" ] &&
		[ "$(cat "$C2000_HNAT_DIR/hook_toggle" 2>/dev/null)" = enabled ]
}

c2000_hard_hnat_runtime_ready()
{
	local role="$1"

	case "$role" in lan|wan) ;; *) return 1 ;; esac
	c2000_is_mtk_gmac "$C2000_PORT_DEVICE" &&
		c2000_is_mtk_gmac "$C2000_PPE_DEVICE" &&
		c2000_ppe_device_unused &&
		c2000_ppe_runtime_unowned &&
		c2000_rxppd_ready &&
		c2000_hnat_endpoints_match "$role" &&
		c2000_hnat_hook_enabled
}

c2000_hard_hnat_ready()
{
	# Network recovery markers must never prevent a valid, fully verified
	# hardware topology from converging.  The runtime checks below are the
	# authority; stale user-space markers are not.
	c2000_hard_hnat_runtime_ready "$1"
}

c2000_hnat_allowed()
{
	local role

	role="$(c2000_actual_role)"
	c2000_hard_hnat_ready "$role"
}
