--- 证明受管理入口必须在 preload 执行前拒绝，普通原生 Service 仍执行 preload。
local service_name = ...
assert(service_name ~= "flywow_hotupgrade_bootstrap", "preload 不得看到内部 Bootstrap")
hotupgrade_preload_seen = true
