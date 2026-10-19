--- 热更跨模块/Service 的统一结果；诊断文本不能代替稳定错误码。
local M = {}

---@class FlyWowHotUpgradeResult
---@field ok boolean 是否成功
---@field code? string 稳定 HU_ 错误码；HU_RECOVERY_REQUIRED 表示不可确认恢复
---@field message? string 诊断信息
---@field txn_id? string 当前 Controller 生命周期内的事务身份

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
