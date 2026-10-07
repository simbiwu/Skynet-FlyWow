// 职责：table 遍历回调中的短期 key/value 视图；不复制值、不持有 registry 引用。
#pragma once
#include "lua_binding.h"

namespace flywow_lua_binding
{
enum class LuaType
{
    kNil,
    kBoolean,
    kNumber, // Lua integer 或浮点 number；readValue<int> 仍要求严格 integer。
    kString,
    kTable,
    kFunction,
    kUserdata,      // full userdata；类型是否由本封装注册由读取时核验。
    kLightUserdata, // 借用 void*，Lua 不释放指向的 C++ 对象。
    kThread
};

/// 仅限当前 forEach visitor；不能复制、移动或保存到回调结束之后。
class LuaValue
{
  public:
    LuaValue(const LuaValue &)            = delete;
    LuaValue &operator=(const LuaValue &) = delete;
    LuaValue(LuaValue &&)                 = delete;
    LuaValue &operator=(LuaValue &&)      = delete;
    /// 当前值的 Lua 类型；读取不转换原始 key，保证 lua_next 可以继续迭代。
    LuaType type() const;
    bool isNil() const;
    /// 与位置参数相同的严格转换；失败保持输出并记录所属 Binding 的错误。
    /// @param output 输出对象；失败时保留原值。
    /// @return 成功完成严格类型检查时返回 true。
    template <typename T> bool readValue(T &output) const
    {
        return binding_->readAt(index_, output);
    }
    /// 将本轮 Table 值变为独立 registry 引用；句柄仍限当前 Binding 回调。
    /// @param output 输出 table 借用句柄；失败时保留原句柄。
    /// @return 当前值为 table 且引用创建成功时返回 true。
    bool readTable(LuaTable &output) const;
    /// 显式 Lua 真值读取，nil/false 为假；失败不改 output。
    /// @param output 输出布尔值；失败时保留原值。
    /// @return 成功读取时返回 true。
    bool readTruth(bool &output) const;

  private:
    friend class LuaTable;
    LuaValue(LuaBinding *binding, int index) : binding_(binding), index_(index)
    {
    }
    LuaBinding *binding_; // 当前 visitor 的 owner。
    int         index_;   // 固定绝对索引；嵌套压栈不会改变目标。
};
} // namespace flywow_lua_binding
