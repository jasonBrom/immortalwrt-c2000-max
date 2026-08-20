'use strict';
'require baseclass';

/* Lightweight canvas charts for LuCI.  Keeping the renderer in one module
 * gives the traffic overview and per-device audit the same responsive,
 * keyboard-accessible interaction without pulling a large browser bundle
 * into the router image. */

var COLORS = [ '#3478f6', '#2fb383', '#ff8a1f', '#8b5cf6', '#ec4899', '#12a8a8', '#84b81b', '#87909c' ];

function number(value) {
	value = Number(value || 0);
	return isFinite(value) && value > 0 ? value : 0;
}

function frame(height) {
	var tooltip = E('div', {
		'style': 'display:none;position:absolute;z-index:2;pointer-events:none;padding:.4em .6em;border-radius:4px;background:rgba(20,20,20,.92);color:#fff;white-space:nowrap;font-size:90%;box-shadow:0 2px 8px rgba(0,0,0,.3)'
	});
	var canvas = E('canvas', {
		'role': 'img',
		'tabindex': '0',
		'style': 'display:block;width:100%;height:%dpx;touch-action:none'.format(height)
	});
	return {
		root: E('div', { 'class': 'c2000max-chart-frame',
			'style': 'position:relative;width:100%;min-width:0' }, [ canvas, tooltip ]),
		canvas: canvas,
		tooltip: tooltip,
		height: height
	};
}

function contextFor(chart) {
	var canvas = chart.canvas;
	var ratio = Math.max(1, Math.min(2, window.devicePixelRatio || 1));
	var width = Math.max(280, Math.round(canvas.clientWidth || 640));
	var height = chart.height;

	if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) {
		canvas.width = Math.round(width * ratio);
		canvas.height = Math.round(height * ratio);
	}
	var ctx = canvas.getContext('2d');
	ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
	ctx.clearRect(0, 0, width, height);
	return { ctx: ctx, width: width, height: height };
}

function watchSize(chart, draw) {
	var queued = false;
	var attached = false;
	var destroyed = false;
	var observer = null;
	var resizeHandler = null;

	function destroy() {
		if (destroyed)
			return;
		destroyed = true;
		if (observer)
			observer.disconnect();
		if (resizeHandler)
			window.removeEventListener('resize', resizeHandler);
	}

	function redraw() {
		if (destroyed || queued) return;
		if (document.body.contains(chart.root))
			attached = true;
		else if (attached) {
			destroy();
			return;
		}
		queued = true;
		requestAnimationFrame(function() {
			queued = false;
			if (destroyed)
				return;
			if (document.body.contains(chart.root))
				attached = true;
			else if (attached) {
				destroy();
				return;
			}
			draw();
		});
	}
	if (window.ResizeObserver) {
		observer = new ResizeObserver(redraw);
		observer.observe(chart.root);
	}
	else {
		resizeHandler = redraw;
		window.addEventListener('resize', resizeHandler);
	}
	chart.root.addEventListener('c2000max-chart-destroy', destroy, { once: true });
	redraw();
}

function positionTooltip(chart, event, html) {
	var rect = chart.root.getBoundingClientRect();
	var x = event.clientX - rect.left + 12;
	var y = event.clientY - rect.top + 12;
	chart.tooltip.innerHTML = html;
	chart.tooltip.style.display = 'block';
	var maxX = Math.max(0, rect.width - chart.tooltip.offsetWidth - 4);
	var maxY = Math.max(0, rect.height - chart.tooltip.offsetHeight - 4);
	chart.tooltip.style.left = Math.min(x, maxX) + 'px';
	chart.tooltip.style.top = Math.min(y, maxY) + 'px';
}

function hideTooltip(chart) {
	chart.tooltip.style.display = 'none';
}

function line(samples, options) {
	options = options || {};
	var chart = frame(Number(options.height || 230));
	var fields = options.series || [
		{ key: 'download', name: '下载', color: COLORS[0] },
		{ key: 'upload', name: '上传', color: COLORS[1] }
	];
	var hidden = {};
	var hover = -1;
	var geometry = null;

	samples = (samples || []).filter(function(sample) {
		return sample && isFinite(Number(sample.timestamp));
	});

	function draw() {
		var box = contextFor(chart);
		var ctx = box.ctx;
		var width = box.width;
		var height = box.height;
		var pad = { left: 58, right: 16, top: 18, bottom: 32 };
		var max = 0;
		var tickLabels = [];
		var widestLabel = 0;

		fields.forEach(function(field) {
			if (hidden[field.key]) return;
			samples.forEach(function(sample) { max = Math.max(max, number(sample[field.key])); });
		});
		max = max || 1;
		ctx.font = '12px sans-serif';
		for (var labelTick = 0; labelTick <= 4; labelTick++) {
			var labelValue = max * (4 - labelTick) / 4;
			var label = options.formatValue ? options.formatValue(labelValue) : String(Math.round(labelValue));
			tickLabels.push(label);
			widestLabel = Math.max(widestLabel, ctx.measureText(label).width);
		}
		/* Fixed padding clipped decimal/unit labels on narrow LuCI cards. Size
		 * the gutter from the actual rendered labels while keeping enough graph
		 * width for small phone screens. */
		pad.left = Math.max(pad.left, Math.ceil(widestLabel) + 14);
		pad.left = Math.min(pad.left, Math.max(58, Math.floor(width * .38)));
		var plotWidth = Math.max(1, width - pad.left - pad.right);
		var plotHeight = Math.max(1, height - pad.top - pad.bottom);
		geometry = { left: pad.left, right: width - pad.right, top: pad.top,
			bottom: height - pad.bottom, width: plotWidth, height: plotHeight };

		ctx.fillStyle = 'rgba(127,127,127,.055)';
		ctx.fillRect(pad.left, pad.top, plotWidth, plotHeight);
		ctx.textBaseline = 'middle';
		ctx.strokeStyle = 'rgba(127,127,127,.28)';
		ctx.fillStyle = '#87909c';
		ctx.lineWidth = 1;
		for (var tick = 0; tick <= 4; tick++) {
			var y = pad.top + tick * plotHeight / 4;
			ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(width - pad.right, y); ctx.stroke();
			ctx.textAlign = 'right';
			ctx.fillText(tickLabels[tick], pad.left - 8, y);
		}

		if (samples.length) {
			var labelCount = Math.min(5, samples.length);
			for (var l = 0; l < labelCount; l++) {
				var index = Math.round(l * (samples.length - 1) / Math.max(1, labelCount - 1));
				var x = pad.left + index * plotWidth / Math.max(1, samples.length - 1);
				ctx.textAlign = l === 0 ? 'left' : (l === labelCount - 1 ? 'right' : 'center');
				ctx.fillText(new Date(Number(samples[index].timestamp) * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }), x, height - 14);
			}
		}

		fields.forEach(function(field) {
			if (hidden[field.key]) return;
			ctx.beginPath();
			samples.forEach(function(sample, index) {
				var x = pad.left + index * plotWidth / Math.max(1, samples.length - 1);
				var y = height - pad.bottom - number(sample[field.key]) * plotHeight / max;
				if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
			});
			ctx.strokeStyle = field.color;
			ctx.lineWidth = 2.5;
			ctx.lineJoin = 'round';
			ctx.stroke();
		});

		if (hover >= 0 && hover < samples.length) {
			var hx = pad.left + hover * plotWidth / Math.max(1, samples.length - 1);
			ctx.beginPath(); ctx.moveTo(hx, pad.top); ctx.lineTo(hx, height - pad.bottom);
			ctx.strokeStyle = 'rgba(127,127,127,.65)'; ctx.lineWidth = 1; ctx.stroke();
			fields.forEach(function(field) {
				if (hidden[field.key]) return;
				var hy = height - pad.bottom - number(samples[hover][field.key]) * plotHeight / max;
				ctx.beginPath(); ctx.arc(hx, hy, 4, 0, Math.PI * 2);
				ctx.fillStyle = field.color; ctx.fill();
			});
		}
	}

	function hoverAt(event) {
		if (!samples.length || !geometry) return;
		var rect = chart.canvas.getBoundingClientRect();
		var x = event.clientX - rect.left;
		hover = Math.max(0, Math.min(samples.length - 1,
			Math.round((x - geometry.left) * Math.max(1, samples.length - 1) / geometry.width)));
		var sample = samples[hover];
		var details = fields.filter(function(field) { return !hidden[field.key]; }).map(function(field) {
			return '<span style="color:%s">●</span> %s：%s'.format(field.color, field.name,
				options.formatValue ? options.formatValue(number(sample[field.key])) : number(sample[field.key]));
		}).join('<br>');
		positionTooltip(chart, event, '%s<br>%s'.format(new Date(Number(sample.timestamp) * 1000).toLocaleString(), details));
		draw();
	}

	chart.canvas.addEventListener('mousemove', hoverAt);
	chart.canvas.addEventListener('mouseleave', function() { hover = -1; hideTooltip(chart); draw(); });
	chart.canvas.addEventListener('touchmove', function(event) {
		if (event.touches.length) hoverAt(event.touches[0]);
	}, { passive: true });
	chart.canvas.addEventListener('touchend', function() { hover = -1; hideTooltip(chart); draw(); });

	var legend = E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;margin-bottom:.45em' },
		fields.map(function(field) {
			return E('button', {
				'class': 'btn',
				'type': 'button',
				'style': 'padding:.25em .65em;border-color:%s'.format(field.color),
				'click': function(event) {
					hidden[field.key] = !hidden[field.key];
					event.currentTarget.style.opacity = hidden[field.key] ? '.45' : '1';
					draw();
				}
			}, [ E('span', { 'style': 'color:%s'.format(field.color) }, '●'), ' ', field.name ]);
		}));

	watchSize(chart, draw);
	return E('div', { 'class': 'c2000max-interactive-chart' }, [ legend, chart.root ]);
}

function doughnut(items, options) {
	options = options || {};
	items = (items || []).map(function(item, index) {
		return { name: item.name, value: number(item.value), color: item.color || COLORS[index % COLORS.length] };
	}).filter(function(item) { return item.value > 0; });
	if (!items.length)
		return E('div', { 'class': 'alert-message notice' }, options.emptyText || '这个时间段没有可展示的流量。');

	var chart = frame(Number(options.height || 220));
	var hidden = {};
	var hover = -1;
	var arcs = [];

	function visibleTotal() {
		return items.reduce(function(sum, item, index) { return sum + (hidden[index] ? 0 : item.value); }, 0);
	}

	function draw() {
		var box = contextFor(chart);
		var ctx = box.ctx;
		var cx = box.width / 2;
		var cy = box.height / 2;
		var radius = Math.max(30, Math.min(box.width, box.height) / 2 - 14);
		var inner = radius * .58;
		var total = visibleTotal();
		var angle = -Math.PI / 2;
		arcs = [];

		items.forEach(function(item, index) {
			if (hidden[index] || !total) return;
			var end = angle + Math.PI * 2 * item.value / total;
			ctx.beginPath(); ctx.arc(cx, cy, radius - (hover === index ? 1 : 4), angle, end);
			ctx.arc(cx, cy, inner, end, angle, true); ctx.closePath();
			ctx.fillStyle = item.color; ctx.fill();
			if (hover === index) { ctx.strokeStyle = '#fff'; ctx.lineWidth = 2; ctx.stroke(); }
			arcs.push({ index: index, start: angle, end: end, cx: cx, cy: cy, inner: inner, outer: radius });
			angle = end;
		});

		ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
		ctx.fillStyle = '#87909c'; ctx.font = '12px sans-serif';
		ctx.fillText(options.centerLabel || '总计', cx, cy - 10);
		ctx.fillStyle = '#c7ccd4'; ctx.font = 'bold 14px sans-serif';
		ctx.fillText(options.formatValue ? options.formatValue(total) : String(total), cx, cy + 12);
	}

	function hit(event) {
		var rect = chart.canvas.getBoundingClientRect();
		var scaleX = chart.canvas.clientWidth / rect.width;
		var scaleY = chart.height / rect.height;
		var x = (event.clientX - rect.left) * scaleX;
		var y = (event.clientY - rect.top) * scaleY;
		var selected = -1;
		arcs.forEach(function(arc) {
			var dx = x - arc.cx, dy = y - arc.cy;
			var distance = Math.sqrt(dx * dx + dy * dy);
			var angle = Math.atan2(dy, dx);
			if (angle < -Math.PI / 2) angle += Math.PI * 2;
			var end = arc.end < arc.start ? arc.end + Math.PI * 2 : arc.end;
			if (distance >= arc.inner && distance <= arc.outer && angle >= arc.start && angle <= end)
				selected = arc.index;
		});
		if (selected !== hover) { hover = selected; draw(); }
		if (selected >= 0) {
			var total = visibleTotal();
			var item = items[selected];
			positionTooltip(chart, event, '<b>%h</b><br>%h（%.1f%%）'.format(String(item.name),
				options.formatValue ? options.formatValue(item.value) : item.value, item.value * 100 / total));
		}
		else hideTooltip(chart);
	}

	chart.canvas.addEventListener('mousemove', hit);
	chart.canvas.addEventListener('mouseleave', function() { hover = -1; hideTooltip(chart); draw(); });
	chart.canvas.addEventListener('touchmove', function(event) {
		if (event.touches.length) hit(event.touches[0]);
	}, { passive: true });
	chart.canvas.addEventListener('touchend', function() { hover = -1; hideTooltip(chart); draw(); });

	var legend = E('div', { 'style': 'min-width:240px;flex:1' }, items.map(function(item, index) {
		return E('button', {
			'class': 'btn',
			'type': 'button',
			'style': 'display:flex;width:100%;gap:.55em;align-items:center;margin:.2em 0;padding:.35em .55em;text-align:left',
			'mouseenter': function(event) { hover = index; draw(); event.currentTarget.style.borderColor = item.color; },
			'mouseleave': function(event) { hover = -1; draw(); event.currentTarget.style.borderColor = ''; },
			'click': function(event) {
				hidden[index] = !hidden[index];
				event.currentTarget.style.opacity = hidden[index] ? '.42' : '1';
				draw();
			}
		}, [
			E('span', { 'style': 'color:%s'.format(item.color) }, '●'),
			E('span', { 'style': 'flex:1' }, [ String(item.name) ]),
			E('span', {}, options.formatValue ? options.formatValue(item.value) : String(item.value))
		]);
	}));

	watchSize(chart, draw);
	return E('div', { 'class': 'c2000max-interactive-chart',
		'style': 'display:flex;gap:1em;align-items:center;flex-wrap:wrap;min-width:0' }, [
		E('div', { 'style': 'width:240px;max-width:100%;flex:0 1 240px' }, chart.root), legend
	]);
}

return baseclass.extend({
	line: line,
	doughnut: doughnut
});
