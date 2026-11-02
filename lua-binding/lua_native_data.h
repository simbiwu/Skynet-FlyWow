// NativeData 将业务字段保存在 C++ 树中；Lua userdata 仅持有根所有权或节点失效记录。
#pragma once
#include "lua_binding.h"
#include <map>
#include <memory>
#include <variant>

namespace flywow_lua_binding
{
class LuaNativeData;

/// 每个节点与其 Lua 代理共享失效通知；不拥有节点。
struct LuaNativeDataProxyState
{
    LuaNativeData *node = nullptr; ///< 节点存活时指向节点自身；析构前清空。
};

using LuaNativeDataKey = std::variant<std::int64_t, std::string>;
using LuaNativeDataValue =
    std::variant<bool, std::int64_t, double, std::string, std::unique_ptr<LuaNativeData>>;

/// 单 owner 数据树；不保存 Lua State、registry 引用或其他 Lua 对象，不允许跨线程共享修改。
class LuaNativeData
{
  public:
    using FieldMap = std::map<LuaNativeDataKey, LuaNativeDataValue>;
    /// 创建空节点及其独立的代理有效性记录。
    LuaNativeData();
    /// 先使本节点代理失效，再由字段容器释放全部独占子树。
    ~LuaNativeData() noexcept;
    LuaNativeData(const LuaNativeData &)            = delete;
    LuaNativeData &operator=(const LuaNativeData &) = delete;

    /// 查找字段；未找到返回 nullptr，返回地址仅在该字段未被替换或删除期间有效。
    /// @param key 调用方提供的整数或二进制安全字符串键。
    const LuaNativeDataValue *get(const LuaNativeDataKey &key) const;
    /// 移入完整值并替换字段；调用前须完成转换或复制。
    /// @param key 写入字段的键。
    /// @param value 标量或独占子树；空子树指针非法，抛出 invalid_argument。
    void set(const LuaNativeDataKey &key, LuaNativeDataValue value);
    /// 删除字段；不存在时无操作，删除子树会使其所有旧代理失效。
    /// @param key 待删除字段的键。
    void erase(const LuaNativeDataKey &key);
    /// 递归复制整棵子树；每个新节点都有独立身份和 ProxyState。
    /// @return 调用方独占的新子树，不与来源共享子节点。
    std::unique_ptr<LuaNativeData> clone() const;
    std::size_t size() const noexcept;
    /// @return 从整数键 1 开始的连续前缀长度，忽略其他键。
    std::size_t arrayLength() const;
    const FieldMap &fields() const noexcept;
    const std::shared_ptr<LuaNativeDataProxyState> &proxyState() const noexcept;

  private:
    FieldMap fields_; ///< 当前节点字段；其中 unique_ptr 是子节点的唯一 owner。
    std::shared_ptr<LuaNativeDataProxyState> proxy_state_; ///< 节点和代理共享的失效通知。
};

/// placement-new 在 full userdata 内构造；alive uservalue 保证析构一次。
struct LuaNativeDataUserdata
{
    std::shared_ptr<LuaNativeData>           root_owner; ///< 根代理持有根；子代理为空，不保活子树。
    std::shared_ptr<LuaNativeDataProxyState> proxy_state; ///< 指向本代理节点的有效性记录。
};

namespace detail
{
template <> struct ValueCodec<std::shared_ptr<LuaNativeData>>
{
    /// 在现有 returnValues 路径中返回同一个根对象；不复制树，空根返回转换失败。
    /// @param state 本次同步回调的 Lua State，元表按 State 幂等注册。
    /// @param root C++ 创建并可自行继续持有的根 owner。
    /// @param reason 失败时输出静态诊断；成功不写。
    static bool push(lua_State *state, const std::shared_ptr<LuaNativeData> &root,
                     const char **reason);
};
} // namespace detail
} // namespace flywow_lua_binding
