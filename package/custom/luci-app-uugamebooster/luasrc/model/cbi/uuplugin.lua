require("luci.util")

mp = Map("uuplugin")
mp.title = translate("网易UU游戏加速器")
mp.description = translate("默认使用经过 C2000MAX PC 能力适配的网易 OpenWrt aarch64 核心，也可选择 H3C NX30 Pro 专用核心进行兼容性实验。开启服务后，请在 UU 主机加速 APP 中绑定路由器并选择需要加速的设备。")

mp:section(SimpleSection).template  = "uuplugin/uuplugin_status"

s = mp:section(TypedSection, "uuplugin")
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用"))
o.default = 0
o.optional = false

o = s:option(ListValue, "platform", translate("核心平台"))
o:value("openwrt-aarch64", translate("OpenWrt aarch64（C2000MAX PC 适配，推荐）"))
o:value("h3c-nx30pro", translate("H3C NX30 Pro（实验）"))
o.default = "openwrt-aarch64"
o.rmempty = false
o.description = translate("推荐项仍下载网易通用 OpenWrt aarch64 核心并使用其自带 xtables、TUN、nft 与 conntrack 后端，只将连接时的合作平台能力标识适配为可识别 PC 的路由器类型；升级检查和代理请求继续使用 openwrt-aarch64。补丁绑定已验证核心的 SHA-256，网易更新核心后会安全停止而不会盲目修改。H3C 核心仍仅为兼容性实验，依赖 C2000MAX 不提供的 /dev/natflushdev 和 /usr/bin/uuclearnat。切换时服务会停止并清理旧规则和旧核心文件。")

function mp.on_after_commit(self)
	luci.sys.call("/etc/init.d/uuplugin restart >/dev/null 2>&1")
end

mp:section(SimpleSection).template  = "uuplugin/uuplugin_qcode"

return mp
