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

const INTERVALS = [
	{ name: 'modem_cache_interval', title: '设备快照缓存', unit: '秒',
		desc: '设备、SIM 与蜂窝静态信息的返回缓存；调小后 APP 信息页更新更快。',
		min: 1, max: 60, fallback: 10 },
	{ name: 'selector_cache_interval', title: 'SIM 状态缓存', unit: '秒',
		desc: '当前 SIM 槽与选择器状态的缓存时间。',
		min: 1, max: 60, fallback: 15 },
	{ name: 'cache_warm_interval', title: '后台预热间隔', unit: '秒',
		desc: '后台刷新 APP 快照的周期；过低会增加设备查询负载。',
		min: 1, max: 60, fallback: 2 },
	{ name: 'signal_normal_interval', title: '普通信号刷新', unit: '秒',
		desc: 'APP 信号页面常规刷新时的最短采样间隔。',
		min: 1, max: 30, fallback: 3 },
	{ name: 'signal_test_interval', title: '信号测试刷新', unit: '秒',
		desc: 'APP 聚焦信号测试时的最短采样间隔。',
		min: 1, max: 10, fallback: 1 },
	{ name: 'signal_carrier_interval', title: '载波聚合刷新', unit: '秒',
		desc: '载波拓扑与聚合频段的缓存时间。',
		min: 2, max: 120, fallback: 10 }
];

const callStatus = rpc.declare({
	object: 'c2000max_app',
	method: 'status',
	expect: { '': {} }
});

const callSet = rpc.declare({
	object: 'c2000max_app',
	method: 'set',
	params: OPTIONS.map(function(option) { return option.name; }).concat(
		INTERVALS.map(function(option) { return option.name; })),
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

function formatDuration(value) {
	let seconds = Number(value) || 0;
	if (seconds <= 0)
		return '尚未建立';
	const days = Math.floor(seconds / 86400);
	seconds %= 86400;
	const hours = Math.floor(seconds / 3600);
	seconds %= 3600;
	const minutes = Math.floor(seconds / 60);
	const parts = [];
	if (days)
		parts.push(days + '天');
	if (hours || days)
		parts.push(hours + '小时');
	parts.push(minutes + '分钟');
	return parts.join(' ');
}

function formatTimestamp(value) {
	const timestamp = Number(value) || 0;
	if (timestamp <= 0)
		return '尚未建立';
	return new Date(timestamp * 1000).toLocaleString();
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

function intervalRow(option, status) {
	const value = Number(status[option.name]) || option.fallback;
	return E('div', { 'class': 'cbi-value' }, [
		E('label', {
			'class': 'cbi-value-title',
			'for': 'c2000max-app-' + option.name
		}, option.title),
		E('div', { 'class': 'cbi-value-field' }, [
			E('input', {
				'id': 'c2000max-app-' + option.name,
				'class': 'cbi-input-text',
				'type': 'number',
				'min': String(option.min),
				'max': String(option.max),
				'step': '1',
				'value': String(value)
			}),
			E('span', { 'style': 'margin-left:.5em' }, option.unit),
			E('div', { 'class': 'cbi-value-description' },
				option.desc + ' 可设置 ' + option.min + '–' + option.max + ' 秒。')
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
	if (!flag(status.reporter_running))
		return '状态上报进程未运行';
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
		const flags = OPTIONS.map(function(option) {
			return document.getElementById(
				'c2000max-app-' + option.name).checked;
		});
		const intervals = INTERVALS.map(function(option) {
			return Number(document.getElementById(
				'c2000max-app-' + option.name).value);
		});
		for (let i = 0; i < INTERVALS.length; i++) {
			const option = INTERVALS[i];
			const value = intervals[i];
			if (!Number.isInteger(value) || value < option.min ||
			    value > option.max) {
				ui.addNotification(null, E('p', {},
					option.title + '必须是 ' + option.min + '–' +
					option.max + ' 之间的整数。'), 'error');
				return;
			}
		}
		const newlyRisky = OPTIONS.some(function(option, index) {
			return option.risk && flags[index] &&
				!flag(this.currentStatus[option.name]);
		}, this);
		if (newlyRisky && !window.confirm(
			'你正在开启可读取隐私数据或改变系统的 APP 接口。' +
			'这些接口仅受各自开关保护，确认继续吗？'))
			return;

		const button = document.getElementById('c2000max-app-save');
		button.disabled = true;
		const result = await L.resolveDefault(callSet.apply(null,
			flags.concat(intervals)), {});
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
		const refreshOptions = INTERVALS.map(function(option) {
			return intervalRow(option, status);
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
				'启用对应总开关即可使用。当前界面：' +
				text(status.app_build, 'V36.10') + '。'),
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
				E('h3', {}, '数据刷新与缓存'),
				E('div', { 'class': 'cbi-section-descr' },
					'数值越小，APP 返回的数据越新，但蜂窝模块和 CPU 查询更频繁。')
			].concat(refreshOptions)),
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
					]),
					E('tr', {}, [
						E('td', { 'class': 'td left' }, 'MQTT 会话建立时间'),
						E('td', { 'class': 'td left' },
							formatTimestamp(status.bridge_session_started))
					]),
					E('tr', {}, [
						E('td', { 'class': 'td left' }, 'MQTT 会话年龄 / 轮换周期'),
						E('td', { 'class': 'td left' },
							formatDuration(status.bridge_session_age) + ' / ' +
							formatDuration(status.bridge_reconnect_interval))
					]),
					E('tr', {}, [
						E('td', { 'class': 'td left' }, '本次开机主动重连次数'),
						E('td', { 'class': 'td left' },
							String(Number(status.bridge_reconnect_count) || 0))
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
