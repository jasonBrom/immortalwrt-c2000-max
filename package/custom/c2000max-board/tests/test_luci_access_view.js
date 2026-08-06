'use strict';

const fs = require('fs');
const filename = process.argv[2];

if (!filename)
	throw new Error('missing LuCI view path');

if (typeof String.prototype.format !== 'function') {
	String.prototype.format = function() {
		let index = 0;
		const values = arguments;
		return String(this).replace(/%s/g, () => String(values[index++]));
	};
}

let applyCalls = 0;

const rpc = {
	declare: (spec) => () => {
		if (spec.method === 'access_apply') {
			applyCalls++;
			return Promise.resolve({ success: true, message: 'ok' });
		}
		return Promise.resolve({});
	}
};

function makeOption() {
	return {
		value: function() { return this; },
		depends: function() { return this; }
	};
}

function makeSection() {
	return {
		option: () => makeOption()
	};
}

const form = {
	Map: function() {
		return {
			section: () => makeSection(),
			render: () => Promise.resolve({})
		};
	},
	NamedSection: function() {},
	GridSection: function() {},
	Flag: function() {},
	ListValue: function() {},
	Value: function() {}
};

const view = { extend: (definition) => definition };
const poll = {
	add: (callback) => {
		if (typeof callback !== 'function')
			throw new Error('poll callback is not callable');
	}
};
const dom = { content: function() {} };
const ui = { addNotification: function() {} };
const uci = { load: () => Promise.resolve() };
const L = {
	resolveDefault: (promise, fallback) => Promise.resolve(promise).catch(() => fallback)
};
const E = function() {
	return { args: Array.from(arguments) };
};
const document = { getElementById: () => null };

const source = fs.readFileSync(filename, 'utf8');
const factory = new Function(
	'view', 'form', 'rpc', 'poll', 'dom', 'ui', 'uci', 'E', 'L', 'document',
	source
);
const page = factory(view, form, rpc, poll, dom, ui, uci, E, L, document);

Promise.resolve(page.render([ null, {} ]))
	.then(() => {
		page.super = (method) => {
			if (method !== 'handleSave')
				throw new Error(`unexpected super method: ${method}`);
			return Promise.resolve();
		};
		page.refresh = () => Promise.resolve();
		return page.handleSave({});
	})
	.then(() => {
		if (applyCalls !== 1)
			throw new Error(`expected one access_apply RPC call, got ${applyCalls}`);
		process.stdout.write('C2000-MAX LuCI access view test passed\n');
	})
	.catch((error) => {
		process.stderr.write(`${error.stack || error}\n`);
		process.exitCode = 1;
	});
