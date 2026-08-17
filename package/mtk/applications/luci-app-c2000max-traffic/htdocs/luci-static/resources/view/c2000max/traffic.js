'use strict';
'require form';
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

function speed(value) {
	return '%s/s'.format(bytes(value));
}

function accelerationName(value) {
	return ({
		mediatek_hnat: 'MediaTek HNAT',
		flow_offloading: 'Flow Offloading',
		disabled: '普通转发'
	})[value] || value || '未知';
}

function sourceName(value) {
	return ({
		hardware_mib: 'HNAT 硬件 MIB → Conntrack',
		flowtable_conntrack: 'Flowtable → Conntrack',
		conntrack: 'Conntrack'
	})[value] || value || '未知';
}

function trafficPair(upload, download) {
	return E('span', {}, [
		E('span', { 'style': 'white-space:nowrap' }, [ '↑ ', bytes(upload) ]),
		' / ',
		E('span', { 'style': 'white-space:nowrap' }, [ '↓ ', bytes(download) ])
	]);
}

function historyTotal(point, direction) {
	return Number(point['fiveg_' + direction] || 0) +
		Number(point['other_' + direction] || 0) +
		Number(point['unknown_' + direction] || 0);
}

function renderChart(history) {
	var samples = [];
	var width = 900;
	var height = 220;
	var padding = 34;
	var maxRate = 0;

	if (!Array.isArray(history))
		history = [];
	for (var i = 1; i < history.length; i++) {
		var elapsed = Number(history[i].timestamp) - Number(history[i - 1].timestamp);
		if (elapsed <= 0)
			continue;
		var up = Math.max(0, historyTotal(history[i], 'upload') -
			historyTotal(history[i - 1], 'upload')) / elapsed;
		var down = Math.max(0, historyTotal(history[i], 'download') -
			historyTotal(history[i - 1], 'download')) / elapsed;
		maxRate = Math.max(maxRate, up, down);
		samples.push({ timestamp: Number(history[i].timestamp), upload: up, download: down });
	}
	if (samples.length > 240)
		samples = samples.slice(samples.length - 240);

	if (!samples.length)
		return E('div', { 'class': 'alert-message notice' },
			'正在积累图表采样，通常约一分钟后显示。');

	maxRate = maxRate || 1;
	function points(field) {
		return samples.map(function(sample, index) {
			var x = padding + index * (width - padding * 2) / Math.max(1, samples.length - 1);
			var y = height - padding - sample[field] * (height - padding * 2) / maxRate;
			return '%s,%s'.format(x.toFixed(1), y.toFixed(1));
		}).join(' ');
	}

	return E('div', {}, [
		E('div', { 'style': 'display:flex;gap:1.5em;margin-bottom:.5em' }, [
			E('span', { 'style': 'color:#1677ff' }, '● 下载'),
			E('span', { 'style': 'color:#22a06b' }, '● 上传'),
			E('span', { 'style': 'margin-left:auto' }, '峰值：%s'.format(speed(maxRate)))
		]),
		E('svg', {
			'viewBox': '0 0 %d %d'.format(width, height),
			'style': 'display:block;width:100%;height:auto;min-height:180px;background:rgba(127,127,127,.06);border-radius:4px',
			'role': 'img',
			'aria-label': '总上传和下载流量趋势'
		}, [
			E('line', { x1: padding, y1: height - padding, x2: width - padding,
				y2: height - padding, stroke: '#888', 'stroke-width': 1 }),
			E('line', { x1: padding, y1: padding, x2: padding,
				y2: height - padding, stroke: '#888', 'stroke-width': 1 }),
			E('polyline', { points: points('download'), fill: 'none', stroke: '#1677ff',
				'stroke-width': 3, 'stroke-linejoin': 'round' }),
			E('polyline', { points: points('upload'), fill: 'none', stroke: '#22a06b',
				'stroke-width': 3, 'stroke-linejoin': 'round' })
		])
	]);
}

function renderTraffic(status) {
	var totals = status.totals || {};
	var devices = Array.isArray(status.devices) ? status.devices : [];
	var updated = Number(status.updated || 0);
	var totalUpload = Number(totals.fiveg_upload || 0) + Number(totals.other_upload || 0) + Number(totals.unknown_upload || 0);
	var totalDownload = Number(totals.fiveg_download || 0) + Number(totals.other_download || 0) + Number(totals.unknown_download || 0);
	var rows = devices.map(function(device) {
		var title = device.name || device.ip || device.mac || device.id || '未知设备';
		var detail = [];
		if (device.ip && device.ip !== title) detail.push(device.ip);
		if (device.mac && device.mac !== title) detail.push(device.mac);
		return E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td' }, [ E('strong', {}, title), detail.length ?
				E('div', { 'style': 'color:#777;font-size:90%' }, detail.join(' · ')) : '' ]),
			E('div', { 'class': 'td' }, trafficPair(device.fiveg_upload, device.fiveg_download)),
			E('div', { 'class': 'td' }, trafficPair(device.other_upload, device.other_download)),
			E('div', { 'class': 'td' }, trafficPair(device.unknown_upload, device.unknown_download))
		]);
	});
	if (!rows.length)
		rows.push(E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td' }, '尚无设备流量。') ]));

	return [
		E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '实时运行状态'),
			E('div', { 'class': 'table' }, [
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '统计服务'),
					E('div', { 'class': 'td left' }, status.active ? '运行中' : '未运行'),
					E('div', { 'class': 'td left' }, '加速模式'),
					E('div', { 'class': 'td left' }, accelerationName(status.acceleration))
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '统计来源'),
					E('div', { 'class': 'td left' }, sourceName(status.counter_source)),
					E('div', { 'class': 'td left' }, '最后采样'),
					E('div', { 'class': 'td left' }, updated ? new Date(updated * 1000).toLocaleString() : '等待首次采样')
				])
			])
		]),
		E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '总流量趋势'), renderChart(status.history),
			E('p', {}, [ '累计总量：', trafficPair(totalUpload, totalDownload) ])
		]),
		E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '分类累计流量'),
			E('div', { 'class': 'table' }, [ E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td left' }, E('strong', {}, '5G 流量')),
				E('div', { 'class': 'td left' }, trafficPair(totals.fiveg_upload, totals.fiveg_download)),
				E('div', { 'class': 'td left' }, E('strong', {}, '其他/宽带流量')),
				E('div', { 'class': 'td left' }, trafficPair(totals.other_upload, totals.other_download))
			]) ]),
			E('div', { 'class': 'right' }, [ E('button', {
				'class': 'btn cbi-button-negative',
				'click': function() {
					ui.showModal('清空累计流量', [ E('p', {}, '确定清空全部累计流量和趋势图吗？'),
						E('div', { 'class': 'right' }, [
							E('button', { 'class': 'btn', 'click': ui.hideModal }, '取消'), ' ',
							E('button', { 'class': 'btn cbi-button-negative important', 'click': function() {
								return callTrafficReset().then(ui.hideModal);
							} }, '确认清空')
						]) ]);
				}
			}, '清空统计') ])
		]),
		E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '各设备流量'),
			E('div', { 'class': 'table cbi-section-table' }, [
				E('div', { 'class': 'tr table-titles' }, [
					E('div', { 'class': 'th' }, '设备'), E('div', { 'class': 'th' }, '5G（上传 / 下载）'),
					E('div', { 'class': 'th' }, '其他/宽带（上传 / 下载）'), E('div', { 'class': 'th' }, '未分类（上传 / 下载）')
				])
			].concat(rows))
		])
	];
}

return view.extend({
	load: function() {
		return Promise.all([ uci.load('c2000max_traffic'), L.resolveDefault(callTrafficStatus(), {}) ]);
	},
	render: function(data) {
		var m = new form.Map('c2000max_traffic', 'C2000MAX 流量统计',
			'HNAT 使用硬件 MIB 同步，Flow Offloading 和普通转发使用 Conntrack；切换加速模式后累计值不会重置。');
		var s = m.section(form.NamedSection, 'config', 'traffic', '统计设置');
		s.anonymous = true;
		var o = s.option(form.Flag, 'enabled', '启用流量统计'); o.default = o.enabled; o.rmempty = false;
		o = s.option(form.Value, 'sample_interval', '采样间隔（秒）'); o.datatype = 'and(uinteger,min(5),max(300))'; o.default = '10'; o.rmempty = false;
		o = s.option(form.Value, 'flush_interval', '持久化间隔（秒）', '写入闪存的间隔，建议不小于 3600 秒。'); o.datatype = 'and(uinteger,min(300),max(86400))'; o.default = '3600'; o.rmempty = false;

		var trafficNode = E('div', { 'id': 'c2000-traffic-body' }, renderTraffic(data[1] || {}));
		poll.add(function() {
			return L.resolveDefault(callTrafficStatus(), {}).then(function(status) {
				var node = document.getElementById('c2000-traffic-body');
				if (node) L.dom.content(node, renderTraffic(status));
			});
		}, 5);
		return m.render().then(function(formNode) { return E('div', {}, [ trafficNode, formNode ]); });
	}
});
