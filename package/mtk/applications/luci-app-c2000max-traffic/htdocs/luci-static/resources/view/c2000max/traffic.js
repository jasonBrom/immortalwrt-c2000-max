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

var callTrafficCatalog = rpc.declare({
	object: 'c2000max.traffic',
	method: 'catalog',
	expect: { '': {} }
});

var callTrafficAudit = rpc.declare({
	object: 'c2000max.traffic',
	method: 'audit',
	params: [ 'device', 'from', 'to' ],
	expect: { '': {} }
});

var callFeatureInstall = rpc.declare({
	object: 'c2000max.traffic',
	method: 'feature_install',
	expect: { '': {} }
});

var callPolicyReload = rpc.declare({
	object: 'c2000max.traffic',
	method: 'policy_reload',
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

function auditModeName(mode) {
	if (mode === 'balanced') return '均衡（8 包）';
	if (mode === 'precise') return '精确（64 包）';
	return '无感（机会式识别）';
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

function asArray(value) {
	if (Array.isArray(value))
		return value;
	if (value && typeof value === 'object')
		return Object.keys(value).map(function(key) { return value[key]; });
	return [];
}

function svgNode(name, attributes, children) {
	var node = document.createElementNS('http://www.w3.org/2000/svg', name);
	Object.keys(attributes || {}).forEach(function(key) {
		node.setAttribute(key, attributes[key]);
	});
	asArray(children).forEach(function(child) {
		if (child != null)
			node.appendChild(child.nodeType ? child : document.createTextNode(String(child)));
	});
	return node;
}

function renderChart(history) {
	var samples = [];
	var width = 900;
	var height = 220;
	var padding = 34;
	var maxRate = 0;

	history = asArray(history).filter(function(point) {
		return point && isFinite(Number(point.timestamp)) && Number(point.timestamp) > 0;
	}).sort(function(a, b) {
		return Number(a.timestamp) - Number(b.timestamp);
	}).filter(function(point, index, list) {
		return index === list.length - 1 || Number(point.timestamp) !== Number(list[index + 1].timestamp);
	});

	if (history.length === 1)
		samples.push({ timestamp: Number(history[0].timestamp), upload: 0, download: 0 });
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
			'尚无有效历史样本；服务首次采样后即显示图表。');

	maxRate = maxRate || 1;
	function points(field) {
		return samples.map(function(sample, index) {
			var x = padding + index * (width - padding * 2) / Math.max(1, samples.length - 1);
			var y = height - padding - sample[field] * (height - padding * 2) / maxRate;
			return '%s,%s'.format(x.toFixed(1), y.toFixed(1));
		}).join(' ');
	}

	var svg = svgNode('svg', {
		viewBox: '0 0 %d %d'.format(width, height),
		style: 'display:block;width:100%;height:auto;min-height:180px;background:rgba(127,127,127,.06);border-radius:4px',
		role: 'img',
		'aria-label': '总上传和下载流量趋势'
	}, [
		svgNode('line', { x1: padding, y1: height - padding, x2: width - padding,
			y2: height - padding, stroke: '#888', 'stroke-width': 1 }),
		svgNode('line', { x1: padding, y1: padding, x2: padding,
			y2: height - padding, stroke: '#888', 'stroke-width': 1 }),
		svgNode('polyline', { points: points('download'), fill: 'none', stroke: '#1677ff',
			'stroke-width': 3, 'stroke-linejoin': 'round' }),
		svgNode('polyline', { points: points('upload'), fill: 'none', stroke: '#22a06b',
			'stroke-width': 3, 'stroke-linejoin': 'round' })
	]);

	return E('div', {}, [
		E('div', { 'style': 'display:flex;gap:1.5em;margin-bottom:.5em' }, [
			E('span', { 'style': 'color:#1677ff' }, '● 下载'),
			E('span', { 'style': 'color:#22a06b' }, '● 上传'),
			E('span', { 'style': 'margin-left:auto' }, '峰值：%s · %d 个速率点'.format(speed(maxRate), samples.length))
		]),
		svg
	]);
}

function renderPie(items, emptyText) {
	var colors = [ '#1677ff', '#22a06b', '#fa8c16', '#722ed1', '#eb2f96', '#13c2c2', '#a0d911', '#8c8c8c' ];
	var total = items.reduce(function(sum, item) { return sum + Number(item.value || 0); }, 0);
	var offset = 0;
	var gradients = [];

	if (!total)
		return E('div', { 'class': 'alert-message notice' }, emptyText || '这个时间段没有应用流量。');

	items.forEach(function(item, index) {
		var end = offset + Number(item.value || 0) * 100 / total;
		gradients.push('%s %.3f%% %.3f%%'.format(colors[index % colors.length], offset, end));
		item.color = colors[index % colors.length];
		offset = end;
	});

	return E('div', { 'style': 'display:flex;gap:1.25em;align-items:center;flex-wrap:wrap' }, [
		E('div', { 'style': 'width:150px;height:150px;border-radius:50%;background:conic-gradient(%s)'.format(gradients.join(',')) }),
		E('div', { 'style': 'min-width:220px;flex:1' }, items.map(function(item) {
			return E('div', { 'style': 'display:flex;gap:.5em;align-items:center;margin:.25em 0' }, [
				E('span', { 'style': 'color:%s'.format(item.color) }, '●'),
				E('span', { 'style': 'flex:1' }, item.name),
				E('span', {}, '%s（%.1f%%）'.format(bytes(item.value), Number(item.value) * 100 / total))
			]);
		}))
	]);
}

function createAlwaysBlock(device, app) {
	if (!device.mac)
		return Promise.reject(new Error('此设备没有可用的 MAC 地址，不能创建稳定的设备规则。'));

	var sid = uci.add('c2000max_traffic', 'schedule');
	uci.set('c2000max_traffic', sid, 'name', '阻断 %s - %s'.format(device.name || device.mac, app.name));
	uci.set('c2000max_traffic', sid, 'enabled', '1');
	uci.set('c2000max_traffic', sid, 'target', 'selected');
	uci.set('c2000max_traffic', sid, 'devices', [ device.mac ]);
	uci.set('c2000max_traffic', sid, 'apps', [ String(app.id) ]);
	uci.set('c2000max_traffic', sid, 'days', [ '0', '1', '2', '3', '4', '5', '6' ]);
	uci.set('c2000max_traffic', sid, 'start', '00:00');
	uci.set('c2000max_traffic', sid, 'end', '00:00');

	return uci.save().then(function() {
		return ui.changes.apply(true);
	}).then(function() {
		return callPolicyReload();
	});
}

function confirmAlwaysBlock(device, app) {
	ui.showModal('创建应用阻断规则', [
		E('p', {}, '将为 %s 创建一条全天阻断“%s”的规则。之后可在本页的“定时应用管控”中修改时间或删除。'.format(device.name || device.mac, app.name)),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, '取消'), ' ',
			E('button', { 'class': 'btn cbi-button-negative important', 'click': function() {
				return createAlwaysBlock(device, app).then(function() {
					ui.hideModal();
					location.reload();
				}).catch(function(error) {
					ui.addNotification(null, E('p', {}, error.message));
				});
			} }, '创建并应用')
		])
	]);
}

function showDeviceAudit(device, seconds) {
	var now = Math.floor(Date.now() / 1000);
	var from = now - seconds;
	ui.showModal('应用流量审计 - %s'.format(device.name || device.ip || device.id), [
		E('p', { 'class': 'spinning' }, '正在加载应用流量…')
	]);

	return L.resolveDefault(callTrafficAudit(device.id, from, now), { apps: [], categories: [] }).then(function(data) {
		var apps = asArray(data.apps);
		var categoryRows = asArray(data.categories);
		var categories = categoryRows.slice(0, 8).map(function(category) {
			return { name: category.name, value: Number(category.total || 0) };
		});
		if (categoryRows.length > 8) {
			categories.push({
				name: '其他分类',
				value: categoryRows.slice(8).reduce(function(sum, category) {
					return sum + Number(category.total || 0);
				}, 0)
			});
		}
		var fiveg = 0, other = 0, unknown = 0;
		apps.forEach(function(app) {
			fiveg += Number(app.fiveg_upload || 0) + Number(app.fiveg_download || 0);
			other += Number(app.other_upload || 0) + Number(app.other_download || 0);
			unknown += Number(app.unknown_upload || 0) + Number(app.unknown_download || 0);
		});
		var rows = apps.slice(0, 100).map(function(app) {
			return E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td' }, [ E('strong', {}, app.name), E('div', { 'style': 'color:#777;font-size:90%' }, app.category || '未知') ]),
				E('div', { 'class': 'td' }, trafficPair(app.fiveg_upload, app.fiveg_download)),
				E('div', { 'class': 'td' }, trafficPair(app.other_upload, app.other_download)),
				E('div', { 'class': 'td' }, trafficPair(app.unknown_upload, app.unknown_download)),
				E('div', { 'class': 'td' }, bytes(app.total)),
				E('div', { 'class': 'td' }, app.id > 0 && device.mac ? E('button', {
					'class': 'btn cbi-button-negative',
					'click': function() { confirmAlwaysBlock(device, app); }
				}, '阻断') : '-')
			]);
		});
		if (!rows.length)
			rows.push(E('div', { 'class': 'tr' }, E('div', { 'class': 'td' }, '所选时间段没有流量。')));

		ui.showModal('应用流量审计 - %s'.format(device.name || device.ip || device.id), [
			E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;margin-bottom:1em' }, [
				[ 86400, '24 小时' ], [ 604800, '7 天' ], [ 2592000, '30 天' ]
			].map(function(period) {
				return E('button', {
					'class': 'btn %s'.format(seconds === period[0] ? 'cbi-button-action' : ''),
					'click': function() { return showDeviceAudit(device, period[0]); }
				}, period[1]);
			})),
			E('h4', {}, '应用分类占比'),
			renderPie(categories, '这个时间段没有可展示的应用分类。'),
			E('h4', {}, '出口流量类型'),
			renderPie([
				{ name: '5G', value: fiveg },
				{ name: '其他/宽带', value: other },
				{ name: '未分类出口', value: unknown }
			], '这个时间段没有出口流量。'),
			E('h4', {}, '应用明细'),
			E('div', { 'class': 'table cbi-section-table' }, [
				E('div', { 'class': 'tr table-titles' }, [
					E('div', { 'class': 'th' }, '应用'), E('div', { 'class': 'th' }, '5G（上传 / 下载）'),
					E('div', { 'class': 'th' }, '其他（上传 / 下载）'), E('div', { 'class': 'th' }, '未分类'),
					E('div', { 'class': 'th' }, '总计'), E('div', { 'class': 'th' }, '操作')
				])
			].concat(rows)),
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, '关闭'))
		]);
	});
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
			E('div', { 'class': 'td' }, trafficPair(device.unknown_upload, device.unknown_download)),
			E('div', { 'class': 'td' }, E('button', {
				'class': 'btn cbi-button-action',
				'click': function() { return showDeviceAudit(device, 86400); }
			}, '查看应用'))
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
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '应用审计'),
					E('div', { 'class': 'td left' }, !status.audit_enabled ? '已关闭（流量记为未审计）' :
						(status.audit_active ? '运行中' : '已启用，引擎未运行')),
					E('div', { 'class': 'td left' }, '识别策略'),
					E('div', { 'class': 'td left' }, auditModeName(status.audit_mode))
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '特征库'),
					E('div', { 'class': 'td left' }, '%s / %s 个应用 / %s 条内核特征'.format(
						status.feature_version || '未知', Number(status.feature_apps || 0),
						Number(status.audit_loaded_features || 0))),
					E('div', { 'class': 'td left' }, '加速暂缓'),
					E('div', { 'class': 'td left' }, status.audit_holds_acceleration ?
						('未知连接最多 %d 包'.format(Number(status.audit_packets || 0))) : '不暂缓')
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '生效阻断规则'),
					E('div', { 'class': 'td left' }, String(Number(status.policy_rules || 0))),
					E('div', { 'class': 'td left' }, '趋势样本'),
					E('div', { 'class': 'td left' }, String(Number(status.history_samples || 0)))
				])
			])
		].concat(status.audit_error ? [ E('div', { 'class': 'alert-message warning' }, '应用审计错误：%s'.format(status.audit_error)) ] : [])),
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
					E('div', { 'class': 'th' }, '其他/宽带（上传 / 下载）'), E('div', { 'class': 'th' }, '未分类（上传 / 下载）'),
					E('div', { 'class': 'th' }, '应用审计')
				])
			].concat(rows))
		])
	];
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('c2000max_traffic'),
			L.resolveDefault(callTrafficStatus(), {}),
			L.resolveDefault(callTrafficCatalog(), { categories: [], apps: [] })
		]);
	},
	render: function(data) {
		var status = data[1] || {};
		var catalog = data[2] || {};
		var devices = asArray(status.devices);
		var categories = asArray(catalog.categories);
		var apps = asArray(catalog.apps);
		var m = new form.Map('c2000max_traffic', 'C2000MAX 流量统计',
			'HNAT 使用硬件 MIB 同步，Flow Offloading 和普通转发使用 Conntrack；切换加速模式后累计值与应用审计不会重置。');
		var s = m.section(form.NamedSection, 'config', 'traffic', '统计设置');
		s.anonymous = true;
		var o = s.option(form.Flag, 'enabled', '启用流量统计'); o.default = o.enabled; o.rmempty = false;
		o = s.option(form.Value, 'sample_interval', '采样间隔（秒）'); o.datatype = 'and(uinteger,min(5),max(300))'; o.default = '10'; o.rmempty = false;
		o = s.option(form.Value, 'flush_interval', '持久化间隔（秒）', '写入闪存的间隔，建议不小于 3600 秒。'); o.datatype = 'and(uinteger,min(300),max(86400))'; o.default = '3600'; o.rmempty = false;

		s = m.section(form.NamedSection, 'audit', 'audit', '应用流量审计',
			'默认关闭。无感模式不会为了识别阻止 HNAT/PPE 或软件 Flow Offload，未识别连接直接记为“未知/其他”；均衡和精确模式会暂缓未知连接加速以提高识别率。');
		s.anonymous = true;
		o = s.option(form.Flag, 'enabled', '启用应用审计'); o.default = o.disabled; o.rmempty = false;
		o = s.option(form.ListValue, 'recognition_mode', '识别策略');
		o.value('seamless', '无感（推荐，识别率较低）');
		o.value('balanced', '均衡（未知连接最多检查 8 包）');
		o.value('precise', '精确（未知连接最多检查 64 包）');
		o.default = 'seamless'; o.rmempty = false;
		o.description = '无感模式只检查连接在加速建立前自然经过 CPU 的数据包，不额外增加慢路径时间；应用禁用对未识别连接可能延后到下一次连接。';
		o = s.option(form.Value, 'retention_days', '明细保留天数'); o.datatype = 'and(uinteger,min(1),max(90))'; o.default = '30'; o.rmempty = false;
		o = s.option(form.Button, '_upload_feature', '上传/更新特征库',
			'支持官方 ZIP，或 ZIP 内单独的 feature3.0_*.bin；当前：%s，%d 个应用。'.format(catalog.version || '未知', apps.length));
		o.inputstyle = 'action'; o.inputtitle = '选择文件并更新';
		o.onclick = function(ev) {
			return ui.uploadFile('/tmp/c2000max-feature-upload', ev.target).then(function() {
				return callFeatureInstall();
			}).then(function(result) {
				if (!result || result.success !== true)
					throw new Error((result && (result.message || result.error)) || '特征库安装失败');
				ui.addNotification(null, E('p', {}, '特征库已更新到 %s，共 %d 个应用。'.format(result.version, Number(result.apps || 0))));
				location.reload();
			}).catch(function(error) {
				ui.addNotification(null, E('p', {}, error.message));
			});
		};

		s = m.section(form.GridSection, 'schedule', '定时应用管控',
			'多条规则可重叠，任一命中即阻断。开始时间与结束时间相同表示所选星期全天；结束时间早于开始时间表示跨午夜。');
		s.anonymous = true; s.addremove = true; s.sortable = true; s.nodescriptions = true;
		o = s.option(form.Flag, 'enabled', '启用'); o.default = o.enabled; o.rmempty = false;
		o = s.option(form.Value, 'name', '规则名称'); o.placeholder = '例如：上课时间禁用游戏'; o.rmempty = false;
		o = s.option(form.MultiValue, 'days', '星期');
		[ [ '1', '周一' ], [ '2', '周二' ], [ '3', '周三' ], [ '4', '周四' ], [ '5', '周五' ], [ '6', '周六' ], [ '0', '周日' ] ].forEach(function(day) { o.value(day[0], day[1]); });
		o.default = [ '0', '1', '2', '3', '4', '5', '6' ]; o.rmempty = false;
		o = s.option(form.Value, 'start', '开始时间'); o.default = '00:00'; o.placeholder = 'HH:MM'; o.rmempty = false; o.modalonly = true;
		o.validate = function(sectionId, value) { return /^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/.test(value) ? true : '请输入 HH:MM（00:00–23:59）'; };
		o = s.option(form.Value, 'end', '结束时间'); o.default = '00:00'; o.placeholder = 'HH:MM'; o.rmempty = false; o.modalonly = true;
		o.validate = function(sectionId, value) { return /^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/.test(value) ? true : '请输入 HH:MM（00:00–23:59）'; };
		o = s.option(form.ListValue, 'target', '作用设备');
		o.value('all', '全部设备（可设白名单）'); o.value('selected', '仅指定设备'); o.default = 'all'; o.rmempty = false; o.modalonly = true;
		o = s.option(form.DynamicList, 'devices', '指定设备'); o.depends('target', 'selected'); o.modalonly = true;
		devices.forEach(function(device) { if (device.mac) o.value(device.mac, '%s（%s）'.format(device.name || device.ip || device.mac, device.mac)); });
		o = s.option(form.DynamicList, 'whitelist', '设备白名单'); o.depends('target', 'all'); o.modalonly = true;
		devices.forEach(function(device) { if (device.mac) o.value(device.mac, '%s（%s）'.format(device.name || device.ip || device.mac, device.mac)); });
		o = s.option(form.MultiValue, 'categories', '应用分类', '勾选后阻断该分类下的全部应用；分类来自当前特征库。'); o.modalonly = true;
		categories.forEach(function(category) { o.value(String(category.id), category.name); });
		o = s.option(form.MultiValue, 'apps', '指定应用', '列表按分类排序，可与整个分类同时选择，生成规则时自动去重。'); o.modalonly = true;
		apps.forEach(function(app) { o.value(String(app.id), '【%s】%s'.format(app.category || '未知', app.name)); });

		var trafficNode = E('div', { 'id': 'c2000-traffic-body' }, renderTraffic(status));
		poll.add(function() {
			return L.resolveDefault(callTrafficStatus(), {}).then(function(status) {
				var node = document.getElementById('c2000-traffic-body');
				if (node) L.dom.content(node, renderTraffic(status));
			});
		}, 5);
		return m.render().then(function(formNode) { return E('div', {}, [ trafficNode, formNode ]); });
	}
});
