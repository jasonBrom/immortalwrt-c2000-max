'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require poll';

function serviceAction(action) {
	return fs.exec('/usr/libexec/cnspeedtest/service-control', [ action ]).then(function() {
		ui.addNotification(null, E('p', '服务操作已完成。'), 'info');
		window.setTimeout(function() {
			window.location.reload();
		}, 1500);
	}).catch(function(err) {
		ui.addNotification(null, E('p', err.message || String(err)), 'danger');
	});
}

function readLog(path) {
	return fs.read_direct(path || '/var/log/cnspeedtest.log').catch(function() {
		return '';
	});
}

function readIdentity() {
	return fs.exec('/usr/libexec/cnspeedtest/identity', []).then(function(res) {
		var out = { machine_id: '', imei: '', android_ua: '' };
		String((res && res.stdout) || '').split(/\n/).forEach(function(line) {
			var m = line.match(/^([A-Z_]+)='(.*)'$/);
			if (!m)
				return;
			if (m[1] === 'MACHINE_ID')
				out.machine_id = m[2];
			else if (m[1] === 'IMEI')
				out.imei = m[2];
			else if (m[1] === 'ANDROID_UA')
				out.android_ua = m[2];
		});
		return out;
	}).catch(function() {
		return { machine_id: '', imei: '', android_ua: '' };
	});
}

function parseServiceStatus(result) {
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

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('cnspeedtest'),
			L.resolveDefault(uci.load('argon'), null)
		]).then(function() {
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
		var serviceStatus = data[0];
		var service = parseServiceStatus(serviceStatus);
		var log = data[1] || '';
		var identity = data[2] || {};
		var listen = service.listen || uci.get('cnspeedtest', 'main', 'listen') || '0.0.0.0:8787';
		var port = listen.split(':').pop() || '8787';
		var argon = (uci.sections('argon', 'global') || [])[0] || {};
		var argonMode = [ 'light', 'dark' ].indexOf(argon.mode) !== -1 ? argon.mode : 'system';
		var webUrl = window.location.protocol + '//' + window.location.hostname + ':' + port +
			'/?theme=' + encodeURIComponent(argonMode);
		var statusLabel = service.running ? '运行中' : (service.enabled ? '已启用，但服务未运行' : '已停止');
		var isRunning = service.running;

		var m = new form.Map('cnspeedtest', '测速配置', '用于管理路由器测速后端的启动参数、节点选择和日志位置。保存配置会自动重启或停止服务端。');
		m.on_after_commit = function() {
			var enabled = uci.get('cnspeedtest', 'main', 'enabled') === '1';
			return fs.exec('/usr/libexec/cnspeedtest/service-control', [ enabled ? 'restart' : 'stop' ]);
		};
		var s = m.section(form.NamedSection, 'main', 'cnspeedtest', '基础设置');
		s.anonymous = true;

		var enabled = s.option(form.Flag, 'enabled', '开机启用');
		enabled.rmempty = false;

		var listenOpt = s.option(form.Value, 'listen', '监听地址');
		listenOpt.placeholder = '0.0.0.0:8787';

		var auto = s.option(form.Flag, 'auto', '自动选择节点');
		auto.rmempty = false;

		var host = s.option(form.Value, 'host', '手动节点地址');
		host.depends('auto', '0');

		var nodePort = s.option(form.Value, 'port', '手动节点端口');
		nodePort.datatype = 'port';
		nodePort.depends('auto', '0');

		var duration = s.option(form.Value, 'duration', '测速时长');
		duration.datatype = 'uinteger';
		duration.placeholder = '15';

		var bandwidth = s.option(form.Value, 'bandwidth', '带宽参数');
		bandwidth.datatype = 'uinteger';
		bandwidth.placeholder = '2000';

		var downloadThreads = s.option(form.Value, 'download_threads', '下载线程数');
		downloadThreads.datatype = 'uinteger';

		var uploadThreads = s.option(form.Value, 'upload_threads', '上传线程数');
		uploadThreads.datatype = 'uinteger';

		var probeCount = s.option(form.Value, 'probe_count', '候选节点数');
		probeCount.datatype = 'uinteger';

		var pingCount = s.option(form.Value, 'ping_count', 'Ping 次数');
		pingCount.datatype = 'uinteger';

		var timeout = s.option(form.Value, 'connect_timeout', '连接超时');
		timeout.placeholder = '1s';

		var runDownload = s.option(form.Flag, 'download', '下载测速');
		runDownload.rmempty = false;

		var runUpload = s.option(form.Flag, 'upload', '上传测速');
		runUpload.rmempty = false;

		var noProbe = s.option(form.Flag, 'no_download_probe', '跳过下载探测');
		noProbe.rmempty = false;

		var forceDownload = s.option(form.Flag, 'force_download', '探测失败仍下载');
		forceDownload.rmempty = false;

		var insecure = s.option(form.Flag, 'insecure_discovery', '兼容节点发现');
		insecure.rmempty = false;

		var logFile = s.option(form.Value, 'log_file', '日志文件');
		logFile.placeholder = '/var/log/cnspeedtest.log';

		var actionButton = function(label, cls, action) {
			return E('button', {
				'class': 'cnspeed-ui-button ' + (cls || ''),
				'type': 'button',
				'click': ui.createHandlerFn(this, function() { return serviceAction(action); })
			}, label);
		}.bind(this);

		var hero = E('div', { 'class': 'cnspeed-ui-hero' }, [
			E('div', { 'class': 'cnspeed-ui-hero-copy' }, [
				E('div', { 'class': 'cnspeed-ui-eyebrow' }, 'OPENWRT ROUTER SPEED TEST'),
				E('h2', { 'class': 'cnspeed-ui-title' }, 'CNSpeedTest'),
				E('p', { 'class': 'cnspeed-ui-subtitle' }, '路由器原生测速、节点管理与实时运行日志。')
			]),
			E('div', { 'class': 'cnspeed-ui-hero-tags' }, [
				E('span', 'OpenWrt 25.12'),
				E('span', 'Linux 6.12'),
				E('span', 'Argon Ready')
			])
		]);

		var openAttributes = {
			'class': 'cnspeed-ui-button cnspeed-ui-primary',
			'type': 'button',
			'click': function() { window.open(webUrl, '_blank', 'noopener'); }
		};
		if (!isRunning)
			openAttributes.disabled = 'disabled';

		var statusBox = E('div', { 'class': 'cnspeed-ui-card' }, [
			E('h3', '运行状态'),
			E('div', { 'class': 'cnspeed-ui-kv' }, [ E('span', '服务状态'), E('strong', [ E('span', { 'class': 'cnspeed-ui-badge ' + (isRunning ? 'is-running' : 'is-stopped') }, [ E('i'), statusLabel ]) ]) ]),
			E('div', { 'class': 'cnspeed-ui-kv' }, [ E('span', '进程 / 端口检查'), E('strong', isRunning ? ('PID ' + service.pid + '，端口正在监听') : (service.pid ? ('PID ' + service.pid + '，但端口未监听') : '未发现测速进程')) ]),
			E('div', { 'class': 'cnspeed-ui-kv' }, [ E('span', '监听地址'), E('strong', listen) ]),
			E('div', { 'class': 'cnspeed-ui-kv' }, [ E('span', '测速页面'), E('strong', webUrl) ]),
			E('div', { 'class': 'cnspeed-ui-actions' }, [
				actionButton('启动服务', 'cnspeed-ui-primary', 'start'),
				actionButton('停止服务', 'cnspeed-ui-danger', 'stop'),
				actionButton('重启服务', '', 'restart'),
				E('button', openAttributes, '打开测速页')
			]),
			E('p', { 'class': 'cnspeed-ui-help' }, '保存配置会自动重启服务端，让新配置立即生效。')
		]);

		var identityBox = E('div', { 'class': 'cnspeed-ui-card' }, [
			E('h3', '设备身份'),
			E('div', { 'class': 'cnspeed-ui-kv' }, [ E('span', '机器 ID'), E('strong', [ E('span', { 'class': 'cnspeed-ui-readonly' }, identity.machine_id || '') ]) ]),
			E('div', { 'class': 'cnspeed-ui-kv' }, [ E('span', 'IMEI / TS'), E('strong', [ E('span', { 'class': 'cnspeed-ui-readonly' }, identity.imei || '') ]) ]),
			E('div', { 'class': 'cnspeed-ui-kv' }, [ E('span', 'Android UA'), E('strong', [ E('span', { 'class': 'cnspeed-ui-readonly' }, identity.android_ua || '') ]) ])
		]);

		var rawStatusBox = E('div', { 'class': 'cnspeed-ui-card' }, [
			E('h3', '服务原始状态'),
			E('pre', { 'style': 'white-space:pre-wrap;margin:0;min-height:70px' }, String((serviceStatus && serviceStatus.stdout) || '').trim() || '暂无状态信息')
		]);

		var logBox = E('div', { 'class': 'cnspeed-ui-card' }, [
			E('h3', '运行日志'),
			E('p', { 'class': 'cnspeed-ui-help' }, uci.get('cnspeedtest', 'main', 'log_file') || '/var/log/cnspeedtest.log'),
			E('pre', {
				'id': 'cnspeedtest-log',
				'class': 'cnspeed-ui-log'
			}, [ log || '暂无日志。' ])
		]);

		poll.add(function() {
			return readLog(uci.get('cnspeedtest', 'main', 'log_file')).then(function(text) {
				var el = document.getElementById('cnspeedtest-log');
				if (el)
					el.textContent = text || '暂无日志。';
			});
		}, 5);

		var mapNode = await m.render();
		return E('div', { 'class': 'cnspeed-ui cnspeed-theme-' + argonMode }, [
			E('link', { 'rel': 'stylesheet', 'href': L.resource('cnspeedtest/argon.css') }),
			hero,
			E('div', { 'class': 'cnspeed-ui-notice' },
				'这里测试的是路由器到外网的速度；结果可能受分流、QoS、代理、' +
				'硬件加速及其他路由器配置影响而波动。'),
			E('div', { 'class': 'cnspeed-ui-grid' }, [
				E('div', {}, [ statusBox, identityBox, E('div', { 'class': 'cnspeed-ui-config' }, mapNode) ]),
				E('div', {}, [ rawStatusBox, logBox ])
			])
		]);
	}
});
