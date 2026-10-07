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

namespace {
using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;
constexpr std::size_t kMaxLuaFiles = 1024;
constexpr std::size_t kMaxTotalBytes = 16U * 1024U * 1024U;
constexpr std::size_t kMaxFileBytes = 2U * 1024U * 1024U;

struct FileList {
  std::vector<std::string> paths;
  std::size_t total_bytes = 0;
};

bool makeDigest(const std::string &input, std::string &output) {
  unsigned char bytes[EVP_MAX_MD_SIZE];
  unsigned int length = 0;
  if (EVP_Digest(input.data(), input.size(), bytes, &length, EVP_sha256(),
                 nullptr) == 0 ||
      length != 32) {
    return false;
  }
  static constexpr char kDigits[] = "0123456789abcdef";
  output.resize(length * 2);
  for (unsigned int i = 0; i < length; ++i) {
    output[i * 2] = kDigits[bytes[i] >> 4];
    output[i * 2 + 1] = kDigits[bytes[i] & 15];
  }
  return true;
}

bool makeNonce(std::string &output) {
  unsigned char bytes[16];
  if (RAND_bytes(bytes, sizeof(bytes)) != 1) {
    return false;
  }
  static constexpr char kDigits[] = "0123456789abcdef";
  output.resize(sizeof(bytes) * 2);
  for (std::size_t i = 0; i < sizeof(bytes); ++i) {
    output[i * 2] = kDigits[bytes[i] >> 4];
    output[i * 2 + 1] = kDigits[bytes[i] & 15];
  }
  return true;
}

bool resolvePath(const std::string &path, std::string &output) {
  if (path.empty() || path.size() >= PATH_MAX ||
      path.find('\0') != std::string::npos) {
    return false;
  }
  char resolved[PATH_MAX];
  if (realpath(path.c_str(), resolved) == nullptr) {
    return false;
  }
  output = resolved;
  return true;
}

int syncParent(const std::string &path) {
  if (path.size() >= PATH_MAX) {
    return -1;
  }
  char parent[PATH_MAX];
  std::memcpy(parent, path.c_str(), path.size() + 1);
  char *slash = std::strrchr(parent, '/');
  if (slash == parent) {
    parent[1] = 0;
  } else if (slash != nullptr) {
    *slash = 0;
  } else {
    std::memcpy(parent, ".", 2);
  }
  const int descriptor = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (descriptor < 0) {
    return -1;
  }
  const int synced = fsync(descriptor);
  const int closed = close(descriptor);
  return synced == 0 && closed == 0 ? 0 : -1;
}

int scanDirectory(const std::string &root, const std::string &directory,
                  const std::string &relative, FileList &files) {
  DIR *handle = opendir(directory.c_str());
  if (handle == nullptr) {
    return -1;
  }
  int status = 0;
  while (true) {
    dirent *entry = readdir(handle);
    if (entry == nullptr) {
      break;
    }
    if (std::strcmp(entry->d_name, ".") == 0 ||
        std::strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    const std::string absolute = directory + "/" + entry->d_name;
    const std::string child_relative =
        relative.empty() ? entry->d_name : relative + "/" + entry->d_name;
    if (absolute.size() >= PATH_MAX || child_relative.size() >= PATH_MAX) {
      status = -1;
      break;
    }
    struct stat attributes;
    if (lstat(absolute.c_str(), &attributes) != 0 ||
        S_ISLNK(attributes.st_mode)) {
      status = -1;
      break;
    }
    if (S_ISDIR(attributes.st_mode)) {
      status = scanDirectory(root, absolute, child_relative, files);
      if (status != 0) {
        break;
      }
      continue;
    }
    if (!S_ISREG(attributes.st_mode)) {
      status = -1;
      break;
    }
    const std::string name = entry->d_name;
    if (name.size() < 4 || name.compare(name.size() - 4, 4, ".lua") != 0) {
      continue;
    }
    const std::size_t file_bytes = static_cast<std::size_t>(attributes.st_size);
    if (files.paths.size() >= kMaxLuaFiles ||
        files.total_bytes > kMaxTotalBytes || file_bytes > kMaxFileBytes ||
        files.total_bytes + file_bytes > kMaxTotalBytes) {
      status = -2;
      break;
    }
    char canonical[PATH_MAX];
    if (realpath(absolute.c_str(), canonical) == nullptr) {
      status = -1;
      break;
    }
    const std::string canonical_path = canonical;
    if (canonical_path.size() <= root.size() ||
        canonical_path.compare(0, root.size(), root) != 0 ||
        canonical_path[root.size()] != '/') {
      status = -1;
      break;
    }
    files.paths.push_back(child_relative);
    files.total_bytes += file_bytes;
  }
  closedir(handle);
  return status;
}

int listLuaFiles(const std::string &root_argument, const std::string &relative,
                 const std::string &category,
                 std::vector<std::string> &output) {
  if (root_argument.empty() || relative.empty() ||
      root_argument.size() >= PATH_MAX || relative.size() >= PATH_MAX ||
      root_argument.find('\0') != std::string::npos ||
      relative.find('\0') != std::string::npos || relative[0] == '/' ||
      relative.find("..") != std::string::npos) {
    return -1;
  }
  std::string root;
  if (!resolvePath(root_argument, root)) {
    return -1;
  }
  std::string patch;
  if (!resolvePath(root + "/" + relative, patch) ||
      patch.size() <= root.size() || patch.compare(0, root.size(), root) != 0 ||
      patch[root.size()] != '/') {
    return -1;
  }
  if (category != "modules" && category != "services" &&
      category != "migrations" && category != "configs") {
    return -1;
  }
  const std::string directory = patch + "/" + category;
  struct stat attributes;
  if (lstat(directory.c_str(), &attributes) != 0 ||
      S_ISLNK(attributes.st_mode) || !S_ISDIR(attributes.st_mode)) {
    return 1;
  }
  FileList files;
  const int status = scanDirectory(root, directory, "", files);
  if (status != 0) {
    return status == -2 ? -2 : -1;
  }
  if (files.paths.empty()) {
    return 1;
  }
  output = std::move(files.paths);
  return 0;
}

bool appendSynchronized(const std::string &path, const std::string &bytes) {
  if (path.empty() || path.size() >= PATH_MAX ||
      path.find('\0') != std::string::npos) {
    return false;
  }
  const int descriptor =
      open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
           0600);
  if (descriptor < 0) {
    return false;
  }
  std::size_t written = 0;
  while (written < bytes.size()) {
    const ssize_t count =
        write(descriptor, bytes.data() + written, bytes.size() - written);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      close(descriptor);
      return false;
    }
    written += static_cast<std::size_t>(count);
  }
  const int synced = fsync(descriptor);
  const int closed = close(descriptor);
  return synced == 0 && closed == 0 && syncParent(path) == 0;
}

int digestCallback(lua_State *state)
{
  LuaBinding binding(state);
  std::string input;
  if (!binding.readValue(1, input)) {
    return binding.pushError();
  }
  std::string output;
  if (!makeDigest(input, output)) {
    return binding.pushError("HU_CHECKSUM_FAILED",
                             "SHA-256 calculation failed");
  }
  return binding.returnValues(output);
}

int nonceCallback(lua_State *state)
{
  LuaBinding binding(state);
  std::string output;
  if (!makeNonce(output)) {
    return binding.pushError("HU_IDENTITY_FAILED",
                             "secure random generation failed");
  }
  return binding.returnValues(output);
}

int resolveCallback(lua_State *state)
{
  LuaBinding binding(state);
  std::string input;
  if (!binding.readValue(1, input)) {
    return binding.pushError();
  }
  std::string output;
  if (!resolvePath(input, output)) {
    return binding.pushError(input.empty() ? "HU_INVALID_PATH"
                                           : "HU_FILE_NOT_FOUND",
                             "path cannot be resolved");
  }
  return binding.returnValues(output);
}

int listLuaCallback(lua_State *state)
{
  LuaBinding binding(state);
  std::string root;
  std::string relative;
  std::string category;
  if (!binding.readValue(1, root) || !binding.readValue(2, relative) ||
      !binding.readValue(3, category)) {
    return binding.pushError();
  }
  std::vector<std::string> paths;
  const int status = listLuaFiles(root, relative, category, paths);
  if (status != 0) {
    return binding.pushError(status == 1    ? "HU_PATCH_EMPTY"
                             : status == -2 ? "HU_PATCH_LIMIT"
                                            : "HU_INVALID_PATH",
                             "patch Lua file list is invalid or empty");
  }
  LuaTable output = binding.newTable();
  if (!output.valid()) {
    return binding.pushError();
  }
  for (std::size_t i = 0; i < paths.size(); ++i) {
    if (!output.writeValue(static_cast<std::int64_t>(i + 1), paths[i])) {
      return binding.pushError();
    }
  }
  return binding.returnValues(output);
}

int appendCallback(lua_State *state)
{
  LuaBinding binding(state);
  std::string path;
  std::string bytes;
  if (!binding.readValue(1, path) || !binding.readValue(2, bytes)) {
    return binding.pushError();
  }
  if (!appendSynchronized(path, bytes)) {
    return binding.pushError(path.empty() ? "HU_INVALID_PATH"
                                          : "HU_HISTORY_WRITE_FAILED",
                             "history append or synchronization failed");
  }
  return binding.returnValues(true);
}

} // namespace

extern "C" int luaopen_flywow_hotupgrade_native(lua_State *state)
{
  LuaBinding binding(state);
  LuaTable module = binding.newTable();
  if (!module.valid() || !module.setFunction("sha256", digestCallback) ||
      !module.setFunction("nonce", nonceCallback) ||
      !module.setFunction("resolve", resolveCallback) ||
      !module.setFunction("list_lua", listLuaCallback) ||
      !module.setFunction("append_sync", appendCallback)) {
    return binding.pushError();
  }
  return binding.returnValues(module);
}
