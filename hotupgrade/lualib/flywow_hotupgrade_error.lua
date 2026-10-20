--- 热更跨模块/Service 的统一结果；诊断文本不能代替稳定错误码。
local M = {}

---@class FlyWowHotUpgradeResult
---@field ok boolean 是否成功
---@field code? string 稳定 HU_ 错误码；HU_RECOVERY_REQUIRED 表示不可确认恢复
---@field message? string 诊断信息
---@field batch_id? string 当前 Controller 生命周期内的升级批次身份
---@field handle? integer 受管理创建成功返回的真实 Service handle
---@field permit_id? string 首次模块加载成功申请的进程内许可 ID
---@field lifecycle? FlyWowHotUpgradeLifecycleStatus status 返回的生命周期概览

---@param code string 稳定错误码
---@param message string 诊断信息
---@param step? string 失败阶段
---@return FlyWowHotUpgradeResult
function M.failure(code, message, step)
    return {ok = false, code = code, message = message, step = step}
end

---@param result_payload? table 要补充成功标记的结果 record
---@return FlyWowHotUpgradeResult
function M.success(result_payload)
    result_payload = result_payload or {}
    result_payload.ok = true
    return result_payload
end

return M
