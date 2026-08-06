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
	params: [ 'role' ],
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
		const accelChanged = status.expected_fastpath !== status.effective_fastpath;
		const gmacReady = status.gmac_ready === true || status.gmac_ready === 1;
		const ppeIdle = status.ppe_idle === true || status.ppe_idle === 1;
		const whnatReady = status.whnat_ready === true || status.whnat_ready === 1;
		const rxppdReady = status.rxppd_ready === true || status.rxppd_ready === 1;
		const endpointsReady = status.endpoints_ready === true || status.endpoints_ready === 1;
		const rows = [
			[ '当前角色', roleName(status.role) ],
			[ '物理网口', '%s（链路：%s%s）'.format(
				text(status.port, 'eth1'),
				status.link === 'up' ? '已连接' : '未连接',
				status.speed ? '，' + status.speed + ' Mbps' : '') ],
			[ 'LAN 管理地址', text(status.lan_ip, '192.168.66.1') ],
			[ 'WAN 地址', text(status.wan_ip, '尚未获取') ],
			[ '强制加速模式', 'MediaTek HNAT（不允许软件卸载回退）' ],
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
			[ 'EQoS', status.eqos === 'paused' ? '已暂停（切回 LAN 自动恢复）' :
				status.eqos === 'configured' ? '已配置（由网口状态机管理运行态）' : '已禁用' ]
		];

		const notes = [];
		if (status.switching)
			notes.push(E('div', { 'class': 'alert-message notice' },
				'切换任务正在执行，两个切换按钮已锁定，请等待运行态校验完成。'));
		if (status.degraded)
			notes.push(E('div', { 'class': 'alert-message danger' },
				'上一次切换未能完成验证或回滚；HNAT 已强制关闭。可点击当前角色重新执行收敛。'));
		if (!consistent)
			notes.push(E('div', { 'class': 'alert-message danger' },
				'检测到 eth1 同时属于 LAN/WAN，或两边都不属于。为避免失联，切换已锁定。'));
		else if (!runtimeConsistent)
			notes.push(E('div', { 'class': 'alert-message warning' },
				'运行态网口归属与 UCI 不一致。请点击当前角色按钮重新加载并验证网络。'));
		if (accelChanged)
			notes.push(E('div', { 'class': 'alert-message danger' },
				'实际加速状态尚未收敛到当前角色要求。请点击当前角色按钮重新收敛；异常状态不会启用 HNAT。'));
		else if (!accelerationConsistent)
			notes.push(E('div', { 'class': 'alert-message warning' },
				'尚未完成加速运行态验证，请点击当前角色按钮重新收敛。'));
		if (!gmacReady || !ppeIdle || !whnatReady || !rxppdReady || !endpointsReady)
			notes.push(E('div', { 'class': 'alert-message danger' },
				'硬件 HNAT 门槛未全部通过。切换不会使用软件卸载；目标角色验证失败时会连同加速配置一起回滚。'));
		if (status.role === 'wan')
			notes.push(E('div', { 'class': 'alert-message notice' },
				'WAN 口不会开放 LuCI/SSH。请通过 Wi-Fi 连接 LAN，并使用上方 LAN 地址管理设备。'));

		return E('div', {}, [
			E('table', { 'class': 'table' }, rows.map((row) =>
				E('tr', {}, [
					E('td', { 'class': 'td left', 'width': '35%' }, row[0]),
					E('td', { 'class': 'td left' }, row[1])
				])))
		].concat(notes));
	},

	waitForJob: async function(jobId) {
		for (let i = 0; i < 45; i++) {
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

	switchRole: async function(role) {
		const target = roleName(role);
		let message = '确认把唯一物理网口切换为 ' + target + ' 吗？';
		if (role === 'wan')
			message += '\n\n当前有线 LuCI 会在约 2 秒后断开。系统检测到了 Wi-Fi LAN AP，但这不能替代现场确认；请先确认本次登录可经 Wi-Fi 恢复。HNAT 将以一次原子事务重绑为 WAN=eth1、LAN=br-lan、LAN2=/、PPD=eth0，并验证 WHNAT/rxppd；任一门槛失败会回滚。';
		else
			message += '\n\n切换期间网络和加速状态会短暂重载；HNAT 将以一次原子事务重绑为 WAN=/、LAN=eth1、LAN2=/、PPD=eth1，验证失败会回滚。';
		if (!window.confirm(message))
			return;

		this.setControls({ role: role, consistent: true, switching: true });
		const response = await L.resolveDefault(callSwitch(role), {});
		if (!response.success || !response.job_id) {
			ui.addNotification(null, E('p', {}, text(response.message, '无法创建切换任务')), 'error');
			this.refresh();
			return;
		}
		ui.addNotification(null, E('p', {}, '请求已接收，正在安全切换网络与加速状态。'), 'info');
		this.waitForJob(response.job_id);
	},

	refresh: async function() {
		const status = await L.resolveDefault(callStatus(), {});
		const node = document.getElementById('c2000max-port-status');
		if (node)
			L.dom.content(node, this.renderStatus(status));
		this.setControls(status);
	},

	setControls: function(status) {
		const consistent = status.consistent === true || status.consistent === 1;
		const switching = status.switching === true || status.switching === 1;
		const degraded = status.degraded === true || status.degraded === 1;
		const converged = status.converged === true || status.converged === 1;
		const lan = document.getElementById('c2000max-role-lan');
		const wan = document.getElementById('c2000max-role-wan');

		if (lan)
			lan.disabled = !consistent || switching ||
				(status.role === 'lan' ? (converged && !degraded) : !converged);
		if (wan) {
			wan.disabled = !consistent || switching ||
				(status.role === 'wan' ? (converged && !degraded) : !converged) ||
				!status.wifi_management;
			wan.title = status.wifi_management ? '' :
				'未发现已启用且实际挂入 br-lan 的 Wi-Fi LAN 接入点';
		}
	},

	render: function(status) {
		const consistent = status.consistent === true || status.consistent === 1;
		const current = status.role;
		const switching = status.switching === true || status.switching === 1;
		const degraded = status.degraded === true || status.degraded === 1;
		const converged = status.converged === true || status.converged === 1;
		const root = E('div', {}, [
			E('h2', {}, '网口 LAN / WAN 一键切换'),
				E('div', { 'class': 'cbi-map-descr' },
					'切换对象是 C2000-MAX 唯一的 2.5G 物理网口 eth1。LAN/WAN 两种角色均强制使用 MediaTek HNAT；不会静默降级为软件流量卸载。蜂窝/QModem 接口不受影响。'),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '状态'),
				E('div', { 'id': 'c2000max-port-status' }, this.renderStatus(status))
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'id': 'c2000max-role-lan',
					'class': 'btn cbi-button cbi-button-positive',
					'disabled': !consistent || switching ||
						(current === 'lan' ? (converged && !degraded) : !converged),
					'click': ui.createHandlerFn(this, this.switchRole, 'lan')
				}, '切换为 LAN 口'),
				' ',
				E('button', {
					'id': 'c2000max-role-wan',
					'class': 'btn cbi-button cbi-button-action important',
					'disabled': !consistent || switching ||
						(current === 'wan' ? (converged && !degraded) : !converged) ||
						!status.wifi_management,
					'title': status.wifi_management ? '' : '未发现已启用的 Wi-Fi LAN 接入点',
					'click': ui.createHandlerFn(this, this.switchRole, 'wan')
				}, '切换为 WAN 口')
			])
		]);

		poll.add(L.bind(this.refresh, this), 5);
		return root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
