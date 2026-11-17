// 职责：以独立 registry 引用隐藏 table 的字段访问和临时栈。
// 句柄可移动、不可复制；只在所属 Binding 的同步回调内使用。
// 栈预留或 C++ 分配异常由注册处 nativeCallback 处理；bool 不表示 noexcept。
#pragma once
#include "lua_binding.h"

namespace flywow_lua_binding
{
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

    // raw 读取字段并严格转换，不触发 __index。
    /// @param key 真实整数或完整字符串 key。
    /// @param output 严格类型转换的输出，失败不覆盖。
    /// @return 读取成功 true；无效句柄、类型或 Lua 操作错误 false。
    template <typename Key, typename T> bool readValue(const Key &key, T &output) const
    {
        if (!valid())
            return false;
        detail::StackRestore stack(binding_->state_);
        return readField(key) && binding_->readAt(-1, output);
    }

    // 子表直接在同一次字段读取中建立引用；失败不覆盖 output。
    /// @param key 存放子表的字段。
    /// @param output 成功获得独立子表引用，仍借用本 Binding。
    /// @return 读取成功 true；失败 false，保持输出。
    template <typename Key> bool readTable(const Key &key, LuaTable &output) const
    {
        if (!valid())
            return false;
        detail::StackRestore stack(binding_->state_);
        return readField(key) && binding_->readTableAt(-1, output);
    }

    /// 只判断字段是否 nil；非 nil 或无效句柄均返回 false，不代替读取结果检查。
    template <typename Key> bool isNil(const Key &key) const
    {
        if (!valid())
            return false;
        detail::StackRestore stack(binding_->state_);
        return readField(key) && lua_isnil(binding_->state_, -1);
    }

    // Lua 真值：nil/false 为假；0 和空串为真。
    /// @param key 待读取字段。
    /// @param output 成功时接收 Lua 真值；失败保持不变。
    /// @return 字段读取成功 true；无效句柄或 Lua 操作失败 false。
    template <typename Key> bool readTruth(const Key &key, bool &output) const
    {
        if (!valid())
            return false;
        detail::StackRestore stack(binding_->state_);
        return readField(key) && binding_->readTruthAt(-1, output);
    }

    /// 读取可选标量字段；省略或 nil 时保留调用方默认值，显式值按 readValue 转换。
    /// @param key 待读取字段；通过一次 raw 查找取得值。
    /// @param output 缺省时保持原值；显式值转换成功后覆盖。
    /// @return 缺省或读取成功为 true；句柄或字段类型、范围错误时为 false。
    template <typename Key, typename T> bool readOptionalValue(const Key &key, T &output) const
    {
        if (!valid())
        {
            return false;
        }
        detail::StackRestore stack(binding_->state_);
        return readField(key) && (lua_isnil(binding_->state_, -1) || binding_->readAt(-1, output));
    }

    /// 读取可选子表；同一次查找决定保留默认句柄或接管子表引用。
    /// @param key 可省略的子表字段。
    /// @param output 缺省时保持原句柄；成功读取子表后替换。
    /// @return 字段为 nil 或取得子表为 true；显式值不是 table 或句柄无效时为 false。
    template <typename Key> bool readOptionalTable(const Key &key, LuaTable &output) const
    {
        if (!valid())
        {
            return false;
        }
        detail::StackRestore stack(binding_->state_);
        return readField(key) &&
               (lua_isnil(binding_->state_, -1) || binding_->readTableAt(-1, output));
    }

    /// 读取可选字段的 Lua 真值；nil 保留默认值，显式 false 覆盖默认值。
    /// @param key 待读取字段；通过一次 raw 查找取得值。
    /// @param output 调用方预置默认值；非 nil 时接收 Lua 真值。
    /// @return 缺省或读取成功为 true；句柄或 key 不合法时为 false。
    template <typename Key> bool readOptionalTruth(const Key &key, bool &output) const
    {
        if (!valid())
        {
            return false;
        }
        detail::StackRestore stack(binding_->state_);
        return readField(key) &&
               (lua_isnil(binding_->state_, -1) || binding_->readTruthAt(-1, output));
    }

    // 转换在当前 C++ 作用域完成。共享表 raw 写入由单独的保护调用捕获。
    /// @param key 真实整数或完整字符串 key。
    /// @param value 要保存的值；nullptr 删除字段，table/userdata 不复制对象。
    /// @return 写入成功为 true；失败为 false 并记录诊断（无 owner 的句柄除外）。
    template <typename Key, typename T> bool writeValue(const Key &key, const T &value)
    {
        static_assert((std::is_integral_v<Key> && !std::is_same_v<Key, bool>) ||
                      std::is_convertible_v<const Key &, std::string>);
        if (!valid())
        {
            return false;
        }

        auto *state = binding_->state_; // 当前回调的 Lua 栈，临时项随本函数退出清除。
        detail::StackRestore stack(state);
        // table/key 两槽外，预留 value 转换的峰值空间，也足够检查托管析构或压入写入回调。
        if (!lua_checkstack(state, 2 + detail::kPushValueStackSlots))
        {
            binding_->setError("INTERNAL_ERROR", "Native table write exceeds stack capacity");
            return false;
        }

        // [S] -> [S, table, key]；先拒绝覆盖托管 __gc，再转换 value。
        const char *failure = nullptr; // codec 报告的类型或范围错误。
        push();
        if (!binding_->pushRaw(state, key, &failure))
        {
            binding_->setError("INVALID_ARGUMENT", failure);
            return false;
        }
        if (!LuaBinding::canWriteField(state, -2, -1))
        {
            binding_->setError("INVALID_ARGUMENT", "__gc is managed by userdata registration");
            return false;
        }
        if (!binding_->pushRaw(state, value, &failure))
        {
            binding_->setError("INVALID_ARGUMENT", failure);
            return false;
        }
        return writeField();
    }

    /// 验证正整数 key 为连续 1..N，忽略其他 key；空数组输出 0，失败保持输出。
    bool denseArrayLength(std::size_t &output) const;

    /// @param key 含托管 userdata 的字段。
    /// @param name 精确注册类型名。
    /// @param output 本回调借用的 T*，失败保持原值。
    /// @return 类型匹配且存活为 true；失败 false 并记录诊断。
    template <typename Key, typename T>
    bool readUserdata(const Key &key, const std::string &name, T *&output) const
    {
        if (!valid())
            return false;
        detail::StackRestore stack(binding_->state_);
        return readField(key) && binding_->readUserdataAt(-1, name, output);
    }

  private:
    friend class LuaBinding;
    /// 接管已经建立的 registry 引用；只由 Binding 和字段读取路径创建。
    /// @param binding 借用的同步回调 owner，必须晚于句柄销毁。
    /// @param reference 要接管的独立 registry 引用编号。
    LuaTable(LuaBinding *binding, int reference);

    /// 将句柄引用的原表压入栈顶，不触发元方法；调用方保证句柄有效。
    /// @return 无返回值；栈顶新增一份临时表引用。
    void push() const;

    /// 保护性写入栈顶的 table/key/value；调用方负责恢复临时栈。
    /// @return 写入成功为 true；Lua 拒绝写入时记录 INTERNAL_ERROR 并返回 false。
    bool writeField();

    /// 释放本句柄的 registry 引用并清空 owner；Lua 中其他引用仍可保活原表。
    /// @return 无返回值；空句柄可重复调用。
    void reset() noexcept;

    /// 直接 raw 读取字段，不执行元方法；调用方用 StackRestore 恢复临时栈。
    /// @param key 要读取的整数或字符串字段名。
    /// @return 成功时栈顶留下字段值；key 转换失败时记录诊断并返回 false。
    template <typename Key> bool readField(const Key &key) const
    {
        static_assert((std::is_integral_v<Key> && !std::is_same_v<Key, bool>) ||
                      std::is_convertible_v<const Key &, std::string>);
        push();
        const char *failure = nullptr; // key 类型或范围转换失败的诊断。
        if (!binding_->pushRaw(binding_->state_, key, &failure))
        {
            binding_->setError("INVALID_ARGUMENT", failure);
            return false;
        }
        // [原栈, table, key] -> [原栈, table, value]，不触发 __index。
        lua_rawget(binding_->state_, -2);
        return true;
    }

    LuaBinding *binding_   = nullptr;   // 借用所属回调，不能晚于 Binding 销毁。
    int         reference_ = LUA_NOREF; // 独立 registry 引用；不代表栈索引。
};
} // namespace flywow_lua_binding
