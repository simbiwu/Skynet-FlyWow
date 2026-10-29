// 职责：table 的引用生命周期、raw 操作、遍历与数组检查。
// 每次操作恢复入口栈；临时引用不跨所属 Binding 回调。
#include "lua_table.h"
extern "C"
{
#include <lauxlib.h>
}
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

bool LuaTable::requireValid() const
{
    return valid();
}

void LuaTable::push() const
{
    // reference_ 是 registry 引用编号，不是业务数组 key。
    // rawgeti 压入同一 table：[S] -> [S, table]，不触发 __index。
    // 句柄继续持有 registry 引用；外层保护器只弹掉这份临时栈引用。
    detail::ensureStack(binding_->state_, 1);
    lua_rawgeti(binding_->state_, LUA_REGISTRYINDEX, reference_);
}

bool LuaTable::pushField(const std::string &key) const
{
    // [S, table, key] -> [S, table, value]，rawget 消耗 key；源表不弹出。
    // pushlstring 保留 key 的完整字节，不将内嵌零字节误当字符串结束。
    push();
    detail::pushString(binding_->state_, key.data(), key.size());
    lua_rawget(binding_->state_, -2);
    return true;
}

// 为 raw 写入准备目标表和完整 key；__gc 由类型注册独占，失败的临时表由调用者恢复。
bool LuaTable::pushWriteKey(const std::string &key) const
{
    push();
    if (key == "__gc")
    {
        binding_->setError("INVALID_ARGUMENT", "__gc is managed by userdata registration");
        return false;
    }
    detail::pushString(binding_->state_, key.data(), key.size());
    return true;
}

bool LuaTable::forEach(const std::function<bool(const LuaValue &, const LuaValue &)> &visitor) const
{
    if (!requireValid())
    {
        return false;
    }
    if (!visitor)
    {
        binding_->setError("INVALID_ARGUMENT", "table visitor must not be empty");
        return false;
    }
    detail::StackRestore stack(binding_->state_);
    push();
    const int table_index = lua_gettop(binding_->state_); // 固定源表，嵌套操作不改变它。
    return visitEntries(table_index, visitor);
}

// 源表已在 table_index；外层 forEach 持有 StackRestore，负责成功/失败/异常的栈恢复。
// key/value 生命周期和 lua_next 的下一轮条件放在同一处，避免恢复栈时误删迭代 key。
bool LuaTable::visitEntries(
    int table_index, const std::function<bool(const LuaValue &, const LuaValue &)> &visitor) const
{
    // nil 是起始游标，不是实际字段：[S,table] -> [S,table,nil]。
    // next 有条目时留下 [S,table,key,value]；没有条目时消费游标，留下 [S,table]。
    detail::ensureStack(binding_->state_, 1);
    lua_pushnil(binding_->state_);
    // lua_next 消耗旧 key，成功时压入新 key/value；结束时不压值。
    // [S, table, nil/key] -> [S, table, key, value]，第一轮 nil 表示开始。
    while (detail::nextEntry(binding_->state_, table_index))
    {
        // 固定本轮两个槽；revision 区分 visitor 的新错误和之前已处理的旧诊断。
        const int iteration_top      = lua_gettop(binding_->state_); // visitor 返回后的栈基线。
        const std::uint64_t revision = binding_->error_revision_;    // 调用前错误序号。
        const LuaValue      key(binding_, iteration_top - 1); // 不转换原 key，保证下一轮迭代。
        const LuaValue      value(binding_, iteration_top);   // 只在本轮有效的字段值视图。
        if (!visitor(key, value))
        {
            if (revision == binding_->error_revision_)
            {
                binding_->setError("INTERNAL_ERROR",
                                   "table visitor failed without recording error");
            }
            return false;
        }
        // 回调临时值清理后，保留原 key，只弹 value，供下次 lua_next 使用。
        // 不对数值 key 原位 tostring；异常/失败则由整个操作的保护器恢复 [S]。
        lua_settop(binding_->state_, iteration_top);
        lua_pop(binding_->state_, 1);
    }
    return true;
}

bool LuaTable::arrayLength(std::size_t &output) const
{
    if (!requireValid())
    {
        return false;
    }
    detail::StackRestore stack(binding_->state_);
    push();
    // 不改变 [S, table]，不调用 __len；返回数组边界，不证明数组无空洞。
    // 稀疏表可能有多个合法边界；出口由保护器移除临时 table，恢复 [S]。
    output = lua_rawlen(binding_->state_, -1);
    return true;
}

bool LuaTable::denseArrayLength(std::size_t &output) const
{
    if (!requireValid())
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

bool LuaTable::setMetatable(const LuaTable &meta)
{
    if (!requireValid())
    {
        return false;
    }
    detail::StackRestore stack(binding_->state_);
    push();
    if (!binding_->pushValue(meta))
    {
        return false;
    }
    // [S, table, meta] -> [S, table]：setmetatable 消耗 meta，不销毁 meta 引用。
    detail::setMetatable(binding_->state_);
    return true;
}

bool LuaTable::readMetatable(LuaTable &output) const
{
    if (!requireValid())
    {
        return false;
    }
    detail::StackRestore stack(binding_->state_);
    push();
    // 有 metatable：[S, table] -> [S, table, meta]；没有则不压值，返回 0。
    // readTableAt 为 meta 建立独立 registry 引用；临时 table/meta 出栈不使句柄失效。
    detail::ensureStack(binding_->state_, 1);
    if (lua_getmetatable(binding_->state_, -1) == 0)
    {
        binding_->setError("INVALID_ARGUMENT", "table has no metatable");
        return false;
    }
    return binding_->readTableAt(-1, output);
}

LuaType LuaValue::type() const
{
    // 查看本轮固定槽，不压栈或转换原 key，保证后续 lua_next 可以继续。
    switch (lua_type(binding_->state_, index_))
    {
    case LUA_TBOOLEAN:
        return LuaType::kBoolean;
    case LUA_TNUMBER:
        return LuaType::kNumber;
    case LUA_TSTRING:
        return LuaType::kString;
    case LUA_TTABLE:
        return LuaType::kTable;
    case LUA_TFUNCTION:
        return LuaType::kFunction;
    case LUA_TUSERDATA:
        return LuaType::kUserdata;
    case LUA_TLIGHTUSERDATA:
        return LuaType::kLightUserdata;
    case LUA_TTHREAD:
        return LuaType::kThread;
    default:
        return LuaType::kNil;
    }
}
bool LuaValue::isNil() const
{
    return lua_isnil(binding_->state_, index_);
}
bool LuaValue::readTable(LuaTable &output) const
{
    return binding_->readTableAt(index_, output);
}
bool LuaValue::readTruth(bool &output) const
{
    return binding_->readTruthAt(index_, output);
}
} // namespace flywow_lua_binding
