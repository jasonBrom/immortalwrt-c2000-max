'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require dom';

const callStatus = rpc.declare({
	object: 'c2000max',
	method: 'swap_status',
	expect: { '': {} }
});

const callApply = rpc.declare({
	object: 'c2000max',
	method: 'swap_apply',
	params: [ 'enabled', 'size_mb', 'comp_algo', 'priority', 'swappiness' ],
	expect: { '': {} }
});

function flag(value) {
	return value === true || value === 1;
}

function integer(value, fallback) {
	const parsed = Number(value);
	return Number.isInteger(parsed) ? parsed : fallback;
}

function mib(kib) {
	return '%.1f MB'.format(integer(kib, 0) / 1024);
}

function bytesMib(bytes) {
	return '%.1f MB'.format(integer(bytes, 0) / 1048576);
}

function renderStatus(data) {
	const original = integer(data.original_bytes, 0);
	const compressed = integer(data.compressed_bytes, 0);
	const total = integer(data.total_kib, 0);
	const used = integer(data.used_kib, 0);
	const free = Math.max(total - used, 0);
	const ratio = compressed > 0 ? '%.2f : 1'.format(original / compressed) : '暂无数据';
	const state = flag(data.active) ?
		'运行中（%s）'.format(data.device || '/dev/zram0') :
		(flag(data.enabled) ? '已配置，当前未运行' : '已关闭');

	return E('table', { 'class': 'table' }, [
		E('tr', {}, [
			E('td', { 'class': 'td left', 'width': '34%' }, '状态'),
			E('td', { 'class': 'td left' }, state)
		]),
		E('tr', {}, [
			E('td', { 'class': 'td left' }, '交换空间'),
			E('td', { 'class': 'td left' },
				flag(data.active) ? '已用 %s / 空闲 %s / 总计 %s'.format(
					mib(used), mib(free), mib(total)) : '%s MB'.format(data.size_mb || 0))
		]),
		E('tr', {}, [
			E('td', { 'class': 'td left' }, '内存换出倾向'),
			E('td', { 'class': 'td left' }, '%s（配置值 %s）'.format(
				integer(data.current_swappiness, 150), integer(data.swappiness, 150)))
		]),
		E('tr', {}, [
			E('td', { 'class': 'td left' }, '压缩算法'),
			E('td', { 'class': 'td left' }, data.current_algo || data.comp_algo || 'lzo')
		]),
		E('tr', {}, [
			E('td', { 'class': 'td left' }, '压缩前 / 实际占用'),
			E('td', { 'class': 'td left' }, '%s / %s'.format(
				bytesMib(data.original_bytes), bytesMib(data.memory_bytes)))
		]),
		E('tr', {}, [
			E('td', { 'class': 'td left' }, '数据压缩比'),
			E('td', { 'class': 'td left' }, ratio)
		])
	]);
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	updateEnabled: function() {
		const enabled = document.getElementById('c2000max-swap-enabled');
		for (const id of [
			'c2000max-swap-size',
			'c2000max-swap-algo',
			'c2000max-swap-priority',
			'c2000max-swap-swappiness'
		]) {
			const node = document.getElementById(id);
			if (node)
				node.disabled = !(enabled && enabled.checked) || this.submitting;
		}
	},

	apply: async function() {
		const enabled = document.getElementById('c2000max-swap-enabled');
		const size = document.getElementById('c2000max-swap-size');
		const algo = document.getElementById('c2000max-swap-algo');
		const priority = document.getElementById('c2000max-swap-priority');
		const swappiness = document.getElementById('c2000max-swap-swappiness');
		const button = document.getElementById('c2000max-swap-apply');
		const sizeValue = size ? Number(size.value) : NaN;
		const priorityValue = priority ? Number(priority.value) : NaN;
		const swappinessValue = swappiness ? Number(swappiness.value) : NaN;

		if (!Number.isInteger(sizeValue) || sizeValue < 64 || sizeValue > 1024) {
			ui.addNotification(null, E('p', {}, 'SWAP 大小必须是 64–1024 MB 的整数。'), 'error');
			return;
		}
		if (!Number.isInteger(priorityValue) || priorityValue < 1 || priorityValue > 32767) {
			ui.addNotification(null, E('p', {}, '优先级必须是 1–32767 的整数。'), 'error');
			return;
		}
		if (!Number.isInteger(swappinessValue) ||
		    swappinessValue < 0 || swappinessValue > 200) {
			ui.addNotification(null, E('p', {}, '换出倾向必须是 0–200 的整数。'), 'error');
			return;
		}
		if (!enabled.checked && !window.confirm(
			'关闭 SWAP 需要把已交换的数据移回内存。内存不足时系统会拒绝关闭，确认继续吗？'))
			return;

		this.submitting = true;
		if (button)
			button.disabled = true;
		this.updateEnabled();
		const result = await L.resolveDefault(callApply(
			enabled.checked,
			sizeValue,
			algo.value,
			priorityValue,
			swappinessValue
		), {});
		ui.addNotification(null,
			E('p', {}, result.message || (result.success ? 'SWAP 设置已应用' : 'SWAP 设置失败')),
			result.success ? 'info' : 'error');
		this.submitting = false;
		if (button)
			button.disabled = false;
		this.updateEnabled();
		await this.refresh();
	},

	refresh: async function() {
		const data = await L.resolveDefault(callStatus(), {});
		const node = document.getElementById('c2000max-swap-status');
		if (node)
			dom.content(node, renderStatus(data));
		return data;
	},

	render: function(status) {
		const enabled = flag(status.enabled);
		const algorithmNames = {
			'lzo': 'LZO（兼容性最好）',
			'lzo-rle': 'LZO-RLE',
			'lz4': 'LZ4',
			'zstd': 'Zstandard'
		};
		const algorithms = Array.isArray(status.supported_algorithms) &&
			status.supported_algorithms.length ? status.supported_algorithms : [ 'lzo' ];
		const form = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'SWAP / ZRAM'),
			E('div', { 'class': 'cbi-map-descr' },
				'C2000MAX 使用内存压缩 ZRAM 作为 SWAP，不会持续写入 SD 卡或 eMMC。' +
				'空间只在实际换出时占用压缩后的物理内存；512 MB 设备建议设置 256–512 MB。' +
				'“空闲 100%”表示当前内存压力不高，并不是 SWAP 故障。'),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '实时状态'),
				E('div', { 'id': 'c2000max-swap-status' }, renderStatus(status || {}))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '设置'),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'c2000max-swap-enabled' }, '启用 ZRAM SWAP'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'id': 'c2000max-swap-enabled',
							'type': 'checkbox',
							'checked': enabled ? '' : null,
							'change': this.updateEnabled.bind(this)
						})
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'c2000max-swap-size' }, 'SWAP 大小（MB）'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'id': 'c2000max-swap-size',
							'class': 'cbi-input-text',
							'type': 'number',
							'min': '64',
							'max': '1024',
							'step': '64',
							'value': integer(status.size_mb, 256)
						}),
						E('div', { 'class': 'cbi-value-description' }, '允许 64–1024 MB，推荐 256 或 512 MB。')
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'c2000max-swap-algo' }, '压缩算法'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('select', { 'id': 'c2000max-swap-algo', 'class': 'cbi-input-select' },
							algorithms.map((name) => E('option', {
								'value': name,
								'selected': status.comp_algo === name ? '' : null
							}, algorithmNames[name] || name)))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'c2000max-swap-priority' }, '优先级'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'id': 'c2000max-swap-priority',
							'class': 'cbi-input-text',
							'type': 'number',
							'min': '1',
							'max': '32767',
							'value': integer(status.priority, 100)
						})
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', {
						'class': 'cbi-value-title',
						'for': 'c2000max-swap-swappiness'
					}, '内存换出倾向'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'id': 'c2000max-swap-swappiness',
							'class': 'cbi-input-text',
							'type': 'number',
							'min': '0',
							'max': '200',
							'value': integer(status.swappiness, 150)
						}),
						E('div', { 'class': 'cbi-value-description' },
							'允许 0–200。本机默认 150，让 512 MB 内存压力出现时更早使用 ZRAM。' +
							'系统不会为了填满 SWAP 而主动换出仍在使用的内存。')
					])
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'id': 'c2000max-swap-apply',
					'class': 'btn cbi-button cbi-button-apply important',
					'click': ui.createHandlerFn(this, 'apply')
				}, '保存并应用')
			])
		]);

		poll.add(this.refresh.bind(this), 5);
		window.setTimeout(this.updateEnabled.bind(this), 0);
		return form;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
