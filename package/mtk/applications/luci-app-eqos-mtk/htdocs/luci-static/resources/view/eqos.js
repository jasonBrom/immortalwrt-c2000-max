'use strict';
'require form';
'require network';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

var callEqosStatus = rpc.declare({
	object: 'c2000max.eqos',
	method: 'status',
	expect: { '': {} }
});

var callEqosApply = rpc.declare({
	object: 'c2000max.eqos',
	method: 'apply',
	expect: { '': {} }
});

function accelerationName(value) {
	return ({
		mediatek_hnat: 'MediaTek HNAT',
		flow_offloading: 'Flow Offloading',
		disabled: '普通转发'
	})[value] || value || '未知';
}

function backendName(value) {
	return ({
		hnat: '硬件 HQoS',
		hybrid: 'HNAT + 下载 HTB / 上传 Police',
		software: '软件 HTB / Police',
		inactive: '未启用'
	})[value] || value || '未启用';
}

function renderStatus(status) {
	var enabled = status.enabled === true || status.enabled === 1;
	var active = status.active === true || status.active === 1;
	var state = active ? '已启用并生效' : (enabled ? '已启用，但应用失败' : '未启用');
	var color = active ? '#22a06b' : (enabled ? '#c9372c' : '#777');
	var profiles = '%s / 31 上传，%s / 31 下载'.format(
		Number(status.upload_profiles || 0), Number(status.download_profiles || 0));
		var profileState = status.backend === 'hybrid' ?
			'0（外部出口使用选择性 tc，不占用 HQoS 档位）' :
		(status.backend === 'hnat' ? profiles : '不适用');
	var sharing = status.backend === 'hnat' ? '同方向、同速率共享总带宽' :
		(status.backend === 'hybrid' ? '仅受限设备软件整形；其他设备保持 HNAT' : '每台设备独立 tc 类');

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, '实时运行状态'),
		E('div', { 'class': 'table' }, [
			E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td left' }, '限速状态'),
				E('div', { 'class': 'td left' }, E('strong', { 'style': 'color:%s'.format(color) }, state)),
				E('div', { 'class': 'td left' }, '加速模式'),
				E('div', { 'class': 'td left' }, accelerationName(status.acceleration))
			]),
			E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td left' }, '限速后端'),
				E('div', { 'class': 'td left' }, backendName(status.backend)),
				E('div', { 'class': 'td left' }, '硬件速率档位'),
				E('div', { 'class': 'td left' }, profileState)
			]),
			E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td left' }, '规则类型'),
				E('div', { 'class': 'td left' }, 'IPv4 / IPv6 / MAC'),
				E('div', { 'class': 'td left' }, '档位共享方式'),
				E('div', { 'class': 'td left' }, sharing)
			])
		]),
		status.error ? E('p', { 'class': 'alert-message error' }, [
			E('strong', {}, '应用错误：'), ' ', status.error
		]) : ''
	]);
}

function collectHostChoices(hosts) {
	var choices = { ip: [], ip6: [], mac: [] };

	for (var host in hosts) {
		var item = hosts[host] || {};
		var ipaddrs = L.toArray(item.ipaddrs || item.ipv4);
		var ip6addrs = L.toArray(item.ip6addrs || item.ipv6);
		var name = item.name;
		if (/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/i.test(host))
			choices.mac.push([ host.toLowerCase(), name ? '%s (%s)'.format(name, host) : host ]);
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

function selectorValue(sectionId) {
	var selector = uci.get('eqos', sectionId, 'selector');
	if (selector === 'ip' || selector === 'ip6' || selector === 'mac')
		return selector;
	if (uci.get('eqos', sectionId, 'mac')) return 'mac';
	if (uci.get('eqos', sectionId, 'ip6')) return 'ip6';
	return 'ip';
}

function matchLabel(selector) {
	return ({ ip: 'IPv4 地址', ip6: 'IPv6 地址', mac: 'MAC 地址' })[selector] || selector;
}

function rateCfgvalue(sectionId) {
	return String(Number(uci.get('eqos', sectionId, this.option) || 0) / 1000);
}

function rateWrite(sectionId, value) {
	uci.set('eqos', sectionId, this.option, String(Math.round(Number(value) * 1000)));
}

function integerWrite(sectionId, value) {
	uci.set('eqos', sectionId, this.option, String(Number(value)));
}

function uniqueSelector(sectionId, value) {
	var sections = uci.sections('eqos', 'device');
	for (var i = 0; i < sections.length; i++) {
		if (sections[i]['.name'] === sectionId || sections[i].enabled === '0') continue;
		if (String(sections[i][this.option] || '').toLowerCase() === String(value).toLowerCase())
			return '该地址已被另一条启用规则使用。';
	}
	return true;
}

function rateText(sectionId) {
	var value = this.cfgvalue(sectionId) || '0';
	return value === '0' ? '不限速' : '%s Mbit/s'.format(value);
}

function nextQueue() {
	var used = {};
	uci.sections('eqos', 'device').forEach(function(section) {
		used[Number(section.queue || section.comment)] = true;
	});
	for (var i = 1; i <= 4094; i++) if (!used[i]) return i;
	return 1;
}

return view.extend({
	load: function() {
		return Promise.all([ uci.load('eqos'), network.getHostHints(), L.resolveDefault(callEqosStatus(), {}) ]);
	},
	render: function(data) {
		var hosts = data[1] ? data[1].hosts || {} : {};
		var choices = collectHostChoices(hosts);
		var m = new form.Map('eqos', 'C2000MAX 网络限速',
			'同一套规则自动适配 MediaTek HNAT/HQoS、Flow Offloading 和普通转发。5G/USB 外部接口下，为避免 PPD 与 IFB 改道断流，仅受限设备使用下载 HTB 和上传入口限速，其他设备继续硬件加速。保存后会立即应用并校验真实运行状态。');
		var s = m.section(form.NamedSection, 'config', 'eqos', '全局设置');
		var o;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', '启用网络限速'); o.default = o.disabled; o.rmempty = false;
		o = s.option(form.Value, 'download', '总下载带宽（Mbit/s）'); o.datatype = 'and(uinteger,min(1),max(1000))'; o.rmempty = false; o.write = integerWrite;
		o = s.option(form.Value, 'upload', '总上传带宽（Mbit/s）'); o.datatype = 'and(uinteger,min(1),max(1000))'; o.rmempty = false; o.write = integerWrite;

		s = m.section(form.GridSection, 'device', '设备限速规则');
		s.addremove = true; s.anonymous = true; s.sortable = true; s.nodescriptions = true;
		s.handleAdd = function() {
			var sectionId = uci.add('eqos', 'device');
			uci.set('eqos', sectionId, 'enabled', '1');
			uci.set('eqos', sectionId, 'queue', String(nextQueue()));
			uci.set('eqos', sectionId, 'selector', 'mac');
			uci.set('eqos', sectionId, 'download', '0');
			uci.set('eqos', sectionId, 'upload', '0');
			m.addedSection = sectionId;
			return this.renderMoreOptionsModal(sectionId);
		};
		s.tab('general', '常规设置');

		o = s.taboption('general', form.Flag, 'enabled', '启用'); o.default = o.enabled; o.rmempty = false; o.editable = true;
		o = s.taboption('general', form.Value, 'queue', '规则 ID', '仅用于标识规则和软件 tc，不对应 HQoS 队列；同方向、同速率的规则自动复用硬件档位并共享该档位总带宽。');
		o.datatype = 'and(uinteger,min(1),max(4094))'; o.rmempty = false; o.placeholder = '1';
		o.readonly = true;
		o.cfgvalue = function(sectionId) { return uci.get('eqos', sectionId, 'queue') || uci.get('eqos', sectionId, 'comment'); };
		o.write = function(sectionId, value) { uci.set('eqos', sectionId, 'queue', String(Number(value))); uci.unset('eqos', sectionId, 'comment'); };
		o.validate = function(sectionId, value) {
			var sections = uci.sections('eqos', 'device');
			for (var i = 0; i < sections.length; i++)
				if (sections[i]['.name'] !== sectionId && sections[i].enabled !== '0' && Number(sections[i].queue || sections[i].comment) === Number(value))
					return '该规则 ID 已被使用。';
			return true;
		};

		o = s.option(form.DummyValue, '_match', '匹配设备');
		o.textvalue = function(sectionId) {
			var selector = selectorValue(sectionId); var value = uci.get('eqos', sectionId, selector);
			return value ? '%s：%s'.format(matchLabel(selector), value) : E('em', {}, '未指定');
		};

		o = s.taboption('general', form.Value, 'download', '下载上限', 'Mbit/s，0 表示不限速。'); o.datatype = 'and(ufloat,min(0),max(1000))'; o.rmempty = false; o.cfgvalue = rateCfgvalue; o.write = rateWrite; o.textvalue = rateText;
		o = s.taboption('general', form.Value, 'upload', '上传上限', 'Mbit/s，0 表示不限速。'); o.datatype = 'and(ufloat,min(0),max(1000))'; o.rmempty = false; o.cfgvalue = rateCfgvalue; o.write = rateWrite; o.textvalue = rateText;

		o = s.taboption('general', form.ListValue, 'selector', '匹配类型'); o.modalonly = true; o.default = 'mac'; o.rmempty = false;
		o.value('mac', 'MAC 地址（推荐）'); o.value('ip', 'IPv4 地址'); o.value('ip6', 'IPv6 地址');
		o.cfgvalue = selectorValue;
		o.write = function(sectionId, value) {
			uci.set('eqos', sectionId, 'selector', value);
			[ 'ip', 'ip6', 'mac' ].forEach(function(field) { if (field !== value) uci.unset('eqos', sectionId, field); });
		};

		o = s.taboption('general', form.Value, 'mac', 'MAC 地址'); o.modalonly = true; o.datatype = 'macaddr'; o.rmempty = false; o.depends('selector', 'mac'); o.validate = uniqueSelector; addChoices(o, choices.mac);
		o = s.taboption('general', form.Value, 'ip', 'IPv4 地址'); o.modalonly = true; o.datatype = 'ip4addr("nomask")'; o.rmempty = false; o.depends('selector', 'ip'); o.validate = uniqueSelector; addChoices(o, choices.ip);
		o = s.taboption('general', form.Value, 'ip6', 'IPv6 地址'); o.modalonly = true; o.datatype = 'ip6addr("nomask")'; o.rmempty = false; o.depends('selector', 'ip6'); o.validate = uniqueSelector; addChoices(o, choices.ip6);

		var statusNode = E('div', { 'id': 'c2000-eqos-status' }, renderStatus(data[2] || {}));
		function updateStatus(status) {
			var node = document.getElementById('c2000-eqos-status');
			if (node) L.dom.content(node, renderStatus(status || {}));
		}
		m.on_after_commit = function() {
			return callEqosApply().then(function(status) {
				updateStatus(status);
				if (!(status.active === true || status.active === 1) && (status.enabled === true || status.enabled === 1))
					ui.addNotification(null, E('p', {}, status.error || '限速配置应用失败。'), 'error');
			});
		};
		poll.add(function() { return L.resolveDefault(callEqosStatus(), {}).then(updateStatus); }, 5);
		return m.render().then(function(formNode) { return E('div', {}, [ statusNode, formNode ]); });
	}
});
