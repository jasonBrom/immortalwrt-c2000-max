require("luci.util")

mp = Map("uuplugin")
mp.title = translate("网易UU游戏加速器")
mp.description = translate("可选择网易官方 OpenWrt aarch64 核心或 H3C NX30 Pro 专用核心。开启服务后，请在 UU 主机加速 APP 中绑定路由器并选择需要加速的设备。")

mp:section(SimpleSection).template  = "uuplugin/uuplugin_status"

s = mp:section(TypedSection, "uuplugin")
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用"))
o.default = 0
o.optional = false

o = s:option(ListValue, "platform", translate("核心平台"))
o:value("openwrt-aarch64", translate("OpenWrt aarch64（推荐）"))
o:value("h3c-nx30pro", translate("H3C NX30 Pro（实验）"))
o.default = "openwrt-aarch64"
o.rmempty = false
o.description = translate("推荐核心由网易为通用 OpenWrt aarch64 发布，并自带匹配的 xtables。H3C 核心仅为兼容性实验，依赖 NX30 Pro 固件中的 /dev/natflushdev 和 /usr/bin/uuclearnat；C2000MAX 不提供这些接口，透明代理初始化可能失败。切换时服务会停止，并清理旧规则和旧核心文件后重新下载所选平台的完整包。")

function mp.on_after_commit(self)
	luci.sys.call("/etc/init.d/uuplugin restart >/dev/null 2>&1")
end

mp:section(SimpleSection).template  = "uuplugin/uuplugin_qcode"

return mp
