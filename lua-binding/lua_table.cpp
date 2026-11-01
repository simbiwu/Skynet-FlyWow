// 职责：管理 table registry 引用并验证稠密数组；每次操作恢复临时栈。
#include "lua_table.h"
#include <algorithm>

namespace flywow_lua_binding
{
LuaTable::LuaTable(LuaBinding *lua_binding, int reference)
    : binding_(lua_binding), reference_(reference)
{
}
LuaTable::~LuaTable()
{
    reset();
}

LuaTable::LuaTable(LuaTable &&other) noexcept
    : binding_(other.binding_), reference_(other.reference_)
{
    other.binding_   = nullptr;
    other.reference_ = LUA_NOREF;
}

// 移动赋值先释放自身引用，再接管 other 的引用；源句柄失去 owner，不能继续操作。
LuaTable &LuaTable::operator=(LuaTable &&other) noexcept
{
    if (this != &other)
    {
        reset();
        binding_         = other.binding_;
        reference_       = other.reference_;
        other.binding_   = nullptr;
        other.reference_ = LUA_NOREF;
    }

    return *this;
}

// 仅释放本句柄持有的 registry 编号；已有栈、字段或闭包引用仍保活同一 table，不弹栈。
void LuaTable::reset() noexcept
{
    if (valid())
    {
        // luaL_unref：释放此 owner 持有的 registry 引用编号，不弹栈、不直接销毁对象；其它 Lua 引用仍可保持对象存活。
        // ref 创建时已建立 registry 槽及空闲链头；unref 只改写已有槽，不分配新表项。
        luaL_unref(binding_->state_, LUA_REGISTRYINDEX, reference_);
    }
    binding_   = nullptr;
    reference_ = LUA_NOREF;
}

bool LuaTable::valid() const
{
    return binding_ != nullptr && reference_ >= 0;
}

void LuaTable::push() const
{
    // reference_ 是 registry 引用编号，不是业务数组 key。
    // rawgeti 压入同一 table：[S] -> [S, table]，不触发 __index。
    // 句柄继续持有 registry 引用；外层保护器只弹掉这份临时栈引用。
    detail::ensureStack(binding_->state_, 1);
    lua_rawgeti(binding_->state_, LUA_REGISTRYINDEX, reference_);
}

bool LuaTable::denseArrayLength(std::size_t &output) const
{
    if (!valid())
    {
        return false;
    }
    detail::StackRestore stack(binding_->state_);
    push();
    const int table_index =
        lua_gettop(binding_->state_); // 源表绝对索引，不随 next 的 key/value 临时项移动。
    lua_Integer max_index = 0;        // 正整数数组 key 的最大值；命名字段和非正 key 不计入。
    std::size_t entries   = 0;        // 每个 table key 唯一，entries==max_index 才说明没有空洞。
    // nil 启动遍历：[S, table] -> [S, table, nil]；nil 不是实际字段 key。
    // next 消耗旧 key，成功压入新 key/value；结束弹掉最后 key，留下 [S, table]。
    // 每轮只弹 value，保留 lua_next 返回的原 key；本方法不执行用户回调或修改源表，
    // 因此下一轮游标必为刚由 lua_next 产生的有效 key，可直接遍历而不为每项建立 pcall。
    detail::ensureStack(binding_->state_, 1);
    lua_pushnil(binding_->state_);
    while (lua_next(binding_->state_, table_index) != 0)
    {
        if (lua_isinteger(binding_->state_, -2))
        {
            const lua_Integer key = lua_tointeger(binding_->state_, -2);
            if (key > 0)
            {
                max_index = std::max(max_index, key);
                ++entries;
            }
        }
        lua_pop(binding_->state_, 1); // 保留 key、移除 value，继续同一次迭代。
    }
    // 正整数 key 唯一且全部落在 1..max_index，数量等于区间大小才说明没有缺项。
    // 例如 {1,3}：entries=2、max_index=3，不能误把 rawlen 的一个边界当连续长度。
    if (static_cast<std::uintmax_t>(max_index) != entries)
    {
        binding_->setError("INVALID_ARGUMENT",
                           "positive integer keys must form a dense 1-based array");
        return false;
    }
    output = entries; // 空表 max_index/entries 均为 0，是否允许空由业务决定。
    return true;
}

} // namespace flywow_lua_binding
