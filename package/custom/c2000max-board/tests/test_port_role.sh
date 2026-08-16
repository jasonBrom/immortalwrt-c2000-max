#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
COMMON="$ROOT/files/usr/lib/c2000max/port-role.sh"
UPLINK="$ROOT/files/usr/lib/c2000max/uplink-mode.sh"
SCRIPT="$ROOT/files/usr/sbin/c2000max-port-role"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

declare -A DB HELD
FAIL_MATCH=""
QMODEM_RUNNING=1
QMODEM_ENABLED=1
MWAN_RUNNING=0
MWAN_ENABLED=0

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

uci()
{
	[[ "${1-}" == -q ]] && shift
	local op="${1-}" arg="${2-}" key value cfg prefix rebuilt item
	[[ "$op:$arg" != "$FAIL_MATCH" ]] || return 1
	case "$op" in
		get)
			[[ -v "DB[$arg]" ]] || return 1
			printf '%s\n' "${DB[$arg]}"
			;;
		show)
			cfg="$arg"
			for key in "${!DB[@]}"; do
				[[ "$key" == "$cfg."* ]] || continue
				if [[ "$key" == *.*.* ]]; then
					printf "%s='%s'\n" "$key" "${DB[$key]}"
				else
					printf '%s=%s\n' "$key" "${DB[$key]}"
				fi
			done | sort
			;;
		set)
			key="${arg%%=*}"
			value="${arg#*=}"
			DB["$key"]="$value"
			;;
		add_list)
			key="${arg%%=*}"
			value="${arg#*=}"
			case " ${DB[$key]-} " in
				*" $value "*) ;;
				*) DB["$key"]="${DB[$key]-}${DB[$key]:+ }$value" ;;
			esac
			;;
		del_list)
			key="${arg%%=*}"
			value="${arg#*=}"
			rebuilt=""
			for item in ${DB[$key]-}; do
				[[ "$item" == "$value" ]] || rebuilt="${rebuilt}${rebuilt:+ }$item"
			done
			DB["$key"]="$rebuilt"
			;;
		delete)
			prefix="$arg"
			unset 'DB['"$prefix"']'
			for key in "${!DB[@]}"; do
				[[ "$key" == "$prefix."* ]] && unset 'DB['"$key"']'
			done
			return 0
			;;
		commit|revert)
			;;
		export)
			printf 'package=%s\n' "$arg"
			;;
		import)
			cat >/dev/null
			;;
		*)
			return 1
			;;
	esac
}

config_load() { return 0; }
config_foreach()
{
	local callback="$1" type="$2"
	[[ "$type" == wifi-iface ]] && "$callback" vif0
}
config_get()
{
	local out="$1" section="$2" option="$3" default="${4-}"
	printf -v "$out" '%s' "${DB[wireless.$section.$option]-$default}"
}
config_get_bool() { config_get "$@"; }
ubus() { return 0; }
logger() { return 0; }
jsonfilter() { return 0; }
board_name() { echo nradio,c2000-max; }

export C2000_SWITCHING="$TMP/switching"
export C2000_DEGRADED="$TMP/degraded"
export C2000_JOB_DIR="$TMP/jobs"
export C2000_ROLE_LOCK="$TMP/role.lock"
export C2000_QUEUE_LOCK="$TMP/queue.lock"
export C2000_HNAT_LOCK="$TMP/hnat.lock"
export C2000_HNAT_DIR="$TMP/hnat"
export C2000_HNAT_HOOK="$C2000_HNAT_DIR/hook_toggle"
export C2000_HNAT_TOPOLOGY="$C2000_HNAT_DIR/hnat_topology"
export C2000_HNAT_EFFECTIVE="$TMP/hnat-effective"
export C2000_WHNAT_EFFECTIVE="$TMP/whnat-effective"
export C2000_HNAT_SETTINGS_EFFECTIVE="$TMP/hnat-settings-effective"
export C2000_ACCEL_DEGRADED="$TMP/hnat-degraded"
export C2000_SYS_CLASS_NET="$TMP/sys/class/net"
export C2000_PPE_DEVICE=eth0
export C2000_RX_PPD_DEVICE=rxppd
export C2000_ROLE_LIB="$COMMON"

mkdir -p "$C2000_HNAT_DIR" "$C2000_SYS_CLASS_NET"

source "$COMMON"
source "$UPLINK"
source <(awk '/^PORT_DEVICE=/{emit=1} /^\[ "\$\(board_name\)"/{exit} emit{print}' "$SCRIPT")

reset_lan()
{
	DB=(
		[network.lan]=interface
		[network.lan.device]=br-lan
		[network.br_lan]=device
		[network.br_lan.type]=bridge
		[network.br_lan.name]=br-lan
		[network.br_lan.ports]=eth1
		[firewall.wan]=zone
		[firewall.wan.name]=wan
		[firewall.wan.network]='wan wan6 qmodem qmodemv6 c2000_wan c2000_wan6'
		[firewall.wan.input]=REJECT
		[firewall.wan.output]=ACCEPT
		[firewall.wan.forward]=REJECT
		[firewall.wan.masq]=1
		["firewall.@defaults[0]"]=defaults
		["firewall.@defaults[0].flow_offloading"]=0
		["firewall.@defaults[0].flow_offloading_hw"]=0
		[c2000max.ethernet]=ethernet
		[c2000max.ethernet.role]=lan
		[c2000max.ethernet.wan_metric]=5
		[c2000max.ethernet.wan_mode]=ethernet_only
		[c2000max.ethernet.ethernet_weight]=60
		[c2000max.ethernet.cellular_weight]=40
		[c2000max.ethernet.cellular_modem]=auto
		[turboacc.config.fastpath]=mediatek_hnat
		[turboacc.config.fastpath_mh_bind_rate]=30
		[turboacc.config.fastpath_mh_update_nfct]=0
		[eqos.config.enabled]=0
		[qmodem.main]=main
		[qmodem.main.enable_dial]=1
		[mwan3.globals]=globals
		[wireless.radio0.disabled]=0
		[wireless.vif0.mode]=ap
		[wireless.vif0.network]=lan
		[wireless.vif0.device]=radio0
		[wireless.vif0.disabled]=0
	)
	FAIL_MATCH=""
	QMODEM_RUNNING=1
	QMODEM_ENABLED=1
	MWAN_RUNNING=0
	MWAN_ENABLED=0
	rm -f "$SWITCHING" "$DEGRADED" "$ACCEL_DEGRADED"
}

reset_lan
[[ "$(c2000_actual_role)" == lan ]] || fail "LAN topology not detected"
missing_flock_output="$(
	(
		flock_available() { return 1; }
		error_json() {
			printf '{"success":false,"message":"%s"}\n' "$1"
		}
		queue_role lan ethernet_only 60 40 auto
	) 2>/dev/null || true
)"
grep -Fq '"success":false' <<<"$missing_flock_output" &&
	grep -Fq '系统缺少 flock' <<<"$missing_flock_output" ||
	fail "missing flock did not return a precise JSON task-creation error"
grep -Fq '+flock' "$ROOT/Makefile" ||
	fail "board package does not install the flock runtime dependency"
DB[c2000max.ethernet.role]=wan
[[ "$(c2000_actual_role)" == lan ]] || fail "stale marker overrode topology"
[[ "$(c2000_effective_fastpath lan disabled)" == disabled ]] ||
	fail "LAN role did not preserve the user's disabled acceleration choice"
[[ "$(c2000_effective_fastpath lan mediatek_hnat)" == mediatek_hnat ]] ||
	fail "LAN role did not preserve the user's MediaTek HNAT choice"
[[ "$(c2000_effective_fastpath wan disabled)" == disabled ]] ||
	fail "WAN role did not preserve the user's disabled acceleration choice"
[[ "$(c2000_effective_fastpath wan mediatek_hnat)" == flow_offloading ]] ||
	fail "WAN role did not replace MediaTek HNAT with software flow offload"
[[ "$(c2000_effective_fastpath lan flow_offloading)" == flow_offloading ]] ||
	fail "LAN role did not preserve software flow offload"
[[ "$(c2000_effective_fastpath wan flow_offloading)" == flow_offloading ]] ||
	fail "WAN role did not preserve software flow offload"
[[ "$(c2000_effective_fastpath inconsistent mediatek_hnat)" == disabled ]] ||
	fail "inconsistent topology did not fail closed"

reset_lan
DB[turboacc.config.fastpath]=disabled
stage_acceleration_policy lan ||
	fail "disabled acceleration policy could not be staged"
[[ "${DB[turboacc.config.fastpath]}" == disabled ]] ||
	fail "role staging promoted disabled acceleration to HNAT"
[[ "${DB[firewall.@defaults[0].flow_offloading]}" == 0 &&
   "${DB[firewall.@defaults[0].flow_offloading_hw]}" == 0 ]] ||
	fail "disabled acceleration staging left a generic flowtable enabled"

reset_lan
stage_acceleration_policy lan ||
	fail "MediaTek HNAT acceleration policy could not be staged"
[[ "${DB[turboacc.config.fastpath]}" == mediatek_hnat ]] ||
	fail "role staging did not preserve MediaTek HNAT"
[[ "${DB[firewall.@defaults[0].flow_offloading]}" == 0 &&
   "${DB[firewall.@defaults[0].flow_offloading_hw]}" == 0 ]] ||
	fail "LAN HNAT staging left a generic flowtable enabled"

reset_lan
DB[turboacc.config.fastpath]=flow_offloading
stage_acceleration_policy lan ||
	fail "software flow-offload policy could not be staged"
[[ "${DB[turboacc.config.fastpath]}" == flow_offloading ]] ||
	fail "software flow-offload preference was not preserved"
[[ "${DB[firewall.@defaults[0].flow_offloading]}" == 1 &&
   "${DB[firewall.@defaults[0].flow_offloading_hw]}" == 0 ]] ||
	fail "software flow-offload staging enabled the wrong firewall mode"

reset_lan
stage_wan || fail "WAN policy fixture could not be staged"
stage_acceleration_policy wan ||
	fail "WAN HNAT fallback policy could not be staged"
[[ "${DB[turboacc.config.fastpath]}" == mediatek_hnat ]] ||
	fail "WAN fallback overwrote the saved LAN HNAT preference"
[[ "${DB[firewall.@defaults[0].flow_offloading]}" == 1 &&
   "${DB[firewall.@defaults[0].flow_offloading_hw]}" == 0 ]] ||
	fail "WAN fallback did not select software-only flow offload"

reset_lan
DB[qmodem.main.enable_dial]=0
stage_repair_dial_intent ||
	fail "repair dial-intent staging rejected a configuration with no modem devices"
[[ "${DB[qmodem.main.enable_dial]}" == 1 ]] ||
	fail "repair without modem devices did not restore the global dial intent"
[[ -z "$(c2000_modem_sections)" ]] ||
	fail "repair without modem devices synthesized an unexpected device section"

reset_lan
DB[qmodem.main.enable_dial]=0
DB[qmodem.modem1]=modem-device
DB[qmodem.modem1.enable_dial]=0
stage_repair_dial_intent ||
	fail "repair dial-intent staging rejected one explicitly disabled modem"
[[ "${DB[qmodem.main.enable_dial]}" == 1 &&
   "${DB[qmodem.modem1.enable_dial]}" == 1 ]] ||
	fail "repair did not make the only non-disabled modem dialable"

reset_lan
DB[qmodem.main.enable_dial]=0
DB[qmodem.modem1]=modem-device
DB[qmodem.modem1.enable_dial]=0
DB[qmodem.modem2]=modem-device
DB[qmodem.modem2.enable_dial]=0
DB[qmodem.modem3]=modem-device
DB[qmodem.modem3.state]=disabled
DB[qmodem.modem3.enable_dial]=0
stage_repair_dial_intent ||
	fail "repair dial-intent staging rejected multiple all-zero modems"
[[ "${DB[qmodem.main.enable_dial]}" == 1 &&
   "${DB[qmodem.modem1.enable_dial]}" == 1 &&
   "${DB[qmodem.modem2.enable_dial]}" == 1 ]] ||
	fail "repair did not enable every non-disabled modem when all were explicit zero"
[[ "${DB[qmodem.modem3.enable_dial]}" == 0 ]] ||
	fail "repair enabled a modem whose state is disabled"

reset_lan
DB[qmodem.main.enable_dial]=0
DB[qmodem.modem1]=modem-device
DB[qmodem.modem1.enable_dial]=1
DB[qmodem.modem2]=modem-device
DB[qmodem.modem2.enable_dial]=0
DB[qmodem.modem3]=modem-device
DB[qmodem.modem3.state]=disabled
DB[qmodem.modem3.enable_dial]=0
stage_repair_dial_intent ||
	fail "repair dial-intent staging rejected an existing dialable selection"
[[ "${DB[qmodem.main.enable_dial]}" == 1 &&
   "${DB[qmodem.modem1.enable_dial]}" == 1 ]] ||
	fail "repair did not preserve the existing dialable modem"
[[ "${DB[qmodem.modem2.enable_dial]}" == 0 ]] ||
	fail "repair overwrote another modem's explicit zero despite an existing dialable modem"
[[ "${DB[qmodem.modem3.enable_dial]}" == 0 ]] ||
	fail "repair changed a disabled modem while preserving an existing selection"

reset_lan
DB[network.c2000_wan]=interface
DB[network.c2000_wan.device]=eth1
[[ "$(c2000_actual_role)" == inconsistent ]] ||
	fail "partial WAN topology was not rejected"

reset_lan
DB[network.shadow]=interface
DB[network.shadow.device]=eth1
[[ "$(c2000_actual_role)" == inconsistent ]] ||
	fail "second interface ownership of eth1 was not rejected"

reset_lan
DB[network.hidden_port]=device
DB[network.hidden_port.name]=eth1
[[ "$(c2000_actual_role)" == inconsistent ]] ||
	fail "device-name ownership of eth1 was not rejected"

reset_lan
DB[network.hidden_device]=device
DB[network.hidden_device.name]=eth0
if c2000_ppe_device_unused; then
	fail "eth0 device-name ownership was not rejected"
fi

reset_lan
DB[network.hidden_vlan]=device
DB[network.hidden_vlan.ifname]=eth0
DB[network.hidden_vlan.name]=eth0.200
if c2000_ppe_device_unused; then
	fail "eth0 VLAN ownership was not rejected"
fi

reset_lan
DB[network.br_shadow]=device
DB[network.br_shadow.type]=bridge
DB[network.br_shadow.name]=br-shadow
DB[network.br_shadow.ports]=eth1
[[ "$(c2000_actual_role)" == inconsistent ]] ||
	fail "second bridge ownership of eth1 was not rejected"

reset_lan
DB[network.vlan_shadow]=device
DB[network.vlan_shadow.type]=8021q
DB[network.vlan_shadow.ifname]=eth1
DB[network.vlan_shadow.name]=eth1.100
[[ "$(c2000_actual_role)" == inconsistent ]] ||
	fail "802.1q parent reference to eth1 was not rejected"

reset_lan
DB[network.bridge_vlan]=bridge-vlan
DB[network.bridge_vlan.ports]='eth1:t'
[[ "$(c2000_actual_role)" == inconsistent ]] ||
	fail "bridge-vlan reference to eth1 was not rejected"

reset_lan
stage_wan || fail "LAN to WAN staging failed"
[[ "$(c2000_actual_role)" == wan ]] || fail "WAN topology not detected"
[[ "${DB[network.c2000_wan.metric]}" == 5 ]] || fail "WAN metric missing"
[[ "${DB[firewall.wan.network]}" == *"wan wan6"* ]] ||
	fail "standard WAN networks were changed"
wan_zone_is_safe || fail "safe WAN zone rejected"
DB[firewall.wan.input]=ACCEPT
if wan_zone_is_safe; then
	fail "ACCEPT inbound WAN zone was accepted"
fi
DB[firewall.wan.input]=REJECT
DB[network.shadow]=interface
DB[network.shadow.device]=eth1
[[ "$(c2000_actual_role)" == inconsistent ]] ||
	fail "WAN plus second eth1 interface was not rejected"

reset_lan
FAIL_MATCH='set:network.c2000_wan.proto=dhcp'
if stage_wan; then
	fail "injected UCI failure was ignored"
fi

reset_lan
c2000_wan_settings_valid ethernet_only 60 40 auto ||
	fail "valid Ethernet-only WAN settings were rejected"
c2000_wan_settings_valid ethernet_5g_balance 60 40 auto ||
	fail "valid balanced WAN settings were rejected"
if c2000_wan_settings_valid ethernet_5g_balance 60 39 auto; then
	fail "weights that do not total 100 were accepted"
fi
if c2000_wan_settings_valid invalid 60 40 auto; then
	fail "unknown WAN mode was accepted"
fi

DB[qmodem.modem1]=modem-device
DB[qmodem.modem1.alias]=qmodem
DB[qmodem.modem1.enable_dial]=1
DB[mwan3.default_rule_v4]=rule
DB[mwan3.default_rule_v4.family]=ipv4
DB[mwan3.default_rule_v4.dest_ip]=0.0.0.0/0
DB[mwan3.default_rule_v4.use_policy]=balanced
DB[mwan3.balanced]=policy
DB[mwan3.balanced.use_member]='wan_member wan6_member'
DB[mwan3.balanced.last_resort]=unreachable
DB[mwan3.wan_member]=member
DB[mwan3.wan_member.interface]=wan
DB[mwan3.wan]=interface
DB[mwan3.wan.family]=ipv4
DB[mwan3.wan6_member]=member
DB[mwan3.wan6_member.interface]=wan6
DB[mwan3.wan6]=interface
DB[mwan3.wan6.family]=ipv6
c2000_stage_uplink_mode wan ethernet_5g_balance 60 40 auto ||
	fail "balanced QModem/mwan3 staging failed: $C2000_UPLINK_ERROR"
[[ "${DB[qmodem.main.enable_dial]}" == 1 ]] ||
	fail "balanced mode did not enable QModem dialing"
[[ "${DB[mwan3.c2000_wan.c2000max_managed]}" == 1 ]] ||
	fail "balanced mode did not manage the Ethernet mwan3 interface"
[[ "${DB[mwan3.qmodem.c2000max_managed]}" == 1 ]] ||
	fail "balanced mode did not manage the cellular mwan3 interface"
[[ "${DB[mwan3.c2000_eth_member.weight]}" == 3 ]] ||
	fail "60 percent Ethernet weight was not reduced to 3"
[[ "${DB[mwan3.c2000_cell_member.weight]}" == 2 ]] ||
	fail "40 percent cellular weight was not reduced to 2"
[[ "${DB[mwan3.default_rule_v4.use_policy]}" == balanced ]] ||
	fail "balanced mode unexpectedly rewrote the IPv4 default rule"
[[ "${DB[mwan3.balanced.use_member]}" == \
	'c2000_eth_member c2000_cell_member wan6_member' ]] ||
	fail "balanced policy did not replace IPv4 while preserving IPv6 members"
[[ "${DB[c2000max.ethernet.mwan_saved_members]}" == \
	'wan_member wan6_member' ]] ||
	fail "original mwan3 policy members were not saved"
DB[c2000max.ethernet.role]=wan
DB[c2000max.ethernet.wan_mode]=ethernet_5g_balance
DB[c2000max.ethernet.ethernet_weight]=60
DB[c2000max.ethernet.cellular_weight]=40
DB[c2000max.ethernet.cellular_modem]=auto
c2000_uplink_config_matches wan ethernet_5g_balance 60 40 auto ||
	fail "staged balanced uplink did not pass convergence validation"

c2000_stage_uplink_mode wan ethernet_only 60 40 auto ||
	fail "Ethernet-only staging failed"
[[ "${DB[qmodem.main.enable_dial]}" == 0 ]] ||
	fail "Ethernet-only mode did not stop QModem dialing"
[[ ! -v 'DB[mwan3.c2000_wan]' && ! -v 'DB[mwan3.qmodem]' ]] ||
	fail "Ethernet-only mode left managed mwan3 interfaces behind"
[[ "${DB[mwan3.default_rule_v4.use_policy]}" == balanced ]] ||
	fail "Ethernet-only mode did not restore the original mwan3 policy"
[[ "${DB[mwan3.balanced.use_member]}" == 'wan_member wan6_member' ]] ||
	fail "Ethernet-only mode did not restore original mwan3 policy members"
[[ "${DB[mwan3.balanced.last_resort]}" == unreachable ]] ||
	fail "Ethernet-only mode did not restore original mwan3 last_resort"
c2000_stage_uplink_mode lan ethernet_only 60 40 auto ||
	fail "LAN staging did not restore uplink overrides"
[[ "${DB[qmodem.main.enable_dial]}" == 1 ]] ||
	fail "returning to LAN did not restore QModem's original dial setting"
[[ ! -v 'DB[c2000max.ethernet.qmodem_override_active]' ]] ||
	fail "returning to LAN left the QModem override marker behind"

DB[qmodem.modem2]=modem-device
DB[qmodem.modem2.alias]=qmodem2
DB[qmodem.modem2.enable_dial]=1
if c2000_select_modem auto >/dev/null; then
	fail "ambiguous automatic QModem selection was accepted"
else
	rc=$?
fi
[[ "$rc" == 2 ]] || fail "ambiguous QModem selection returned $rc instead of 2"
[[ "$(c2000_select_modem modem2)" == 'modem2|qmodem2' ]] ||
	fail "explicit QModem selection did not resolve its network interface"

reset_lan
DB[qmodem.modem1]=modem-device
DB[qmodem.modem1.alias]=cell1
DB[qmodem.modem1.enable_dial]=1
DB[qmodem.modem2]=modem-device
DB[qmodem.modem2.alias]=cell2
c2000_modem_enabled modem2 ||
	fail "QModem's missing per-device enable_dial was not treated as enabled"
c2000_stage_uplink_mode wan ethernet_5g_balance 70 30 modem1 ||
	fail "explicit selected-only balance staging failed"
[[ "${DB[qmodem.modem1.enable_dial]}" == 1 &&
   "${DB[qmodem.modem2.enable_dial]}" == 0 ]] ||
	fail "balanced mode did not dial only the selected modem"
[[ "${DB[c2000max.ethernet.qmodem_saved_modem2]}" == __unset__ ]] ||
	fail "missing original per-device dial state was not journaled"
c2000_stage_uplink_mode wan ethernet_5g_balance 30 70 modem2 ||
	fail "reselecting another modem during balance mode failed"
[[ "${DB[qmodem.modem1.enable_dial]}" == 0 &&
   "${DB[qmodem.modem2.enable_dial]}" == 1 ]] ||
	fail "reselecting a modem did not converge selected-only dialing"
DB[c2000max.ethernet.role]=wan
DB[c2000max.ethernet.wan_mode]=ethernet_5g_balance
DB[c2000max.ethernet.ethernet_weight]=30
DB[c2000max.ethernet.cellular_weight]=70
DB[c2000max.ethernet.cellular_modem]=modem2
c2000_uplink_config_matches wan ethernet_5g_balance 30 70 modem2 ||
	fail "created-rule balanced graph did not pass convergence validation"
[[ "${#C2000_MWAN_RULE}" -le 15 ]] ||
	fail "managed mwan3 rule name exceeds the 15-character limit"
[[ "${DB[mwan3.$C2000_MWAN_RULE.c2000max_managed]}" == 1 ]] ||
	fail "no-catchall path did not create its managed IPv4 default rule"
c2000_stage_uplink_mode lan ethernet_only 60 40 auto ||
	fail "selected-only QModem state could not be restored"
[[ "${DB[qmodem.modem1.enable_dial]}" == 1 ]] ||
	fail "explicit original modem state was not restored"
[[ ! -v 'DB[qmodem.modem2.enable_dial]' ]] ||
	fail "originally missing modem enable_dial was not restored as missing"

reset_lan
DB[qmodem.modem1]=modem-device
DB[qmodem.modem1.alias]=lan
DB[qmodem.modem1.enable_dial]=1
if c2000_stage_uplink_mode wan ethernet_5g_balance 60 40 modem1; then
	fail "cellular alias collision with network.lan was accepted"
fi

reset_lan
DB[qmodem.modem1]=modem-device
DB[qmodem.modem1.alias]=cell1
DB[qmodem.modem1.enable_dial]=1
DB[mwan3.default_rule_v4]=rule
DB[mwan3.default_rule_v4.family]=ipv4
DB[mwan3.default_rule_v4.dest_ip]=0.0.0.0/0
DB[mwan3.default_rule_v4.use_policy]=balanced
DB[mwan3.balanced]=policy
DB[mwan3.balanced.use_member]=original_member
DB[mwan3.balanced.last_resort]=unreachable
DB[mwan3.original_member]=member
DB[mwan3.original_member.interface]=original_wan
DB[mwan3.original_wan]=interface
DB[mwan3.original_wan.family]=ipv4
c2000_stage_uplink_mode wan ethernet_5g_balance 60 40 modem1 ||
	fail "policy-disappearance fixture could not enter balance mode"
uci -q delete mwan3.balanced
c2000_stage_uplink_mode wan ethernet_only 60 40 auto ||
	fail "a deleted overridden policy trapped exit from balance mode"
[[ "${DB[mwan3.balanced]}" == policy &&
   "${DB[mwan3.balanced.use_member]}" == original_member &&
   "${DB[mwan3.balanced.last_resort]}" == unreachable ]] ||
	fail "deleted original mwan3 policy was not safely reconstructed"

reset_lan
mkdir -p "$SYS_CLASS_NET/br-lan/brif/ra0" "$SYS_CLASS_NET/ra0"
printf '0x1003\n' > "$SYS_CLASS_NET/ra0/flags"
printf 'up\n' > "$SYS_CLASS_NET/ra0/operstate"
has_wifi_management || fail "live Wi-Fi AP in br-lan was not detected"
DB[wireless.radio0.disabled]=1
if has_wifi_management; then
	fail "disabled Wi-Fi radio passed management guard"
fi

set_topology_fixture()
{
	local role="$1" topology ppd endpoint value

	topology="$(c2000_expected_hnat_topology "$role")"
	printf '%s\n' "$topology" > "$C2000_HNAT_TOPOLOGY"
	ppd="$(c2000_expected_hnat_endpoint "$role" ppd)"
	printf '%s\ng_ppdev=%s\ng_rx_ppdev=%s\n' \
		"$ppd" "$ppd" "$C2000_RX_PPD_DEVICE" \
		> "$C2000_HNAT_DIR/hnat_ppd_if"

	# Model the V21 kernel's read-only compatibility nodes. The controller
	# must never use these four files as a sequential-write fallback.
	for endpoint in wan lan lan2 ppd; do
		value="$(c2000_expected_hnat_endpoint "$role" "$endpoint")"
		[[ "$endpoint" == ppd ]] ||
			printf '%s\n' "$value" > "$C2000_HNAT_DIR/hnat_${endpoint}_if"
	done
}

reset_runtime_fixture()
{
	local role="$1"

	rm -rf "$C2000_SYS_CLASS_NET" "$C2000_HNAT_DIR"
	mkdir -p \
		"$C2000_SYS_CLASS_NET/eth0/of_node" \
		"$C2000_SYS_CLASS_NET/eth1/of_node" \
		"$C2000_SYS_CLASS_NET/br-lan/brif/ra0" \
		"$C2000_SYS_CLASS_NET/br-lan/brif/rxppd" \
		"$C2000_SYS_CLASS_NET/ra0/wireless" \
		"$C2000_SYS_CLASS_NET/rxppd" \
		"$C2000_HNAT_DIR"
	printf 'mediatek,eth-mac\n' > "$C2000_SYS_CLASS_NET/eth0/of_node/compatible"
	printf 'mediatek,eth-mac\n' > "$C2000_SYS_CLASS_NET/eth1/of_node/compatible"
	printf '0x1002\n' > "$C2000_SYS_CLASS_NET/eth0/flags"
	printf 'down\n' > "$C2000_SYS_CLASS_NET/eth0/operstate"
	printf '0x1003\n' > "$C2000_SYS_CLASS_NET/eth1/flags"
	printf 'up\n' > "$C2000_SYS_CLASS_NET/eth1/operstate"
	printf '0x1003\n' > "$C2000_SYS_CLASS_NET/ra0/flags"
	printf 'up\n' > "$C2000_SYS_CLASS_NET/ra0/operstate"
	printf '0x1003\n' > "$C2000_SYS_CLASS_NET/rxppd/flags"
	printf 'up\n' > "$C2000_SYS_CLASS_NET/rxppd/operstate"
	ln -s ../br-lan "$C2000_SYS_CLASS_NET/rxppd/master"
	if [[ "$role" == lan ]]; then
		ln -s ../br-lan "$C2000_SYS_CLASS_NET/eth1/master"
	fi
	printf '1:ra0\n' > "$C2000_HNAT_DIR/whnat_interface"
	printf 'enabled\n' > "$C2000_HNAT_DIR/hook_toggle"
	printf 'entry|state=UNBIND|\n' > "$C2000_HNAT_DIR/all_entry"
	printf '0\n' > "$C2000_HNAT_DIR/hnat_setting"
	set_topology_fixture "$role"
	printf 'mediatek_hnat\n' > "$C2000_HNAT_EFFECTIVE"
	rm -f "$C2000_HNAT_SETTINGS_EFFECTIVE"
}

reset_lan
reset_runtime_fixture lan
[[ "$(c2000_expected_hnat_topology lan)" == \
	"wan=/ lan=eth1 lan2=/ ppd=eth1" ]] ||
	fail "LAN canonical HNAT tuple is wrong"
[[ "$(c2000_hnat_topology_read)" == \
	"wan=/ lan=eth1 lan2=/ ppd=eth1" ]] ||
	fail "LAN atomic topology readback is wrong"
c2000_hard_hnat_ready lan || fail "verified LAN HNAT fixture was rejected"
touch "$DEGRADED"
acceleration_matches lan ||
	fail "verified hardware could not repair an existing degraded marker"
rm -f "$DEGRADED"

printf '9:ghost0\n' > "$C2000_HNAT_DIR/whnat_interface"
if c2000_whnat_ready; then
	fail "unregistered Wi-Fi passed the independent WHNAT readiness check"
fi
c2000_hard_hnat_ready lan ||
	fail "missing WHNAT registration incorrectly disabled base LAN HNAT"
printf '1:ra0\n' > "$C2000_HNAT_DIR/whnat_interface"

printf 'wan=/ lan=eth0 lan2=/ ppd=eth1\n' > "$C2000_HNAT_TOPOLOGY"
if c2000_hnat_endpoints_match lan; then
	fail "wrong LAN atomic tuple passed readback gate"
fi
set_topology_fixture lan

topology="$(c2000_expected_hnat_topology lan)"
printf '%s' "$topology" > "$C2000_HNAT_TOPOLOGY"
if c2000_hnat_topology_read >/dev/null; then
	fail "non-newline-terminated atomic readback was accepted"
fi
set_topology_fixture lan

rm -f "$C2000_HNAT_TOPOLOGY"
if c2000_hnat_endpoints_match lan; then
	fail "legacy four-file endpoint interface was accepted without hnat_topology"
fi
set_topology_fixture lan

printf '0x1002\n' > "$C2000_SYS_CLASS_NET/rxppd/flags"
if c2000_rxppd_ready; then
	fail "down rxppd passed readiness gate"
fi
printf '0x1003\n' > "$C2000_SYS_CLASS_NET/rxppd/flags"

DB[network.hidden_eth0]=device
DB[network.hidden_eth0.name]=eth0
if c2000_hard_hnat_ready lan; then
	fail "UCI-owned eth0 passed hard HNAT gate"
fi
unset 'DB[network.hidden_eth0]' 'DB[network.hidden_eth0.name]'

stage_wan || fail "WAN staging for HNAT fixture failed"
reset_runtime_fixture wan
[[ "$(c2000_expected_hnat_topology wan)" == \
	"wan=eth1 lan=br-lan lan2=/ ppd=eth0" ]] ||
	fail "WAN canonical HNAT tuple is wrong"
c2000_hard_hnat_ready wan || fail "verified WAN HNAT fixture was rejected"
[[ "$(c2000_hnat_endpoint_value wan)" == eth1 ]] ||
	fail "WAN role did not map HNAT WAN to eth1"
[[ "$(c2000_hnat_endpoint_value lan)" == br-lan ]] ||
	fail "WAN role did not map HNAT LAN to br-lan"
[[ "$(c2000_hnat_endpoint_value ppd)" == eth0 ]] ||
	fail "WAN role did not map HNAT PPD to eth0"

HNAT_INIT="$ROOT/files/etc/init.d/c2000max-hnat"
source "$HNAT_INIT"

set_hnat_hook_state()
{
	case "$1" in
		0) printf 'disabled\n' > "$HNAT_DIR/hook_toggle" ;;
		1) printf 'enabled\n' > "$HNAT_DIR/hook_toggle" ;;
		*) return 1 ;;
	esac
}

reload_firewall() { return 0; }
lsmod() { printf 'mtkhnat 1 0\n'; }
modprobe() { return 0; }
c2000_register_whnat_member()
{
	printf '1:%s\n' "$1" > "$C2000_HNAT_DIR/whnat_interface"
}
ip()
{
	if [[ "${1-}" == -d ]]; then
		printf '1: %s: <BROADCAST> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000 dummy\n' "${5-rxppd}"
		return 0
	fi
	if [[ "${1-} ${2-} ${3-} ${4-} ${5-}" == "link set dev eth0 up" ]]; then
		printf '0x1003\n' > "$SYS_CLASS_NET/eth0/flags"
		printf 'up\n' > "$SYS_CLASS_NET/eth0/operstate"
		return 0
	fi
	if [[ "${1-} ${2-} ${3-} ${4-} ${5-}" == "link set dev eth0 down" ]]; then
		printf '0x1002\n' > "$SYS_CLASS_NET/eth0/flags"
		printf 'down\n' > "$SYS_CLASS_NET/eth0/operstate"
		return 0
	fi
	return 0
}

# A healthy topology may skip flow-table teardown, but it must not skip a
# later TurboACC/EQoS parameter update.
reset_lan
reset_runtime_fixture lan
apply_mode_locked ||
	fail "healthy HNAT path did not initialize its settings readback"
[[ "$(cat "$C2000_HNAT_SETTINGS_EFFECTIVE")" == \
	"bind_rate=30 update_nfct=0" ]] ||
	fail "initial HNAT settings readback is wrong"
DB[turboacc.config.fastpath_mh_bind_rate]=5
DB[turboacc.config.fastpath_mh_update_nfct]=1
apply_mode_locked ||
	fail "healthy HNAT path did not synchronize changed settings"
[[ "$(cat "$C2000_HNAT_SETTINGS_EFFECTIVE")" == \
	"bind_rate=5 update_nfct=1" ]] ||
	fail "healthy HNAT path falsely reported stale settings"
[[ "$(cat "$HNAT_DIR/hnat_setting")" == "7 1" ]] ||
	fail "healthy HNAT path did not issue the final update_nfct command"

DB[turboacc.config.fastpath_mh_bind_rate]=6
rm -f "$HNAT_DIR/hnat_setting"
mkdir "$HNAT_DIR/hnat_setting"
if apply_mode_locked 2>/dev/null; then
	fail "failed HNAT setting write passed the healthy fast path"
fi
[[ "$(cat "$HNAT_DIR/hook_toggle")" == disabled ]] ||
	fail "HNAT setting failure did not fail closed"
[[ "$(cat "$HNAT_EFFECTIVE")" == disabled ]] ||
	fail "HNAT setting failure left a false effective-HNAT state"
rmdir "$HNAT_DIR/hnat_setting"
printf '0\n' > "$HNAT_DIR/hnat_setting"

reset_lan
reset_runtime_fixture lan
DB[c2000max.ethernet.pending]=1
apply_mode_locked ||
	fail "stale persistent journal incorrectly blocked valid LAN HNAT"
[[ "$(cat "$HNAT_DIR/hook_toggle")" == enabled ]] ||
	fail "stale journal forced a verified LAN HNAT topology off"
unset 'DB[c2000max.ethernet.pending]'
printf 'enabled\n' > "$HNAT_DIR/hook_toggle"
if write_hnat_topology lan; then
	fail "atomic topology write was accepted while the HNAT hook was enabled"
fi
printf 'disabled\n' > "$HNAT_DIR/hook_toggle"
write_hnat_topology lan ||
	fail "single-write LAN atomic topology transaction failed"
apply_mode_locked || fail "LAN hard HNAT controller convergence failed"
[[ "$(cat "$HNAT_DIR/hook_toggle")" == enabled ]] ||
	fail "LAN convergence did not enable HNAT"
[[ "$(cat "$HNAT_EFFECTIVE")" == mediatek_hnat ]] ||
	fail "LAN convergence did not record hard HNAT"

stage_wan || fail "WAN controller staging failed"
reset_runtime_fixture wan
printf 'enabled\n' > "$HNAT_DIR/hook_toggle"
printf 'mediatek_hnat\n' > "$HNAT_EFFECTIVE"
apply_mode_locked || fail "WAN software-flow fallback convergence failed"
[[ "$(cat "$HNAT_DIR/hook_toggle")" == disabled ]] ||
	fail "WAN convergence did not disable HNAT"
[[ "$(cat "$HNAT_EFFECTIVE")" == flow_offloading ]] ||
	fail "WAN convergence did not record software flow offload"
[[ "${DB[turboacc.config.fastpath]}" == mediatek_hnat ]] ||
	fail "WAN convergence overwrote the user's LAN HNAT preference"
[[ "${DB[firewall.@defaults[0].flow_offloading]}" == 1 &&
   "${DB[firewall.@defaults[0].flow_offloading_hw]}" == 0 ]] ||
	fail "WAN convergence did not enable software-only flow offload"

reset_lan
reset_runtime_fixture lan
printf 'disabled\n' > "$HNAT_DIR/hook_toggle"
printf '9:ghost0\n' > "$HNAT_DIR/whnat_interface"
apply_mode_locked ||
	fail "missing WHNAT registration incorrectly failed base HNAT convergence"
[[ "$(cat "$HNAT_DIR/hook_toggle")" == enabled ]] ||
	fail "optional WHNAT registration kept base HNAT disabled"
[[ "$(cat "$HNAT_EFFECTIVE")" == mediatek_hnat ]] ||
	fail "base HNAT did not become effective while WHNAT was synchronizing"
[[ "$(cat "$C2000_WHNAT_EFFECTIVE")" == ready ]] ||
	fail "active Wi-Fi member was not registered into WHNAT independently"

reset_lan
reset_runtime_fixture lan
rm -rf "$C2000_SYS_CLASS_NET/br-lan/brif/ra0" \
	"$C2000_SYS_CLASS_NET/ra0"
: > "$HNAT_DIR/whnat_interface"
printf 'disabled\n' > "$HNAT_DIR/hook_toggle"
apply_mode_locked ||
	fail "an inactive radio incorrectly prevented base LAN HNAT convergence"
[[ "$(cat "$HNAT_DIR/hook_toggle")" == enabled ]] ||
	fail "inactive Wi-Fi kept the base HNAT hook disabled"
[[ "$(cat "$C2000_WHNAT_EFFECTIVE")" == inactive ]] ||
	fail "inactive Wi-Fi was not reported independently from base HNAT"

reset_lan
reset_runtime_fixture lan
printf '1:ra0\n' > "$HNAT_DIR/whnat_interface"
printf 'disabled\n' > "$HNAT_DIR/hook_toggle"
saved_topology="$HNAT_TOPOLOGY"
saved_c2000_topology="$C2000_HNAT_TOPOLOGY"
HNAT_TOPOLOGY="$HNAT_DIR/missing/hnat_topology"
C2000_HNAT_TOPOLOGY="$HNAT_TOPOLOGY"
if apply_mode_locked; then
	fail "missing atomic topology node did not fail convergence"
fi
HNAT_TOPOLOGY="$saved_topology"
C2000_HNAT_TOPOLOGY="$saved_c2000_topology"
[[ "$(cat "$HNAT_DIR/hook_toggle")" == disabled ]] ||
	fail "atomic topology failure left HNAT enabled"

printf 'disabled\n' > "$HNAT_DIR/hook_toggle"
printf 'entry|state=BIND|\n' > "$HNAT_DIR/all_entry"
if apply_mode_locked; then
	fail "uncleared PPE BIND entry passed quiesce barrier"
fi
[[ "$(cat "$HNAT_EFFECTIVE")" == unknown ]] ||
	fail "failed hook-off proof falsely recorded disabled HNAT"
printf 'entry|state=UNBIND|\n' > "$HNAT_DIR/all_entry"

DB[turboacc.config.fastpath]=disabled
printf 'enabled\n' > "$HNAT_DIR/hook_toggle"
printf 'mediatek_hnat\n' > "$HNAT_EFFECTIVE"
touch "$ACCEL_DEGRADED"
apply_mode_locked ||
	fail "manual acceleration disable did not converge as a valid steady state"
[[ "$(cat "$HNAT_DIR/hook_toggle")" == disabled ]] ||
	fail "manual acceleration disable left the HNAT hook enabled"
[[ "$(cat "$HNAT_EFFECTIVE")" == disabled ]] ||
	fail "manual acceleration disable did not record the disabled state"
[[ ! -e "$ACCEL_DEGRADED" ]] ||
	fail "verified manual acceleration disable left a stale acceleration warning"
stage_wan || fail "WAN staging before disabled-policy readback failed"
reset_runtime_fixture wan
printf 'disabled\n' > "$HNAT_DIR/hook_toggle"
printf 'disabled\n' > "$HNAT_EFFECTIVE"
acceleration_matches wan ||
	fail "disabled WAN acceleration did not pass transaction readback"

reset_lan
reset_runtime_fixture lan
DB[turboacc.config.fastpath]=flow_offloading
printf 'enabled\n' > "$HNAT_DIR/hook_toggle"
apply_mode_locked ||
	fail "supported software flow-offload request failed board convergence"
[[ "$(cat "$HNAT_DIR/hook_toggle")" == disabled ]] ||
	fail "software flow-offload request left MediaTek HNAT enabled"
[[ "$(cat "$HNAT_EFFECTIVE")" == flow_offloading ]] ||
	fail "software flow-offload request did not record its effective state"
[[ "${DB[firewall.@defaults[0].flow_offloading]}" == 1 &&
   "${DB[firewall.@defaults[0].flow_offloading_hw]}" == 0 ]] ||
	fail "software flow-offload request enabled the wrong firewall mode"

DB[turboacc.config.fastpath]=disabled
rm -rf "$HNAT_DIR"
apply_mode_locked ||
	fail "manual acceleration disable required an already-loaded HNAT module"
[[ "$(cat "$HNAT_EFFECTIVE")" == disabled ]] ||
	fail "module-absent disable did not keep the effective state disabled"

LOCK_TRACE=""
flock()
{
	local operation="${1-}" fd="${2-}" lock_path

	if [[ "$operation" == -w ]]; then
		operation="${3-}"
		fd="${4-}"
	fi

	case "$fd" in
		4|7) lock_path="$ROLE_LOCK" ;;
		5|8) lock_path="$HNAT_LOCK" ;;
		9) lock_path="$QUEUE_LOCK" ;;
		*) return 1 ;;
	esac

	case "$operation" in
		-x)
			HELD["$lock_path"]=1
			LOCK_TRACE="${LOCK_TRACE}${LOCK_TRACE:+ }lock:$lock_path"
			;;
		-u)
			HELD["$lock_path"]=0
			LOCK_TRACE="${LOCK_TRACE}${LOCK_TRACE:+ }-u:$lock_path"
			;;
		*)
			return 1
			;;
	esac
}

SIGNAL_PROBE="$TMP/hnat-signal-probe"
rm -f "$SIGNAL_PROBE"
(
	fail_closed() { : >"$SIGNAL_PROBE"; return 1; }
	HNAT_LOCK_HELD=0
	HNAT_ROLE_HELD=0
	hnat_signal_abort
) >/dev/null 2>&1 || true
[[ ! -e "$SIGNAL_PROBE" ]] ||
	fail "HNAT signal handler changed hardware before owning HNAT"
(
	fail_closed() { : >"$SIGNAL_PROBE"; return 1; }
	HNAT_LOCK_HELD=1
	HNAT_ROLE_HELD=1
	hnat_signal_abort
) >/dev/null 2>&1 || true
[[ -e "$SIGNAL_PROBE" ]] ||
	fail "HNAT signal handler did not fail closed after owning HNAT"

PREACTIVE_JOB="$TMP/preactive-signal-job"
PREACTIVE_CLEAR="$TMP/preactive-signal-clear"
PREACTIVE_BACKUP="$TMP/preactive-signal-backup"
rm -f "$PREACTIVE_JOB" "$PREACTIVE_CLEAR" "$PREACTIVE_BACKUP"
(
	write_job() { printf '%s:%s\n' "$2" "$3" >"$1"; }
	clear_active_job() { printf '%s\n' "$1" >"$PREACTIVE_CLEAR"; }
	cleanup_backup() { : >"$PREACTIVE_BACKUP"; }
	APPLY_CONTEXT=1
	APPLY_ACTIVE=0
	CURRENT_JOB=preactive
	CURRENT_JOB_FILE="$PREACTIVE_JOB"
	CURRENT_BACKUP="$TMP/backup-preactive"
	abort_apply
) >/dev/null 2>&1 || true
[[ "$(cat "$PREACTIVE_JOB")" == failed:0 ]] ||
	fail "pre-transaction signal left a running job"
[[ "$(cat "$PREACTIVE_CLEAR")" == preactive ]] ||
	fail "pre-transaction signal left the active queue entry"
[[ -e "$PREACTIVE_BACKUP" ]] ||
	fail "pre-transaction signal did not clean its backup"

reset_lan
reset_runtime_fixture lan
LOCK_TRACE=""
C2000MAX_ACCEL_LOCKS_HELD=1 apply_mode ||
	fail "lock-owned nested HNAT convergence failed"
[[ -z "$LOCK_TRACE" ]] ||
	fail "lock-owned nested HNAT convergence reacquired shared locks"

LOCK_TRACE=""
apply_mode || fail "normal HNAT convergence failed to acquire shared locks"
[[ "$LOCK_TRACE" == \
	"lock:$ROLE_LOCK lock:$HNAT_LOCK -u:$HNAT_LOCK -u:$ROLE_LOCK" ]] ||
	fail "normal HNAT convergence violated ROLE -> HNAT lock order: $LOCK_TRACE"

HNAT_HELPER_CALLS=0
hnat_locked_helper_mock()
{
	[[ "${HELD[$HNAT_LOCK]-0}" == 1 ]] || return 1
	[[ "$C2000MAX_PORT_SWITCH" == 1 ]] || return 1
	[[ "$C2000MAX_ACCEL_LOCKS_HELD" == 1 ]] || return 1
	HNAT_HELPER_CALLS=$((HNAT_HELPER_CALLS + 1))
}
HNAT_LOCKED_HELPER=hnat_locked_helper_mock
LOCK_TRACE=""
hnat_reload || fail "role transaction could not run the locked HNAT worker"
[[ "$HNAT_HELPER_CALLS" == 1 ]] ||
	fail "role transaction did not invoke the locked HNAT worker"
[[ "$LOCK_TRACE" == "lock:$HNAT_LOCK -u:$HNAT_LOCK" ]] ||
	fail "role transaction did not hold HNAT across convergence: $LOCK_TRACE"

EQOS_HELPER_CALLS=0
eqos_locked_helper_mock()
{
	[[ "$1" == start ]] || return 1
	[[ "${HELD[$HNAT_LOCK]-0}" == 1 ]] || return 1
	[[ "$C2000MAX_PORT_SWITCH" == 1 ]] || return 1
	[[ "$C2000MAX_ACCEL_LOCKS_HELD" == 1 ]] || return 1
	EQOS_HELPER_CALLS=$((EQOS_HELPER_CALLS + 1))
}
EQOS_LOCKED_HELPER=eqos_locked_helper_mock
LOCK_TRACE=""
eqos_start || fail "role transaction could not run the locked EQoS worker"
[[ "$EQOS_HELPER_CALLS" == 1 ]] ||
	fail "role transaction did not invoke the locked EQoS worker"
[[ "$LOCK_TRACE" == "lock:$HNAT_LOCK -u:$HNAT_LOCK" ]] ||
	fail "role transaction did not hold HNAT across EQoS: $LOCK_TRACE"

# Service command exit codes and momentary process state are advisory.  Only
# persistent enable/disable intent belongs to the synchronous role transaction.
eqos_stop ||
	fail "EQoS runtime-clean stop was rejected because its helper returned nonzero"
NONZERO_INIT="$TMP/nonzero-init"
printf '#!/bin/sh\nexit 7\n' > "$NONZERO_INIT"
chmod 700 "$NONZERO_INIT"
SAVED_QMODEM_INIT="$QMODEM_INIT"
SAVED_MWAN_INIT="$MWAN_INIT"
QMODEM_INIT="$NONZERO_INIT"
MWAN_INIT="$NONZERO_INIT"
MOCK_SERVICE_RUNNING=0
MOCK_SERVICE_ENABLED=0
service_running() { [[ "$MOCK_SERVICE_RUNNING" == 1 ]]; }
service_enabled() { [[ "$MOCK_SERVICE_ENABLED" == 1 ]]; }
qmodem_stop ||
	fail "already-stopped QModem was rejected because init stop returned nonzero"
mwan_stop ||
	fail "already-stopped mwan3 was rejected because init stop returned nonzero"
MOCK_SERVICE_RUNNING=1
qmodem_stop ||
	fail "QModem best-effort stop incorrectly vetoed the role transaction"
MOCK_SERVICE_RUNNING=0
set_service_state "$NONZERO_INIT" 0 0 ||
	fail "already-disabled/stopped service state rejected nonzero init commands"
MOCK_SERVICE_RUNNING=1
MOCK_SERVICE_ENABLED=1
set_service_state "$NONZERO_INIT" 1 1 ||
	fail "already-enabled/running service state rejected nonzero init commands"
QMODEM_INIT="$SAVED_QMODEM_INIT"
MWAN_INIT="$SAVED_MWAN_INIT"

eqos_stop() { return 0; }
FORCE_OFF=0
FORCE_OFF_FAIL_AT=0
force_hook_off()
{
	FORCE_OFF=$((FORCE_OFF + 1))
	if [[ "$FORCE_OFF_FAIL_AT" -gt 0 &&
	      "$FORCE_OFF" -eq "$FORCE_OFF_FAIL_AT" ]]; then
		printf 'unknown\n' > "$HNAT_EFFECTIVE"
		return 1
	fi
	printf 'disabled\n' > "$HNAT_EFFECTIVE"
	return 0
}
quiesce_acceleration || fail "acceleration quiesce failed"
[[ "${HELD[$HNAT_LOCK]-0}" == 0 ]] || fail "HNAT lock leaked"
[[ "$FORCE_OFF" -gt 0 ]] || fail "HNAT hook was not forced off"

write_job()
{
	JOB_STATE="$2"
	JOB_SUCCESS="$3"
	JOB_MESSAGE="$4"
}
clear_active_job() { return 0; }
BACKUP_FASTPATH=""
BACKUP_QMODEM=""
backup_configs()
{
	BACKUP_FASTPATH="${DB[turboacc.config.fastpath]-}"
	BACKUP_QMODEM="${DB[qmodem.main.enable_dial]-}"
	return 0
}
cleanup_backup() { return 0; }
sleep() { return 0; }
firewall_reload() { return 0; }
service_running()
{
	[[ "$1" == "$QMODEM_INIT" && "$QMODEM_RUNNING" == 1 ]] ||
		[[ "$1" == "$MWAN_INIT" && "$MWAN_RUNNING" == 1 ]]
}
service_enabled()
{
	[[ "$1" == "$QMODEM_INIT" && "$QMODEM_ENABLED" == 1 ]] ||
		[[ "$1" == "$MWAN_INIT" && "$MWAN_ENABLED" == 1 ]]
}
qmodem_service_running() { [[ "$QMODEM_RUNNING" == 1 ]]; }
qmodem_service_enabled() { [[ "$QMODEM_ENABLED" == 1 ]]; }
mwan_service_running() { [[ "$MWAN_RUNNING" == 1 ]]; }
mwan_service_enabled() { [[ "$MWAN_ENABLED" == 1 ]]; }
QMODEM_STOP_MODE=success
MWAN_STOP_MODE=success
QMODEM_STOP_CALLS=0
MWAN_STOP_CALLS=0
qmodem_stop()
{
	QMODEM_STOP_CALLS=$((QMODEM_STOP_CALLS + 1))
	[[ "$QMODEM_STOP_MODE" != fail ]] || return 1
	if [[ "$QMODEM_STOP_MODE" == first_fail &&
	      "$QMODEM_STOP_CALLS" == 1 ]]; then
		return 1
	fi
	QMODEM_RUNNING=0
}
mwan_stop()
{
	MWAN_STOP_CALLS=$((MWAN_STOP_CALLS + 1))
	[[ "$MWAN_STOP_MODE" != fail ]] || return 1
	if [[ "$MWAN_STOP_MODE" == first_fail &&
	      "$MWAN_STOP_CALLS" == 1 ]]; then
		return 1
	fi
	MWAN_RUNNING=0
}
set_service_state()
{
	local init="$1" enabled="$2" running="$3"
	if [[ "$init" == "$QMODEM_INIT" ]]; then
		QMODEM_ENABLED="$enabled"
		QMODEM_RUNNING="$running"
	elif [[ "$init" == "$MWAN_INIT" ]]; then
		MWAN_ENABLED="$enabled"
		MWAN_RUNNING="$running"
	else
		return 1
	fi
}
HNAT_RELOAD_MODE=success
HNAT_RELOAD_CALLS=0
HNAT_EXPECT_NO_PENDING=0
HNAT_EXPECT_ROLE=""
hnat_reload()
{
	HNAT_RELOAD_CALLS=$((HNAT_RELOAD_CALLS + 1))
	if [[ "$HNAT_EXPECT_NO_PENDING" == 1 &&
	      -v 'DB[c2000max.ethernet.pending]' ]]; then
		return 8
	fi
	if [[ -n "$HNAT_EXPECT_ROLE" &&
	      "${DB[c2000max.ethernet.role]-}" != "$HNAT_EXPECT_ROLE" ]]; then
		return 9
	fi
	if [[ "$HNAT_RELOAD_MODE" == first_fail && "$HNAT_RELOAD_CALLS" == 1 ]]; then
		return 1
	fi
	[[ "$HNAT_RELOAD_MODE" != always_fail ]]
}
eqos_start() { return 0; }
wait_runtime_role() { return 0; }
ACCEL_MATCH_MODE=success
ACCEL_MATCH_CALLS=0
acceleration_matches()
{
	ACCEL_MATCH_CALLS=$((ACCEL_MATCH_CALLS + 1))
	if [[ "$ACCEL_MATCH_MODE" == first_fail &&
	      "$ACCEL_MATCH_CALLS" == 1 ]]; then
		return 1
	fi
	[[ "$ACCEL_MATCH_MODE" != always_fail ]]
}
restore_role_backup_runtime()
{
	local key
	for key in "${!DB[@]}"; do
		case "$key" in
			network.*|mwan3.*)
				unset 'DB['"$key"']'
				;;
		esac
	done
	DB[network.lan]=interface
	DB[network.lan.device]=br-lan
	DB[network.br_lan]=device
	DB[network.br_lan.type]=bridge
	DB[network.br_lan.name]=br-lan
	DB[network.br_lan.ports]=eth1
	DB[mwan3.globals]=globals
	DB[qmodem.main]=main
	DB[qmodem.main.enable_dial]="$BACKUP_QMODEM"
	DB[turboacc.config.fastpath]="$BACKUP_FASTPATH"
}
restore_role_backup_state()
{
	local key
	for key in "${!DB[@]}"; do
		case "$key" in
			c2000max.ethernet.*)
				unset 'DB['"$key"']'
				;;
		esac
	done
	DB[c2000max.ethernet]=ethernet
	DB[c2000max.ethernet.role]=lan
	DB[c2000max.ethernet.wan_mode]=ethernet_only
	DB[c2000max.ethernet.ethernet_weight]=60
	DB[c2000max.ethernet.cellular_weight]=40
	DB[c2000max.ethernet.cellular_modem]=auto
}
backup_has_pending() { return 1; }

RELOAD_MODE=first_fail
RELOAD_CALLS=0
network_reload()
{
	[[ "${HELD[$HNAT_LOCK]-0}" == 0 ]] ||
		fail "network reload ran while HNAT lock was held"
	RELOAD_CALLS=$((RELOAD_CALLS + 1))
	if [[ "$RELOAD_MODE" == first_fail && "$RELOAD_CALLS" == 1 ]]; then
		return 1
	fi
	[[ "$RELOAD_MODE" != always_fail ]]
}

# A healthy network with only an acceleration mismatch must never enter the
# network/service transaction or create a persistent journal.
reset_lan
mkdir -p "$JOB_DIR"
RELOAD_MODE=success
RELOAD_CALLS=0
HNAT_RELOAD_MODE=success
HNAT_RELOAD_CALLS=0
HNAT_EXPECT_NO_PENDING=1
HNAT_EXPECT_ROLE=lan
ACCEL_MATCH_MODE=first_fail
ACCEL_MATCH_CALLS=0
FORCE_OFF=0
FORCE_OFF_FAIL_AT=0
apply_role lan acceleration-only ethernet_only 60 40 auto 0 ||
	fail "acceleration-only convergence failed"
[[ "$RELOAD_CALLS" == 0 ]] ||
	fail "acceleration-only convergence reloaded the network"
[[ "$HNAT_RELOAD_CALLS" == 1 ]] ||
	fail "acceleration-only convergence did not run exactly one HNAT pass"
[[ "$QMODEM_RUNNING:$QMODEM_ENABLED:$MWAN_RUNNING:$MWAN_ENABLED" == 1:1:0:0 ]] ||
	fail "acceleration-only convergence changed uplink services"
[[ ! -v 'DB[c2000max.ethernet.pending]' ]] ||
	fail "acceleration-only convergence created a recovery journal"

# Even an unverified hook-off proof is acceleration degradation only: report it
# precisely without making network_converged false or touching uplinks.
reset_lan
RELOAD_CALLS=0
HNAT_RELOAD_MODE=first_fail
HNAT_RELOAD_CALLS=0
HNAT_EXPECT_NO_PENDING=1
HNAT_EXPECT_ROLE=lan
ACCEL_MATCH_MODE=always_fail
ACCEL_MATCH_CALLS=0
FORCE_OFF=0
FORCE_OFF_FAIL_AT=1
if apply_role lan acceleration-unknown ethernet_only 60 40 auto 0; then
	fail "unknown acceleration safety state was reported as a successful job"
else
	rc=$?
fi
[[ "$rc" == 2 ]] ||
	fail "unknown acceleration state returned $rc instead of 2"
[[ "$RELOAD_CALLS" == 0 ]] ||
	fail "unknown acceleration state reloaded the network"
[[ ! -e "$DEGRADED" && -e "$ACCEL_DEGRADED" ]] ||
	fail "unknown acceleration state was not isolated from network degradation"
[[ "$QMODEM_RUNNING:$QMODEM_ENABLED:$MWAN_RUNNING:$MWAN_ENABLED" == 1:1:0:0 ]] ||
	fail "unknown acceleration state changed uplink services"
HNAT_EXPECT_NO_PENDING=0
HNAT_EXPECT_ROLE=""
ACCEL_MATCH_MODE=success
ACCEL_MATCH_CALLS=0
FORCE_OFF_FAIL_AT=0

reset_lan
QMODEM_RUNNING=0
QMODEM_ENABLED=0
RELOAD_MODE=first_fail
RELOAD_CALLS=0
HNAT_RELOAD_MODE=success
HNAT_RELOAD_CALLS=0
if apply_role wan rollback-ok ethernet_only 60 40 auto 1; then
	fail "fault-injected target reload unexpectedly succeeded"
else
	rc=$?
fi
[[ "$rc" == 1 ]] || fail "verified rollback returned $rc instead of 1"
[[ "$(c2000_actual_role)" == lan ]] || fail "verified rollback did not restore LAN"
[[ "${DB[qmodem.main.enable_dial]}" == 1 ]] ||
	fail "LAN rollback lost the configured QModem dial intent"
[[ "$QMODEM_RUNNING:$QMODEM_ENABLED" == 1:1 ]] ||
	fail "LAN rollback did not force QModem enabled and running for enable_dial=1"
[[ ! -e "$DEGRADED" ]] || fail "successful rollback left degraded marker"

reset_lan
DB[turboacc.config.fastpath]=disabled
RELOAD_MODE=success
RELOAD_CALLS=0
HNAT_RELOAD_MODE=success
HNAT_RELOAD_CALLS=0
apply_role wan disabled-policy-wan ethernet_only 60 40 auto 1 ||
	fail "WAN transaction rejected the user's disabled acceleration policy"
[[ "$(c2000_actual_role)" == wan ]] ||
	fail "disabled acceleration prevented the WAN network from converging"
[[ "${DB[turboacc.config.fastpath]}" == disabled ]] ||
	fail "WAN transaction silently promoted disabled acceleration"
[[ ! -e "$ACCEL_DEGRADED" ]] ||
	fail "verified disabled WAN acceleration was reported as degraded"
apply_role lan disabled-policy-lan ethernet_only 60 40 auto 1 ||
	fail "LAN transaction rejected the user's disabled acceleration policy"
[[ "$(c2000_actual_role)" == lan ]] ||
	fail "disabled acceleration prevented the LAN network from converging"
[[ "${DB[turboacc.config.fastpath]}" == disabled ]] ||
	fail "LAN transaction silently promoted disabled acceleration"

reset_lan
DB[qmodem.modem1]=modem-device
DB[qmodem.modem1.alias]=cell1
DB[qmodem.modem1.enable_dial]=1
RELOAD_MODE=success
RELOAD_CALLS=0
HNAT_RELOAD_MODE=success
HNAT_RELOAD_CALLS=0
apply_role wan service-balance ethernet_5g_balance 60 40 modem1 1 ||
	fail "balanced service-state transaction did not converge"
[[ "$QMODEM_RUNNING:$QMODEM_ENABLED" == 1:1 ]] ||
	fail "balanced mode did not run and enable QModem"
[[ "$MWAN_RUNNING:$MWAN_ENABLED" == 1:1 ]] ||
	fail "balanced mode did not run and enable mwan3"
[[ ! -v 'DB[c2000max.ethernet.qmodem_saved_running]' &&
   ! -v 'DB[c2000max.ethernet.mwan_saved_running]' &&
   ! -v 'DB[c2000max.ethernet.services_override_active]' ]] ||
	fail "momentary service process state was persisted"
[[ ! -v 'DB[c2000max.ethernet.pending]' &&
   ! -v 'DB[c2000max.ethernet.journal_phase]' ]] ||
	fail "successful transaction left its write-ahead journal active"
apply_role lan service-restore ethernet_only 60 40 auto 1 ||
	fail "returning to LAN did not apply deterministic service intent"
[[ "$QMODEM_RUNNING:$QMODEM_ENABLED" == 1:1 ]] ||
	fail "LAN did not enable QModem for configured 5G dialing"
[[ "$MWAN_RUNNING:$MWAN_ENABLED" == 0:0 ]] ||
	fail "LAN did not disable unused mwan3"
[[ ! -v 'DB[c2000max.ethernet.services_override_active]' ]] ||
	fail "LAN left the service override journal active"

reset_lan
DB[qmodem.modem1]=modem-device
DB[qmodem.modem1.alias]=cell1
DB[qmodem.modem1.enable_dial]=1
DB[qmodem.modem2]=modem-device
DB[qmodem.modem2.alias]=cell2
DB[qmodem.modem2.enable_dial]=1
DB[c2000max.ethernet.pending]=1
DB[c2000max.ethernet.pending_role]=wan
DB[c2000max.ethernet.pending_wan_mode]=ethernet_5g_balance
DB[c2000max.ethernet.pending_ethernet_weight]=60
DB[c2000max.ethernet.pending_cellular_weight]=40
DB[c2000max.ethernet.pending_cellular_modem]=auto
DB[c2000max.ethernet.pending_resolved_cellular_modem]=modem1
DB[c2000max.ethernet.pending_cellular_interface]=cell1
RELOAD_MODE=success
HNAT_RELOAD_MODE=success
if ! apply_role wan pending-auto-replay ethernet_5g_balance 60 40 auto 1; then
	fail "pending auto selection with multiple offline modems was not replayable"
fi
[[ "${DB[c2000max.ethernet.resolved_cellular_modem]}" == modem1 ]] ||
	fail "pending journal did not reuse its frozen modem selection"
DB[wireless.radio0.disabled]=1
apply_role wan normal-auto-boot ethernet_5g_balance 60 40 auto 0 ||
	fail "normal S98 balance replay did not reuse its persisted auto modem"
[[ "${DB[c2000max.ethernet.resolved_cellular_modem]}" == modem1 ]] ||
	fail "normal S98 replay changed the persisted automatic modem"

reset_lan
RELOAD_MODE=success
RELOAD_CALLS=0
HNAT_RELOAD_MODE=success
HNAT_RELOAD_CALLS=0
touch "$DEGRADED"
apply_role lan degraded-recovery ethernet_only 60 40 auto 1 ||
	fail "existing degraded marker could not be recovered transactionally"
[[ ! -e "$DEGRADED" ]] ||
	fail "verified degraded recovery did not clear the marker"
[[ "$(c2000_actual_role)" == lan ]] ||
	fail "degraded recovery changed the requested LAN role"

reset_lan
RELOAD_MODE=success
HNAT_RELOAD_MODE=success
apply_role lan invalid-wan-settings-rescue invalid 1 2 'bad-name!' 1 ||
	fail "invalid stored WAN settings blocked a forced LAN rescue"
[[ "${DB[c2000max.ethernet.wan_mode]}" == ethernet_only &&
   "${DB[c2000max.ethernet.ethernet_weight]}" == 60 &&
   "${DB[c2000max.ethernet.cellular_weight]}" == 40 &&
   "${DB[c2000max.ethernet.cellular_modem]}" == auto ]] ||
	fail "LAN rescue did not normalize corrupt WAN settings"

reset_lan
DB[network.br_lan.ports]=''
DB[qmodem.main.enable_dial]=0
DB[qmodem.modem1]=modem-device
DB[qmodem.modem1.enable_dial]=0
DB[qmodem.modem2]=modem-device
DB[qmodem.modem2.state]=disabled
DB[qmodem.modem2.enable_dial]=0
QMODEM_RUNNING=0
QMODEM_ENABLED=0
[[ "$(c2000_actual_role)" == inconsistent ]] ||
	fail "repair fixture did not start from an inconsistent topology"
RELOAD_MODE=success
RELOAD_CALLS=0
HNAT_RELOAD_MODE=success
HNAT_RELOAD_CALLS=0
apply_role lan repair-network ethernet_only 60 40 auto 1 1 ||
	fail "repair transaction could not recover inconsistent topology"
[[ "$(c2000_actual_role)" == lan ]] ||
	fail "repair transaction did not restore eth1 to LAN"
[[ "${DB[qmodem.main.enable_dial]}" == 1 ]] ||
	fail "repair transaction did not restore QModem dial intent"
[[ "${DB[qmodem.modem1.enable_dial]}" == 1 &&
   "${DB[qmodem.modem2.enable_dial]}" == 0 ]] ||
	fail "repair did not recover eligible per-device dialing safely"
[[ "$QMODEM_RUNNING:$QMODEM_ENABLED" == 1:1 ]] ||
	fail "repair transaction did not force QModem enabled and running"
[[ "$JOB_STATE:$JOB_SUCCESS" == done:1 ]] ||
	fail "successful repair job was not reported as successful"
[[ "$JOB_MESSAGE" == *"LAN 与 QModem 服务已修复"* ]] ||
	fail "repair job did not report the recovered LAN/QModem state"
[[ ! -e "$DEGRADED" ]] ||
	fail "successful repair left the network degraded marker"

reset_lan
RELOAD_MODE=success
RELOAD_CALLS=0
HNAT_RELOAD_MODE=first_fail
HNAT_RELOAD_CALLS=0
HNAT_EXPECT_NO_PENDING=1
HNAT_EXPECT_ROLE=wan
apply_role wan hnat-nonfatal ethernet_only 60 40 auto 1 ||
	fail "WAN hook-off retry rolled back an otherwise usable network"
[[ "$(c2000_actual_role)" == wan ]] ||
	fail "WAN hook-off retry did not preserve the verified WAN topology"
[[ "${DB[c2000max.ethernet.role]}" == wan ]] ||
	fail "WAN hook-off retry did not persist the verified WAN role"
[[ "${DB[turboacc.config.fastpath]}" == mediatek_hnat ]] ||
	fail "WAN software fallback overwrote the user's LAN HNAT preference"
[[ "$RELOAD_CALLS" == 1 ]] ||
	fail "WAN software-fallback retry unexpectedly rolled back the network"
[[ "$HNAT_RELOAD_CALLS" == 1 ]] ||
	fail "WAN software-fallback path retried inside the network transaction boundary"
[[ -e "$ACCEL_DEGRADED" ]] ||
	fail "WAN hook-off retry did not record a separate acceleration warning"
[[ ! -e "$DEGRADED" ]] ||
	fail "WAN acceleration-only retry incorrectly marked the network degraded"
[[ "$JOB_STATE:$JOB_SUCCESS" == done:1 ]] ||
	fail "usable WAN with verified hook-off was not reported as successful"
[[ "$JOB_MESSAGE" == *"软件流量分载未能完成验证"* &&
   "$JOB_MESSAGE" != *"MediaTek HNAT 运行态验证失败"* ]] ||
	fail "WAN retry warning incorrectly described the software fallback"
HNAT_EXPECT_NO_PENDING=0
HNAT_EXPECT_ROLE=""

# If the post-commit HNAT pass cannot prove hook-off, preserve the committed
# network and clear journal, but report an acceleration-only failure.
reset_lan
RELOAD_MODE=success
RELOAD_CALLS=0
HNAT_RELOAD_MODE=first_fail
HNAT_RELOAD_CALLS=0
HNAT_EXPECT_NO_PENDING=1
HNAT_EXPECT_ROLE=wan
ACCEL_MATCH_MODE=success
ACCEL_MATCH_CALLS=0
FORCE_OFF=0
FORCE_OFF_FAIL_AT=2
if apply_role wan committed-hnat-unknown ethernet_only 60 40 auto 1; then
	fail "post-commit unknown HNAT state was reported as full success"
else
	rc=$?
fi
[[ "$rc" == 2 ]] ||
	fail "post-commit unknown HNAT state returned $rc instead of 2"
[[ "$(c2000_actual_role)" == wan &&
   "${DB[c2000max.ethernet.role]}" == wan ]] ||
	fail "post-commit unknown HNAT state rolled back the verified WAN"
[[ "$RELOAD_CALLS" == 1 ]] ||
	fail "post-commit unknown HNAT state retried or rolled back the network"
[[ ! -v 'DB[c2000max.ethernet.pending]' ]] ||
	fail "post-commit HNAT pass ran before the recovery journal was cleared"
[[ ! -e "$DEGRADED" && -e "$ACCEL_DEGRADED" ]] ||
	fail "post-commit HNAT uncertainty incorrectly degraded the network"
[[ "$JOB_STATE:$JOB_SUCCESS" == failed:0 ]] ||
	fail "post-commit HNAT uncertainty was not reported precisely"
HNAT_EXPECT_NO_PENDING=0
HNAT_EXPECT_ROLE=""
FORCE_OFF_FAIL_AT=0

# Failing the initial acceleration barrier happens before pending/service
# mutation and therefore must leave the current network and uplinks untouched.
reset_lan
RELOAD_MODE=success
RELOAD_CALLS=0
HNAT_RELOAD_MODE=success
HNAT_RELOAD_CALLS=0
FORCE_OFF=0
FORCE_OFF_FAIL_AT=1
if apply_role wan initial-quiesce-unknown ethernet_only 60 40 auto 1; then
	fail "failed initial acceleration barrier unexpectedly switched WAN"
else
	rc=$?
fi
[[ "$rc" == 2 ]] ||
	fail "failed initial acceleration barrier returned $rc instead of 2"
[[ "$(c2000_actual_role)" == lan && "$RELOAD_CALLS" == 0 ]] ||
	fail "failed initial acceleration barrier changed or reloaded LAN"
[[ "$QMODEM_RUNNING:$QMODEM_ENABLED:$MWAN_RUNNING:$MWAN_ENABLED" == 1:1:0:0 ]] ||
	fail "failed initial acceleration barrier changed uplink services"
[[ ! -v 'DB[c2000max.ethernet.pending]' ]] ||
	fail "failed initial acceleration barrier created a recovery journal"
[[ ! -e "$DEGRADED" && -e "$ACCEL_DEGRADED" ]] ||
	fail "failed initial acceleration barrier was not acceleration-only degradation"
FORCE_OFF_FAIL_AT=0

# A journal write failure may leave c2000max UCI deltas, but it occurs before
# service stops and must restore those deltas without a network rollback.
reset_lan
RELOAD_MODE=success
RELOAD_CALLS=0
HNAT_RELOAD_MODE=success
HNAT_RELOAD_CALLS=0
FORCE_OFF=0
FAIL_MATCH='set:c2000max.ethernet.pending=1'
if apply_role wan pending-write-fail ethernet_only 60 40 auto 1; then
	fail "fault-injected pending journal write unexpectedly succeeded"
else
	rc=$?
fi
FAIL_MATCH=""
[[ "$rc" == 1 ]] ||
	fail "pending journal write failure returned $rc instead of 1"
[[ "$(c2000_actual_role)" == lan && "$RELOAD_CALLS" == 0 ]] ||
	fail "pending journal write failure changed or reloaded LAN"
[[ "$QMODEM_RUNNING:$QMODEM_ENABLED:$MWAN_RUNNING:$MWAN_ENABLED" == 1:1:0:0 ]] ||
	fail "pending journal write failure changed uplink services"
[[ ! -v 'DB[c2000max.ethernet.pending]' &&
   ! -v 'DB[c2000max.ethernet.services_override_active]' ]] ||
	fail "pending journal write failure left staged c2000max state"

reset_lan
RELOAD_MODE=success
RELOAD_CALLS=0
HNAT_RELOAD_MODE=success
FORCE_OFF=0
QMODEM_STOP_MODE=first_fail
QMODEM_STOP_CALLS=0
MWAN_STOP_MODE=success
MWAN_STOP_CALLS=0
apply_role wan qmodem-stop-fail ethernet_only 60 40 auto 1 ||
	fail "momentary QModem stop failure vetoed a valid WAN switch"
[[ "$(c2000_actual_role)" == wan ]] ||
	fail "QModem stop timing prevented the WAN topology from applying"
QMODEM_STOP_MODE=success

apply_role lan qmodem-stop-reset ethernet_only 60 40 auto 1 ||
	fail "test fixture could not return from WAN to LAN"
RELOAD_CALLS=0
HNAT_RELOAD_MODE=success
FORCE_OFF=0
QMODEM_STOP_CALLS=0
MWAN_STOP_MODE=first_fail
MWAN_STOP_CALLS=0
apply_role wan mwan-stop-fail ethernet_only 60 40 auto 1 ||
	fail "momentary mwan3 stop failure vetoed a valid WAN switch"
[[ "$(c2000_actual_role)" == wan ]] ||
	fail "mwan3 stop timing prevented the WAN topology from applying"
MWAN_STOP_MODE=success

reset_lan
RELOAD_MODE=always_fail
RELOAD_CALLS=0
HNAT_RELOAD_MODE=success
if apply_role wan rollback-fail ethernet_only 60 40 auto 1; then
	fail "double reload failure unexpectedly succeeded"
else
	rc=$?
fi
[[ "$rc" == 2 ]] || fail "failed rollback returned $rc instead of 2"
[[ -e "$DEGRADED" ]] || fail "failed rollback did not mark degraded"
[[ "$FORCE_OFF" -gt 1 ]] || fail "failed rollback did not force HNAT off"

HNAT_HOTPLUG="$ROOT/../.."/mtk/applications/hnat-detect/files/etc/hotplug.d/iface/99-hnat-detect
grep -q 'ifup|ifdown|update' "$HNAT_HOTPLUG" ||
	fail "C2000 HNAT hotplug does not cover down/update events"
grep -q 'exec /etc/init.d/c2000max-hnat reload' "$HNAT_HOTPLUG" ||
	fail "C2000 HNAT hotplug does not run fail-closed controller convergence"
EQOS_HOTPLUG="$ROOT/../.."/mtk/applications/luci-app-eqos-mtk/root/etc/hotplug.d/iface/10-eqos
grep -q 'exec /etc/init.d/eqos stop' "$EQOS_HOTPLUG" ||
	fail "C2000 EQoS hotplug does not stop unsafe runtime state"
EQOS_INIT="$ROOT/../.."/mtk/applications/luci-app-eqos-mtk/root/etc/init.d/eqos
EQOS_CLI="$ROOT/../.."/mtk/applications/luci-app-eqos-mtk/root/usr/sbin/eqos
source <(awk '$0 != ". /lib/functions/system.sh" { print }' "$EQOS_INIT")

EQOS_SIGNAL_PROBE="$TMP/eqos-signal-probe"
rm -f "$EQOS_SIGNAL_PROBE"
(
	eqos() { : >"$EQOS_SIGNAL_PROBE"; }
	C2000_EQOS_HNAT_HELD=0
	C2000_EQOS_ROLE_HELD=0
	c2000_eqos_signal_abort
) >/dev/null 2>&1 || true
[[ ! -e "$EQOS_SIGNAL_PROBE" ]] ||
	fail "EQoS signal handler changed hardware before owning HNAT"
(
	eqos() { : >"$EQOS_SIGNAL_PROBE"; }
	C2000_EQOS_HNAT_HELD=1
	C2000_EQOS_ROLE_HELD=1
	c2000_eqos_signal_abort
) >/dev/null 2>&1 || true
[[ -e "$EQOS_SIGNAL_PROBE" ]] ||
	fail "EQoS signal handler did not stop EQoS after owning HNAT"

EQOS_LOCK_PROBES=0
eqos_lock_probe()
{
	[[ "$C2000MAX_ACCEL_LOCKS_HELD" == 1 ]] || return 9
	EQOS_LOCK_PROBES=$((EQOS_LOCK_PROBES + 1))
	return "${1:-0}"
}

C2000MAX_ACCEL_LOCKS_HELD=0
HELD["$C2000_ROLE_LOCK"]=0
HELD["$C2000_HNAT_LOCK"]=0
LOCK_TRACE=""
c2000_eqos_run_locked eqos_lock_probe 0 ||
	fail "normal C2000 EQoS worker failed under shared locks"
[[ "$EQOS_LOCK_PROBES" == 1 ]] ||
	fail "normal C2000 EQoS worker was not called exactly once"
[[ "$LOCK_TRACE" == \
	"lock:$C2000_ROLE_LOCK lock:$C2000_HNAT_LOCK -u:$C2000_HNAT_LOCK -u:$C2000_ROLE_LOCK" ]] ||
	fail "EQoS violated ROLE -> HNAT lock order: $LOCK_TRACE"
[[ "${HELD[$C2000_ROLE_LOCK]}" == 0 && "${HELD[$C2000_HNAT_LOCK]}" == 0 ]] ||
	fail "successful EQoS operation leaked a shared lock"
[[ "$C2000MAX_ACCEL_LOCKS_HELD" == 0 ]] ||
	fail "successful EQoS operation leaked its lock-owned marker"

LOCK_TRACE=""
if c2000_eqos_run_locked eqos_lock_probe 7; then
	fail "fault-injected EQoS worker unexpectedly succeeded"
else
	rc=$?
fi
[[ "$rc" == 7 ]] || fail "EQoS worker failure code was not preserved"
[[ "${HELD[$C2000_ROLE_LOCK]}" == 0 && "${HELD[$C2000_HNAT_LOCK]}" == 0 ]] ||
	fail "failed EQoS operation leaked a shared lock"
[[ "$C2000MAX_ACCEL_LOCKS_HELD" == 0 ]] ||
	fail "failed EQoS operation leaked its lock-owned marker"

C2000MAX_ACCEL_LOCKS_HELD=1
LOCK_TRACE=""
c2000_eqos_run_locked eqos_lock_probe 0 ||
	fail "already-owned EQoS worker failed"
[[ -z "$LOCK_TRACE" ]] ||
	fail "already-owned EQoS worker reacquired shared locks"
C2000MAX_ACCEL_LOCKS_HELD=0

grep -q 'require_c2000_accel_locks' "$EQOS_CLI" ||
	fail "direct C2000 EQoS CLI changes are not guarded by shared-lock ownership"
DIRECT_EQOS_ERROR="$TMP/direct-eqos-error"
if (
	set -- stop
	C2000MAX_ACCEL_LOCKS_HELD=0
	source <(awk '$0 != ". /lib/functions.sh" && $0 != ". /lib/functions/system.sh" { print }' "$EQOS_CLI")
) >/dev/null 2>"$DIRECT_EQOS_ERROR"; then
	fail "direct unlocked C2000 EQoS CLI change was accepted"
fi
grep -q 'must be changed through /etc/init.d/eqos' "$DIRECT_EQOS_ERROR" ||
	fail "direct unlocked C2000 EQoS rejection did not explain the lock contract"
grep -q 'C2000MAX_ACCEL_LOCKS_HELD' "$EQOS_INIT" ||
	fail "EQoS init service does not publish nested lock ownership"
HNAT_INIT="$ROOT/files/etc/init.d/c2000max-hnat"
grep -q 'flock -x 4' "$HNAT_INIT" ||
	fail "TurboACC reload does not wait for the port role transaction"
grep -q 'exec 4<>"$ROLE_LOCK"' "$HNAT_INIT" ||
	fail "TurboACC reload does not preserve the shared lock inode"
grep -q 'C2000MAX_ACCEL_LOCKS_HELD' "$HNAT_INIT" ||
	fail "nested EQoS HNAT convergence cannot avoid lock re-entry"
capture_line="$(
	grep -n '^[[:space:]]*capture_transaction_service_state$' "$SCRIPT" |
		head -n1 | cut -d: -f1
)"
active_line="$(
	grep -n '^[[:space:]]*APPLY_ACTIVE=1$' "$SCRIPT" |
		head -n1 | cut -d: -f1
)"
pending_line="$(
	grep -n '^[[:space:]]*elif ! write_pending_marker ' "$SCRIPT" |
		head -n1 | cut -d: -f1
)"
[[ -n "$capture_line" && -n "$active_line" &&
   "$capture_line" -lt "$active_line" ]] ||
	fail "active signal rollback can run before service-state capture"
[[ -n "$pending_line" && "$pending_line" -lt "$active_line" ]] ||
	fail "active rollback begins before the persistent journal succeeds"
UPLINK_INIT="$ROOT/files/etc/init.d/c2000max-uplink"
UPLINK_GUARD="$ROOT/files/etc/init.d/c2000max-uplink-guard"
if grep -Eq 'hook_toggle|qmodem_network.*(stop|disable)|mwan3.*(stop|disable)' \
	"$UPLINK_INIT" "$UPLINK_GUARD"; then
	fail "boot recovery still quarantines HNAT, QModem or mwan3"
fi
grep -q 'c2000_hnat_settings_match' "$HNAT_INIT" ||
	fail "healthy HNAT path does not verify dynamic settings"
grep -q 'HNAT_TOPOLOGY=.*hnat_topology' "$HNAT_INIT" ||
	fail "dedicated controller does not require the atomic topology ABI"
[[ "$(grep -c '> "$HNAT_TOPOLOGY"' "$HNAT_INIT")" == 1 ]] ||
	fail "dedicated controller does not perform exactly one topology write"
if grep -Eq '>.*hnat_(wan|lan|lan2|ppd)_if' "$HNAT_INIT"; then
	fail "dedicated controller contains a legacy per-endpoint write fallback"
fi
[[ "$(grep -c 'hnat_bind_table_empty' "$HNAT_INIT")" -ge 3 ]] ||
	fail "controller does not verify zero BIND entries before and after commit"
DEFAULTS="$ROOT/files/etc/uci-defaults/99-c2000max-defaults"
grep -q 'for wan_network in wan wan6 c2000_wan c2000_wan6' "$DEFAULTS" ||
	fail "permanent standard and managed WAN-zone membership missing"
grep -q 'input=REJECT' "$DEFAULTS" ||
	fail "fail-closed WAN input default missing"
grep -q 'forward=REJECT' "$DEFAULTS" ||
	fail "fail-closed WAN forward default missing"
grep -Fq 'disabled|flow_offloading|mediatek_hnat)' "$DEFAULTS" ||
	fail "board defaults do not preserve all supported acceleration choices"
grep -Fq "*) fastpath='mediatek_hnat' ;;" "$DEFAULTS" ||
	fail "board defaults lost MediaTek HNAT as the fresh-install fallback"
grep -Fq '[ "$effective_fastpath" != flow_offloading ] || flow_offloading=1' \
	"$DEFAULTS" ||
	fail "board defaults do not derive software flow offload from the effective mode"
grep -Fq "flow_offloading_hw='0'" "$DEFAULTS" ||
	fail "board defaults do not force hardware flow offload off"
grep -q '/etc/init.d/mwan3 disable' "$DEFAULTS" ||
	fail "stock mwan3 is not disabled when it has no live interface"
UPLINK_INIT="$ROOT/files/etc/init.d/c2000max-uplink"
grep -q '^START=98$' "$UPLINK_INIT" ||
	fail "boot uplink convergence does not run before QModem S99"
grep -q '"$controller" apply' "$UPLINK_INIT" ||
	fail "boot uplink journal is not replayed synchronously"
if grep -q '"$controller" switch' "$UPLINK_INIT"; then
	fail "boot uplink journal still queues an asynchronous switch"
fi
UPLINK_GUARD="$ROOT/files/etc/init.d/c2000max-uplink-guard"
[[ -f "$UPLINK_GUARD" ]] || fail "V23 guard compatibility stub is missing"
if grep -q 'c2000max-uplink-guard.*$(1)/etc/init.d' "$ROOT/Makefile"; then
	fail "board package still installs the obsolete S18 quarantine service"
fi
grep -q 'c2000max-uplink-guard disable' "$DEFAULTS" ||
	fail "V24 migration does not disable the obsolete S18 quarantine service"
UPLINK_HOTPLUG="$ROOT/files/etc/hotplug.d/iface/98-c2000max-uplink"
grep -q 'ifup|ifdown|connected|disconnected' "$UPLINK_HOTPLUG" ||
	fail "uplink hotplug misses a supported link transition"
grep -q 'uplink-event' "$UPLINK_HOTPLUG" ||
	fail "uplink hotplug does not use lightweight HNAT convergence"
if grep -q ' switch ' "$UPLINK_HOTPLUG"; then
	fail "uplink hotplug still launches a full port-role transaction"
fi
MODEM_SCANNER="$ROOT/../qmodem/application/modem_scan/src/modem_scand.c"
grep -q 'board_balanced' "$MODEM_SCANNER" ||
	fail "new QModem sections can bypass selected-only balanced dialing"
grep -A6 'qmodem_saved_%s' "$MODEM_SCANNER" | grep -q 'uci_set(key, "1")' ||
	fail "new balanced-mode QModem does not preserve its normal dial baseline"
grep -q '#include <sys/file.h>' "$MODEM_SCANNER" ||
	fail "QModem scanner does not use the kernel shared-lock ABI"
scanner_reload_body="$(
	sed -n '/^static void reload_network_serialized(void)/,/^}/p' \
		"$MODEM_SCANNER"
)"
grep -q 'role_lock_acquire()' <<<"$scanner_reload_body" &&
	grep -q 'reload_network();' <<<"$scanner_reload_body" &&
	grep -q 'role_lock_release(role_lock_fd)' <<<"$scanner_reload_body" ||
	fail "QModem reload is not serialized across the complete ROLE lock"
grep -q 'ethernet_only' <<<"$scanner_reload_body" &&
	grep -q 'C2000_SWITCHING' <<<"$scanner_reload_body" ||
	fail "QModem scanner can restart cellular during an active role transaction"
if grep -q 'C2000_DEGRADED\|c2000max.ethernet.pending' \
	<<<"$scanner_reload_body"; then
	fail "stale journal/degraded state still blocks QModem discovery reload"
fi
MAKEFILE="$ROOT/Makefile"
for dependency in firewall4 kmod-mediatek_hnat mtkhnat_util hnat-detect \
	luci-app-turboacc-mtk luci-app-eqos-mtk; do
	grep -q "+$dependency" "$MAKEFILE" ||
		fail "board package runtime dependency is missing: $dependency"
done
for dependency_makefile in \
	"$ROOT/../.."/mtk/applications/hnat-detect/Makefile \
	"$ROOT/../.."/mtk/applications/mtkhnat_util/Makefile \
	"$ROOT/../.."/mtk/applications/luci-app-turboacc-mtk/Makefile \
	"$ROOT/../.."/mtk/applications/luci-app-eqos-mtk/Makefile; do
	if grep -q 'c2000max-board' "$dependency_makefile"; then
		fail "board package dependency cycle found in $dependency_makefile"
	fi
done
grep -q 'c2000max-eqos-locked' "$MAKEFILE" ||
	fail "board package does not install its non-rc.common locked EQoS worker"
EQOS_LOCKED_HELPER_FILE="$ROOT/files/usr/sbin/c2000max-eqos-locked"
grep -q 'C2000MAX_PORT_SWITCH.*=.*1' "$EQOS_LOCKED_HELPER_FILE" ||
	fail "internal EQoS worker does not require port-switch ownership"
grep -q 'C2000MAX_ACCEL_LOCKS_HELD.*=.*1' "$EQOS_LOCKED_HELPER_FILE" ||
	fail "internal EQoS worker does not require shared-lock ownership"
grep -q 'c2000max-hnat-locked' "$MAKEFILE" ||
	fail "board package does not install its non-rc.common locked HNAT worker"
HNAT_LOCKED_HELPER_FILE="$ROOT/files/usr/sbin/c2000max-hnat-locked"
grep -q 'C2000MAX_PORT_SWITCH.*=.*1' "$HNAT_LOCKED_HELPER_FILE" ||
	fail "internal HNAT worker does not require port-switch ownership"
grep -q 'C2000MAX_ACCEL_LOCKS_HELD.*=.*1' "$HNAT_LOCKED_HELPER_FILE" ||
	fail "internal HNAT worker does not require shared-lock ownership"
grep -q '^apply_mode_locked$' "$HNAT_LOCKED_HELPER_FILE" ||
	fail "internal HNAT worker does not call the non-rc controller worker"
grep -q 'HNAT_LOCKED_HELPER' "$SCRIPT" ||
	fail "port transaction does not use the locked HNAT worker"
grep -q 'HNAT_LOCKED_HELPER' "$EQOS_CLI" ||
	fail "EQoS HNAT convergence does not use the locked HNAT worker"
if grep -Fq '/etc/init.d/c2000max-hnat reload' "$SCRIPT" "$EQOS_CLI"; then
	fail "ROLE/HNAT-owned call chain still enters the HNAT rc.common lock"
fi

MOCK_HNAT_INIT="$TMP/mock-c2000max-hnat"
HNAT_HELPER_PROBE="$TMP/hnat-helper-probe"
cat > "$MOCK_HNAT_INIT" <<'EOF'
apply_mode_locked()
{
	printf 'applied\n' > "$HNAT_HELPER_PROBE"
}
EOF
run_hnat_helper()
(
	C2000MAX_PORT_SWITCH="${1:-0}"
	C2000MAX_ACCEL_LOCKS_HELD="${2:-0}"
	C2000_HNAT_INIT="$MOCK_HNAT_INIT"
	source <(awk '$0 != ". /lib/functions.sh" && $0 != ". /lib/functions/system.sh" { print }' \
		"$HNAT_LOCKED_HELPER_FILE")
)
if run_hnat_helper 0 1 >/dev/null 2>&1; then
	fail "locked HNAT helper accepted missing port-switch ownership"
fi
if run_hnat_helper 1 0 >/dev/null 2>&1; then
	fail "locked HNAT helper accepted missing shared-lock ownership"
fi
rm -f "$HNAT_HELPER_PROBE"
run_hnat_helper 1 1 ||
	fail "locked HNAT helper rejected its complete ownership contract"
[[ "$(cat "$HNAT_HELPER_PROBE")" == applied ]] ||
	fail "locked HNAT helper did not call apply_mode_locked"

# Reproduce the historical two-process lock graph.  An ordinary HNAT reload
# holds procd_hnat and waits for ROLE, while a role transaction owns ROLE/HNAT
# and invokes the protected worker.  Both processes must complete: the nested
# path must never wait on procd_hnat.
unset -f flock
PROCD_REAL_LOCK="$TMP/procd-c2000max-hnat.lock"
ROLE_REAL_LOCK="$TMP/role-real.lock"
HNAT_REAL_LOCK="$TMP/hnat-real.lock"
PROCD_READY="$TMP/procd-ready"
ROLE_READY="$TMP/role-ready"
(
	exec 9> "$PROCD_REAL_LOCK"
	flock -x 9
	: > "$PROCD_READY"
	for _ in $(seq 1 200); do
		[[ -e "$ROLE_READY" ]] && break
		/bin/sleep 0.01
	done
	[[ -e "$ROLE_READY" ]] || exit 21
	exec 8> "$ROLE_REAL_LOCK"
	flock -w 2 -x 8
) &
procd_pid=$!
for _ in $(seq 1 200); do
	[[ -e "$PROCD_READY" ]] && break
	/bin/sleep 0.01
done
[[ -e "$PROCD_READY" ]] ||
	fail "two-process lock test could not establish procd_hnat ownership"
(
	exec 7> "$ROLE_REAL_LOCK"
	flock -w 2 -x 7
	exec 6> "$HNAT_REAL_LOCK"
	flock -w 2 -x 6
	: > "$ROLE_READY"
	run_hnat_helper 1 1
) &
role_pid=$!
for _ in $(seq 1 300); do
	if ! kill -0 "$procd_pid" 2>/dev/null &&
	   ! kill -0 "$role_pid" 2>/dev/null; then
		break
	fi
	/bin/sleep 0.01
done
if kill -0 "$procd_pid" 2>/dev/null ||
   kill -0 "$role_pid" 2>/dev/null; then
	kill "$procd_pid" "$role_pid" 2>/dev/null || true
	wait "$procd_pid" "$role_pid" 2>/dev/null || true
	fail "procd_hnat and ROLE/HNAT paths deadlocked"
fi
wait "$procd_pid" ||
	fail "ordinary procd_hnat path failed after role worker released ROLE"
wait "$role_pid" ||
	fail "ROLE/HNAT-owned non-rc HNAT worker failed"

RPCD="$ROOT/files/usr/libexec/rpcd/c2000max"
ACL="$ROOT/files/usr/share/rpcd/acl.d/c2000max.json"
grep -Fq '"port_repair": {}' "$RPCD" ||
	fail "RPC list does not publish the network repair method"
grep -q '^[[:space:]]*port_repair)' "$RPCD" &&
	grep -Fq 'exec /usr/sbin/c2000max-port-role repair' "$RPCD" ||
	fail "RPC repair method does not enter the dedicated CLI repair path"
grep -Fq '"port_repair"' "$ACL" ||
	fail "LuCI ACL does not authorize the network repair method"
grep -q '^[[:space:]]*repair)' "$SCRIPT" &&
	grep -Fq 'queue_role lan "$mode" "$ethernet_weight"' "$SCRIPT" &&
	grep -Fq '"$cellular_weight" "$modem" 1 1' "$SCRIPT" ||
	fail "CLI repair does not queue a forced LAN repair transaction"
grep -Fq '| repair |' "$SCRIPT" ||
	fail "CLI usage does not expose the network repair command"

MENU="$ROOT/files/usr/share/luci/menu.d/c2000max.json"
V31_VIEW="$ROOT/files/www/luci-static/resources/view/c2000max/port_role_v31.js"
[[ -f "$V31_VIEW" ]] || fail "V31 role view is missing"
grep -Fq './files/www/luci-static/resources/view/c2000max/port_role_v31.js $(1)/www/luci-static/resources/view/c2000max/port_role_v31.js' \
	"$MAKEFILE" ||
	fail "package does not install the V31 role view at the LuCI view path"
grep -Fq '"path": "c2000max/port_role_v31"' "$MENU" ||
	fail "LuCI menu does not reference the V31 role view"
if grep -Eq 'port_role_v(20|21|22|23|24|25|26)' "$MENU" ||
	grep -Eq '^[[:space:]]*\$\(INSTALL_(DATA|BIN)\).*port_role_v(20|21|22|23|24|25|26)' "$MAKEFILE"; then
	fail "package metadata still references a stale role view"
fi

for stale_view in 20 21 22 23 24 25 26; do
	grep -Fq "rm -f /www/luci-static/resources/view/c2000max/port_role_v${stale_view}.js" \
		"$DEFAULTS" ||
		fail "V31 migration does not remove the stale V${stale_view} LuCI overlay"
done

if grep -q 'parseInt' "$V31_VIEW"; then
	fail "V31 ratio input accepts fractional values through parseInt"
fi
grep -q 'valueAsNumber' "$V31_VIEW" ||
	fail "V31 ratio input is not validated as an integer"
grep -q 'WAN 和 WAN＋5G 模式关闭 HNAT，但可以使用软件流量分载' "$V31_VIEW" ||
	fail "V31 UI does not disclose the WAN software-flow fallback policy"
grep -q '软件流量分载（HNAT 已关闭）' "$V31_VIEW" ||
	fail "V31 UI cannot report the WAN software-flow runtime"
if grep -Eq '紧急|WHNAT|PPE 端点|MTK GMAC|网络 / WAN 配置 / 服务启动策略' "$V31_VIEW"; then
	fail "V31 UI still exposes emergency wording or low-level diagnostic clutter"
fi
grep -q "method: 'port_repair'" "$V31_VIEW" &&
	grep -q 'repair: async function' "$V31_VIEW" &&
	grep -q "document.getElementById('c2000max-port-repair')" "$V31_VIEW" &&
	grep -q 'this.waitForJob(response.job_id)' "$V31_VIEW" ||
	fail "V31 UI does not conditionally expose and track the repair RPC"
grep -q "E('option'.*'LAN'" "$V31_VIEW" &&
	grep -q "E('option'.*'WAN（仅网口）'" "$V31_VIEW" &&
	grep -q "E('option'.*'WAN＋5G'" "$V31_VIEW" ||
	fail "V31 UI does not offer the three concise port modes"
grep -q 'stale_task' "$V31_VIEW" &&
	grep -q '终止任务并恢复 LAN' "$V31_VIEW" ||
	fail "V31 UI does not expose stale-task recovery"
grep -q 'exec "\$launcher" -S -b -m -p' "$SCRIPT" &&
	grep -q 'terminate_job_process' "$SCRIPT" &&
	grep -q 'reap_orphaned_active_job' "$SCRIPT" ||
	fail "V31 backend does not track, terminate and reap switch jobs"
grep -Fq 'QUEUE_LOCK_WAIT="${C2000_QUEUE_LOCK_WAIT:-30}"' "$SCRIPT" ||
	fail "queue wait does not cover the complete repair cancellation window"
grep -q '^[[:space:]]*exec 9>&-$' "$SCRIPT" ||
	fail "detached apply worker can inherit and retain the queue lock descriptor"
job_status_body="$(sed -n '/^job_status()/,/^}/p' "$SCRIPT")"
grep -q 'queue_lock_try_acquire' <<<"$job_status_body" ||
	fail "job status polling can block the task submission queue"
if grep -q 'queue_lock_acquire' <<<"$job_status_body"; then
	fail "job status polling still uses the blocking queue lock"
fi

TURBOACC_VIEW="$ROOT/../../mtk/applications/luci-app-turboacc-mtk/htdocs/luci-static/resources/view/turboacc.js"
hard_hnat_options="$(
	sed -n '/if (features\.hardHnat) {/,/^[[:space:]]*}/p' "$TURBOACC_VIEW"
)"
grep -Fq "o.value('disabled'" <<<"$hard_hnat_options" &&
	grep -Fq "o.value('flow_offloading'" <<<"$hard_hnat_options" &&
	grep -Fq "o.value('mediatek_hnat'" <<<"$hard_hnat_options" ||
	fail "C2000-MAX TurboACC UI does not offer Disable, software flow and MediaTek HNAT"
if grep -Eq 'readonly[[:space:]]*=[[:space:]]*true' <<<"$hard_hnat_options"; then
	fail "C2000-MAX TurboACC acceleration selector is still read-only"
fi

missing_luci_caches=""
grep -Eq 'rm -f[[:space:]]+/tmp/luci-indexcache\.\*' "$DEFAULTS" ||
	missing_luci_caches="${missing_luci_caches} /tmp/luci-indexcache.*"
grep -Eq 'rm -rf[[:space:]]+/tmp/luci-modulecache/?' "$DEFAULTS" ||
	missing_luci_caches="${missing_luci_caches} /tmp/luci-modulecache/"
[[ -z "$missing_luci_caches" ]] ||
	fail "V31 migration does not clear LuCI cache paths:${missing_luci_caches}"

assert_argon_v31_resources()
{
	local header="$1" label="$2" versioned_count

	[[ -f "$header" ]] || fail "$label Argon header.ut is missing"
	grep -Fq "{{ dispatcher.build_url('admin/translations', dispatcher.lang) }}?v={{ version.luciversion }}-c2000max-v35" \
		"$header" ||
		fail "$label Argon translations URL is missing the c2000max-v35 cache token"
	grep -Fq '{{ resource }}/cbi.js?v={{ version.luciversion }}-c2000max-v35' \
		"$header" ||
		fail "$label Argon cbi.js URL is missing the c2000max-v35 cache token"
	grep -Fq '{{ resource }}/luci.js?v={{ version.luciversion }}-c2000max-v35' \
		"$header" ||
		fail "$label Argon luci.js URL is missing the c2000max-v35 cache token"
	versioned_count="$(
		grep -Ec '<script[[:space:]]+src=.*c2000max-v35' "$header" || true
	)"
	[[ "$versioned_count" == 3 ]] ||
		fail "$label Argon header does not contain exactly three V35-versioned resource URLs"
	if grep -Eq 'c2000max-v(21|22|23|24|25|26|31|34)' "$header"; then
		fail "$label Argon header still contains a stale cache token"
	fi
}

CUSTOM_ARGON_HEADER="$ROOT/../luci-theme-argon/ucode/template/themes/argon/header.ut"
assert_argon_v31_resources "$CUSTOM_ARGON_HEADER" "selected custom"
FEED_ARGON_HEADER="$ROOT/../../../feeds/luci/themes/luci-theme-argon/ucode/template/themes/argon/header.ut"
if [[ -f "$FEED_ARGON_HEADER" ]]; then
	assert_argon_v31_resources "$FEED_ARGON_HEADER" "feed"
fi

FEED_BASE_HEADER="$ROOT/../../../feeds/luci/modules/luci-base/ucode/template/header.ut"
if [[ -f "$FEED_BASE_HEADER" ]]; then
	grep -Fq '{{ resource }}/luci.js?v={# PKG_VERSION #}-{{ pkgs_update_time }}-c2000max-v35' \
		"$FEED_BASE_HEADER" ||
		fail "feed LuCI base header is missing the c2000max-v35 cache token"
	if grep -Eq 'c2000max-v(21|22|23|24|25|26|31|34)' "$FEED_BASE_HEADER"; then
		fail "feed LuCI base header still contains a stale cache token"
	fi
fi

echo 'C2000-MAX port role topology and fault-injection tests passed'
