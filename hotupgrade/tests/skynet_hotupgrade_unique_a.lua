--- 唯一服务逻辑名夹具；业务仍在本 Lua State 执行。
return assert(loadfile(SERVICE_PATH .. "skynet_hotupgrade_worker.lua"))(...)
