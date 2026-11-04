--- 从 FlyWow 根目录运行，LUA_PATH 设为 common/lualib/?.lua，使用项目固定的 Lua 5.4.7。
local IndexMinHeap = require "flywow_indexminheap"

--- 数值用例以较小的数值为更高优先级。
---@param a number 比较器收到的第一个堆内数值。
---@param b number 比较器收到的第二个堆内数值。
---@return boolean higher a 严格小于 b 时为 true。
local function min_less(a, b)
    return a < b
end

--- 检查查看或弹出操作返回的两个位置，确保空堆也明确返回两个 nil。
---@param expected_key any 本用例预期的键。
---@param expected_value any 本用例预期的值。
---@param ... any 来自 peek 或 pop 的全部返回值。
---@return nil 断言通过时无返回值。
local function assert_pair(expected_key, expected_value, ...)
    assert(select("#", ...) == 2, "应返回两个值")
    local key, value = ... -- 分别检查键和值；false 不视为空，对象值按引用检查。
    assert(rawequal(key, expected_key), "返回的键不符合预期")
    assert(rawequal(value, expected_value), "返回的值不符合预期")
end

-- 空堆、重复键、缺失键及查看后依次弹出。
do
    local heap = IndexMinHeap.new(min_less) -- 验证空堆与插入、查看的返回合同。
    assert(heap:size() == 0)
    assert_pair(nil, nil, heap:peek())
    assert_pair(nil, nil, heap:pop())
    assert(heap:remove("missing") == nil)
    assert(heap:update("missing", 0) == false)
    assert(heap:insert("three", 3) == true)
    assert(heap:insert("one", 1) == true)
    assert(heap:insert("two", 2) == true)
    assert(heap:insert("one", 9) == false)
    assert_pair("one", 1, heap:peek())
    assert(heap:size() == 3)
    assert_pair("one", 1, heap:pop())
    assert_pair("two", 2, heap:pop())
    assert_pair("three", 3, heap:pop())
    assert(heap:size() == 0)
    assert_pair(nil, nil, heap:pop())
end

-- 同一键跨多层上浮、下沉，随后仍可通过原键准确删除。
do
    local heap = IndexMinHeap.new(min_less) -- 升序插入后，键 7 初始位于第三层。
    for i = 1, 7 do
        assert(heap:insert(i, i))
    end
    assert(heap:update(7, 0))
    assert_pair(7, 0, heap:peek())
    assert(heap:update(7, 9))
    assert_pair(1, 1, heap:peek())
    assert(heap:remove(7) == 9)
    for i = 1, 6 do
        assert_pair(i, i, heap:pop())
    end
end

-- 删除尾项和堆顶，以及尾项补入中间位置后须下沉的情况。
do
    local heap = IndexMinHeap.new(min_less) -- 升序插入构造值为 1 至 8 的堆。
    for i = 1, 8 do
        assert(heap:insert(i, i))
    end
    assert(heap:remove(8) == 8)
    assert(heap:remove(2) == 2)
    assert(heap:remove(1) == 1)
    assert(heap:remove(2) == nil)
    for i = 3, 7 do
        assert_pair(i, i, heap:pop())
    end
end

-- 末尾值 4 补入值 12 的位置时要越过父项 10；再重复混合操作检查移动后的索引。
do
    local heap = IndexMinHeap.new(min_less) -- 两侧子树可有不同的优先级范围。
    for _, value in ipairs({1, 10, 2, 11, 12, 3, 4}) do
        assert(heap:insert(value, value))
    end
    assert(heap:remove(12) == 12)
    assert(heap:update(4, 0))
    assert_pair(4, 0, heap:pop())
    assert(heap:insert(12, 5))
    assert(heap:remove(10) == 10)
    assert(heap:update(12, 8))
    assert_pair(1, 1, heap:pop())
    assert(heap:insert(4, 6))
    assert(heap:update(11, 7))
    assert_pair(2, 2, heap:pop())
    assert_pair(3, 3, heap:pop())
    assert_pair(4, 6, heap:pop())
    assert_pair(11, 7, heap:pop())
    assert_pair(12, 8, heap:pop())
    assert_pair(nil, nil, heap:peek())
end

-- 业务对象按字段排序，原地修改后立即 update，并验证返回的仍是原引用。
do
    local heap = IndexMinHeap.new(function(a, b)
        return a.deadline < b.deadline
    end)
    local first  = {deadline = 30} -- 第一项的截止时间将提前，键使用对象本身。
    local second = {deadline = 10} -- 初始截止时间更早，先成为堆顶。
    assert(heap:insert(first, first))
    assert(heap:insert(second, second))
    assert_pair(second, second, heap:peek())
    first.deadline = 5
    assert(heap:update(first, first))
    assert_pair(first, first, heap:pop())
    assert_pair(second, second, heap:pop())
end

-- 同一组件反向排序；同优先级只验证两个元素都被取出。
do
    local heap = IndexMinHeap.new(function(a, b)
        return a > b
    end)
    assert(heap:insert("low", 1))
    assert(heap:insert("high", 3))
    assert(heap:insert("tie", 3))
    local first_key, first_value = heap:pop()   -- 先取出的最高值，键可以是任一并列项。
    local second_key, second_value = heap:pop() -- 另一个并列项也必须保留。
    assert(first_value == 3 and second_value == 3)
    assert((first_key == "high" and second_key == "tie") or (first_key == "tie" and second_key == "high"))
    assert_pair("low", 1, heap:pop())
end

-- false 同时作为键和值时，必须与空堆或未找到区分。
do
    local heap = IndexMinHeap.new(function(a, b)
        return a == false and b == true
    end)
    assert(heap:insert(true, true))
    assert(heap:insert(false, false))
    assert(heap:insert(false, true) == false)
    assert_pair(false, false, heap:peek())
    assert(heap:remove(false) == false)
    assert(heap:remove(false) == nil)
    assert(heap:insert(false, true))
    assert(heap:update(false, false))
    assert_pair(false, false, heap:pop())
    assert_pair(true, true, heap:pop())
end

print("IndexMinHeap 测试通过")
