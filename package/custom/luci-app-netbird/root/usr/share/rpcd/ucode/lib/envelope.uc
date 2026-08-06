// SPDX-License-Identifier: Apache-2.0
//
// Canonical runtime path: /usr/share/rpcd/ucode/lib/envelope.uc
// Repo canonical source:  root/usr/share/rpcd/ucode/lib/envelope.uc
//
// envelope.uc — rpcd 统一返回信封 + CODE 枚举
// 约定：
//   ok(data)              → { ok: true,  data: <data> }
//   err(code, msg, hint?) → { ok: false, code, message, hint? }
// 调用 err() 必须用 CODE 常量；传入非枚举值直接 die() 抛错，阻止后续
// 悄悄引入未注册的 code 值。
//
// module-compat：本文件作为 ucode 模块经 loadfile()() 加载，返回 { ok, err, CODE }。
//
// 例外：get_status 方法永远返回 ok:true，5 态统一以 data.status 暴露。

// CODE 枚举：空态系 + 运行时系 + 写操作系
const CODE = {
    // 空态系（5 态）
    NOT_INSTALLED:     'not_installed',
    SERVICE_DISABLED:  'service_disabled',
    SERVICE_STOPPED:   'service_stopped',
    NEEDS_LOGIN:       'needs_login',
    // 运行时系
    CLI_ERROR:         'cli_error',
    PARSE_ERROR:       'parse_error',
    INTERNAL_ERROR:    'internal_error',
    PERMISSION_DENIED: 'permission_denied',
    INVALID_INPUT:     'invalid_input',
    // 写操作系（当前仅 do_enable_and_start 用）
    ENABLE_FAILED:     'enable_failed',
    START_FAILED:      'start_failed',
    ALREADY_RUNNING:   'already_running',
    // 认证系（do_up/do_login 连接超时）
    CONNECT_FAILED:    'connect_failed',
    // 二进制管理系（update_binary：下载/校验/安装官方最新二进制）
    DOWNLOAD_FAILED:   'download_failed',
    DOWNLOAD_CANCELED: 'download_canceled',
    CHECKSUM_MISMATCH: 'checksum_mismatch',
    INSTALL_FAILED:    'install_failed',
    INSUFFICIENT_SPACE: 'insufficient_space',   // overlay 空间不足(下载/写二进制);前端按 code 本地化「删旧版本」提示
    // 二进制来源管理系（update_binary/set_binary_source：架构不符/坏包）
    ARCH_MISMATCH:     'arch_mismatch',
};

// 已知合法 code 集合：从 CODE 派生（值即合法 code），用于 err() 白名单校验，遇到未知 code die()。
// 派生而非手列第二份：杜绝「往 CODE 加了 code 却漏进白名单 → err() 运行时 die()」的双表漂移。
const _VALID_CODES = {};
for (let _k in CODE)
    _VALID_CODES[CODE[_k]] = true;

// 成功信封：{ ok: true, data: <任意对象> }
function ok(data) {
    return { ok: true, data: data };
}

// 失败信封：{ ok: false, code, message, hint? }
// code 必须是 CODE 枚举值之一；否则 die（契约违规立即崩溃，避免噪声错误流入前端）
function err(code, message, hint) {
    if (!_VALID_CODES[code])
        die(sprintf('envelope.err: illegal code "%s" (not in CODE enum)', code));
    let out = { ok: false, code: code, message: message };
    if (hint != null)
        out.hint = hint;
    return out;
}

return { ok, err, CODE };
