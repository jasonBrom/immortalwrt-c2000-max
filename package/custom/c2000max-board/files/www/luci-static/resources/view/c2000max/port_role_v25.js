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

function value(v, fallback) {
	return v == null || v === '' ? fallback : String(v);
}

function flag(v) {
	return v === true || v === 1;
}

function integer(v, fallback) {
	const raw = v == null ? '' : String(v).trim();
	const parsed = /^[0-9]+$/.test(raw) ? Number(raw) : NaN;
	return Number.isInteger(parsed) ? parsed : fallback;
}

function inputInteger(node) {
	if (!node || !/^[0-9]+$/.test(node.value.trim()) ||
	    !Number.isInteger(node.valueAsNumber) || !node.validity.valid)
		return -1;
	return node.valueAsNumber;
}

function safeModem(v) {
	const modem = value(v, 'auto');
	return /^[A-Za-z0-9_]+$/.test(modem) ? modem : 'auto';
}

function selectedMode(status) {
	if (status.role !== 'wan')
		return 'lan';
	return status.wan_mode === 'ethernet_5g_balance' ? 'wan5g' : 'wan';
}

function modeLabel(mode) {
	switch (mode) {
	case 'wan':
		return 'WAN（仅网口）';
	case 'wan5g':
		return 'WAN＋5G';
	default:
		return 'LAN';
	}
}

function accelerationLabel(status) {
	if (status.role === 'wan')
		return '已关闭（WAN 模式固定关闭）';
	if (status.effective_fastpath === 'mediatek_hnat')
		return 'MediaTek HNAT';
	if (status.effective_fastpath === 'disabled')
		return '已关闭';
	return '状态未知';
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	renderStatus: function(status) {
		const mode = selectedMode(status);
		const cellularUp = flag(status.cellular_up) || flag(status.qmodem_any_up);
		const rows = [
			[ '当前模式', modeLabel(mode) ],
			[ '2.5G 网口', status.link === 'up' ?
				'已连接%s'.format(status.speed ? '，%s Mbps'.format(status.speed) : '') :
				'未连接' ],
			[ 'LAN 地址', value(status.lan_ip, '未获取') ],
			[ 'WAN 地址', status.role === 'wan' ?
				value(status.wan_ip, '未获取') : '未启用' ],
			[ '5G', mode === 'wan5g' ?
				(cellularUp ? '已联网%s'.format(
					status.cellular_ip ? '，' + status.cellular_ip : '') :
					'正在拨号或尚未联网') :
				(mode === 'lan' ? (cellularUp ? '已联网' : '正在拨号或尚未联网') : '已停用') ],
			[ '网络加速', accelerationLabel(status) ]
		];
		const notices = [];

		if (flag(status.switching))
			notices.push(E('div', { 'class': 'alert-message notice' },
				'正在应用网口模式，请稍候。'));
		if (!flag(status.consistent))
			notices.push(E('div', { 'class': 'alert-message warning' },
				'检测到网口配置不一致，可使用下方“修复网口配置”。'));
		if (status.role === 'wan')
			notices.push(E('div', { 'class': 'alert-message notice' },
				'WAN 口不开放 LuCI/SSH，请通过 Wi-Fi 管理本机。'));

		return E('div', {}, [
			E('table', { 'class': 'table' }, rows.map((row) =>
				E('tr', {}, [
					E('td', { 'class': 'td left', 'width': '34%' }, row[0]),
					E('td', { 'class': 'td left' }, row[1])
				])))
		].concat(notices));
	},

	updateModeControls: function() {
		const mode = document.getElementById('c2000max-port-mode');
		const weight = document.getElementById('c2000max-ethernet-weight');
		const preview = document.getElementById('c2000max-cellular-weight');
		const balanced = mode && mode.value === 'wan5g';
		const ethernetWeight = inputInteger(weight);

		if (weight)
			weight.disabled = !balanced || mode.disabled;
		if (preview)
			preview.textContent = ethernetWeight >= 1 && ethernetWeight <= 99 ?
				'5G %d%%'.format(100 - ethernetWeight) : '请输入 1–99';
	},

	setBusy: function(busy) {
		const mode = document.getElementById('c2000max-port-mode');
		const apply = document.getElementById('c2000max-port-apply');
		const repair = document.getElementById('c2000max-port-repair');

		if (mode)
			mode.disabled = busy;
		if (apply)
			apply.disabled = busy;
		if (repair)
			repair.disabled = busy;
		this.updateModeControls();
	},

	waitForJob: async function(jobId) {
		for (let i = 0; i < 210; i++) {
			await new Promise((resolve) => window.setTimeout(resolve, 1000));
			const job = await L.resolveDefault(callJobStatus(jobId), {});

			if (job.state === 'done') {
				ui.addNotification(null,
					E('p', {}, value(job.message, '网口模式已应用')), 'info');
				window.setTimeout(() => window.location.reload(), 1200);
				return;
			}
			if (job.state === 'failed') {
				ui.addNotification(null,
					E('p', {}, value(job.message, '网口模式应用失败')), 'error');
				this.setBusy(false);
				this.refresh();
				return;
			}
		}

		ui.addNotification(null,
			E('p', {}, '任务仍在运行，请稍后重新打开本页查看。'), 'warning');
		this.setBusy(false);
	},

	applyMode: async function() {
		const modeNode = document.getElementById('c2000max-port-mode');
		const weightNode = document.getElementById('c2000max-ethernet-weight');
		const mode = modeNode ? modeNode.value : 'lan';
		let ethernetWeight = inputInteger(weightNode);

		if (ethernetWeight < 1 || ethernetWeight > 99) {
			ui.addNotification(null,
				E('p', {}, '网口权重必须是 1–99 之间的整数。'), 'error');
			return;
		}

		const role = mode === 'lan' ? 'lan' : 'wan';
		const wanMode = mode === 'wan5g' ?
			'ethernet_5g_balance' : 'ethernet_only';
		const cellularWeight = 100 - ethernetWeight;
		let message = '确认切换为“%s”吗？'.format(modeLabel(mode));

		if (role === 'wan') {
			message += '\n\nWAN 和 WAN＋5G 模式会关闭硬件加速。';
			if (this.currentStatus.role !== 'wan')
				message += '\n有线管理连接将断开，请确认 Wi-Fi 可用。';
		}
		if (!window.confirm(message))
			return;

		this.setBusy(true);
		const response = await L.resolveDefault(callSwitch(
			role,
			wanMode,
			ethernetWeight,
			cellularWeight,
			safeModem(this.currentStatus.cellular_modem)
		), {});

		if (!response.success || !response.job_id) {
			ui.addNotification(null,
				E('p', {}, value(response.message, '无法创建切换任务')), 'error');
			this.setBusy(false);
			return;
		}
		ui.addNotification(null, E('p', {}, '正在应用网口模式。'), 'info');
		this.waitForJob(response.job_id);
	},

	repair: async function() {
		if (!window.confirm('确认修复网口配置吗？\n\n设备将恢复为 LAN 模式并重载网络。'))
			return;

		this.setBusy(true);
		const response = await L.resolveDefault(callRepair(), {});
		if (!response.success || !response.job_id) {
			ui.addNotification(null,
				E('p', {}, value(response.message, '无法创建修复任务')), 'error');
			this.setBusy(false);
			return;
		}
		this.waitForJob(response.job_id);
	},

	refresh: async function() {
		const status = await L.resolveDefault(callStatus(), {});
		const node = document.getElementById('c2000max-port-status');

		this.currentStatus = status;
		if (node)
			L.dom.content(node, this.renderStatus(status));
		this.setBusy(flag(status.switching));
		const repair = document.getElementById('c2000max-port-repair');
		if (repair)
			repair.style.display = flag(status.consistent) ? 'none' : '';
	},

	render: function(status) {
		const mode = selectedMode(status);
		const ethernetWeight = integer(status.ethernet_weight, 60);
		const switching = flag(status.switching);
		const repairVisible = !flag(status.consistent);
		const root = E('div', {}, [
			E('h2', {}, '网口模式'),
			E('div', { 'class': 'cbi-map-descr' },
				'选择 2.5G 网口用途。LAN 模式可使用 MediaTek HNAT；WAN 和 WAN＋5G 模式固定关闭硬件加速。'),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'id': 'c2000max-port-status' },
					this.renderStatus(status))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', {
						'class': 'cbi-value-title',
						'for': 'c2000max-port-mode'
					}, '模式'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('select', {
							'id': 'c2000max-port-mode',
							'class': 'cbi-input-select',
							'disabled': switching,
							'change': L.bind(this.updateModeControls, this)
						}, [
							E('option', { 'value': 'lan', 'selected': mode === 'lan' }, 'LAN'),
							E('option', { 'value': 'wan', 'selected': mode === 'wan' }, 'WAN（仅网口）'),
							E('option', { 'value': 'wan5g', 'selected': mode === 'wan5g' }, 'WAN＋5G')
						])
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', {
						'class': 'cbi-value-title',
						'for': 'c2000max-ethernet-weight'
					}, 'WAN＋5G 权重'),
					E('div', { 'class': 'cbi-value-field' }, [
						'网口 ',
						E('input', {
							'id': 'c2000max-ethernet-weight',
							'class': 'cbi-input-text',
							'type': 'number',
							'min': '1',
							'max': '99',
							'step': '1',
							'value': String(ethernetWeight),
							'disabled': switching || mode !== 'wan5g',
							'input': L.bind(this.updateModeControls, this)
						}),
						'%　',
						E('span', { 'id': 'c2000max-cellular-weight' },
							'5G %d%%'.format(100 - ethernetWeight))
					])
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'id': 'c2000max-port-repair',
					'class': 'btn cbi-button cbi-button-negative',
					'style': repairVisible ? '' : 'display:none',
					'disabled': switching,
					'click': ui.createHandlerFn(this, this.repair)
				}, '修复网口配置'),
				' ',
				E('button', {
					'id': 'c2000max-port-apply',
					'class': 'btn cbi-button cbi-button-action important',
					'disabled': switching,
					'click': ui.createHandlerFn(this, this.applyMode)
				}, '应用')
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
