'use strict';
'require view';
'require rpc';
'require poll';
'require dom';
'require ui';

var callStatus = rpc.declare({
	object: 'c2000max',
	method: 'sim_status',
	expect: { '': {} }
});

var callSwitch = rpc.declare({
	object: 'c2000max',
	method: 'sim_switch',
	params: [ 'slot' ],
	expect: { '': {} }
});

var callForce = rpc.declare({
	object: 'c2000max',
	method: 'sim_force',
	params: [ 'slot' ],
	expect: { '': {} }
});

var slotNames = {
	external1: _('外置卡槽 1'),
	external2: _('外置卡槽 2'),
	internal: _('内置贴片卡'),
	unknown: _('未知')
};

var stateNames = {
	stable: _('已确认'),
	noncanonical: _('已识别（GPIO 将在下次切换时归一化）'),
	inactive: _('SIM 接口未激活（目标卡槽可能为空）'),
	inconsistent: _('模组状态不一致'),
	offline: _('模组离线'),
	unknown: _('无法确认')
};

function value(v, fallback) {
	return (v != null && String(v).length) ? v : (fallback || _('未知'));
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	renderStatus: function(data) {
		var current = data.current_slot || 'unknown';
		var table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'width': '33%' }, _('当前模组名称')), E('td', { 'class': 'td left' }, value(data.model)) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('当前 SIM 卡槽')), E('td', { 'class': 'td left' }, slotNames[current] || slotNames.unknown) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('槽位检测状态')), E('td', { 'class': 'td left' }, stateNames[data.route_state] || stateNames.unknown) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('ICCID')), E('td', { 'class': 'td left' }, value(data.iccid, _('未检测到 SIM 卡'))) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('运营商')), E('td', { 'class': 'td left' }, value(data.carrier)) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('SIM 状态')), E('td', { 'class': 'td left' }, value(data.cpin)) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('QModem / AT 串口')), E('td', { 'class': 'td left' }, '%s / %s'.format(value(data.qmodem_section), value(data.at_port))) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('硬件选择状态')), E('td', { 'class': 'td left' }, _('模组通道 %s，GPIO48=%s').format(value(data.module_channel, '-'), value(data.gpio_mux, '-'))) ])
		]);
		if (data.forced_slot) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, _('最近一次强制 GPIO 操作')),
				E('td', { 'class': 'td left' }, _('%s，GPIO48=%s（未执行模组 AT 切换）').format(slotNames[data.forced_slot] || data.forced_slot, value(data.forced_gpio, '-')))
			]));
		}

		var buttons = E('div', { 'class': 'cbi-page-actions', 'style': 'display:flex;gap:.5em;flex-wrap:wrap;justify-content:flex-start' });
		[ 'external1', 'external2', 'internal' ].forEach(L.bind(function(slot) {
			buttons.appendChild(E('button', {
				'class': 'btn cbi-button cbi-button-action' + (current === slot ? ' important' : ''),
				'disabled': current === slot ? '' : null,
				'click': ui.createHandlerFn(this, 'handleSwitch', slot)
			}, [ current === slot ? _('当前：') + slotNames[slot] : _('切换到') + slotNames[slot] ]));
		}, this));

		var forceButtons = E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;margin-top:.8em' });
		[ 'external1', 'external2' ].forEach(L.bind(function(slot) {
			forceButtons.appendChild(E('button', {
				'class': 'btn cbi-button cbi-button-negative',
				'type': 'button',
				'click': ui.createHandlerFn(this, 'handleForce', slot)
			}, _('强制 GPIO 切换到') + slotNames[slot]));
		}, this));
		var forceBox = E('div', { 'class': 'alert-message warning', 'style': 'margin-top:1em' }, [
			E('strong', {}, _('不受支持模组的强制切换：')),
			E('span', {}, _('只写入 CPE-Sel0 / GPIO48，不检测模组型号、不发送 SIM 切换 AT 命令，也不校验实际卡槽。GPIO 高电平路径还可能对应内置贴片卡；操作后若模组未重新识别 SIM，请手动复位模组。')),
			forceButtons
		]);

		return E([ table, buttons, forceBox ]);
	},

	updateStatus: function(data) {
		if (this.statusNode)
			dom.content(this.statusNode, this.renderStatus(data || {}));
	},

	handleSwitch: function(slot, ev) {
		ev.currentTarget.blur();
		/* Do not let the periodic status request issue AT commands while the
		 * switch sequence owns the modem port. */
		poll.stop();
		ui.showModal(_('正在切换 SIM 卡'), [
			E('p', { 'class': 'spinning' }, _('正在安全停用 SIM、切换模组通道/GPIO 并校验结果，请稍候……'))
		]);

		return callSwitch(slot).then(L.bind(function(result) {
			ui.hideModal();
			this.updateStatus(result);
			ui.addNotification(null, E('p', {}, result.success ? value(result.message, _('SIM 卡切换成功')) : value(result.message, _('SIM 卡切换失败'))),
				result.success ? 'info' : 'error');
			poll.start();
		}, this)).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('SIM 卡切换失败：%s').format(err.message || err)), 'error');
			poll.start();
		});
	},

	handleForce: function(slot, ev) {
		var self = this;
		ev.currentTarget.blur();
		ui.showModal(_('确认强制 GPIO 切换'), [
			E('p', {}, _('该操作会绕过模组型号与 AT 能力检查，直接改写 GPIO48。当前蜂窝连接可能立即中断，并且页面显示的卡槽无法通过不受支持模组自动校验。')),
			E('p', {}, _('目标：%s').format(slotNames[slot] || slot)),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn',
					'type': 'button',
					'click': ui.hideModal
				}, _('取消')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative important',
					'type': 'button',
					'click': function() { return self.executeForce(slot); }
				}, _('确认强制切换'))
			])
		]);
	},

	executeForce: function(slot) {
		poll.stop();
		ui.showModal(_('正在强制切换 GPIO'), [
			E('p', { 'class': 'spinning' }, _('正在直接写入 SIM 复用 GPIO，请稍候……'))
		]);
		return callForce(slot).then(L.bind(function(result) {
			ui.hideModal();
			this.updateStatus(result);
			ui.addNotification(null, E('p', {}, result.success ? value(result.message, _('GPIO 强制切换完成')) : value(result.message, _('GPIO 强制切换失败'))),
				result.success ? 'warning' : 'error');
			poll.start();
		}, this)).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('GPIO 强制切换失败：%s').format(err.message || err)), 'error');
			poll.start();
		});
	},

	render: function(data) {
		this.statusNode = E('div', { 'class': 'cbi-section' }, this.renderStatus(data || {}));
		poll.add(L.bind(function() {
			return L.resolveDefault(callStatus(), {}).then(L.bind(this.updateStatus, this));
		}, this));

		return E([ 
			E('h2', {}, _('SIM 卡切换')),
			E('div', { 'class': 'cbi-map-descr' },
					_('实际硬件拓扑：外置卡槽 2 使用模组通道 1；外置卡槽 1 与内置贴片卡共用模组通道 2，并由 GPIO48 选择。允许切换到空卡槽；此时卡槽选择仍会成功，但 SIM 状态会显示未激活。正常安全切换支持 MT5700M-CN、FM350-GL 与 RM520N-CN；下方另提供不检查型号的强制 GPIO 模式。')),
			this.statusNode
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
