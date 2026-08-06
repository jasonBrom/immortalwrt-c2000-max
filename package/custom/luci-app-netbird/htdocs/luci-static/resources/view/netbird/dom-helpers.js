// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Tailscale Inc & AUTHORS  (attribution retained; see NOTICE)
// Modified from luci-app-tailscale-community@eabe1288afe024566b930b26681a722ccf07b19b
// for luci-app-netbird (2026-04-15)
//
// luci-app-netbird — DOM helpers (XSS 安全的薄包装层)
//
// 背景：禁止的 DOM 写法（原地写入 HTML 字符串 / DOM_UNSAFE_SET / HTML 字符串模板）
//       会让用户可控文本逃逸为 HTML 结构，导致 XSS。
//       本文件所有 helper 走 E() 构造，让浏览器把 children 视作 Text node 自动 escape。
//
// 参考：tailscale-community commit b0b1c99
//
// 暴露方式：LuCI view 内 require('view.netbird.dom-helpers')
//   例：var dom = require('view.netbird.dom-helpers');
//       dom.pair('Interface', 'wt0');
//
// 安全基线（不得违反）：
//   - helper 内部只经 E(tag, attrs, children) 构造 DOM，不使用禁止的 DOM 写法
//   - 所有用户可控值作为 E() 的 children 参数传入，由浏览器当作 Text node 处理
//   - 函数保持无副作用（不触发 rpcd 调用 / 不写 UCI）

'use strict';

'require ui';

// 注入视图样式表(只注一次):nb-pair 标签/值对齐 + nb-pill 配色 + nb-banner。
// 所有 netbird 视图都 require 本模块,故在此集中注入,避免每个视图各自加载。
(function () {
	if (typeof document === 'undefined' || document.getElementById('nb-style'))
		return;
	document.head.appendChild(E('link', {
		'id': 'nb-style',
		'rel': 'stylesheet',
		'href': L.resource('view/netbird/netbird.css')
	}));
})();

/**
 * pair(label, value) — 渲染"标签—值"行
 *
 * 用途：Settings Tab 字段展示、Status Tab 属性列表
 * 返回：<div class="nb-pair">
 *           <span class="nb-pair-label">label</span>
 *           <span class="nb-pair-value">value</span>
 *       </div>
 *
 * 安全保证：label 与 value 均作为 E() children 传入，浏览器自动 escape。
 *
 * @param {string} label  字段名（可翻译字符串）
 * @param {*}      value  字段值（用户可控文本；null/undefined 显示为空字符串）
 * @returns {HTMLElement}
 */
function pair(label, value) {
    return E('div', { 'class': 'nb-pair' }, [
        E('span', { 'class': 'nb-pair-label' }, String(label)),
        E('span', { 'class': 'nb-pair-value' }, value == null ? '' : String(value))
    ]);
}

/**
 * code(text) — 以等宽字体安全回显用户可控文本
 *
 * 用途：日志行、CLI 输出片段、错误消息原文
 * 返回：<code>text</code>
 *
 * 安全保证：text 作为 E() children 传入，DOM_UNSAFE_SET 不发生。
 *
 * @param {*} text  待回显文本（用户可控；null/undefined 显示为空字符串）
 * @returns {HTMLElement}
 */
function code(text) {
    return E('code', {}, text == null ? '' : String(text));
}

/**
 * statusPill(state, label) — 连接状态胶囊
 *
 * 用途：顶部状态条、空态页
 * 返回：<span class="nb-pill nb-pill-<state>">label</span>
 *
 * state 白名单（与下方 WHITELIST 正则一字对齐）：
 *   connected / running        — 已连接 / 服务运行（绿）
 *   connecting                 — 连接进行中（蓝）
 *   disconnected / error       — 已断开 / 运行时错误（红）
 *   needs_login / service_stopped / service_disabled — 需登录 / 已停 / 已禁用（橙）
 *   not_installed              — netbird 二进制未安装（灰）
 *   unknown                    — 降级值（非白名单输入，灰）
 *
 * 安全保证：
 *   1) state 正则白名单防止 CSS class 注入（防御纵深）
 *   2) safeState 作为属性值传入 E()，LuCI 再做一次 escape
 *   3) label 作为 children 传入，浏览器 Text node 处理
 *
 * @param {string} state   状态键（非白名单值降级为 'unknown'）
 * @param {*}      label   显示文字（用户可控；null/undefined 显示为空字符串）
 * @returns {HTMLElement}
 */
function statusPill(state, label) {
    var WHITELIST = /^(connected|connecting|disconnected|error|running|needs_login|service_stopped|not_installed|service_disabled|unknown)$/;
    var safeState = (typeof state === 'string' && WHITELIST.test(state)) ? state : 'unknown';
    return E('span', { 'class': 'nb-pill nb-pill-' + safeState }, label == null ? '' : String(label));
}

return L.Class.extend({
    pair:       pair,
    code:       code,
    statusPill: statusPill
});
