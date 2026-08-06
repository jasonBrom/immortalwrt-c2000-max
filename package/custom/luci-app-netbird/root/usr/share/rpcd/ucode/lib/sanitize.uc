// SPDX-License-Identifier: Apache-2.0
//
// Canonical runtime path: /usr/share/rpcd/ucode/lib/sanitize.uc
// Repo canonical source:  root/usr/share/rpcd/ucode/lib/sanitize.uc
//
// sanitize.uc — 敏感字段脱敏集中入口 + settings 类型规整
// 安全基线：任何跨 rpcd↔browser 边界的 settings dict 都必须经此函数，
//       返回 dict 绝不含字面量 preshared_key 键；仅允许 preshared_key_configured:boolean；
//       绝不回 setup_key（原始 setup_key 本就不在 UCI，此处亦不读不回）。
//       改动 2：透传 setup_key_hint（非机密——已消费 key 的打码前缀，详见 netbird.uc
//       _mask_setup_key 注释）；这与「绝不回原始 setup_key」不冲突，hint ≠ 完整密钥。
//       CI 扫描会检查源码，违规即 CI 红。
//
// 字段语义：UCI 一律存「正向 / UI 语义」（勾选=1=启用）。取反（disable_*/block_*）
//       只在 /etc/init.d/netbird-settings 渲染 `netbird up` flag 时发生，sanitize 不取反。
//
// module-compat：本文件作为 ucode 模块经 loadfile()() 加载，返回 { sanitize_settings }。

// _b(v) —— UCI 布尔规整：'1' / 1 / true → true；其余（含 '0' / 空 / null）→ false。
function _b(v) {
    return v === '1' || v === 1 || v === true;
}

// _bd(v, dflt) —— 带默认的布尔规整：缺省（null/未设置）回退 dflt，已设置按 _b 解析。
// 用于「默认开」的字段（enable_firewall / access_lan / enable_ipv6 等），区分
// 「未配置」与「显式关闭」：UCI 缺字段时不应误判为 false。
function _bd(v, dflt) {
    if (v == null)
        return dflt;
    return _b(v);
}

// _port(v) —— WireGuard 端口规整：取整后限制 1..65535；非法回退 51820。
function _port(v) {
    let n = +v;
    if (n == null || n != n || n < 1 || n > 65535)
        return 51820;
    return n;
}

// _log_level(v) —— 日志级别枚举校验；非枚举回退 'info'。
// netbird 官方实用集 5 级（trace/debug/info/warn/error，docs.netbird.io troubleshooting）；
// 与设置页 ListValue + 日志页严重性筛选同用这 5 级。panic/fatal 是 logrus 内部级别，
// 守护进程用不到，不暴露也不接受（统一 5 级，非枚举一律回退 info）。
const _LOG_LEVELS = {
    error: true, warn: true, info: true, debug: true, trace: true,
};
function _log_level(v) {
    if (type(v) == 'string' && _LOG_LEVELS[v])
        return v;
    return 'info';
}

// sanitize_settings(raw) —— 把 UCI 原值字典脱敏 + 类型规整 + 补齐默认值。
// 输入：任意 dict（允许空对象 {}）
// 输出：标准 settings dict（全正向 / UI 语义），不含 preshared_key 字面键、不含 setup_key。
//   默认值与 root/etc/config/netbird 一致：enable_dns 默认 false（OpenWRT 避 53 冲突）；
//   enable_firewall / access_lan / accept_client_routes / accept_server_routes / enable_ipv6 /
//   enable_ssh_auth / service_enabled 默认 true；其余开关默认 false。
function sanitize_settings(raw) {
    if (raw == null)
        raw = {};

    // PSK 是否已配置：UCI 值非空即视为 configured，原文**绝不**回传（密钥绝不入边界）。
    // 消费链：settings.js write-only 字段写 UCI → init.d _render_and_apply 渲染
    //   --preshared-key（其值不进日志串，PSK 不入 logread）。本函数仅向前端回布尔，供占位提示用。
    let psk_configured = (raw.preshared_key != null && raw.preshared_key !== '');

    return {
        // 常规
        service_enabled:       _bd(raw.service_enabled, true),
        wireguard_port:        _port(raw.wireguard_port),
        interface_name:        raw.interface_name || 'wt0',
        hostname:              raw.hostname || '',
        management_url:        raw.management_url || '',
        // 防火墙
        enable_firewall:       _bd(raw.enable_firewall, true),
        block_inbound:         _b(raw.block_inbound),
        // SSH
        allow_ssh:             _b(raw.allow_ssh),
        ssh_root:              _b(raw.ssh_root),
        ssh_sftp:              _b(raw.ssh_sftp),
        ssh_local_fwd:         _b(raw.ssh_local_fwd),
        ssh_remote_fwd:        _b(raw.ssh_remote_fwd),
        enable_ssh_auth:       _bd(raw.enable_ssh_auth, true),
        // DNS（OpenWRT 默认关）
        enable_dns:            _b(raw.enable_dns),
        // 路由
        access_lan:            _bd(raw.access_lan, true),
        accept_client_routes:  _bd(raw.accept_client_routes, true),
        accept_server_routes:  _bd(raw.accept_server_routes, true),
        // IPv6
        enable_ipv6:           _bd(raw.enable_ipv6, true),
        // 后量子
        rosenpass_enabled:     _b(raw.rosenpass_enabled),
        rosenpass_permissive:  _b(raw.rosenpass_permissive),
        // 日志
        log_level:             _log_level(raw.log_level),
        // 敏感：仅回是否已配置布尔；原文绝不回传
        preshared_key_configured: psk_configured,
        // 改动 2：安装密钥打码 hint（非机密——已消费 key 的部分前缀；无则空串）。
        // 仅透传 UCI 既有打码串，绝不构造/回传原始 setup_key。
        setup_key_hint:        (type(raw.setup_key_hint) == 'string') ? raw.setup_key_hint : '',
    };
}

return { sanitize_settings };
