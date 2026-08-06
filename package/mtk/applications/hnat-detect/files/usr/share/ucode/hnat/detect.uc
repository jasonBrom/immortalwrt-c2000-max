/*
 * OpenWrt Firewall 4 based HNAT wan/lan/lan2 interface Setup Utility.
 *
 * Copyright (C) 2026  chasey-dev <ellenyoung0912@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 *
 * Basic rules:
 *  - Never write Wi-Fi/USB/virtual device names into HNAT.
 *  - Only accept endpoints on GMAC0/GMAC1:
 *      (1) GMAC root netdev: of_node compatible contains "mediatek,eth-mac"
 *      (2) Switch (DSA-like) user port netdev:
 *          has phys_switch_id + phys_port_name, and has a lower_* chain to a GMAC root
 *  - All switch ports are summarized as a single LAN prefix (e.g. "lan") for driver prefix match.
 *  - LAN2 is an independent PHY GMAC-root (has phydev). If none -> "/".
 *  - Rx PPD for Ext devices HNAT, only add to bridge when an ext device is detected.
 */

'use strict';

import { log, merge } from 'hnat.utils.common';
import * as fs from 'fs';
import * as uci from 'uci';
import * as debugfs from 'hnat.utils.debugfs';
import * as sysnet from 'hnat.utils.sysnet';
import * as fw4 from 'hnat.utils.fw4_parser';

const STRICT = getenv('HNAT_DETECT_STRICT') == '1';

if (!debugfs.is_hnat_present()) {
	log.error('skip: HNAT debugfs is unavailable');
	exit(STRICT ? 1 : 0);
}

/* ---------------- Env guard ---------------- */

const ACTION    = getenv('ACTION');
const INTERFACE = getenv('INTERFACE');

const fail = (message) => {
	log.error(message);

	/*
	 * Hotplug runs in strict mode.  Once a topology cannot be proven safe,
	 * leave no old hook active under stale endpoints.  hnat_disable_hook()
	 * synchronously flushes the PPE BIND table, so this is also the
	 * fail-closed barrier for preflight errors.
	 */
	if (STRICT && debugfs.hook_toggle.read() == 'enabled') {
		if (!debugfs.hook_toggle.write('0') ||
		    debugfs.hook_toggle.read() != 'disabled')
			log.error('failed to force HNAT hook off after detector error');
	}

	exit(STRICT ? 1 : 0);
};

const write_debugfs = (node, value, label) => {
	if (!node.write(value))
		fail(`write failed: ${label}`);
};

log.debug(`env: ACTION= ${ACTION || ''} INTERFACE= ${INTERFACE || ''}`);

if (ACTION != 'ifup' && ACTION != 'update')
	exit(0);

if (!INTERFACE || INTERFACE == 'loopback')
	exit(0);

/*
 * Netifd hotplug events may overlap.  Hold one process-wide lock from the
 * state snapshot through hook disable, topology commit/readback, rxppd
 * changes and hook restore.  Acquiring it before fw4 discovery also ensures
 * a queued event resolves the latest topology instead of applying a stale
 * pre-lock snapshot after a newer event.
 */
const DETECT_LOCK = '/var/lock/hnat-detect.lock';
let detect_lock = fs.open(DETECT_LOCK, 'w+');

if (!detect_lock) {
	log.error(`cannot open HNAT detector lock ${DETECT_LOCK}: ${fs.error()}`);
	exit(1);
}

if (!detect_lock.lock('x')) {
	log.error(`cannot acquire HNAT detector lock ${DETECT_LOCK}: ${fs.error()}`);
	detect_lock.close();
	exit(1);
}

/* ---------------- Main selection ---------------- */

let state = fw4.load_state();
if (!state || !state.zones) {
	fail('skip: /var/run/fw4.state missing or invalid JSON');
}

let roots = sysnet.get_gmac_roots();
log.debug('gmac_roots=' + sprintf('%J', roots));

if (!length(roots)) {
	fail('skip: no GMAC roots (mediatek,eth-mac) found');
}

let z = fw4.zmap(state);

let nat_zone = fw4.pick_nat_zone(state, INTERFACE);
if (!nat_zone) {
	fail('skip: no NAT (masq) zone found');
}

let src_zones = fw4.forward_src_zones(nat_zone.name);
log.debug(`forward src_zones: ${src_zones} -> nat_zone: ${nat_zone.name}`);

/* pick lan/lan2 zones */
let lan_zone_name = fw4.pick_best(src_zones, [ 'lan' ]);
let lan2_zone_name = null;

if (length(src_zones) > 1) {
	let other = filter(src_zones, s => s != lan_zone_name);
	lan2_zone_name = fw4.pick_best(other, [ 'lan2', 'dmz', 'guest' ]);
}

log.debug(`lan_zone = ${lan_zone_name || '-'}, lan2_zone = ${lan2_zone_name || '-'}`);

/* resolve zone endpoints */
const zone_devs = (zone_name) => {
	let zone = z[zone_name];
	let devs = fw4.zone_devices(zone);

	if (zone && !length(zone.related_physdevs || []) && length(zone.match_devices || []))
		log.debug(`zone ${zone_name}: related_physdevs empty, fallback match_devices = ${devs}`);

	return devs;
};

const zone_eps = (devs) => uniq(merge(...map(devs, d => sysnet.resolve_endpoints(d, roots, 0))));

let nat_zone_devs  = zone_devs(nat_zone.name);
let lan_zone_devs  = lan_zone_name  ? zone_devs(lan_zone_name)  : [];
let lan2_zone_devs = lan2_zone_name ? zone_devs(lan2_zone_name) : [];

let wan_eps  = zone_eps(nat_zone_devs);
let lan_eps  = zone_eps(lan_zone_devs);
let lan2_eps = zone_eps(lan2_zone_devs);

log.debug(`eps: wan = ${wan_eps}, lan = ${lan_eps}, lan2 = ${lan2_eps}`);

/* classify */
const is_phy_root = (d) => (index(roots, d) >= 0) && sysnet.has_phy(d);
const is_sw_port  = (d) => sysnet.is_switch_port_on_gmac(d, roots);
const is_gmac     = (d) => (index(roots, d) >= 0);

let all_sw = filter(lan_eps, (d) => sysnet.is_switch_port_on_gmac(d, roots));
let has_sw = length(all_sw) > 0;

/* WAN selection:
 * Prefer PHY root > switch port > any GMAC root.
 * If WAN cannot be resolved (e.g. NAT on apcli0/apclix0), do NOT touch WAN
 */
let wan_name =
	filter(wan_eps, d => is_phy_root(d))[0] ||
	filter(wan_eps, d => is_sw_port(d))[0]  ||
	filter(wan_eps, d => is_gmac(d))[0]     ||
	null;

/* LAN selection:
 * Prefer switch prefix "lan" (safe) when switch ports exist, else pick GMAC root endpoint from LAN zone.
 */
let lan_name = null;

if (has_sw) {
	let prefix = sysnet.get_switch_prefix(all_sw);

	/* avoid prefix swallowing WAN if WAN itself shares that prefix (rare, but possible) */
	if (prefix && (!wan_name || index(wan_name, prefix) != 0))
		lan_name = prefix;
	else {
		/* fallback: pick one LAN endpoint not equal to WAN */
		lan_name =
			filter(lan_eps, d => is_sw_port(d) && d != wan_name)[0] ||
			filter(lan_eps, d => is_gmac(d) && d != wan_name)[0]    ||
			filter(lan_eps, d => d != wan_name)[0]                  ||
			null;
	}
} else {
	lan_name =
		filter(lan_eps, d => is_gmac(d))[0] ||
		null;
}

if (!lan_name) {
	fail('skip: cannot resolve LAN endpoint safely');
}

/* LAN2 selection:
 * - Exception 1: No switch, 2 PHY roots, WAN is on one of them -> LAN2 must be "/".
 * - Exception 2: No switch, 2 PHY roots, but WAN is NOT on GMAC (e.g. Wi-Fi) -> Allow LAN2.
 */
let lan2_name = '/';

/* Check basic topology for Exception 1 */
let two_phy_roots = (length(roots) == 2 && length(filter(roots, r => sysnet.has_phy(r))) == 2);

/* Exception 2: No switch AND 2 PHY roots AND WAN is actually using a GMAC */
let block_lan2 = (!has_sw && two_phy_roots && wan_name != null);

if (!block_lan2 && length(roots) >= 2) {
	let prefer =
		filter(lan2_eps, d => is_phy_root(d) && d != wan_name && d != lan_name)[0] ||
		filter(roots,    r => sysnet.has_phy(r) && r != wan_name && r != lan_name)[0]  ||
		null;

	if (prefer)
		lan2_name = prefer;
}

/* PPD (Ping-Pong Device) selection (must be an exact GMAC root):
 * - Source zone is switch ports -> PPD = switch's GMAC root
 * - Source zone is PHY -> PPD = that PHY's GMAC root
 * - Source zone is PHY + switch ports -> prefer switch GMAC root
 * - Source zone is PHY + PHY -> keep existing PPD (apcli scenario)
 */

let ppd_name = null;

if (has_sw) {
	ppd_name = sysnet.resolve_gmac_endpoint(all_sw[0], roots);
} else {
	ppd_name = filter(lan_eps, d => is_gmac(d))[0] || null;
}

log.info(`chosen: ppd = ${ppd_name || '(keep)'}, wan = ${wan_name || '(keep)'}, lan = ${lan_name}, lan2 = ${lan2_name}`);

if (STRICT && !ppd_name)
	fail('skip: cannot resolve PPD endpoint safely');

/* Rx PPD detect logic:
 * Rx PPD is used for Ext devices (such as USB, WWAN) HNAT
 * If NAT zone physical device is ext device, add Rx PPD to bridge device in src zone.
 * Else delete Rx PPD from bridge device in src zone.
 */

const RX_PPD_NAME = "rxppd";
const is_ext = (name) => {
    return match(name, /^(usb|wwan|eth|rmnet|mhi)/);
};
let ext_devs = filter(nat_zone_devs, d => is_ext(d) && !is_gmac(d));

/* cmd queue to exec */
let rx_ppd_cmd = [];

/* remove useless "dummy0" created by default */
if (sysnet.dev_exist("dummy0")) {
	push(rx_ppd_cmd, `ip link delete dummy0`);
}

/* find bridge device in lan zone */
let br_dev = null;
let lan_devs = lan_zone_devs;
for (let dev in lan_devs) {
	if (sysnet.is_bridge(dev)) {
		br_dev = dev;
		break;
	}
}

if (length(ext_devs) > 0) {
	if (!br_dev) {
		if (STRICT)
			fail('skip: external NAT device requires a LAN bridge for rxppd');
	}
	else {
		log.info(`ext devices: ${ext_devs}, enable ${RX_PPD_NAME} on ${br_dev}`);
		/* add Rx PPD */
		if (!sysnet.dev_exist(RX_PPD_NAME)) {
			push(rx_ppd_cmd, `ip link add ${RX_PPD_NAME} type dummy`);
			push(rx_ppd_cmd, `ip link set ${RX_PPD_NAME} up`);
		}
		/* The device may survive a network reload in DOWN state.  Restore it
		 * only when necessary so ordinary ifup events do not toggle HNAT and
		 * flush the PPE flow table. */
		else if (trim(fs.readfile(`/sys/class/net/${RX_PPD_NAME}/operstate`) || '') == 'down') {
			push(rx_ppd_cmd, `ip link set ${RX_PPD_NAME} up`);
		}
		/* add Rx PPD to bridge */
		if (index(sysnet.br_members(br_dev), RX_PPD_NAME) < 0) {
			push(rx_ppd_cmd, `ip link set ${RX_PPD_NAME} master ${br_dev}`);
		}
	}
} else {
	/* no ext devices, remove Rx PPD from bridge */
	if (br_dev && sysnet.dev_exist(RX_PPD_NAME) &&
	    index(sysnet.br_members(br_dev), RX_PPD_NAME) >= 0) {
		push(rx_ppd_cmd, `ip link set ${RX_PPD_NAME} nomaster`);
		log.info(`No ext devices, removing ${RX_PPD_NAME}`);
	}
}

/* Apply every endpoint as one kernel transaction.  The legacy per-endpoint
 * debugfs nodes are read-only so an interrupted event can never expose a
 * half-old, half-new topology.
 */

const hook_toggle = () => debugfs.hook_toggle.read() == 'enabled' ? true : false;

const parse_topology = (value) => {
	let m = match(value || '',
		/^wan=([^ \n]+) lan=([^ \n]+) lan2=([^ \n]+) ppd=([^ \n]+)\n$/);

	if (!m)
		return null;

	return {
		wan: m[1],
		lan: m[2],
		lan2: m[3],
		ppd: m[4],
	};
};

const topology_line = (topology) =>
	`wan=${topology.wan} lan=${topology.lan} lan2=${topology.lan2} ppd=${topology.ppd}`;

let active_topology_line = debugfs.topology.read();
let active_topology = parse_topology(active_topology_line);

if (!active_topology)
	fail('HNAT atomic topology node is missing or returned invalid state');

let desired_topology = {
	/* An unresolved NAT device is an external/Wi-Fi path, not a wired WAN. */
	wan: wan_name || '/',
	lan: lan_name,
	lan2: lan2_name,
	/* Keep a valid existing PPD when generic discovery cannot improve it. */
	ppd: ppd_name || active_topology.ppd,
};
let desired_topology_line = topology_line(desired_topology);
let desired_topology_readback = desired_topology_line + '\n';

let cur_state = {
	hook_toggle: hook_toggle(),
	topology: active_topology_line,
};

let changed = desired_topology_readback != cur_state.topology ||
	(length(rx_ppd_cmd) > 0);

/* if changed, disable hook first */
if (changed && cur_state.hook_toggle) {
	write_debugfs(debugfs.hook_toggle, "0", "hook_toggle");
	if (hook_toggle())
		fail('HNAT hook remained enabled after disable request');
}

if (desired_topology_readback != cur_state.topology) {
	write_debugfs(debugfs.topology, desired_topology_line, "hnat_topology");
	if (debugfs.topology.read() != desired_topology_readback)
		fail('HNAT topology readback did not match the atomic request');
}

for (let cmd in rx_ppd_cmd) {
	if (system(cmd) != 0)
		fail(`command failed: ${cmd}`);
}

if (cur_state.hook_toggle && !hook_toggle()) {
	let board = trim(fs.readfile('/tmp/sysinfo/board_name') || '');
	let restore = true;

	if (board == 'nradio,c2000-max') {
		let cursor = uci.cursor();
		let network = cursor.get_all('network') || {};
		let lan_bridge = null;

		for (let name, section in network) {
			if (section['.type'] == 'device' &&
			    section.type == 'bridge' && section.name == 'br-lan') {
				lan_bridge = section;
				break;
			}
		}
		cursor.load('turboacc');
		let ports = lan_bridge?.ports;
		let eth1_in_lan =
			(type(ports) == 'array' && index(ports, 'eth1') >= 0) ||
			(type(ports) == 'string' &&
			 index(split(trim(ports), /\s+/), 'eth1') >= 0);
		restore =
			eth1_in_lan &&
			!network.c2000_wan && !network.c2000_wan6 &&
			!fs.access('/var/run/c2000max-port-role.switching') &&
			!fs.access('/var/run/c2000max-port-role.degraded') &&
			cursor.get('turboacc', 'config', 'fastpath') == 'mediatek_hnat';
	}

	if (restore) {
		write_debugfs(debugfs.hook_toggle, "1", "hook_toggle");
		if (!hook_toggle())
			fail('HNAT hook remained disabled after restore request');
	}
	else {
		log.info('skip hook restore: TurboACC no longer selects MediaTek HNAT');
		if (board == 'nradio,c2000-max')
			fail('C2000-MAX topology changed while detecting HNAT endpoints');
	}
}

exit(0);
