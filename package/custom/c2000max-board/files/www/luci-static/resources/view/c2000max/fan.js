'use strict';
'require view';
'require form';
'require rpc';
'require poll';
'require dom';

var callFanStatus = rpc.declare({
	object: 'c2000max',
	method: 'fan_status',
	expect: { '': {} }
});

function temp(value) {
	value = Number(value || 0);
	return value ? '%.1f °C'.format(value / 1000) : _('未检测到');
}

function renderStatus(data) {
	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'width': '33%' }, _('控制器')), E('td', { 'class': 'td left' }, data.enabled ? _('已启用') : _('已关闭')) ]),
		E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('PWM 接口')), E('td', { 'class': 'td left' }, data.pwm_available ? _('可用') : _('未检测到')) ]),
		E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('当前转速')), E('td', { 'class': 'td left' }, '%s%%'.format(data.speed || 0)) ]),
		E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('CPU 温度')), E('td', { 'class': 'td left' }, temp(data.cpu_temp)) ]),
		E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('Wi-Fi 温度')), E('td', { 'class': 'td left' }, temp(data.wifi_temp)) ])
	]);
}

return view.extend({
	load: function() {
		return L.resolveDefault(callFanStatus(), {});
	},

	render: function(status) {
		var m = new form.Map('c2000max', _('智能风扇控制'),
			_('使用 CPU 与 Wi-Fi 的较高温度控制 GPIO5 供电和 PWM1 转速。未安装风扇时请保持关闭。'));
		var s = m.section(form.NamedSection, 'fan', 'fan', _('风扇设置'));
		s.addremove = false;
		s.anonymous = true;

		var o = s.option(form.Flag, 'enabled', _('启用风扇控制'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('控制模式'));
		o.value('smart', _('智能温控'));
		o.value('manual', _('固定转速'));
		o.default = 'smart';
		o.depends('enabled', '1');
		o.rmempty = false;

		o = s.option(form.Value, 'manual_speed', _('固定转速（%）'));
		o.datatype = 'range(20,100)';
		o.default = '50';
		o.depends({ enabled: '1', mode: 'manual' });

		o = s.option(form.Value, 'temp_low', _('低速启动温度（°C）'));
		o.datatype = 'range(30,90)'; o.default = '55'; o.depends({ enabled: '1', mode: 'smart' });
		o = s.option(form.Value, 'speed_low', _('低速转速（%）'));
		o.datatype = 'range(20,100)'; o.default = '35'; o.depends({ enabled: '1', mode: 'smart' });
		o = s.option(form.Value, 'temp_medium', _('中速启动温度（°C）'));
		o.datatype = 'range(35,95)'; o.default = '65'; o.depends({ enabled: '1', mode: 'smart' });
		o = s.option(form.Value, 'speed_medium', _('中速转速（%）'));
		o.datatype = 'range(20,100)'; o.default = '65'; o.depends({ enabled: '1', mode: 'smart' });
		o = s.option(form.Value, 'temp_high', _('全速启动温度（°C）'));
		o.datatype = 'range(40,100)'; o.default = '75'; o.depends({ enabled: '1', mode: 'smart' });
		o = s.option(form.Value, 'hysteresis', _('回差温度（°C）'));
		o.datatype = 'range(1,10)'; o.default = '3'; o.depends({ enabled: '1', mode: 'smart' });
		o = s.option(form.Value, 'interval', _('检测间隔（秒）'));
		o.datatype = 'range(2,60)'; o.default = '5'; o.depends('enabled', '1');

		var statusNode = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('实时状态')),
			E('div', { 'id': 'c2000max-fan-status' }, renderStatus(status || {}))
		]);

		poll.add(function() {
			return L.resolveDefault(callFanStatus(), {}).then(function(data) {
				var node = document.getElementById('c2000max-fan-status');
				if (node)
					dom.content(node, renderStatus(data));
			});
		});

		return m.render().then(function(formNode) {
			return E([ statusNode, formNode ]);
		});
	}
});
