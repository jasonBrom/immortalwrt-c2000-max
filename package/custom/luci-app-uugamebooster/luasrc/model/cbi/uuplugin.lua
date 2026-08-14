require("luci.util")

mp = Map("uuplugin")
mp.title = translate("网易UU游戏加速器")
mp.description = translate("默认使用已在 C2000MAX 实机验证的网易 H3C NX30 Pro 核心；遇到兼容性问题时，可手动切换网易官方 OpenWrt aarch64 通用核心。开启后请在 UU 主机加速 APP 中绑定路由器并选择需要加速的设备。")

warning = mp:section(SimpleSection)
warning.description = translate("重要：启用 UU 时会临时禁用软件流量卸载和 MediaTek HNAT，避免游戏流量绕过 UU 的 TUN 与防火墙规则。关闭“启用”后，系统会恢复启用 UU 前保存的加速设置；若规则清理失败则保持禁用，以保证网络稳定。")

mp:section(SimpleSection).template  = "uuplugin/uuplugin_status"

s = mp:section(TypedSection, "uuplugin")
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用"))
o.default = 0
o.optional = false

o = s:option(ListValue, "platform", translate("核心平台"))
o:value("h3c-nx30pro", translate("H3C NX30 Pro（C2000MAX 实机验证，推荐）"))
o:value("openwrt-aarch64", translate("OpenWrt aarch64（官方通用回退）"))
o.default = "h3c-nx30pro"
o.rmempty = false
o.description = translate("两个选项均只下载网易官方核心，不修改核心二进制。H3C 模式使用官方 H3C 主程序，并从官方 OpenWrt 包中取得已校验的 xtables 兼容组件；通用模式完整使用官方 OpenWrt aarch64 包。切换核心时会先停止旧进程并清理旧规则。")

function mp.on_after_commit(self)
	luci.sys.call("/etc/init.d/uuplugin restart >/dev/null 2>&1")
end

mp:section(SimpleSection).template  = "uuplugin/uuplugin_qcode"

return mp
