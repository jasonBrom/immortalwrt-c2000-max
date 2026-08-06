'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

function parseKeyValue(result) {
	var state = {
		running: false,
		enabled: false,
		listening: false,
		pid: '',
		listen: ''
	};

	String((result && result.stdout) || '').split(/\n/).forEach(function(line) {
		var match = line.match(/^([a-z_]+)=(.*)$/);
		if (!match)
			return;
		if (match[1] === 'running' || match[1] === 'enabled' || match[1] === 'listening')
			state[match[1]] = match[2] === '1';
		else if (match[1] === 'pid' || match[1] === 'listen')
			state[match[1]] = match[2];
	});
	state.running = state.running && state.listening && !!state.pid;
	return state;
}

function parseDiscovery(result) {
	try {
		return JSON.parse(String((result && result.stdout) || '{}'));
	}
	catch (error) {
		return { modems: [], ports: [], selected_section: 'auto', selected_port: '', selected_model: '', supported: false };
	}
}

function serviceAction(action) {
	return fs.exec('/usr/libexec/mt5700-web/service-control', [ action ]).then(function() {
		ui.addNotification(null, E('p', {}, _('服务操作已完成。')), 'info');
		window.setTimeout(function() { window.location.reload(); }, 1500);
	}).catch(function(error) {
		ui.addNotification(null, E('p', {}, error.message || String(error)), 'danger');
	});
}

function webURL(listen) {
	var match = String(listen || '').match(/:(\d+)$/);
	var port = match ? match[1] : '9010';
	return window.location.protocol + '//' + window.location.hostname + ':' + port + '/5700/';
}

return view.extend({
	load: function() {
		return uci.load('mt5700-web').then(function() {
			var section = uci.get('mt5700-web', 'main', 'modem_section') || 'auto';
			var port = uci.get('mt5700-web', 'main', 'at_port') || 'auto';
			return Promise.all([
				fs.exec('/usr/libexec/mt5700-web/service-control', [ 'status' ]).catch(function() {
					return { stdout: 'running=0\nenabled=0\nlistening=0\npid=\n' };
				}),
				fs.exec('/usr/bin/mt5700-web-go', [ '-discover', '-modem-section', section, '-serial', port ]).catch(function() {
					return { stdout: '{}' };
				})
			]);
		});
	},

	render: async function(data) {
		var service = parseKeyValue(data[0]);
		var discovery = parseDiscovery(data[1]);
		var listen = service.listen || uci.get('mt5700-web', 'main', 'listen') || '0.0.0.0:9010';
		var url = webURL(listen);
		var stateLabel = service.running ? _('运行中') : (service.enabled ? _('已启用，但服务未运行') : _('已停止'));
		var model = discovery.selected_model || _('未识别');
		var selectedPort = discovery.selected_port || _('未发现');
		var modelColor = discovery.supported ? '#2d9d53' : '#d98600';

		var map = new form.Map('mt5700-web', _('MT5700 网页控制面板'),
			_('使用单个 Go 二进制托管网页、WebSocket 与 AT 转发。服务默认关闭，关闭时不占用常驻内存。'));
		map.on_after_commit = function() {
			var enabled = uci.get('mt5700-web', 'main', 'enabled') === '1';
			return fs.exec('/usr/libexec/mt5700-web/service-control', [ enabled ? 'restart' : 'stop' ]);
		};

		var section = map.section(form.NamedSection, 'main', 'service', _('服务设置'));
		section.anonymous = true;

		var enabled = section.option(form.Flag, 'enabled', _('启用服务'));
		enabled.rmempty = false;
		enabled.description = _('默认关闭；只有手动启用后才会启动 Go 服务。');

		var listenOption = section.option(form.Value, 'listen', _('网页监听地址'));
		listenOption.placeholder = '0.0.0.0:9010';
		listenOption.rmempty = false;

		var transport = section.option(form.ListValue, 'transport', _('AT 连接方式'));
		transport.value('serial', _('QModem / 串口'));
		transport.value('network', _('网络 AT'));
		transport.default = 'serial';

		var modemSection = section.option(form.ListValue, 'modem_section', _('QModem 模组'));
		modemSection.value('auto', _('自动选择第一个模组'));
		(discovery.modems || []).forEach(function(modem) {
			var title = '%s（%s，%s）'.format(modem.name || modem.section, modem.model || _('未知型号'), modem.at_port || _('无串口'));
			modemSection.value(modem.section, title);
		});
		modemSection.depends('transport', 'serial');

		var atPort = section.option(form.Value, 'at_port', _('AT 串口'));
		atPort.value('auto', _('跟随 QModem 自动选择'));
		(discovery.ports || []).forEach(function(port) { atPort.value(port, port); });
		atPort.placeholder = '/dev/ttyUSB2';
		atPort.depends('transport', 'serial');

		var baudrate = section.option(form.ListValue, 'baudrate', _('串口波特率'));
		[ '9600', '19200', '38400', '57600', '115200', '230400' ].forEach(function(rate) { baudrate.value(rate); });
		baudrate.default = '115200';
		baudrate.depends('transport', 'serial');

		var networkHost = section.option(form.Value, 'network_host', _('网络 AT 地址'));
		networkHost.placeholder = '192.168.8.1';
		networkHost.depends('transport', 'network');

		var networkPort = section.option(form.Value, 'network_port', _('网络 AT 端口'));
		networkPort.datatype = 'port';
		networkPort.placeholder = '20249';
		networkPort.depends('transport', 'network');

		var timeout = section.option(form.Value, 'command_timeout', _('AT 命令超时'));
		timeout.placeholder = '4s';
		timeout.description = _('普通查询建议 4s；弱信号或升级操作可适当增大。');

		var maxClients = section.option(form.Value, 'max_clients', _('最大网页客户端数'));
		maxClients.datatype = 'range(1,32)';
		maxClients.placeholder = '8';

		var openAttributes = {
			'class': 'btn cbi-button cbi-button-positive',
			'type': 'button',
			'click': function() { window.open(url, '_blank', 'noopener'); }
		};
		if (!service.running)
			openAttributes.disabled = 'disabled';

		function button(label, style, action) {
			return E('button', {
				'class': 'btn cbi-button ' + style,
				'type': 'button',
				'click': ui.createHandlerFn(this, function() { return serviceAction(action); })
			}, label);
		}

		var warning = E('div', { 'class': 'alert-message warning' }, [
			E('strong', {}, _('兼容性提醒：')),
			_('此控制面板及其 AT 命令集仅为 MT5700 系列设计。其他模组即使能打开页面，也可能显示错误数据或执行不兼容命令。')
		]);
		var status = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('运行状态')),
			E('div', { 'class': 'table' }, [
				E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left', 'style': 'width:33%' }, _('服务状态')), E('div', { 'class': 'td left' }, E('strong', { 'style': 'color:' + (service.running ? '#2d9d53' : '#d34b4b') }, stateLabel)) ]),
				E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left' }, _('进程 / 端口检查')), E('div', { 'class': 'td left' }, service.running ? _('PID %s，端口正在监听').format(service.pid) : (service.pid ? _('PID %s 存在，但端口未监听').format(service.pid) : _('未发现服务进程'))) ]),
				E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left' }, _('QModem 检测型号')), E('div', { 'class': 'td left' }, E('strong', { 'style': 'color:' + modelColor }, model)) ]),
				E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left' }, _('实际 AT 串口')), E('div', { 'class': 'td left' }, selectedPort) ]),
				E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left' }, _('控制面板地址')), E('div', { 'class': 'td left' }, url) ])
			]),
			E('div', { 'style': 'display:flex;gap:.6rem;flex-wrap:wrap;margin-top:1rem' }, [
				button.call(this, _('启动服务'), 'cbi-button-positive', 'start'),
				button.call(this, _('停止服务'), 'cbi-button-negative', 'stop'),
				button.call(this, _('重启服务'), 'cbi-button-action', 'restart'),
				E('button', openAttributes, _('打开 MT5700 面板'))
			])
		]);

		var mapNode = await map.render();
		return E('div', {}, [ warning, status, mapNode ]);
	}
});
