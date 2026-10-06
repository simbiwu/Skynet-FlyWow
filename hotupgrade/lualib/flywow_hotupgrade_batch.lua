--- 稳定灰度选择；按逻辑类型与 ID 哈希，不使用随机选择。
local native = require "flywow_hotupgrade_native"
local result = require "flywow_hotupgrade_error"
local M = {}

---@param patch_id string 发布身份
---@param records table[] 注册目标快照
---@param selector table all/ids/percent/exclude
---@return flywow_hotupgrade_result
function M.select(patch_id, records, selector)
    selector = selector or {all = true}
    if selector.percent and (selector.percent < 0 or selector.percent > 1) then
        return result.failure("HU_INVALID_SELECTOR", "percent 范围是 0..1")
    end
    local ids, excluded, chosen = {}, {}, {}
    for _, id in ipairs(selector.ids or {}) do ids[tostring(id)] = true end
    for _, id in ipairs(selector.exclude or {}) do excluded[tostring(id)] = true end
    for _, record in ipairs(records) do
        local hash = native.sha256(patch_id .. ":" .. record.key)
        local ratio = tonumber(hash:sub(1, 8), 16) / 4294967296
        local selected = selector.all or ids[tostring(record.service_id)]
            or (selector.percent and ratio < selector.percent)
        if selected and not excluded[tostring(record.service_id)] then chosen[#chosen + 1] = record end
    end
    table.sort(chosen, function(a, b) return a.key < b.key end)
    return result.success({records = chosen})
end

return M
