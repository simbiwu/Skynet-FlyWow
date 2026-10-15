// 职责：使用 OpenSSL 3 EVP 执行 Gateway P-256/HKDF/HMAC 握手，不实现自有密码算法。
// 边界：FlyWow Native Lua Binding；输入固定握手字节，输出 challenge/ready 或 nil,error。
// 生命周期：每个 Lua userdata 独占临时密钥和派生密钥；close/__gc 擦除并释放，不共享可变 scratch。
// 不负责：不访问 Socket、Skynet、业务、登录或文件；私钥和 secret 不返回 Lua 字符串。
#include "lua_binding.h"
#include "lua_table.h"
#include <openssl/evp.h>
#include <openssl/kdf.h>
#include <openssl/core_names.h>
#include <openssl/params.h>
#include <openssl/rand.h>
#include <openssl/crypto.h>
#include <array>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>

namespace
{
using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;
constexpr const char* TYPE = "flywow.gateway.crypto";
struct Context
{
    EVP_PKEY*                    key    = nullptr; // userdata 独占，仅生成 challenge 时持有。
    std::array<unsigned char,32> secret = {};      // HMAC 密钥，握手结束擦除。
    std::array<unsigned char,32> hash   = {};      // 公开 transcript 摘要。
    bool                         active = false;   // 成功 verify 后不允许重复使用。
    ~Context() noexcept;
};
template<class T, void(*Free)(T*)> using Handle = std::unique_ptr<T, decltype(Free)>;

// 检查 EVP 的显式返回；失败由当前 Lua 回调转为稳定错误结果。
void check(bool ok, const char* code)
{
    if (!ok) throw std::runtime_error(code);
}

// 幂等擦除 context；只影响本 userdata，无 I/O/yield，失败路径也可调用。
void clear(Context* c)
{
    EVP_PKEY_free(c->key);
    c->key    = nullptr;
    c->active = false;
    OPENSSL_cleanse(c->secret.data(), c->secret.size());
    OPENSSL_cleanse(c->hash.data(), c->hash.size());
}

Context::~Context() noexcept
{
    clear(this);
}

// 对指定消息执行完整 HMAC-SHA256；key/message 只在调用期间借用，输出为32字节。
void hmac(const unsigned char* key, const std::string& message, unsigned char* out)
{
    Handle<EVP_MAC, EVP_MAC_free> algorithm(EVP_MAC_fetch(nullptr, "HMAC", nullptr), EVP_MAC_free);
    check(bool(algorithm), "CRYPTO_PROVIDER");
    Handle<EVP_MAC_CTX, EVP_MAC_CTX_free> ctx(EVP_MAC_CTX_new(algorithm.get()), EVP_MAC_CTX_free);
    check(bool(ctx), "CRYPTO_ALLOC");
    char digest[] = "SHA256";
    OSSL_PARAM params[] =
    {
        OSSL_PARAM_construct_utf8_string(OSSL_MAC_PARAM_DIGEST, digest, 0),
        OSSL_PARAM_construct_end()
    };
    size_t size = 0;
    check(EVP_MAC_init(ctx.get(), key, 32, params) == 1 &&
          EVP_MAC_update(ctx.get(), reinterpret_cast<const unsigned char*>(message.data()), message.size()) == 1 &&
          EVP_MAC_final(ctx.get(), out, &size, 32) == 1 && size == 32, "CRYPTO_HMAC");
}

// 创建服务端 challenge 并派生 secret；hello 已由入口检查精确长度/版本。
// ECDH 使用原始32字节Z，不使用各平台默认的二次散列；临时共享秘密离开函数时擦除。
std::string challenge(Context* c, const char* hello)
{
    Handle<EVP_PKEY_CTX, EVP_PKEY_CTX_free> gen(EVP_PKEY_CTX_new_from_name(nullptr, "EC", nullptr), EVP_PKEY_CTX_free);
    check(bool(gen), "CRYPTO_ALLOC");
    char group[] = "prime256v1";
    OSSL_PARAM group_params[] =
    {
        OSSL_PARAM_construct_utf8_string(OSSL_PKEY_PARAM_GROUP_NAME, group, 0),
        OSSL_PARAM_construct_end()
    };
    check(EVP_PKEY_keygen_init(gen.get()) == 1 && EVP_PKEY_CTX_set_params(gen.get(), group_params) == 1 &&
          EVP_PKEY_generate(gen.get(), &c->key) == 1, "CRYPTO_KEYGEN");
    Handle<EVP_PKEY_CTX, EVP_PKEY_CTX_free> import(EVP_PKEY_CTX_new_from_name(nullptr, "EC", nullptr), EVP_PKEY_CTX_free);
    check(bool(import), "CRYPTO_ALLOC");
    OSSL_PARAM peer_params[] =
    {
        OSSL_PARAM_construct_utf8_string(OSSL_PKEY_PARAM_GROUP_NAME, group, 0),
        OSSL_PARAM_construct_octet_string(OSSL_PKEY_PARAM_PUB_KEY, const_cast<char*>(hello + 2), 65),
        OSSL_PARAM_construct_end()
    };
    EVP_PKEY* raw_peer = nullptr;
    const bool imported = EVP_PKEY_fromdata_init(import.get()) == 1 &&
        EVP_PKEY_fromdata(import.get(), &raw_peer, EVP_PKEY_PUBLIC_KEY, peer_params) == 1;
    Handle<EVP_PKEY, EVP_PKEY_free> peer(raw_peer, EVP_PKEY_free);
    check(imported, "INVALID_PUBLIC_KEY");
    Handle<EVP_PKEY_CTX, EVP_PKEY_CTX_free> verify(EVP_PKEY_CTX_new(peer.get(), nullptr), EVP_PKEY_CTX_free);
    check(bool(verify) && EVP_PKEY_public_check(verify.get()) == 1, "INVALID_PUBLIC_KEY");
    std::string response(99, '\0');
    response[0] = 2;
    response[1] = 1;
    size_t size = 0;
    check(EVP_PKEY_get_octet_string_param(c->key, OSSL_PKEY_PARAM_PUB_KEY,
          reinterpret_cast<unsigned char*>(&response[2]), 65, &size) == 1 && size == 65, "CRYPTO_PUBLIC_KEY");
    check(RAND_bytes(reinterpret_cast<unsigned char*>(&response[67]), 32) == 1, "CRYPTO_RANDOM");
    Handle<EVP_PKEY_CTX, EVP_PKEY_CTX_free> derive(EVP_PKEY_CTX_new(c->key, nullptr), EVP_PKEY_CTX_free);
    check(bool(derive), "CRYPTO_ALLOC");
    struct Shared
    {
        unsigned char bytes[32] = {}; // 原始Z，只在当前调用存活。
        // 所有正常和异常退出都擦除Z；不执行I/O。
        ~Shared()
        {
            OPENSSL_cleanse(bytes, sizeof(bytes));
        }
    } z;
    size = sizeof(z.bytes);
    check(EVP_PKEY_derive_init(derive.get()) == 1 && EVP_PKEY_derive_set_peer(derive.get(), peer.get()) == 1 &&
          EVP_PKEY_derive(derive.get(), z.bytes, &size) == 1 && size == 32, "CRYPTO_DERIVE");
    std::string transcript(hello, 67);
    transcript += response;
    unsigned int hash_size = 0;
    check(EVP_Digest(transcript.data(), transcript.size(), c->hash.data(), &hash_size, EVP_sha256(), nullptr) == 1 &&
          hash_size == 32, "CRYPTO_HASH");
    std::string info = "flywow/handshake/v1";
    info.append(reinterpret_cast<const char*>(c->hash.data()), 32);
    Handle<EVP_KDF, EVP_KDF_free> algorithm(EVP_KDF_fetch(nullptr, "HKDF", nullptr), EVP_KDF_free);
    check(bool(algorithm), "CRYPTO_PROVIDER");
    Handle<EVP_KDF_CTX, EVP_KDF_CTX_free> kdf(EVP_KDF_CTX_new(algorithm.get()), EVP_KDF_CTX_free);
    check(bool(kdf), "CRYPTO_ALLOC");
    char digest[] = "SHA256";
    OSSL_PARAM params[] =
    {
        OSSL_PARAM_construct_utf8_string(OSSL_KDF_PARAM_DIGEST, digest, 0),
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_KEY, z.bytes, 32),
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_SALT, &response[67], 32),
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_INFO, &info[0], info.size()),
        OSSL_PARAM_construct_end()
    };
    check(EVP_KDF_derive(kdf.get(), c->secret.data(), 32, params) == 1, "CRYPTO_HKDF");
    EVP_PKEY_free(c->key);
    c->key    = nullptr;
    c->active = true;
    return response;
}

// 创建独占 userdata 和 challenge；参数 hello 为 67 字节。失败返回稳定 Lua 错误，不执行 I/O/yield。
int create(lua_State *state)
{
    LuaBinding lua_binding(state);
    std::string hello;
    if (!lua_binding.readValue(1, hello)) return lua_binding.pushError();
    if (hello.size() != 67 || hello[0] != 1 || hello[1] != 1 ||
        static_cast<unsigned char>(hello[2]) != 4)
    {
        lua_binding.setError("HANDSHAKE_HELLO", "invalid handshake hello");
        return lua_binding.pushError();
    }
    Context *context = nullptr;
    if (!lua_binding.newUserdata(TYPE, context)) return lua_binding.pushError();
    std::string response;
    try
    {
        response = challenge(context, hello.data());
    }
    catch (const std::runtime_error &error)
    {
        clear(context);
        lua_binding.setError(error.what(), error.what());
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(context, response);
}

// 验证33字节客户端证明并返回33字节服务端证明；常量时间比较，成功即擦除secret。
int proof(lua_State *state)
{
    LuaBinding lua_binding(state);
    Context *context = nullptr;
    std::string bytes;
    if (!lua_binding.readUserdata(1, TYPE, context) || !lua_binding.readValue(2, bytes))
        return lua_binding.pushError();
    if (!context->active || bytes.size() != 33 || bytes[0] != 3)
    {
        clear(context);
        lua_binding.setError("HANDSHAKE_PROOF", "invalid handshake proof");
        return lua_binding.pushError();
    }
    std::array<unsigned char,32> expected = {};
    std::string message = "client-proof";
    message.append(reinterpret_cast<const char*>(context->hash.data()), 32);
    hmac(context->secret.data(), message, expected.data());
    try
    {
        check(CRYPTO_memcmp(expected.data(), bytes.data() + 1, 32) == 0, "HANDSHAKE_PROOF");
        message = "server-ready";
        message.append(reinterpret_cast<const char*>(context->hash.data()), 32);
        std::string response(33, '\0');
        response[0] = 4;
        hmac(context->secret.data(), message, reinterpret_cast<unsigned char*>(&response[1]));
        clear(context);
        return lua_binding.returnValues(response);
    }
    catch (const std::runtime_error &error)
    {
        clear(context);
        lua_binding.setError(error.what(), error.what());
        return lua_binding.pushError();
    }
}

// close 幂等清理 Context 持有的资源；Lua GC 随后自动调用 Context 析构。
int close(lua_State *state)
{
    LuaBinding lua_binding(state);
    Context *context = nullptr;
    if (!lua_binding.readUserdata(1, TYPE, context)) return lua_binding.pushError();
    clear(context);
    return lua_binding.returnValues();
}
}

// 注册本Lua State的模块及userdata方法；无全局可变context，不接触Skynet服务。
extern "C" int luaopen_flywow_gateway_crypto(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaTable metatable;
    if (!lua_binding.registerUserdata<Context>(TYPE, metatable)) return lua_binding.pushError();
    LuaTable methods = lua_binding.newTable();
    if (!methods.setFunction("verify", proof) || !methods.setFunction("close", close) ||
        !metatable.writeValue("__index", methods)) return lua_binding.pushError();
    LuaTable module = lua_binding.newTable();
    if (!module.setFunction("new", create)) return lua_binding.pushError();
    return lua_binding.returnValues(module);
}
