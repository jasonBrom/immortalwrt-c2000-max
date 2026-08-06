'use strict';
'require view';
'require form';
'require rpc';
'require poll';
'require dom';
'require ui';
'require uci';

const callStatus = rpc.declare({
	object: 'c2000max',
	method: 'access_status',
	expect: { '': {} }
});

const callApply = rpc.declare({
	object: 'c2000max',
	method: 'access_apply',
	expect: { '': {} }
});

function flag(value) {
	return value === true || value === 1;
}

function renderStatus(data) {
	let state = '已关闭';
	if (flag(data.enabled) && flag(data.table_active) && flag(data.acceleration_suspended))
		state = '规则已生效';
	else if (flag(data.enabled))
		state = '配置已启用，但运行状态异常';

	return E('div', {}, [
		E('table', { 'class': 'table' }, [
			E('tr', {}, [
				E('td', { 'class': 'td left', 'width': '34%' }, '运行状态'),
				E('td', { 'class': 'td left' }, state)
			]),
			E('tr', {}, [
				E('td', { 'class': 'td left' }, '控制模式'),
				E('td', { 'class': 'td left' },
					data.mode === 'whitelist' ? '白名单' : '黑名单')
			]),
			E('tr', {}, [
				E('td', { 'class': 'td left' }, '有效设备条目'),
				E('td', { 'class': 'td left' }, String(data.entry_count || 0))
			]),
			E('tr', {}, [
				E('td', { 'class': 'td left' }, 'LAN 入口'),
				E('td', { 'class': 'td left' }, data.lan_device || 'br-lan')
			]),
			E('tr', {}, [
				E('td', { 'class': 'td left' }, '网络加速'),
				E('td', { 'class': 'td left' }, flag(data.enabled) ?
					(flag(data.acceleration_suspended) ? '已安全暂停' : '未确认暂停') :
					'按 TurboACC 原设置运行')
			])
		]),
		data.invalid_entries ? E('div', { 'class': 'alert-message warning' },
			'发现无效 MAC 地址：%s'.format(data.invalid_entries)) : ''
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('c2000max'),
			L.resolveDefault(callStatus(), {})
		]);
	},

	refresh: async function() {
		const data = await L.resolveDefault(callStatus(), {});
		const node = document.getElementById('c2000max-access-status');
		if (node)
			dom.content(node, renderStatus(data));
	},

	render: function(data) {
		const status = data[1] || {};
		const m = new form.Map('c2000max', '设备上网控制',
			'黑名单模式会禁止名单内设备通过路由器转发；白名单模式只允许名单内设备转发。' +
			'规则同时覆盖 IPv4 和 IPv6，默认关闭。设备仍可访问路由器管理页，便于修正名单。');
		let s = m.section(form.NamedSection, 'access_control', 'access_control', '控制设置');
		s.addremove = false;
		s.anonymous = true;

		let o = s.option(form.Flag, 'enabled', '启用设备上网控制');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', '工作模式');
		o.value('blacklist', '黑名单：名单内设备不能上网');
		o.value('whitelist', '白名单：只有名单内设备才能上网');
		o.default = 'blacklist';
		o.rmempty = false;
		o.depends('enabled', '1');

		o = s.option(form.Value, 'lan_device', 'LAN 入口设备');
		o.default = 'auto';
		o.placeholder = 'auto';
		o.description = '通常保持 auto；系统会自动使用 network.lan 的设备。';
		o.depends('enabled', '1');

		s = m.section(form.GridSection, 'access_device', '设备名单',
			'MAC 地址可手动填写；“启用”关闭的条目不会参与黑/白名单。');
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;

		o = s.option(form.Flag, 'enabled', '启用');
		o.default = '1';
		o.rmempty = false;
		o.width = '10%';

		o = s.option(form.Value, 'name', '设备备注');
		o.placeholder = '例如：客厅电视';
		o.rmempty = true;

		o = s.option(form.Value, 'mac', 'MAC 地址');
		o.datatype = 'macaddr';
		o.placeholder = 'AA:BB:CC:DD:EE:FF';
		o.rmempty = false;

		const statusNode = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '实时状态'),
			E('div', { 'id': 'c2000max-access-status' }, renderStatus(status)),
			E('div', { 'class': 'alert-message warning' },
				'启用黑/白名单时，系统会暂停 MediaTek HNAT 和软件流量分载，' +
				'以防已建立连接绕过新规则。关闭后会自动恢复 TurboACC 中原来的选择。' +
				'白名单为空时，所有 LAN 设备都不能访问外网。')
		]);

		poll.add(this.refresh.bind(this), 5);
		return m.render().then(function(formNode) {
			return E([ statusNode, formNode ]);
		});
	},

	handleSave: function(ev) {
		return this.super('handleSave', arguments).then(async () => {
			const result = await L.resolveDefault(callApply(), {
				success: false,
				message: '设备上网控制后端没有返回结果'
			});
			const success = flag(result.success);

			ui.addNotification(null,
				E('p', {}, result.message ||
					(success ? '设备上网控制已应用' : '设备上网控制应用失败')),
				success ? 'info' : 'error');
			await this.refresh();
		});
	}
});
