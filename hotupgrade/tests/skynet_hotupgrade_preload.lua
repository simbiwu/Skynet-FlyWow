--- 原生 loader 在受管理和普通入口执行 preload，入口名不经重写。
local service_name = ...
assert(service_name == "skynet_hotupgrade_worker" or service_name == "skynet_hotupgrade_unique_a")
hotupgrade_preload_seen = true
