#!/bin/sh

# FM350 firmware families disagree about the usable PDP context.  Keep the
# compatibility logic here instead of teaching the generic dialer that one CID
# is universally correct.

fm350_is_modem()
{
	[ "$manufacturer" = "fibocom" ] && [ "$platform" = "mediatek" ]
}

fm350_is_uint()
{
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	return 0
}

fm350_is_valid_ipv4()
{
	local ip="$1" old_ifs="$IFS" octet count=0

	[ "$ip" != "0.0.0.0" ] || return 1
	IFS=.
	set -- $ip
	IFS="$old_ifs"
	[ "$#" -eq 4 ] || return 1
	for octet in "$@"; do
		fm350_is_uint "$octet" || return 1
		[ "$octet" -le 255 ] || return 1
		count=$((count + 1))
	done
	[ "$count" -eq 4 ]
}

fm350_netmask_to_prefix()
{
	awk -v value="$1" '
	BEGIN {
		n = split(value, octet, ".")
		if (n != 4)
			exit 1
		prefix = 0
		seen_partial = 0
		for (i = 1; i <= 4; i++) {
			if (octet[i] == 255) bits = 8
			else if (octet[i] == 254) bits = 7
			else if (octet[i] == 252) bits = 6
			else if (octet[i] == 248) bits = 5
			else if (octet[i] == 240) bits = 4
			else if (octet[i] == 224) bits = 3
			else if (octet[i] == 192) bits = 2
			else if (octet[i] == 128) bits = 1
			else if (octet[i] == 0) bits = 0
			else exit 1
			if (seen_partial && bits != 0)
				exit 1
			if (bits != 8)
				seen_partial = 1
			prefix += bits
		}
		print prefix
	}'
}

fm350_dotted_ipv6()
{
	awk -v value="$1" '
	BEGIN {
		n = split(value, byte, ".")
		if (n != 16)
			exit 1
		nonzero = 0
		for (i = 1; i <= 16; i++) {
			if (byte[i] !~ /^[0-9]+$/ || byte[i] < 0 || byte[i] > 255)
				exit 1
			if (byte[i] != 0)
				nonzero = 1
		}
		if (!nonzero)
			exit 1
		for (i = 1; i <= 16; i += 2) {
			if (i > 1)
				printf ":"
			printf "%02x%02x", byte[i], byte[i + 1]
		}
		printf "\n"
	}'
}

fm350_colon_ipv6()
{
	awk -v value="$1" '
	BEGIN {
		if (value !~ /^[0-9A-Fa-f:]+$/)
			exit 1
		if (value ~ /:::/ ||
		    (value ~ /^:/ && value !~ /^::/) ||
		    (value ~ /:$/ && value !~ /::$/))
			exit 1
		tmp = value
		double_colons = gsub(/::/, "", tmp)
		if (double_colons > 1)
			exit 1
		n = split(value, group, ":")
		nonempty = 0
		nonzero = 0
		for (i = 1; i <= n; i++) {
			if (group[i] == "")
				continue
			if (length(group[i]) > 4 || group[i] !~ /^[0-9A-Fa-f]+$/)
				exit 1
			nonempty++
			if (group[i] !~ /^0+$/)
				nonzero = 1
		}
		if ((double_colons == 0 && nonempty != 8) ||
		    (double_colons == 1 && nonempty >= 8) || !nonzero)
			exit 1
		print tolower(value)
	}'
}

fm350_response_has_error()
{
	printf '%s\n' "$1" |
		grep -qiE '(^|[[:space:]])(ERROR|[+]CME ERROR|[+]CMS ERROR|NO CARRIER|NO DIALTONE|BUSY)(:|[[:space:]]|$)'
}

fm350_extract_addresses()
{
	local response="$1" expected_cid="${2:-}" field old_ifs ipv6_candidate

	fm350_ipv4=""
	fm350_ipv6=""
	old_ifs="$IFS"
	IFS='
'
	for field in $(printf '%s\n' "$response" |
		awk -v wanted="$expected_cid" '
		function trim(value) {
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
			if (value ~ /^".*"$/) {
				sub(/^"/, "", value)
				sub(/"$/, "", value)
			}
			return value
		}
		/\+CGPADDR:/ {
			line = $0
			sub(/\r$/, "", line)
			sub(/^.*\+CGPADDR:[[:space:]]*/, "", line)
			n = split(line, part, ",")
			cid = trim(part[1])
			if (wanted != "" && cid != wanted)
				next
			for (i = 2; i <= n; i++)
				print trim(part[i])
		}'); do
		if [ -z "$fm350_ipv4" ] && fm350_is_valid_ipv4 "$field"; then
			fm350_ipv4="$field"
			continue
		fi
		case "$field" in
			*:* )
				ipv6_candidate="$(fm350_colon_ipv6 "$field" 2>/dev/null)" ||
					ipv6_candidate=""
				[ -n "$ipv6_candidate" ] && fm350_ipv6="$ipv6_candidate"
				;;
			*.*.*.*.*.*.*.*.*.*.*.*.*.*.*.*)
				ipv6_candidate="$(fm350_dotted_ipv6 "$field" 2>/dev/null)" ||
					ipv6_candidate=""
				[ -n "$ipv6_candidate" ] && fm350_ipv6="$ipv6_candidate"
				;;
		esac
	done
	IFS="$old_ifs"

	[ -n "$fm350_ipv4$fm350_ipv6" ]
}

fm350_query_addresses()
{
	local cid="$1"

	fm350_address_response="$(at_timeout "$at_port" "AT+CGPADDR=$cid" 8 2>&1)"
	fm350_address_rc=$?
	[ "$fm350_address_rc" -eq 0 ] || return 1
	fm350_response_has_error "$fm350_address_response" && return 1
	fm350_extract_addresses "$fm350_address_response" "$cid"
}

fm350_address_matches_pdp_type()
{
	local type

	type="$(printf '%s' "${pdp_type:-IPV4V6}" | tr 'a-z' 'A-Z')"
	case "$type" in
		IP)
			[ -n "$fm350_ipv4" ]
			;;
		IPV6)
			[ -n "$fm350_ipv6" ]
			;;
		IPV4V6)
			# Some operator profiles deliberately fall back to one family.
			[ -n "$fm350_ipv4$fm350_ipv6" ]
			;;
		*)
			[ -n "$fm350_ipv4" ]
			;;
	esac
}

fm350_context_records()
{
	printf '%s\n' "$1" | awk -F',' '
	/\+CGDCONT:/ {
		cid = $1
		sub(/^.*\+CGDCONT:[[:space:]]*/, "", cid)
		gsub(/[[:space:]]/, "", cid)
		type = $2
		apn = $3
		gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", type)
		gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", apn)
		if (cid ~ /^[0-9]+$/)
			print cid "|" type "|" apn
	}'
}

fm350_context_apn()
{
	local wanted="$1" record cid apn old_ifs="$IFS"

	IFS='
'
	for record in $fm350_contexts; do
		cid="${record%%|*}"
		[ "$cid" = "$wanted" ] || continue
		apn="${record#*|}"
		apn="${apn#*|}"
		printf '%s\n' "$apn"
		IFS="$old_ifs"
		return 0
	done
	IFS="$old_ifs"
	# An absent context is represented by an empty APN and is safe to probe.
	return 0
}

fm350_context_type()
{
	local wanted="$1" record cid type old_ifs="$IFS"

	IFS='
'
	for record in $fm350_contexts; do
		cid="${record%%|*}"
		[ "$cid" = "$wanted" ] || continue
		type="${record#*|}"
		type="${type%%|*}"
		printf '%s\n' "$type"
		IFS="$old_ifs"
		return 0
	done
	IFS="$old_ifs"
	return 1
}

fm350_context_exists()
{
	local wanted="$1" record cid old_ifs="$IFS"

	IFS='
'
	for record in $fm350_contexts; do
		cid="${record%%|*}"
		if [ "$cid" = "$wanted" ]; then
			IFS="$old_ifs"
			return 0
		fi
	done
	IFS="$old_ifs"
	return 1
}

fm350_context_definition()
{
	local wanted="$1"

	printf '%s\n' "$fm350_context_snapshot" | awk -v wanted="$wanted" '
	/\+CGDCONT:/ {
		line = $0
		sub(/\r$/, "", line)
		sub(/^.*\+CGDCONT:[[:space:]]*/, "", line)
		cid = line
		sub(/,.*/, "", cid)
		gsub(/[[:space:]]/, "", cid)
		if (cid == wanted) {
			print line
			exit
		}
	}'
}

fm350_reserved_apn()
{
	local value
	value="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
	case "$value" in
		ims|ims.*|xcap|xcap.*|sos|sos.*|emergency|emergency.*)
			return 0
			;;
	esac
	return 1
}

fm350_candidate_apn_allowed()
{
	local existing requested

	existing="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
	requested="$(printf '%s' "$apn" | tr 'A-Z' 'a-z')"
	[ "$requested" = auto ] && requested=""
	fm350_reserved_apn "$existing" && return 1
	case "$existing" in
		ctiot|ctiot.*)
			[ "$requested" = "$existing" ] || return 1
			;;
	esac
	return 0
}

fm350_add_candidate()
{
	local cid="$1" existing_apn

	fm350_is_uint "$cid" || return 0
	[ "$cid" -le 15 ] || return 0
	# When CGDCONT? failed, the modem has not proven that any context is
	# available for general data.  In particular, never trust an old
	# configured/cached CID 1 or 2: OEM profiles commonly reserve those for
	# IMS and operator services.  Only the two FM350 data CIDs seen across
	# known firmware families are safe to probe without rewriting.
	if [ "$fm350_contexts_valid" != "1" ]; then
		case "$cid" in
			0|3) ;;
			*) return 0 ;;
		esac
	fi
	case " $fm350_candidates " in
		*" $cid "*) return 0 ;;
	esac
	existing_apn="$(fm350_context_apn "$cid" 2>/dev/null)"
	fm350_candidate_apn_allowed "$existing_apn" || return 0
	fm350_candidates="${fm350_candidates}${fm350_candidates:+ }$cid"
}

fm350_add_at_port()
{
	local port="$1"

	case "$port" in
		/dev/ttyUSB*|/dev/ttyACM*|/dev/wwan*at*) ;;
		*) return 0 ;;
	esac
	case " $fm350_at_ports " in
		*" $port "*) return 0 ;;
	esac
	fm350_at_ports="${fm350_at_ports}${fm350_at_ports:+ }$port"
}

fm350_build_at_ports()
{
	local cached_port candidate valid_ports

	fm350_at_ports=""
	if [ -n "$override_at_port" ]; then
		fm350_add_at_port "$override_at_port"
		return
	fi

	cached_port="$(uci -q get "qmodem.${modem_config}.fm350_last_good_at_port")"
	valid_ports="$(uci -q get "qmodem.${modem_config}.valid_at_ports")"
	if [ -n "$cached_port" ] && [ -e "$cached_port" ] &&
	   { [ "$cached_port" = "$at_port" ] ||
	     case " $valid_ports " in *" $cached_port "*) true ;; *) false ;; esac; }; then
		fm350_add_at_port "$cached_port"
	fi
	# The USB composition documented for FM350 and field reports commonly use
	# ttyUSB3 as the stable control port after RNDIS activation.  Prefer it only
	# when this modem's scanner already proved that exact device is an AT port.
	case " $valid_ports " in
		*" /dev/ttyUSB3 "*) [ -e /dev/ttyUSB3 ] && fm350_add_at_port /dev/ttyUSB3 ;;
	esac
	fm350_add_at_port "$at_port"
	for candidate in $valid_ports; do
		[ -e "$candidate" ] && fm350_add_at_port "$candidate"
	done
	if [ -n "$modem_path" ] && [ -d "$modem_path" ]; then
		for candidate in $(find "$modem_path" -type d \
			\( -name 'ttyUSB*' -o -name 'ttyACM*' -o -name '*at*' \) \
			2>/dev/null | sed 's#^.*/#/dev/#' | sort -u); do
			[ -e "$candidate" ] && fm350_add_at_port "$candidate"
		done
	fi
}

fm350_build_candidates()
{
	local response active record cid context_apn requested_apn cached_cid
	local cached_apn cached_requested cached_revision cached_iccid current_revision
	local cache_identity_ok=1 old_ifs="$IFS"

	if response="$(at_timeout "$at_port" "AT+CGDCONT?" 8 2>&1)"; then
		fm350_contexts_rc=0
	else
		fm350_contexts_rc=$?
	fi
	fm350_contexts_valid=0
	fm350_contexts=""
	fm350_context_snapshot=""
	if [ "$fm350_contexts_rc" -eq 0 ] &&
	   ! fm350_response_has_error "$response" &&
	   printf '%s\n' "$response" | grep -q '+CGDCONT:'; then
		fm350_context_snapshot="$response"
		fm350_contexts="$(fm350_context_records "$response")"
		[ -n "$fm350_contexts" ] && fm350_contexts_valid=1
	fi
	active="$(at_timeout "$at_port" "AT+CGACT?" 8 2>&1 |
		awk -F'[:,]' '/\+CGACT:/ {
			gsub(/[[:space:]]/, "", $2)
			gsub(/[[:space:]]/, "", $3)
			if ($2 ~ /^[0-9]+$/ && $3 == 1) print $2
		}')"
	fm350_active_contexts="$active"
	fm350_candidates=""
	requested_apn="$(printf '%s' "$apn" | tr 'A-Z' 'a-z')"
	[ "$requested_apn" = "auto" ] && requested_apn=""

	cached_cid="$(uci -q get "qmodem.${modem_config}.fm350_last_good_cid")"
	cached_apn="$(uci -q get "qmodem.${modem_config}.fm350_last_good_apn")"
	cached_requested="$(uci -q get "qmodem.${modem_config}.fm350_last_requested_cid")"
	cached_revision="$(uci -q get "qmodem.${modem_config}.fm350_last_good_revision")"
	cached_iccid="$(uci -q get "qmodem.${modem_config}.fm350_last_good_iccid")"
	current_revision="$(printf '%s\n' "$fm350_revision" |
		sed '/^AT/d; /^OK$/d; /^[[:space:]]*$/d' |
		head -n 1 | tr -d '\r' | cut -c1-80)"
	cached_apn="$(printf '%s' "$cached_apn" | tr 'A-Z' 'a-z')"
	if [ -n "$cached_revision" ] && [ "$cached_revision" != "$current_revision" ]; then
		cache_identity_ok=0
	fi
	if [ -n "$cached_iccid" ] && [ "$cached_iccid" != "$fm350_iccid" ]; then
		cache_identity_ok=0
	fi
	if [ -n "$cached_cid" ] &&
	   [ "$cache_identity_ok" = "1" ] &&
	   [ "$cached_requested" = "${fm350_configured_cid:-$pdp_index}" ] &&
	   { [ "$cached_apn" = "$requested_apn" ] || [ -z "$requested_apn" ]; }; then
		fm350_add_candidate "$cached_cid"
	fi

	# A configured CID is a first-choice hint on first use or after the user
	# changes it, not a permanent lock.  Once a fallback succeeds, the cached
	# working tuple takes priority on following reconnects.
	[ -n "$pdp_index" ] && fm350_add_candidate "$pdp_index"

	if [ -n "$cached_cid" ] &&
	   [ "$cache_identity_ok" = "1" ] &&
	   { [ "$cached_apn" = "$requested_apn" ] || [ -z "$requested_apn" ]; }; then
		fm350_add_candidate "$cached_cid"
	fi

	# A failed/empty CGDCONT query is not proof that a context is free.  Probe
	# likely contexts without rewriting them, and never touch CID 1/2 until a
	# complete inventory proves they are not IMS/operator-reserved.
	if [ "$fm350_contexts_valid" != "1" ]; then
		[ -n "$suggest_pdp_index" ] && fm350_add_candidate "$suggest_pdp_index"
		fm350_add_candidate 0
		fm350_add_candidate 3
		return
	fi

	# Prefer an exact APN match before merely active contexts.  OEM firmware
	# commonly leaves IMS active on CID 1, which must never become the data CID.
	IFS='
'
	for record in $fm350_contexts; do
		cid="${record%%|*}"
		context_apn="${record#*|}"
		context_apn="${context_apn#*|}"
		if [ -n "$requested_apn" ] &&
		   [ "$(printf '%s' "$context_apn" | tr 'A-Z' 'a-z')" = "$requested_apn" ]; then
			fm350_add_candidate "$cid"
		fi
	done
	for cid in $active; do
		fm350_add_candidate "$cid"
	done
	IFS="$old_ifs"

	# Empty contexts are safe to program.  If APN is automatic, existing
	# non-reserved data contexts are also valid candidates.
	IFS='
'
	for record in $fm350_contexts; do
		cid="${record%%|*}"
		context_apn="${record#*|}"
		context_apn="${context_apn#*|}"
		[ -z "$context_apn" ] && fm350_add_candidate "$cid"
	done
	if [ -z "$requested_apn" ]; then
		for record in $fm350_contexts; do
			cid="${record%%|*}"
			context_apn="${record#*|}"
			context_apn="${context_apn#*|}"
			fm350_reserved_apn "$context_apn" || fm350_add_candidate "$cid"
		done
	fi
	IFS="$old_ifs"

	[ -n "$suggest_pdp_index" ] && fm350_add_candidate "$suggest_pdp_index"
	# Known FM350 firmware families use both zero-based and three-based data
	# contexts.  Only absent/empty non-reserved contexts will be programmed.
	for cid in 0 3 2 1; do
		fm350_add_candidate "$cid"
	done
}

fm350_escape_at_string()
{
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

fm350_activate_candidate()
{
	local cid="$1" context_apn requested_apn requested_lower context_lower
	local type command response attempt activation_rc config_rc configure_context=0
	local context_existed=0 original_type="" original_definition="" context_changed=0
	local context_type type_change_safe=0 command_apn

	context_apn="$(fm350_context_apn "$cid" 2>/dev/null)"
	if fm350_context_exists "$cid"; then
		context_existed=1
		original_type="$(fm350_context_type "$cid" 2>/dev/null)"
		original_definition="$(fm350_context_definition "$cid" 2>/dev/null)"
	fi
	requested_apn="$apn"
	[ "$requested_apn" = "auto" ] && requested_apn=""
	requested_lower="$(printf '%s' "$requested_apn" | tr 'A-Z' 'a-z')"
	context_lower="$(printf '%s' "$context_apn" | tr 'A-Z' 'a-z')"

	fm350_reserved_apn "$context_apn" && return 1
	if [ -n "$requested_apn" ] && [ -n "$context_apn" ] &&
	   [ "$requested_lower" != "$context_lower" ] &&
	   [ "$force_set_apn" != "1" ]; then
		return 1
	fi
	if [ -n "$requested_apn" ] && [ -n "$context_apn" ] &&
	   [ "$requested_lower" != "$context_lower" ] &&
	   { [ "$userset_pdp_index" != "1" ] ||
	     [ "$cid" != "$fm350_configured_cid" ]; }; then
		return 1
	fi

	type="$(printf '%s' "${pdp_type:-IPV4V6}" | tr 'a-z' 'A-Z')"
	case "$type" in
		IP|IPV6|IPV4V6) ;;
		*) type="IPV4V6" ;;
	esac
	context_type="$(printf '%s' "$original_type" | tr 'a-z' 'A-Z')"
	if [ -z "$context_apn" ] ||
	   { [ -n "$requested_apn" ] && [ "$requested_lower" = "$context_lower" ]; }; then
		type_change_safe=1
	fi

	# An empty/automatic APN means "use the modem/operator context".  Never
	# erase an existing APN in that mode.  Only create an absent context, or
	# rewrite one when the user supplied a concrete APN.
	if [ "$fm350_contexts_valid" != "1" ]; then
		configure_context=0
	elif [ "$context_existed" != "1" ]; then
		configure_context=1
	elif [ -n "$requested_apn" ] && [ "$requested_lower" != "$context_lower" ]; then
		configure_context=1
	elif [ "$context_type" != "$type" ] && [ "$type_change_safe" = "1" ]; then
		configure_context=1
	fi

	if [ "$configure_context" = "1" ]; then
		command="AT+CGDCONT=$cid,\"$type\""
		command_apn="$requested_apn"
		[ -n "$command_apn" ] || command_apn="$context_apn"
		[ -z "$command_apn" ] ||
			command="$command,\"$(fm350_escape_at_string "$command_apn")\""
		response="$(at_timeout "$at_port" "$command" 10 2>&1)"
		config_rc=$?
		if [ "$config_rc" -ne 0 ] || fm350_response_has_error "$response"; then
			m_debug "FM350 CID $cid rejected CGDCONT: $(printf '%s' "$response" | tr '\r\n' ' ' | cut -c1-160)"
			return 1
		fi
		context_changed=1
		# Several FM350 firmware lines cannot accept CGACT immediately after
		# rewriting CGDCONT.  Older QModem releases had this delay, but it was
		# accidentally lost during the generic dialer refactor.
		sleep 3
	fi

	response="$(at_timeout "$at_port" "AT+CGACT=1,$cid" 35 2>&1)"
	activation_rc=$?
	if fm350_response_has_error "$response"; then
		m_debug "FM350 CID $cid activation error: $(printf '%s' "$response" | tr '\r\n' ' ' | cut -c1-160)"
		fm350_cleanup_candidate "$cid" "$context_existed" "$original_type" \
			"$context_apn" "$context_changed" "$original_definition"
		return 1
	fi
	if [ "$activation_rc" -ne 0 ]; then
		m_debug "FM350 CID $cid activation timed out; checking whether the modem completed it asynchronously"
	fi

	attempt=0
	while [ "$attempt" -lt 7 ]; do
		if fm350_query_addresses "$cid" && fm350_address_matches_pdp_type; then
			pdp_index="$cid"
			ipv4="$fm350_ipv4"
			ipv6="$fm350_ipv6"
			return 0
		fi
		attempt=$((attempt + 1))
		[ "$attempt" -ge 7 ] || sleep 4
	done
	fm350_cleanup_candidate "$cid" "$context_existed" "$original_type" \
		"$context_apn" "$context_changed" "$original_definition"
	return 1
}

fm350_cleanup_candidate()
{
	local cid="$1" context_existed="$2" original_type="$3"
	local original_apn="$4" context_changed="$5" original_definition="$6"
	local command minimal_command response restore_rc

	case " $fm350_active_contexts " in
		*" $cid "*) ;;
		*) at_timeout "$at_port" "AT+CGACT=0,$cid" 15 >/dev/null 2>&1 ;;
	esac

	[ "$context_changed" = "1" ] || return 0
	if [ "$context_existed" = "1" ]; then
		[ -n "$original_type" ] || original_type="IPV4V6"
		minimal_command="AT+CGDCONT=$cid,\"$original_type\",\"$(fm350_escape_at_string "$original_apn")\""
		case "$original_definition" in
			"$cid,"*)
				if printf '%s\n' "$original_definition" |
				   grep -qE '^[0-9]+,[A-Za-z0-9_+./":,-]+$'; then
					command="AT+CGDCONT=$original_definition"
				fi
				;;
		esac
		[ -n "$command" ] || command="$minimal_command"
	else
		command="AT+CGDCONT=$cid"
	fi
	response="$(at_timeout "$at_port" "$command" 10 2>&1)"
	restore_rc=$?
	if [ "$context_existed" = "1" ] &&
	   [ "$command" != "$minimal_command" ] &&
	   { [ "$restore_rc" -ne 0 ] || fm350_response_has_error "$response"; }; then
		response="$(at_timeout "$at_port" "$minimal_command" 10 2>&1)"
		restore_rc=$?
	fi
	if [ "$restore_rc" -ne 0 ] || fm350_response_has_error "$response"; then
		m_debug "FM350 CID $cid context restore failed: $(printf '%s' "$response" | tr '\r\n' ' ' | cut -c1-160)"
		return 1
	fi
	return 0
}

fm350_save_working_profile()
{
	local cid="$1" requested_apn revision dirty=0

	requested_apn="$apn"
	[ "$requested_apn" = "auto" ] && requested_apn=""
	revision="$(printf '%s\n' "$fm350_revision" |
		sed '/^AT/d; /^OK$/d; /^[[:space:]]*$/d' |
		head -n 1 | tr -d '\r' | cut -c1-80)"

	if [ "$(uci -q get "qmodem.${modem_config}.fm350_last_good_cid")" != "$cid" ] ||
	   [ "$(uci -q get "qmodem.${modem_config}.fm350_last_good_apn")" != "$requested_apn" ] ||
	   [ "$(uci -q get "qmodem.${modem_config}.fm350_last_good_revision")" != "$revision" ] ||
	   [ "$(uci -q get "qmodem.${modem_config}.fm350_last_good_iccid")" != "$fm350_iccid" ] ||
	   [ "$(uci -q get "qmodem.${modem_config}.fm350_last_good_at_port")" != "$at_port" ] ||
	   [ "$(uci -q get "qmodem.${modem_config}.fm350_last_requested_cid")" != "${fm350_configured_cid:-$cid}" ]; then
		uci -q set "qmodem.${modem_config}.fm350_last_good_cid=$cid"
		uci -q set "qmodem.${modem_config}.fm350_last_good_apn=$requested_apn"
		uci -q set "qmodem.${modem_config}.fm350_last_good_at_port=$at_port"
		uci -q set "qmodem.${modem_config}.fm350_last_requested_cid=${fm350_configured_cid:-$cid}"
		[ -z "$revision" ] ||
			uci -q set "qmodem.${modem_config}.fm350_last_good_revision=$revision"
		[ -z "$fm350_iccid" ] ||
			uci -q set "qmodem.${modem_config}.fm350_last_good_iccid=$fm350_iccid"
		dirty=1
	fi
	# Propagate the proven port and serialized backend to status, SMS and
	# debug callers, which read the primary UCI fields rather than this cache.
	if [ -z "$override_at_port" ] &&
	   [ "$(uci -q get "qmodem.${modem_config}.at_port")" != "$at_port" ]; then
		uci -q set "qmodem.${modem_config}.at_port=$at_port"
		dirty=1
	fi
	if [ "$(uci -q get "qmodem.${modem_config}.use_ubus")" != "1" ]; then
		uci -q set "qmodem.${modem_config}.use_ubus=1"
		dirty=1
	fi
	[ "$dirty" = "1" ] && uci -q commit qmodem
}

fm350_cached_cid_for_hang()
{
	local cached_cid cached_revision cached_iccid current_revision current_iccid
	local identity_evidence=0

	cached_cid="$(uci -q get "qmodem.${modem_config}.fm350_last_good_cid")"
	fm350_is_uint "$cached_cid" || return 1
	[ "$cached_cid" -le 15 ] || return 1

	cached_revision="$(uci -q get "qmodem.${modem_config}.fm350_last_good_revision")"
	cached_iccid="$(uci -q get "qmodem.${modem_config}.fm350_last_good_iccid")"

	if [ -n "$cached_revision" ]; then
		current_revision="$(at_timeout "$at_port" "AT+CGMR?" 8 2>/dev/null |
			sed '/^AT/d; /^OK$/d; /^[[:space:]]*$/d' |
			head -n 1 | tr -d '\r' | cut -c1-80)"
		[ "$current_revision" = "$cached_revision" ] || return 1
		identity_evidence=1
	fi
	if [ -n "$cached_iccid" ]; then
		current_iccid="$(at_timeout "$at_port" "AT+CCID" 8 2>/dev/null |
			grep -oE '[0-9]{18,22}' | head -n 1)"
		[ "$current_iccid" = "$cached_iccid" ] || return 1
		identity_evidence=1
	fi

	# Never apply an unbound cache entry to a replaced module or SIM.
	[ "$identity_evidence" = "1" ] || return 1
	printf '%s\n' "$cached_cid"
}

fm350_dial()
{
	local cid model model_raw model_rc usb_mode candidate_port identity_cmd

	fm350_build_at_ports
	m_debug "FM350 automatic AT ports: ${fm350_at_ports:-none}"
	for candidate_port in $fm350_at_ports; do
		at_port="$candidate_port"
		model_raw=""
		for identity_cmd in 'AT+CGMM?' 'AT+CGMM' 'ATI'; do
			model_raw="$(at_timeout "$at_port" "$identity_cmd" 8 2>&1)"
			model_rc=$?
			[ "$model_rc" -eq 0 ] || continue
			fm350_response_has_error "$model_raw" && continue
			printf '%s\n' "$model_raw" | grep -qiE '(fm350|rw350)' && break
			model_raw=""
		done
		[ -n "$model_raw" ] || {
			m_debug "FM350 rejected unrelated/unusable AT port $at_port"
			continue
		}
		model="$(printf '%s\n' "$model_raw" |
			tr '\r\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-120)"
		fm350_revision="$(at_timeout "$at_port" "AT+CGMR?" 8 2>&1)"
		fm350_response_has_error "$fm350_revision" && fm350_revision=""
		fm350_iccid="$(at_timeout "$at_port" "AT+CCID" 8 2>&1 |
			grep -oE '[0-9]{18,22}' | head -n 1)"
		usb_mode="$(at_timeout "$at_port" "AT+GTUSBMODE?" 8 2>&1 |
			tr '\r\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-120)"
		m_debug "FM350 identity on $at_port: model=$model; iccid=${fm350_iccid:-unknown}; usb_mode=$usb_mode"

		fm350_build_candidates
		m_debug "FM350 automatic PDP candidates on $at_port: ${fm350_candidates:-none}"
		for cid in $fm350_candidates; do
			m_debug "FM350 trying port $at_port CID $cid"
			if fm350_activate_candidate "$cid"; then
				fm350_save_working_profile "$cid"
				m_debug "FM350 port $at_port CID $cid connected: IPv4=${ipv4:-none}; IPv6=${ipv6:-none}"
				return 0
			fi
		done
	done
	m_debug "FM350 could not activate any safe AT port/PDP context pair"
	return 1
}

fm350_parse_ipv4_parameters()
{
	local value="$1" old_ifs="$IFS"

	IFS=.
	set -- $value
	IFS="$old_ifs"
	[ "$#" -eq 8 ] || return 1
	fm350_is_valid_ipv4 "$1.$2.$3.$4" || return 1
	fm350_netmask_to_prefix "$5.$6.$7.$8" >/dev/null || return 1
	fm350_runtime_ipv4="$1.$2.$3.$4"
	fm350_runtime_netmask="$5.$6.$7.$8"
	return 0
}

fm350_read_runtime_parameters()
{
	local response line line_cid source gateway dns1 dns2 old_ifs="$IFS"

	fm350_runtime_ipv4=""
	fm350_runtime_netmask=""
	fm350_runtime_gateway=""
	fm350_runtime_dns=""
	response="$(at_timeout "$at_port" "AT+CGCONTRDP=$pdp_index" 10 2>&1)"
	IFS='
'
	for line in $(printf '%s\n' "$response" | grep '+CGCONTRDP:'); do
		line_cid="$(printf '%s\n' "$line" | awk -F',' '{
			sub(/^.*\+CGCONTRDP:[[:space:]]*/, "", $1)
			gsub(/[[:space:]"]/, "", $1)
			print $1
		}')"
		[ "$line_cid" = "$pdp_index" ] || continue
		source="$(printf '%s\n' "$line" | awk -F',' '{gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", $4); print $4}')"
		fm350_parse_ipv4_parameters "$source" || continue
		gateway="$(printf '%s\n' "$line" | awk -F',' '{gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", $5); print $5}')"
		dns1="$(printf '%s\n' "$line" | awk -F',' '{gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", $6); print $6}')"
		dns2="$(printf '%s\n' "$line" | awk -F',' '{gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", $7); print $7}')"
		fm350_is_valid_ipv4 "$gateway" && fm350_runtime_gateway="$gateway"
		fm350_is_valid_ipv4 "$dns1" && fm350_runtime_dns="$dns1"
		if fm350_is_valid_ipv4 "$dns2"; then
			fm350_runtime_dns="${fm350_runtime_dns}${fm350_runtime_dns:+ }$dns2"
		fi
		break
	done
	IFS="$old_ifs"

	if [ -z "$fm350_runtime_ipv4" ] && fm350_query_addresses "$pdp_index"; then
		fm350_runtime_ipv4="$fm350_ipv4"
	fi

	# GTDNS is present on firmware that returns a shortened CGCONTRDP record.
	response="$(at_timeout "$at_port" "AT+GTDNS=$pdp_index" 10 2>&1)"
	IFS='
'
	for source in $(printf '%s\n' "$response" |
		awk -v wanted="$pdp_index" '
		function trim(value) {
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
			if (value ~ /^".*"$/) {
				sub(/^"/, "", value)
				sub(/"$/, "", value)
			}
			return value
		}
		/\+GTDNS:/ {
			line = $0
			sub(/\r$/, "", line)
			sub(/^.*\+GTDNS:[[:space:]]*/, "", line)
			n = split(line, part, ",")
			if (trim(part[1]) != wanted)
				next
			for (i = 2; i <= n; i++)
				print trim(part[i])
		}'); do
		if fm350_is_valid_ipv4 "$source"; then
			case " $fm350_runtime_dns " in
				*" $source "*) ;;
				*) fm350_runtime_dns="${fm350_runtime_dns}${fm350_runtime_dns:+ }$source" ;;
			esac
		else
			case "$source" in
				*:*) source="$(fm350_colon_ipv6 "$source" 2>/dev/null)" || source="" ;;
				*) source="$(fm350_dotted_ipv6 "$source" 2>/dev/null)" || source="" ;;
			esac
			[ -z "$source" ] ||
				fm350_runtime_dns="${fm350_runtime_dns}${fm350_runtime_dns:+ }$source"
		fi
	done
	IFS="$old_ifs"

	[ -n "$fm350_runtime_ipv4" ]
}

fm350_prefix_to_netmask()
{
	local prefix="$1"

	fm350_is_uint "$prefix" || return 1
	[ "$prefix" -le 32 ] || return 1
	awk -v prefix="$prefix" 'BEGIN {
		for (i = 0; i < 4; i++) {
			bits = prefix - (i * 8)
			if (bits >= 8)
				octet = 255
			else if (bits <= 0)
				octet = 0
			else
				octet = 256 - (2 ^ (8 - bits))
			printf "%s%d", (i ? "." : ""), octet
		}
		printf "\n"
	}'
}
