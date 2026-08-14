'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..');
const views = [ 'sim.js', 'sim_v8.js' ];

function fail(message) {
	console.error(`FAIL: ${message}`);
	process.exit(1);
}

for (const view of views) {
	const filename = path.join(root, 'files/www/luci-static/resources/view/c2000max', view);
	const source = fs.readFileSync(filename, 'utf8');
	const start = source.indexOf('function isRecognizedMT5700(data) {');
	const end = source.indexOf('\n\nreturn view.extend', start);
	if (start < 0 || end < 0)
		fail(`${view}: visibility predicate missing`);
	const context = {};
	vm.runInNewContext(`${source.slice(start, end)}\nresult = isRecognizedMT5700;`, context);
	const recognized = context.result;
	const cases = [
		[ { available: true, model: 'MT5700M-CN' }, true, 'recognized MT5700 model' ],
		[ { available: 1, model: 'TD Tech 5700' }, true, 'numeric availability' ],
		[ { available: true, model: 'FM350-GL' }, false, 'known non-MT5700 model' ],
		[ { available: false, model: 'MT5700M-CN' }, false, 'offline MT5700 state' ],
		[ { available: true, model: '未知模组' }, false, 'unknown model' ],
		[ {}, false, 'undiscovered modem' ]
	];
	for (const [ input, expected, label ] of cases) {
		if (recognized(input) !== expected)
			fail(`${view}: ${label}`);
	}
	if (!source.includes('isRecognizedMT5700(data) ? [ table, buttons ] : [ table, buttons, forceBox ]'))
		fail(`${view}: force box is not gated by the predicate`);
}

console.log('C2000-MAX SIM LuCI visibility tests passed');
