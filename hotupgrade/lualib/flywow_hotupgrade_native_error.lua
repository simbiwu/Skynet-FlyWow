-- 将 Native Binding 的结构化错误转换为 HotUpgrade 内部稳定错误码。
local M = {}

---@param value any Native 的第二返回值
---@return string
function M.code(value)
    if type(value) == "table" then return value.code or "HU_NATIVE_ERROR" end
    return value or "HU_NATIVE_ERROR"
end

return M
