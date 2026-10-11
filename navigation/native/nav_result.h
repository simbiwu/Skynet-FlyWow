// 职责：定义 Native 导航模块统一的错误码和 Result<T> 返回值。
// 边界：Server Runtime 公共错误合同；Reader、GridMap、Registry 和 Binding 共用。
// 输入/输出：接收一次操作的成功值或失败信息 -> 交给上层做稳定分支和日志记录。
// 生命周期：NavResult 由调用方按值持有；不保存跨请求的全局可变状态。
// 不负责：不记录日志，不把错误转换成 Lua 返回值，也不决定进程是否退出。
#pragma once

#include <string>
#include <utility>

namespace flywow_navigation
{

// 错误枚举属于跨模块合同；已有值不要随意改名或复用为其他语义。
enum class NavError
{
    kOk = 0,              // 操作成功。
    kIoError,             // 文件打开、读取或系统 I/O 失败。
    kBadMagic,            // 文件开头不是 BMAP。
    kUnsupportedVersion,  // BMAP 版本不受当前 Reader 支持。
    kInvalidHeaderSize,   // Header 长度与 V1 合同不符。
    kInvalidDimensions,   // width、height 或 cellSize 非法。
    kSizeOverflow,        // 尺寸乘法超出可安全表示的范围。
    kInvalidStride,       // 单格磁盘长度与 V1 合同不符。
    kPayloadSizeMismatch, // Header 声明的 Payload 长度与尺寸不一致。
    kHeaderCrcMismatch,   // Header 自身校验失败。
    kPayloadCrcMismatch,  // Cell Payload 校验失败。
    kTruncated,           // 文件短于 Header 声明的长度。
    kTrailingBytes,       // 合法内容后仍有未定义字节。
    kMapNotFound,         // 查询的 mapId 或版本未加载。
    kOutOfBounds,         // 世界坐标或 Grid 下标位于地图外。
    kInvalidArgument,     // 其他调用参数违反公开合同。
    kInvalidAgent,        // NavigationProfile 本身不合法或 unit_id 不存在。
    kStartNotNavigable,   // 起点在地图内，但不满足静态/动态通行规则。
    kEndNotNavigable,     // 终点在地图内，但不满足静态/动态通行规则。
    kNoPath,              // 起终点均合法，但当前规则下不存在连通路径。
    kContextClosed,       // Lua/业务仍在调用已经关闭的 NavigationContext。
    kPathTooLong,         // 回溯点数或累计长度超过项目保护上限。
    kDynamicOccupied,     // 动态占位提交与其他 Unit 冲突。
    kMoveBlocked,         // 缓存路径的本次跨格已被静态或动态规则拒绝。
    kInternalError,       // Native 未预期异常在 C ABI 边界被收敛，不能继续传播。
};

// 返回便于日志和 Lua 错误结果使用的稳定 ASCII 名称。
const char *NavErrorName(NavError error) noexcept;

// 一次 Native 操作的返回值。先检查 ok()，成功才读 value，失败读 error/detail。
// NavResult<bool>::Success(false) 仍是成功，例如重复 Freeze；不要把 value 当成功标志。
template <typename T> struct NavResult
{
    NavError    error = NavError::kOk; // 稳定机器错误码；kOk 表示成功。
    std::string detail;                // 面向日志的上下文；可包含路径或实际数值。
    T           value{};               // 仅在 ok()==true 时具有业务意义。

    // 调用方只通过稳定错误码判断成功，不依赖 detail 文案。
    bool ok() const noexcept
    {
        return error == NavError::kOk;
    }

    // 构造成功结果；error 保持 kOk，并把结果值移动进返回对象。
    // 对 vector/shared_ptr 等结果，move 可交接其资源而不复制全部数据；
    // 返回对象拥有自己的结果，调用方无需依赖此 helper 的局部变量生命周期。
    static NavResult Success(T result)
    {
        NavResult output;
        output.value = std::move(result);
        return output;
    }

    // 构造失败结果；value 保持默认值，调用方不得读取它作为业务结果。
    static NavResult Failure(NavError code, std::string message)
    {
        NavResult output;
        output.error  = code;
        output.detail = std::move(message);
        return output;
    }
};

} // namespace flywow_navigation
