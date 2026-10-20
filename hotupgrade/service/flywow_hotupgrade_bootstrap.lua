--- 内部受管理启动入口：先绑定创建身份，再复用宿主 Skynet loader 加载真实 Service。
--- 业务入口收到原始参数及 SERVICE_NAME/SERVICE_PATH；不调用 skynet.start，不接管业务 init。
local controller_handle, creation_id, service_name = ...
local skynet = require "skynet"
local creation = require "flywow_hotupgrade_creation"

creation.initialize(assert(tonumber(controller_handle)), creation_id)

-- 若首轮 loader 加入了引导专属搜索前缀，移除后让同一 loader 加入真实业务目录。
local bootstrap_prefix = SERVICE_PATH .. "?.lua;"
local business_path = package.path
if business_path:sub(1, #bootstrap_prefix) == bootstrap_prefix then
    business_path = business_path:sub(#bootstrap_prefix + 1)
end

LUA_PATH = business_path
LUA_CPATH = package.cpath
LUA_SERVICE = skynet.getenv("luaservice") or "./service/?.lua"
-- Controller 已在原生启动前拒绝非空 preload；此处不执行第二次 preload。
LUA_PRELOAD = nil
local loader = assert(loadfile(skynet.getenv("lualoader") or "./lualib/loader.lua"))
-- 原生 newservice 本来就把参数转成空白分隔 token；这里仅移除三个内部身份参数。
local arguments = {service_name, select(4, ...)}
loader(table.concat(arguments, " "))
