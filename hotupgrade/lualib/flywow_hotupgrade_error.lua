--- 热更跨模块/Service 的统一结果；诊断文本不能代替稳定错误码。
local M = {}

---@class FlyWowHotUpgradeResult
---@field ok boolean 是否成功
---@field code? string 稳定 HU_ 错误码；HU_RECOVERY_REQUIRED 表示不可确认恢复
---@field cause_code? string 阶段失败中的稳定根因码；调用方不解析 message。
---@field message? string 供日志展示的失败上下文；调用方按 code/cause_code 分支，不解析该文本。
---@field original_error? FlyWowHotUpgradeResult 恢复失败前的原始更新错误
---@field recovery_error? FlyWowHotUpgradeResult 目标 Abort 恢复失败的独立诊断
---@field batch_id? string 当前 Controller 生命周期内的升级批次身份
---@field service_handle? integer 受管理创建成功返回的真实 Service handle
---@field permit_id? string 首次模块加载成功申请的进程内许可 ID
---@field lifecycle? FlyWowHotUpgradeLifecycleStatus status 返回的生命周期概览
---@field record? FlyWowHotUpgradeBatchStatus status 返回的批次状态记录

--- 构造失败结果；只打包诊断，恢复或门禁处理由调用方负责。
---@param code string 稳定错误码
---@param message string 诊断信息
---@param step? string 失败阶段
---@param cause_code? string 已知的稳定根因码
---@return FlyWowHotUpgradeResult
function M.failure(code, message, step, cause_code)
    return {ok = false, code = code, message = message, step = step, cause_code = cause_code}
end

--- 为调用方提供的结果 record 原地补充 ok=true，并返回同一张表。
---@param result_payload? table 要补充成功标记的结果 record
---@return FlyWowHotUpgradeResult
function M.success(result_payload)
    result_payload = result_payload or {}
    result_payload.ok = true
    return result_payload
end

return M
