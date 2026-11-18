--- FlyWow 模块间共享的结果表合同；业务载荷由 value 承载，错误诊断由 details 承载。
---@class FlyWowResult<T>
---@field ok boolean 是否成功；调用方必须先检查该字段再读取 value 或错误字段。
---@field value? T 成功时的类型化载荷；成功载荷允许为 nil，需按具体 API 合同判断。
---@field code? string 失败时的稳定机器错误码；由所属模块定义，不解析 message。
---@field message? string 失败诊断文本；只供日志和排查，不用于业务分支。
---@field details? table 模块专属的结构化诊断；不扩展公共顶层字段。
local M = {}

--- 构造成功结果；value 可为 nil，调用方以 ok 判断成功。
---@generic T
---@param value? T 成功载荷
---@return FlyWowResult<T> ok 为 true；调用方从 value 取得载荷。
function M.success(value)
    return {ok = true, value = value}
end

--- 构造失败结果；code 稳定，message 仅用于诊断。
---@param code string 所属模块定义的稳定错误码
---@param message string 诊断文本
---@param details? table 模块专属的结构化诊断
---@return FlyWowResult<nil> ok 为 false；调用方按 code 分支，message 和 details 用于排查。
function M.failure(code, message, details)
    return {ok = false, code = code, message = message, details = details}
end

--- 将 Result 转成日志文本；Worker 本地结果和跨 Service 收到的结果都可使用。
---@generic T
---@param result FlyWowResult<T> 需要记录的结果。
---@return string 成功时返回 "ok"；失败时返回错误码和诊断消息。
function M.to_string(result)
    if result.ok then
        return "ok"
    end

    return string.format("%s: %s", result.code, result.message)
end

return M
