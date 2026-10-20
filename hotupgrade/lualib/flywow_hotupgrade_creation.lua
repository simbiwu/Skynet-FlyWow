--- 仅内部启动引导写入的本 State 创建身份；不跨 Service 共享可变对象。
local M = {}
local creation_identity -- 引导加载目标业务入口前写入一次，首次登记读取。

---@class FlyWowHotUpgradeCreationIdentity
---@field controller_handle integer 本次受管理创建所属的 Controller
---@field creation_id string Controller 生成的进程内创建标识，不复用

--- 仅由内部引导在业务入口执行前调用；重复绑定视为启动错误。
---@param controller_handle integer
---@param creation_id string
function M.initialize(controller_handle, creation_id)
    assert(not creation_identity, "HU_DUPLICATE_CREATION: 当前 State 已有创建身份")
    assert(math.type(controller_handle) == "integer" and type(creation_id) == "string",
        "HU_INVALID_REQUEST: 创建身份无效")
    creation_identity = {controller_handle = controller_handle, creation_id = creation_id}
end

---@return FlyWowHotUpgradeCreationIdentity? identity 非受管理 State 返回 nil
function M.get()
    return creation_identity
end

return M
