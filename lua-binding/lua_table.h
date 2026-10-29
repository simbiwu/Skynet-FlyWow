// 职责：用独立 registry 引用操作 Lua table；raw 读写不触发元方法。
// 生命周期：仅限所属 LuaBinding 回调；可移动、不可复制，析构释放引用而不弹返回值。
#pragma once
#include "lua_binding.h"
#include "lua_value.h"
#include <functional>

namespace flywow_lua_binding
{
/// 当前同步回调内的 table 句柄；父子表互不限制销毁顺序。
class LuaTable
{
  public:
    LuaTable() = default;
    ~LuaTable();
    LuaTable(LuaTable &&other) noexcept;
    LuaTable &operator=(LuaTable &&other) noexcept;
    LuaTable(const LuaTable &)            = delete;
    LuaTable &operator=(const LuaTable &) = delete;

    bool valid() const;
    /// 按真实整数 key 或完整字符串 key 读取；失败不改 output。
    /// @param key Lua 整数 key 或完整字符串 key。
    /// @param output 输出对象；失败时保留原值。
    /// @return 成功读取并完成严格类型检查时返回 true。
    template <typename Key, typename T> bool readValue(const Key &key, T &output) const
    {
        if (!requireValid())
        {
            return false;
        }
        detail::StackRestore stack(binding_->state_);
        if (!pushField(key))
        {
            return false;
        }
        return binding_->readAt(-1, output);
    }

    /// 读取字段中的 table 引用；失败时保留 output 原句柄。
    /// @param key Lua 整数 key 或完整字符串 key。
    /// @param output 输出 table；成功时拥有新 registry 引用并借用当前 Binding。
    /// @return 字段存在且为 table 时返回 true。
    template <typename Key> bool readTable(const Key &key, LuaTable &output) const
    {
        if (!requireValid())
        {
            return false;
        }
        detail::StackRestore stack(binding_->state_);
        return pushField(key) && binding_->readTableAt(-1, output);
    }

    /// 判断字段是否为 nil；不把正常的非 nil 字段误当作读取错误。
    /// @param key 真实整数 key 或完整字符串 key，读取使用 raw 语义。
    /// @return 字段为 nil 时为 true；非 nil 或读取失败时为 false。
    /// @note 无 owner 的默认/移动后句柄只能返回 false，不能向某个 Binding 记录错误。
    template <typename Key> bool isNil(const Key &key) const
    {
        if (!requireValid())
        {
            return false;
        }
        detail::StackRestore stack(binding_->state_);
        // lua_isnil：检查该槽是否恰为 nil，不改变栈；缺失字段由 rawget 产生 nil，无效槽则不是 nil。
        return pushField(key) && lua_isnil(binding_->state_, -1);
    }

    /// 显式 Lua 真值规则：只有 nil/false 为假，0 和空串为真。
    /// @param key Lua 整数 key 或完整字符串 key。
    /// @param output 输出布尔值；失败时保留原值。
    /// @return 成功读取时返回 true。
    template <typename Key> bool readTruth(const Key &key, bool &output) const
    {
        if (!requireValid())
        {
            return false;
        }
        detail::StackRestore stack(binding_->state_);
        return pushField(key) && binding_->readTruthAt(-1, output);
    }

    /// raw 写入字段；成功时只更新目标字段，临时栈在退出时恢复。
    /// @param key 真实整数或完整字符串 key；__gc 留给类型注册，不能经普通字段写入。
    /// @param value 要写入的值；nullptr 删除字段，table/userdata 保存同一 Lua 对象引用。
    /// @return 写入成功为 true；值或 key 非法时返回 false，原字段不变。
    /// @note 有 owner 时记录错误；无 owner 的失效句柄只返回 false。Lua 分配失败交 invoke 处理。
    template <typename Key, typename T> bool writeValue(const Key &key, const T &value)
    {
        if (!requireValid())
        {
            return false;
        }
        detail::StackRestore stack(binding_->state_);
        if (!pushWriteKey(key) || !binding_->pushValue(value))
        {
            return false;
        }
        // [S, table, key, value] -> [S, table]：rawset 消耗 key/value，不调用 __newindex。
        // lua_rawset：消耗栈顶 key/value 并写入目标 table：[S, key, value] -> [S]；不调用 __newindex，写 nil 等价于删除字段。
        detail::rawSet(binding_->state_);
        return true;
    }

    /// 同步遍历无序字段；每轮视图仅在该次 visitor 内有效，不得修改源表或 yield。
    /// @param visitor 接收当前 key/value 的同步函数；true 继续，false 表示失败并立即停止。
    /// @return 遍历完毕为 true；visitor 失败或句柄非法为 false，有 owner 时记录诊断。
    /// @note visitor 未记录新错误就返回 false 时补 INTERNAL_ERROR；C++ 异常恢复栈后继续向外传播。
    bool forEach(const std::function<bool(const LuaValue &, const LuaValue &)> &visitor) const;
    /// rawlen 只给出数组边界，不承诺无空洞；失败保持输出。
    /// @param output 输出长度；失败时保留原值。
    /// @return 成功读取时返回 true。
    bool arrayLength(std::size_t &output) const;
    /// 只检查正整数 key 的连续 1..N；忽略其它 key，空数组得到 0。
    /// @param output 输出连续长度；失败时保留原值。
    /// @return 成功完成检查时返回 true。
    bool denseArrayLength(std::size_t &output) const;

    /// 将 Lua C 回调直接注册为函数或闭包；upvalue 按 Lua 原生编号读取。
    /// @note void* 为借用指针；Table/本封装管理的 userdata 由闭包强引用。
    /// Values... 与 upvalues... 一一对应；实参顺序就是 closure 的 upvalue 顺序，允许零个。
    /// @param name 写入此 LuaTable 的字段名。
    /// @param callback Lua C 回调；通过标准 int(lua_State *) 签名接收参数和返回值。
    /// @param upvalues 按顺序捕获到闭包的值；可为空，编号从 1 开始。
    /// @return 注册成功返回 true；失败记录错误并在作用域结束时恢复临时栈。
    template <typename... Values>
    bool setFunction(const std::string &name, Callback callback, const Values &...upvalues)
    {
        static_assert(sizeof...(Values) <= detail::kMaxUpvalues,
                      "Lua C closures support at most 255 upvalues");
        if (!requireValid())
        {
            return false;
        }
        detail::ensureStack(binding_->state_, static_cast<int>(sizeof...(Values)) + 4);
        // 记录当前栈高；函数退出时清掉本次压入的临时值，不撤销已经完成的 table 写入。
        detail::StackRestore stack(binding_->state_);

        // 压入目标 table 和字段名，再按顺序压入调用方提供的 upvalue：
        // [S] -> [S, table, key, upvalue1, ..., upvalueN]。
        // 任一步失败都提前返回，由 StackRestore 清理已压入的临时值。
        if (!pushWriteKey(name) || !binding_->pushValues(upvalues...))
        {
            return false;
        }

        // sizeof...(Values) 在编译期计算 upvalue 数量；零个参数时传 0。
        // lua_pushcclosure 消耗栈顶 N 个 upvalue 并压入闭包函数，不消耗 table/key：
        // [S, table, key, upvalue1, ..., upvalueN] -> [S, table, key, function]。
        // 闭包按传入顺序保存 upvalue，读取时从 lua_upvalueindex(1) 开始。
        detail::pushClosure(binding_->state_, callback, sizeof...(Values));

        // 此时 -3 指向目标 table；lua_rawset 消耗 key 和 function，直接写 table[key]，不触发 __newindex：
        // [S, table, key, function] -> [S, table]。
        detail::rawSet(binding_->state_);

        // 返回时 StackRestore 再移除临时 table，栈恢复为 [S]；table[key] 的写入保留。
        return true;
    }

    /// 为当前 table 设置元表，保持两张表的对象身份。
    /// @param meta 必须属于同一个 LuaBinding 的有效表句柄；当前接口不通过失效句柄表达移除元表。
    /// @return 设置成功为 true；句柄或所属 Binding 不匹配时返回 false，有 owner 时记录错误。
    /// @note 目标变化保留；临时栈恢复，元表引用不被销毁。
    bool setMetatable(const LuaTable &meta);
    /// 无 metatable 视为正常读取失败，记录 INVALID_ARGUMENT。
    /// @param output 输出 metatable 借用句柄；失败时保留原句柄。
    /// @return 成功读取时返回 true。
    bool readMetatable(LuaTable &output) const;

    /// 读取字段中的已注册 userdata；返回本回调内借用的 T*。
    /// @param key Lua 整数 key 或完整字符串 key。
    /// @param name 注册 userdata 时使用的精确类型名。
    /// @param output 输出借用指针；失败时保留原指针。
    /// @return 类型匹配时返回 true。
    template <typename Key, typename T>
    bool readUserdata(const Key &key, const std::string &name, T *&output) const
    {
        if (!requireValid())
        {
            return false;
        }
        detail::StackRestore stack(binding_->state_);
        return pushField(key) && binding_->readUserdataAt(-1, name, output);
    }

  private:
    friend class LuaBinding;
    LuaTable(LuaBinding *lua_binding, int reference);
    // 拒绝失效句柄；默认/移动后句柄没有 owner，不可能替它记录某个 Binding 的错误。
    bool requireValid() const;
    void push() const;
    /// 为字段读取准备 Lua 栈，不负责 C++ 类型转换。
    /// 成功时把当前 table 和 key 对应的字段值放入栈顶，栈变化为 [S] -> [S, table, value]；
    /// table 保留在 value 下方，调用方随后可用 -1 读取 value。字符串和整数 key 都走同一套 raw 读取语义。
    /// 该函数通常由 readValue、readTable、readTruth 或 readUserdata 调用，成功后立即由具体接口消费栈顶 value。
    /// 失败时不承诺新增栈项；调用方必须由 StackRestore 或等价逻辑恢复临时栈。
    /// @param key 要读取的 Lua 整数 key；范围检查由 pushValue 完成，不默默截断。
    /// @return key 合法且字段读取准备成功时返回 true。
    template <typename T>
    typename std::enable_if<std::is_integral<T>::value && !std::is_same<T, bool>::value, bool>::type
    pushField(T key) const
    {
        push();
        if (!binding_->pushValue(key))
        {
            return false;
        }
        // [S, table, integer-key] -> [S, table, value]；先检查 key 范围，不默默截断 uint64。
        // lua_rawget：消耗栈顶 key 并压入原始字段值：[S, key] -> [S, value]；不触发 __index，目标 table 不弹出。
        lua_rawget(binding_->state_, -2);
        return true;
    }
    /// 字符串 key 的字段读取版本；行为和整数 key 的 pushField 相同。
    /// 使用完整字节长度压入 key，支持包含内嵌零字节的字符串；只做 raw 读取，不触发 __index。
    /// @param key 要读取的完整 Lua 字符串 key。
    /// @return 字段读取准备成功时返回 true。
    bool pushField(const std::string &key) const;
    // 准备整数写入键：[S] -> [S,table,key]；范围检查失败留下的临时表由外层恢复。
    template <typename T>
    typename std::enable_if<std::is_integral<T>::value && !std::is_same<T, bool>::value, bool>::type
    pushWriteKey(T key) const
    {
        push();
        return binding_->pushValue(key);
    }
    // 准备完整字节串键并拒绝覆盖 __gc；成功留下 [S,table,key]，失败交外层恢复临时栈。
    bool pushWriteKey(const std::string &key) const;
    bool visitEntries(int                                                            table_index,
                      const std::function<bool(const LuaValue &, const LuaValue &)> &visitor) const;
    void reset() noexcept;

    LuaBinding *binding_   = nullptr;   // 借用当前同步回调，必须比本句柄活得久。
    int         reference_ = LUA_NOREF; // 独立 registry 引用，移动后源句柄失效。
};
} // namespace flywow_lua_binding
