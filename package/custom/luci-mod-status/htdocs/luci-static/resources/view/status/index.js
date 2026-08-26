'use strict';
'require view';
'require dom';
'require poll';
'require fs';
'require network';
'require ui';

var STATUS_INCLUDE_TIMEOUT = 3500;
var STATUS_NETWORK_TIMEOUT = 1500;
var STATUS_MODULE_TIMEOUT = 6000;

function boundedLoad(promise, timeout, label) {
	return new Promise(function(resolve, reject) {
		var settled = false;
		var timer = window.setTimeout(function() {
			if (settled)
				return;
			settled = true;
			reject(new Error('%s timed out after %d ms'.format(label, timeout)));
		}, timeout);

		Promise.resolve(promise).then(function(value) {
			if (settled)
				return;
			settled = true;
			window.clearTimeout(timer);
			resolve(value);
		}, function(error) {
			if (settled)
				return;
			settled = true;
			window.clearTimeout(timer);
			reject(error);
		});
	});
}

return view.extend({
	handleToggleSection: function(include, container, ev) {
		var btn = ev.currentTarget;

		include.hide = !include.hide;

		btn.setAttribute('data-style', include.hide ? 'active' : 'inactive');
		btn.setAttribute('class', include.hide ? 'label notice' : 'label');
		btn.firstChild.data = include.hide ? _('Show') : _('Hide');
		btn.blur();

		container.style.display = include.hide ? 'none' : 'block';

		if (include.hide) {
			localStorage.setItem(include.id, 'hide');
		} else {
			dom.content(container,
				E('p', {}, E('em', { 'class': 'spinning' },
					[ _('Collecting data...') ])
				)
			);

			localStorage.removeItem(include.id);
		}
	},

	invokeIncludesLoad: function(includes, first_load) {
		var tasks = [], has_load = false;

		for (var i = 0; i < includes.length; i++) {
			if (includes[i].hide && !first_load) {
				tasks.push(null);
				continue;
			}

			if (typeof(includes[i].load) == 'function') {
				includes[i].failed = false;
				var include = includes[i];
				var task = Promise.resolve().then(L.bind(include.load, include));

				tasks.push(boundedLoad(task, STATUS_INCLUDE_TIMEOUT,
					include.title || include.id || ('status include ' + i)).catch(L.bind(function(error) {
					this.failed = true;
					console.warn('Status overview include failed:', this.title || this.id, error);
					return null;
				}, includes[i])));

				has_load = true;
			}
			else {
				tasks.push(null);
			}
		}

		return has_load ? Promise.all(tasks) : Promise.resolve(null);
	},

	poll_status: function(includes, containers, first_load) {
		return boundedLoad(network.flushCache(), STATUS_NETWORK_TIMEOUT,
			'network cache refresh').catch(function(error) {
			console.warn('Status overview network cache refresh failed:', error);
			return null;
		}).then(L.bind(this.invokeIncludesLoad, this, includes, first_load))
		.then(function(results) {
			for (var i = 0; i < includes.length; i++) {
				var content = null;

				if (includes[i].hide && !first_load)
					continue;

				if (includes[i].failed)
					continue;

				if (typeof(includes[i].render) == 'function')
					content = includes[i].render(results ? results[i] : null);
				else if (includes[i].content != null)
					content = includes[i].content;

				if (typeof (includes[i].oneshot) == 'function') {
					includes[i].oneshot(results ? results[i] : null);
					includes[i].oneshot = null;
				}

				if (content != null) {
					containers[i].parentNode.style.display = '';
					containers[i].parentNode.classList.add('fade-in');

					if (!includes[i].hide)
						dom.content(containers[i], content);
				}
			}

			var ssi = document.querySelector('div.includes');
			if (ssi) {
				ssi.style.display = '';
				ssi.classList.add('fade-in');
			}
		});
	},

	load: function() {
		return L.resolveDefault(fs.list('/www' + L.resource('view/status/include')), []).then(function(entries) {
			return Promise.all(entries.filter(function(e) {
				return (e.type == 'file' && e.name.match(/\.js$/));
			}).map(function(e) {
				return 'view.status.include.' + e.name.replace(/\.js$/, '');
			}).sort().map(function(n) {
				return boundedLoad(L.require(n), STATUS_MODULE_TIMEOUT, n).catch(function(error) {
					console.warn('Status overview module failed:', n, error);
					return null;
				});
			})).then(function(includes) {
				return includes.filter(function(include) { return include != null; });
			});
		});
	},

	render: function(includes) {
		var rv = E([]), containers = [];

		for (var i = 0; i < includes.length; i++) {
			var title = null;

			if (includes[i].title != null)
				title = includes[i].title;
			else
				title = String(includes[i]).replace(/^\[ViewStatusInclude\d+_(.+)Class\]$/,
					function(m, n) { return n.replace(/(^|_)(.)/g,
						function(m, s, c) { return (s ? ' ' : '') + c.toUpperCase() })
					});

			includes[i].id = title;
			includes[i].hide = localStorage.getItem(includes[i].id) == 'hide';

			var container = E('div');

			rv.appendChild(E('div', { 'class': 'cbi-section', 'style': 'display: none' }, [
				E('div', { 'class': 'cbi-title' },[
					E('h3', { 'style': 'display: flex; justify-content: space-between' }, [
						title || '-',
						E('span', {
							'class': includes[i].hide ? 'label notice' : 'label',
							'style': 'display: flex; align-items: center; justify-content: center; min-width: 4em',
							'data-style': includes[i].hide ? 'active' : 'inactive',
							'data-indicator': 'poll-status',
							'data-clickable': 'true',
							'click': ui.createHandlerFn(this, 'handleToggleSection',
										    includes[i], container)
						}, [ _(includes[i].hide ? 'Show' : 'Hide') ])
					]),
				]),
				container
			]));

			containers.push(container);
		}

		// End the global "Loading view..." state immediately. Every status
		// card is collected in the background and rendered as data arrives.
		window.setTimeout(L.bind(function() {
			this.poll_status(includes, containers, true).then(L.bind(function() {
				return poll.add(L.bind(this.poll_status, this, includes, containers));
			}, this)).catch(function(error) {
				console.warn('Status overview background load failed:', error);
			});
		}, this), 0);

		return rv;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
