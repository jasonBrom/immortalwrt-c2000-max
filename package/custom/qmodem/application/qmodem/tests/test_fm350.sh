#!/bin/sh

set -eu

QMODEM_PACKAGE_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
. "${QMODEM_PACKAGE_DIR}/files/usr/share/qmodem/fm350.sh"

manufacturer=fibocom
platform=mediatek
at_port=/dev/ttyUSB3
modem_config=dev0
pdp_type=ipv4v6
pdp_index=3
suggest_pdp_index=0
userset_pdp_index=1
force_set_apn=0
apn=cbnet
fm350_revision='81600.0000.00.29.23.06'
override_at_port=
modem_path=
test_context_mode=normal
test_cached_cid=
test_cached_apn=
test_cached_requested=
test_cached_revision=
test_cached_iccid=
test_current_revision="$fm350_revision"
test_current_iccid=8986001234567890123
at_command_log_file="$(mktemp)"
trap 'rm -f "$at_command_log_file"; [ -z "${TEST_MODEM_RUNDIR:-}" ] || rm -rf "$TEST_MODEM_RUNDIR"' EXIT

sleep()
{
	:
}

m_debug()
{
	:
}

uci()
{
	case "$1:$2" in
		-q:get)
			case "$3" in
				qmodem.dev0.fm350_last_good_cid) printf '%s\n' "$test_cached_cid" ;;
				qmodem.dev0.fm350_last_good_apn) printf '%s\n' "$test_cached_apn" ;;
				qmodem.dev0.fm350_last_requested_cid) printf '%s\n' "$test_cached_requested" ;;
				qmodem.dev0.fm350_last_good_revision) printf '%s\n' "$test_cached_revision" ;;
				qmodem.dev0.fm350_last_good_iccid) printf '%s\n' "$test_cached_iccid" ;;
			esac
			return 0
			;;
		-q:set|-q:commit) return 0 ;;
	esac
	return 0
}

at_timeout()
{
	printf '%s\n' "$2" >> "$at_command_log_file"
	case "$2" in
		'AT+CGDCONT?')
			if [ "$test_context_mode" = query_failed ]; then
				return 1
			elif [ "$test_context_mode" = preserve_auto ]; then
				printf '%s\n' \
					'+CGDCONT: 3,"IPV4V6","cmnet","0.0.0.0",0,0' \
					'OK'
			elif [ "$test_context_mode" = type_rewrite ]; then
				printf '%s\n' \
					'+CGDCONT: 3,"IP","","0.0.0.0",0,0' \
					'OK'
			else
				printf '%s\n' \
					'+CGDCONT: 1,"IPV4V6","IMS","0.0.0.0",0,0' \
					'+CGDCONT: 2,"IPV4V6","ctiot","0.0.0.0",0,0' \
					'+CGDCONT: 3,"IPV4V6","","0.0.0.0",0,0' \
					'OK'
			fi
			;;
		'AT+CGACT?')
			printf '%s\n' '+CGACT: 1,1' 'OK'
			;;
		'AT+CGMR?')
			printf '%s\n' "$test_current_revision" 'OK'
			;;
		'AT+CCID')
			printf '%s\n' "+CCID: $test_current_iccid" 'OK'
			;;
		'AT+CGDCONT=3,"IPV4V6","cbnet"')
			printf '%s\n' 'OK'
			;;
		'AT+CGDCONT=3,"IPV6"')
			printf '%s\n' 'OK'
			;;
		'AT+CGDCONT=3,"IPV4V6","","0.0.0.0",0,0')
			printf '%s\n' 'ERROR'
			;;
		'AT+CGDCONT=3,"IPV4V6",""')
			printf '%s\n' 'OK'
			;;
		'AT+CGACT=1,3')
			if [ "$test_context_mode" = no_carrier ]; then
				printf '%s\n' 'NO CARRIER'
			else
				printf '%s\n' 'OK'
			fi
			;;
		'AT+CGACT=0,3'|'AT+CGDCONT=3')
			printf '%s\n' 'OK'
			;;
		'AT+CGPADDR=3')
			printf '%s\n' \
				'+CGPADDR: 3,"10.17.146.151","0.0.0.0.0.0.0.0.24.14.55.168.255.188.161.146"' \
				'OK'
			;;
		'AT+CGCONTRDP=3')
			printf '%s\n' \
				'+CGCONTRDP: 1,5,"IMS","100.64.0.2.255.255.255.0","100.64.0.1","1.1.1.1","1.0.0.1"' \
				'+CGCONTRDP: 3,5,"cbnet","10.17.146.151.255.255.255.248","10.17.146.150","211.136.17.107","211.136.20.203"' \
				'OK'
			;;
		'AT+GTDNS=3')
			printf '%s\n' \
				'+GTDNS: 1,"1.1.1.1","1.0.0.1"' \
				'+GTDNS: 3,"211.136.17.107","211.136.20.203"' \
				'+GTDNS: 3,"36.9.128.128.0.0.0.0.0.0.0.0.0.0.0.1","36.9.128.128.0.0.0.0.0.0.0.0.0.0.0.2"' \
				'OK'
			;;
		*)
			return 1
			;;
	esac
}

sample='+CGPADDR: 3,"10.17.146.151","0.0.0.0.0.0.0.0.24.14.55.168.255.188.161.146"'
fm350_extract_addresses "$sample" 3
[ "$fm350_ipv4" = '10.17.146.151' ]
[ "$fm350_ipv6" = '0000:0000:0000:0000:180e:37a8:ffbc:a192' ]

fm350_extract_addresses '+CGPADDR: 3,10.17.146.151,0.0.0.0.0.0.0.0.24.14.55.168.255.188.161.146' 3
[ "$fm350_ipv4" = '10.17.146.151' ]
[ "$fm350_ipv6" = '0000:0000:0000:0000:180e:37a8:ffbc:a192' ]
pdp_type=ip
fm350_address_matches_pdp_type
pdp_type=ipv6
fm350_address_matches_pdp_type
pdp_type=ipv4v6
fm350_address_matches_pdp_type
fm350_extract_addresses '+CGPADDR: 3,"0.0.0.0","0.0.0.0.0.0.0.0.24.14.55.168.255.188.161.146"' 3
pdp_type=ip
if fm350_address_matches_pdp_type; then
	printf 'IPv6-only address was accepted for an IPv4 PDP\n' >&2
	exit 1
fi
pdp_type=ipv6
fm350_address_matches_pdp_type
fm350_extract_addresses '+CGPADDR: 3,"10.17.146.151","0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0"' 3
if fm350_address_matches_pdp_type; then
	printf 'IPv4-only address was accepted for an IPv6 PDP\n' >&2
	exit 1
fi
pdp_type=ip
fm350_address_matches_pdp_type
pdp_type=ipv4v6
if fm350_extract_addresses "$sample" 0; then
	exit 1
fi
if fm350_extract_addresses '+CGPADDR: 3,"0.0.0.0","foo::bar"' 3; then
	exit 1
fi
if fm350_extract_addresses '+CGPADDR: 3,"0.0.0.0","1:::2"' 3; then
	printf 'invalid triple-colon IPv6 address was accepted\n' >&2
	exit 1
fi
fm350_response_has_error '+CME ERROR: 50'
fm350_response_has_error 'NO CARRIER'
if fm350_response_has_error 'OK'; then
	exit 1
fi

if fm350_extract_addresses '+CGPADDR: 0,"0.0.0.0","0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0"'; then
	exit 1
fi
[ -z "$fm350_ipv4$fm350_ipv6" ]
pdp_type=ip
if fm350_address_matches_pdp_type; then
	exit 1
fi
pdp_type=ipv4v6

fm350_build_candidates
[ "${fm350_candidates%% *}" = 3 ]
case " $fm350_candidates " in
	*' 1 '*) exit 1 ;;
esac
case " $fm350_candidates " in
	*' 2 '*) printf 'automatic candidate list included the ctiot context\n' >&2; exit 1 ;;
esac

# A cached CID belongs to a specific firmware/SIM/APN tuple.  A stale cache
# must not outrank the currently configured CID after firmware or SIM changes.
test_cached_cid=0
test_cached_apn=cbnet
test_cached_requested=3
test_cached_revision=OLD-FIRMWARE
test_cached_iccid=8986001234567890123
fm350_iccid=8986001234567890123
fm350_build_candidates
[ "${fm350_candidates%% *}" = 3 ]
test_cached_revision="$fm350_revision"
fm350_build_candidates
[ "${fm350_candidates%% *}" = 0 ]
test_cached_iccid=DIFFERENT-SIM
fm350_build_candidates
[ "${fm350_candidates%% *}" = 3 ]
test_cached_cid=
test_cached_apn=
test_cached_requested=
test_cached_revision=
test_cached_iccid=
fm350_iccid=

fm350_activate_candidate 3
[ "$pdp_index" = 3 ]
[ "$ipv4" = '10.17.146.151' ]
[ "$ipv6" = '0000:0000:0000:0000:180e:37a8:ffbc:a192' ]

fm350_read_runtime_parameters
[ "$fm350_runtime_ipv4" = '10.17.146.151' ]
[ "$fm350_runtime_netmask" = '255.255.255.248' ]
[ "$fm350_runtime_gateway" = '10.17.146.150' ]
for expected_dns in \
	211.136.17.107 \
	211.136.20.203 \
	2409:8080:0000:0000:0000:0000:0000:0001 \
	2409:8080:0000:0000:0000:0000:0000:0002; do
	case " $fm350_runtime_dns " in
		*" $expected_dns "*) ;;
		*) printf 'missing DNS %s in: %s\n' "$expected_dns" "$fm350_runtime_dns" >&2; exit 1 ;;
	esac
done
case " $fm350_runtime_dns " in
	*' 1.1.1.1 '*|*' 1.0.0.1 '*)
		printf 'runtime parser accepted DNS from the wrong CID: %s\n' "$fm350_runtime_dns" >&2
		exit 1
		;;
esac

# A stop/restart process may use the cached working fallback CID only after
# binding it to the currently attached firmware or SIM.
test_cached_cid=3
test_cached_revision="$fm350_revision"
test_cached_iccid="$test_current_iccid"
[ "$(fm350_cached_cid_for_hang)" = 3 ]
test_current_iccid=8901000000000000000
if fm350_cached_cid_for_hang >/dev/null 2>&1; then
	printf 'hang path accepted a cached CID from a different SIM\n' >&2
	exit 1
fi
test_current_iccid=8986001234567890123
test_cached_cid=
test_cached_revision=
test_cached_iccid=

# A safe empty context with the wrong PDP type may be adapted to the explicit
# requested family, rather than failing every pre-created context.
test_context_mode=type_rewrite
apn=auto
pdp_type=ipv6
: > "$at_command_log_file"
fm350_build_candidates
fm350_activate_candidate 3
case "$(cat "$at_command_log_file")" in
	*'AT+CGDCONT=3,"IPV6"'*) ;;
	*) printf 'safe empty context PDP type was not adapted\n' >&2; exit 1 ;;
esac

# Automatic APN must activate an existing operator context without clearing it.
test_context_mode=preserve_auto
apn=auto
pdp_type=ipv4v6
: > "$at_command_log_file"
fm350_build_candidates
fm350_activate_candidate 3
at_command_log="$(cat "$at_command_log_file")"
case "$at_command_log" in
	*'AT+CGDCONT=3,'*)
		printf 'automatic APN unexpectedly rewrote the existing context\n' >&2
		exit 1
		;;
esac
case "$at_command_log" in
	*'AT+CGACT=1,3'*) ;;
	*) printf 'automatic APN did not activate CID 3\n' >&2; exit 1 ;;
esac

# A missing context inventory may be probed, but must never be treated as an
# empty context or expand into the commonly reserved CID 1/2.
test_context_mode=query_failed
apn=cbnet
pdp_index=1
fm350_configured_cid=1
suggest_pdp_index=0
test_cached_cid=2
test_cached_apn=cbnet
test_cached_requested=1
test_cached_revision="$fm350_revision"
test_cached_iccid="$test_current_iccid"
fm350_iccid="$test_current_iccid"
: > "$at_command_log_file"
fm350_build_candidates
[ "$fm350_contexts_valid" = 0 ]
case " $fm350_candidates " in
	*' 1 '*|*' 2 '*) printf 'unsafe candidate after failed CGDCONT query: %s\n' "$fm350_candidates" >&2; exit 1 ;;
esac
[ "$fm350_candidates" = '0 3' ]
fm350_activate_candidate 3
case "$(cat "$at_command_log_file")" in
	*'AT+CGDCONT=3,'*) printf 'invalid inventory allowed a persistent context rewrite\n' >&2; exit 1 ;;
esac
test_cached_cid=
test_cached_apn=
test_cached_requested=
test_cached_revision=
test_cached_iccid=
fm350_iccid=
pdp_index=3
fm350_configured_cid=3

# Legacy configurations used upper-case or empty PDP values.  Normalize them
# before set_if computes env4/env6.
MODEM_DIAL_SH="${QMODEM_PACKAGE_DIR}/files/usr/share/qmodem/modem_dial.sh"
eval "$(sed -n '/^normalize_pdp_type()/,/^}/p' "$MODEM_DIAL_SH")"
[ "$(normalize_pdp_type IPV4V6)" = ipv4v6 ]
[ "$(normalize_pdp_type ipv6)" = ipv6 ]
[ "$(normalize_pdp_type IPV4)" = ip ]
[ "$(normalize_pdp_type '')" = ipv4v6 ]
[ "$(normalize_pdp_type vendor-value)" = ipv4v6 ]

# A modem command can return a shell success status together with +CME ERROR.
# Treat that as a rejected PIN and persist the per-boot retry guard.
TEST_MODEM_RUNDIR="$(mktemp -d)"
MODEM_RUNDIR="$TEST_MODEM_RUNDIR"
mkdir -p "$MODEM_RUNDIR/${modem_config}_dir"
eval "$(sed -n '/^unlock_sim()/,/^}/p' "$MODEM_DIAL_SH")"
lock()
{
	:
}
test_pin_response='+CME ERROR: 16'
test_pin_log="$TEST_MODEM_RUNDIR/pin-at.log"
at()
{
	printf '%s\n' "$*" >> "$test_pin_log"
	printf '%s\n' "$test_pin_response"
	return 0
}
if unlock_sim 1234; then
	printf 'CME PIN error was accepted as success\n' >&2
	exit 1
fi
[ "$(cat "$MODEM_RUNDIR/${modem_config}_dir/pincode")" = 1234 ]
pin_attempts_before="$(wc -l < "$test_pin_log")"
if unlock_sim 1234; then
	printf 'guarded PIN retry was accepted\n' >&2
	exit 1
fi
[ "$(wc -l < "$test_pin_log")" = "$pin_attempts_before" ]
test_pin_response=OK
unlock_sim 5678
[ ! -e "$MODEM_RUNDIR/${modem_config}_dir/pincode" ]

# PCIe MBIM must omit --apn for empty/auto settings instead of sending the
# literal string "auto" to the modem.
eval "$(sed -n '/^fm350_mbim_connect()/,/^}/p' "$MODEM_DIAL_SH")"
test_umbim_log="$TEST_MODEM_RUNDIR/umbim.log"
umbim()
{
	printf '%s\n' "$*" >> "$test_umbim_log"
}
fm350_mbim_connect /dev/wwan0mbim IPV4V6 '' none '' ''
fm350_mbim_connect /dev/wwan0mbim ip AUTO none '' ''
fm350_mbim_connect /dev/wwan0mbim ipv6 cbnet MsChapV2 alice secret
grep ' connect ' "$test_umbim_log" > "$TEST_MODEM_RUNDIR/mbim-connect.log"
[ "$(sed -n '1p' "$TEST_MODEM_RUNDIR/mbim-connect.log")" = '-n -t 7 -d /dev/wwan0mbim connect ipv4v6:   ' ]
[ "$(sed -n '2p' "$TEST_MODEM_RUNDIR/mbim-connect.log")" = '-n -t 7 -d /dev/wwan0mbim connect ipv4:   ' ]
[ "$(sed -n '3p' "$TEST_MODEM_RUNDIR/mbim-connect.log")" = '-n -t 7 -d /dev/wwan0mbim connect ipv6:cbnet mschapv2 alice secret' ]
rm -rf "$TEST_MODEM_RUNDIR"

# Explicit activation errors must not accept a stale CGPADDR result.
test_context_mode=no_carrier
fm350_contexts='+CGDCONT: 3,"IPV4V6","","0.0.0.0",0,0'
fm350_context_snapshot="$fm350_contexts"
fm350_contexts="$(fm350_context_records "$fm350_contexts")"
fm350_contexts_valid=1
fm350_active_contexts=
: > "$at_command_log_file"
if fm350_activate_candidate 3; then
	printf 'NO CARRIER was accepted as a successful activation\n' >&2
	exit 1
fi
case "$(cat "$at_command_log_file")" in
	*'AT+CGACT=0,3'*'AT+CGDCONT=3,"IPV4V6","","0.0.0.0",0,0'*'AT+CGDCONT=3,"IPV4V6",""'*) ;;
	*) printf 'failed activation did not deactivate and restore CID 3 with fallback\n' >&2; exit 1 ;;
esac

[ "$(fm350_prefix_to_netmask 0)" = '0.0.0.0' ]
[ "$(fm350_prefix_to_netmask 24)" = '255.255.255.0' ]
[ "$(fm350_prefix_to_netmask 29)" = '255.255.255.248' ]
[ "$(fm350_prefix_to_netmask 32)" = '255.255.255.255' ]
[ "$(fm350_netmask_to_prefix 255.255.255.248)" = 29 ]
if fm350_netmask_to_prefix 255.0.255.0 >/dev/null 2>&1; then
	exit 1
fi
if fm350_prefix_to_netmask 33 >/dev/null 2>&1; then
	exit 1
fi

# MBIM config parsing must preserve IPv6 colons and apply the static tuple
# exposed by FM350/RW350 PCIe firmware.
eval "$(sed -n '/^fm350_mbim_field()/,/^}/p' "$MODEM_DIAL_SH")"
eval "$(sed -n '/^fm350_apply_mbim_ipv6_config()/,/^}/p' "$MODEM_DIAL_SH")"
mbim_config_sample='ipv4address: 10.17.146.151/29
ipv4gateway: 10.17.146.150
ipv6address: 2409:8123:4567:8900::10/64
ipv6gateway: fe80::1
ipv6dnsserver: 2409:8088::a
ipv6dnsserver: 2409:8088::b'
[ "$(fm350_mbim_field ipv4address "$mbim_config_sample")" = '10.17.146.151/29' ]
[ "$(fm350_mbim_field ipv6gateway "$mbim_config_sample")" = 'fe80::1' ]
[ "$(fm350_mbim_field ipv6dnsserver "$mbim_config_sample")" = '2409:8088::a
2409:8088::b' ]
TEST_MODEM_RUNDIR="$(mktemp -d)"
test_uci_log="$TEST_MODEM_RUNDIR/uci.log"
uci()
{
	printf '%s\n' "$*" >> "$test_uci_log"
	return 0
}
ifdown()
{
	return 0
}
ifup()
{
	return 0
}
interface_name=dev0
interface6_name=dev0v6
metric=10
env6=1
ipv6=2409:8123:4567:8900::10
do_not_add_dns=0
dns_list=
fm350_apply_mbim_ipv6_config "$mbim_config_sample"
grep -qF 'set network.dev0v6.proto=static' "$test_uci_log"
grep -qF 'add_list network.dev0v6.ip6addr=2409:8123:4567:8900::10/64' "$test_uci_log"
grep -qF 'set network.dev0v6.ip6gw=fe80::1' "$test_uci_log"
grep -qF 'add_list network.dev0v6.dns=2409:8088::a' "$test_uci_log"
: > "$test_uci_log"
mbim_config_no_gateway="$(printf '%s\n' "$mbim_config_sample" | grep -v '^ipv6gateway:')"
fm350_apply_mbim_ipv6_config "$mbim_config_no_gateway"
grep -qF 'set network.dev0v6.proto=static' "$test_uci_log"
if grep -qF 'set network.dev0v6.ip6gw=' "$test_uci_log"; then
	printf 'gateway-less point-to-point MBIM tuple wrote an invalid gateway\n' >&2
	exit 1
fi
: > "$test_uci_log"
if fm350_apply_mbim_ipv6_config 'ipv6address: broken/64'; then
	printf 'invalid MBIM IPv6 tuple was accepted\n' >&2
	exit 1
fi
[ ! -s "$test_uci_log" ]
: > "$test_uci_log"
ipv6=
fm350_apply_mbim_ipv6_config "$mbim_config_sample"
grep -qF 'set network.dev0v6.proto=dhcpv6' "$test_uci_log"
rm -rf "$TEST_MODEM_RUNDIR"

echo 'FM350 compatibility tests passed'
