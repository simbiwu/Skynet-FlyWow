// 职责：提供 HotUpgrade 的 hash、随机身份、路径校验、补丁枚举和审计追加能力。
// 边界：只处理本模块的同步文件操作；Lua 参数、结果和错误统一由 lua_binding
// 管理。
#define _XOPEN_SOURCE 700

#include "lua_binding.h"
#include "lua_table.h"
#include <cerrno>
#include <climits>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
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

struct FileList
{
    std::vector<std::string> paths; ///< 分类目录下的相对 Lua 路径，供 Lua 推导模块名并读取源码。
    std::size_t total_bytes = 0;    ///< 已接受文件累计大小；与单文件上限共同限制扫描占用。
};

// 输入是调用方提供的 Patch 身份字节；成功时把 32 字节摘要写成 64 个小写十六进制字符。
// EVP_Digest 失败或结果长度不符合 SHA-256 时返回 false，output 不作为错误文本使用。
bool makeDigest(const std::string &input, std::string &output)
{
    unsigned char bytes[EVP_MAX_MD_SIZE];
    unsigned int  length = 0;
    if (EVP_Digest(input.data(), input.size(), bytes, &length, EVP_sha256(), nullptr) == 0 ||
        length != 32)
    {
        return false;
    }
    static constexpr char kDigits[] = "0123456789abcdef";
    output.resize(length * 2);
    for (unsigned int i = 0; i < length; ++i)
    {
        output[i * 2]     = kDigits[bytes[i] >> 4];
        output[i * 2 + 1] = kDigits[bytes[i] & 15];
    }
    return true;
}

// 生成 128 位 OpenSSL CSPRNG 随机数，并编码为 32 个小写十六进制字符供实例/引用身份使用。
// 随机源失败时返回 false；调用方必须拒绝创建依赖此身份的对象。
bool makeNonce(std::string &output)
{
    unsigned char bytes[16];
    if (RAND_bytes(bytes, sizeof(bytes)) != 1)
    {
        return false;
    }
    static constexpr char kDigits[] = "0123456789abcdef";
    output.resize(sizeof(bytes) * 2);
    for (std::size_t i = 0; i < sizeof(bytes); ++i)
    {
        output[i * 2]     = kDigits[bytes[i] >> 4];
        output[i * 2 + 1] = kDigits[bytes[i] & 15];
    }
    return true;
}

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

// 文件 fsync 只保证文件内容；再 fsync 父目录，持久化新建文件的目录项。
// 返回 0 表示父目录同步成功；负值表示路径解析、open、fsync 或 close 失败。
int syncParent(const std::string &path)
{
    if (path.size() >= PATH_MAX)
    {
        return -1;
    }
    char parent[PATH_MAX];
    std::memcpy(parent, path.c_str(), path.size() + 1);
    char *slash = std::strrchr(parent, '/');
    if (slash == parent)
    {
        parent[1] = 0;
    }
    else if (slash != nullptr)
    {
        *slash = 0;
    }
    else
    {
        std::memcpy(parent, ".", 2);
    }
    const int descriptor = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (descriptor < 0)
    {
        return -1;
    }
    const int synced = fsync(descriptor);
    const int closed = close(descriptor);
    return synced == 0 && closed == 0 ? 0 : -1;
}

// 递归枚举受信任根目录内的普通 Lua 文件；拒绝符号链接/特殊文件，并累计资源上限。
// 返回 0 成功，-1 路径/文件结构无效，-2 超出文件数或字节预算。
int scanDirectory(const std::string &root, const std::string &directory,
                  const std::string &relative, FileList &files)
{
    DIR *handle = opendir(directory.c_str());
    if (handle == nullptr)
    {
        return -1;
    }
    int status = 0;
    while (true)
    {
        dirent *entry = readdir(handle);
        if (entry == nullptr)
        {
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
        struct stat attributes;
        if (lstat(absolute.c_str(), &attributes) != 0 || S_ISLNK(attributes.st_mode))
        {
            status = -1;
            break;
        }
        if (S_ISDIR(attributes.st_mode))
        {
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
    closedir(handle);
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
    if (category != "modules" && category != "services" && category != "migrations" &&
        category != "configs")
    {
        return -1;
    }
    const std::string directory = patch + "/" + category;
    struct stat       attributes;
    if (lstat(directory.c_str(), &attributes) != 0 || S_ISLNK(attributes.st_mode) ||
        !S_ISDIR(attributes.st_mode))
    {
        return 1;
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

// 以仅追加、禁止跟随符号链接的方式写审计记录；文件和父目录都同步后才报告成功。
bool appendSynchronized(const std::string &path, const std::string &bytes)
{
    if (path.empty() || path.size() >= PATH_MAX || path.find('\0') != std::string::npos)
    {
        return false;
    }
    const int descriptor =
        open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0)
    {
        return false;
    }
    std::size_t written = 0;
    while (written < bytes.size())
    {
        const ssize_t count = write(descriptor, bytes.data() + written, bytes.size() - written);
        if (count < 0 && errno == EINTR)
        {
            continue;
        }
        if (count <= 0)
        {
            close(descriptor);
            return false;
        }
        written += static_cast<std::size_t>(count);
    }
    const int synced = fsync(descriptor);
    const int closed = close(descriptor);
    return synced == 0 && closed == 0 && syncParent(path) == 0;
}

// 参数 1 是待计算的字节串。LuaBinding::readValue 不改变参数栈；pushError 返回 nil/error。
// 成功时 returnValues 压入一个摘要，返回数量 1；Lua 之后清理原始参数栈槽。
int sha256(lua_State *state)
{
    LuaBinding  binding(state);
    std::string input;
    if (!binding.readValue(1, input))
    {
        return binding.pushError();
    }
    std::string output;
    if (!makeDigest(input, output))
    {
        return binding.pushError("HU_CHECKSUM_FAILED", "SHA-256 calculation failed");
    }
    return binding.returnValues(output);
}

// 不读取参数。成功返回一个随机身份字符串；随机源失败时返回 nil/error。
int nonce(lua_State *state)
{
    LuaBinding  binding(state);
    std::string output;
    if (!makeNonce(output))
    {
        return binding.pushError("HU_IDENTITY_FAILED", "secure random generation failed");
    }
    return binding.returnValues(output);
}

// 参数 1 是必须已存在的路径。成功返回规范化绝对路径；失败返回 nil/error。
int resolve(lua_State *state)
{
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

// 参数依次为 Patch Root、相对 Patch 目录和允许的分类名；readValue 不改变参数栈。
// LuaTable 以 registry 引用临时持有结果 table；returnValues 压入它并返回 1，
// C++ 句柄析构只释放自身引用，不移除 Lua 返回栈中已压入的 table。
int list_lua(lua_State *state)
{
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

// 参数依次为审计文件路径和完整记录字节。只有文件及父目录同步成功才返回 true；
// 任何写入或同步失败均通过 nil/error 交付，不吞掉持久化失败。
int append_sync(lua_State *state)
{
    LuaBinding  binding(state);
    std::string path;
    std::string bytes;
    if (!binding.readValue(1, path) || !binding.readValue(2, bytes))
    {
        return binding.pushError();
    }
    if (!appendSynchronized(path, bytes))
    {
        return binding.pushError(path.empty() ? "HU_INVALID_PATH" : "HU_HISTORY_WRITE_FAILED",
                                 "history append or synchronization failed");
    }
    return binding.returnValues(true);
}

} // namespace

// 模块加载入口只创建并返回公开函数表。LuaTable 封装在局部作用域恢复临时栈项；
// returnValues 最后压入模块 table 并返回 1，不把临时栈槽暴露给调用者。
extern "C" int luaopen_flywow_hotupgrade_native(lua_State *state)
{
    LuaBinding binding(state);
    LuaTable   module = binding.newTable();
    if (!module.valid() || !module.setFunction("sha256", sha256) ||
        !module.setFunction("nonce", nonce) || !module.setFunction("resolve", resolve) ||
        !module.setFunction("list_lua", list_lua) ||
        !module.setFunction("append_sync", append_sync))
    {
        return binding.pushError();
    }
    return binding.returnValues(module);
}
