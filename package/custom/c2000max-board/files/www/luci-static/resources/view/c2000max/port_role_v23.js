'use strict';
'require poll';
'require rpc';
'require ui';
'require view';

const callStatus = rpc.declare({
	object: 'c2000max',
	method: 'port_status',
	expect: { '': {} }
});

const callSwitch = rpc.declare({
	object: 'c2000max',
	method: 'port_switch',
	params: [
		'role',
		'wan_mode',
		'ethernet_weight',
		'cellular_weight',
		'cellular_modem'
	],
	expect: { '': {} }
});

const callRepair = rpc.declare({
	object: 'c2000max',
	method: 'port_repair',
	expect: { '': {} }
});

const callJobStatus = rpc.declare({
	object: 'c2000max',
	method: 'port_job_status',
	params: [ 'job_id' ],
	expect: { '': {} }
});

function text(value, fallback) {
	return value == null || value === '' ? fallback : value;
}

function integer(value, fallback) {
	const raw = typeof value === 'number' ? String(value) :
		value == null ? '' : String(value).trim();
	const parsed = /^[0-9]+$/.test(raw) ? Number(raw) : NaN;
	return Number.isInteger(parsed) ? parsed : fallback;
}

function inputInteger(node) {
	if (!node || !/^[0-9]+$/.test(node.value.trim()) ||
	    !Number.isInteger(node.valueAsNumber) || !node.validity.valid)
		return -1;
	return node.valueAsNumber;
}

function safeModem(value) {
	const modem = text(value, 'auto');
	return /^[A-Za-z0-9_]+$/.test(modem) ? modem : 'auto';
}

function roleName(role) {
	return role === 'wan' ? 'WAN' : role === 'lan' ? 'LAN' : '异常';
}

function fastpathName(value) {
	const names = {
		disabled: '已禁用',
		flow_offloading: '软件流量卸载',
		mediatek_hnat: 'MediaTek HNAT'
	};
	return names[value] || text(value, '未知');
}

function normalizeWanMode(value) {
	return value === 'ethernet_5g_balance' ?
		'ethernet_5g_balance' : 'ethernet_only';
}

function wanModeName(value) {
	return normalizeWanMode(value) === 'ethernet_5g_balance' ?
		'网口宽带 + 5G 叠加' : '仅网口宽带';
}

function configuredEthernetWeight(status) {
	const value = integer(status.ethernet_weight, 60);
	return value >= 1 && value <= 99 ? value : 60;
}

function configuredCellularWeight(status, ethernetWeight) {
	const value = integer(status.cellular_weight, 100 - ethernetWeight);
	return value >= 1 && value <= 99 && value + ethernetWeight === 100 ?
		value : 100 - ethernetWeight;
}

function modemEntries(modems) {
	const source = [];
	const result = [];

	if (Array.isArray(modems)) {
		modems.forEach((item) => source.push({ item: item, fallback: '' }));
	}
	else if (modems && typeof modems === 'object') {
		Object.keys(modems).forEach((key) =>
			source.push({ item: modems[key], fallback: key }));
	}

	source.forEach((entry) => {
		const item = entry.item;
		let id;
		let label;

		if (item != null && typeof item === 'object') {
			id = item.section || item.id || item.value || item.name ||
				entry.fallback || item.interface || item.network || item.device;
			label = item.label || item.display_name || item.model || item.name;
			if (!label && item.interface)
				label = '%s（%s%s）'.format(
					id, item.interface,
					item.up === true || item.up === 1 ? '，已联网' : '，未联网');
			label = label || item.interface || item.network || item.device || id;
		}
		else if (entry.fallback) {
			id = entry.fallback;
			label = item || entry.fallback;
		}
		else {
			id = item;
			label = item;
		}

		id = id == null ? '' : String(id);
		label = label == null ? id : String(label);
		if (!id || id === 'auto' || result.some((candidate) => candidate.id === id))
			return;
		result.push({ id: id, label: label });
	});

	return result;
}

function modemName(value, modems) {
	const id = text(value, 'auto');
	const entry = modemEntries(modems).find((candidate) => candidate.id === id);

	if (id === 'auto')
		return '自动选择';
	return entry ? entry.label : id;
}

function selectOption(value, label, selected) {
	const attributes = { 'value': value };

	if (selected)
		attributes.selected = 'selected';
	return E('option', attributes, label);
}

function modemOptions(modems, selected) {
	const current = text(selected, 'auto');
	const entries = modemEntries(modems);
	const options = [
		selectOption('auto', '自动选择可用 5G 接口', current === 'auto')
	];

	entries.forEach((entry) =>
		options.push(selectOption(entry.id, entry.label, current === entry.id)));
	if (current !== 'auto' &&
	    !entries.some((entry) => entry.id === current))
		options.push(selectOption(current, current, true));
	return options;
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	renderStatus: function(status) {
		const consistent = status.consistent === true || status.consistent === 1;
		const runtimeConsistent = status.runtime_consistent === true ||
			status.runtime_consistent === 1;
		const accelerationConsistent = status.acceleration_consistent === true ||
			status.acceleration_consistent === 1;
		const accelerationDegraded = status.acceleration_degraded === true ||
			status.acceleration_degraded === 1;
		const networkConverged = status.network_converged === true ||
			status.network_converged === 1;
		const accelChanged = status.expected_fastpath !== status.effective_fastpath;
		const gmacReady = status.gmac_ready === true || status.gmac_ready === 1;
		const ppeIdle = status.ppe_idle === true || status.ppe_idle === 1;
		const whnatReady = status.whnat_ready === true || status.whnat_ready === 1;
		const rxppdReady = status.rxppd_ready === true || status.rxppd_ready === 1;
		const endpointsReady = status.endpoints_ready === true || status.endpoints_ready === 1;
		const uplinkConsistent = status.uplink_consistent === true ||
			status.uplink_consistent === 1;
		const servicesConsistent = status.services_consistent === true ||
			status.services_consistent === 1;
		const qmodemDialEnabled = status.qmodem_dial_enabled === true ||
			status.qmodem_dial_enabled === 1;
		const qmodemServiceEnabled = status.qmodem_enabled === true ||
			status.qmodem_enabled === 1;
		const qmodemRunning = status.qmodem_running === true ||
			status.qmodem_running === 1;
		const qmodemAnyUp = status.qmodem_any_up === true ||
			status.qmodem_any_up === 1;
		const mwanManaged = status.mwan_managed === true || status.mwan_managed === 1;
		const mwanRunning = status.mwan_running === true || status.mwan_running === 1;
		const cellularUp = status.cellular_up === true || status.cellular_up === 1;
		const wanMode = normalizeWanMode(status.wan_mode);
		const ethernetWeight = configuredEthernetWeight(status);
		const cellularWeight = configuredCellularWeight(status, ethernetWeight);
		const rows = [
			[ '当前角色', roleName(status.role) ],
			[ '物理网口', '%s（链路：%s%s）'.format(
				text(status.port, 'eth1'),
				status.link === 'up' ? '已连接' : '未连接',
				status.speed ? '，' + status.speed + ' Mbps' : '') ],
			[ 'LAN 管理地址', text(status.lan_ip, '192.168.66.1') ],
			[ 'WAN 地址', text(status.wan_ip, '尚未获取') ],
			[ 'WAN 上网模式', wanModeName(wanMode) ],
			[ 'IPv4 新连接分流比例', wanMode === 'ethernet_5g_balance' ?
				'网口 %d%% / 5G %d%%'.format(ethernetWeight, cellularWeight) :
				'网口 100% / 5G 停止拨号' ],
			[ '5G 上网接口', wanMode === 'ethernet_5g_balance' ?
				modemName(status.cellular_modem, status.cellular_modems) :
				'未启用' ],
			[ '网络 / WAN 配置 / 服务运行态', '%s / %s / %s'.format(
				networkConverged ? '已收敛' : '未收敛',
				uplinkConsistent ? '已收敛' : '未收敛',
				servicesConsistent ? '已收敛' : '未收敛') ],
			[ 'QModem 拨号', qmodemDialEnabled ?
				'配置允许 / 开机%s / 进程%s / %s'.format(
					qmodemServiceEnabled ? '启用' : '禁用',
					qmodemRunning ? '运行' : '停止',
					qmodemAnyUp ?
						'%s 已联网%s'.format(
							text(status.qmodem_interface, '5G 接口'),
							status.qmodem_ip ? '，' + status.qmodem_ip : '') :
						'接口尚未联网') :
				'配置已停止' ],
			[ 'mwan3 分流', wanMode === 'ethernet_5g_balance' ?
				'%s，%s'.format(
					mwanManaged ? '受管规则已配置' : '受管规则缺失',
					mwanRunning ? '服务已运行' : '服务未运行') :
				'此模式不使用 mwan3 叠加规则' ],
			[ '5G 运行状态', wanMode === 'ethernet_5g_balance' ?
				'%s（%s%s）'.format(
					text(status.cellular_interface, '尚未解析接口'),
					cellularUp ? '已联网' : '未联网',
					status.cellular_ip ? '，' + status.cellular_ip : '') :
				'未参与上网' ],
			[ '用户选择的加速模式', fastpathName(status.requested_fastpath) ],
			[ '5G 分支 HNAT', wanMode === 'ethernet_5g_balance' ?
				'实验性：取决于模块实际 netdev / PPE 外部接口注册' :
				'不适用' ],
			[ '当前有效加速模式', fastpathName(status.effective_fastpath) ],
			[ 'MTK GMAC 验证', gmacReady ? 'eth0 / eth1 均已确认' : '未通过' ],
			[ 'eth0 PPE 回注口', ppeIdle ? '未被 UCI/桥占用' : '被占用或运行态不安全' ],
			[ 'WHNAT / rxppd', '%s / %s'.format(
				whnatReady ? 'Wi-Fi 已注册' : '未就绪',
				rxppdReady ? 'br-lan 已就绪' : '未就绪') ],
			[ 'PPE 端点回读', endpointsReady ?
				'WAN=%s，LAN=%s，LAN2=%s，PPD=%s'.format(
					text(status.hnat_wan, '-'), text(status.hnat_lan, '-'),
					text(status.hnat_lan2, '-'), text(status.hnat_ppd, '-')) :
				'未通过' ],
			[ 'EQoS', status.eqos === 'paused' ?
				(status.requested_fastpath === 'mediatek_hnat' ?
					'已暂停（切回 LAN 自动恢复）' :
					'已暂停（TurboACC 当前关闭加速）') :
				status.eqos === 'configured' ? '已配置（由网口状态机管理运行态）' : '已禁用' ]
		];

		const notes = [];
		if (status.recovery_pending)
			notes.push(E('div', { 'class': 'alert-message warning' },
				'检测到未完成的持久化切换日志；系统会保持 HNAT 与受管上行关闭，直到恢复事务验证完成。'));
		if (status.switching)
			notes.push(E('div', { 'class': 'alert-message notice' },
				'切换任务正在执行，两个切换按钮和 WAN 设置已锁定，请等待运行态校验完成。'));
		if (status.degraded)
			notes.push(E('div', { 'class': 'alert-message danger' },
				'上一次网络事务未能完成验证；加速已强制关闭。请使用“一键修复 LAN 与 5G 网络”。'));
		if (accelerationDegraded)
			notes.push(E('div', { 'class': 'alert-message warning' },
				text(status.acceleration_error,
					'网络角色可用，但硬件加速尚未通过运行态验证并保持关闭。')));
		if (!consistent)
			notes.push(E('div', { 'class': 'alert-message danger' },
				'检测到 eth1 同时属于 LAN/WAN，或两边都不属于。为避免失联，切换已锁定。'));
		else if (!runtimeConsistent)
			notes.push(E('div', { 'class': 'alert-message warning' },
				'运行态网口归属与 UCI 不一致。请点击当前角色按钮重新加载并验证网络。'));
		if (Object.prototype.hasOwnProperty.call(status, 'uplink_consistent') &&
		    !uplinkConsistent)
			notes.push(E('div', { 'class': 'alert-message warning' },
				'WAN 上网模式尚未收敛到配置要求。请重新应用当前角色与 WAN 设置。'));
		if (Object.prototype.hasOwnProperty.call(status, 'services_consistent') &&
		    !servicesConsistent)
			notes.push(E('div', { 'class': 'alert-message warning' },
				'QModem 或 mwan3 服务状态尚未收敛，当前角色不会被标记为完成。'));
		if (status.requested_fastpath === 'mediatek_hnat' && accelChanged)
			notes.push(E('div', { 'class': 'alert-message danger' },
				'实际加速状态尚未收敛到当前角色要求。请点击当前角色按钮重新收敛；异常状态不会启用 HNAT。'));
		else if (status.requested_fastpath === 'mediatek_hnat' &&
		         !accelerationConsistent)
			notes.push(E('div', { 'class': 'alert-message warning' },
				'尚未完成加速运行态验证，请点击当前角色按钮重新收敛。'));
		if (status.requested_fastpath === 'mediatek_hnat' &&
		    (!gmacReady || !ppeIdle || !whnatReady || !rxppdReady || !endpointsReady))
			notes.push(E('div', { 'class': 'alert-message danger' },
				'硬件 HNAT 门槛未全部通过。网络角色仍可正常生效，但 HNAT 会保持关闭且不会回退到软件卸载。'));
		if (status.role === 'wan')
			notes.push(E('div', { 'class': 'alert-message notice' },
				'WAN 口不会开放 LuCI/SSH。请通过 Wi-Fi 连接 LAN，并使用上方 LAN 地址管理设备。'));
		if (status.role === 'wan' && wanMode === 'ethernet_5g_balance')
			notes.push(E('div', { 'class': 'alert-message notice' },
				'mwan3 仅按 IPv4 新连接权重分流；单个 TCP 连接只走一条链路。网口侧 HNAT 已验证，5G 分支硬件卸载仍需按实际模块实机验证。'));

		return E('div', {}, [
			E('table', { 'class': 'table' }, rows.map((row) =>
				E('tr', {}, [
					E('td', { 'class': 'td left', 'width': '35%' }, row[0]),
					E('td', { 'class': 'td left' }, row[1])
				])))
		].concat(notes));
	},

	updateWeightPreview: function() {
		const input = document.getElementById('c2000max-ethernet-weight');
		const preview = document.getElementById('c2000max-cellular-weight');
		const value = inputInteger(input);

		if (!preview)
			return;
		preview.textContent = value >= 1 && value <= 99 ?
			'蜂窝 5G：%d%%'.format(100 - value) :
			'请输入 1–99';
	},

	updateWanModeControls: function() {
		const mode = document.getElementById('c2000max-wan-mode');
		const weight = document.getElementById('c2000max-ethernet-weight');
		const modem = document.getElementById('c2000max-cellular-modem');
		const balanced = mode && mode.value === 'ethernet_5g_balance';
		const locked = !mode || mode.disabled;

		if (weight)
			weight.disabled = locked || !balanced;
		if (modem)
			modem.disabled = locked || !balanced;
		this.updateWeightPreview();
	},

	readWanSettings: function() {
		const modeNode = document.getElementById('c2000max-wan-mode');
		const weightNode = document.getElementById('c2000max-ethernet-weight');
		const modemNode = document.getElementById('c2000max-cellular-modem');
		const wanMode = normalizeWanMode(modeNode ? modeNode.value : 'ethernet_only');
		let ethernetWeight = inputInteger(weightNode);

		if (ethernetWeight < 1 || ethernetWeight > 99) {
			if (wanMode === 'ethernet_only')
				ethernetWeight = configuredEthernetWeight(this.currentStatus || {});
		}
		if (ethernetWeight < 1 || ethernetWeight > 99) {
			ui.addNotification(null,
				E('p', {}, '网口比例必须是 1–99 之间的整数。'), 'error');
			if (weightNode) {
				weightNode.focus();
				weightNode.select();
			}
			return null;
		}

		if (weightNode)
			weightNode.value = String(ethernetWeight);
		return {
			wanMode: wanMode,
			ethernetWeight: ethernetWeight,
			cellularWeight: 100 - ethernetWeight,
			cellularModem: modemNode && modemNode.value ?
				modemNode.value : 'auto'
		};
	},

	waitForJob: async function(jobId) {
		for (let i = 0; i < 210; i++) {
			await new Promise((resolve) => window.setTimeout(resolve, 1000));
			const job = await L.resolveDefault(callJobStatus(jobId), {});
			if (job.state === 'done') {
				ui.addNotification(null, E('p', {}, text(job.message, '切换完成')), 'info');
				window.setTimeout(() => window.location.reload(), 1500);
				return;
			}
			if (job.state === 'failed') {
				ui.addNotification(null, E('p', {}, text(job.message, '切换失败')), 'error');
				this.refresh();
				return;
			}
		}
		ui.addNotification(null, E('p', {}, '切换仍在进行，请稍后重新打开本页。'), 'warning');
	},

	repairNetwork: async function() {
		if (!window.confirm(
			'确认执行网络修复吗？\n\n此操作会把 eth1 恢复为 LAN、清理未完成的受管 WAN/mwan3 状态，并重新启用 QModem 5G 拨号。修复期间网络会短暂重载。'))
			return;

		this.setControls({
			role: this.currentStatus ? this.currentStatus.role : 'lan',
			consistent: true,
			switching: true,
			wifi_management: true
		});
		const response = await L.resolveDefault(callRepair(), {});
		if (!response.success || !response.job_id) {
			ui.addNotification(null,
				E('p', {}, text(response.message, '无法创建网络修复任务')), 'error');
			this.refresh();
			return;
		}
		ui.addNotification(null,
			E('p', {}, '修复请求已接收，正在恢复 LAN、QModem 与防火墙。'), 'info');
		this.waitForJob(response.job_id);
	},

	switchRole: async function(role) {
		const current = this.currentStatus || {};
		const currentEthernetWeight = configuredEthernetWeight(current);
		const settings = role === 'lan' ? {
			wanMode: normalizeWanMode(current.wan_mode),
			ethernetWeight: currentEthernetWeight,
			cellularWeight: configuredCellularWeight(
				current, currentEthernetWeight),
			cellularModem: safeModem(current.cellular_modem)
		} : this.readWanSettings();
		const reapplyWan = role === 'wan' && this.currentStatus &&
			this.currentStatus.role === 'wan';
		const target = roleName(role);
		let message;

		if (!settings)
			return;
		message = reapplyWan ?
			'确认应用新的 WAN 上网设置吗？' :
			'确认把唯一物理网口切换为 ' + target + ' 吗？';
		if (role === 'wan') {
			if (settings.wanMode === 'ethernet_5g_balance')
				message += '\n\n将按 IPv4 新连接使用网口 %d%%、5G %d%% 的权重分流，蜂窝接口为“%s”；单个 TCP 连接不会叠加带宽。'.format(
					settings.ethernetWeight, settings.cellularWeight,
					settings.cellularModem === 'auto' ? '自动选择' : settings.cellularModem);
			else
				message += '\n\n将仅使用网口宽带接入外网，并停止 QModem 蜂窝拨号。';
			if (!reapplyWan)
				message += '\n\n当前有线 LuCI 会在约 2 秒后断开，请先确认可通过 Wi-Fi 恢复管理。';
				if (current.requested_fastpath === 'mediatek_hnat')
					message += '\n\n网络与服务会先完成切换，再重绑并验证 HNAT；HNAT 门槛失败只会让硬件加速保持关闭，不会撤销已经可用的 WAN 网络。5G 分支 HNAT 仍取决于实际模块的 netdev/PPE 注册。';
				else
					message += '\n\nTurboACC 当前选择关闭加速；切换会保持该选择，不会自动打开 HNAT。';
			}
			else {
				message += '\n\n切换期间网络和加速状态会短暂重载；若 HNAT 验证失败，LAN 与 5G 网络仍会保留，硬件加速则保持关闭。';
			}
		if (!window.confirm(message))
			return;

		this.setControls({
			role: role,
			consistent: true,
			switching: true,
			wifi_management: true
		});
		const response = await L.resolveDefault(callSwitch(
			role,
			settings.wanMode,
			settings.ethernetWeight,
			settings.cellularWeight,
			settings.cellularModem
		), {});
		if (!response.success || !response.job_id) {
			ui.addNotification(null,
				E('p', {}, text(response.message, '无法创建切换任务')), 'error');
			this.refresh();
			return;
		}
		ui.addNotification(null,
			E('p', {}, reapplyWan ?
				'请求已接收，正在应用 WAN 上网设置。' :
				'请求已接收，正在安全切换网络与加速状态。'), 'info');
		this.waitForJob(response.job_id);
	},

	refresh: async function() {
		const status = await L.resolveDefault(callStatus(), {});
		const node = document.getElementById('c2000max-port-status');

		this.currentStatus = status;
		if (node)
			L.dom.content(node, this.renderStatus(status));
		this.setControls(status);
	},

	setControls: function(status) {
		const consistent = status.consistent === true || status.consistent === 1;
		const switching = status.switching === true || status.switching === 1;
		const degraded = status.degraded === true || status.degraded === 1;
		const networkConverged = status.network_converged === true ||
			status.network_converged === 1;
		const accelerationConsistent = status.acceleration_consistent === true ||
			status.acceleration_consistent === 1;
		const accelerationDegraded = status.acceleration_degraded === true ||
			status.acceleration_degraded === 1;
		const lan = document.getElementById('c2000max-role-lan');
		const wan = document.getElementById('c2000max-role-wan');
		const repair = document.getElementById('c2000max-network-repair');
		const mode = document.getElementById('c2000max-wan-mode');

		if (lan)
			lan.disabled = !consistent || switching ||
				(status.role === 'lan' && networkConverged && !degraded &&
					accelerationConsistent && !accelerationDegraded);
		if (lan)
			lan.textContent = status.role === 'wan' ?
				'紧急切回 LAN 口' : '切换为 LAN 口';
		if (wan) {
			wan.disabled = !consistent || switching ||
				(status.role !== 'wan' && !networkConverged) ||
				!status.wifi_management;
			wan.textContent = status.role === 'wan' ?
				'应用 WAN 设置' : '切换为 WAN 口';
			wan.title = status.wifi_management ? '' :
				'未发现已启用且实际挂入 br-lan 的 Wi-Fi LAN 接入点';
		}
		if (mode)
			mode.disabled = !consistent || switching;
		if (repair)
			repair.disabled = switching;
		this.updateWanModeControls();
	},

	render: function(status) {
		const consistent = status.consistent === true || status.consistent === 1;
		const current = status.role;
		const switching = status.switching === true || status.switching === 1;
		const degraded = status.degraded === true || status.degraded === 1;
		const networkConverged = status.network_converged === true ||
			status.network_converged === 1;
		const accelerationConsistent = status.acceleration_consistent === true ||
			status.acceleration_consistent === 1;
		const accelerationDegraded = status.acceleration_degraded === true ||
			status.acceleration_degraded === 1;
		const wanMode = normalizeWanMode(status.wan_mode);
		const ethernetWeight = configuredEthernetWeight(status);
		const cellularModem = text(status.cellular_modem, 'auto');
		const settingsLocked = !consistent || switching;
		const root = E('div', {}, [
			E('h2', {}, '网口 LAN / WAN 一键切换'),
			E('div', { 'class': 'cbi-map-descr' },
				'切换对象是 C2000-MAX 唯一的 2.5G 物理网口 eth1。WAN 可选择仅使用网口宽带，或让网口与 5G 分流。LAN/WAN 都支持 MediaTek HNAT，但是否启用由 TurboACC 的用户设置决定；加速验证失败不会再回滚可用网络。'),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '状态'),
				E('div', { 'id': 'c2000max-port-status' }, this.renderStatus(status))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'WAN 上网设置'),
				E('div', { 'class': 'cbi-section-descr' },
					'“仅网口宽带”会停止并禁用 QModem 蜂窝拨号；“网口宽带 + 5G 叠加”会自动配置 mwan3，仅按 IPv4 新连接权重近似分流。IPv6 不参与 V23 权重分流，单个 TCP 连接也不会带宽相加。'),
				E('div', { 'class': 'cbi-value' }, [
					E('label', {
						'class': 'cbi-value-title',
						'for': 'c2000max-wan-mode'
					}, 'WAN 模式'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('select', {
							'id': 'c2000max-wan-mode',
							'class': 'cbi-input-select',
							'disabled': settingsLocked,
							'change': L.bind(this.updateWanModeControls, this)
						}, [
							selectOption('ethernet_only', '仅网口宽带',
								wanMode === 'ethernet_only'),
							selectOption('ethernet_5g_balance', '网口宽带 + 5G 叠加',
								wanMode === 'ethernet_5g_balance')
						])
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', {
						'class': 'cbi-value-title',
						'for': 'c2000max-ethernet-weight'
					}, '网口分流比例'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'id': 'c2000max-ethernet-weight',
							'class': 'cbi-input-text',
							'type': 'number',
							'min': '1',
							'max': '99',
							'step': '1',
							'value': String(ethernetWeight),
							'disabled': settingsLocked ||
								wanMode !== 'ethernet_5g_balance',
							'input': L.bind(this.updateWeightPreview, this)
						}),
						' %　',
						E('span', { 'id': 'c2000max-cellular-weight' },
							'蜂窝 5G：%d%%'.format(100 - ethernetWeight))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', {
						'class': 'cbi-value-title',
						'for': 'c2000max-cellular-modem'
					}, '5G 上网接口'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('select', {
							'id': 'c2000max-cellular-modem',
							'class': 'cbi-input-select',
							'disabled': settingsLocked ||
								wanMode !== 'ethernet_5g_balance'
						}, modemOptions(status.cellular_modems, cellularModem))
					])
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'id': 'c2000max-role-lan',
					'class': 'btn cbi-button cbi-button-positive',
					'disabled': !consistent || switching ||
						(current === 'lan' && networkConverged && !degraded &&
							accelerationConsistent && !accelerationDegraded),
					'click': ui.createHandlerFn(this, this.switchRole, 'lan')
				}, current === 'wan' ? '紧急切回 LAN 口' : '切换为 LAN 口'),
				' ',
				E('button', {
					'id': 'c2000max-role-wan',
					'class': 'btn cbi-button cbi-button-action important',
					'disabled': !consistent || switching ||
						(current !== 'wan' && !networkConverged) ||
						!status.wifi_management,
					'title': status.wifi_management ? '' :
						'未发现已启用的 Wi-Fi LAN 接入点',
					'click': ui.createHandlerFn(this, this.switchRole, 'wan')
				}, current === 'wan' ? '应用 WAN 设置' : '切换为 WAN 口'),
				' ',
				E('button', {
					'id': 'c2000max-network-repair',
					'class': 'btn cbi-button cbi-button-negative',
					'disabled': switching,
					'click': ui.createHandlerFn(this, this.repairNetwork)
				}, '一键修复 LAN 与 5G 网络')
			])
		]);

		this.currentStatus = status;
		poll.add(L.bind(this.refresh, this), 5);
		return root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
