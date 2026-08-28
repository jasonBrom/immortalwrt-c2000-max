'use strict';
'require view';
'require rpc';
'require ui';
'require dom';

const callStatus = rpc.declare({
	object: 'c2000max',
	method: 'ip_family_status',
	expect: { '': {} }
});

const callApply = rpc.declare({
	object: 'c2000max',
	method: 'ip_family_apply',
	params: [ 'preference', 'dns_service', 'ipv4_dns', 'ipv6_dns', 'stun_ipv4', 'stun_ipv6' ],
	expect: { '': {} }
});

const callStun = rpc.declare({
	object: 'c2000max',
	method: 'stun_test',
	params: [ 'family', 'server' ],
	expect: { '': {} }
});

const STUN_SERVERS = [
	[ 'stun.miwifi.com:3478', 'MIWiFi（中国大陆，IPv4）' ],
	[ 'stun.hot-chilli.net:3478', 'Hot-Chilli（IPv4 / IPv6）' ],
	[ 'stun.voipbuster.com:3478', 'VoIPBuster（IPv4）' ],
	[ 'stun.telnyx.com:3478', 'Telnyx（IPv4）' ],
	[ 'stun.cloudflare.com:3478', 'Cloudflare（IPv4 / IPv6）' ],
	[ 'global.stun.twilio.com:3478', 'Twilio Global（IPv4）' ],
	[ 'stun.l.google.com:19302', 'Google（IPv4）' ]
];

const RFC3489_NAMES = {
	open_internet: '开放互联网（未经过 NAT）',
	symmetric_udp_firewall: '对称型 UDP 防火墙',
	full_cone_nat: '完全锥形 NAT（Full Cone）',
	symmetric_nat: '对称型 NAT（Symmetric NAT）',
	restricted_cone_nat: '受限锥形 NAT（Restricted Cone）',
	port_restricted_cone_nat: '端口受限锥形 NAT（Port Restricted Cone）',
	unavailable: '服务器不支持完整 RFC 3489 检测'
};

const RFC5780_NAMES = {
	endpoint_independent: '端点无关（Endpoint-Independent）',
	address_dependent: '地址相关（Address-Dependent）',
	address_port_dependent: '地址和端口相关（Address-and-Port-Dependent）',
	unavailable: '服务器不支持完整行为发现'
};

function flag(value) {
	return value === true || value === 1 || value === '1';
}

function list(value) {
	return Array.isArray(value) ? value : [];
}

function statusText(ok, yes, no) {
	return E('span', {
		'class': ok ? 'label success' : 'label warning',
		'style': 'display:inline-block;min-width:5.5em;text-align:center'
	}, ok ? yes : no);
}

function row(name, value) {
	return E('tr', {}, [
		E('td', { 'class': 'td left', 'width': '34%' }, name),
		E('td', { 'class': 'td left' }, value || '—')
	]);
}

function renderFamilyStatus(family, data) {
	const isV6 = family === 'ipv6';
	const upstream = list(data.upstream_dns);
	let dnsDescription;

	if (flag(data.dns_available) && isV6 && !upstream.length)
		dnsDescription = E('span', {}, [
			statusText(true, 'AAAA 正常', ''),
			' 通过现有 IPv4 上游 DNS 完成解析，这是正常的双栈 DNS 方式。'
		]);
	else
		dnsDescription = statusText(flag(data.dns_available),
			isV6 ? 'AAAA 正常' : 'A 记录正常', '解析失败');

	return E('table', { 'class': 'table' }, [
		row('公网连通', statusText(flag(data.internet_available), '可用', '不可用')),
		row('DNS 解析', dnsDescription),
		row('出口地址', data.address || '未获得'),
		row('出口接口', data.device || '未找到'),
		row('默认路由', data.default_route || '未配置'),
		row('同地址族上游 DNS', upstream.length ? upstream.join('、') :
			(isV6 ? '未下发（不等于 IPv6 DNS 不可用）' : '未下发'))
	]);
}

function serverIsPreset(server) {
	return STUN_SERVERS.some((entry) => entry[0] === server);
}

function makeServerSelect(family, server) {
	const custom = !serverIsPreset(server);
	return E('div', {}, [
		E('select', {
			'id': 'c2000max-stun-' + family,
			'class': 'cbi-input-select',
			'change': function() { updateCustomServer(family); }
		}, STUN_SERVERS.map((entry) => E('option', {
			'value': entry[0],
			'selected': !custom && entry[0] === server ? '' : null
		}, entry[1])).concat([
			E('option', { 'value': '__custom__', 'selected': custom ? '' : null }, '自定义服务器')
		])),
		E('input', {
			'id': 'c2000max-stun-custom-' + family,
			'class': 'cbi-input-text',
			'placeholder': '例如 stun.example.com:3478',
			'value': custom ? server : '',
			'style': 'margin-top:.5em;display:' + (custom ? 'block' : 'none')
		})
	]);
}

function updateCustomServer(family) {
	const select = document.getElementById('c2000max-stun-' + family);
	const input = document.getElementById('c2000max-stun-custom-' + family);
	if (select && input)
		input.style.display = select.value === '__custom__' ? 'block' : 'none';
}

function selectedServer(family) {
	const select = document.getElementById('c2000max-stun-' + family);
	const custom = document.getElementById('c2000max-stun-custom-' + family);
	if (!select)
		return '';
	return select.value === '__custom__' ? (custom ? custom.value.trim() : '') : select.value;
}

function stunErrorMessage(result, family) {
	const errors = {
		dns_no_ipv4_address: '所选服务器没有可用的 IPv4 地址。',
		dns_no_ipv6_address: '所选服务器没有可用的 IPv6 地址，请改用 Hot-Chilli、Cloudflare 或自定义双栈服务器。',
		invalid_server: 'STUN 服务器地址格式无效。',
		timeout: 'STUN 请求超时，可能是服务器不可用、UDP 被拦截或当前地址族没有公网路由。',
		socket_failed: '无法创建 ' + family.toUpperCase() + ' UDP 套接字。',
		bind_failed: '无法绑定本地 UDP 端口。'
	};
	return result.message || errors[result.error] || result.detail || 'STUN 检测失败。';
}

function renderStunResult(result, family) {
	if (!result || !flag(result.success))
		return E('div', { 'class': 'alert-message warning' }, stunErrorMessage(result || {}, family));

	const classic = result.rfc3489 || {};
	const behavior = result.rfc5780 || {};
	const serverRow = row('STUN 节点', '%s（%s ms）'.format(result.server_address || result.server,
		result.rtt_ms == null ? '—' : result.rtt_ms));

	if (family === 'ipv6') {
		const ipv6Rows = [
			row('STUN 反射端点', result.public_endpoint),
			row('本地端点', result.local_endpoint),
			serverRow,
			row('地址转换', flag(result.nat_present) ?
				statusText(false, '', '检测到 IPv6 地址转换') :
				statusText(true, '未检测到（原生 IPv6）', ''))
		];

		if (flag(behavior.available)) {
			if (flag(result.nat_present))
				ipv6Rows.push(row('IPv6 映射行为', RFC5780_NAMES[behavior.mapping] || behavior.mapping));
			ipv6Rows.push(
				row('UDP 防火墙过滤', RFC5780_NAMES[behavior.filtering] || behavior.filtering),
				row('行为发现备用节点', behavior.other_address || '—')
			);
		}
		else {
			ipv6Rows.push(row('UDP 防火墙过滤', E('span', {}, [
				statusText(false, '', '未检测'),
				' 当前服务器未提供 OTHER-ADDRESS / RESPONSE-ORIGIN；本次仅完成基础 STUN 连通性与反射端点检测。'
			])));
		}

		return E('table', { 'class': 'table', 'style': 'margin-top:1em' }, ipv6Rows);
	}

	const behaviorRows = flag(behavior.available) ? [
		row('RFC 5780 映射行为', RFC5780_NAMES[behavior.mapping] || behavior.mapping),
		row('RFC 5780 过滤行为', RFC5780_NAMES[behavior.filtering] || behavior.filtering),
		row('行为发现备用节点', behavior.other_address || '—')
	] : [
		row('RFC 5780', E('span', {}, [
			statusText(false, '', '不完整'),
			' 当前服务器未提供 OTHER-ADDRESS / RESPONSE-ORIGIN，基础 STUN 结果仍然有效。'
		]))
	];

	return E('table', { 'class': 'table', 'style': 'margin-top:1em' }, [
		row('公网映射端点', result.public_endpoint),
		row('本地端点', result.local_endpoint),
		serverRow,
		row('是否存在 NAT', flag(result.nat_present) ? '是' : '否'),
		row('传统 NAT 类型（RFC 3489）', flag(classic.available) ?
			(RFC3489_NAMES[classic.type] || classic.type) : RFC3489_NAMES.unavailable)
	].concat(behaviorRows));
}

function switchTab(tabName) {
	document.querySelectorAll('.c2000-family-tab').forEach((button) => {
		const active = button.getAttribute('data-tab') === tabName;
		button.classList.toggle('active', active);
		button.setAttribute('aria-selected', active ? 'true' : 'false');
	});
	document.querySelectorAll('.c2000-family-pane').forEach((pane) => {
		const active = pane.getAttribute('data-tab') === tabName;
		pane.hidden = !active;
		pane.style.display = active ? 'block' : 'none';
	});
}

function tabButton(name, label, active) {
	return E('button', {
		'type': 'button',
		'class': 'c2000-family-tab' + (active ? ' active' : ''),
		'data-tab': name,
		'role': 'tab',
		'aria-selected': active ? 'true' : 'false',
		'click': function(ev) {
			ev.preventDefault();
			switchTab(name);
		}
	}, label);
}

function dnsText(value) {
	return list(value).join('\n');
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	testStun: async function(family) {
		const server = selectedServer(family);
		const button = document.getElementById('c2000max-stun-test-' + family);
		const resultNode = document.getElementById('c2000max-stun-result-' + family);
		if (!server) {
			ui.addNotification(null, E('p', {}, '请输入自定义 STUN 服务器地址。'), 'error');
			return;
		}
		if (button) {
			button.disabled = true;
			button.textContent = '检测中…';
		}
		if (resultNode)
			dom.content(resultNode, E('em', {}, family === 'ipv6' ?
				'正在检测 IPv6 STUN 连通性与 UDP 防火墙行为…' :
				'正在执行 Binding、映射与过滤行为测试…'));
		const result = await L.resolveDefault(callStun(family, server), {
			success: false,
			message: 'RPC 调用失败。'
		});
		if (resultNode)
			dom.content(resultNode, renderStunResult(result, family));
		if (button) {
			button.disabled = false;
			button.textContent = family === 'ipv6' ? '单独检测 IPv6' : '单独检测 IPv4';
		}
	},

	refreshStatus: async function() {
		const button = document.getElementById('c2000max-family-refresh');
		if (button) button.disabled = true;
		const status = await L.resolveDefault(callStatus(), {});
		for (const family of [ 'ipv4', 'ipv6' ]) {
			const node = document.getElementById('c2000max-family-status-' + family);
			if (node) dom.content(node, renderFamilyStatus(family, status[family] || {}));
		}
		if (button) button.disabled = false;
	},

	apply: async function() {
		const preference = document.getElementById('c2000max-family-preference');
		const dnsService = document.getElementById('c2000max-family-dns-service');
		const ipv4Dns = document.getElementById('c2000max-family-dns-ipv4');
		const ipv6Dns = document.getElementById('c2000max-family-dns-ipv6');
		const stun4 = selectedServer('ipv4');
		const stun6 = selectedServer('ipv6');
		const button = document.getElementById('c2000max-family-apply');

		if (!stun4 || !stun6) {
			ui.addNotification(null, E('p', {}, 'IPv4 和 IPv6 的 STUN 服务器都不能为空。'), 'error');
			return;
		}
		if (button) button.disabled = true;
		const result = await L.resolveDefault(callApply(
			preference ? preference.value : 'auto',
			dnsService ? dnsService.checked : true,
			ipv4Dns ? ipv4Dns.value : '',
			ipv6Dns ? ipv6Dns.value : '',
			stun4,
			stun6
		), {});
		ui.addNotification(null, E('p', {}, result.message ||
			(flag(result.success) ? '设置已应用。' : '保存设置失败。')),
			flag(result.success) ? 'info' : 'error');
		if (button) button.disabled = false;
		if (flag(result.success)) await this.refreshStatus();
	},

	render: function(status) {
		status = status || {};
		const page = E('div', { 'class': 'cbi-map' }, [
			E('style', {}, [
				'.c2000-family-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:1em}',
				'.c2000-family-grid>.cbi-section{margin:0;min-width:0}',
				'.c2000-family-actions{display:flex;gap:.6em;flex-wrap:wrap;margin-top:1em}',
				'.c2000-family-tabbar{display:flex;gap:.25em;margin-top:1em;border-bottom:1px solid rgba(127,127,127,.28);overflow-x:auto}',
				'.c2000-family-tab{appearance:none;background:transparent;border:0;border-bottom:3px solid transparent;color:inherit;cursor:pointer;font:inherit;padding:.8em 1.15em;white-space:nowrap}',
				'.c2000-family-tab:hover{background:rgba(127,127,127,.10)}',
				'.c2000-family-tab.active{border-bottom-color:var(--primary-color,#1677ff);color:var(--primary-color,#1677ff);font-weight:600}',
				'.c2000-family-pane{padding-top:1em}',
				'@media(max-width:600px){.c2000-family-grid{grid-template-columns:1fr}.c2000-family-tab{padding:.7em .85em}}'
			].join('')),
			E('h2', {}, 'IPv4 / IPv6 配置与网络检测'),
			E('div', { 'class': 'cbi-map-descr' },
				'IPv4 与 IPv6 完全独立检测。DNS 能否解析 AAAA 记录和上游 DNS 自身使用 IPv4/IPv6 传输是两回事；' +
				'只要 AAAA 查询与 IPv6 公网连通正常，就不会再误报“DNS 服务器未接入 IPv6”。'),
			E('div', { 'class': 'c2000-family-tabbar', 'role': 'tablist' }, [
				tabButton('status', '双栈状态', true),
				tabButton('settings', '地址族与 DNS', false),
				tabButton('ipv4', 'IPv4 检测', false),
				tabButton('ipv6', 'IPv6 检测', false)
			]),
			E('div', { 'class': 'c2000-family-pane', 'data-tab': 'status', 'role': 'tabpanel' }, [
			E('div', { 'class': 'c2000-family-actions', 'style': 'margin-top:0' }, [
				E('button', {
					'id': 'c2000max-family-refresh',
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, 'refreshStatus')
				}, '刷新双栈状态')
			]),
			E('div', { 'class': 'c2000-family-grid', 'style': 'margin-top:1em' }, [
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, 'IPv4 状态'),
					E('div', { 'id': 'c2000max-family-status-ipv4' },
						renderFamilyStatus('ipv4', status.ipv4 || {}))
				]),
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, 'IPv6 状态'),
					E('div', { 'id': 'c2000max-family-status-ipv6' },
						renderFamilyStatus('ipv6', status.ipv6 || {}))
				])
			])
			]),
			E('div', {
				'class': 'c2000-family-pane',
				'data-tab': 'settings',
				'role': 'tabpanel',
				'hidden': '',
				'style': 'display:none'
			}, [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '地址族与 DNS 设置'),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'c2000max-family-preference' }, '地址族优先'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('select', { 'id': 'c2000max-family-preference', 'class': 'cbi-input-select' }, [
							[ 'auto', '自动（按系统 RFC 6724）' ],
							[ 'ipv6', 'IPv6 优先' ],
							[ 'ipv4', 'IPv4 优先' ]
						].map((entry) => E('option', {
							'value': entry[0],
							'selected': status.preference === entry[0] ? '' : null
						}, entry[1]))),
						E('div', { 'class': 'cbi-value-description' },
							'用于本页诊断及支持该配置的路由器组件。LAN 终端仍由各自系统的 Happy Eyeballs 决定，' +
							'路由器不会通过过滤 A/AAAA 记录来伪装“优先”，因此不会破坏双栈回退。')
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'c2000max-family-dns-service' }, '通告 IPv6 DNS'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'id': 'c2000max-family-dns-service',
							'type': 'checkbox',
							'checked': flag(status.dns_service) ? '' : null
						}),
						E('div', { 'class': 'cbi-value-description' },
							'通过 RA 向 LAN 终端通告路由器的 IPv6 DNS 代理。默认开启；即使运营商只下发 IPv4 DNS，' +
							'路由器仍可正常查询 AAAA 记录。')
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'c2000max-family-dns-ipv4' }, '补充 IPv4 DNS'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('textarea', {
							'id': 'c2000max-family-dns-ipv4',
							'class': 'cbi-input-textarea',
							'rows': '3',
							'placeholder': '例如 223.5.5.5，每行一个'
						}, [ dnsText(status.ipv4_dns) ]),
						E('div', { 'class': 'cbi-value-description' }, '留空继续使用运营商自动下发的 DNS；最多补充 6 个。')
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'c2000max-family-dns-ipv6' }, '补充 IPv6 DNS'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('textarea', {
							'id': 'c2000max-family-dns-ipv6',
							'class': 'cbi-input-textarea',
							'rows': '3',
							'placeholder': '例如 2400:3200::1，每行一个'
						}, [ dnsText(status.ipv6_dns) ]),
						E('div', { 'class': 'cbi-value-description' },
							'用于运营商未下发 IPv6 DNS 时补充直连节点；这不是 IPv6/AAAA 正常工作的必要条件。')
					])
				])
			])
			]),
			E('div', {
				'class': 'c2000-family-pane',
				'data-tab': 'ipv4',
				'role': 'tabpanel',
				'hidden': '',
				'style': 'display:none'
			}, [
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, 'IPv4 NAT 行为检测'),
					E('div', { 'class': 'cbi-section-descr' },
						'显示传统 RFC 3489 NAT 类型以兼容常见测速结果，并使用 RFC 5780 分别检测映射和过滤行为。'),
					makeServerSelect('ipv4', status.stun_ipv4 || 'stun.miwifi.com:3478'),
					E('div', { 'class': 'c2000-family-actions' }, [
						E('button', {
							'id': 'c2000max-stun-test-ipv4',
							'class': 'btn cbi-button cbi-button-action',
							'click': ui.createHandlerFn(this, 'testStun', 'ipv4')
						}, '单独检测 IPv4')
					]),
					E('div', { 'id': 'c2000max-stun-result-ipv4' })
				])
			]),
			E('div', {
				'class': 'c2000-family-pane',
				'data-tab': 'ipv6',
				'role': 'tabpanel',
				'hidden': '',
				'style': 'display:none'
			}, [
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, 'IPv6 连通性与 UDP 防火墙检测'),
					E('div', { 'class': 'cbi-section-descr' },
						'基础 STUN 用于确认 IPv6 反射端点和是否发生地址转换；服务器支持行为发现时，再检测 UDP 状态防火墙的过滤行为。IPv6 不显示 RFC 3489 锥形 NAT 类型。'),
					makeServerSelect('ipv6', status.stun_ipv6 || 'stun.hot-chilli.net:3478'),
					E('div', { 'class': 'c2000-family-actions' }, [
						E('button', {
							'id': 'c2000max-stun-test-ipv6',
							'class': 'btn cbi-button cbi-button-action',
							'click': ui.createHandlerFn(this, 'testStun', 'ipv6')
						}, '单独检测 IPv6')
					]),
					E('div', { 'id': 'c2000max-stun-result-ipv6' })
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'id': 'c2000max-family-apply',
					'class': 'btn cbi-button cbi-button-apply important',
					'click': ui.createHandlerFn(this, 'apply')
				}, '保存并应用')
			])
		]);

		window.setTimeout(function() {
			updateCustomServer('ipv4');
			updateCustomServer('ipv6');
			switchTab('status');
		}, 0);
		return page;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
