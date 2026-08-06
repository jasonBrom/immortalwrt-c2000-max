'use strict';
'require baseclass';
'require rpc';

var callHardwareStatus = rpc.declare({
	object: 'c2000max',
	method: 'hardware_status',
	expect: { '': {} }
});

function number(value) {
	value = Number(value);
	return isFinite(value) && value >= 0 ? value : 0;
}

function temperature(value) {
	value = number(value);
	return value ? '%.1f °C'.format(value / 1000) : _('未检测到');
}

function frequency(khz) {
	khz = number(khz);
	if (!khz)
		return _('未检测到');
	return (khz >= 1000000) ? '%.3f GHz'.format(khz / 1000000) : '%.0f MHz'.format(khz / 1000);
}

return baseclass.extend({
	title: _('C2000-MAX 硬件与 PPE 状态'),

	load: function() {
		return L.resolveDefault(callHardwareStatus(), {});
	},

	render: function(data) {
		data = data || {};
		var fields = [], cpus = Array.isArray(data.cpus) ? data.cpus : [];

		cpus.sort(function(a, b) { return number(a.core) - number(b.core); });
		for (var i = 0; i < cpus.length; i++)
			fields.push(_('CPU 核心 %s 实时频率').format(cpus[i].core), frequency(cpus[i].khz));

		if (!cpus.length)
			fields.push(_('CPU 实时频率'), _('未检测到'));

		fields.push(_('CPU 温度'), temperature(data.cpu_temp));

		var ppe = data.ppe || {};
		if (ppe.available) {
			var ppe0 = number(ppe.ppe0);
			var ppe1 = number(ppe.ppe1);
			var total = number(ppe.total);

			fields.push(_('PPE0 / PPE1 BIND 表项'), _('%d / %d 条').format(ppe0, ppe1));
			fields.push(_('BIND 表项总数'), _('%d 条').format(total));
			fields.push(_('UNBIND / FIN 表项'), _('%d / %d 条').format(number(ppe.unbind), number(ppe.fin)));
		}

		var table = E('table', { 'class': 'table' });
		for (var k = 0; k < fields.length; k += 2) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, fields[k]),
				E('td', { 'class': 'td left' }, fields[k + 1])
			]));
		}

		return table;
	}
});
