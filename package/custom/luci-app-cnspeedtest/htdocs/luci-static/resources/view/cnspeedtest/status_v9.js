'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require poll';

function serviceAction(action) {
	return fs.exec('/usr/libexec/cnspeedtest/service-control', [ action ]).then(function() {
		ui.addNotification(null, E('p', {}, _('服务操作已完成。')), 'info');
		window.setTimeout(function() { window.location.reload(); }, 1200);
	}).catch(function(error) {
		ui.addNotification(null, E('p', {}, error.message || String(error)), 'danger');
	});
}

function readLog(path) {
	return fs.read_direct(path || '/var/log/cnspeedtest.log').catch(function() { return ''; });
}

function readIdentity() {
	return fs.exec('/usr/libexec/cnspeedtest/identity', []).then(function(result) {
		var identity = { machine_id: '', imei: '', android_ua: '' };
		String((result && result.stdout) || '').split(/\n/).forEach(function(line) {
			var match = line.match(/^([A-Z_]+)='(.*)'$/);
			if (!match)
				return;
			if (match[1] === 'MACHINE_ID')
				identity.machine_id = match[2];
			else if (match[1] === 'IMEI')
				identity.imei = match[2];
			else if (match[1] === 'ANDROID_UA')
				identity.android_ua = match[2];
		});
		return identity;
	}).catch(function() {
		return { machine_id: '', imei: '', android_ua: '' };
	});
}

function parseStatus(result) {
	var status = { running: false, enabled: false, listening: false, pid: '', listen: '' };
	String((result && result.stdout) || '').split(/\n/).forEach(function(line) {
		var match = line.match(/^([a-z_]+)=(.*)$/);
		if (!match)
			return;
		if (match[1] === 'running' || match[1] === 'enabled' || match[1] === 'listening')
			status[match[1]] = match[2] === '1';
		else if (match[1] === 'pid' || match[1] === 'listen')
			status[match[1]] = match[2];
	});
	status.running = status.running && status.listening && !!status.pid;
	return status;
}

function row(label, value) {
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width:32%' }, label),
		E('div', { 'class': 'td left', 'style': 'overflow-wrap:anywhere;color:var(--text-color-high,inherit)' }, value)
	]);
}

function identityCode(value) {
	return E('code', {
		'style': 'display:inline-block;max-width:100%;overflow-wrap:anywhere;white-space:normal;' +
			'background:transparent;color:var(--text-color-high,inherit)'
	}, value);
}

return view.extend({
	load: function() {
		return Promise.all([ uci.load('cnspeedtest'), L.resolveDefault(uci.load('argon'), null) ]).then(function() {
			return Promise.all([
				fs.exec('/usr/libexec/cnspeedtest/service-control', [ 'status' ]).catch(function() {
					return { stdout: 'running=0\nenabled=0\nlistening=0\n' };
				}),
				readLog(uci.get('cnspeedtest', 'main', 'log_file')),
				readIdentity()
			]);
		});
	},

	render: async function(data) {
		var rawStatus = data[0];
		var service = parseStatus(rawStatus);
		var log = data[1] || '';
		var identity = data[2] || {};
		var listen = service.listen || uci.get('cnspeedtest', 'main', 'listen') || '0.0.0.0:8787';
		var port = listen.split(':').pop() || '8787';
		var argon = (uci.sections('argon', 'global') || [])[0] || {};
		var argonMode = [ 'light', 'dark' ].indexOf(argon.mode) !== -1 ? argon.mode : 'system';
		var systemDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
		var effectiveDark = argonMode === 'dark' || (argonMode === 'system' && systemDark);
		var themeVariables = effectiveDark
			? '--border-color-medium:#3c3c3c;--background-color-high:#1e1e1e;--text-color-high:#cccccc;color:#cccccc'
			: '--border-color-medium:#d9d9d9;--background-color-high:#f5f5f5;--text-color-high:#32325d;color:#32325d';
		var webHost = window.location.hostname;
		if (webHost.indexOf(':') !== -1 && webHost.charAt(0) !== '[')
			webHost = '[' + webHost + ']';
		var webURL = 'http://' + webHost + ':' + port +
			'/?theme=' + encodeURIComponent(argonMode);
		var stateLabel = service.running ? _('运行中') : (service.enabled ? _('已启用，但服务未运行') : _('已停止'));
		var stateColor = service.running ? '#2d9d53' : '#d34b4b';

		var map = new form.Map('cnspeedtest', _('测速配置'),
			_('管理路由器测速后端的启动参数、节点选择和日志位置。保存后会自动重启或停止服务。'));
		map.on_after_commit = function() {
			var enabled = uci.get('cnspeedtest', 'main', 'enabled') === '1';
			return fs.exec('/usr/libexec/cnspeedtest/service-control', [ enabled ? 'restart' : 'stop' ]);
		};
		var section = map.section(form.NamedSection, 'main', 'cnspeedtest', _('基础设置'));
		section.anonymous = true;

		var enabled = section.option(form.Flag, 'enabled', _('开机启用'));
		enabled.rmempty = false;
		var listenOption = section.option(form.Value, 'listen', _('监听地址'));
		listenOption.placeholder = '0.0.0.0:8787';
		var auto = section.option(form.Flag, 'auto', _('自动选择节点'));
		auto.rmempty = false;
		var host = section.option(form.Value, 'host', _('手动节点地址'));
		host.depends('auto', '0');
		var nodePort = section.option(form.Value, 'port', _('手动节点端口'));
		nodePort.datatype = 'port';
		nodePort.depends('auto', '0');
		var duration = section.option(form.Value, 'duration', _('测速时长'));
		duration.datatype = 'uinteger';
		duration.placeholder = '15';
		var bandwidth = section.option(form.Value, 'bandwidth', _('带宽参数'));
		bandwidth.datatype = 'uinteger';
		bandwidth.placeholder = '2000';
		var downloadThreads = section.option(form.Value, 'download_threads', _('下载线程数'));
		downloadThreads.datatype = 'uinteger';
		var uploadThreads = section.option(form.Value, 'upload_threads', _('上传线程数'));
		uploadThreads.datatype = 'uinteger';
		var probeCount = section.option(form.Value, 'probe_count', _('候选节点数'));
		probeCount.datatype = 'uinteger';
		var pingCount = section.option(form.Value, 'ping_count', _('Ping 次数'));
		pingCount.datatype = 'uinteger';
		var timeout = section.option(form.Value, 'connect_timeout', _('连接超时'));
		timeout.placeholder = '1s';
		var runDownload = section.option(form.Flag, 'download', _('下载测速'));
		runDownload.rmempty = false;
		var runUpload = section.option(form.Flag, 'upload', _('上传测速'));
		runUpload.rmempty = false;
		var noProbe = section.option(form.Flag, 'no_download_probe', _('跳过下载探测'));
		noProbe.rmempty = false;
		var forceDownload = section.option(form.Flag, 'force_download', _('探测失败仍下载'));
		forceDownload.rmempty = false;
		var insecure = section.option(form.Flag, 'insecure_discovery', _('兼容节点发现'));
		insecure.rmempty = false;
		var logFile = section.option(form.Value, 'log_file', _('日志文件'));
		logFile.placeholder = '/var/log/cnspeedtest.log';

		function actionButton(label, style, action) {
			return E('button', {
				'class': 'btn cbi-button ' + style,
				'type': 'button',
				'click': ui.createHandlerFn(this, function() { return serviceAction(action); })
			}, label);
		}
		var openButton = E('button', {
			'class': 'btn cbi-button cbi-button-positive',
			'type': 'button',
			'disabled': service.running ? null : 'disabled',
			'click': function() { window.open(webURL, '_blank', 'noopener'); }
		}, _('打开测速页面'));

		var statusSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('运行状态')),
			E('div', { 'class': 'table' }, [
				row(_('服务状态'), E('strong', { 'style': 'color:' + stateColor }, stateLabel)),
				row(_('进程 / 端口'), service.running ? _('PID %s，端口正在监听').format(service.pid) : (service.pid ? _('PID %s 存在，但端口未监听').format(service.pid) : _('未发现测速进程'))),
				row(_('监听地址'), listen),
				row(_('测速页面'), E('a', { 'href': webURL, 'target': '_blank', 'rel': 'noopener' }, webURL))
			]),
			E('div', { 'style': 'display:flex;gap:.6rem;flex-wrap:wrap;margin-top:1rem' }, [
				actionButton.call(this, _('启动服务'), 'cbi-button-positive', 'start'),
				actionButton.call(this, _('停止服务'), 'cbi-button-negative', 'stop'),
				actionButton.call(this, _('重启服务'), 'cbi-button-action', 'restart'),
				openButton
			])
		]);

		var identitySection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('设备身份')),
			E('div', { 'class': 'table' }, [
				row(_('机器 ID'), identityCode(identity.machine_id || _('未获取'))),
				row(_('IMEI / TS'), identityCode(identity.imei || _('未获取'))),
				row(_('Android UA'), identityCode(identity.android_ua || _('未获取')))
			])
		]);

		var logPath = uci.get('cnspeedtest', 'main', 'log_file') || '/var/log/cnspeedtest.log';
		var logSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('运行日志')),
			E('div', { 'class': 'cbi-section-descr' }, logPath),
			E('pre', {
				'id': 'cnspeedtest-log',
				'style': 'min-height:220px;max-height:520px;overflow:auto;white-space:pre-wrap;' +
					'padding:1rem;border:1px solid var(--border-color-medium,#d9d9d9);border-radius:.5rem;' +
					'background:var(--background-color-high,#f5f5f5);color:var(--text-color-high,inherit)'
			}, log || _('暂无日志。'))
		]);

		poll.add(function() {
			return readLog(logPath).then(function(text) {
				var element = document.getElementById('cnspeedtest-log');
				if (element)
					element.textContent = text || _('暂无日志。');
			});
		}, 5);

		var mapNode = await map.render();
		return E('div', {
			'class': 'cbi-map cnspeedtest-native-' + (effectiveDark ? 'dark' : 'light'),
			'style': themeVariables
		}, [
			E('h2', {}, _('CNSpeedTest 外网测速')),
			E('div', { 'class': 'cbi-map-descr' }, _('直接使用 Argon / LuCI 原生组件，页面颜色、间距、按钮和亮暗模式均跟随当前主题。')),
			E('div', { 'class': 'alert-message notice' },
				_('这里测试的是路由器到外网的速度；结果可能受分流、QoS、代理、硬件加速及其他配置影响。')),
			statusSection,
			identitySection,
			mapNode,
			logSection
		]);
	}
});
