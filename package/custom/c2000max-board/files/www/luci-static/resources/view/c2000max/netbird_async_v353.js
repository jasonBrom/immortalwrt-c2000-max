// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';

/*
 * Board-owned NetBird authentication page.
 *
 * Every operation that may wait for NetBird or its management server is queued
 * through c2000max-service-worker.  rpcd only writes/reads small state files,
 * so updating luci-app-netbird cannot put the blocking authentication path back
 * on LuCI's shared RPC process.
 */

var callStatus = rpc.declare({
	object: 'c2000max',
	method: 'netbird_status',
	expect: {}
});

var callJobStart = rpc.declare({
	object: 'c2000max',
	method: 'netbird_job_start',
	params: [ 'action', 'management_url', 'setup_key' ],
	expect: {}
});

var callJobStatus = rpc.declare({
	object: 'c2000max',
	method: 'netbird_job_status',
	params: [ 'job_id' ],
	expect: {}
});

function stateModel(data) {
	if (data && data.connected)
		return {
			color: '#168a45',
			label: _('Connected'),
			hint: _('NetBird is connected to the management server.')
		};

	switch ((data && data.state) || 'unknown') {
	case 'not_installed':
		return {
			color: '#8a1f11',
			label: _('Not installed'),
			hint: _('The NetBird binary was not found.')
		};
	case 'service_disabled':
		return {
			color: '#777',
			label: _('Service disabled'),
			hint: _('Enable the service or connect below.')
		};
	case 'service_stopped':
		return {
			color: '#a66b00',
			label: _('Service stopped'),
			hint: _('The NetBird service is enabled but is not running.')
		};
	case 'running':
		return {
			color: '#a66b00',
			label: _('Disconnected'),
			hint: _('The service is running but the mesh session is not connected.')
		};
	default:
		return {
			color: '#777',
			label: _('Unknown'),
			hint: _('The cached service state is not available yet; it will refresh automatically.')
		};
	}
}

function actionMessage(action) {
	switch (action) {
	case 'enable': return _('Enable and start');
	case 'up': return _('Connect');
	case 'reconnect': return _('Reconnect');
	case 'down': return _('Disconnect');
	case 'logout': return _('Deregister');
	case 'local_wipe': return _('Remove local identity');
	default: return _('NetBird operation');
	}
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {
			success: false,
			state: 'unknown',
			job: { state: 'idle' }
		});
	},

	_setButtonBusy: function(btn, busy) {
		if (!btn)
			return;
		if (busy)
			btn.classList.add('spinning');
		else
			btn.classList.remove('spinning');
		btn.disabled = !!busy;
	},

	_setJobText: function(message) {
		var el = document.getElementById('c2000max-netbird-job');
		if (el)
			el.textContent = message || '';
	},

	_pollJob: function(btn, jobId, attempt) {
		var self = this;
		attempt = attempt || 0;

		return callJobStatus(jobId).then(function(res) {
			var state = (res && res.state) || 'unknown';
			self._setJobText((res && res.message) || _('NetBird background task is running.'));

			if (state === 'success') {
				self._setButtonBusy(btn, false);
				ui.addNotification(null, E('p', {}, (res && res.message) ||
					_('NetBird operation completed.')), 'info');
				window.setTimeout(function() { location.reload(); }, 600);
				return;
			}
			if (state === 'error') {
				self._setButtonBusy(btn, false);
				ui.addNotification(null, E('p', {}, (res && res.message) ||
					_('NetBird operation failed.')), 'error');
				return;
			}
			if (attempt >= 90) {
				self._setButtonBusy(btn, false);
				ui.addNotification(null, E('p', {},
					_('The NetBird task is still running in the background. Reload this page later to see its result.')),
					'warning');
				return;
			}

			window.setTimeout(function() {
				self._pollJob(btn, jobId, attempt + 1);
			}, 1000);
		}).catch(function() {
			/*
			 * A NetBird route/DNS transition can abort one browser XHR.  The
			 * task is outside rpcd and continues safely, so retry the small
			 * state-file read instead of reporting a false failure.
			 */
			if (attempt >= 90) {
				self._setButtonBusy(btn, false);
				ui.addNotification(null, E('p', {},
					_('The browser could not read the task result. The background task was not cancelled.')),
					'warning');
				return;
			}
			window.setTimeout(function() {
				self._pollJob(btn, jobId, attempt + 1);
			}, 1000);
		});
	},

	_startJob: function(btn, action, managementUrl, setupKey) {
		var self = this;
		var promise;

		self._setButtonBusy(btn, true);
		self._setJobText(actionMessage(action) + '…');
		promise = callJobStart(action, managementUrl || '', setupKey || '');
		setupKey = '';

		return promise.then(function(res) {
			if (!res || !res.success || !res.job_id) {
				self._setButtonBusy(btn, false);
				ui.addNotification(null, E('p', {}, (res && res.message) ||
					_('Unable to queue the NetBird task.')), 'error');
				return;
			}
			return self._pollJob(btn, res.job_id, 0);
		}).catch(function(err) {
			self._setButtonBusy(btn, false);
			ui.addNotification(null, E('p', {},
				String(err && err.message ? err.message : err)), 'error');
		});
	},

	handleEnable: function(ev) {
		return this._startJob(ev.currentTarget, 'enable', '', '');
	},

	handleConnect: function(ev) {
		var urlEl = document.getElementById('c2000max-nb-url');
		var keyEl = document.getElementById('c2000max-nb-key');
		var url = urlEl ? String(urlEl.value || '').trim() : '';
		var key = keyEl ? String(keyEl.value || '') : '';
		var promise;

		if (keyEl)
			keyEl.value = '';
		promise = this._startJob(ev.currentTarget, 'up', url, key);
		key = '';
		return promise;
	},

	handleReconnect: function(ev) {
		return this._startJob(ev.currentTarget, 'reconnect',
			(this._status && this._status.management_url) || '', '');
	},

	handleDisconnect: function(ev) {
		return this._startJob(ev.currentTarget, 'down', '', '');
	},

	handleDeregister: function() {
		var self = this;
		ui.showModal(_('Deregister this NetBird device?'), [
			E('p', {}, _('Deregister removes this device from the management server. Removing the local identity only is a recovery option when that server is no longer reachable.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': ui.createHandlerFn(self, 'handleLocalWipeConfirmed')
				}, _('Remove local identity only')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': ui.createHandlerFn(self, 'handleDeregisterConfirmed')
				}, _('Deregister'))
			])
		]);
	},

	handleDeregisterConfirmed: function(ev) {
		ui.hideModal();
		return this._startJob(ev.currentTarget, 'logout', '', '');
	},

	handleLocalWipeConfirmed: function(ev) {
		ui.hideModal();
		return this._startJob(ev.currentTarget, 'local_wipe', '', '');
	},

	renderAuthForm: function(data) {
		var keyHint = data.setup_key_hint || '';
		var description = [
			_('The setup key is sent once to the board-owned background worker and is never stored in UCI or the job result.')
		];
		if (keyHint)
			description.push(E('br'), _('Last used:') + ' ' + keyHint);

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Authentication')),
			data.last_error ? E('div', { 'class': 'alert-message warning' }, [
				E('strong', {}, _('Last error:')), ' ', data.last_error
			]) : E('span'),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'c2000max-nb-url' },
					_('Management URL')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', {
						'id': 'c2000max-nb-url',
						'type': 'text',
						'class': 'cbi-input-text',
						'value': data.management_url || '',
						'placeholder': 'https://api.netbird.io:443'
					}),
					E('div', { 'class': 'cbi-value-description' },
						_('Official or self-hosted NetBird management server.'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'c2000max-nb-key' },
					_('Setup Key')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', {
						'id': 'c2000max-nb-key',
						'type': 'password',
						'class': 'cbi-input-password',
						'autocomplete': 'off',
						'placeholder': _('Leave blank to reuse an existing identity')
					}),
					E('div', { 'class': 'cbi-value-description' }, description)
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, 'handleConnect')
					}, _('Connect'))
				])
			])
		]);
	},

	renderConnectedControls: function() {
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Connection control')),
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, 'handleReconnect')
			}, _('Reconnect')),
			' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, 'handleDisconnect')
			}, _('Disconnect')),
			' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-negative',
				'click': ui.createHandlerFn(this, 'handleDeregister')
			}, _('Deregister'))
		]);
	},

	render: function(data) {
		var model = stateModel(data);
		var job = (data && data.job) || { state: 'idle' };
		var children;

		this._status = data || {};
		children = [
			E('h2', {}, _('NetBird') + ' — ' + _('Authentication')),
			E('div', { 'class': 'cbi-section' }, [
				E('span', {
					'style': 'display:inline-block;color:#fff;background:' + model.color +
						';border-radius:10px;padding:2px 9px;font-weight:600'
				}, model.label),
				' ',
				E('span', {}, model.hint),
				E('div', {
					'id': 'c2000max-netbird-job',
					'class': 'cbi-value-description',
					'style': 'margin-top:8px'
				}, (job.state === 'queued' || job.state === 'running') ?
					(job.message || _('NetBird background task is running.')) : '')
			])
		];

		if (data && data.state === 'not_installed') {
			children.push(E('div', { 'class': 'alert-message warning' },
				_('Install the netbird package before using this page.')));
		} else {
			if (data && (data.state === 'service_disabled' || data.state === 'service_stopped')) {
				children.push(E('div', { 'class': 'cbi-section' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, 'handleEnable')
					}, _('Enable and start'))
				]));
			}
			children.push((data && data.connected) ?
				this.renderConnectedControls() : this.renderAuthForm(data || {}));
		}

		if ((job.state === 'queued' || job.state === 'running') && job.job_id) {
			window.setTimeout(L.bind(function() {
				this._pollJob(null, job.job_id, 0);
			}, this), 250);
		}

		return E('div', { 'class': 'cbi-map' }, children);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
