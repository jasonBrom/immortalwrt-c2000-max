require("luci.util")

mp = Map("accelerator")
mp.title = "雷神加速器客户端"
mp.description = "请使用雷神加速器官方客户端登录、购买时长并绑定路由器。"

mp:section(SimpleSection).template  = "leigod/app"

return mp
