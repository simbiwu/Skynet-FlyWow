--- 每个元素有一个 key 和一个 value。用 key 找元素，用 value 决定谁先出堆。
--- 例如按截止时间取任务时，key 可以是任务 ID，value 可以是截止时间；时间越早越先取。
--- items[1] 总是优先级最高的元素。其余元素只保证父节点的优先级不低于子节点。
--- indices[key] 记着该元素在 items 里的下标，因此改值或删除时不用从头找。
--- 如果 value 是 table，堆保存的是同一个 table。元素移除后，堆不再持有它的 key 和 value。
--- 键必须可作 Lua 表键（非 nil、非 NaN），值必须非 nil；键和值都允许 false。
--- 堆操作不做 I/O，也不主动 yield。比较函数如果报错，错误会传给调用方，已改动的位置可能只调整了一半。
local M = {}

---@class FlyWowIndexMinHeap
local Heap = {}
Heap.__index = Heap

--- 交换两个元素的位置，再把它们的新下标写回索引。漏写一个，之后按那个 key 找到的就是另一个元素。
---@param heap FlyWowIndexMinHeap 当前正在调整的堆，读写其元素数组和键索引。
---@param i integer 本轮待调整元素的位置。
---@param j integer 本轮与待调整元素交换的父项或子项位置。
---@return nil 无返回值。
local function swap(heap, i, j)
    local items   = heap.items   -- 交换后，items[i] 和 items[j] 已经是各自的新元素。
    local indices = heap.indices -- 记下两个 key 的新下标，供后续 update 和 remove 查找。
    items[i], items[j] = items[j], items[i]
    indices[items[i].key] = i
    indices[items[j].key] = j
end

--- 让优先级更高的元素往堆顶移动。每次与父节点比较，只有比父节点更优先才交换。
---@param heap FlyWowIndexMinHeap 刚插入或调整过一个元素的堆；其余元素之间的顺序已经正确。
---@param index integer 新增项或待上浮项当前所在的数组位置。
---@return nil 无返回值。
local function sift_up(heap, index)
    local items = heap.items -- 读取待调整项与父项的值，交换后继续从新位置比较。
    while index > 1 do
        local parent = index // 2 -- 数组从 1 开始。下标除以 2 向下取整就得到父节点，例如 6 和 7 的父节点都在 3。
        if not heap.less(items[index].value, items[parent].value) then
            break
        end
        swap(heap, index, parent)
        index = parent
    end
end

--- 让优先级降低或刚从末尾搬来的元素往下移动。每次先挑两个子节点中更优先的那个，再看是否需要交换。
--- 例如按数值从小到大取，当前值是 9，左右子节点是 5 和 3，就要和 3 换。若和 5 换，5 仍排在 3 上面。
---@param heap FlyWowIndexMinHeap 刚换值或补位的堆；待移动元素下面的两棵子树各自已经排好。
---@param index integer 待下沉项当前所在的数组位置。
---@return nil 无返回值。
local function sift_down(heap, index)
    local items = heap.items -- 比较当前项及其子项的值；调整过程中数组长度不变。
    while index * 2 <= #items do
        local child = index * 2 -- 先选一定存在的左子项；右子项存在且优先级更高时改选右项。
        local right = child + 1 -- 与左子项相邻，可能已超出数组尾部。
        if right <= #items and heap.less(items[right].value, items[child].value) then
            child = right
        end
        if not heap.less(items[child].value, items[index].value) then
            break
        end
        swap(heap, index, child)
        index = child
    end
end

--- 用传入的比较函数创建空堆。数值小的先取就传 a < b，数值大的先取就传 a > b。
--- 同优先级的元素可能以任意顺序取出。
---@param less fun(a: any, b: any): boolean 只比较两个 value。a 应排在 b 前面时返回 true，同优先级时两个方向都返回 false。比较须一致并满足严格弱序，不得 yield、修改堆或在操作中改变规则。
---@return FlyWowIndexMinHeap heap 新建的空堆。
function M.new(less)
    return setmetatable(
    {
        items   = {},   -- 保存按堆序排列的键值对，数组首项优先级最高。
        indices = {},   -- 保存各键当前的数组下标，移动或删除元素时同步更新。
        less    = less, -- 这个堆用它决定两个 value 谁更优先。
    }, Heap)
end

--- 加入一个新 key 和对应的 value。如果 key 已经在堆里，保留它原来的 value。
---@param key any 调用方为元素选定的唯一 Lua 表键，用于后续定位。
---@param value any 调用方要保存的非 nil 值，优先级由构造时传入的比较函数决定。
---@return boolean inserted 新键插入成功为 true，键已存在为 false。
function Heap:insert(key, value)
    if self.indices[key] ~= nil then
        return false
    end

    -- 先把新元素放到数组末尾并登记下标。之后它只可能比父节点更优先，所以从末尾往上检查。
    local index = #self.items + 1 -- 新项加入前的第一个空位。
    self.items[index] =
    {
        key   = key,   -- 保留调用方的标识，移动时据此更新索引。
        value = value, -- 保存原值，供比较器排序以及读取和删除时返回。
    }
    self.indices[key] = index
    sift_up(self, index)
    return true
end

--- 用插入时的 key 找到元素，换成新值，再把它移到合适的位置。
--- 如果直接改了 table 的 deadline 等排序字段，也要立刻用同一个 table 调用 update。堆不会自己移动它。
--- 改字段到调用 update 之间不能 yield，也不能先 peek 或 pop 等依赖堆顺序的操作。
---@param key any 调用方插入元素时使用的键，用于找到待修改项。
---@param value any 调用方提供的新非 nil 值，也可以是刚原地修改过的同一个对象。
---@return boolean updated 找到并更新为 true，键不存在为 false。
function Heap:update(key, value)
    local index = self.indices[key] -- 从键索引直接定位；缺失时不插入。
    if index == nil then
        return false
    end

    -- 新值比父节点更优先，就往上移。否则它与父节点的顺序已经正确，只需检查下面的子节点。
    local items = self.items -- 原地替换目标项的值，比较时读取其父项的值。
    items[index].value = value
    if index > 1 and self.less(value, items[index // 2].value) then
        sift_up(self, index)
    else
        sift_down(self, index)
    end
    return true
end

--- 用插入时的 key 找到并删除元素，返回它原来的 value。若删的是中间位置，用最后一个元素补上。
---@param key any 调用方插入元素时使用的键，用于定位待删除项。
---@return any value 被删除的非 nil 值（可为 false）；键不存在时返回 nil。
function Heap:remove(key)
    local index = self.indices[key] -- 从键索引定位待删项；没有索引便无需调整。
    if index == nil then
        return nil
    end

    -- 记下要返回的值和可能拿来补位的最后一个元素，再清掉被删 key 的下标和数组最后一格。
    local items      = self.items        -- 取出待删值，并缩短存放键值对的数组。
    local value      = items[index].value -- 留给调用方的原值，即使数组空位随后被覆盖。
    local last_index = #items            -- 删除之前的尾部位置，用来判断是否要填补空位。
    local last_item  = items[last_index]  -- 删除非尾项时，将这个键值对移入空位。
    self.indices[key] = nil
    items[last_index] = nil
    if index == last_index then
        return value
    end

    -- 用最后一个元素填上空位，数组就不会留下洞。先登记它的新下标，再按与父节点的比较决定往上移还是检查子节点。
    items[index] = last_item
    self.indices[last_item.key] = index
    if index > 1 and self.less(last_item.value, items[index // 2].value) then
        sift_up(self, index)
    else
        sift_down(self, index)
    end
    return value
end

--- 读取当前优先级最高的键和值，保留堆顶元素。
---@return any key 堆顶元素的键；空堆为 nil。
---@return any value 堆顶元素的值；空堆为 nil。
function Heap:peek()
    local item = self.items[1] -- 数组首项持有堆顶键值对；空堆没有首项。
    if item == nil then
        return nil, nil
    end
    return item.key, item.value
end

--- 取出堆顶的 key 和 value，同时把它从堆里删掉。删除和重新排堆由 remove 完成。
---@return any key 被取出的堆顶键；空堆为 nil。
---@return any value 被取出的堆顶值；空堆为 nil。
function Heap:pop()
    local item = self.items[1] -- 删除前保留原堆顶；删除后首项可能已换成其他元素。
    if item == nil then
        return nil, nil
    end
    return item.key, self:remove(item.key)
end

--- 返回当前元素数量，空堆为 0。
---@return integer count 堆内现存的元素数。
function Heap:size()
    return #self.items
end

return M
