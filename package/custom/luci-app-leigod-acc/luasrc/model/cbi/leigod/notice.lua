local uci                         = require "luci.model.uci".cursor()

-- config
m                                 = Map("accelerator")
m.title                           = "雷神加速器使用说明"
m.description                     = "配置设备前请先阅读运行方式、兼容性与隐私说明。"

m:section(SimpleSection).template = "leigod/notice"

return m
