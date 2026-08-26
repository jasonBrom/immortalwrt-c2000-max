'use strict';
'require baseclass';
'require qmodem.qmodem as qmodem';

function progressbar(value, max, min, unit) {
	var val = parseInt(value) || 0,
		maximum = parseInt(max) || 100,
		minimum = parseInt(min) || 0,
		unit = unit || '',
		pc = Math.floor((100 / (maximum - minimum)) * (val - minimum));

	return E('div', {
		'class': 'cbi-progressbar',
		'title': '%s / %s%s (%d%%)'.format(val, maximum, unit, pc)
	}, E('div', { 'style': 'width:%.2f%%'.format(pc) }));
}

var lastData = [];
var liveRefresh = null;
var liveRefreshStarted = 0;
var LIVE_REFRESH_INTERVAL = 10000;

function mapInfo(section, base, cell) {
	var allInfo = [];

	if (base && base.modem_info)
		allInfo = allInfo.concat(base.modem_info);
	if (cell && cell.modem_info)
		allInfo = allInfo.concat(cell.modem_info);

	return { section: section, info: allInfo };
}

function startLiveRefresh(sections) {
	var now = Date.now();

	if (liveRefresh || now - liveRefreshStarted < LIVE_REFRESH_INTERVAL)
		return;

	liveRefreshStarted = now;
	liveRefresh = Promise.all(sections.map(function(section) {
		return Promise.all([
			qmodem.getBaseInfo(section.id),
			qmodem.getCellInfo(section.id)
		]).then(function(results) {
			return mapInfo(section, results[0], results[1]);
		});
	})).then(function(data) {
		lastData = data;
		liveRefresh = null;
	}, function(error) {
		console.warn('Background QModem overview refresh failed:', error);
		liveRefresh = null;
	});
}

return baseclass.extend({
	title: _('Modem Info'),

	load: function() {
		return qmodem.getModemSections().then(function(sections) {
			var promises = sections.map(function(section) {
				return qmodem.getOverviewInfo(section.id).then(function(result) {
					return mapInfo(section, result, null);
				}, function() {
					return mapInfo(section, null, null);
				});
			});
			return Promise.all(promises).then(function(cachedData) {
				if (!lastData.length)
					lastData = cachedData;
				startLiveRefresh(sections);
				return lastData;
			});
		});
	},

	render: function(data) {
		var container = E('div', {});

		if (!data || data.length === 0) {
			var table = E('table', { 'class': 'table' });
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '100%' }, [ _('No modem information available') ])
			]));
			return table;
		}

		try {
			for (var m = 0; m < data.length; m++) {
				var modem = data[m];
				var table = E('table', { 'class': 'table' });
				var fields = [];

				// Add section header
				if (modem.section && modem.section.name) {
					table.appendChild(E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th', 'colspan': '2' }, [ modem.section.name ])
					]));
				}

				var infoArray = modem.info || [];
				for (var i = 0; i < infoArray.length; i++) {
					var entry = infoArray[i];
					var full_name = entry.full_name;
					var extra_info = entry.extra_info;
					
					if (entry.value == null) {
						continue;
					}
					
					if ((entry.class == 'Base Information') || 
						(entry.class == 'Cell Information' && entry.type == 'progress_bar')) {
						fields.push(extra_info ? '%s (%s)'.format(_(full_name), extra_info) : _(full_name));
						fields.push(entry);
					}
				}

				if (fields.length == 0) {
					table.appendChild(E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left', 'width': '100%' }, [ _('No modem information available') ])
					]));
					container.appendChild(table);
					continue;
				}

				for (var i = 0; i < fields.length; i += 2) {
					var entry = fields[i + 1];
					var type = entry.type;
					var value;
					if (type == 'progress_bar') {
						value = E('td', { 'class': 'td left' }, [
							(entry.value != null) ? progressbar(entry.value, entry.max_value, entry.min_value, entry.unit) : '?'
						]);
					} else {
						value = E('td', { 'class': 'td left' }, [ (entry.value != null) ? entry.value : '?' ]);
					}

					table.appendChild(E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left', 'width': '33%' }, [ fields[i] ]),
						value
					]));
				}

				container.appendChild(table);
			}

			return container;
		}
		catch (e) {
			var table = E('table', { 'class': 'table' });
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '100%' }, [ _('No modem information available') ])
			]));
			return table;
		}
	}
});
