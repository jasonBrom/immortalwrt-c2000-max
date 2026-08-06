#!/bin/sh
source /lib/functions.sh
#运行目录
MODEM_RUNDIR="/var/run/qmodem"
SCRIPT_DIR="/usr/share/qmodem"

modem_config=$1
mkdir -p "${MODEM_RUNDIR}/${modem_config}_dir"
log_file="${MODEM_RUNDIR}/${modem_config}_dir/dial_log"
debug_subject="modem_dial"
source "${SCRIPT_DIR}/generic.sh"
source "${SCRIPT_DIR}/fm350.sh"
touch $log_file

exec_pre_dial()
{
    section=$1
    /usr/share/qmodem/modem_hook.sh $section pre_dial
}

get_led()
{
    config_foreach get_led_by_slot modem-slot
}

get_led_by_slot()
{
    local cfg="$1"
    config_get slot "$cfg" slot
    if [ "$modem_slot" = "$slot" ];then
        config_get sim_led "$cfg" sim_led
        config_get net_led "$cfg" net_led
    fi
}

get_slot_network_config()
{
    local cfg="$1"
    local slot
    config_get slot "$cfg" slot
    if [ "$modem_slot" = "$slot" ];then
        config_get ethernet_5g "$cfg" ethernet_5g
        config_get slot_bridge_port "$cfg" bridge_port
    fi
}

sanitize_bridge_id()
{
    local value="$1"
    value=$(printf '%s' "$value" | tr -c 'A-Za-z0-9_-' '_')
    value=$(printf '%s' "$value" | sed 's/^_\\+//; s/_\\+$//')
    echo "$value"
}

make_bridge_device_name()
{
    local source="$1"
    local sanitized

    sanitized=$(sanitize_bridge_id "$source")
    [ -z "$sanitized" ] && return 1
    printf 'b%s\n' "$sanitized" | cut -c1-15
}

get_bridge_device_section()
{
    local safe_cfg
    safe_cfg=$(sanitize_bridge_id "$modem_config")
    [ -z "$safe_cfg" ] && safe_cfg="modem"
    echo "qmodem_bridge_${safe_cfg}"
}

get_bridge_backup_section()
{
    local bridge_cfg="$1"
    local safe_cfg
    local safe_bridge

    safe_cfg=$(sanitize_bridge_id "$modem_config")
    safe_bridge=$(sanitize_bridge_id "$bridge_cfg")
    [ -z "$safe_cfg" ] && safe_cfg="modem"
    [ -z "$safe_bridge" ] && safe_bridge="bridge"
    echo "qmodem_bridge_backup_${safe_cfg}_${safe_bridge}"
}

bridge_name_conflict_cb()
{
    local cfg="$1"
    local name

    [ "$cfg" = "$bridge_name_allow_section" ] && return
    config_get name "$cfg" name
    [ "$name" = "$bridge_name_candidate" ] && bridge_name_conflict=1
}

bridge_name_in_use()
{
    local candidate="$1"
    local allow_section="$2"
    local current_name

    [ -z "$candidate" ] && return 0

    bridge_name_candidate="$candidate"
    bridge_name_allow_section="$allow_section"
    bridge_name_conflict=0
    config_load network
    config_foreach bridge_name_conflict_cb device
    current_name=$(uci -q get network.${allow_section}.name)
    if [ -d "/sys/class/net/$candidate" ] && [ "$current_name" != "$candidate" ]; then
        bridge_name_conflict=1
    fi
    [ "$bridge_name_conflict" = "1" ]
}

resolve_bridge_device_name()
{
    local bridge_section
    local preferred_name
    local fallback_name
    local current_name
    local seed
    local suffix

    bridge_section=$(get_bridge_device_section)
    current_name=$(uci -q get network.${bridge_section}.name)
    preferred_name=$(make_bridge_device_name "$alias")
    fallback_name=$(make_bridge_device_name "$modem_config")

    if [ -n "$preferred_name" ] && ! bridge_name_in_use "$preferred_name" "$bridge_section"; then
        echo "$preferred_name"
        return
    fi

    if [ -n "$fallback_name" ] && ! bridge_name_in_use "$fallback_name" "$bridge_section"; then
        echo "$fallback_name"
        return
    fi

    if [ -n "$current_name" ]; then
        echo "$current_name"
        return
    fi

    seed=$(sanitize_bridge_id "$modem_config")
    [ -z "$seed" ] && seed="modem"
    suffix=$(printf '%s' "$modem_config" | cksum | awk '{print $1}' | cut -c1-4)
    printf 'b%s%s\n' "$(printf '%s' "$seed" | cut -c1-10)" "$suffix" | cut -c1-15
}

collect_bridge_ports()
{
    local port="$1"

    [ -n "$bridge_ports" ] && bridge_ports="$bridge_ports $port" || bridge_ports="$port"
    [ "$port" = "$bridge_scan_target_port" ] && bridge_port_found=1
}

save_bridge_port_backup()
{
    local source_section="$1"
    local source_ports="$2"
    local backup_section

    backup_section=$(get_bridge_backup_section "$source_section")
    [ -n "$(uci -q get qmodem.${backup_section})" ] && return

    uci -q set qmodem.${backup_section}=bridge-port-backup
    uci -q set qmodem.${backup_section}.modem_config="${modem_config}"
    uci -q set qmodem.${backup_section}.device_section="${source_section}"
    uci -q set qmodem.${backup_section}.bridge_port="${bridge_port}"
    uci -q delete qmodem.${backup_section}.ports
    for port in $source_ports; do
        uci -q add_list qmodem.${backup_section}.ports="${port}"
    done
    bridge_qmodem_dirty=1
    m_debug "backup bridge device $source_section ports: $source_ports"
}

remove_bridge_port_from_device()
{
    local cfg="$1"
    local type

    [ "$cfg" = "$bridge_device_section" ] && return
    config_get type "$cfg" type
    [ "$type" = "bridge" ] || return

    bridge_ports=""
    bridge_port_found=0
    config_list_foreach "$cfg" ports collect_bridge_ports
    [ "$bridge_port_found" = "1" ] || return

    save_bridge_port_backup "$cfg" "$bridge_ports"
    uci -q delete network.${cfg}.ports
    for port in $bridge_ports; do
        [ "$port" = "$bridge_scan_target_port" ] && continue
        uci -q add_list network.${cfg}.ports="${port}"
    done
    bridge_network_dirty=1
    m_debug "remove bridge port $bridge_scan_target_port from bridge device $cfg"
}

ensure_bridge_device()
{
    local wwan_port="$1"
    local bridge_section
    local desired_ports
    local current_type
    local current_name
    local current_ports

    bridge_section=$(get_bridge_device_section)
    bridge_device_section="$bridge_section"
    bridge_device_name=$(resolve_bridge_device_name)
    current_type=$(uci -q get network.${bridge_section}.type)
    current_name=$(uci -q get network.${bridge_section}.name)
    current_ports=$(uci -q get network.${bridge_section}.ports)

    desired_ports="$bridge_port"
    [ -n "$wwan_port" ] && [ "$wwan_port" != "$bridge_port" ] && desired_ports="$desired_ports $wwan_port"

    if [ "$(uci -q get network.${bridge_section})" != "device" ] || [ "$current_type" != "bridge" ] || [ "$current_name" != "$bridge_device_name" ] || [ "$current_ports" != "$desired_ports" ]; then
        uci -q set network.${bridge_section}=device
        uci -q set network.${bridge_section}.name="${bridge_device_name}"
        uci -q set network.${bridge_section}.type='bridge'
        uci -q delete network.${bridge_section}.ports
        uci -q add_list network.${bridge_section}.ports="${bridge_port}"
        [ -n "$wwan_port" ] && [ "$wwan_port" != "$bridge_port" ] && uci -q add_list network.${bridge_section}.ports="${wwan_port}"
        bridge_network_dirty=1
        m_debug "set dedicated bridge ${bridge_device_name} ports: ${desired_ports}"
    fi
}

ensure_bridge_passthrough()
{
    local wwan_port="$1"

    bridge_device_name=""
    bridge_device_section=$(get_bridge_device_section)
    bridge_scan_target_port="$bridge_port"

    config_load network
    config_foreach remove_bridge_port_from_device device
    ensure_bridge_device "$wwan_port"
}

restore_bridge_backup_ports()
{
    local port="$1"

    [ -n "$port" ] && uci -q add_list network.${restore_bridge_section}.ports="${port}"
}

restore_bridge_port_backup()
{
    local cfg="$1"
    local bind_modem_config
    local source_section

    config_get bind_modem_config "$cfg" modem_config
    [ "$bind_modem_config" = "$modem_config" ] || return

    config_get source_section "$cfg" device_section
    if [ -n "$source_section" ] && [ -n "$(uci -q get network.${source_section})" ]; then
        uci -q delete network.${source_section}.ports
        restore_bridge_section="$source_section"
        config_list_foreach "$cfg" ports restore_bridge_backup_ports
        bridge_network_dirty=1
        m_debug "restore bridge device $source_section"
    fi

    uci -q delete qmodem.${cfg}
    bridge_qmodem_dirty=1
}

cleanup_bridge_passthrough()
{
    local bridge_section

    bridge_network_dirty=0
    bridge_qmodem_dirty=0

    config_load qmodem
    config_foreach restore_bridge_port_backup bridge-port-backup

    bridge_section=$(get_bridge_device_section)
    if [ -n "$(uci -q get network.${bridge_section})" ]; then
        uci -q delete network.${bridge_section}
        bridge_network_dirty=1
        m_debug "delete dedicated bridge section $bridge_section"
    fi
}

set_led()
{
    local type=$1
    local modem_config=$2
    local value=$3
    get_led "$modem_slot"
    case $type in
        sim)
            [ -z "$sim_led" ] && return
            echo $value > /sys/class/leds/$sim_led/brightness
            ;;
        net)
            [ -z "$net_led" ] && return
            cfg_name=$(echo $net_led |tr ":" "_") 
            uci batch << EOF
set system.n${cfg_name}=led
set system.n${cfg_name}.name=${modem_slot}_net_indicator
set system.n${cfg_name}.sysfs=${net_led}
set system.n${cfg_name}.trigger=netdev
set system.n${cfg_name}.dev=${value:-$modem_netcard}
set system.n${cfg_name}.mode="link tx rx"
commit system
EOF

            /etc/init.d/led restart
            ;;
    esac
}

unlock_sim()
{
    local pin="$1"
    local sim_lock_file="${MODEM_RUNDIR}/${modem_config}_dir/pincode"
    local response rc

    lock "${sim_lock_file}.lock" || return 1
    if [ -f "$sim_lock_file" ] &&
       [ "$pin" = "$(cat "$sim_lock_file")" ]; then
        m_debug "PIN was already rejected; blocking retries until next boot"
        rc=1
    else
        response=$(at "$at_port" "AT+CPIN=\"$pin\"")
        rc=$?
        if [ "$rc" -eq 0 ] && ! fm350_response_has_error "$response"; then
            rm -f "$sim_lock_file"
            m_debug "SIM PIN accepted"
            rc=0
        else
            printf '%s\n' "$pin" > "$sim_lock_file"
            m_debug "SIM PIN rejected; blocking retries until next boot"
            rc=1
        fi
    fi
    lock -u "${sim_lock_file}.lock"
    return "$rc"
}

get_platform_suggest_pdp_index()
{
    case $manufacturer in
    quectel)
        case $platform in
            lte)
                echo 3
                ;;
            *)
                echo 1
                ;;
        esac
    ;;
    fibocom)
        case $platform in
            mediatek)
                echo 3
                ;;
            *)
                echo 1
                ;;
        esac
    ;;
    *)
        echo 1
        ;;
    esac
}

update_config()
{
    config_load qmodem
    config_get state $modem_config state
    config_get enable_dial $modem_config enable_dial
    config_get modem_path $modem_config path
    config_get dial_tool $modem_config dial_tool
    config_get pdp_type $modem_config pdp_type
    pdp_type="$(normalize_pdp_type "$pdp_type")"
    config_get network_bridge $modem_config network_bridge
    config_get metric $modem_config metric
    config_get at_port $modem_config at_port
    config_get override_at_port $modem_config override_at_port
    [ -n "$override_at_port" ] && at_port="$override_at_port"
    config_get manufacturer $modem_config manufacturer
    config_get platform $modem_config platform
    config_get use_ubus $modem_config use_ubus
    config_get force_set_apn $modem_config force_set_apn
    config_get fm350_pdp_auto $modem_config fm350_pdp_auto 1
    config_get fm350_legacy_route_guess $modem_config fm350_legacy_route_guess 0
    config_get pdp_index $modem_config pdp_index
    [ -n "$pdp_index" ] && userset_pdp_index="1" || userset_pdp_index="0"
    config_get suggest_pdp_index $modem_config suggest_pdp_index
    [ -z "$suggest_pdp_index" ] && suggest_pdp_index=$(get_platform_suggest_pdp_index)
    [ -z "$pdp_index" ] && pdp_index=$suggest_pdp_index
    fm350_configured_cid="$pdp_index"
    config_get ra_master $modem_config ra_master
    config_get extend_prefix $modem_config extend_prefix
    config_get en_bridge $modem_config en_bridge
    config_get do_not_add_dns $modem_config do_not_add_dns
    config_get dns_list $modem_config dns_list
    config_get huawei_dial_mode $modem_config huawei_dial_mode
    config_get donot_nat $modem_config donot_nat 0
    config_get global_dial main enable_dial
    modem_slot=$(basename $modem_path)
    slot_bridge_port=""
    ethernet_5g=""
    bridge_port=""
    bridge_enabled=0
    # config_get ethernet_5g u$modem_config ethernet 转往口获取命令更新，待测试
    config_foreach get_slot_network_config modem-slot
    config_get alias $modem_config alias
    config_get device_bridge_port $modem_config bridge_port
    bridge_port="$slot_bridge_port"
    [ -n "$device_bridge_port" ] && bridge_port="$device_bridge_port"
    [ "$en_bridge" = "1" ] && [ -n "$bridge_port" ] && bridge_enabled=1
    driver=$(get_driver)
    update_sim_slot
    case $sim_slot in
        1)
        config_get apn $modem_config apn
        config_get username $modem_config username
        config_get password $modem_config password
        config_get auth $modem_config auth
        config_get pincode $modem_config pincode
        ;;
        2)
        config_get apn $modem_config apn2
        config_get username $modem_config username2
        config_get password $modem_config password2
        config_get auth $modem_config auth2
        config_get pincode $modem_config pincode2
        [ -z "$apn" ] && config_get apn $modem_config apn
        [ -z "$username" ] && config_get username $modem_config username
        [ -z "$password" ] && config_get password $modem_config password
        [ -z "$auth" ] && config_get auth $modem_config auth
        [ -z "$pincode" ] && config_get pincode $modem_config pincode
        ;;
        *)
            config_get apn $modem_config apn
            config_get username $modem_config username
            config_get password $modem_config password
            config_get auth $modem_config auth
            config_get pincode $modem_config pincode
            ;;
    esac
    modem_net=$(find $modem_path -name net |tail -1)
    modem_netcard=$(ls $modem_net)
    interface_name=$modem_config
    [ -n "$alias" ] && interface_name=$alias
    interface6_name=${interface_name}v6
    if [ "$use_ubus" = "1" ]; then
        use_ubus_flag="-u"
    else
        use_ubus_flag=""
    fi
}

normalize_pdp_type()
{
    local value

    value="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    case "$value" in
        ip|ipv6|ipv4v6)
            printf '%s\n' "$value"
            ;;
        ipv4)
            printf '%s\n' ip
            ;;
        *)
            # Old QModem configurations can have an empty or vendor-specific
            # value.  Dual stack is the least destructive upgrade default and
            # still permits FM350's single-stack fallback.
            printf '%s\n' ipv4v6
            ;;
    esac
}

check_dial_prepare()
{
    cpin=$(at "$at_port" "AT+CPIN?")
    get_sim_status "$cpin"
    [ "$manufacturer" = "neoway" ] && {
        local res
        res=$(at $at_port 'AT+SIMCROSS=1,1;$MYCCID' | grep -q "ERROR")
        if [ $? -ne 0 ]; then
            sim_state_code="1"
        else
            sim_state_code="0"
        fi
    }
    case $sim_state_code in
        "0")
            m_debug "info sim card is miss"
            ;;
        "1")
            m_debug "info sim card is ready"
            sim_fullfill=1
            ;;
        "2")
            m_debug "pin code required"
            [ -n "$pincode" ] && unlock_sim "$pincode"
            ;;
        *)
            m_debug "info sim card state is $sim_state_code"
            ;;
    esac
    
    if [ "$sim_fullfill" = "1" ];then
        set_led "sim" $modem_config 255
    else
        set_led "sim" $modem_config 0
    fi
    if [ -n "$modem_netcard" ] && [ -d "/sys/class/net/$modem_netcard" ];then
        netdev_fullfill=1
    else
        netdev_fullfill=0
    fi

    if [ "$enable_dial" = "1" ] && [ "$sim_fullfill" = "1" ] && [ "$state" != "disabled" ] ;then
        config_fullfill=1
    fi
    if [ "$config_fullfill" = "1" ] && [ "$sim_fullfill" = "1" ] && [ "$netdev_fullfill" = "1" ] ;then
        at "$at_port" "AT+CFUN=1"
        return 1
    else
        return 0
    fi
}

check_ip()
{
    if fm350_is_modem && [ "$driver" != "mtk_pcie" ]; then
        if fm350_query_addresses "$pdp_index" &&
           fm350_address_matches_pdp_type; then
            ipv4="$fm350_ipv4"
            ipv6="$fm350_ipv6"
            connection_status=0
            [ -n "$ipv4" ] && connection_status=1
            [ -n "$ipv6" ] && connection_status=2
            [ -n "$ipv4" ] && [ -n "$ipv6" ] && connection_status=3
        elif printf '%s\n' "$fm350_address_response" | grep -q '+CGPADDR:'; then
            # A syntactically valid response containing only zero addresses
            # means that the context is not connected yet.
            ipv4=""
            ipv6=""
            connection_status=0
        else
            connection_status="-1"
            m_debug "FM350 CGPADDR unavailable (rc=$fm350_address_rc): $(printf '%s' "$fm350_address_response" | tr '\r\n' ' ' | cut -c1-160)"
        fi
        return
    fi

    case $manufacturer in
            "simcom")
                case $platform in
                    "qualcomm")
                        check_ip_command="AT+CGPADDR=6"
                        ;;
                esac
                ;;
            "neoway")
                case $platform in
                    "unisoc")
                        check_ip_command="AT+CGPADDR=1"
                        ;;
                esac
                ;;
            *)
                check_ip_command="AT+CGPADDR=$pdp_index"
                ;;
        esac

        if [ "$driver" = "mtk_pcie" ]; then
            local config mbim_ipv4 mbim_ipv6
            mbim_port=$(printf '%s' "$at_port" | sed 's/at/mbim/g')
            config=$(qmodem_mbim_run "$mbim_port" \
                umbim -d "$mbim_port" config 2>/dev/null) || {
                ipv4=""
                ipv6=""
                connection_status="-1"
                m_debug "FM350 MBIM config query failed on $mbim_port"
                return
            }
            mbim_ipv4="$(fm350_mbim_field ipv4address "$config" | head -n 1)"
            mbim_ipv6="$(fm350_mbim_field ipv6address "$config" | head -n 1)"
            ipv4="${mbim_ipv4%%/*}"
            ipv6="${mbim_ipv6%%/*}"
            fm350_is_valid_ipv4 "$ipv4" || ipv4=""
            ipv6="$(fm350_colon_ipv6 "$ipv6" 2>/dev/null)" || ipv6=""
            connection_status=0
            [ -n "$ipv4" ] && connection_status=1
            [ -n "$ipv6" ] && connection_status=2
            [ -n "$ipv4" ] && [ -n "$ipv6" ] && connection_status=3
            return
        else
            ipaddr=$(at "$at_port" "$check_ip_command" | grep +CGPADDR:)
        fi

        if [ -n "$ipaddr" ];then
            ipv6=$(echo $ipaddr | grep -oE "\b([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}\b")
            ipv4=$(echo $ipaddr | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b")
            if [ "$manufacturer" = "simcom" ];then
                ipv4=$(echo $ipaddr | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | grep -v "0\.0\.0\.0" | head -n 1)
                ipv6=$(echo $ipaddr | grep -oE "\b([0-9a-fA-F]{0,4}.){2,7}[0-9a-fA-F]{0,4}\b")
            fi
            # disallow_ipv4="0.0.0.0"
            # #remove the disallow ip
            # if [[ "$ipv4" == *"$disallow_ipv4"* ]];then
            #     ipv4=""
            # fi
            connection_status=0
            if [ -n "$ipv4" ];then
                connection_status=1
            fi
            if [ -n "$ipv6" ];then
                connection_status=2
            fi
            if [ -n "$ipv4" ] && [ -n "$ipv6" ];then
                connection_status=3
            fi
        else
            connection_status="-1"
            m_debug "at port response unexpected $ipaddr"
        fi
}

append_to_fw_zone()
{
    local fw_zone=$1
    local if_name=$2
    source /etc/os-release
    local os_version=${VERSION_ID:0:2}
    if [ "$os_version" -le 21 ];then
        has_ifname=0
        origin_line=$(uci -q get firewall.@zone[${fw_zone}].network)
        for i in $origin_line
        do
            if [ "$i" = "$if_name" ];then
                has_ifname=1
            fi
        done
        if [ -n "$origin_line" ] && [ "$has_ifname" -eq 0 ];then
            uci set firewall.@zone[${fw_zone}].network="${origin_line} ${if_name}"
        elif [ -z "$origin_line" ];then
            uci set firewall.@zone[${fw_zone}].network="${if_name}"
        fi
    else
        uci add_list firewall.@zone[${fw_zone}].network=${if_name}
    fi
}

set_if()
{
    firewall_reload_flag=0
    dhcp_reload_flag=0
    network_reload_flag=0
    interface_update_flag=0
    bridge_network_dirty=0
    bridge_qmodem_dirty=0
    fm350_ipv6_transport=0
    #check if exist
    proto="dhcp"
    protov6="dhcpv6"
    case $manufacturer in
        "quectel")
            case $platform in
                "unisoc")
                    case $driver in
                        "mbim")
                            proto="none"
                            protov6="none"
                            ;;
                        esac
                    ;;
            esac
            ;; 
        "fibocom")
            case $platform in
                "mediatek")
                    proto="static"
                    protov6="dhcpv6"
                    ;;
                esac
            ;;
    esac
    if fm350_is_modem && [ "$bridge_enabled" != "1" ]; then
        # Start the USB transport without an address.  The proven CGCONTRDP
        # tuple is installed after activation.  This also keeps the parent
        # usable when an IPV4V6 subscription falls back to IPv6-only.
        proto="none"
    fi
    if [ "$bridge_enabled" = "1" ]; then
        proto="none"
        protov6="none"
    fi
    case $pdp_type in
        "ip")
            env4="1"
            env6="0"
            ;;
        "ipv6")
            env4="0"
            env6="1"
            ;;
        "ipv4v6")
            env4="1"
            env6="1"
            ;;
    esac
    if [ "$bridge_enabled" = "1" ]; then
        env4="1"
        env6="0"
    fi
    if fm350_is_modem && [ "$env4" = "0" ] && [ "$env6" = "1" ] &&
       [ "$bridge_enabled" != "1" ]; then
        # A DHCPv6 child needs a live netifd parent.  Keep the RNDIS/NCM
        # transport as proto=none for IPv6-only profiles instead of deleting
        # the interface that the @<name> child references.
        fm350_ipv6_transport=1
    fi
    base_proto="$proto"
    [ "$fm350_ipv6_transport" -eq 1 ] && base_proto="none"
    interface=$(uci -q get network.$interface_name)
    interfacev6=$(uci -q get network.$interface6_name)
    num=$(uci show firewall | grep "name='wan'" | wc -l)
    if [ "$env4" -eq 1 ] || [ "$fm350_ipv6_transport" -eq 1 ];then
        if [ -z "$interface" ];then
            uci set network.${interface_name}=interface
            uci set network.${interface_name}.modem_config="${modem_config}"
            if [ "$env4" -eq 1 ]; then
                uci set network.${interface_name}.proto="${base_proto}"
                uci set network.${interface_name}.defaultroute='1'
            else
                uci set network.${interface_name}.proto='none'
                uci -q del network.${interface_name}.defaultroute
            fi
            uci set network.${interface_name}.metric="${metric}"
            uci del network.${interface_name}.dns
            if [ -n "$dns_list" ];then
                uci set network.${interface_name}.peerdns='0'
                for dns in $dns_list;do
                    uci add_list network.${interface_name}.dns="${dns}"
                done
            else
                uci del network.${interface_name}.peerdns
            fi
            if [ "$env4" -eq 1 ]; then
                local wwan_num=$(uci -q get firewall.@zone[$num].network | grep -w "${interface_name}" | wc -l)
                if [ "$wwan_num" = "0" ]; then
                    append_to_fw_zone $num ${interface_name}
                fi
            fi
            network_reload_flag=1
            [ "$env4" -eq 1 ] && firewall_reload_flag=1
            m_debug "create interface $interface_name with proto $(uci -q get network.${interface_name}.proto) and metric $metric"
        fi
    else
        if [ -n "$interface" ];then
            uci delete network.${interface_name}
            network_reload_flag=1
            m_debug "delete interface $interface_name"
        fi
    fi
    if [ "$env6" -eq 1 ];then
        if [ -z "$interfacev6" ];then
            # uci set network.lan.ipv6='1' # user decide themself whether to enable IPv6 on LAN.
            # uci set network.lan.ip6assign='64'
            uci set network.${interface6_name}='interface'
            uci set network.${interface6_name}.modem_config="${modem_config}"
            uci set network.${interface6_name}.proto="${protov6}"
            uci set network.${interface6_name}.ifname="@${interface_name}"
            uci set network.${interface6_name}.device="@${interface_name}"
            uci set network.${interface6_name}.metric="${metric}"
            
            local wwan6_num=$(uci -q get firewall.@zone[$num].network | grep -w "${interface6_name}" | wc -l)
            if [ "$wwan6_num" = "0" ]; then
                append_to_fw_zone $num ${interface6_name}
            fi
            network_reload_flag=1
            firewall_reload_flag=1
            m_debug "create interface $interface6_name with proto $protov6 and metric $metric"
        fi
        if [ "$ra_master" = "1" ];then
            uci set dhcp.${interface6_name}='dhcp'
            uci set dhcp.${interface6_name}.interface="${interface6_name}"
            uci set dhcp.${interface6_name}.ra='relay'
            uci set dhcp.${interface6_name}.ndp='relay'
            uci set dhcp.${interface6_name}.master='1'
            uci set dhcp.${interface6_name}.ignore='1'
            uci set dhcp.lan.ra='relay'
            uci set dhcp.lan.ndp='relay'
            uci set dhcp.lan.dhcpv6='relay'
            dhcp_reload_flag=1
        elif [ "$extend_prefix" = "1" ];then
            uci set network.${interface6_name}.extendprefix=1
            dhcpv6=$(uci -q get dhcp.${interface6_name})
            if [ -n "$dhcpv6" ];then
                uci delete dhcp.${interface6_name}
                dhcp_reload_flag=1
            fi
        else
            dhcpv6=$(uci -q get dhcp.${interface6_name})
            if [ -n "$dhcpv6" ];then
                uci delete dhcp.${interface6_name}
                dhcp_reload_flag=1
            fi
        fi
    else
        if [ -n "$interfacev6" ];then
            uci delete network.${interface6_name}
            network_reload_flag=1
            m_debug "delete interface $interface6_name"
        fi
        dhcpv6=$(uci -q get dhcp.${interface6_name})
        if [ -n "$dhcpv6" ];then
            uci delete dhcp.${interface6_name}
            dhcp_reload_flag=1
            if ! uci show dhcp 2>/dev/null | grep -q "\\.master='1'"; then
                [ "$(uci -q get dhcp.lan.ra)" = "relay" ] &&
                    uci -q delete dhcp.lan.ra
                [ "$(uci -q get dhcp.lan.ndp)" = "relay" ] &&
                    uci -q delete dhcp.lan.ndp
                [ "$(uci -q get dhcp.lan.dhcpv6)" = "relay" ] &&
                    uci -q delete dhcp.lan.dhcpv6
            fi
        fi
    fi


    set_modem_netcard=$modem_netcard
    if [ -z "$set_modem_netcard" ];then
        m_debug "no netcard found"
    fi
    ethernet_check=$(handle_5gethernet)
    if [ -n "$ethernet_check" ] && [ -n "/sys/class/net/$ethernet_5g" ] && [ -n "$ethernet_5g" ];then
        set_modem_netcard=$ethernet_5g
    fi
    if [ "$bridge_enabled" = "1" ]; then
        ensure_bridge_passthrough "$set_modem_netcard"
        target_netcard="$bridge_device_name"
    else
        cleanup_bridge_passthrough
        target_netcard="$set_modem_netcard"
    fi
    [ -z "$target_netcard" ] && target_netcard="$set_modem_netcard"

    #set led
    set_led "net" $modem_config $set_modem_netcard
    origin_netcard=$(uci -q get network.$interface_name.ifname)
    origin_device=$(uci -q get network.$interface_name.device)
    origin_metric=$(uci -q get network.$interface_name.metric)
    origin_proto=$(uci -q get network.$interface_name.proto)
    if [ "$origin_netcard" == "$target_netcard" ] && [ "$origin_device" == "$target_netcard" ] && [ "$origin_metric" == "$metric" ] && [ "$origin_proto" == "$base_proto" ];then
        m_debug "interface $interface_name already set to $target_netcard"
    else
        uci set network.${interface_name}.ifname="${target_netcard}"
        uci set network.${interface_name}.device="${target_netcard}"
        uci set network.${interface_name}.modem_config="${modem_config}"
        if [ "$env4" -eq 1 ];then
            uci set network.${interface_name}.proto="${base_proto}"
            uci set network.${interface_name}.metric="${metric}"
            if fm350_is_modem && [ "$base_proto" = "none" ]; then
                uci -q del network.${interface_name}.ipaddr
                uci -q del network.${interface_name}.netmask
                uci -q del network.${interface_name}.gateway
            fi
        elif [ "$fm350_ipv6_transport" -eq 1 ]; then
            uci set network.${interface_name}.proto='none'
            uci -q del network.${interface_name}.ipaddr
            uci -q del network.${interface_name}.netmask
            uci -q del network.${interface_name}.gateway
        fi
        if [ "$env6" -eq 1 ];then
            uci set network.${interface6_name}.proto="${protov6}"
            uci set network.${interface6_name}.metric="${metric}"
        fi
        interface_update_flag=1
        m_debug "set interface $interface_name to $target_netcard"
    fi

    if [ "$bridge_qmodem_dirty" -eq 1 ]; then
        uci commit qmodem
    fi
    if [ "$network_reload_flag" -eq 1 ] || [ "$interface_update_flag" -eq 1 ] || [ "$bridge_network_dirty" -eq 1 ];then
        uci commit network
        if [ "$bridge_network_dirty" -eq 1 ]; then
            /etc/init.d/network reload
            m_debug "network reload"
        else
            ifup ${interface_name}
            ifup ${interface6_name}
            m_debug "network reload"
        fi
    fi
    if [ "$firewall_reload_flag" -eq 1 ];then
        uci commit firewall
        /etc/init.d/firewall restart
        m_debug "firewall reload"
    fi
    if [ "$dhcp_reload_flag" -eq 1 ];then
        uci commit dhcp
        /etc/init.d/dhcp restart
        m_debug "dhcp reload"
    fi
}

flush_if()
{
    network_reload_needed=0
    qmodem_reload_needed=0
    ifdown ${interface_name} >/dev/null 2>&1
    ifdown ${interface6_name} >/dev/null 2>&1
    config_load network
    remove_target="$modem_config"
    config_foreach flush_ip_cb "interface"
    cleanup_bridge_passthrough
    [ "$bridge_network_dirty" -eq 1 ] && network_reload_needed=1
    [ "$bridge_qmodem_dirty" -eq 1 ] && qmodem_reload_needed=1
    set_led "net" $modem_config
    set_led "sim" $modem_config 0
    m_debug "delete interface $interface_name"
    uci commit network
    uci commit dhcp
    [ "$qmodem_reload_needed" -eq 1 ] && uci commit qmodem
    if [ "$network_reload_needed" -eq 1 ]; then
        /etc/init.d/network reload
    fi
}

flush_ip_cb()
{
    local network_cfg=$1
    local bind_modem_config
    config_get bind_modem_config "$network_cfg" modem_config
    if [ "$remove_target" = "$bind_modem_config" ];then
        uci delete network.$network_cfg
        network_reload_needed=1
    fi
    
}

dial(){
    update_config
    m_debug "modem_path=$modem_path,driver=$driver,interface=$interface_name,at_port=$at_port,using_sim_slot:$sim_slot,dns_list:$dns_list,bridge_enabled:$bridge_enabled,bridge_port:$bridge_port"
    while [ "$dial_prepare" != 1 ] ; do
        sleep 5
        update_config
        check_dial_prepare
        dial_prepare=$?
    done
    set_if
    m_debug "dialing $modem_path driver $driver"
    exec_pre_dial $modem_config
    case $driver in
        "qmi")
            qmi_dial
            ;;
        "mbim")
            mbim_dial
            ;;
        "mhi")
            mhi_dial
            ;;
        "ncm")
            at_dial_monitor
            ;;
        "ecm")
            at_dial_monitor
            ;;
        "rndis")
            at_dial_monitor
            ;;
        "mtk_pcie")
            at_dial_monitor
            ;;
        *)
            mbim_dial
            ;;
    esac
}

wwan_hang()
{
    pid=$(cat "${MODEM_RUNDIR}/${modem_config}_dir/$modem_config.pid")
    m_debug "wwan_hang, pid = $pid"
    if [ -n $pid ]; then
        kill $pid
    fi
}

ecm_hang()
{
    m_debug "ecm_hang"
    if fm350_is_modem && [ "$driver" != "mtk_pcie" ] &&
       [ "$fm350_pdp_auto" != "0" ]; then
        local cached_working_cid

        cached_working_cid="$(fm350_cached_cid_for_hang 2>/dev/null)" &&
            pdp_index="$cached_working_cid"
    fi
    auto_dial_hang_fail=0
    auto_dial_hang
    auto_dial_hang_fail=$?
    if [ $auto_dial_hang_fail -eq 0 ]; then
        return
    fi
    case "$manufacturer" in
        "quectel")
            at_command="AT+QNETDEVCTL=$pdp_index,2,1"
            ;;
        "fibocom")
            case "$platform" in
                "mediatek")
                    at_command="AT+CGACT=0,$pdp_index"
                    ;;
                *)
                    at_command="AT+GTRNDIS=0,$pdp_index"
                    ;;
            esac
            ;;
        "meig")
            at_command='AT$QCRMCALL=0,0,3,2,'$pdp_index
            ;;
        "huawei")
            at_command="AT^NDISDUP=0,0"
            ;;
        "neoway")
            delay=3
            at_command='AT$MYUSBNETACT=0,0'
            ;;
        "gosuncn")
            at_command="AT+ZECMCALL=0"
            ;;
        *)
            at_command="ATI"
            ;;
    esac
    at "${at_port}" "${at_command}"
    [ -n "$delay" ] && sleep "$delay"
}

auto_dial_stop(){
    m_debug "stop auto dial"
    case "$manufacturer" in
        "huawei")
        case "$platform" in
            "unisoc")
            ;;
        esac
        ;;
    esac
}


hang()
{
    m_debug "hang up $modem_path driver $driver"
    case $driver in
        "ncm")
            ecm_hang
            ;;
        "ecm")
            ecm_hang
            ;;
        "rndis")
            ecm_hang
            ;;
        "qmi")
            wwan_hang
            ;;
        "mbim")
            wwan_hang
            ;;
        "mhi")
            wwan_hang
            ;;
    esac
    flush_if
}

mbim_dial(){
    if [ -z "$apn" ];then
        apn="auto"
    fi
    qmi_dial
}

mhi_dial()
{
    qmi_dial
}

qmi_dial()
{
    cmd_line="quectel-CM"
    [ -e "/usr/bin/quectel-CM-M" ] && cmd_line="quectel-CM-M" && tom_modified=1
    case $pdp_type in
        "ip") cmd_line="$cmd_line -4" ;;
        "ipv6") cmd_line="$cmd_line -6" ;;
        "ipv4v6") cmd_line="$cmd_line -4 -6" ;;
        *) cmd_line="$cmd_line -4 -6" ;;
    esac

    if [ -n "$pdp_index" ] && [ "$userset_pdp_index" = "1" ]; then
        cmd_line="$cmd_line -n $pdp_index"
    fi
    if [ "$manufacturer" = "telit" ] && [ "$force_set_apn" != "1" ];then
        m_debug 'please use force apn set for telit modem'
    fi
    if [ -n "$apn" ]; then
        cmd_line="$cmd_line -s $apn"
    fi
    if [ -n "$username" ]; then
        cmd_line="$cmd_line $username"
    fi
    if [ -n "$password" ]; then
        cmd_line="$cmd_line $password"
    fi
    if [ "$auth" != "none" ]; then
        cmd_line="$cmd_line $auth"
    fi
    if [ -n "$modem_netcard" ]; then
    qmi_if=$modem_netcard
    #if is wwan* ,use the first part of the name
    if  [[ "$modem_netcard" = "wwan"* ]];then
        qmi_if=$(echo "$modem_netcard" | cut -d_ -f1)
    fi
    #if is rmnet* ,use the first part of the name
    if [[ "$modem_netcard" = "rmnet"* ]];then
        qmi_if=$(echo "$modem_netcard" | cut -d. -f1)
    fi
        cmd_line="${cmd_line} -i ${qmi_if}"
    fi
    if [ "$bridge_enabled" = "1" ];then
        cmd_line="${cmd_line} -b"
    fi
    if [ "$do_not_add_dns" = "1" ];then
        cmd_line="${cmd_line} -D"
    fi
    if [ -e "/usr/bin/quectel-CM-M" ];then
        [ -n "$metric" ] && cmd_line="$cmd_line -d -M $metric"
        [ "$force_set_apn" == "1" ] && cmd_line="$cmd_line -F"
    else
        [ -n "$metric" ] && cmd_line="$cmd_line"
    fi
    cmd_line="$cmd_line -f $log_file"
    while true; do
        m_debug "dialing: $cmd_line"
        $cmd_line &
        echo "$!" > "${MODEM_RUNDIR}/${modem_config}_dir/$modem_config.pid"
        m_debug "pid: $!"
        wait
        m_debug "quectel-CM exited, retrying dial"
    done
}

at_dial()
{
    if [ -z "$pdp_type" ];then
        pdp_type="IP"
    fi
    if fm350_is_modem && [ "$driver" != "mtk_pcie" ] &&
       [ "$fm350_pdp_auto" != "0" ]; then
        fm350_dial
        return $?
    fi
    [ -n "$apn" ] && apn_append=",\"$apn\"" || apn_append=""
    local at_command='AT+COPS=0,0'
    tmp=$(at "${at_port}" "${at_command}")
    pdp_type=$(echo $pdp_type | tr 'a-z' 'A-Z')
    case $manufacturer in
        "quectel")
            [ "$donot_nat" = "1" ] && nat_cfg="AT+QCFG=\"nat\",0" || nat_cfg="AT+QCFG=\"nat\",1"
            case $platform in
                "hisilicon")
                    at_command="AT+QNETDEVCTL=1,1,1"
                    cgdcont_command=""
                    ;;

                "unisoc")
                    at_command="AT+QNETDEVCTL=1,$pdp_index,1" # +QNETDEVCTL: <cid>,<op>,<state> 
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    ;;
                *)
                    at_command="AT+QNETDEVCTL=3,$pdp_index,1" #LTE Standard AT+QNETDEVCTL=<connect_type>[,<CID>[,<URC_switch>]] 
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    ;;
            esac
            ;;
        "fibocom")
            case $platform in
                "qualcomm")
                    at_command="AT+GTRNDIS=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    if [ -n "$auth" ]; then
                        case $auth in
                            "pap")
                                auth_num=1 ;;
                            "chap")
                                auth_num=2 ;;
                            "auto"|"both"|"MsChapV2")
                                auth_num=3 ;;
                            *)
                                auth_num=0 ;;
                        esac
                        if [ -n "$username" ] || [ -n "$password" ] && [ "$auth_num" != "0" ] ; then
                            ppp_auth_command="AT+MGAUTH=$pdp_index,$auth_num,\"$username\",\"$password\""
                        fi
                    fi
                    ;;
                "mediatek")
                    # delay=3
                    # [ "$apn" = "auto" ] || [ -z "$apn" ] && apn="cbnet"
                    if [ "$pdp_index" = "3" ];then
                        delay=3
                        [ "$apn" = "auto" ] || [ -z "$apn" ] && apn="cbnet"
                        m_debug "Due to a historical issue (https://github.com/FUjr/QModem/issues/179#issuecomment-3968653343), the fm350 pdp_index was incorrectly set to 3, which caused dialing to work but remain unstable. In version 2026.2.27, we have fixed this issue."
                        m_debug "To avoid unexpectedly removing legacy configuration files, we applied additional handling to ensure consistent behavior with previous versions. However, if you see this message, please manually set the pdp_index to 0. We apologize for any inconvenience caused."
                    fi
                    at_command="AT+CGACT=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\",\"$apn\""
                    ;;
                "lte")
                    at_command="AT+GTRNDIS=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    if [ -n "$auth" ]; then
                        case $auth in
                            "pap") 
                                auth_num=1 ;;
                            "chap") 
                                auth_num=2 ;;
                            "auto"|"both"|"MsChapV2") 
                                auth_num=3 ;;
                            *) 
                                auth_num=0 ;;
                        esac
                        if [ -n "$username" ] || [ -n "$password" ] && [ "$auth_num" != "0" ] ; then
                            ppp_auth_command="AT+MGAUTH=$pdp_index,$auth_num,\"$username\",\"$password\""
                        fi
                    fi
                    ;;
                "unisoc")
                    at_command="AT+GTRNDIS=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    if [ -n "$auth" ]; then
                        case $auth in
                            "pap") 
                                auth_num=1 ;;
                            "chap") 
                                auth_num=2 ;;
                            "auto"|"both"|"MsChapV2") 
                                auth_num=3 ;;
                            *) 
                                auth_num=0 ;;
                        esac
                        if [ -n "$username" ] || [ -n "$password" ] && [ "$auth_num" != "0" ] ; then
                            ppp_auth_command="AT+MGAUTH=$pdp_index,$auth_num,\"$username\",\"$password\""
                        fi
                    fi
            esac
            ;;
        "huawei")
            case $platform in
                "hisilicon")
                    at_command="AT^NDISDUP=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    if [ -n "$auth" ]; then
                        case $auth in
                            "pap") 
                                auth_num=1 ;;
                            "chap") 
                                auth_num=2 ;;
                            "auto"|"both"|"MsChapV2") 
                                auth_num=3 ;;
                            *) 
                                auth_num=0 ;;
                        esac
                        if [ -n "$username" ] || [ -n "$password" ] && [ "$auth_num" != "0" ] ; then
                            plmn=$(at ${at_port} "AT+COPS=3,2;+COPS?" | grep "+COPS:" | sed 's/+COPS: //g' | cut -d',' -f3 | sed 's/\"//g' | cut -c1-5 | grep -o  -o '[0-9]\{5\}')
                            [ -z "$plmn" ] && plmn="00000"
                            ppp_auth_command="AT^AUTHDATA=$pdp_index,$auth_num,$plmn,\"$username\",\"$password\""
                        fi
                    fi
                    ;;
            esac
            ;;
        "simcom")
            case $platform in
                "asrmicro")                    
                    at_command="AT+CGACT=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    ;;
                "qualcomm")
                    local cnmp=$(at ${at_port} "AT+CNMP?" | grep "+CNMP:" | sed 's/+CNMP: //g' | sed 's/\r//g')
                    at_command="AT+CNMP=$cnmp;+CNWINFO=1"
                    cgdcont_command="AT+CGDCONT=1,\"$pdp_type\""$apn_append
                    ;;
                "lte")
                    at_command="AT+CGACT=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    ;;
            esac
            ;;
        "meig")
            case $platform in
                "qualcomm")
                    at_command='AT$QCRMCALL=1,0,3,2,'$pdp_index
                    cgdcont_command="AT+CGDCONT=1,\"$pdp_type\""$apn_append
                    ;;
            esac
            ;;
        "neoway")
            case $platform in
                "unisoc")
                    at_command='AT$MYUSBNETACT=0,1'
                    cgdcont_command="AT+CGDCONT=1,\"$pdp_type\""$apn_append
                    ;;
            esac
            ;;
        "telit")
            case $platform in
                "qualcomm")
                    at_command="AT#ICMAUTOCONN=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    ;;
            esac
            ;;
        "gosuncn")
            case $platform in
                "lte")
                    at_command="AT+ZECMCALL=1"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    ;;
            esac
            ;;
    esac
	m_debug "dialing: vendor:$manufacturer; platform:$platform; driver:$driver; apn:$apn; command:$at_command pdp_index:$pdp_index"
    m_debug "dial_cmd: $at_command; cgdcont_cmd: $cgdcont_command; ppp_auth_cmd: $ppp_auth_command"
	case $driver in
        "mtk_pcie")
            mbim_port=$(printf '%s' "$at_port" | sed 's/at/mbim/g')
            qmodem_mbim_run "$mbim_port" fm350_mbim_dial_locked \
                "$mbim_port" "$pdp_type" "$apn" \
                "$auth" "$username" "$password"
		 	;;
		*)
  			at "${at_port}" "${cgdcont_command}"
            [ -n "$ppp_auth_command" ] && at "${at_port}" "$ppp_auth_command"
            [ -n "$nat_cfg" ] && at "${at_port}" "$nat_cfg"
        	at "${at_port}" "$at_command"
		 	;;
	esac
}

fm350_mbim_dial_locked()
{
    local mbim_port="$1"
    local requested_pdp="$2"
    local requested_apn="$3"
    local requested_auth="$4"
    local requested_username="$5"
    local requested_password="$6"
    local rf_status

    rf_status=$(umbim -d "$mbim_port" radio |
        sed -n 's/.*swradiostate: *//p')
    if [ "$rf_status" = "off" ]; then
        umbim -d "$mbim_port" radio on || return 1
    fi
    umbim -d "$mbim_port" disconnect >/dev/null 2>&1 || true
    sleep 1
    fm350_mbim_connect "$mbim_port" "$requested_pdp" "$requested_apn" \
        "$requested_auth" "$requested_username" "$requested_password"
}

fm350_mbim_connect()
{
    local mbim_port="$1"
    local requested_pdp="$(normalize_pdp_type "$2")"
    local configured_apn="$3"
    local requested_auth="$4"
    local requested_username="$5"
    local requested_password="$6"
    local normalized_apn
    local tid=2 registration_rc connect_rc

    normalized_apn="$(printf '%s' "$configured_apn" | tr 'A-Z' 'a-z')"
    [ "$normalized_apn" = auto ] && configured_apn=""
    [ "$requested_pdp" = ip ] && requested_pdp=ipv4
    requested_auth="$(printf '%s' "$requested_auth" | tr 'A-Z' 'a-z')"
    case "$requested_auth" in
        none|"") requested_auth="" ;;
        pap|chap|mschapv2) ;;
        *) requested_auth="" ;;
    esac

    # Mirror this firmware's netifd mbim.sh transaction sequence.  caps opens
    # and retains the control session; only then are -n/-t transactions valid.
    umbim -n -d "$mbim_port" caps || return 1
    tid=$((tid + 1))
    umbim -n -t "$tid" -d "$mbim_port" pinstate
    [ "$?" -eq 2 ] && {
        tid=$((tid + 1))
        umbim -t "$tid" -d "$mbim_port" disconnect >/dev/null 2>&1
        return 1
    }
    tid=$((tid + 1))
    umbim -n -t "$tid" -d "$mbim_port" subscriber || {
        tid=$((tid + 1))
        umbim -t "$tid" -d "$mbim_port" disconnect >/dev/null 2>&1
        return 1
    }
    tid=$((tid + 1))
    umbim -n -t "$tid" -d "$mbim_port" registration
    registration_rc=$?
    case "$registration_rc" in
        0|4|5) ;;
        *)
            tid=$((tid + 1))
            umbim -t "$tid" -d "$mbim_port" disconnect >/dev/null 2>&1
            return 1
            ;;
    esac
    tid=$((tid + 1))
    umbim -n -t "$tid" -d "$mbim_port" attach || {
        tid=$((tid + 1))
        umbim -t "$tid" -d "$mbim_port" disconnect >/dev/null 2>&1
        return 1
    }
    tid=$((tid + 1))
    umbim -n -t "$tid" -d "$mbim_port" connect \
        "${requested_pdp}:${configured_apn}" \
        "$requested_auth" "$requested_username" "$requested_password"
    connect_rc=$?
    tid=$((tid + 1))
    if [ "$connect_rc" -eq 0 ]; then
        # Close only the MBIM control session; the activated bearer remains.
        umbim -t "$tid" -d "$mbim_port" config >/dev/null 2>&1 || true
    else
        umbim -t "$tid" -d "$mbim_port" disconnect >/dev/null 2>&1
    fi
    return "$connect_rc"
}

at_auto_dial()
{
    case $manufacturer in
        "huawei")
            case $platform in
                "unisoc")
                    huawei_auto_dial_unisoc
                    return 0
                    ;;
            esac
            ;;
    esac
    return 1
}

huawei_auto_dial_unisoc()
{
    m_debug "huawei_auto_dial: auto dial(no monitor)"
    m_debug "huawei_auto_dial: vendor:$manufacturer; platform:$platform; driver:$driver; apn:$apn; command:$at_command; pdp_index:$pdp_index; huawei_dial_mode:$huawei_dial_mode; at_port:$at_port"
    # dial prepare
    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\",\"$apn\""
    at "$at_port" "$cgdcont_command"
    # get current auto dial setting
    at_command='AT^SETAUTODIAL?'
    at_res=$(at "$at_port" "$at_command" | grep 'SETAUTO')
    # return ^SETAUTODAIL:1,x
    current_setting=${at_res##*:}
    dial_status=$(echo "$current_setting" | cut -d ',' -f 1)
    current_dial_mode=$(echo "$current_setting" | cut -d ',' -f 2)
    m_debug "current dial status: $dial_status, current dial mode: $current_dial_mode"
    # if dial stat is disabled, or when huawei_dial_mode is not empty and current dial mode is not equal to huawei_dial_mode, enable dial
    if [ "$dial_status" = "0" ] || [ ! -z "$huawei_dial_mode" ] && [ "$current_dial_mode" != "$huawei_dial_mode" ]; then
        [ -n "$huawei_dial_mode" ] && dial_mode=",$huawei_dial_mode" || dial_mode=",4"
        at_command="AT^SETAUTODIAL=1$dial_mode"
        at "$at_port" "$at_command"
    fi
}

auto_dial_hang_huawei_unisoc()
{
    m_debug "huawei_auto_hang"
    at_command='AT^SETAUTODIAL?'
    current_setting=$(at "$at_port" "$at_command" | grep 'SETAUTO')
    # return ^SETAUTODAIL:1,x
    current_setting=${current_setting##*:}
    dial_status=$(echo "$current_setting" | cut -d ',' -f 1)
    if [ "$dial_status" = "1" ]; then 
        at_command="AT^SETAUTODIAL=0"
        at "$at_port" "$at_command"
        m_debug "huawei_at_hang: auto hang done"
        m_debug "huawei_at_hang: turning radio off"
        off_cmd="AT+CFUN=0"
        on_cmd="AT+CFUN=1"
        at "$at_port" "$off_cmd"
        m_debug "huawei_at_hang: turning radio on"
        at "$at_port" "$on_cmd"
        return 0
    fi
    return 1
}

auto_dial_hang(){
    m_debug "auto_dial_hang"
    case "$manufacturer" in 
        "huawei")
            case "$platform" in
                "unisoc")
                    auto_dial_hang_huawei_unisoc
                    return $?
                    ;;
            esac
            ;;
    esac
    return 1
}

fm350_mbim_field()
{
    local field="$1"
    local config="$2"

    printf '%s\n' "$config" | awk -v wanted="$field" '
        {
            name = $0
            sub(/:.*/, "", name)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name != wanted)
                next
            value = $0
            sub(/^[^:]*:[[:space:]]*/, "", value)
            gsub(/[[:space:]]+$/, "", value)
            if (value != "")
                print value
        }'
}

fm350_apply_mbim_ipv6_config()
{
    local config="$1"
    local addresses address base prefix normalized valid_addresses=""
    local gateway dns_source dns

    [ "${env6:-0}" = "1" ] || return 0

    # Parse and validate the entire tuple before touching UCI.  If MBIM emits
    # a transient/truncated config, preserving the last committed tuple is
    # safer than leaving pending deletions for a later IPv4 commit.
    addresses="$(fm350_mbim_field ipv6address "$config")"
    for address in $addresses; do
        base="${address%/*}"
        prefix="${address#*/}"
        [ "$prefix" != "$address" ] || continue
        fm350_is_uint "$prefix" || continue
        [ "$prefix" -le 128 ] || continue
        normalized="$(fm350_colon_ipv6 "$base" 2>/dev/null)" || continue
        valid_addresses="${valid_addresses}${valid_addresses:+ }${normalized}/${prefix}"
    done
    if [ -n "$ipv6" ]; then
        [ -n "$valid_addresses" ] || return 1
        gateway="$(fm350_mbim_field ipv6gateway "$config" | head -n 1)"
        gateway="$(fm350_colon_ipv6 "$gateway" 2>/dev/null)" || gateway=""
        dns_source="$dns_list"
        [ -n "$dns_source" ] ||
            dns_source="$(fm350_mbim_field ipv6dnsserver "$config")"
    fi

    uci set network.${interface6_name}='interface' || return 1
    uci set network.${interface6_name}.modem_config="${modem_config}" || return 1
    uci set network.${interface6_name}.ifname="@${interface_name}" || return 1
    uci set network.${interface6_name}.device="@${interface_name}" || return 1
    uci set network.${interface6_name}.metric="${metric}" || return 1
    uci -q delete network.${interface6_name}.ip6addr
    uci -q delete network.${interface6_name}.ip6prefix
    uci -q delete network.${interface6_name}.ip6gw
    uci -q delete network.${interface6_name}.dns
    if [ -n "$ipv6" ]; then
        uci set network.${interface6_name}.proto='static' || return 1
        uci set network.${interface6_name}.defaultroute='1' || return 1
        for address in $valid_addresses; do
            uci add_list network.${interface6_name}.ip6addr="$address" || return 1
            uci add_list network.${interface6_name}.ip6prefix="$address" || return 1
        done
        [ -z "$gateway" ] ||
            uci set network.${interface6_name}.ip6gw="$gateway" || return 1
        if [ "$do_not_add_dns" != "1" ]; then
            if [ -n "$dns_source" ]; then
                uci set network.${interface6_name}.peerdns='0' || return 1
                for dns in $dns_source; do
                    uci add_list network.${interface6_name}.dns="$dns" || return 1
                done
            else
                uci -q delete network.${interface6_name}.peerdns
            fi
        else
            uci -q delete network.${interface6_name}.peerdns
        fi
    else
        # Keep the requested IPv6 child ready for a later single-stack
        # fallback, but never retain an old static MBIM tuple.
        uci set network.${interface6_name}.proto='dhcpv6' || return 1
        uci -q delete network.${interface6_name}.defaultroute
        uci -q delete network.${interface6_name}.peerdns
    fi
    uci commit network || return 1
    ifdown "${interface6_name}" >/dev/null 2>&1 || true
    ifup "${interface6_name}" || return 1
    return 0
}

ip_change_fm350()
{
    m_debug "ip_change_fm350"
    local public_dns1_ipv4="223.5.5.5"
    local public_dns2_ipv4="119.29.29.29"
    local netmask gateway ipv4_config selected_dns dns
    local mbim_address mbim_prefix ipv4_dns1 ipv4_dns2 mbim_config

    if [ "$driver" = "mtk_pcie" ]; then
        mbim_port=$(printf '%s' "$at_port" | sed 's/at/mbim/g')
        mbim_config=$(qmodem_mbim_run "$mbim_port" \
            umbim -d "$mbim_port" config 2>/dev/null) || return 1
        if [ -z "$ipv4" ]; then
            clear_fm350_ipv4_config || return 1
            fm350_apply_mbim_ipv6_config "$mbim_config"
            return $?
        fi
        mbim_address="$(fm350_mbim_field ipv4address "$mbim_config" | head -n 1)"
        ipv4_config="${mbim_address%%/*}"
        mbim_prefix="${mbim_address#*/}"
        [ "$mbim_prefix" = "$mbim_address" ] && mbim_prefix=32
        netmask="$(fm350_prefix_to_netmask "$mbim_prefix" 2>/dev/null)" || {
            m_debug "FM350 PCIe returned invalid IPv4 prefix: $mbim_address"
            return 1
        }
        gateway="$(fm350_mbim_field ipv4gateway "$mbim_config" | head -n 1)"
        fm350_is_valid_ipv4 "$gateway" || gateway=""

        ipv4_dns1="$(fm350_mbim_field ipv4dnsserver "$mbim_config" | head -n 1)"
        ipv4_dns2="$(fm350_mbim_field ipv4dnsserver "$mbim_config" | tail -n 1)"
        [ -z "$ipv4_dns1" ] && ipv4_dns1="$public_dns1_ipv4"
        [ -z "$ipv4_dns2" ] && ipv4_dns2="$public_dns2_ipv4"
        selected_dns="$ipv4_dns1 $ipv4_dns2"
        m_debug "FM350 PCIe config: ipv4=$ipv4_config, gateway=$gateway, netmask=$netmask, dns=$selected_dns"
    else
        fm350_read_runtime_parameters || {
            m_debug "FM350 has no usable IPv4 parameters for CID $pdp_index"
            return 1
        }
        ipv4_config="$fm350_runtime_ipv4"
        netmask="$fm350_runtime_netmask"
        gateway="$fm350_runtime_gateway"
        selected_dns="$fm350_runtime_dns"

        # Very old OEM firmware can omit CGCONTRDP fields.  Retain the legacy
        # route only behind an explicit compatibility flag.  Automatic mode
        # falls back to RNDIS DHCP rather than inventing a /24 and .1 gateway.
        if [ -z "$netmask" ] || [ -z "$gateway" ]; then
            if [ "$fm350_legacy_route_guess" = "1" ]; then
                netmask="255.255.255.0"
                gateway="${ipv4_config%.*}.1"
                m_debug "FM350 legacy route override: $ipv4_config/$netmask via $gateway"
            else
                uci set network.${interface_name}.proto='dhcp' || return 1
                uci -q del network.${interface_name}.ipaddr
                uci -q del network.${interface_name}.netmask
                uci -q del network.${interface_name}.gateway
                uci -q del network.${interface_name}.defaultroute
                if [ "$do_not_add_dns" = "1" ]; then
                    uci set network.${interface_name}.peerdns='0' || return 1
                elif [ -z "$dns_list" ]; then
                    uci -q del network.${interface_name}.peerdns
                fi
                uci commit network || return 1
                ifdown "${interface_name}" >/dev/null 2>&1 || true
                ifup "${interface_name}" || return 1
                m_debug "FM350 CGCONTRDP incomplete; switched $interface_name to RNDIS DHCP"
                return 0
            fi
        fi
    fi
    fm350_is_valid_ipv4 "$ipv4_config" || return 1
    uci set network.${interface_name}.proto='static' || return 1
    uci set network.${interface_name}.ipaddr="${ipv4_config}" || return 1
    uci set network.${interface_name}.netmask="${netmask}" || return 1
    uci -q delete network.${interface_name}.gateway
    [ -z "$gateway" ] ||
        uci set network.${interface_name}.gateway="${gateway}" || return 1
    uci set network.${interface_name}.defaultroute='1' || return 1

    if [ "$do_not_add_dns" != "1" ]; then
        [ -n "$dns_list" ] && selected_dns="$dns_list"
        [ -n "$selected_dns" ] ||
            selected_dns="$public_dns1_ipv4 $public_dns2_ipv4"
        uci set network.${interface_name}.peerdns='0' || return 1
        uci -q del network.${interface_name}.dns
        for dns in $selected_dns; do
            uci add_list network.${interface_name}.dns="$dns" || return 1
        done
    fi
    uci commit network || return 1
    ifdown "${interface_name}" >/dev/null 2>&1 || true
    ifup "${interface_name}" || return 1
    m_debug "set interface $interface_name to $ipv4_config"
    if [ "$driver" = "mtk_pcie" ]; then
        fm350_apply_mbim_ipv6_config "$mbim_config" || return 1
    fi
    return 0
}

clear_fm350_ipv4_config()
{
    # A dual-stack session may be renegotiated as IPv6-only.  Remove the old
    # static IPv4 tuple before acknowledging the address change, otherwise
    # netifd keeps a stale default route indefinitely.
    uci set network.${interface_name}.proto='none' || return 1
    uci -q delete network.${interface_name}.ipaddr
    uci -q delete network.${interface_name}.netmask
    uci -q delete network.${interface_name}.gateway
    uci -q delete network.${interface_name}.defaultroute
    uci -q delete network.${interface_name}.dns
    uci -q delete network.${interface_name}.peerdns
    uci commit network || return 1
    ifdown "${interface_name}" >/dev/null 2>&1 || true
    ifup "${interface_name}" || return 1
    m_debug "FM350 removed stale IPv4 configuration from $interface_name"
}

handle_5gethernet()
{
    case $manufacturer in
        "quectel")
            case $platform in
                "qualcomm")
                    quectel_qualcomm_ethernet
                    ;;
                "unisoc")
                    quectel_unisoc_ethernet
                    ;;
            esac
            ;;
    esac
}

quectel_unisoc_ethernet()
{
    case "$driver" in
        "ncm"|\
        "ecm"|\
        "rndis")
            check_ethernet_cmd="AT+QCFG=\"ethernet\""
            time=0
            while [ $time -lt 5 ]; do
                result=$(at $at_port $check_ethernet_cmd | grep "+QCFG:")
                if [ -n "$result" ]; then
                    if [ -n "$(echo $result | grep "ethernet\",1")" ]; then
                        echo "1"
                        m_debug "5G Ethernet mode is enabled"
                        break
                    fi
                fi
                sleep 5
                time=$((time+1))
            done
        ;;
    esac
}

quectel_qualcomm_ethernet()
{
     case "$driver" in
        "mbim")
            eth_driver_at="AT+QETH=\"eth_driver\""
            data_interface_at="AT+QCFG=\"data_interface\""
            ehter_driver_expect="\"r8125\",1"
            data_interface_expect="\"data_interface\",1"

            time=0
            while [ $time -lt 5 ]; do
                eth_driver_result=$(at $at_port $eth_driver_at | grep "+QETH:")
                time=$(($time+1))
                sleep 1
                if [ -n "$eth_driver_result" ];then
                    break
                fi
            done
            time=0
            while [ $time -lt 5 ]; do
                data_interface_result=$(at $at_port $data_interface_at | grep "+QCFG:")
                time=$(($time+1))
                sleep 1
                if [ -n "$data_interface_result" ];then
                    break
                fi
            done
            eth_driver_pass=$(echo $eth_driver_result | grep "$ehter_driver_expect")
            data_interface_pass=$(echo $data_interface_result | grep "$data_interface_expect")
            if  [ -n "$eth_driver_pass" ] && [ -n "$data_interface_pass" ];then
                echo "1"
                m_debug "5G Ethernet mode is enabled"
            fi
            ;;
    esac
}

handle_ip_change()
{
    export ipv4
    export ipv6
    export connection_status
    m_debug  "ip changed from $ipv6_cache,$ipv4_cache to $ipv6,$ipv4"
    case $manufacturer in
        "fibocom")
            case $platform in
                "mediatek")
                    if [ "$driver" = "mtk_pcie" ]; then
                        ip_change_fm350
                        return $?
                    fi
                    if [ -n "$ipv4" ]; then
                        ip_change_fm350
                        return $?
                    fi
                    if [ -n "$ipv4_cache" ]; then
                        clear_fm350_ipv4_config
                        return $?
                    fi
                    ;;
            esac
            ;;
    esac
    return 0
}

check_cfun(){
    at_command="AT+CFUN?"
    response=$(at ${at_port} "${at_command}")
    cfun_status=$(echo "$response" | tr -d "\r" | grep "+CFUN:" | awk '{print $2}')
    cfun_status=$(echo "$cfun_status" | cut -d',' -f1)
    if [ "$cfun_status" = "1" ]; then
        return 0
    else
        at_command="AT+CFUN=1"
        response=$(at ${at_port} "${at_command}")
        return 1
    fi
}

check_logfile_line()
{
    local line=$(wc -l $log_file | awk '{print $1}')
    if [ $line -gt 300 ];then
        echo "" > $log_file
        m_debug  "log file line is over 300,clear it"
    fi
}

unexpected_response_count=0
at_dial_monitor()
{
    #check if support auto dial
    check_cfun
    if [ $? -ne 0 ]; then
        m_debug "CFUN is not 1, try to set it to 1"
        sleep 5
        check_cfun
        if [ $? -ne 0 ]; then
            m_debug "Failed to set CFUN to 1, dailing may not work properly"
        else
            m_debug "Successfully set CFUN to 1"
        fi
    fi
    auto_dial_support=0
    at_auto_dial
    auto_dial_support=$?
    if [ $auto_dial_support -eq 0 ]; then
        m_debug "dialing service is managed by modem(auto dial), do not need monitor"
        while true; do
            sleep 30
        done
    fi
    ipv4_cache=$ipv4
    ipv6_cache=$ipv6
    at_dial
    sleep 5
    while true; do
        check_ip
        case $connection_status in
            0)
                at_dial
                sleep 3
                ;;
            -1)
                unexpected_response_count=$((unexpected_response_count+1))
                if [ $unexpected_response_count -gt 3 ]; then
                    at_dial
                    unexpected_response_count=0
                fi
                sleep 5
                ;;
            *)
                unexpected_response_count=0
                if [ "$ipv4" != "$ipv4_cache" ] || [ "$ipv6" != "$ipv6_cache" ]; then
                    if handle_ip_change; then
                        ipv4_cache=$ipv4
                        ipv6_cache=$ipv6
                    else
                        m_debug "failed to apply FM350 address change; keeping old cache for retry"
                    fi
                fi

                pdp_type=$(echo $pdp_type | tr 'A-Z' 'a-z')
                if [ "$pdp_type" = "ipv4v6" ]; then
                    local ifup_time=$(ubus call network.interface.$interface6_name status 2>/dev/null | jsonfilter -e '@.uptime' 2>/dev/null || echo 0)
                    local origin_device=$(uci -q get network.$interface_name.device 2>/dev/null || echo "")
                    [ "$ifup_time" -lt 5 ] && continue
                    rdisc6 $origin_device &
                    ndisc6 fe80::1 $origin_device &
                fi
                sleep 15
                ;;
        esac
        check_logfile_line
    done
}

case "$2" in
    "hang")
        debug_subject="modem_hang"
        update_config
        hang;;
    "dial")
        case "$state" in
            "disabled")
                debug_subject="modem_hang"
                hang;;
            *)
                dial;;
        esac
esac
