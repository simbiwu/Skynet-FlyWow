---@meta

--- Controller、Service 热更入口和模块更新逻辑共同使用的数据合同。

---@class FlyWowHotUpgradeTargetMetadata
---@field module_paths string[] 当前 State 已声明模块的宿主相对文件路径数组
---@field has_service_update boolean 是否在本 State 提供私有状态及函数更新入口

---@class FlyWowHotUpgradeModulePatch
---@field name string 目标 Lua State 的缓存别名；如 lualib/player.lua 对应 lualib.player
---@field host_relative_path string 相对宿主根的真实文件路径；Controller 按它匹配，目标按它取得原加载参数
---@field source string 本批读取并固定的模块源码，随 Update 发给匹配 Service

---@class FlyWowHotUpgradeControlRequest
---@field batch_id string Controller Service handle 与本进程递增序号组成；仅在该 Controller 生命周期有效
---@field modules? FlyWowHotUpgradeModulePatch[] Controller 按目标已登记文件筛选、按缓存别名排序的候选；不含业务对象
---@field service_patch_source? string Update 请求携带的 Service .patch 源码；没有匹配的 Service Patch 时为 nil

---@class FlyWowHotUpgradeModuleStage
---@field entries table[] 本 State 每个候选模块的旧字段与新字段记录；Commit/Abort 处理，Finish 释放。
