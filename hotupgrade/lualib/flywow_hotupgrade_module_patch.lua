--- 当前 Lua State 的受控模块更新；不扫描 VM，只处理本次新函数的明确导出表引用。
local result = require "flywow_hotupgrade_error"
local M = {}
local Engine = {}
Engine.__index = Engine

local function readonly(value, seen, stage)
    if type(value) == "function" and stage then
        return function(...)
            if not stage.committed then error("stage cannot invoke live dependency", 0) end
            return value(...)
        end
    end
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local proxy = {}
    seen[value] = proxy
    return setmetatable(proxy,
    {
        __index = function(_, key) return readonly(value[key], seen, stage) end,
        __newindex = function() error("stage cannot mutate live data", 0) end,
        __len = function() return #value end,
        __pairs = function()
            local function next_item(_, key)
                local next_key, item = next(value, key)
                return next_key, readonly(item, seen, stage)
            end
            return next_item, proxy, nil
        end,
        __metatable = false,
    })
end

local function environment(loader)
    local env = {}
    local primitives = {"assert", "error", "ipairs", "next", "pairs", "pcall",
        "select", "tonumber", "tostring", "type", "xpcall"}
    for _, key in ipairs(primitives) do env[key] = _G[key] end
    env.math, env.string, env.table, env.utf8 =
        readonly(math), readonly(string), readonly(table), readonly(utf8)
    env.require = loader
    return setmetatable(env,
    {
        __newindex = function() error("module globals forbidden", 0) end,
    })
end

local function dependency_proxy(binding)
    return setmetatable({},
    {
        __index = function(_, key) return binding.table[key] end,
        __newindex = function() error("dependency writes forbidden", 0) end,
        __pairs = function() return pairs(binding.table) end,
        __len = function() return #binding.table end,
        __metatable = false,
    })
end

--- Stage 只读，提交后绑定原来的状态表；代理本身可被新闭包长期持有。
local function stable_proxy(engine, state, namespace)
    local binding = state.stable_bindings[namespace]
    if binding then return binding.proxy end

    binding = {table = engine.stable[namespace] or {}, writable = false}
    binding.proxy = setmetatable({},
    {
        __index = function(_, key)
            local value = binding.table[key]
            return binding.writable and value or readonly(value)
        end,
        __newindex = function(_, key, value)
            if not binding.writable then error("stage cannot mutate stable state", 0) end
            binding.table[key] = value
        end,
        __pairs = function()
            if binding.writable then return pairs(binding.table) end
            return pairs(readonly(binding.table))
        end,
        __len = function() return #binding.table end,
        __metatable = false,
    })
    state.stable_bindings[namespace] = binding
    return binding.proxy
end

local function validate_exports(entry, live, candidate)
    if type(candidate) ~= "table" or getmetatable(candidate) then
        return result.failure("HU_MODULE_CONTRACT", "模块必须返回普通 table")
    end
    for key, value in pairs(candidate) do
        if type(key) ~= "string" then
            return result.failure("HU_MODULE_CONTRACT", "export key 必须为字符串")
        end
        if live and live[key] ~= nil and type(live[key]) ~= type(value) then
            return result.failure("HU_MODULE_CONTRACT", "export 类型变化: " .. key)
        end
        if type(value) ~= "function" and not entry.replace_all_values and not (entry.replace_values or {})[key] then
            if not live or live[key] ~= value then
                return result.failure("HU_MODULE_CONTRACT", "值导出需显式声明: " .. key)
            end
        end
    end
    return result.success()
end

--- 创建模块引擎；loaded 必须是当前 Lua State 的模块缓存，不跨 Service 共用。
---@param options? table loaded/trusted/stable
---@return table
function M.new(options)
    options = options or {}
    return setmetatable(
    {
        loaded = options.loaded or package.loaded,
        trusted = options.trusted or {},
        stable = options.stable or {},
        versions = {},
    }, Engine)
end

local function stage_loader(engine, state)
    return function(name)
        if state.entries[name] then
            local checked = engine:load_entry(state, name)
            if not checked.ok then error(checked.message, 0) end
            local binding = state.bindings[name]
            return binding.proxy
        end
        if engine.trusted[name] then return readonly(engine.trusted[name], nil, state) end
        if name == "flywow_hotupgrade" then
            return {stable_state = function(namespace)
                assert(type(namespace) == "string" and namespace ~= "", "invalid stable namespace")
                return stable_proxy(engine, state, namespace)
            end}
        end
        if engine.loaded[name] then return readonly(engine.loaded[name], nil, state) end
        error("undeclared dependency: " .. name, 0)
    end
end

function Engine:load_entry(state, name)
    if state.new[name] then return result.success() end
    if state.loading[name] then
        return result.failure("HU_MODULE_DEPENDENCY_CYCLE", name)
    end
    state.loading[name] = true
    local entry = state.entries[name]
    local fn, message = load(entry.source, "@" .. entry.name, "t", environment(stage_loader(self, state)))
    if not fn then return result.failure("HU_MODULE_SYNTAX", message) end

    local executed = result.execute(fn, state.budget)
    if not executed.ok then return executed end
    local candidate = executed.values[1]
    local checked = validate_exports(entry, self.loaded[name], candidate)
    if not checked.ok then return checked end

    state.new[name] = candidate
    state.bindings[name].table = candidate
    state.loading[name] = nil
    return result.success()
end

---@param entries table[] name/source/action/code_version/remove_exports/replace_values
---@return flywow_hotupgrade_result
function Engine:stage(entries)
    local state = {entries = {}, new = {}, loading = {}, bindings = {}, old = {},
        stable_bindings = {}, new_stable = {}, budget = 1000000}
    for _, entry in ipairs(entries) do
        if entry.action == nil then
            entry.action = self.loaded[entry.name] == nil and "add" or "replace"
        end
        if state.entries[entry.name] then
            return result.failure("HU_INVALID_MANIFEST", "模块重复")
        end
        if entry.action == "add" and self.loaded[entry.name] ~= nil then
            return result.failure("HU_VERSION_MISMATCH", "新增模块已存在")
        end
        if entry.action ~= "add" and type(self.loaded[entry.name]) ~= "table" then
            return result.failure("HU_MODULE_NOT_REGISTERED", entry.name)
        end
        state.entries[entry.name] = entry
        state.bindings[entry.name] = {}
        state.bindings[entry.name].proxy = dependency_proxy(state.bindings[entry.name])
    end

    for _, entry in ipairs(entries) do
        local checked = self:load_entry(state, entry.name)
        if not checked.ok then return checked end
    end
    return result.success({stage = state})
end

local function rebind_function(fn, candidate, live, seen)
    if seen[fn] then return end
    seen[fn] = true
    for index = 1, math.huge do
        local name, value = debug.getupvalue(fn, index)
        if not name then break end
        if value == candidate then
            debug.setupvalue(fn, index, live)
        elseif type(value) == "function" and name ~= "_ENV" then
            rebind_function(value, candidate, live, seen)
        end
    end
end

function Engine:install_entry(state, name)
    local candidate = state.new[name]
    local entry = state.entries[name]
    local live = self.loaded[name]
    local saved = {table = live, version = self.versions[name], fields = {}}
    if live then
        for key, value in pairs(live) do saved.fields[key] = value end
    else
        live = {}
        self.loaded[name] = live
    end
    state.old[name] = saved

    for key, value in pairs(candidate) do
        if type(value) == "function" then
            rebind_function(value, candidate, live, {})
        end
        live[key] = value
    end
    for _, key in ipairs(entry.remove_exports or {}) do live[key] = nil end
    state.bindings[name].table = live
    self.versions[name] = entry.code_version
end

--- 仅 Guard 已静止时调用；同步、不 yield，可保留 undo 到组提交决定。
---@param state table stage 返回的独占句柄
---@param postcheck? function 同步无副作用检查
---@return flywow_hotupgrade_result
function Engine:commit(state, postcheck)
    local checked = result.execute(function()
        for name in pairs(state.new) do self:install_entry(state, name) end
        if postcheck then
            local verdict = postcheck()
            if verdict == false or (type(verdict) == "table" and verdict.ok == false) then
                error("postcheck rejected", 0)
            end
        end
    end)
    if not checked.ok then
        self:abort(state)
        return result.failure("HU_MODULE_COMMIT_FAILED", checked.message)
    end

    -- 检查通过后才允许业务修改状态；失败的 Stage 不创建线上 namespace。
    for namespace, binding in pairs(state.stable_bindings) do
        if not self.stable[namespace] then
            self.stable[namespace] = binding.table
            state.new_stable[namespace] = true
        end
        binding.writable = true
    end
    state.committed = true
    return result.success()
end

--- 恢复本次保存的 exports/版本/缓存；没有提交时只释放暂存句柄。
---@param state table stage
---@return flywow_hotupgrade_result
function Engine:abort(state)
    state.committed = false
    for namespace, binding in pairs(state.stable_bindings) do
        binding.writable = false
        if state.new_stable[namespace] then self.stable[namespace] = nil end
    end

    for name, saved in pairs(state.old) do
        self.versions[name] = saved.version
        self.loaded[name] = saved.table
        if saved.table then
            for key in pairs(saved.table) do saved.table[key] = nil end
            for key, value in pairs(saved.fields) do saved.table[key] = value end
            state.bindings[name].table = saved.table
        end
    end
    state.old, state.new = {}, {}
    return result.success()
end

return M
