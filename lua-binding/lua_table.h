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

    // raw 读取字段；类型校验在保护调用外执行，C++ 字符串异常交给注册入口。
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
        FieldArguments<Key>  args{this, key};
        const bool           ok = detail::protectedCall(
            binding_->state_,
            [](lua_State *state) noexcept -> int
            {
                auto *data = static_cast<FieldArguments<Key> *>(lua_touserdata(state, 1));
                if (!getField(state, *data))
                    return 0;
                if (!lua_istable(state, -1))
                {
                    data->failure = "value must be a table";
                    return 0;
                }
                data->reference = luaL_ref(state, LUA_REGISTRYINDEX);
                return 0;
            },
            &args, 0, 0);
        if (!binding_->completeCall(ok, args.failure))
            return false;
        output = LuaTable(binding_, args.reference);
        return true;
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
    // 完整字段写入只进入一次 pcall；key/value 无效时不更新原字段。
    // 普通 table 可写任何合法 key；托管元表的 __gc 在注册与后续字段写入时均受保护。
    /// @param key 真实整数或完整字符串 key。
    /// @param value 要保存的值；nullptr 删除字段，table/userdata 不复制对象。
    /// @return 写入成功 true；失败 false 并记录诊断（无 owner 的句柄除外）。
    template <typename Key, typename T> bool writeValue(const Key &key, const T &value)
    {
        if (!valid())
            return false;
        detail::StackRestore stack(binding_->state_);
        struct Arguments
        {
            FieldArguments<Key> field; ///< 本次字段操作的目标表、key 与输出诊断。
            const T            &value; ///< 借用本次待写入的值，外层作用域覆盖保护调用。
        } args{{this, key}, value};
        const bool ok = detail::protectedCall(
            binding_->state_,
            [](lua_State *state) noexcept -> int
            {
                auto *data = static_cast<Arguments *>(lua_touserdata(state, 1));
                lua_rawgeti(state, LUA_REGISTRYINDEX, data->field.table->reference_);
                auto *binding = data->field.table->binding_;
                if (!pushKey(state, data->field))
                    return 0;
                if (!LuaBinding::canWriteField(state, -2, -1))
                {
                    data->field.failure = "__gc is managed by userdata registration";
                    return 0;
                }
                if (!binding->pushRaw(state, data->value, &data->field.failure))
                    return 0;
                lua_rawset(state, -3);
                return 0;
            },
            &args, 0, 0);
        return binding_->completeCall(ok, args.field.failure);
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
        struct Arguments
        {
            FieldArguments<Key> field; ///< 本次字段操作的目标表、key 与输出诊断。
            const std::string  &name;  ///< 借用本次字段/类型名称，不在保护回调中构造字符串。
            void               *object = nullptr; ///< 原生操作返回的借用地址；外层决定构造或保活。
        } args{{this, key}, name};
        const bool ok = detail::protectedCall(
            binding_->state_,
            [](lua_State *state) noexcept -> int
            {
                auto *data = static_cast<Arguments *>(lua_touserdata(state, 1));
                if (!getField(state, data->field))
                    return 0;
                data->object = LuaBinding::inspectUserdata(
                    state, -1, data->name.c_str(), data->field.reference, &data->field.failure);
                return 0;
            },
            &args, 0, 0);
        if (!binding_->completeCall(ok, args.field.failure) ||
            !binding_->retainUserdata(args.object, args.field.reference))
            return false;
        output = static_cast<T *>(args.object);
        return true;
    }

  private:
    friend class LuaBinding;
    LuaTable(LuaBinding *binding, int reference);
    void push() const;
    void reset() noexcept;

    template <typename Key> struct FieldArguments
    {
        const LuaTable *table;               ///< 本次操作的目标表句柄；registry 编号不代表栈位置。
        const Key      &key;                 ///< 借用原始字段 key，不执行隐式转换。
        const char     *failure   = nullptr; ///< 失败时由原生操作写入的常量原因；外层随后记录诊断。
        int             reference = LUA_NOREF; ///< 成功时建立的 registry 引用；外层接管或释放。
    };
    template <typename Key> static bool pushKey(lua_State *state, FieldArguments<Key> &data)
    {
        static_assert((std::is_integral_v<Key> && !std::is_same_v<Key, bool>) ||
                      std::is_convertible_v<const Key &, std::string>);
        return data.table->binding_->pushRaw(state, data.key, &data.failure);
    }
    // 仅供 C 回调使用；成功留下 table/value，原始 key 不发生隐式转换。
    template <typename Key> static bool getField(lua_State *state, FieldArguments<Key> &data)
    {
        lua_rawgeti(state, LUA_REGISTRYINDEX, data.table->reference_);
        if (!pushKey(state, data))
            return false;
        lua_rawget(state, -2);
        return true;
    }
    template <typename Key> bool readField(const Key &key) const
    {
        FieldArguments<Key> args{this, key};
        const bool          ok = detail::protectedCall(
            binding_->state_,
            [](lua_State *state) noexcept -> int
            {
                auto *data = static_cast<FieldArguments<Key> *>(lua_touserdata(state, 1));
                return getField(state, *data) ? 1 : 0;
            },
            &args, 0, 1);
        return binding_->completeCall(ok, args.failure);
    }

    LuaBinding *binding_   = nullptr;   // 借用所属回调，不能晚于 Binding 销毁。
    int         reference_ = LUA_NOREF; // 独立 registry 引用；不代表栈索引。
};
} // namespace flywow_lua_binding
