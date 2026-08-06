// SPDX-License-Identifier: Apache-2.0
//
// Canonical runtime path: /usr/share/rpcd/ucode/lib/state.uc
// Repo canonical source:  root/usr/share/rpcd/ucode/lib/state.uc
//
// state.uc — 5 态判定算法（runtime-first）
//
// 关键设计：
//   旧顺序：bin → enabled → running → needs_login → running
//   新顺序：bin → runtime(ubus/pgrep) → needs_login(running 子分支) → enabled
//   原因：service disabled 但用户手动 netbird service run 在旧顺序下被误判为
//   service_disabled 空态；改为 runtime-first 后，service_disabled
//   只在 (!running && !enabled) 时返回。
//
// 返回纯 dict（不套信封）：
//   { status: <5 态字面量>, bin_path: <string|null>, init_enabled?, init_running?, raw_text? }
//
// module-compat：作为 ucode 模块经 loadfile()() 加载，返回 { probe_state }。
// 依赖 paths/netbird_cli/shell 也走 loadfile，路径 NBLIB env override。

import { popen, access } from 'fs';

const _LIB = getenv('NBLIB') || '/usr/share/rpcd/ucode/lib';
let _paths = loadfile(_LIB + '/paths.uc')();
let _cli = loadfile(_LIB + '/netbird_cli.uc')();
let _shell = loadfile(_LIB + '/shell.uc')();
let resolve_netbird_bin = _paths.resolve_netbird_bin;
let classify_status_text = _cli.classify_status_text;
let probe_running_via_ubus = _cli.probe_running_via_ubus;
let shell_quote = _shell.shell_quote;

// _HAS_TIMEOUT：BusyBox 1.36.1 默认未携带 timeout applet；
// 缺失时降级为透传命令。C2000-MAX 固件提供 coreutils-timeout。
const _HAS_TIMEOUT = access('/usr/bin/timeout', 'x') || access('/bin/timeout', 'x');

function _t(cmd) {
    if (_HAS_TIMEOUT)
        return 'timeout 2s ' + cmd;
    return cmd;
}

// ============================================================================
// probe_state(fast) —— 5 态判定（runtime-first）
// ============================================================================
// 返回 { status, bin_path, init_enabled?, init_running?, raw_text? }
//
// 顺序（短路）：
//   step 1. resolve_netbird_bin() == null → 'not_installed'
//   step 2. ubus probe_running_via_ubus() 主判定 → running_flag
//           pgrep -f '^<bin> service run' 兜底（procd 读不到 pidfile 时）
//   step 3. running_flag == true → 跑 `<bin> status`（不带 --json），文本分类：
//             - classify_status_text() 命中 → 'needs_login'
//             - 否则 → 'running'
//   step 4. running_flag == false → 判 /etc/init.d/netbird enabled 退出码：
//             - 非 0 → 'service_disabled'  (!running && !enabled)
//             - 0    → 'service_stopped'   (!running && enabled)
//
// 不抛异常；任何子进程异常返保守上位（false / 空串）以保证返回结构稳定。
function probe_state(fast) {
    // step 1: binary 路径探测
    let bin = resolve_netbird_bin();
    if (bin == null)
        return { status: 'not_installed', bin_path: null };

    // step 2: runtime-first（ubus 主 + pgrep 兜底）
    let ub = probe_running_via_ubus();
    let running_flag = !!ub.running;

    if (!running_flag) {
        // pgrep 兜底：BusyBox pgrep -f 锚定 '^<bin> service run'
        // shell_quote 包模式串防注入；timeout 2s 防 hang；rc==0 即命中。
        let pgrep_pat = '^' + bin + ' service run';
        let pg_cmd = _t('pgrep -f ' + shell_quote(pgrep_pat) + ' >/dev/null 2>&1');
        let pg_rc = system(pg_cmd);
        if (pg_rc == 0)
            running_flag = true;
    }

    // step 3: running 子分支 → needs_login 文本分类 vs running
    if (running_flag) {
        // LuCI 的常规状态请求只需要知道 procd 实例已经运行。启动期间
        // `netbird status` 可能等待 daemon 数秒，而 rpcd 是单线程的；在这里
        // 同步等待会让所有 LuCI 页面一起排队。fast=true 时直接返回运行态，
        // 连接详情由有独立短超时的 status --json 方法按需获取。
        if (fast) {
            return {
                status: 'running',
                bin_path: bin,
                init_enabled: true,
                init_running: true,
            };
        }
        // 跑 `<bin> status`（不带 --json）
        let status_cmd = _t(shell_quote(bin) + ' status 2>&1');
        let fd = popen(status_cmd, 'r');
        let stdout = '';
        if (fd != null) {
            stdout = fd.read('all') || '';
            fd.close();
        }
        let raw = substr(stdout, 0, 512);
        if (classify_status_text(raw) == 'needs_login') {
            return {
                status: 'needs_login',
                bin_path: bin,
                init_enabled: true,    // procd 在跑 → init 必然 enabled or 用户 manual run
                init_running: true,
                raw_text: trim(raw),
            };
        }
        return {
            status: 'running',
            bin_path: bin,
            init_enabled: true,
            init_running: true,
        };
    }

    // step 4: 非 running → /etc/init.d/netbird enabled 区分 disabled vs stopped
    // 注：/etc/init.d/netbird enabled 不接用户输入，命令字面安全；timeout 2s 防 hang。
    let en_rc = system(_t('/etc/init.d/netbird enabled'));
    if (en_rc != 0) {
        return {
            status: 'service_disabled',
            bin_path: bin,
            init_enabled: false,
            init_running: false,
        };
    }
    return {
        status: 'service_stopped',
        bin_path: bin,
        init_enabled: true,
        init_running: false,
    };
}

return { probe_state };
