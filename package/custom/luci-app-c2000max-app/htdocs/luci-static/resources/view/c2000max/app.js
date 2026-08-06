'use strict';
'require rpc';
'require ui';
'require view';

const OPTIONS = [
	{ name: 'local_enable', title: '局域网 APP 管理',
		desc: '启动局域网发现与鉴权；下方本地功能权限已默认预选。' },
	{ name: 'remote_enable', title: '官方云端远程管理（实验）',
		desc: '连接官方 MQTT，并发送设备身份与在线握手；下方云端接口权限已默认预选。仅适用于已绑定账号的原厂 bdinfo 身份。',
		risk: true },
	{ name: 'local_device_enable', title: '本地设备状态',
		desc: '允许 APP 读取运行状态、SIM 槽位和设备基础信息。' },
	{ name: 'local_signal_enable', title: '本地蜂窝与信号',
		desc: '允许 APP 读取蜂窝详情、信号、小区和频点锁定状态。',
		risk: true },
	{ name: 'local_client_enable', title: '本地终端列表',
		desc: '允许 APP 读取已连接终端、IP、MAC 和租约信息。',
		risk: true },
	{ name: 'local_wifi_enable', title: '本地 Wi-Fi 信息',
		desc: '允许 APP 读取 SSID、无线频段和鉴权状态。', risk: true },
	{ name: 'local_traffic_enable', title: '本地流量统计',
		desc: '允许 APP 读取 LAN/WAN 接口流量。', risk: true },
	{ name: 'local_sms_enable', title: '本地短信',
		desc: '允许 APP 读取、发送和删除 SIM 短信。', risk: true },
	{ name: 'local_network_write_enable', title: '本地网络修改',
		desc: '允许 APP 修改 Wi-Fi、APN、LAN 地址、门户设置及蜂窝锁频/锁小区。',
		risk: true },
	{ name: 'local_sim_switch_enable', title: '本地 SIM 切换',
		desc: '允许 APP 切换实体 SIM 卡槽。', risk: true },
	{ name: 'local_cellular_record_enable', title: '蜂窝记录控制',
		desc: '允许 APP 开关蜂窝记录服务；记录内容可能含小区信息。',
		risk: true },
	{ name: 'password_enable', title: '修改管理员密码',
		desc: '允许本地或云端 APP 修改 root 管理密码。', risk: true },
	{ name: 'reboot_enable', title: '重启设备',
		desc: '允许本地或云端 APP 请求重启设备。', risk: true },
	{ name: 'remote_web_enable', title: '远程登录后台',
		desc: '允许官方设备专属 command 启动临时 RSSH/LuCI 通道；不会开放 rpc/exec 通用命令主题。',
		risk: true },
	{ name: 'device_report_enable', title: '设备统计',
		desc: '允许查询及主动发送设备、运行状态和配置摘要。',
		risk: true },
	{ name: 'signal_report_enable', title: '信号上报',
		desc: '允许主动发送蜂窝网络、信号和小区状态。', risk: true },
	{ name: 'traffic_report_enable', title: '流量上报',
		desc: '允许主动发送 LAN/WAN 接口流量统计。', risk: true },
	{ name: 'terminal_tracking_enable', title: '终端跟踪',
		desc: '允许云端读取已连接终端、IP、MAC 和租约信息。',
		risk: true },
	{ name: 'broadcast_enable', title: '广播主题',
		desc: '订阅官方全设备广播管理主题。', risk: true },
	{ name: 'command_enable', title: '任意命令',
		desc: '允许官方云端执行 shell 命令和服务控制。', risk: true },
	{ name: 'file_enable', title: '远程文件',
		desc: '允许下载经校验的文件；系统路径还需要开发者接口。',
		risk: true },
	{ name: 'appstore_enable', title: '应用商店',
		desc: '允许下载并校验官方应用包；无兼容后端时只暂存。',
		risk: true },
	{ name: 'developer_enable', title: '开发者接口',
		desc: '允许通用 ubus 调用和扩展文件路径。', risk: true }
];

const callStatus = rpc.declare({
	object: 'c2000max_app',
	method: 'status',
	expect: { '': {} }
});

const callSet = rpc.declare({
	object: 'c2000max_app',
	method: 'set',
	params: OPTIONS.map(function(option) { return option.name; }),
	expect: { '': {} }
});

const callRestart = rpc.declare({
	object: 'c2000max_app',
	method: 'restart',
	expect: { '': {} }
});

function flag(value) {
	return value === true || value === 1;
}

function text(value, fallback) {
	return value == null || value === '' ? fallback : String(value);
}

function checkbox(option, checked) {
	const node = E('input', {
		'id': 'c2000max-app-' + option.name,
		'type': 'checkbox'
	});
	node.checked = !!checked;
	return node;
}

function optionRow(option, status) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', {
			'class': 'cbi-value-title',
			'for': 'c2000max-app-' + option.name
		}, option.title),
		E('div', { 'class': 'cbi-value-field' }, [
			checkbox(option, flag(status[option.name])),
			E('div', { 'class': 'cbi-value-description' }, option.desc)
		])
	]);
}

function statusLabel(status) {
	if (!flag(status.remote_enable))
		return '未启用';
	if (!flag(status.identity_available))
		return '设备身份不可用';
	if (!flag(status.service_autostart))
		return 'APP 服务启动项未注册';
	if (!flag(status.bridge_running))
		return 'MQTT bridge 未运行';
	if (!flag(status.agent_running))
		return '本地管理代理未运行';
	const labels = {
		bridge_starting: 'bridge 已启动，等待官方服务器连接',
		connected: 'bridge 已连接官方服务器',
		disconnected: '连接已断开',
		identity_error: '设备身份错误',
		agent_error: '本地管理代理异常退出',
		disabled: '未启用'
	};
	return labels[status.remote_state] ||
		text(status.remote_state, '远程进程运行中');
}

function localStatusLabel(status) {
	if (!flag(status.local_enable))
		return '未启用';
	if (!flag(status.identity_available))
		return '设备身份不可用';
	if (!flag(status.local_api_ready))
		return 'HTTP APP API 未就绪：' +
			text(status.local_probe_message, '回环检测失败');
	return 'HTTP APP API 已就绪（网关端口 80，回环检测通过）';
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	save: async function() {
		const values = OPTIONS.map(function(option) {
			return document.getElementById(
				'c2000max-app-' + option.name).checked;
		});
		const newlyRisky = OPTIONS.some(function(option, index) {
			return option.risk && values[index] &&
				!flag(this.currentStatus[option.name]);
		}, this);
		if (newlyRisky && !window.confirm(
			'你正在开启可读取隐私数据或改变系统的 APP 接口。' +
			'这些接口仅受各自开关保护，确认继续吗？'))
			return;

		const button = document.getElementById('c2000max-app-save');
		button.disabled = true;
		const result = await L.resolveDefault(callSet.apply(null, values), {});
		if (!result.success) {
			ui.addNotification(null,
				E('p', {}, text(result.message, '无法保存 APP 管理设置')),
				'error');
			button.disabled = false;
			return;
		}
		ui.addNotification(null,
			E('p', {}, text(result.message, 'APP 管理设置已应用')), 'info');
		window.setTimeout(function() { window.location.reload(); }, 1000);
	},

	restartService: async function() {
		const button = document.getElementById('c2000max-app-restart');
		button.disabled = true;
		const result = await L.resolveDefault(callRestart(), {});
		ui.addNotification(null,
			E('p', {}, text(result.message, 'APP 服务已重新启动')),
			result.success ? 'info' : 'error');
		window.setTimeout(function() { window.location.reload(); }, 1500);
	},

	render: function(status) {
		this.currentStatus = status;
		const masterOptions = OPTIONS.slice(0, 2).map(function(option) {
			return optionRow(option, status);
		});
		const localOptions = OPTIONS.slice(2, 13).map(function(option) {
			return optionRow(option, status);
		});
		const cloudOptions = OPTIONS.slice(13).map(function(option) {
			return optionRow(option, status);
		});
		const updatePolicy = E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, '软件更新权限'),
			E('div', { 'class': 'cbi-value-field' }, [
				E('strong', {}, '永久关闭'),
				E('div', { 'class': 'cbi-value-description' },
					'不提供用户开关，本地和云端升级请求都会被拒绝；' +
					'APP 固定版本号 ' +
					text(status.app_software_version, '9.9.13.n0.c1') + '。')
			])
		]);

		return E('div', {}, [
			E('h2', {}, 'APP 支持'),
			E('div', { 'class': 'cbi-map-descr' },
				'局域网和云端总开关默认关闭；下方功能权限已默认开启，' +
				'启用对应总开关即可使用。当前界面：V35.25-TEST。'),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '总开关')
			].concat(masterOptions)),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '本地可选功能'),
				E('div', { 'class': 'cbi-section-descr' },
					'以下开关只有在“局域网 APP 管理”开启时生效。')
			].concat(localOptions)),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '云端可选接口'),
				E('div', { 'class': 'cbi-section-descr' },
					'以下开关只有在“官方云端远程管理”开启时生效。'),
				updatePolicy
			].concat(cloudOptions)),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '设备身份与状态'),
				E('table', { 'class': 'table' }, [
					E('tr', {}, [
						E('td', { 'class': 'td left', 'width': '34%' },
							'设备编号（只读）'),
						E('td', { 'class': 'td left' },
							text(status.device_id, '不可用'))
					]),
					E('tr', {}, [
						E('td', { 'class': 'td left' }, '官方服务器'),
						E('td', { 'class': 'td left' },
							text(status.broker, '设备编号不可用'))
					]),
					E('tr', {}, [
						E('td', { 'class': 'td left' }, '局域网运行状态'),
						E('td', { 'class': 'td left' },
							localStatusLabel(status))
					]),
					E('tr', {}, [
						E('td', { 'class': 'td left' },
							'官方云端远程管理运行状态'),
						E('td', { 'class': 'td left' }, statusLabel(status))
					])
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'id': 'c2000max-app-restart',
					'class': 'btn cbi-button cbi-button-neutral',
					'click': ui.createHandlerFn(this, this.restartService)
				}, '重新启动 APP 服务'),
				E('button', {
					'id': 'c2000max-app-save',
					'class': 'btn cbi-button cbi-button-action important',
					'click': ui.createHandlerFn(this, this.save)
				}, '保存并应用')
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
