module("luci.controller.acc", package.seeall)

function index()
  entry({ "admin", "services", "acc" }, alias("admin", "services", "acc", "service"), "雷神加速器", 50)
  entry({ "admin", "services", "acc", "service" }, cbi("leigod/service"), "基本设置", 30)
  entry({ "admin", "services", "acc", "device" }, cbi("leigod/device"), "设备管理", 50)
  entry({ "admin", "services", "acc", "app" }, cbi("leigod/app"), "客户端", 60)
  entry({ "admin", "services", "acc", "notice" }, cbi("leigod/notice"), "使用说明", 80)
  entry({ "admin", "services", "acc", "status" }, call("get_acc_status")).leaf = true
end

-- get_acc_status get acc status
function get_acc_status()
  -- util module
  local util      = require "luci.util"
  local uci       = require "luci.model.uci".cursor()
  -- init result
  local resp      = {}
  -- init state
  resp.service    = "加速服务未启动"
  resp.state      = {}
  -- check if exist
  local exist     = util.exec("ps | grep acc-gw | grep -v grep")
  -- check if program is running
  if exist ~= "" then
    resp.service = "加速服务已启动"
  end
  for _, typ in pairs({ "Phone", "PC", "Game", "Unknown" }) do
    local state = uci:get("accelerator", typ, "state")
    -- check state
    local state_text = "未加速"
    if state == nil or state == '0' then
    elseif state == '1' then
      state_text = "已开始加速"
    elseif state == '2' then
      state_text = "已停止加速"
    elseif state == '3' then
      state_text = "加速已暂停"
    end
    -- store text
    local catalog_name = {
      Phone = "手机设备",
      PC = "电脑设备",
      Game = "游戏主机",
      Unknown = "其他设备"
    }
    resp.state[catalog_name[typ]] = state_text
  end
  luci.http.prepare_content("application/json")
  luci.http.write_json(resp)
end
