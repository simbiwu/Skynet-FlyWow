// 职责：提供 HotUpgrade 的路径校验和补丁枚举能力。
// 边界：只处理本模块的同步文件操作；Lua 参数、结果和错误统一由 lua_binding
// 管理。
#define _XOPEN_SOURCE 700

#include "lua_binding.h"
#include "lua_table.h"
#include <cerrno>
#include <climits>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <exception>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <utility>
#include <vector>

namespace
{
using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;
// 单次补丁扫描的硬上限：文件数、总 Lua 字节数和单文件字节数分别独立校验。
constexpr std::size_t kMaxLuaFiles   = 1024;
constexpr std::size_t kMaxTotalBytes = 16U * 1024U * 1024U;
constexpr std::size_t kMaxFileBytes  = 2U * 1024U * 1024U;

// C++ 分配或容器操作异常不得越过 Lua C 回调边界；错误结果沿 Native 的 nil/error 合同返回。
int pushNativeException(lua_State *state)
{
    // 参数栈槽由 Lua 在返回时清理；只追加 nil 和稳定错误 record，不依赖可能已耗尽的 C++ 分配。
    // [...args] -> [...args, nil, {code=..., message=...}]；返回 2 后 VM 取最顶端两个结果。
    lua_pushnil(state);
    lua_createtable(state, 0, 2);
    lua_pushliteral(state, "HU_NATIVE_EXCEPTION");
    lua_setfield(state, -2, "code");
    lua_pushliteral(state, "native operation failed");
    lua_setfield(state, -2, "message");
    return 2;
}

struct FileList
{
    std::vector<std::string> paths; ///< 分类目录下的相对 Lua 路径，供 Lua 推导模块名并读取源码。
    std::size_t total_bytes = 0;    ///< 已接受文件累计大小；与单文件上限共同限制扫描占用。
};

// realpath 要求目标已存在；输出规范化绝对路径，供后续根目录包含关系校验。
// path 含空字节、超出 PATH_MAX 或无法解析时返回 false，不写入有效 output。
bool resolvePath(const std::string &path, std::string &output)
{
    if (path.empty() || path.size() >= PATH_MAX || path.find('\0') != std::string::npos)
    {
        return false;
    }
    char resolved[PATH_MAX];
    if (realpath(path.c_str(), resolved) == nullptr)
    {
        return false;
    }
    output = resolved;
    return true;
}

// 递归枚举受信任根目录内的普通 Lua 文件；拒绝符号链接/特殊文件，并累计资源上限。
// 返回 0 成功，-1 路径/文件结构无效，-2 超出文件数或字节预算。
int scanDirectory(const std::string &root, const std::string &directory,
                  const std::string &relative, FileList &files)
{
    // DIR 归当前递归层所有；字符串/vector 分配异常也必须关闭，不泄漏祖先层的目录 fd。
    const std::unique_ptr<DIR, int (*)(DIR *)> directory_handle(opendir(directory.c_str()),
                                                                closedir);
    DIR                                       *handle = directory_handle.get();
    if (handle == nullptr)
    {
        return -1;
    }
    int status = 0;
    while (true)
    {
        errno         = 0;
        dirent *entry = readdir(handle);
        if (entry == nullptr)
        {
            if (errno != 0)
            {
                status = -1;
            }
            break;
        }
        if (std::strcmp(entry->d_name, ".") == 0 || std::strcmp(entry->d_name, "..") == 0)
        {
            continue;
        }
        const std::string absolute = directory + "/" + entry->d_name;
        const std::string child_relative =
            relative.empty() ? entry->d_name : relative + "/" + entry->d_name;
        if (absolute.size() >= PATH_MAX || child_relative.size() >= PATH_MAX)
        {
            status = -1;
            break;
        }
        // lstat 检查链接本身，不跟随链接目标；递归和源码读取只接受普通目录/文件。
        struct stat attributes;
        if (lstat(absolute.c_str(), &attributes) != 0 || S_ISLNK(attributes.st_mode))
        {
            status = -1;
            break;
        }
        if (S_ISDIR(attributes.st_mode))
        {
            // 同一个 FileList 贯穿递归，因此数量和累计字节上限覆盖整棵分类子树。
            status = scanDirectory(root, absolute, child_relative, files);
            if (status != 0)
            {
                break;
            }
            continue;
        }
        if (!S_ISREG(attributes.st_mode))
        {
            status = -1;
            break;
        }
        const std::string name = entry->d_name;
        if (name.size() < 4 || name.compare(name.size() - 4, 4, ".lua") != 0)
        {
            continue;
        }
        // 非 Lua 普通文件不计入源码数量和字节预算；Lua 文件在保存路径前先检查上限。
        const std::size_t file_bytes = static_cast<std::size_t>(attributes.st_size);
        if (files.paths.size() >= kMaxLuaFiles || files.total_bytes > kMaxTotalBytes ||
            file_bytes > kMaxFileBytes || files.total_bytes + file_bytes > kMaxTotalBytes)
        {
            status = -2;
            break;
        }
        char canonical[PATH_MAX];
        if (realpath(absolute.c_str(), canonical) == nullptr)
        {
            status = -1;
            break;
        }
        // realpath 复核规范化目标仍在 root 内，阻止扫描期间目录路径被替换后越界。
        const std::string canonical_path = canonical;
        if (canonical_path.size() <= root.size() ||
            canonical_path.compare(0, root.size(), root) != 0 || canonical_path[root.size()] != '/')
        {
            status = -1;
            break;
        }
        files.paths.push_back(child_relative);
        files.total_bytes += file_bytes;
    }
    return status;
}

// 校验补丁目录必须位于 root 下，再扫描白名单分类；1 表示分类目录或内容为空。
int listLuaFiles(const std::string &root_argument, const std::string &relative,
                 const std::string &category, std::vector<std::string> &output)
{
    if (root_argument.empty() || relative.empty() || root_argument.size() >= PATH_MAX ||
        relative.size() >= PATH_MAX || root_argument.find('\0') != std::string::npos ||
        relative.find('\0') != std::string::npos || relative[0] == '/' ||
        relative.find("..") != std::string::npos)
    {
        return -1;
    }
    std::string root;
    if (!resolvePath(root_argument, root))
    {
        return -1;
    }
    std::string patch;
    if (!resolvePath(root + "/" + relative, patch) || patch.size() <= root.size() ||
        patch.compare(0, root.size(), root) != 0 || patch[root.size()] != '/')
    {
        return -1;
    }
    if (category != "modules" && category != "services")
    {
        return -1;
    }
    const std::string directory = patch + "/" + category;
    struct stat       attributes;
    if (lstat(directory.c_str(), &attributes) != 0)
    {
        // 只有确实缺省的分类允许为空；权限/I/O 错误不能把 Patch 静默裁成另一半。
        return errno == ENOENT ? 1 : -1;
    }
    if (S_ISLNK(attributes.st_mode) || !S_ISDIR(attributes.st_mode))
    {
        return -1;
    }
    FileList  files;
    const int status = scanDirectory(root, directory, "", files);
    if (status != 0)
    {
        return status == -2 ? -2 : -1;
    }
    if (files.paths.empty())
    {
        return 1;
    }
    output = std::move(files.paths);
    return 0;
}

// 参数 1 是必须已存在的路径。成功返回规范化绝对路径；失败返回 nil/error。
int resolve(lua_State *state)
{
    try
    {
        // 参数读取不改变原栈槽；成功压入路径，失败追加 nil/error 两个结果。
        // [S, input] -> [S, input, canonical_path] 或 [S, input, nil, error]；VM 取回调返回数。
        LuaBinding  binding(state);
        std::string input;
        if (!binding.readValue(1, input))
        {
            return binding.pushError();
        }
        std::string output;
        if (!resolvePath(input, output))
        {
            return binding.pushError(input.empty() ? "HU_INVALID_PATH" : "HU_FILE_NOT_FOUND",
                                     "path cannot be resolved");
        }
        return binding.returnValues(output);
    }
    catch (const std::exception &)
    {
        return pushNativeException(state);
    }
    catch (...)
    {
        return pushNativeException(state);
    }
}

// 参数依次为 Patch Root、相对 Patch 目录和允许的分类名；readValue 不改变参数栈。
// LuaTable 以 registry 引用临时持有结果 table；returnValues 压入它并返回 1，
// C++ 句柄析构只释放自身引用，不移除 Lua 返回栈中已压入的 table。
int list_lua(lua_State *state)
{
    try
    {
        // 三个 readValue 只读取原参数槽；临时 table 由 registry 引用持有，不占用工作栈。
        // returnValues 压入 table 后：[S, root, relative, category] -> [..., result_table]；
        // 返回 1 时 VM 保留最顶层 table，LuaTable 析构 unref 不弹栈或移除它。
        LuaBinding  binding(state);
        std::string root;
        std::string relative;
        std::string category;
        if (!binding.readValue(1, root) || !binding.readValue(2, relative) ||
            !binding.readValue(3, category))
        {
            return binding.pushError();
        }
        std::vector<std::string> paths;
        const int                status = listLuaFiles(root, relative, category, paths);
        if (status != 0)
        {
            return binding.pushError(status == 1    ? "HU_PATCH_EMPTY"
                                     : status == -2 ? "HU_PATCH_LIMIT"
                                                    : "HU_INVALID_PATH",
                                     "patch Lua file list is invalid or empty");
        }
        LuaTable output = binding.newTable();
        if (!output.valid())
        {
            return binding.pushError();
        }
        for (std::size_t i = 0; i < paths.size(); ++i)
        {
            if (!output.writeValue(static_cast<std::int64_t>(i + 1), paths[i]))
            {
                return binding.pushError();
            }
        }
        return binding.returnValues(output);
    }
    catch (const std::exception &)
    {
        return pushNativeException(state);
    }
    catch (...)
    {
        return pushNativeException(state);
    }
}

} // namespace

// 模块加载入口只创建并返回公开函数表。LuaTable 封装在局部作用域恢复临时栈项；
// returnValues 最后压入模块 table 并返回 1，不把临时栈槽暴露给调用者。
extern "C" int luaopen_flywow_hotupgrade_native(lua_State *state)
{
    try
    {
        // newTable 的 registry 引用不改变原栈；returnValues 再压入模块 table 作为唯一返回值。
        // [S] -> [S, module]；返回 1 后 VM 保留该 table，Binding 析构只释放临时引用。
        LuaBinding binding(state);
        LuaTable   module = binding.newTable();
        if (!module.valid() || !module.setFunction("resolve", resolve) ||
            !module.setFunction("list_lua", list_lua))
        {
            return binding.pushError();
        }
        return binding.returnValues(module);
    }
    catch (...)
    {
        // luaopen_* 必须以 Lua 加载错误结束，不能把 C++ 异常或 nil 模块结果交给 require。
        lua_pushliteral(state, "HotUpgrade native module initialization failed");
        return lua_error(state);
    }
}
