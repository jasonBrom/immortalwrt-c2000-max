'use strict';
'require form';
'require network';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

var callTrafficStatus = rpc.declare({
	object: 'c2000max.traffic',
	method: 'status',
	expect: { '': {} }
});

var callTrafficReset = rpc.declare({
	object: 'c2000max.traffic',
	method: 'reset',
	expect: { '': {} }
});

function bytes(value) {
	var number = Number(value || 0);
	var units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB' ];
	var unit = 0;

	if (!isFinite(number) || number < 0)
		number = 0;
	while (number >= 1024 && unit < units.length - 1) {
		number /= 1024;
		unit++;
	}

	return '%s %s'.format(number.toFixed(unit === 0 ? 0 : 2), units[unit]);
}

function accelerationName(value) {
	var names = {
		mediatek_hnat: 'MediaTek HNAT',
		flow_offloading: 'Flow Offloading',
		disabled: '普通转发'
	};

	return names[value] || value || '未知';
}

function backendName(value) {
	var names = {
		hnat: '硬件 HQoS',
		software: '软件 tc/IFB',
		inactive: '未启用'
	};

	return names[value] || value || '未启用';
}

function sourceName(value) {
	var names = {
		hardware_mib: 'HNAT 硬件 MIB → Conntrack',
		flowtable_conntrack: 'Flowtable → Conntrack',
		conntrack: 'Conntrack'
	};

	return names[value] || value || '未知';
}

function trafficPair(upload, download) {
	return E('span', {}, [
		E('span', { 'style': 'white-space:nowrap' }, [ '↑ ', bytes(upload) ]),
		' / ',
		E('span', { 'style': 'white-space:nowrap' }, [ '↓ ', bytes(download) ])
	]);
}

function renderTraffic(status) {
	var totals = status.totals || {};
	var devices = Array.isArray(status.devices) ? status.devices : [];
	var updated = Number(status.updated || 0);
	var unknown = Number(totals.unknown_upload || 0) +
		Number(totals.unknown_download || 0);
	var rows = devices.map(function(device) {
		var title = device.name || device.ip || device.mac || device.id || '未知设备';
		var detail = [];

		if (device.ip && device.ip !== title)
			detail.push(device.ip);
		if (device.mac && device.mac !== title)
			detail.push(device.mac);

		return E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td' }, [
				E('strong', {}, title),
				detail.length ? E('div', {
					'class': 'hide-sm',
					'style': 'color:#777;font-size:90%'
				}, detail.join(' · ')) : ''
			]),
			E('div', { 'class': 'td' }, trafficPair(
				device.fiveg_upload, device.fiveg_download)),
			E('div', { 'class': 'td' }, trafficPair(
				device.other_upload, device.other_download)),
			E('div', { 'class': 'td' }, trafficPair(
				device.unknown_upload, device.unknown_download))
		]);
	});

	if (!rows.length)
		rows.push(E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td', 'style': 'flex:1' },
				'尚无设备流量；启用统计后，新流量会自动出现。')
		]));

	return [
		E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '实时运行状态'),
			E('div', { 'class': 'table' }, [
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left', 'style': 'width:25%' }, '加速模式'),
					E('div', { 'class': 'td left' }, accelerationName(status.acceleration)),
					E('div', { 'class': 'td left', 'style': 'width:25%' }, '限速后端'),
					E('div', { 'class': 'td left' }, backendName(status.limiter_backend))
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '统计来源'),
					E('div', { 'class': 'td left' }, sourceName(status.counter_source)),
					E('div', { 'class': 'td left' }, '最后采样'),
					E('div', { 'class': 'td left' }, updated ?
						new Date(updated * 1000).toLocaleString() : '等待首次采样')
				])
			])
		]),
		E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '累计流量'),
			E('div', { 'class': 'table' }, [
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left', 'style': 'width:25%' },
						E('strong', {}, '5G 流量')),
					E('div', { 'class': 'td left' }, trafficPair(
						totals.fiveg_upload, totals.fiveg_download)),
					E('div', { 'class': 'td left', 'style': 'width:25%' },
						E('strong', {}, '其他/宽带流量')),
					E('div', { 'class': 'td left' }, trafficPair(
						totals.other_upload, totals.other_download))
				])
			]),
			unknown ? E('p', { 'class': 'alert-message warning' }, [
				'无法匹配出口的流量：', trafficPair(
					totals.unknown_upload, totals.unknown_download),
				'。这通常发生在 mwan3 路由表切换或接口尚未就绪时。'
			]) : '',
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': function() {
						ui.showModal('清空累计流量', [
							E('p', {}, '确定清空全部设备的 5G 和其他流量记录吗？此操作不可撤销。'),
							E('div', { 'class': 'right' }, [
								E('button', {
									'class': 'btn',
									'click': ui.hideModal
								}, '取消'),
								' ',
								E('button', {
									'class': 'btn cbi-button-negative important',
									'click': function() {
										return callTrafficReset().then(function() {
											ui.hideModal();
											return callTrafficStatus();
										}).then(function(fresh) {
											L.dom.content(document.getElementById('c2000-traffic-body'),
												renderTraffic(fresh));
										});
									}
								}, '确认清空')
							])
						]);
					}
				}, '清空统计')
			])
		]),
		E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '各设备流量'),
			E('div', { 'class': 'table cbi-section-table' }, [
				E('div', { 'class': 'tr table-titles' }, [
					E('div', { 'class': 'th' }, '设备'),
					E('div', { 'class': 'th' }, '5G（上传 / 下载）'),
					E('div', { 'class': 'th' }, '其他/宽带（上传 / 下载）'),
					E('div', { 'class': 'th' }, '未分类（上传 / 下载）')
				])
			].concat(rows))
		])
	];
}

function collectHostChoices(hosts) {
	var choices = {
		ip: [],
		ip6: []
	};

	for (var host in hosts) {
		var ipaddrs = L.toArray(hosts[host].ipaddrs || hosts[host].ipv4);
		var ip6addrs = L.toArray(hosts[host].ip6addrs || hosts[host].ipv6);
		var name = hosts[host].name;

		for (var i = 0; i < ipaddrs.length; i++)
			choices.ip.push([ ipaddrs[i], name ? '%s (%s)'.format(name, ipaddrs[i]) : ipaddrs[i] ]);

		for (var j = 0; j < ip6addrs.length; j++)
			choices.ip6.push([ ip6addrs[j], name ? '%s (%s)'.format(name, ip6addrs[j]) : ip6addrs[j] ]);
	}

	return choices;
}

function addChoices(option, choices) {
	for (var i = 0; i < choices.length; i++)
		option.value(choices[i][0], choices[i][1]);
}

function selectorValue(section_id) {
	var selector = uci.get('eqos', section_id, 'selector');

	if (selector === 'ip' || selector === 'ip6')
		return selector;

	if (uci.get('eqos', section_id, 'ip6'))
		return 'ip6';

	return 'ip';
}

function matchLabel(selector) {
	if (selector === 'ip6')
		return _('IPv6 address');

	return _('IPv4 address');
}

function rateCfgvalue(section_id) {
	return String(Number(uci.get('eqos', section_id, this.option) || 0) / 1000);
}

function rateWrite(section_id, value) {
	uci.set('eqos', section_id, this.option, String(Math.round(Number(value) * 1000)));
}

function integerWrite(section_id, value) {
	uci.set('eqos', section_id, this.option, String(Number(value)));
}

function uniqueAddress(section_id, value) {
	var sections = uci.sections('eqos', 'device');

	for (var i = 0; i < sections.length; i++) {
		if (sections[i]['.name'] === section_id || sections[i].enabled === '0')
			continue;

		if (sections[i][this.option] === value)
			return _('This value is already in use.');
	}

	return true;
}

function rateText(section_id) {
	var value = this.cfgvalue(section_id) || '0';

	return value === '0' ? _('unlimited') : '%s Mbit/s'.format(value);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('eqos'),
			network.getHostHints(),
			L.resolveDefault(callTrafficStatus(), {})
		]);
	},

	render: function(data) {
		var hosts = data[1] ? data[1].hosts || {} : {};
		var hostChoices = collectHostChoices(hosts);
		var m, s, o;

		m = new form.Map('eqos', 'C2000MAX 流量管理',
			'同一套设备规则自动适配硬件 HNAT/HQoS、Flow Offloading 和普通转发；切换加速方式后限速与累计统计会继续生效。');

		s = m.section(form.NamedSection, 'config', 'eqos', _('Settings'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.option(form.Value, 'download', '%s (Mbit/s)'.format(_('Download')),
			_('Total download bandwidth.'));
		o.datatype = 'and(uinteger,min(1),max(1000))';
		o.rmempty = false;
		o.write = integerWrite;

		o = s.option(form.Flag, 'statistics_enabled', '启用流量统计',
			'按设备累计 5G 与其他/宽带流量。HNAT 模式自动读取硬件 MIB，其他模式读取 Conntrack。');
		o.default = o.enabled;
		o.rmempty = false;

		o = s.option(form.Value, 'sample_interval', '采样间隔（秒）');
		o.datatype = 'and(uinteger,min(5),max(300))';
		o.default = '10';
		o.rmempty = false;
		o.depends('statistics_enabled', '1');

		o = s.option(form.Value, 'flush_interval', '持久化间隔（秒）',
			'定期保存到闪存，重启后继续累计。建议不小于 3600 秒。');
		o.datatype = 'and(uinteger,min(300),max(86400))';
		o.default = '3600';
		o.rmempty = false;
		o.depends('statistics_enabled', '1');

		o = s.option(form.Value, 'upload', '%s (Mbit/s)'.format(_('Upload')),
			_('Total upload bandwidth.'));
		o.datatype = 'and(uinteger,min(1),max(1000))';
		o.rmempty = false;
		o.write = integerWrite;

		s = m.section(form.GridSection, 'device', _('Device rules'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.handleAdd = function(ev) {
			var section_id = uci.add('eqos', 'device');

			uci.set('eqos', section_id, 'enabled', '1');
			uci.set('eqos', section_id, 'selector', 'ip');
			uci.set('eqos', section_id, 'download', '0');
			uci.set('eqos', section_id, 'upload', '0');
			m.addedSection = section_id;

			return this.renderMoreOptionsModal(section_id);
		};

		s.tab('general', _('General Settings'));

		o = s.taboption('general', form.Flag, 'enabled', _('Enable'));
		o.default = o.enabled;
		o.rmempty = false;
		o.editable = true;

		o = s.taboption('general', form.Value, 'queue', _('Queue ID'),
			'规则编号。HNAT 下 1–31 使用硬件 HQoS，32 及以上回退软件队列；其他加速模式全部自动使用软件队列。');
		o.datatype = 'and(uinteger,min(1),max(4094))';
		o.placeholder = '1';
		o.rmempty = false;
		o.cfgvalue = function(section_id) {
			return uci.get('eqos', section_id, 'queue') ||
				uci.get('eqos', section_id, 'comment');
		};
		o.write = function(section_id, value) {
			uci.set('eqos', section_id, 'queue', String(Number(value)));
			uci.unset('eqos', section_id, 'comment');
		};
		o.validate = function(section_id, value) {
			var sections = uci.sections('eqos', 'device');

			for (var i = 0; i < sections.length; i++) {
				if (sections[i]['.name'] === section_id || sections[i].enabled === '0')
					continue;

				if (Number(sections[i].queue || sections[i].comment) === Number(value))
					return _('This value is already in use.');
			}

			return true;
		};

		o = s.option(form.DummyValue, '_match', _('Address'));
		o.textvalue = function(section_id) {
			var selector = selectorValue(section_id);
			var value = uci.get('eqos', section_id, selector);

			return value ? '%s: %s'.format(matchLabel(selector), value) : E('em', _('unspecified'));
		};

		o = s.taboption('general', form.Value, 'download', _('Download'),
			_('Maximum rate in Mbit/s. Use 0 for no limit.'));
		o.datatype = 'and(ufloat,min(0),max(1000))';
		o.rmempty = false;
		o.cfgvalue = rateCfgvalue;
		o.write = rateWrite;
		o.textvalue = rateText;

		o = s.taboption('general', form.Value, 'upload', _('Upload'),
			_('Maximum rate in Mbit/s. Use 0 for no limit.'));
		o.datatype = 'and(ufloat,min(0),max(1000))';
		o.rmempty = false;
		o.cfgvalue = rateCfgvalue;
		o.write = rateWrite;
		o.textvalue = rateText;

		o = s.taboption('general', form.ListValue, 'selector', _('Type'));
		o.modalonly = true;
		o.default = 'ip';
		o.rmempty = false;
		o.value('ip', _('IPv4 address'));
		o.value('ip6', _('IPv6 address'));
		o.cfgvalue = function(section_id) {
			return selectorValue(section_id);
		};
		o.write = function(section_id, value) {
			uci.set('eqos', section_id, 'selector', value);

			if (value !== 'ip')
				uci.unset('eqos', section_id, 'ip');

			if (value !== 'ip6')
				uci.unset('eqos', section_id, 'ip6');
		};

		o = s.taboption('general', form.Value, 'ip', _('IPv4 address'));
		o.modalonly = true;
		o.datatype = 'ip4addr("nomask")';
		o.rmempty = false;
		o.depends('selector', 'ip');
		o.validate = uniqueAddress;
		addChoices(o, hostChoices.ip);

		o = s.taboption('general', form.Value, 'ip6', _('IPv6 address'));
		o.modalonly = true;
		o.datatype = 'ip6addr("nomask")';
		o.rmempty = false;
		o.depends('selector', 'ip6');
		o.validate = uniqueAddress;
		addChoices(o, hostChoices.ip6);

		var trafficNode = E('div', { 'id': 'c2000-traffic-body' },
			renderTraffic(data[2] || {}));

		poll.add(function() {
			return L.resolveDefault(callTrafficStatus(), {}).then(function(status) {
				var node = document.getElementById('c2000-traffic-body');
				if (node)
					L.dom.content(node, renderTraffic(status));
			});
		}, 5);

		return m.render().then(function(formNode) {
			return E('div', {}, [ trafficNode, formNode ]);
		});
	}
});
