'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

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

function serviceAction(action) {
	return fs.exec('/usr/libexec/speedtest-x/service-control', [ action ]).then(function() {
		ui.addNotification(null, E('p', {}, '服务操作已完成。'), 'info');
		window.setTimeout(function() { window.location.reload(); }, 1500);
	}).catch(function(error) {
		ui.addNotification(null, E('p', {}, error.message || String(error)), 'danger');
	});
}

function webURL(listen) {
	var match = String(listen || '').match(/:(\d+)$/);
	var port = match ? match[1] : '9001';
	return window.location.protocol + '//' + window.location.hostname + ':' + port + '/';
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('speedtestx'),
			fs.exec('/usr/libexec/speedtest-x/service-control', [ 'status' ]).catch(function() {
				return { stdout: 'running=0\nenabled=0\nlistening=0\n' };
			})
		]);
	},

	render: async function(data) {
		var service = parseServiceStatus(data[1]);
		var listen = service.listen || uci.get('speedtestx', 'main', 'listen') || '0.0.0.0:9001';
		var url = webURL(listen);
		var stateLabel = service.running ? '运行中' : (service.enabled ? '已启用，但服务未运行' : '已停止');
		var map = new form.Map('speedtestx', '内网测速（Speedtest-X）',
			'使用单个轻量 Go 服务测试终端与 C2000-MAX 之间的下载、上传、延迟和抖动。结果仅供参考：此测速链路不经过路由器网络加速，速度可能与实际转发或上网速度存在差异。服务默认关闭，也不会开放 WAN 防火墙端口。');

		map.on_after_commit = function() {
			var enabled = uci.get('speedtestx', 'main', 'enabled') === '1';
			return fs.exec('/usr/libexec/speedtest-x/service-control', [ enabled ? 'restart' : 'stop' ]);
		};

		var section = map.section(form.NamedSection, 'main', 'speedtestx', '服务设置');
		section.anonymous = true;

		var enabled = section.option(form.Flag, 'enabled', '启用服务');
		enabled.rmempty = false;
		enabled.description = '关闭时不会启动进程，不占用常驻内存。';

		var address = section.option(form.Value, 'listen', '监听地址');
		address.placeholder = '0.0.0.0:9001';
		address.rmempty = false;

		var chunk = section.option(form.Value, 'max_download_mb', '单次下载块上限（MiB）');
		chunk.datatype = 'range(1,1024)';
		chunk.placeholder = '50';

		var clients = section.option(form.Value, 'max_clients', '并发测速流上限');
		clients.datatype = 'range(12,128)';
		clients.placeholder = '24';

		var history = section.option(form.Value, 'history_limit', '内存测速记录数');
		history.datatype = 'range(0,1000)';
		history.placeholder = '100';
		history.description = '仅保存在进程内存中，服务重启后清空；设为 0 可关闭记录。';

		function button(label, style, action) {
			return E('button', {
				'class': 'btn cbi-button ' + style,
				'type': 'button',
				'click': ui.createHandlerFn(this, function() { return serviceAction(action); })
			}, label);
		}

		var openAttributes = {
			'class': 'btn cbi-button cbi-button-positive',
			'type': 'button',
			'click': function() { window.open(url, '_blank', 'noopener'); }
		};
		if (!service.running)
			openAttributes.disabled = 'disabled';

		var status = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '运行状态'),
			E('div', { 'class': 'table' }, [
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left', 'style': 'width:33%' }, '服务状态'),
					E('div', { 'class': 'td left' }, [
						E('strong', { 'style': 'color:' + (service.running ? '#2d9d53' : '#d34b4b') }, stateLabel)
					])
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '进程 / 端口检查'),
					E('div', { 'class': 'td left' }, service.running ?
						('PID ' + service.pid + '，端口正在监听') :
						(service.pid ? ('PID ' + service.pid + '，但端口未监听') : '未发现测速进程'))
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left' }, '测速地址'),
					E('div', { 'class': 'td left' }, url)
				])
			]),
			E('div', { 'style': 'display:flex;gap:.6rem;flex-wrap:wrap;margin-top:1rem' }, [
				button.call(this, '启动服务', 'cbi-button-positive', 'start'),
				button.call(this, '停止服务', 'cbi-button-negative', 'stop'),
				button.call(this, '重启服务', 'cbi-button-action', 'restart'),
				E('button', openAttributes, '打开测速页面')
			])
		]);

		var mapNode = await map.render();
		return E('div', {}, [ status, mapNode ]);
	}
});
