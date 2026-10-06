/* 职责：复用 OpenSSL SHA-256，解析真实路径并同步写审计；无共享可变状态。
 * Lua 字符串在调用期间借用；所有 fd/EVP 资源在压入 Lua 结果前释放。 */
#define _XOPEN_SOURCE 700
#include <lua.h>
#include <lauxlib.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <limits.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <dirent.h>
#include <sys/stat.h>

static int flywow_failure(lua_State *L, const char *code)
{
    lua_pushnil(L);
    lua_pushstring(L, code);
    return 2;
}

static int flywow_digest(lua_State *L)
{
    size_t size;
    const char *bytes = luaL_checklstring(L, 1, &size);
    unsigned char output[EVP_MAX_MD_SIZE];
    unsigned int length = 0;
    char hex[65];
    static const char digits[] = "0123456789abcdef";
    if (!EVP_Digest(bytes, size, output, &length, EVP_sha256(), NULL) || length != 32)
    {
        return flywow_failure(L, "HU_CHECKSUM_FAILED");
    }

    for (unsigned int i = 0; i < length; ++i)
    {
        hex[i * 2] = digits[output[i] >> 4];
        hex[i * 2 + 1] = digits[output[i] & 15];
    }
    hex[64] = 0;
    lua_pushlstring(L, hex, 64);
    return 1;
}

static int flywow_nonce(lua_State *L)
{
    unsigned char bytes[16];
    char hex[32];
    static const char digits[] = "0123456789abcdef";
    if (RAND_bytes(bytes, sizeof(bytes)) != 1)
    {
        return flywow_failure(L, "HU_IDENTITY_FAILED");
    }

    for (size_t i = 0; i < sizeof(bytes); ++i)
    {
        hex[i * 2] = digits[bytes[i] >> 4];
        hex[i * 2 + 1] = digits[bytes[i] & 15];
    }
    lua_pushlstring(L, hex, sizeof(hex));
    return 1;
}

static int flywow_resolve(lua_State *L)
{
    size_t size;
    const char *path = luaL_checklstring(L, 1, &size);
    char output[PATH_MAX];
    if (size == 0 || size >= PATH_MAX)
    {
        return flywow_failure(L, "HU_INVALID_PATH");
    }

    for (size_t i = 0; i < size; ++i)
    {
        if (path[i] == 0)
        {
            return flywow_failure(L, "HU_INVALID_PATH");
        }
    }
    if (!realpath(path, output))
    {
        return flywow_failure(L, "HU_FILE_NOT_FOUND");
    }

    lua_pushstring(L, output);
    return 1;
}

/* 每次追加完成文件和目录同步；目录 fd 只归本次调用，不跨 Lua API 分配点。 */
static int flywow_sync_parent(const char *path)
{
    char parent[PATH_MAX];
    size_t length = strlen(path);
    if (length >= sizeof(parent))
    {
        return -1;
    }
    memcpy(parent, path, length + 1);
    char *slash = strrchr(parent, '/');
    if (slash == parent)
    {
        parent[1] = 0;
    }
    else if (slash)
    {
        *slash = 0;
    }
    else
    {
        memcpy(parent, ".", 2);
    }

    int fd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0)
    {
        return -1;
    }
    int synced = fsync(fd);
    int closed = close(fd);
    return synced == 0 && closed == 0 ? 0 : -1;
}

typedef struct flywow_file_list
{
    char **paths;
    size_t count;
    size_t capacity;
    size_t total_bytes;
} flywow_file_list;

static int flywow_scan_directory(const char *root, const char *directory,
    const char *relative, flywow_file_list *files)
{
    DIR *handle = opendir(directory);
    if (handle == NULL)
    {
        return -1;
    }

    struct dirent *entry;
    int status = 0;
    while ((entry = readdir(handle)) != NULL)
    {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
        {
            continue;
        }

        char absolute[PATH_MAX];
        char child_relative[PATH_MAX];
        int absolute_size = snprintf(absolute, sizeof(absolute), "%s/%s", directory, entry->d_name);
        int relative_size = relative[0] == '\0'
            ? snprintf(child_relative, sizeof(child_relative), "%s", entry->d_name)
            : snprintf(child_relative, sizeof(child_relative), "%s/%s", relative, entry->d_name);
        if (absolute_size < 0 || (size_t)absolute_size >= sizeof(absolute)
            || relative_size < 0 || (size_t)relative_size >= sizeof(child_relative))
        {
            status = -1;
            break;
        }

        struct stat attributes;
        if (lstat(absolute, &attributes) != 0 || S_ISLNK(attributes.st_mode))
        {
            status = -1;
            break;
        }
        if (S_ISDIR(attributes.st_mode))
        {
            status = flywow_scan_directory(root, absolute, child_relative, files);
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

        size_t name_size = strlen(entry->d_name);
        if (name_size < 4 || strcmp(entry->d_name + name_size - 4, ".lua") != 0)
        {
            continue;
        }
        if (files->count >= 1024 || files->total_bytes > 16 * 1024 * 1024
            || (size_t)attributes.st_size > 2 * 1024 * 1024
            || files->total_bytes + (size_t)attributes.st_size > 16 * 1024 * 1024)
        {
            status = -2;
            break;
        }

        char canonical[PATH_MAX];
        if (!realpath(absolute, canonical) || strncmp(canonical, root, strlen(root)) != 0
            || canonical[strlen(root)] != '/')
        {
            status = -1;
            break;
        }

        if (files->count == files->capacity)
        {
            size_t capacity = files->capacity == 0 ? 16 : files->capacity * 2;
            char **paths = realloc(files->paths, capacity * sizeof(*paths));
            if (paths == NULL)
            {
                status = -3;
                break;
            }
            files->paths = paths;
            files->capacity = capacity;
        }
        files->paths[files->count] = strdup(child_relative);
        if (files->paths[files->count] == NULL)
        {
            status = -3;
            break;
        }
        files->count++;
        files->total_bytes += (size_t)attributes.st_size;
    }

    closedir(handle);
    return status;
}

static int flywow_list_lua(lua_State *L)
{
    size_t root_size;
    size_t relative_size;
    const char *root_argument = luaL_checklstring(L, 1, &root_size);
    const char *relative = luaL_checklstring(L, 2, &relative_size);
    const char *category = luaL_optstring(L, 3, "modules");
    if (root_size == 0 || relative_size == 0 || root_size >= PATH_MAX || relative_size >= PATH_MAX
        || memchr(root_argument, 0, root_size) || memchr(relative, 0, relative_size)
        || relative[0] == '/' || strstr(relative, "..") != NULL)
    {
        return flywow_failure(L, "HU_INVALID_PATH");
    }

    char root[PATH_MAX];
    char patch_path[PATH_MAX];
    if (!realpath(root_argument, root))
    {
        return flywow_failure(L, "HU_INVALID_PATH");
    }
    int patch_size = snprintf(patch_path, sizeof(patch_path), "%s/%.*s", root,
        (int)relative_size, relative);
    if (patch_size < 0 || (size_t)patch_size >= sizeof(patch_path))
    {
        return flywow_failure(L, "HU_INVALID_PATH");
    }

    char patch[PATH_MAX];
    if (!realpath(patch_path, patch) || strncmp(patch, root, strlen(root)) != 0
        || patch[strlen(root)] != '/')
    {
        return flywow_failure(L, "HU_INVALID_PATH");
    }

    char modules[PATH_MAX];
    if (strcmp(category, "modules") != 0 && strcmp(category, "services") != 0
        && strcmp(category, "migrations") != 0 && strcmp(category, "configs") != 0)
    {
        return flywow_failure(L, "HU_INVALID_PATH");
    }
    int modules_size = snprintf(modules, sizeof(modules), "%s/%s", patch, category);
    if (modules_size < 0 || (size_t)modules_size >= sizeof(modules))
    {
        return flywow_failure(L, "HU_INVALID_PATH");
    }

    struct stat modules_attributes;
    if (lstat(modules, &modules_attributes) != 0 || S_ISLNK(modules_attributes.st_mode)
        || !S_ISDIR(modules_attributes.st_mode))
    {
        return flywow_failure(L, "HU_PATCH_EMPTY");
    }

    flywow_file_list files = {0};
    int status = flywow_scan_directory(root, modules, "", &files);
    if (status == 0 && files.count == 0) status = 1;
    if (status != 0)
    {
        for (size_t i = 0; i < files.count; ++i)
        {
            free(files.paths[i]);
        }
        free(files.paths);
        return flywow_failure(L, status == 1 ? "HU_PATCH_EMPTY"
            : status == -2 ? "HU_PATCH_LIMIT" : "HU_INVALID_PATH");
    }

    lua_createtable(L, (int)files.count, 0);
    for (size_t i = 0; i < files.count; ++i)
    {
        lua_pushstring(L, files.paths[i]);
        lua_rawseti(L, -2, (lua_Integer)i + 1);
        free(files.paths[i]);
    }
    free(files.paths);
    return 1;
}

static int flywow_append(lua_State *L)
{
    size_t path_size;
    const char *path = luaL_checklstring(L, 1, &path_size);
    size_t size;
    const char *bytes = luaL_checklstring(L, 2, &size);
    if (path_size == 0 || path_size >= PATH_MAX || memchr(path, 0, path_size))
    {
        return flywow_failure(L, "HU_INVALID_PATH");
    }

    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0)
    {
        return flywow_failure(L, "HU_HISTORY_WRITE_FAILED");
    }

    size_t written = 0;
    while (written < size)
    {
        ssize_t count = write(fd, bytes + written, size - written);
        if (count < 0 && errno == EINTR)
        {
            continue;
        }
        if (count <= 0)
        {
            close(fd);
            return flywow_failure(L, "HU_HISTORY_WRITE_FAILED");
        }
        written += (size_t)count;
    }

    int synced = fsync(fd);
    int closed = close(fd);
    if (synced != 0 || closed != 0 || flywow_sync_parent(path) != 0)
    {
        return flywow_failure(L, "HU_HISTORY_WRITE_FAILED");
    }

    lua_pushboolean(L, 1);
    return 1;
}

int luaopen_flywow_hotupgrade_native(lua_State *L)
{
    const luaL_Reg functions[] =
    {
        {"sha256", flywow_digest},
        {"nonce", flywow_nonce},
        {"resolve", flywow_resolve},
        {"list_lua", flywow_list_lua},
        {"append_sync", flywow_append},
        {NULL, NULL}
    };
    luaL_newlib(L, functions);
    return 1;
}
