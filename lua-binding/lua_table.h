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
    /// @param output 输出 table；成功时写入借用句柄。
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

    /// 缺省字段判断；无效句柄/非法 key 返回 false 并记录错误。
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

    /// raw 写入；nullptr 删除字段，table/userdata 保留同一 Lua 对象引用。
    /// @return 失败时原字段不变，错误记录在所属 Binding。
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
        lua_rawset(binding_->state_, -3);
        return true;
    }

    /// 遍历无序 key/value；visitor false 表示失败。禁止修改源表或 yield。
    /// @note LuaValue 只在本轮 visitor 内有效；嵌套操作的临时栈由内部恢复。
    bool forEach(const std::function<bool(const LuaValue &, const LuaValue &)> &visitor) const;
    /// rawlen 只给出数组边界，不承诺无空洞；失败保持输出。
    /// @param output 输出长度；失败时保留原值。
    /// @return 成功读取时返回 true。
    bool arrayLength(std::size_t &output) const;
    /// 只检查正整数 key 的连续 1..N；忽略其它 key，空数组得到 0。
    /// @param output 输出连续长度；失败时保留原值。
    /// @return 成功完成检查时返回 true。
    bool denseArrayLength(std::size_t &output) const;

    /// 普通函数和闭包统一注册；最多 254 个业务 upvalue。
    /// @note void* 为借用指针；Table/本封装管理的 userdata 由闭包强引用。
    template <typename... Values>
    bool setFunction(const std::string &name, Callback callback, const Values &...upvalues)
    {
        if (!requireValid())
        {
            return false;
        }
        detail::StackRestore stack(binding_->state_);
        if (callback == nullptr || sizeof...(Values) > 254)
        {
            binding_->setError("INVALID_ARGUMENT", "invalid callback or too many upvalues");
            return false;
        }
        // Lua C 回调只保证少量可用槽。closure 可有 255 个 upvalue，必须提前扩容，
        // 不能依赖未检查的连续 push；table/key/descriptor 另外占 3 个槽。
        if (!binding_->reserveStack(3 + static_cast<int>(sizeof...(Values))))
        {
            return false;
        }
        if (!pushWriteKey(name))
        {
            return false;
        }
        pushCallback(callback);
        if (!binding_->pushValues(upvalues...))
        {
            return false;
        }
        // [S, table, key, descriptor, uv...] -> [S, table, key, closure]。
        // closure 消耗全部 upvalue；descriptor 保存真正函数指针，不转成 void*。
        // lua_pushcclosure：把栈顶指定数量的值作为 upvalue 消耗并压入 C 闭包；内部 descriptor 位于槽 1，业务 upvalue 从槽 2 开始。
        lua_pushcclosure(binding_->state_, &LuaBinding::dispatch, 1 + sizeof...(Values));
        // lua_rawset：消耗栈顶 key/value 并写入目标 table：[S, key, value] -> [S]；不调用 __newindex，写 nil 等价于删除字段。
        lua_rawset(binding_->state_, -3);
        return true;
    }

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
    LuaTable(LuaBinding *binding, int reference);
    bool requireValid() const;
    bool push() const;
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
        if (!push())
        {
            return false;
        }
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
    template <typename T>
    typename std::enable_if<std::is_integral<T>::value && !std::is_same<T, bool>::value, bool>::type
    pushWriteKey(T key) const
    {
        if (!push())
        {
            return false;
        }
        return binding_->pushValue(key);
    }
    bool pushWriteKey(const std::string &key) const;
    void pushCallback(Callback callback);
    bool visitEntries(int                                                            table_index,
                      const std::function<bool(const LuaValue &, const LuaValue &)> &visitor) const;
    void reset() noexcept;

    LuaBinding *binding_   = nullptr;   // 借用当前同步回调，必须比本句柄活得久。
    int         reference_ = LUA_NOREF; // 独立 registry 引用，移动后源句柄失效。
};
} // namespace flywow_lua_binding
