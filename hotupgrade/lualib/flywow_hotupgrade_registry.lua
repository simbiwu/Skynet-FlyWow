--- 逻辑实例和代际访问者索引；声明依赖就保留访问资格，保护迟到访问。
local result = require "flywow_hotupgrade_error"
local M = {}
local Registry = {}
Registry.__index = Registry

---@param service_type string 类型
---@param service_id string|integer 逻辑 ID
---@return string 无歧义内部索引
function M.key(service_type, service_id)
    return #service_type .. ":" .. service_type .. ":" .. type(service_id) .. ":" .. tostring(service_id)
end

---@return table 仅由控制面拥有
function M.new()
    return setmetatable({targets = {}, callers = {}, revision = 0}, Registry)
end

---@param record table key/address/generation/code_version/dependencies/candidate
---@return flywow_hotupgrade_result
function Registry:register(record)
    local target = self.targets[record.key]
    if not target then
        target = {instances = {}}
        self.targets[record.key] = target
    end
    if target.instances[record.generation] then
        return result.failure("HU_DUPLICATE_SERVICE", record.key)
    end
    local instance = {record = record, visitors = {}, inflight = 0, state = "READY"}
    target.instances[record.generation] = instance
    if not record.candidate then target.current = record.generation end
    self.revision = self.revision + 1
    return result.success()
end

---@param caller string 注册实例身份
---@param dependencies table[] target/edge/cross_generation
---@return flywow_hotupgrade_result
function Registry:declare(caller, dependencies, generations)
    if self.callers[caller] then
        return result.failure("HU_DUPLICATE_SERVICE", caller)
    end
    local bindings = {}
    for _, edge in ipairs(dependencies or {}) do
        local target = self.targets[edge.target]
        if not target or not target.current then
            return result.failure("HU_DEPENDENCY_MISSING", edge.target)
        end
        local generation = (generations or {})[edge.target] or target.current
        if not target.instances[generation] then
            return result.failure("HU_DEPENDENCY_MISSING", edge.target)
        end
        bindings[edge.target] = {generation = generation, edge = edge.edge or "strong",
            cross_generation = edge.cross_generation == true}
    end

    self.callers[caller] = bindings
    for key, binding in pairs(bindings) do
        self.targets[key].instances[binding.generation].visitors[caller] = binding.edge
    end
    return result.success()
end

---@param caller string 实例身份
---@param key string target
---@return flywow_hotupgrade_result
function Registry:resolve(caller, key)
    local binding = self.callers[caller] and self.callers[caller][key]
    if not binding then
        return result.failure("HU_UNDECLARED_DEPENDENCY", key)
    end
    local target = self.targets[key]
    local instance = target and target.instances[binding.generation]
    if not instance then return result.failure("HU_TARGET_RETIRED", key) end
    return result.success({record = instance.record, revision = self.revision})
end

--- 显式取得一个本地引用；首次调用前的声明仍保留访问资格。
function Registry:acquire(caller, key, ref_id)
    local resolved = self:resolve(caller, key)
    if not resolved.ok then return resolved end
    local binding = self.callers[caller][key]
    binding.leases = binding.leases or {}
    binding.leases[ref_id] = true
    return resolved
end

--- 目标屏障已完成才调用；最后一个引用释放时撤销本实例的依赖资格。
function Registry:release_binding(caller, key, ref_id)
    local bindings = self.callers[caller]
    local binding = bindings and bindings[key]
    if not binding or not binding.leases or not binding.leases[ref_id] then return result.success() end
    binding.leases[ref_id] = nil
    if next(binding.leases) == nil then
        local target = self.targets[key]
        local instance = target and target.instances[binding.generation]
        if instance then instance.visitors[caller] = nil end
        bindings[key] = nil
    end
    return result.success()
end

---@param key string target
---@param expected integer 当前代际
---@param generation integer 候选代际
---@return flywow_hotupgrade_result
function Registry:publish(key, expected, generation)
    local target = self.targets[key]
    if not target or target.current ~= expected or not target.instances[generation] then
        return result.failure("HU_ROUTE_SWITCH_FAILED", "代际比较失败")
    end
    target.current = generation
    self.revision = self.revision + 1
    return result.success()
end

--- 只允许明确兼容且调用者已到安全点的跨代切换。
---@param caller string owner
---@param key string target
---@param can_switch boolean 调用方安全条件
---@return flywow_hotupgrade_result
function Registry:switch(caller, key, can_switch)
    local binding = self.callers[caller] and self.callers[caller][key]
    if not binding or not can_switch then
        return result.failure("HU_SWITCH_BLOCKED", key)
    end
    local lease_count = 0
    for _ in pairs(binding.leases or {}) do lease_count = lease_count + 1 end
    if lease_count > 1 then
        return result.failure("HU_SWITCH_BLOCKED", "同一依赖仍有其它引用")
    end
    local target = self.targets[key]
    if target.current == binding.generation then return self:resolve(caller, key) end
    if not binding.cross_generation then
        return result.failure("HU_GENERATION_INCOMPATIBLE", key)
    end

    target.instances[target.current].visitors[caller] = binding.edge
    local old = target.instances[binding.generation]
    if old then old.visitors[caller] = nil end
    binding.generation = target.current
    return self:resolve(caller, key)
end

---@param caller string 身份
---@return flywow_hotupgrade_result
function Registry:release(caller)
    for key, binding in pairs(self.callers[caller] or {}) do
        local instance = self.targets[key].instances[binding.generation]
        if instance then instance.visitors[caller] = nil end
    end
    self.callers[caller] = nil
    return result.success()
end

---@param key string target
---@param generation integer 实例代际
---@return integer strong 引用数
function Registry:strong_count(key, generation)
    local instance = self.targets[key].instances[generation]
    local count = 0
    for _, edge in pairs(instance.visitors) do
        if edge == "strong" then count = count + 1 end
    end
    return count
end

---@param key string target
---@param generation integer 旧实例
---@return flywow_hotupgrade_result
function Registry:retire(key, generation)
    local target = self.targets[key]
    local instance = target and target.instances[generation]
    if not instance then return result.success() end
    if target.current == generation or instance.inflight > 0 or self:strong_count(key, generation) > 0 then
        return result.failure("HU_RETIRE_BLOCKED", key)
    end
    target.instances[generation] = nil
    self.revision = self.revision + 1
    return result.success()
end

return M
