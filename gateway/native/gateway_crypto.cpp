// 职责：使用 OpenSSL 3 EVP 执行 Gateway P-256/HKDF/HMAC 握手，不实现自有密码算法。
// 边界：FlyWow Native Lua Binding；输入固定握手字节，输出 challenge/ready 或 nil,error。
// 生命周期：每个 Lua userdata 独占临时密钥和派生密钥；close/__gc 擦除并释放，不共享可变 scratch。
// 不负责：不访问 Socket、Skynet、业务、登录或文件；私钥和 secret 不返回 Lua 字符串。
#include "lua_binding.h"
#include "lua_table.h"
#include <array>
#include <cstring>
#include <exception>
#include <memory>
#include <openssl/core_names.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/kdf.h>
#include <openssl/params.h>
#include <openssl/rand.h>
#include <stdexcept>
#include <string>

namespace flywow_gateway
{
namespace
{
using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;
constexpr const char *kCryptoMetatable = "flywow.gateway.crypto";
struct CryptoContext
{
    EVP_PKEY                     *server_key      = nullptr; ///< 派生完成即释放的服务端密钥。
    std::array<unsigned char, 32> proof_key       = {};      ///< 验证结束或关闭时擦除的证明密钥。
    std::array<unsigned char, 32> transcript_hash = {};      ///< 双向证明共用的 transcript 摘要。
    bool                          active          = false;   ///< 是否仍允许验证一次客户端证明。
    ~CryptoContext() noexcept;
};
template <class T, void (*Free)(T *)> using CryptoHandle = std::unique_ptr<T, decltype(Free)>;

/// 检查 EVP 操作是否成功，失败时抛出由 Lua 回调捕获的运行错误。
/// @param ok 当前 EVP 操作的返回值是否满足成功条件。
/// @param code 操作所属的稳定错误码，不包含密钥或输入字节。
/// @return 正常返回表示操作成功。
void requireCryptoSuccess(bool ok, const char *code)
{
    if (!ok)
    {
        throw std::runtime_error(code);
    }
}

/// 由 close、验证结束或析构调用，幂等释放密钥并擦除敏感数组。
/// @param crypto_context 当前 userdata 独占的已构造对象；不释放 userdata 内存。
/// @return 无返回值，不执行 I/O 或 yield。
void clearCryptoContext(CryptoContext *crypto_context)
{
    EVP_PKEY_free(crypto_context->server_key);
    crypto_context->server_key = nullptr;
    crypto_context->active     = false;
    OPENSSL_cleanse(crypto_context->proof_key.data(), crypto_context->proof_key.size());
    OPENSSL_cleanse(crypto_context->transcript_hash.data(), crypto_context->transcript_hash.size());
}

CryptoContext::~CryptoContext() noexcept
{
    clearCryptoContext(this);
}

/// 为客户端或服务端证明计算 HMAC-SHA256；EVP 失败抛出运行错误。
/// @param key 当前握手派生的 32 字节密钥，仅在调用期间借用。
/// @param message 证明方向字符串与 transcript 摘要拼接后的消息。
/// @param output_mac 调用方提供的至少 32 字节输出区。
/// @return 无返回值，成功时输出区包含完整 HMAC。
void computeHmac(const unsigned char *key, const std::string &message, unsigned char *output_mac)
{
    // algorithm 是 OpenSSL provider 提供的 HMAC 实现，句柄离开作用域时释放。
    CryptoHandle<EVP_MAC, EVP_MAC_free> algorithm(EVP_MAC_fetch(nullptr, "HMAC", nullptr),
                                                  EVP_MAC_free);
    requireCryptoSuccess(bool(algorithm), "CRYPTO_PROVIDER");

    // mac_context 独占本次消息的 HMAC 运算状态，不跨调用共享。
    CryptoHandle<EVP_MAC_CTX, EVP_MAC_CTX_free> mac_context(EVP_MAC_CTX_new(algorithm.get()),
                                                            EVP_MAC_CTX_free);
    requireCryptoSuccess(bool(mac_context), "CRYPTO_ALLOC");

    char       digest[] = "SHA256"; // 本次 HMAC 运算使用的摘要算法名称。
    // params 指定本次 HMAC 运算使用的 SHA-256 摘要。
    OSSL_PARAM params[] = {OSSL_PARAM_construct_utf8_string(OSSL_MAC_PARAM_DIGEST, digest, 0),
                           OSSL_PARAM_construct_end()};
    size_t     size     = 0; // EVP_MAC_final 写出的 MAC 长度，必须为 32 字节。
    requireCryptoSuccess(EVP_MAC_init(mac_context.get(), key, 32, params) == 1 &&
                             EVP_MAC_update(mac_context.get(),
                                            reinterpret_cast<const unsigned char *>(message.data()),
                                            message.size()) == 1 &&
                             EVP_MAC_final(mac_context.get(), output_mac, &size, 32) == 1 &&
                             size == 32,
                         "CRYPTO_HMAC");
}

/// 在 new 回调中根据已校验的 CLIENT_HELLO 创建挑战并派生证明密钥。
/// @param crypto_context 新构造 userdata，接收派生密钥及 transcript 摘要。
/// @param hello 入口已确认长度为 67 字节且版本有效的完整 HELLO。
/// @return 99 字节 SERVER_CHALLENGE；EVP 失败抛错，由入口清理 context。
// ECDH 使用原始32字节Z，不使用各平台默认的二次散列；临时共享秘密离开函数时擦除。
std::string buildChallenge(CryptoContext *crypto_context, const char *hello)
{
    // keygen_context 配置 P-256 keygen，完成后不参与后续派生。
    CryptoHandle<EVP_PKEY_CTX, EVP_PKEY_CTX_free> keygen_context(
        EVP_PKEY_CTX_new_from_name(nullptr, "EC", nullptr), EVP_PKEY_CTX_free);
    requireCryptoSuccess(bool(keygen_context), "CRYPTO_ALLOC");

    char       group[]        = "prime256v1"; // OpenSSL EC group 参数，固定为协议要求的 P-256。
    OSSL_PARAM group_params[] = {
        OSSL_PARAM_construct_utf8_string(OSSL_PKEY_PARAM_GROUP_NAME, group, 0),
        OSSL_PARAM_construct_end()};
    requireCryptoSuccess(EVP_PKEY_keygen_init(keygen_context.get()) == 1 &&
                             EVP_PKEY_CTX_set_params(keygen_context.get(), group_params) == 1 &&
                             EVP_PKEY_generate(keygen_context.get(), &crypto_context->server_key) ==
                                 1,
                         "CRYPTO_KEYGEN");

    // import_context 把 HELLO 中的公钥字节导入为 EVP 公钥对象。
    CryptoHandle<EVP_PKEY_CTX, EVP_PKEY_CTX_free> import_context(
        EVP_PKEY_CTX_new_from_name(nullptr, "EC", nullptr), EVP_PKEY_CTX_free);
    requireCryptoSuccess(bool(import_context), "CRYPTO_ALLOC");
    // peer_params 描述曲线与客户端公钥的固定字节区间 [2,67)。
    OSSL_PARAM peer_params[] = {
        OSSL_PARAM_construct_utf8_string(OSSL_PKEY_PARAM_GROUP_NAME, group, 0),
        OSSL_PARAM_construct_octet_string(OSSL_PKEY_PARAM_PUB_KEY, const_cast<char *>(hello + 2),
                                          65),
        OSSL_PARAM_construct_end()};
    EVP_PKEY  *raw_peer = nullptr; // EVP 导入产生的所有权指针，下一行交给 RAII 句柄。
    const bool imported =          // 区分导入操作失败；peer 句柄随后统一释放成功导入的对象。
        EVP_PKEY_fromdata_init(import_context.get()) == 1 &&
        EVP_PKEY_fromdata(import_context.get(), &raw_peer, EVP_PKEY_PUBLIC_KEY, peer_params) == 1;
    CryptoHandle<EVP_PKEY, EVP_PKEY_free> peer(raw_peer,
                                               EVP_PKEY_free); // 当前 HELLO 提供的客户端公钥。
    requireCryptoSuccess(imported, "INVALID_PUBLIC_KEY");

    // public_key_check 验证导入点是否为有效曲线公钥。
    CryptoHandle<EVP_PKEY_CTX, EVP_PKEY_CTX_free> public_key_check(
        EVP_PKEY_CTX_new(peer.get(), nullptr), EVP_PKEY_CTX_free);
    requireCryptoSuccess(bool(public_key_check) &&
                             EVP_PKEY_public_check(public_key_check.get()) == 1,
                         "INVALID_PUBLIC_KEY");

    // CHALLENGE：类型/版本占前 2 字节，公钥占 [2,67)，随机 salt 占 [67,99)。
    std::string response(99, '\0'); // 固定长度 SERVER_CHALLENGE，按协议字段偏移填充。
    response[0] = 2;
    response[1] = 1;
    size_t size = 0; // 接收 OpenSSL 写入的服务端 P-256 公钥长度，协议要求恰为 65 字节。
    requireCryptoSuccess(EVP_PKEY_get_octet_string_param(
                             crypto_context->server_key, OSSL_PKEY_PARAM_PUB_KEY,
                             reinterpret_cast<unsigned char *>(&response[2]), 65, &size) == 1 &&
                             size == 65,
                         "CRYPTO_PUBLIC_KEY");
    requireCryptoSuccess(RAND_bytes(reinterpret_cast<unsigned char *>(&response[67]), 32) == 1,
                         "CRYPTO_RANDOM");

    // derive_context 使用服务端私钥和客户端公钥计算原始 ECDH Z。
    CryptoHandle<EVP_PKEY_CTX, EVP_PKEY_CTX_free> derive_context(
        EVP_PKEY_CTX_new(crypto_context->server_key, nullptr), EVP_PKEY_CTX_free);
    requireCryptoSuccess(bool(derive_context), "CRYPTO_ALLOC");
    struct SharedSecret
    {
        unsigned char bytes[32] = {}; ///< 当前 challenge 派生出的原始 ECDH 秘密；离开作用域即擦除。
        // 所有正常和异常退出都擦除Z；不执行I/O。
        ~SharedSecret()
        {
            OPENSSL_cleanse(bytes, sizeof(bytes));
        }
    } shared_secret;

    size = sizeof(shared_secret.bytes); // EVP_PKEY_derive 的输出容量，成功后改写为实际长度。
    requireCryptoSuccess(
        EVP_PKEY_derive_init(derive_context.get()) == 1 &&
            EVP_PKEY_derive_set_peer(derive_context.get(), peer.get()) == 1 &&
            EVP_PKEY_derive(derive_context.get(), shared_secret.bytes, &size) == 1 && size == 32,
        "CRYPTO_DERIVE");

    // transcript 严格拼接完整 HELLO 与 CHALLENGE，不包含 TCP/WS 帧头。
    std::string transcript(hello, 67); // 完整 CLIENT_HELLO；追加 challenge 后计算 transcript 摘要。
    transcript += response;
    unsigned int hash_size = 0; // EVP 实际写入的摘要长度，必须等于 SHA-256 的 32 字节。
    requireCryptoSuccess(EVP_Digest(transcript.data(), transcript.size(),
                                    crypto_context->transcript_hash.data(), &hash_size,
                                    EVP_sha256(), nullptr) == 1 &&
                             hash_size == 32,
                         "CRYPTO_HASH");

    // HKDF info 用固定协议域与 transcript 摘要隔离不同握手及用途。
    std::string info = "flywow/handshake/v1"; // HKDF 域分离前缀，后接 transcript_hash。
    info.append(reinterpret_cast<const char *>(crypto_context->transcript_hash.data()), 32);

    // algorithm 是 OpenSSL provider 的 HKDF 实现。
    CryptoHandle<EVP_KDF, EVP_KDF_free> algorithm(EVP_KDF_fetch(nullptr, "HKDF", nullptr),
                                                  EVP_KDF_free);
    requireCryptoSuccess(bool(algorithm), "CRYPTO_PROVIDER");
    // kdf 保存本次 HKDF 参数与派生过程，不跨连接共享。
    CryptoHandle<EVP_KDF_CTX, EVP_KDF_CTX_free> kdf(EVP_KDF_CTX_new(algorithm.get()),
                                                    EVP_KDF_CTX_free);
    requireCryptoSuccess(bool(kdf), "CRYPTO_ALLOC");

    char       digest[] = "SHA256"; // 本次 HMAC 运算使用的摘要算法名称。
    // params 将原始 Z、随机 salt 与域分离信息交给 OpenSSL HKDF。
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_utf8_string(OSSL_KDF_PARAM_DIGEST, digest, 0),
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_KEY, shared_secret.bytes, 32),
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_SALT, &response[67], 32),
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_INFO, &info[0], info.size()),
        OSSL_PARAM_construct_end()};
    requireCryptoSuccess(EVP_KDF_derive(kdf.get(), crypto_context->proof_key.data(), 32, params) ==
                             1,
                         "CRYPTO_HKDF");

    EVP_PKEY_free(crypto_context->server_key);
    crypto_context->server_key = nullptr;
    crypto_context->active     = true;
    return response;
}

/// Lua handshake manager 在 hello 阶段调用 new，创建独占密码上下文及挑战。
/// @param state 栈索引 1 是完整 HELLO 字节串；由 LuaBinding 校验参数。
/// @return Lua 返回 userdata、challenge；参数或密码操作失败返回 nil、错误记录。
// Lua 名称 new 是 C++ 保留字，回调使用 createCryptoContext；不改变公开 Lua 名称。
// [hello] -> [hello, userdata]；userdata 构造和 __gc 由 LuaBinding 管理。
// 失败时清理其密钥，userdata 内存仍由 Lua GC 回收，不手工析构两次。
int createCryptoContext(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding  lua_binding(state);
            std::string hello; // 从参数复制的完整 CLIENT_HELLO，校验后才用于密钥派生。
            if (!lua_binding.readValue(1, hello))
            {
                return lua_binding.pushError();
            }

            if (hello.size() != 67 || hello[0] != 1 || hello[1] != 1 ||
                static_cast<unsigned char>(hello[2]) != 4)
            {
                lua_binding.setError("HANDSHAKE_HELLO", "invalid handshake hello");
                return lua_binding.pushError();
            }

            CryptoContext *context =
                nullptr; // 从 Lua 栈借用的已构造对象；其内存仍由 userdata 拥有。
            if (!lua_binding.newUserdata(kCryptoMetatable, context))
            {
                return lua_binding.pushError();
            }

            std::string response; // buildChallenge 产生的公开挑战消息，成功后交还 Lua。
            try
            {
                response = buildChallenge(context, hello.data());
            }
            catch (const std::exception &error)
            {
                clearCryptoContext(context);
                lua_binding.setError(error.what(), error.what());
                return lua_binding.pushError();
            }
            catch (...)
            {
                clearCryptoContext(context);
                lua_binding.setError("CRYPTO_FAILURE", "unknown native handshake failure");
                return lua_binding.pushError();
            }

            return lua_binding.returnValues(context, response);
        });
}

/// Lua handshake manager 在 proof 阶段验证客户端证明并生成服务端证明。
/// @param state 索引 1 为本模块 userdata，索引 2 为 33 字节 CLIENT_PROOF。
/// @return 成功返回 33 字节 SERVER_READY；失败返回 nil、错误记录。
// 只借用栈中的 userdata；returnValues 追加输出，LuaBinding 负责错误结果与栈平衡。
int verify(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding     lua_binding(state);
            CryptoContext *context =
                nullptr;       // 从 Lua 栈借用的已构造对象；其内存仍由 userdata 拥有。
            std::string bytes; // 从第二个参数复制的完整 CLIENT_PROOF，验证期间只读。
            if (!lua_binding.readUserdata(1, kCryptoMetatable, context) ||
                !lua_binding.readValue(2, bytes))
            {
                return lua_binding.pushError();
            }

            if (!context->active || bytes.size() != 33 || bytes[0] != 3)
            {
                clearCryptoContext(context);
                lua_binding.setError("HANDSHAKE_PROOF", "invalid handshake proof");
                return lua_binding.pushError();
            }

            std::array<unsigned char, 32> expected =
                {};                               // 预期客户端 HMAC；与输入证明做常量时间比较。
            std::string message = "client-proof"; // 证明用途前缀，后接握手摘要。
            message.append(reinterpret_cast<const char *>(context->transcript_hash.data()), 32);
            try
            {
                // EVP 计算失败也须落入本回调的清理与错误返回路径。
                computeHmac(context->proof_key.data(), message, expected.data());
                requireCryptoSuccess(CRYPTO_memcmp(expected.data(), bytes.data() + 1, 32) == 0,
                                     "HANDSHAKE_PROOF");

                message = "server-ready";
                message.append(reinterpret_cast<const char *>(context->transcript_hash.data()), 32);
                std::string response(33, '\0'); // SERVER_READY：1 字节类型加 32 字节服务端证明。
                response[0] = 4;
                computeHmac(context->proof_key.data(), message,
                            reinterpret_cast<unsigned char *>(&response[1]));
                clearCryptoContext(context);
                return lua_binding.returnValues(response);
            }
            catch (const std::exception &error)
            {
                clearCryptoContext(context);
                lua_binding.setError(error.what(), error.what());
                return lua_binding.pushError();
            }
            catch (...)
            {
                clearCryptoContext(context);
                lua_binding.setError("CRYPTO_FAILURE", "unknown native handshake failure");
                return lua_binding.pushError();
            }
        });
}

/// Gateway 关闭连接或完成握手时幂等释放密码资源。
/// @param state 索引 1 是仍由 Lua 持有的 userdata；仅清理内部资源。
/// @return 无 Lua 返回值；userdata 类型错误按 Binding 错误合同返回。
// 不弹出或释放 userdata；Lua GC 随后调用析构，重复清理因空指针及复位状态而安全。
int close(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding     lua_binding(state);
            CryptoContext *context =
                nullptr; // 从 Lua 栈借用的已构造对象；其内存仍由 userdata 拥有。
            if (!lua_binding.readUserdata(1, kCryptoMetatable, context))
            {
                return lua_binding.pushError();
            }
            clearCryptoContext(context);
            return lua_binding.returnValues();
        });
}
} // namespace
} // namespace flywow_gateway

/// require 加载当前 Lua State 的密码模块，注册 userdata 的 verify/close 方法。
/// @param state Lua 加载器提供的栈；模块表追加到栈顶交给 require。
/// @return 一个模块表；注册失败时返回 Binding 错误结果。
// metatable/methods/module 由 LuaTable 的 registry 引用保活；局部句柄销毁只释放引用。
// __index 指向方法表，__gc 由 registerUserdata 安装，负责调用已构造对象的析构。
extern "C" int luaopen_flywow_gateway_crypto(lua_State *state)
{
    return flywow_lua_binding::LuaBinding::invokeModule(
        state,
        [state]() -> int
        {
            using namespace flywow_gateway;
            LuaBinding lua_binding(state); // 借用当前 Lua State；参数和结果均由本次回调管理。
            LuaTable   metatable; // 注册当前 userdata 类型及其由 LuaBinding 管理的 __gc 行为。
            if (!lua_binding.registerUserdata<CryptoContext>(kCryptoMetatable, metatable))
            {
                return lua_binding.pushError();
            }

            LuaTable methods = lua_binding.newTable(); // userdata 的公开 verify/close 方法集合。
            if (!methods.setFunction("verify", verify) || !methods.setFunction("close", close) ||
                !metatable.writeValue("__index", methods))
            {
                return lua_binding.pushError();
            }

            LuaTable module = lua_binding.newTable(); // require 返回的模块表，仅提供 new 构造入口。
            if (!module.setFunction("new", createCryptoContext))
            {
                return lua_binding.pushError();
            }
            return lua_binding.returnValues(module);
        });
}
