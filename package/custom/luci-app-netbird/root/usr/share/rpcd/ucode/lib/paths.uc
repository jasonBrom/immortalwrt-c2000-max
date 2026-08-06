// SPDX-License-Identifier: Apache-2.0
//
// Canonical runtime path: /usr/share/rpcd/ucode/lib/paths.uc
// Repo canonical source:  root/usr/share/rpcd/ucode/lib/paths.uc
//
// paths.uc — netbird binary 路径动态探测
// 约定：/usr/bin/netbird 为 openwrt/packages 官方路径（优先），/usr/sbin/netbird
// 为历史 target 回退。
// 两路径都不 access() 可执行则返回 null，触发 5 态判定的 not_installed 态。
//
// module-compat：本文件作为 ucode 模块经 loadfile()() 加载，返回 { resolve_netbird_bin }。

import { access } from 'fs';

// 返回 netbird 可执行文件绝对路径；找不到返 null。
// 顺序：/usr/bin/netbird → /usr/sbin/netbird（首个 access(x) 命中即返回）。
function resolve_netbird_bin() {
    for (let p in ['/usr/bin/netbird', '/usr/sbin/netbird'])
        if (access(p, 'x'))
            return p;
    return null;
}

return { resolve_netbird_bin };
