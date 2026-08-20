'use strict';
'require c2000max.traffic-chart as trafficChart';
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

var callCatalogInfo = rpc.declare({
	object: 'c2000max.traffic',
	method: 'catalog_info',
	params: [ 'profile' ],
	expect: { '': {} }
});

var callCatalogSearch = rpc.declare({
	object: 'c2000max.traffic',
	method: 'catalog_search',
	params: [ 'profile', 'query', 'category', 'offset', 'limit' ],
	expect: { '': {} }
});

var callCatalogLookup = rpc.declare({
	object: 'c2000max.traffic',
	method: 'catalog_lookup',
	params: [ 'profile', 'ids' ],
	expect: { '': {} }
});

var callTrafficAudit = rpc.declare({
	object: 'c2000max.traffic',
	method: 'audit',
	params: [ 'device', 'from', 'to' ],
	expect: { '': {} }
});

var callRecentAudit = rpc.declare({
	object: 'c2000max.traffic',
	method: 'recent_audit',
	params: [ 'offset', 'limit' ],
	expect: { '': {} }
});

var callFeatureInstall = rpc.declare({
	object: 'c2000max.traffic',
	method: 'feature_install',
	expect: { '': {} }
});

var callFeatureInstallStatus = rpc.declare({
	object: 'c2000max.traffic',
	method: 'feature_install_status',
	params: [ 'job_id' ],
	expect: { '': {} }
});

var callFeatureList = rpc.declare({
	object: 'c2000max.traffic',
	method: 'feature_list',
	expect: { '': {} }
});

var callFeatureActivate = rpc.declare({
	object: 'c2000max.traffic',
	method: 'feature_activate',
	params: [ 'id' ],
	expect: { '': {} }
});

var callFeatureRollback = rpc.declare({
	object: 'c2000max.traffic',
	method: 'feature_rollback',
	expect: { '': {} }
});

var callPolicyReload = rpc.declare({
	object: 'c2000max.traffic',
	method: 'policy_reload',
	expect: { '': {} }
});

var currentProfileId = '';
var auditModalSequence = 0;
var featureInstallInProgress = false;
var featureJobBannerNode = null;
var featureJobBannerStatus = { state: 'idle' };
var featureJobRecoveryStarted = false;

/* rpc.declare() has no per-call timeout.  A slow audit/catalog process must not
 * keep LuCI's view loader pending forever: once load() is pending, LuCI does
 * not call render() at all and the user only sees "正在载入视图".  This helper
 * bounds calls used for first paint while allowing the original request to
 * finish in the background. */
function resolveWithin(promise, fallback, timeout) {
	return new Promise(function(resolve) {
		var settled = false;
		var timer = setTimeout(function() {
			if (!settled) {
				settled = true;
				resolve(fallback);
			}
		}, Math.max(1, Number(timeout) || 1));

		Promise.resolve(promise).then(function(value) {
			if (settled)
				return;
			settled = true;
			clearTimeout(timer);
			resolve(value);
		}, function() {
			if (settled)
				return;
			settled = true;
			clearTimeout(timer);
			resolve(fallback);
		});
	});
}

/* LuCI treats a scalar string passed to E() as HTML, while strings inside an
 * array become Text nodes.  Catalog and device names ultimately come from an
 * uploaded library or DHCP, so always render them through this helper. */
function safeText(value) {
	return [ String(value == null ? '' : value) ];
}

/* form.value() preserves DOM nodes but stringifies arrays.  Use a real node
 * for untrusted choice captions so ui.Dropdown never receives a scalar string
 * (which LuCI otherwise interprets as HTML). */
function safeChoice(value) {
	return E('span', {}, safeText(value));
}

function destroyCharts(root) {
	if (!root)
		return;
	if (root.classList && root.classList.contains('c2000max-chart-frame'))
		root.dispatchEvent(new CustomEvent('c2000max-chart-destroy'));
	root.querySelectorAll('.c2000max-chart-frame').forEach(function(chart) {
		chart.dispatchEvent(new CustomEvent('c2000max-chart-destroy'));
	});
}

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
	if (mode === 'balanced') return '均衡（最多检查 8 个有效载荷包）';
	if (mode === 'precise') return '精确（最多检查 64 个有效载荷包）';
	return '无感（机会式识别）';
}

function controlModeName(mode) {
	return mode === 'force' ? '强力管控（现有连接立即重检）' : '无感管控（新连接生效）';
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

function profileItems(data) {
	return asArray((data || {}).profiles || (data || {}).libraries || (data || {}).items);
}

function profileId(profile) {
	return String((profile || {}).id || (profile || {}).sha256 || '');
}

function profileLabel(profile) {
	var source = String((profile || {}).source_format || (profile || {}).type || 'oaf-v3');
	var label = (profile || {}).label || (profile || {}).name || (profile || {}).version || profileId(profile).slice(0, 12);
	if (source === 'ik-native-v1')
		return '爱快原生库 %s'.format(label);
	if (/ikuai/i.test(source) || /-ikuai$/i.test(String((profile || {}).version || '')))
		return '爱快 OAF 转换库 %s'.format(label);
	return '特征库 %s'.format(label);
}

function resultError(result, fallback) {
	if (result && result.success === true)
		return null;
	return new Error((result && (result.message || result.error)) || fallback);
}

function rejectConcurrentFeatureJob() {
	if (!featureInstallInProgress)
		return false;
	ui.addNotification(null, E('p', {}, '已有特征库操作正在后台执行，请等待完成后再试。'));
	return true;
}

/* A rejected start request can be ambiguous: the worker may have accepted it
 * before the browser lost the response. Only a structured busy/validation or
 * terminal response proves that releasing the local single-flight guard is
 * safe. */
function featureJobStartCanRelease(result) {
	var state = String((result || {}).state || '');
	return !!(result && (result.busy === true || result.accepted === false ||
		state === 'done' || state === 'failed' || state === 'missing' || state === 'idle' ||
		(result.success === false && state !== 'queued' && state !== 'running')));
}

function featureInstallDelay() {
	return new Promise(function(resolve) { window.setTimeout(resolve, 2000); });
}

function featureJobPhaseName(status) {
	var phase = String((status || {}).phase || '');
	return ({
		queued: '等待后台任务',
		migrate: '整理旧库审计记录',
		install: '校验、编译并加载规则',
		activate: '切换并重载规则库',
		rollback: '回退并重载规则库',
		done: '处理完成',
		failed: '处理失败',
		upload: '上传文件'
	})[phase] || '后台处理特征库';
}

function renderFeatureJobBanner() {
	if (!featureJobBannerNode)
		return;
	var status = featureJobBannerStatus || {};
	var state = String(status.state || 'idle');
	var phase = featureJobPhaseName(status);
	var message = String(status.message || '');
	var body;

	featureJobBannerNode.style.display = state === 'idle' ? 'none' : '';
	featureJobBannerNode.className = 'alert-message ' +
		(state === 'failed' || state === 'missing' ? 'warning' : 'notice');
	if (state === 'idle') {
		L.dom.content(featureJobBannerNode, []);
		return;
	}
	body = E('div', { 'style': 'display:flex;gap:.75em;align-items:flex-start' }, [
		E('span', {
			'class': state === 'queued' || state === 'running' || state === 'upload' ?
				'spinning' : null,
			'style': 'min-width:1.2em;min-height:1.2em'
		}),
		E('div', {}, [
			E('strong', {}, safeText('特征库：%s'.format(phase))),
			E('div', { 'style': 'margin-top:.2em' }, safeText(message ||
				(state === 'done' ? '最近一次特征库操作已完成。' :
				 state === 'failed' ? '最近一次特征库操作失败。' :
				 '任务正在路由器后台执行，请勿断电。'))),
			(state === 'queued' || state === 'running' || state === 'upload') ?
				E('div', { 'style': 'color:#777;font-size:90%;margin-top:.25em' },
					'可以留在当前页面或切换标签；重新进入本页仍会显示任务进度。') : ''
		])
	]);
	L.dom.content(featureJobBannerNode, body);
}

function updateFeatureJobBanner(status) {
	featureJobBannerStatus = status && typeof status === 'object' ? status : { state: 'idle' };
	renderFeatureJobBanner();
}

function waitFeatureInstall(jobId, progress, failures) {
	/* Each status call is independently bounded.  A wedged rpcd request must
	 * not recreate the original endless XHR wait in the polling path. */
	return resolveWithin(callFeatureInstallStatus(jobId), null, 5000).then(function(status) {
		if (!status) {
			failures = Number(failures || 0) + 1;
			if (failures >= 5)
				throw new Error('连续无法查询特征库操作进度，请稍后重新进入页面查看。');
			return featureInstallDelay().then(function() {
				return waitFeatureInstall(jobId, progress, failures);
			});
		}
		var state = String((status || {}).state || '');
		updateFeatureJobBanner(status);
		if (state === 'done') {
			featureInstallInProgress = false;
			var result = status.result || status;
			var error = resultError(result, '特征库操作失败');
			if (error) throw error;
			return result;
		}
		if (state === 'failed' || state === 'missing' || state === 'idle') {
			featureInstallInProgress = false;
			throw new Error((status && (status.message || status.error)) || '特征库后台操作失败');
		}
		if (state !== 'queued' && state !== 'running')
			throw new Error('特征库后台任务返回了未知状态');
		if (progress)
			L.dom.content(progress, safeText(status.message || '正在后台处理特征库…'));
		return featureInstallDelay().then(function() {
			return waitFeatureInstall(jobId, progress, 0);
		});
	});
}

function resolveFeatureJobStart(result, progress, fallback) {
	var state = String((result || {}).state || '');
	if (result && (result.busy === true || result.accepted === false))
		throw resultError(result, '已有特征库操作任务正在运行') ||
			new Error('已有特征库操作任务正在运行');
	if (state === 'done') {
		var doneResult = result.result || result;
		var doneError = resultError(doneResult, fallback);
		if (doneError) throw doneError;
		return Promise.resolve(doneResult);
	}
	if (state === 'queued' || state === 'running') {
		if (!result.job_id)
			throw new Error('后台任务没有返回任务编号');
		if (progress)
			L.dom.content(progress, safeText(result.message || '任务已提交，正在后台处理…'));
		updateFeatureJobBanner(result);
		return waitFeatureInstall(result.job_id, progress, 0);
	}
	/* Keep compatibility with an older synchronous RPC backend. */
	var error = resultError(result, fallback);
	if (error) throw error;
	return Promise.resolve(result);
}

function appChoiceLabel(app) {
	if (!app)
		return '';
	var suffix = app.missing ? '（已失效）' : '';
	return '【%s】%s%s  #%s'.format(app.category || '未知', app.name || '应用', suffix, app.id);
}

function showAppPicker(option, widget) {
	var selected = {};
	var labels = option.labelCache || (option.labelCache = {});
	var profile = option.profile || currentProfileId;
	var categories = asArray(option.categories);
	/* LuCI owns a single modal node. Keep the GridSection editor DOM so the
	 * picker can replace it temporarily and return without losing form state. */
	var parentModalNode = document.querySelector('#modal_overlay > .modal');
	var parentModal = document.body.classList.contains('modal-overlay-active') && parentModalNode ? {
		node: parentModalNode,
		className: parentModalNode.className,
		children: Array.prototype.slice.call(parentModalNode.childNodes),
		scrollTop: parentModalNode.parentNode.scrollTop
	} : null;
	var sequence = 0;
	var page = 0;
	var pageSize = 50;
	var debounce = null;
	var query = E('input', {
		'class': 'cbi-input-text',
		'type': 'search',
		'placeholder': '输入软件名称或 APPID',
		'style': 'min-width:240px;flex:1'
	});
	var category = E('select', { 'class': 'cbi-input-select', 'style': 'min-width:170px' }, [
		E('option', { 'value': '0' }, '全部分类')
	].concat(categories.map(function(item) {
		return E('option', { 'value': String(item.id) }, safeText(
			'%s（%s）'.format(item.name, Number(item.count || 0))));
	})));
	var resultBody = E('div', {}, E('p', { 'class': 'spinning' }, '正在查询…'));
	var selectedStatus = E('span');
	var pageStatus = E('span');
	var previous = E('button', { 'class': 'btn', 'type': 'button', 'disabled': '' }, '上一页');
	var next = E('button', { 'class': 'btn', 'type': 'button', 'disabled': '' }, '下一页');

	L.toArray(widget.getValue()).forEach(function(id) { selected[String(id)] = true; });

	function closePicker(ev) {
		if (ev) {
			ev.preventDefault();
			ev.stopPropagation();
		}
		sequence++;
		if (debounce)
			clearTimeout(debounce);
		if (!parentModal) {
			ui.hideModal();
			return;
		}

		parentModal.node.setAttribute('class', parentModal.className);
		L.dom.content(parentModal.node, parentModal.children);
		document.body.classList.add('modal-overlay-active');
		parentModal.node.parentNode.scrollTop = parentModal.scrollTop;
	}

	function updateSelectedStatus() {
		var count = Object.keys(selected).length;
		L.dom.content(selectedStatus, '已选 %d 个（单项最多 256 个，大批量建议直接选分类）'.format(count));
	}

	function renderResults(result, requestPage) {
		var items = asArray(result.items || result.apps);
		var total = Number(result.total || 0);
		var pageCount = Math.max(1, Math.ceil(total / pageSize));
		page = Math.max(0, Math.min(requestPage, pageCount - 1));
		var rows = items.map(function(app) {
			var id = String(app.id);
			labels[id] = appChoiceLabel(app);
			var checkbox = E('input', {
				'type': 'checkbox',
				'checked': selected[id] ? '' : null,
				'change': function(ev) {
					if (ev.target.checked && !selected[id] && Object.keys(selected).length >= 256) {
						ev.target.checked = false;
						ui.addNotification(null, E('p', {}, '单项软件最多选择 256 个；请使用“应用分类”处理整类软件。'));
						return;
					}
					if (ev.target.checked)
						selected[id] = true;
					else
						delete selected[id];
					updateSelectedStatus();
				}
			});
			return E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td', 'style': 'width:3em;text-align:center' }, checkbox),
				E('div', { 'class': 'td' }, [ E('strong', {}, safeText(app.name || '未知应用')),
					E('div', { 'style': 'color:#777;font-size:90%' }, safeText(app.category || '未知分类')) ]),
				E('div', { 'class': 'td', 'style': 'width:8em;white-space:nowrap' }, '#%s'.format(id))
			]);
		});
		if (!rows.length)
			rows.push(E('div', { 'class': 'tr' }, E('div', { 'class': 'td' }, '没有匹配的软件。')));
		L.dom.content(resultBody, E('div', { 'class': 'table cbi-section-table' }, [
			E('div', { 'class': 'tr table-titles' }, [
				E('div', { 'class': 'th', 'style': 'width:3em' }, '选择'),
				E('div', { 'class': 'th' }, '软件'),
				E('div', { 'class': 'th', 'style': 'width:8em' }, 'APPID')
			])
		].concat(rows)));
		previous.disabled = page <= 0;
		next.disabled = !result.has_more && page >= pageCount - 1;
		L.dom.content(pageStatus, '第 %d / %d 页，共 %d 个可识别软件'.format(page + 1, pageCount, total));
	}

	function loadPage(wantedPage) {
		var requestSequence = ++sequence;
		var wantedQuery = query.value.trim();
		var wantedCategory = Number(category.value || 0);
		previous.disabled = true;
		next.disabled = true;
		L.dom.content(resultBody, E('p', { 'class': 'spinning' }, '正在查询…'));
		return L.resolveDefault(callCatalogSearch(profile, wantedQuery, wantedCategory,
			Math.max(0, wantedPage) * pageSize, pageSize), { items: [], total: 0 }).then(function(result) {
			if (requestSequence !== sequence || !document.body.contains(resultBody))
				return;
			if (result.success !== true)
				throw new Error(result.message || result.error || '查询软件失败');
			if (result.profile && result.profile !== profile)
				return;
			renderResults(result, wantedPage);
		}).catch(function(error) {
			if (requestSequence === sequence)
				L.dom.content(resultBody, E('div', { 'class': 'alert-message warning' }, safeText(error.message)));
		});
	}

	query.addEventListener('input', function() {
		if (debounce)
			clearTimeout(debounce);
		debounce = setTimeout(function() { loadPage(0); }, 300);
	});
	query.addEventListener('keydown', function(ev) {
		if (ev.key === 'Enter') {
			ev.preventDefault();
			if (debounce)
				clearTimeout(debounce);
			loadPage(0);
		}
	});
	category.addEventListener('change', function() { loadPage(0); });
	previous.addEventListener('click', function(ev) { ev.preventDefault(); loadPage(page - 1); });
	next.addEventListener('click', function(ev) { ev.preventDefault(); loadPage(page + 1); });

	updateSelectedStatus();
	/* Detach the GridSection editor before ui.showModal() replaces the LuCI
	 * singleton modal.  Keeping only references while the nodes are still
	 * attached is insufficient: L.dom.content() unregisters every descendant
	 * carrying data-idref, so reattaching those nodes would leave the form
	 * widgets unable to save. */
	if (parentModal)
		parentModal.children.forEach(function(child) {
			if (child.parentNode === parentModal.node)
				parentModal.node.removeChild(child);
		});
	ui.showModal('选择软件', [
		E('div', { 'style': 'max-height:calc(100vh - 190px);overflow:auto;padding-right:.5em' }, [
			E('div', { 'style': 'display:flex;gap:.6em;align-items:center;flex-wrap:wrap;margin-bottom:.75em' }, [ query, category ]),
			E('div', { 'style': 'margin-bottom:.6em;color:#555' }, selectedStatus),
			resultBody,
			E('div', { 'style': 'display:flex;justify-content:flex-end;align-items:center;gap:.6em;margin-top:.75em;flex-wrap:wrap' }, [
				previous, pageStatus, next
			])
		]),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'type': 'button', 'click': closePicker }, '取消'), ' ',
			E('button', { 'class': 'btn cbi-button-positive important', 'type': 'button', 'click': function(ev) {
				ev.preventDefault();
				ev.stopPropagation();
				var ids = Object.keys(selected).sort(function(a, b) { return Number(a) - Number(b); });
				var selectedLabels = {};
				ids.forEach(function(id) { selectedLabels[id] = safeText(labels[id] || '应用 #%s'.format(id)); });
				widget.clearChoices(true);
				widget.addChoices(ids, selectedLabels);
				widget.setValue(ids);
				closePicker();
			} }, '使用已选软件')
		])
	], 'c2000max-app-picker-modal');
	loadPage(0);
}

var LazyAppSelector = form.MultiValue.extend({
	renderWidget: function(sectionId, optionIndex, cfgvalue) {
		var values = L.toArray(cfgvalue != null ? cfgvalue : this.default).map(String);
		var labels = this.labelCache || (this.labelCache = {});
		var choices = {};
		values.forEach(function(id) { choices[id] = safeText(labels[id] || '应用 #%s'.format(id)); });
		var widget = new ui.Dropdown(values, choices, {
			id: this.cbid(sectionId),
			multiple: true,
			optional: true,
			create: false,
			display_items: 8,
			dropdown_items: 12,
			select_placeholder: '尚未选择单项软件',
			disabled: (this.readonly != null) ? this.readonly : this.map.readonly,
			validate: this.getValidator(sectionId)
		});
		var widgetNode = widget.render();
		var countNode = E('span', { 'style': 'color:#777' });
		function updateCount() {
			L.dom.content(countNode, '已选 %d 个'.format(L.toArray(widget.getValue()).length));
		}
		widgetNode.addEventListener('cbi-dropdown-change', updateCount);
		updateCount();
		return E('div', {}, [
			widgetNode,
			E('div', { 'style': 'display:flex;align-items:center;gap:.6em;margin-top:.5em;flex-wrap:wrap' }, [
				E('button', {
					'class': 'btn cbi-button-action',
					'type': 'button',
					'disabled': ((this.readonly != null) ? this.readonly : this.map.readonly) ? '' : null,
					'click': function(ev) {
						ev.preventDefault();
						ev.stopPropagation();
						showAppPicker(this, widget);
					}.bind(this)
				}, '搜索并选择软件'),
				countNode
			])
		]);
	},

	validate: function(sectionId, value) {
		var values = L.toArray(value);
		if (values.length > 256)
			return '单项软件最多选择 256 个；请使用应用分类。';
		for (var i = 0; i < values.length; i++)
			if (!/^[0-9]+$/.test(String(values[i])))
				return '应用 APPID 必须是数字。';
		return true;
	}
});

function renderFeatureManager(featureData, catalog) {
	var profiles = profileItems(featureData);
	var active = String((catalog || {}).profile || (catalog || {}).profile_id ||
		(featureData || {}).active || (featureData || {}).active_id || currentProfileId);
	var previousId = String((featureData || {}).previous || (featureData || {}).previous_id || '');
	var selector = E('select', { 'class': 'cbi-input-select', 'style': 'min-width:280px;max-width:100%' });
	profiles.forEach(function(profile) {
		var id = profileId(profile);
		if (!id)
			return;
		selector.appendChild(E('option', {
			'value': id,
			'selected': id === active ? '' : null,
			'title': id
		}, safeText('%s · %d 软件 · %d 特征'.format(
			profileLabel(profile), Number(profile.apps || profile.app_count || 0),
			Number(profile.features || profile.feature_count || 0)))));
	});
	if (!selector.children.length)
		selector.appendChild(E('option', { 'value': active }, safeText(catalog.version || '当前特征库')));

	function activate(id) {
		if (rejectConcurrentFeatureJob())
			return;
		var progress = E('p', { 'style': 'color:#777' }, '确认后将在后台执行切换。');
		ui.showModal('切换特征库', [
			E('p', {}, '切换时会先完成当前流量记账，再重载特征并重建客户端连接。现有连接可能短暂中断。'),
			E('p', {}, '管控规则按规则库隔离：只有属于新规则库的规则会生效，历史应用流量仍按原规则库显示。'),
			progress,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, '取消'), ' ',
				E('button', { 'class': 'btn cbi-button-positive important', 'click': function(ev) {
					var releaseOnError = false;
					var startResponseReceived = false;
					if (rejectConcurrentFeatureJob())
						return Promise.resolve();
					ev.target.classList.add('spinning');
					ev.target.disabled = true;
					featureInstallInProgress = true;
					return callFeatureActivate(id).then(function(result) {
						startResponseReceived = true;
						releaseOnError = featureJobStartCanRelease(result);
						return resolveFeatureJobStart(result, progress, '特征库切换失败');
					}).then(function() {
						featureInstallInProgress = false;
						location.reload();
					}).catch(function(error) {
						if (releaseOnError)
							featureInstallInProgress = false;
						ui.hideModal();
						ui.addNotification(null, E('p', {}, safeText(startResponseReceived ? error.message :
							'无法确认切换任务是否已提交；请稍后重新进入页面查看状态。')));
					});
				} }, '确认切换')
			])
		]);
	}

	var activeProfile = profiles.filter(function(profile) { return profileId(profile) === active; })[0] || {};
	var sourceTotal = Number(activeProfile.source_apps || activeProfile.source_total || 0);
	var nativeProfile = String(activeProfile.source_format || '') === 'ik-native-v1';
	return E('div', {}, [
		E('div', { 'style': 'display:flex;gap:.6em;align-items:center;flex-wrap:wrap' }, [
			selector,
			E('button', { 'class': 'btn cbi-button-action', 'click': function(ev) {
				ev.preventDefault();
				if (selector.value === active) {
					ui.addNotification(null, E('p', {}, '该特征库已在使用。'));
					return;
				}
				activate(selector.value);
			} }, '切换到选中库'),
			E('button', {
				'class': 'btn',
				'disabled': previousId && previousId !== active ? null : '',
				'click': function(ev) {
					ev.preventDefault();
					if (rejectConcurrentFeatureJob())
						return;
					var progress = E('p', { 'style': 'color:#777' }, '确认后将在后台执行回退。');
					ui.showModal('回退特征库', [
						E('p', {}, '确定切回上一个活动特征库吗？同样会重建现有客户端连接。'),
						progress,
						E('div', { 'class': 'right' }, [
							E('button', { 'class': 'btn', 'click': ui.hideModal }, '取消'), ' ',
							E('button', { 'class': 'btn cbi-button-positive important', 'click': function(buttonEvent) {
								var releaseOnError = false;
								var startResponseReceived = false;
								if (rejectConcurrentFeatureJob())
									return Promise.resolve();
								buttonEvent.target.classList.add('spinning');
								buttonEvent.target.disabled = true;
								featureInstallInProgress = true;
								return callFeatureRollback().then(function(result) {
									startResponseReceived = true;
									releaseOnError = featureJobStartCanRelease(result);
									return resolveFeatureJobStart(result, progress, '特征库回退失败');
								}).then(function() {
									featureInstallInProgress = false;
									location.reload();
								}).catch(function(error) {
									if (releaseOnError)
										featureInstallInProgress = false;
									ui.hideModal();
									ui.addNotification(null, E('p', {}, safeText(startResponseReceived ? error.message :
										'无法确认回退任务是否已提交；请稍后重新进入页面查看状态。')));
								});
							} }, '确认回退')
						])
					]);
				}
			}, '回退上一库')
		]),
		E('div', { 'style': 'color:#777;margin-top:.5em' }, [
			String('当前：%s，%d 个可识别软件'.format(catalog.version || '未知', Number(catalog.total_apps || catalog.apps || 0))),
			sourceTotal > Number(catalog.total_apps || 0) ?
				(nativeProfile ?
					'；来源库共 %d 个 APPID，%d 个未能被原生匹配器安全兼容。' :
					'；来源库共 %d 个 APPID，%d 个因 OAF 无法等价表达而未转换。').format(
					sourceTotal, sourceTotal - Number(catalog.total_apps || 0)) : '。'
		]),
		E('div', { 'style': 'color:#777;font-size:90%;margin-top:.35em;word-break:break-all' },
			safeText('规则库 ID：%s'.format(active || '未初始化')))
	]);
}

function renderChart(history) {
	var samples = [];
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

	return E('div', {}, [
		E('div', { 'style': 'text-align:right;margin-bottom:.25em;color:#777' },
			'峰值：%s · %d 个速率点 · 可悬停查看详情'.format(speed(maxRate), samples.length)),
		trafficChart.line(samples, { formatValue: speed, height: 240 })
	]);
}

function renderPie(items, emptyText) {
	return trafficChart.doughnut(items, {
		emptyText: emptyText || '这个时间段没有应用流量。',
		formatValue: bytes,
		centerLabel: '总计',
		height: 220
	});
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
	uci.set('c2000max_traffic', sid, 'ruleset', app.profile_id || currentProfileId);
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
		E('p', {}, safeText('将为 %s 创建一条全天阻断“%s”的规则。之后可在本页的“定时应用管控”中修改时间或删除。'.format(
			device.name || device.mac, app.name))),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, '取消'), ' ',
			E('button', { 'class': 'btn cbi-button-negative important', 'click': function() {
				return createAlwaysBlock(device, app).then(function() {
					ui.hideModal();
					location.reload();
				}).catch(function(error) {
					ui.addNotification(null, E('p', {}, safeText(error.message)));
				});
			} }, '创建并应用')
		])
	]);
}

function showDeviceAudit(device, seconds) {
	var now = Math.floor(Date.now() / 1000);
	var from = now - seconds;
	var requestSequence = ++auditModalSequence;
	destroyCharts(document.querySelector('#modal_overlay > .modal'));
	ui.showModal('应用流量审计 - %h'.format(device.name || device.ip || device.id), [
		E('p', { 'class': 'spinning' }, '正在加载应用流量…')
	], 'c2000max-audit-modal');

	return L.resolveDefault(callTrafficAudit(device.id, from, now), { apps: [], categories: [] }).then(function(data) {
		var activeModal = document.querySelector('#modal_overlay > .modal');
		if (requestSequence !== auditModalSequence || !activeModal ||
		    !activeModal.classList.contains('c2000max-audit-modal'))
			return;
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

		function renderAuditPage(page, sortMode) {
			var pageSize = 20;
			var sorted = apps.slice();
			var descending = /_desc$/.test(sortMode);
			var sortField = /^time_/.test(sortMode) ? 'last_seen' : 'total';
			sorted.sort(function(a, b) {
				var av = Number(a[sortField] || 0);
				var bv = Number(b[sortField] || 0);
				if (av === bv)
					return String(a.name || '').localeCompare(String(b.name || ''));
				return descending ? bv - av : av - bv;
			});
			var pageCount = Math.max(1, Math.ceil(sorted.length / pageSize));
			page = Math.max(1, Math.min(Number(page) || 1, pageCount));
			var rows = sorted.slice((page - 1) * pageSize, page * pageSize).map(function(app) {
				var lastSeen = Number(app.last_seen || 0);
				return E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td', 'style': 'min-width:150px;word-break:normal' }, [
						E('strong', {}, safeText(app.name)),
						E('div', { 'style': 'color:#777;font-size:90%' }, safeText(app.category || '未知'))
					]),
					E('div', { 'class': 'td' }, trafficPair(app.fiveg_upload, app.fiveg_download)),
					E('div', { 'class': 'td' }, trafficPair(app.other_upload, app.other_download)),
					E('div', { 'class': 'td' }, trafficPair(app.unknown_upload, app.unknown_download)),
					E('div', { 'class': 'td' }, bytes(app.total)),
					E('div', { 'class': 'td', 'style': 'white-space:nowrap' },
						lastSeen ? new Date(lastSeen * 1000).toLocaleString() : '-'),
					E('div', { 'class': 'td' }, app.id > 0 && device.mac &&
						(!app.profile_id || app.profile_id === currentProfileId) ? E('button', {
						'class': 'btn cbi-button-negative',
						'click': function() { confirmAlwaysBlock(device, app); }
					}, '阻断') : (app.id > 0 && app.profile_id ? '历史规则库' : '-'))
				]);
			});
			if (!rows.length)
				rows.push(E('div', { 'class': 'tr' }, E('div', { 'class': 'td' }, '所选时间段没有流量。')));

			var sortSelect = E('select', {
				'class': 'cbi-input-select',
				'change': function(ev) { renderAuditPage(1, ev.target.value); }
			}, [
				[ 'traffic_desc', '流量：从大到小' ], [ 'traffic_asc', '流量：从小到大' ],
				[ 'time_desc', '时间：最近优先' ], [ 'time_asc', '时间：最早优先' ]
			].map(function(option) {
				return E('option', { 'value': option[0], 'selected': sortMode === option[0] ? '' : null }, option[1]);
			}));
			var pagination = E('div', {
				'style': 'display:flex;align-items:center;justify-content:flex-end;gap:.6em;margin-top:.75em'
			}, [
				E('button', {
					'class': 'btn', 'disabled': page <= 1 ? '' : null,
					'click': function() { renderAuditPage(page - 1, sortMode); }
				}, '上一页'),
				E('span', {}, '第 %d / %d 页，共 %d 个应用'.format(page, pageCount, sorted.length)),
				E('button', {
					'class': 'btn', 'disabled': page >= pageCount ? '' : null,
					'click': function() { renderAuditPage(page + 1, sortMode); }
				}, '下一页')
			]);

			destroyCharts(document.querySelector('#modal_overlay > .modal'));
			ui.showModal('应用流量审计 - %h'.format(device.name || device.ip || device.id), [
				E('div', { 'style': 'max-height:calc(100vh - 190px);overflow-y:auto;overflow-x:hidden;padding-right:.5em' }, [
					E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;margin-bottom:1em' }, [
						[ 86400, '24 小时' ], [ 604800, '7 天' ], [ 2592000, '30 天' ]
					].map(function(period) {
						return E('button', {
							'class': 'btn %s'.format(seconds === period[0] ? 'cbi-button-action' : ''),
							'click': function() { return showDeviceAudit(device, period[0]); }
						}, period[1]);
					})),
					E('div', { 'class': 'c2000max-audit-pies' }, [
						E('div', {}, [ E('h4', {}, '应用分类占比'),
							renderPie(categories, '这个时间段没有可展示的应用分类。') ]),
						E('div', {}, [ E('h4', {}, '出口流量类型'), renderPie([
							{ name: '5G', value: fiveg },
							{ name: '其他/宽带', value: other },
							{ name: '未分类出口', value: unknown }
						], '这个时间段没有出口流量。') ])
					]),
					E('div', { 'style': 'display:flex;align-items:center;justify-content:space-between;gap:1em;flex-wrap:wrap;margin-top:1.25em' }, [
						E('h4', { 'style': 'margin:0' }, '应用明细'),
						E('label', {}, [ '排序：', sortSelect ])
					]),
					E('div', { 'style': 'overflow-x:auto;max-width:100%;margin-top:.5em' }, E('div', {
						'class': 'table cbi-section-table', 'style': 'min-width:1080px'
					}, [
						E('div', { 'class': 'tr table-titles' }, [
							E('div', { 'class': 'th' }, '应用'), E('div', { 'class': 'th' }, '5G（上传 / 下载）'),
							E('div', { 'class': 'th' }, '其他（上传 / 下载）'), E('div', { 'class': 'th' }, '未分类'),
							E('div', { 'class': 'th' }, '总计'), E('div', { 'class': 'th' }, '最后活动'),
							E('div', { 'class': 'th' }, '操作')
						])
					].concat(rows))),
					pagination
				]),
				E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': function() {
					auditModalSequence++;
					destroyCharts(document.querySelector('#modal_overlay > .modal'));
					ui.hideModal();
				} }, '关闭'))
			], 'c2000max-audit-modal');
		}

		renderAuditPage(1, 'time_desc');
	});
}

function renderOverview(status) {
	var totals = status.totals || {};
	var updated = Number(status.updated || 0);
	var totalUpload = Number(totals.fiveg_upload || 0) + Number(totals.other_upload || 0) + Number(totals.unknown_upload || 0);
	var totalDownload = Number(totals.fiveg_download || 0) + Number(totals.other_download || 0) + Number(totals.unknown_download || 0);

	return [
		E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '实时运行状态'),
			E('div', { 'class': 'table' }, [
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '统计服务'),
					E('div', { 'class': 'td left' }, status.active ? '运行中' : '未运行'),
					E('div', { 'class': 'td left' }, '加速模式'),
					E('div', { 'class': 'td left' }, safeText(accelerationName(status.acceleration)))
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '统计来源'),
					E('div', { 'class': 'td left' }, safeText(sourceName(status.counter_source))),
					E('div', { 'class': 'td left' }, '最后采样'),
					E('div', { 'class': 'td left' }, updated ? new Date(updated * 1000).toLocaleString() : '等待首次采样')
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '特征库'),
					E('div', { 'class': 'td left' }, safeText('%s / %s 个应用 / %s 条内核特征'.format(
						status.feature_version || '未知', Number(status.feature_apps || 0),
						Number(status.audit_loaded_features || 0)))),
					E('div', { 'class': 'td left' }, '加速暂缓'),
					E('div', { 'class': 'td left' }, status.audit_holds_acceleration ?
						('未知连接最多检查 %d 个有效载荷包'.format(Number(status.audit_packets || 0))) : '不暂缓')
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '生效阻断规则'),
					E('div', { 'class': 'td left' }, String(Number(status.policy_rules || 0))),
					E('div', { 'class': 'td left' }, '管控方式'),
					E('div', { 'class': 'td left' }, controlModeName(status.control_mode))
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '趋势样本'),
					E('div', { 'class': 'td left' }, String(Number(status.history_samples || 0))),
					E('div', { 'class': 'td left' }, '日志占用'),
					E('div', { 'class': 'td left' }, '%s / %s'.format(bytes(status.storage_used), bytes(status.storage_limit)))
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '应用审计'),
					E('div', { 'class': 'td left' }, !status.audit_enabled ? '已关闭' :
						(status.audit_active ? '运行中' : '引擎未运行')),
					E('div', { 'class': 'td left' }, '识别策略'),
					E('div', { 'class': 'td left' }, auditModeName(status.audit_mode))
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
		])
	];
}

function deviceRows(status, auditOnly) {
	var devices = asArray(status.devices);
	var rows = devices.map(function(device) {
		var title = device.name || device.ip || device.mac || device.id || '未知设备';
		var detail = [];
		if (device.ip && device.ip !== title) detail.push(device.ip);
		if (device.mac && device.mac !== title) detail.push(device.mac);
		var cells = [
			E('div', { 'class': 'td' }, [ E('strong', {}, safeText(title)), detail.length ?
				E('div', { 'style': 'color:#777;font-size:90%' }, safeText(detail.join(' · '))) : '' ])
		];
		if (!auditOnly) {
			cells.push(E('div', { 'class': 'td' }, trafficPair(device.fiveg_upload, device.fiveg_download)));
			cells.push(E('div', { 'class': 'td' }, trafficPair(device.other_upload, device.other_download)));
			cells.push(E('div', { 'class': 'td' }, trafficPair(device.unknown_upload, device.unknown_download)));
		}
		cells.push(E('div', { 'class': 'td' }, E('button', {
			'class': 'btn cbi-button-action',
			'click': function() { return showDeviceAudit(device, 86400); }
		}, '查看应用')));
		return E('div', { 'class': 'tr' }, cells);
	});
	if (!rows.length)
		rows.push(E('div', { 'class': 'tr' }, E('div', { 'class': 'td' }, '尚无设备流量。')));
	return rows;
}

function renderDevices(status) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, '各设备流量'),
		E('div', { 'class': 'table cbi-section-table' }, [
			E('div', { 'class': 'tr table-titles' }, [
				E('div', { 'class': 'th' }, '设备'), E('div', { 'class': 'th' }, '5G（上传 / 下载）'),
				E('div', { 'class': 'th' }, '其他/宽带（上传 / 下载）'), E('div', { 'class': 'th' }, '未分类（上传 / 下载）'),
				E('div', { 'class': 'th' }, '应用审计')
			])
		].concat(deviceRows(status, false)))
	]);
}

function renderAuditSummary(status) {
	return [
		E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '应用识别状态'),
			E('div', { 'class': 'table' }, [
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '审计引擎'),
					E('div', { 'class': 'td left' }, !status.audit_enabled ? '已关闭（流量记为未审计）' :
						(status.audit_active ? '运行中' : '已启用，引擎未运行')),
					E('div', { 'class': 'td left' }, '识别策略'),
					E('div', { 'class': 'td left' }, auditModeName(status.audit_mode))
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '当前连接'),
					E('div', { 'class': 'td left' }, '%d 已识别 / %d 未识别'.format(
						Number(status.audit_identified_connections || 0), Number(status.audit_unknown_connections || 0))),
					E('div', { 'class': 'td left' }, '可见 secmark'),
					E('div', { 'class': 'td left' }, String(Number(status.audit_secmark_connections || 0)))
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '加载特征'),
					E('div', { 'class': 'td left' }, String(Number(status.audit_loaded_features || 0))),
					E('div', { 'class': 'td left' }, '加速暂缓'),
					E('div', { 'class': 'td left' }, status.audit_holds_acceleration ?
						('未知连接最多检查 %d 个有效载荷包'.format(Number(status.audit_packets || 0))) : '不暂缓')
				])
			])
		].concat(status.audit_error ? [ E('div', { 'class': 'alert-message warning' },
			safeText('应用审计错误：%s'.format(status.audit_error))) ] : [])),
		E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '按设备查看应用'),
			E('p', {}, '点击设备后可切换 24 小时、7 天或 30 天，并对应用明细分页、排序。'),
			E('div', { 'class': 'table cbi-section-table' }, [
				E('div', { 'class': 'tr table-titles' }, [
					E('div', { 'class': 'th' }, '设备'), E('div', { 'class': 'th' }, '操作')
				])
			].concat(deviceRows(status, true)))
		])
	];
}

function renderRealtimeAudit(initialData) {
	var page = 0;
	var pageSize = 50;
	var sequence = 0;
	var timer = null;
	var loading = false;
	var loaded = false;
	var body = E('div', {}, E('div', { 'class': 'alert-message notice' },
		'切换到“实时应用”标签后再读取最近记录，不占用首屏加载时间。'));
	var pageStatus = E('span');
	var updateStatus = E('span', { 'style': 'color:#777' });
	var previous = E('button', { 'class': 'btn', 'type': 'button', 'disabled': '' }, '上一页');
	var next = E('button', { 'class': 'btn', 'type': 'button', 'disabled': '' }, '下一页');
	var interval = E('select', { 'class': 'cbi-input-select', 'disabled': '' }, [
		E('option', { 'value': '3' }, '每 3 秒'),
		E('option', { 'value': '5', 'selected': '' }, '每 5 秒'),
		E('option', { 'value': '10' }, '每 10 秒'),
		E('option', { 'value': '30' }, '每 30 秒')
	]);
	var live = E('input', { 'type': 'checkbox' });
	var refresh = E('button', { 'class': 'btn cbi-button-action', 'type': 'button' }, '立即刷新');

	function renderResult(result, requestPage) {
		var items = asArray(result.items);
		var total = Math.min(150, Math.max(0, Number(result.total || 0)));
		var pageCount = Math.max(1, Math.ceil(total / pageSize));
		var rows;

		page = Math.max(0, Math.min(requestPage, pageCount - 1));
		rows = items.map(function(item) {
			var timestamp = Number(item.timestamp || item.last_seen || 0);
			var device = item.device_name || item.device || item.device_ip || item.device_id || '未知设备';
			var detail = [];
			if (item.device_ip && item.device_ip !== device) detail.push(item.device_ip);
			if (item.device_id && item.device_id !== device && item.device_id !== item.device_ip) detail.push(item.device_id);
			return E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td' }, [
					E('strong', {}, safeText(item.name || '应用 #%s'.format(Number(item.id || 0)))),
					E('div', { 'style': 'color:#777;font-size:90%' }, safeText('%s · APPID %s'.format(
						item.category || '未分类', Number(item.id || 0))))
				]),
				E('div', { 'class': 'td', 'style': 'white-space:nowrap' },
					timestamp ? new Date(timestamp * 1000).toLocaleString() : '未知时间'),
				E('div', { 'class': 'td' }, [
					E('strong', {}, safeText(device)),
					detail.length ? E('div', { 'style': 'color:#777;font-size:90%' }, safeText(detail.join(' · '))) : ''
				])
			]);
		});
		if (!rows.length)
			rows.push(E('div', { 'class': 'tr' }, E('div', { 'class': 'td' },
				'尚无已识别的应用记录；未知连接不会出现在这里。')));
		L.dom.content(body, E('div', { 'style': 'overflow-x:auto;max-width:100%' }, E('div', {
			'class': 'table cbi-section-table', 'style': 'min-width:720px'
		}, [
			E('div', { 'class': 'tr table-titles' }, [
				E('div', { 'class': 'th' }, '应用'),
				E('div', { 'class': 'th', 'style': 'width:15em' }, '时间'),
				E('div', { 'class': 'th' }, '设备')
			])
		].concat(rows))));
		previous.disabled = page <= 0;
		next.disabled = !result.has_more || page >= pageCount - 1;
		L.dom.content(pageStatus, '第 %d / %d 页，共保留最近 %d 条'.format(page + 1, pageCount, total));
		var updated = Number(result.updated || 0);
		L.dom.content(updateStatus, updated ? '最新记录：%s'.format(new Date(updated * 1000).toLocaleString()) : '等待审计记录');
	}

	function loadPage(wantedPage) {
		if (loading)
			return Promise.resolve();
		loaded = true;
		loading = true;
		var requestSequence = ++sequence;
		previous.disabled = true;
		next.disabled = true;
		refresh.disabled = true;
		return L.resolveDefault(callRecentAudit(Math.max(0, wantedPage) * pageSize, pageSize), {
			success: false,
			message: '读取最近应用失败',
			items: [],
			total: 0
		}).then(function(result) {
			if (requestSequence !== sequence)
				return;
			if (result.success !== true)
				throw new Error(result.message || result.error || '读取最近应用失败');
			renderResult(result, wantedPage);
		}).catch(function(error) {
			if (requestSequence === sequence)
				L.dom.content(body, E('div', { 'class': 'alert-message warning' }, safeText(error.message)));
		}).finally(function() {
			if (requestSequence === sequence) {
				refresh.disabled = false;
				loading = false;
				if (live.checked)
					scheduleTimer();
			}
		});
	}

	function stopTimer() {
		if (timer !== null) {
			clearInterval(timer);
			timer = null;
		}
	}

	function realtimeTabActive() {
		var pane = panel.closest('[data-tab]');
		return !pane || pane.getAttribute('data-tab-active') === 'true';
	}

	function scheduleTimer() {
		stopTimer();
		if (!live.checked)
			return;
		timer = setTimeout(function() {
			timer = null;
			if (!document.body.contains(panel)) {
				stopTimer();
				return;
			}
			if (realtimeTabActive())
				loadPage(page);
			else
				scheduleTimer();
		}, Number(interval.value || 5) * 1000);
	}

	previous.addEventListener('click', function(ev) { ev.preventDefault(); loadPage(page - 1); });
	next.addEventListener('click', function(ev) { ev.preventDefault(); loadPage(page + 1); });
	refresh.addEventListener('click', function(ev) { ev.preventDefault(); loadPage(page); });
	live.addEventListener('change', function() {
		interval.disabled = !live.checked;
		if (live.checked) {
			page = 0;
			loadPage(0);
		}
		else {
			stopTimer();
		}
	});
	interval.addEventListener('change', scheduleTimer);

	var panel = E('div', { 'class': 'cbi-section' }, [
		E('div', { 'style': 'display:flex;align-items:center;justify-content:space-between;gap:1em;flex-wrap:wrap' }, [
			E('div', {}, [
				E('h3', { 'style': 'margin-bottom:.25em' }, '最近识别的应用'),
				E('div', {}, '按时间从新到旧显示最近 150 条；未知连接已过滤。')
			]),
			E('div', { 'style': 'display:flex;align-items:center;gap:.6em;flex-wrap:wrap' }, [
				E('label', { 'style': 'display:flex;align-items:center;gap:.35em' }, [ live, '实时刷新' ]),
				interval,
				refresh
			])
		]),
		E('div', { 'style': 'margin:.6em 0' }, updateStatus),
		body,
		E('div', { 'style': 'display:flex;justify-content:flex-end;align-items:center;gap:.6em;margin-top:.75em;flex-wrap:wrap' }, [
			previous, pageStatus, next
		])
	]);

	if (initialData && initialData.success === true) {
		loaded = true;
		renderResult(initialData, 0);
	}
	setTimeout(function() {
		var pane = panel.closest('[data-tab]');
		if (pane)
			pane.addEventListener('cbi-tab-active', function() {
				if (!loaded) {
					page = 0;
					loadPage(0);
				}
				else if (live.checked) {
					page = 0;
					loadPage(0);
				}
			});
	}, 0);
	return panel;
}

return view.extend({
	load: function() {
		/* Keep first paint independent from audit history and from a feature
		 * import holding the profile lock.  Catalog metadata calls are started in
		 * parallel after the small UCI load and each has the same hard deadline. */
		var statusRequest = L.resolveDefault(callTrafficStatus(), {});
		/* The form renderer depends on a populated UCI state, so do not substitute
		 * an empty fallback here.  This RPC only reads the small local config; the
		 * expensive status/catalog work below is what needs a deadline. */
		return uci.load('c2000max_traffic').then(function() {
			var active = String(uci.get('c2000max_traffic', 'audit', 'ruleset') || '');
			/* This is a tiny atomic status file, not the long-running importer.
			 * Query the current job on every page entry so a background import stays
			 * visible even after navigation, reload or an earlier XHR disconnect. */
			var featureJobRequest = L.resolveDefault(callFeatureInstallStatus(''), {
				state: 'idle', _loadFailed: true
			});
			var featureRequest = L.resolveDefault(callFeatureList(), {
				profiles: [], _loadFailed: true
			});
			/* The manager commits ACTIVE_PTR before its potentially long kernel
			 * reload and updates UCI audit.ruleset only after that reload succeeds.
			 * Resolve an empty request on the backend so catalog, rule identity and
			 * the immutable active pointer all refer to the same generation. */
			var catalogRequest = L.resolveDefault(callCatalogInfo(''), {
				profile: active, categories: [], total_apps: 0, _loadFailed: true
			});
			/* catalog_info creates the small on-device catalog cache when needed.
			 * Chain lookup after it so a cold page does not launch two competing
			 * builders for the same 3000+ application profile. */
			var lookupRequest = catalogRequest.then(function(info) {
				if (!info || info._loadFailed || info.success === false)
					return { profile: active, items: [], _loadFailed: true };
				var lookupProfile = String(info.profile || info.profile_id || '');
				var wanted = {};
				if (!lookupProfile)
					return { profile: active, items: [], _loadFailed: true };
				uci.sections('c2000max_traffic', 'schedule', function(section) {
					/* Legacy sections without an explicit binding still belong to the
					 * UCI ruleset visible at page-load time. During activation that can
					 * intentionally lag ACTIVE_PTR, so never relabel them as the new
					 * catalog merely to populate its lookup cache. */
					var ruleset = String(section.ruleset || active);
					if (ruleset !== lookupProfile)
						return;
					L.toArray(section.apps).forEach(function(id) {
						if (/^[0-9]+$/.test(String(id))) wanted[String(id)] = true;
					});
				});
				return L.resolveDefault(callCatalogLookup(lookupProfile, Object.keys(wanted).join(',')), {
					profile: lookupProfile, items: [], _loadFailed: true
				});
			});
			var deferredFeature = { profiles: [], _deferred: true };
			var deferredCatalog = { profile: active, categories: [], total_apps: 0, _deferred: true };
			var deferredLookup = { profile: active, items: [], _deferred: true };
			var deferredStatus = { _deferred: true };
			return Promise.all([
				resolveWithin(statusRequest, deferredStatus, 1800),
				resolveWithin(featureRequest, deferredFeature, 1800),
				resolveWithin(catalogRequest, deferredCatalog, 1800),
				resolveWithin(lookupRequest, deferredLookup, 1800),
				resolveWithin(featureJobRequest, { state: 'idle', _deferred: true }, 800)
			]).then(function(base) {
				var statusDeferred = base[0] === deferredStatus;
				var status = statusDeferred ? {} : (base[0] || {});
				var features = base[1] || {};
				active = String(status.feature_profile || features.active || features.active_id || active);
				currentProfileId = active;
				return {
					status: status,
					features: features,
					catalog: base[2] || {},
					lookup: base[3] || {},
					featureJob: base[4] || { state: 'idle' },
					featureJobRequest: featureJobRequest,
					recentAudit: null,
					statusRequest: statusRequest,
					managementDeferred: !!(statusDeferred || base[1]._deferred ||
						base[2]._deferred || base[3]._deferred),
					managementRequest: Promise.all([ featureRequest, catalogRequest, lookupRequest ])
				};
			});
		});
	},
	render: function(data) {
		var status = data.status || {};
		var featureData = data.features || {};
		var catalog = data.catalog || {};
		var lookup = data.lookup || {};
		var recentAudit = data.recentAudit || {};
		var initialFeatureJob = data.featureJob || { state: 'idle' };
		var devices = asArray(status.devices);
		var categories = asArray(catalog.categories);
		var selectedLabels = {};
		asArray(lookup.items || lookup.apps).forEach(function(app) {
			selectedLabels[String(app.id)] = appChoiceLabel(app);
		});
		/* Every management control must use the same profile that produced its
		 * categories and APPID labels. Status can observe a switch at another
		 * point in the manager transaction and must never override this identity. */
		var catalogProfile = catalog._deferred || catalog._loadFailed ? '' :
			String(catalog.profile || catalog.profile_id || '');
		currentProfileId = String(catalogProfile || featureData.active ||
			featureData.active_id || status.feature_profile || currentProfileId);

		var inactiveSchedules = 0;
		uci.sections('c2000max_traffic', 'schedule', function(section) {
			var ruleset = String(section.ruleset || currentProfileId);
			if (ruleset !== currentProfileId) inactiveSchedules++;
		});

		var m = new form.Map('c2000max_traffic', null, null);
		m.tabbed = true;
		var s = m.section(form.NamedSection, 'config', 'traffic', '统计与存储');
		s.anonymous = true;
		var o = s.option(form.Flag, 'enabled', '启用流量统计'); o.default = o.enabled; o.rmempty = false;
		o = s.option(form.Value, 'sample_interval', '采样间隔（秒）'); o.datatype = 'and(uinteger,min(5),max(300))'; o.default = '10'; o.rmempty = false;
		o = s.option(form.Value, 'flush_interval', '持久化间隔（秒）', '写入闪存的间隔，建议不小于 3600 秒。'); o.datatype = 'and(uinteger,min(300),max(86400))'; o.default = '3600'; o.rmempty = false;
		o = s.option(form.Value, 'storage_limit_mb', '日志数据上限（MB）', '默认最多保留 100 MB 的趋势和应用明细；超过后自动删除最早记录。'); o.datatype = 'and(uinteger,min(1),max(2048))'; o.default = '100'; o.rmempty = false;

		s = m.section(form.NamedSection, 'audit', 'audit', '审计与规则库',
			'默认关闭。无感模式不会为了识别阻止 HNAT/PPE 或软件 Flow Offload，未识别连接直接记为“未知/其他”；均衡和精确模式会暂缓未知连接加速以提高识别率。');
		s.anonymous = true;
		o = s.option(form.Flag, 'enabled', '启用应用审计'); o.default = o.disabled; o.rmempty = false;
		o = s.option(form.ListValue, 'recognition_mode', '识别策略');
		o.value('balanced', '均衡（推荐；最多检查 8 个有效载荷包后恢复硬件加速）');
		o.value('precise', '精确（未知连接最多检查 64 个有效载荷包）');
		o.value('seamless', '无感（立即加速，识别率较低）');
		o.default = 'balanced'; o.rmempty = false;
		o.description = '均衡模式只暂缓尚未识别的新连接，最多检查 8 个有效载荷包后即恢复 HNAT/PPE；不会全局关闭硬件加速。无感模式可能在首个应用载荷到达前就被硬件接管，从而漏识别。';
		o = s.option(form.ListValue, 'control_mode', '管控生效方式');
		o.value('seamless', '无感管控（推荐）');
		o.value('force', '强力管控（立即中断现有连接）');
		o.default = 'seamless'; o.rmempty = false;
		o.description = '无感管控只让新连接立即受规则约束，已有 HNAT/Flowtable 连接自然结束后生效；强力管控会清空加速连接使规则立即生效，保存时可能出现短暂卡顿。';
		o = s.option(form.Value, 'retention_days', '明细保留天数'); o.datatype = 'and(uinteger,min(1),max(90))'; o.default = '30'; o.rmempty = false;
		o = s.option(form.DummyValue, '_feature_profiles', '已上传的规则库',
			'同一时刻只激活一个经过校验的 OAF v3/v4 Profile；不同库的 APPID、历史和管控规则互相隔离。');
		o.rawhtml = true;
		o.cfgvalue = function() { return renderFeatureManager(featureData, catalog); };
		o = s.option(form.Button, '_upload_feature', '上传新规则库',
			'支持 OpenAppFilter 官方 ZIP/.bin、IKprotocol-*-oaf.bin，以及 IKprotocol extracted.tar.gz 原始规则包。原始 .lib 需先解包为 extracted 版；爱快规则不会被打包到固件或自动下载。');
		o.inputstyle = 'action'; o.inputtitle = '选择文件并更新';
		o.onclick = function(ev) {
			var progress = null;
			var uploadCompleted = false;
			var releaseOnError = false;
			var startResponseReceived = false;
			if (rejectConcurrentFeatureJob())
				return Promise.resolve();
			/* Cover the file-transfer interval too: cgi-io always writes one fixed
			 * upload path, so a second picker must not race before the job starts. */
			featureInstallInProgress = true;
			updateFeatureJobBanner({
				state: 'upload', phase: 'upload',
				message: '正在把特征库上传到路由器；上传完成后会自动转入后台校验和编译。'
			});
			return ui.uploadFile('/tmp/c2000max-feature-upload', ev.target).then(function() {
				/* Keep the current, internally-consistent management generation on
				 * screen until the background transaction reaches a terminal state. */
				uploadCompleted = true;
				return callFeatureInstall();
			}).then(function(result) {
				startResponseReceived = true;
				var state = String((result || {}).state || '');
				var asyncAccepted = result && result.accepted !== false &&
					(state === 'queued' || state === 'running');
				releaseOnError = featureJobStartCanRelease(result);
				if (asyncAccepted) {
					progress = E('p', {}, safeText(result.message || '上传完成，正在后台安装特征库…'));
					ui.addNotification(null, progress);
				}
				return resolveFeatureJobStart(result, progress, '特征库安装失败');
			}).then(function(result) {
				featureInstallInProgress = false;
				ui.addNotification(null, E('p', {}, safeText('特征库已更新到 %s，共 %d 个应用。'.format(
					result.version, Number(result.apps || 0)))));
				location.reload();
			}).catch(function(error) {
				/* If polling itself became unreachable, the detached worker may still
				 * be switching generations. Keep mismatch reloads suppressed until the
				 * user follows the error advice and re-enters/reloads this page. */
				if (!uploadCompleted || releaseOnError)
					featureInstallInProgress = false;
				if (!uploadCompleted || releaseOnError)
					updateFeatureJobBanner({ state: 'failed', phase: 'failed', message: error.message });
				ui.addNotification(null, E('p', {}, safeText(uploadCompleted && !startResponseReceived ?
					'无法确认安装任务是否已提交；请稍后重新进入页面查看状态。' : error.message)));
			});
		};

		s = m.section(form.GridSection, 'schedule', '管控规则',
			'多条规则可重叠，任一命中即阻断。每条规则只属于创建它的特征库；当前仅显示活动库的规则%s。开始与结束相同表示全天，结束早于开始表示跨午夜。'.format(
				inactiveSchedules ? '，另有 %d 条其他库规则已隐藏且不生效'.format(inactiveSchedules) : ''));
		s.anonymous = true; s.addremove = true; s.sortable = true; s.nodescriptions = true;
		s.filter = function(sectionId) {
			return String(uci.get('c2000max_traffic', sectionId, 'ruleset') || currentProfileId) === currentProfileId;
		};
		o = s.option(form.Flag, 'enabled', '启用'); o.default = o.enabled; o.rmempty = false;
		o = s.option(form.Value, 'name', '规则名称'); o.placeholder = '例如：上课时间禁用游戏'; o.rmempty = false;
		var rulesetOption = o = s.option(form.Value, 'ruleset', '所属规则库'); o.default = currentProfileId; o.rmempty = false; o.readonly = true; o.modalonly = true;
		o = s.option(form.MultiValue, 'days', '星期');
		[ [ '1', '周一' ], [ '2', '周二' ], [ '3', '周三' ], [ '4', '周四' ], [ '5', '周五' ], [ '6', '周六' ], [ '0', '周日' ] ].forEach(function(day) { o.value(day[0], day[1]); });
		o.default = [ '0', '1', '2', '3', '4', '5', '6' ]; o.rmempty = false;
		o = s.option(form.Value, 'start', '开始时间'); o.default = '00:00'; o.placeholder = 'HH:MM'; o.rmempty = false; o.modalonly = true;
		o.validate = function(sectionId, value) { return /^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/.test(value) ? true : '请输入 HH:MM（00:00–23:59）'; };
		o = s.option(form.Value, 'end', '结束时间'); o.default = '00:00'; o.placeholder = 'HH:MM'; o.rmempty = false; o.modalonly = true;
		o.validate = function(sectionId, value) { return /^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/.test(value) ? true : '请输入 HH:MM（00:00–23:59）'; };
		o = s.option(form.ListValue, 'target', '作用设备');
		o.value('all', '全部设备（可设白名单）'); o.value('selected', '仅指定设备'); o.default = 'all'; o.rmempty = false; o.modalonly = true;
		var deviceOption = o = s.option(form.DynamicList, 'devices', '指定设备'); o.depends('target', 'selected'); o.modalonly = true;
			devices.forEach(function(device) { if (device.mac) o.value(device.mac, safeChoice('%s（%s）'.format(device.name || device.ip || device.mac, device.mac))); });
			var whitelistOption = o = s.option(form.DynamicList, 'whitelist', '设备白名单'); o.depends('target', 'all'); o.modalonly = true;
			devices.forEach(function(device) { if (device.mac) o.value(device.mac, safeChoice('%s（%s）'.format(device.name || device.ip || device.mac, device.mac))); });
			var categoryOption = o = s.option(form.MultiValue, 'categories', '应用分类', '勾选后阻断该分类下的全部应用；分类来自当前特征库。'); o.modalonly = true;
			categories.forEach(function(category) { o.value(String(category.id), safeChoice(category.name)); });
		var appOption = o = s.option(LazyAppSelector, 'apps', '指定应用', '打开搜索器后才按 50 条/页查询，不会一次加载整个软件库。可与整个分类同时选择，生成规则时自动去重。');
		o.modalonly = true; o.rmempty = true; o.profile = currentProfileId; o.categories = categories; o.labelCache = selectedLabels;

		var modalStyle = E('style', {}, [
			'.modal.c2000max-audit-modal{width:calc(100vw - 3rem);max-width:1280px!important;}',
			'.modal.c2000max-app-picker-modal{width:calc(100vw - 3rem);max-width:1050px!important;}',
			'.c2000max-audit-pies{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1.25em;align-items:start;}',
			'.c2000max-tabs-wrap>.cbi-tabmenu{overflow-x:auto;white-space:nowrap;flex-wrap:nowrap;}',
			'@media(max-width:760px){.modal.c2000max-audit-modal,.modal.c2000max-app-picker-modal{width:calc(100vw - 1rem);margin:1em auto;}.c2000max-audit-pies{grid-template-columns:1fr;}}'
		].join(''));
		var latestStatus = status;
		var statusPollRequest = data.statusRequest || null;
		var profileConsistencyRequest = null;
		var pendingProfileId = '';
		if (statusPollRequest) {
			Promise.resolve(statusPollRequest).finally(function() {
				if (statusPollRequest === data.statusRequest)
					statusPollRequest = null;
			});
		}

		function statusHasData(nextStatus) {
			return nextStatus && typeof nextStatus === 'object' && Object.keys(nextStatus).length > 0;
		}

		function tabIsActive(name) {
			var pane = document.querySelector('#c2000-traffic-tabs > [data-tab="%s"]'.format(name));
			return pane && pane.getAttribute('data-tab-active') === 'true';
		}

		function verifyProfileGeneration() {
			if (featureInstallInProgress || profileConsistencyRequest || !pendingProfileId)
				return;
			var wantedProfile = pendingProfileId;
			var request = L.resolveDefault(callCatalogInfo(''), {});
			profileConsistencyRequest = request;
			request.then(function(info) {
				var resolvedProfile = String((info || {}).profile || (info || {}).profile_id || '');
				/* Status and catalog calls can straddle the manager's atomic pointer
				 * commit. Reload only after both independently resolve the same new
				 * generation; otherwise the next status poll will verify again. */
				if (!featureInstallInProgress && pendingProfileId === wantedProfile &&
				    resolvedProfile === wantedProfile && wantedProfile !== currentProfileId &&
				    document.body.contains(page))
					location.reload();
			}).finally(function() {
				if (profileConsistencyRequest === request)
					profileConsistencyRequest = null;
				if (!featureInstallInProgress && pendingProfileId && pendingProfileId !== wantedProfile)
					verifyProfileGeneration();
			});
		}

		function updateStatusPanels(nextStatus, forcedTab) {
			if (!statusHasData(nextStatus))
				return;
			if (nextStatus.feature_profile && currentProfileId && nextStatus.feature_profile !== currentProfileId) {
				pendingProfileId = String(nextStatus.feature_profile);
				verifyProfileGeneration();
				return;
			}
			pendingProfileId = '';
			latestStatus = nextStatus;

			if (forcedTab === 'traffic-overview' || (!forcedTab && tabIsActive('traffic-overview'))) {
				var overview = document.getElementById('c2000-traffic-overview-body');
				if (overview) {
					destroyCharts(overview);
					L.dom.content(overview, renderOverview(nextStatus));
				}
			}
			if (forcedTab === 'traffic-devices' || (!forcedTab && tabIsActive('traffic-devices'))) {
				var deviceBody = document.getElementById('c2000-traffic-devices-body');
				if (deviceBody)
					L.dom.content(deviceBody, renderDevices(nextStatus));
			}
			if (forcedTab === 'traffic-audit' || (!forcedTab && tabIsActive('traffic-audit'))) {
				var auditBody = document.getElementById('c2000-traffic-audit-body');
				if (auditBody)
					L.dom.content(auditBody, renderAuditSummary(nextStatus));
			}
		}

		poll.add(function() {
			/* Do not start another status process when the previous one is still
			 * blocked (for example while a profile is being installed). */
			if (statusPollRequest)
				return Promise.resolve();
			var request = L.resolveDefault(callTrafficStatus(), {});
			statusPollRequest = request;
			request.then(function(nextStatus) {
				updateStatusPanels(nextStatus);
			}).finally(function() {
				if (statusPollRequest === request)
					statusPollRequest = null;
			});
			return resolveWithin(request, null, 3000);
		}, 5);

		var formBody = E('div', {}, E('p', { 'class': 'spinning' }, '正在后台载入管控与设置…'));
		var tabGroup = E('div', { 'id': 'c2000-traffic-tabs' }, [
				E('div', { 'data-tab': 'traffic-overview', 'data-tab-title': '概览', 'data-tab-active': 'true' },
					E('div', { 'id': 'c2000-traffic-overview-body' }, renderOverview(status))),
				E('div', { 'data-tab': 'traffic-devices', 'data-tab-title': '设备流量' },
					E('div', { 'id': 'c2000-traffic-devices-body' }, renderDevices(status))),
				E('div', { 'data-tab': 'traffic-audit', 'data-tab-title': '应用审计' },
					E('div', { 'id': 'c2000-traffic-audit-body' }, renderAuditSummary(status))),
				E('div', { 'data-tab': 'traffic-realtime', 'data-tab-title': '实时应用' },
					renderRealtimeAudit(recentAudit)),
				E('div', { 'data-tab': 'traffic-manage', 'data-tab-title': '管控与设置' }, formBody)
		]);
		var jobBanner = E('div', {
			'id': 'c2000max-feature-job-banner',
			'style': 'display:none;margin:0 0 1em'
		});
		var page = E('div', { 'class': 'c2000max-tabs-wrap' }, [
			modalStyle,
			E('h2', {}, 'C2000MAX 流量统计'),
			E('p', {}, 'HNAT 使用硬件 MIB 同步，Flow Offloading 和普通转发使用 Conntrack。规则库切换只重建应用识别连接，不清空总流量和趋势。'),
			jobBanner,
			tabGroup
		]);
		featureJobBannerNode = jobBanner;
		updateFeatureJobBanner(initialFeatureJob);
		function recoverFeatureJob(status) {
			var state = String((status || {}).state || 'idle');
			updateFeatureJobBanner(status);
			if ((state !== 'queued' && state !== 'running') ||
			    featureJobRecoveryStarted || !(status || {}).job_id)
				return;
			featureJobRecoveryStarted = true;
			featureInstallInProgress = true;
			waitFeatureInstall(status.job_id, null, 0).then(function(result) {
				updateFeatureJobBanner({ state: 'done', phase: 'done',
					message: '特征库后台处理完成，正在载入新的规则库和分类…' });
				window.setTimeout(function() { location.reload(); }, 800);
			}).catch(function(error) {
				featureInstallInProgress = false;
				updateFeatureJobBanner({ state: 'failed', phase: 'failed', message: error.message });
			});
		}
		recoverFeatureJob(initialFeatureJob);
		Promise.resolve(data.featureJobRequest).then(recoverFeatureJob);
		ui.tabs.initTabGroup(tabGroup.children);
		var managementOpened = false;
		Array.prototype.forEach.call(tabGroup.children, function(pane) {
			pane.addEventListener('cbi-tab-active', function() {
				var tabName = pane.getAttribute('data-tab');
				updateStatusPanels(latestStatus, tabName);
				if (tabName === 'traffic-manage') {
					managementOpened = true;
					maybeRenderManagementForm();
				}
			});
		});

		var managementReady = !data.managementDeferred;
		var managementRenderStarted = false;
		var managementPane = tabGroup.querySelector('[data-tab="traffic-manage"]');
		if (managementPane && managementPane.getAttribute('data-tab-active') === 'true')
			managementOpened = true;
		function renderManagementForm() {
			m.render().then(function(formNode) {
				if (document.body.contains(formBody))
					L.dom.content(formBody, formNode);
			}).catch(function(error) {
				if (document.body.contains(formBody))
					L.dom.content(formBody, E('div', { 'class': 'alert-message warning' },
						safeText('管控与设置载入失败：%s'.format(error.message || error))));
			});
		}
		function maybeRenderManagementForm() {
			if (!managementOpened || !managementReady || managementRenderStarted)
				return;
			managementRenderStarted = true;
			setTimeout(renderManagementForm, 0);
		}

		/* form.Map rendering can be noticeable with many saved rules.  It is not
		 * needed for the overview, so let LuCI attach the page first and populate
		 * the management tab in a separate task.  If catalog calls missed the
		 * first-paint deadline, keep their original requests alive and hydrate the
		 * not-yet-rendered Map with the real choices when they finish. */
		if (!data.managementDeferred) {
			L.dom.content(formBody, E('div', { 'class': 'alert-message notice' },
				'切换到本标签后再渲染管控表单，不占用流量概览的首屏时间。'));
			maybeRenderManagementForm();
		}
		else {
			L.dom.content(formBody, E('div', { 'class': 'alert-message notice' }, [
				E('p', { 'class': 'spinning' }, '规则库元数据仍在后台载入；统计视图可以正常使用。'),
				E('p', {}, '载入完成后本页会自动更新一次，无需手动刷新。')
			]));
			Promise.all([
				resolveWithin(data.statusRequest, status, 5000),
				Promise.resolve(data.managementRequest)
			]).then(function(deferred) {
				var nextStatus = deferred[0] || status;
				var result = deferred[1];
				var failed = !result || result.some(function(item) {
					return !item || item._loadFailed || item.success === false;
				});
				if (failed) {
					L.dom.content(formBody, E('div', { 'class': 'alert-message warning' },
						'规则库元数据读取失败；统计页面不受影响，请稍后重新进入“管控与设置”。'));
					return;
				}

				status = nextStatus;
				featureData = result[0] || {};
				catalog = result[1] || {};
				lookup = result[2] || {};
				currentProfileId = String(catalog.profile || catalog.profile_id ||
					featureData.active || featureData.active_id || currentProfileId);
				rulesetOption.default = currentProfileId;
				devices = asArray(status.devices);
				categories = asArray(catalog.categories);
				selectedLabels = {};
				asArray(lookup.items || lookup.apps).forEach(function(app) {
					selectedLabels[String(app.id)] = appChoiceLabel(app);
				});
				devices.forEach(function(device) {
					if (!device.mac)
						return;
					var label = safeChoice('%s（%s）'.format(device.name || device.ip || device.mac, device.mac));
					deviceOption.value(device.mac, label);
					whitelistOption.value(device.mac, safeChoice('%s（%s）'.format(
						device.name || device.ip || device.mac, device.mac)));
				});
				categories.forEach(function(category) {
					categoryOption.value(String(category.id), safeChoice(category.name));
				});
				appOption.profile = currentProfileId;
				appOption.categories = categories;
				appOption.labelCache = selectedLabels;
				managementReady = true;
				maybeRenderManagementForm();
			});
		}

		/* If the bounded first-paint request completed after its deadline, use it
		 * to fill the visible tab instead of forcing the user to refresh. */
		Promise.resolve(data.statusRequest).then(function(nextStatus) {
			updateStatusPanels(nextStatus);
		});
		return page;
	}
});
