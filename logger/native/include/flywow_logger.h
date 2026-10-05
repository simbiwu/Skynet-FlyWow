// 本文件解决的问题：为 Native 模块提供统一的 FlyWow 分级日志发送接口。
// 所属边界：Module API / Adapter；只负责把日志投递回 Skynet，不负责创建文件或管理 Logger Service。
// 主要输入和输出：输入是当前 Service context、日志级别和正文；输出是异步文本消息。
// 生命周期与所有权：context 只在所属 Service 回调期间借用；message 只在本次调用期间借用并立即复制。
// 明确不负责的事情：不保存 context、不启动线程、不直接链接 flywow_logger.so、不直接写日志文件。
#pragma once

// Skynet 分配器头面向 C；SDK 不使用其分配函数，隔离该头以避免 C++ 声明冲突。
#ifndef skynet_malloc_h
#define skynet_malloc_h
#define FLYWOW_LOGGER_SKIP_MALLOC_HEADER
#endif
extern "C"
{
#include "skynet.h"
}
#ifdef FLYWOW_LOGGER_SKIP_MALLOC_HEADER
#undef skynet_malloc_h
#undef FLYWOW_LOGGER_SKIP_MALLOC_HEADER
#endif

#include <cstring>
#include <string>

namespace flywow_logger
{
enum class LogLevel
{
    Debug  = 0,
    Normal = 1,
    Error  = 2
};

constexpr std::size_t max_message_size = 8192;
constexpr std::size_t max_service_name_size = 128;

// Logger 文本消息的第一个字符是保留命令；Native callback 按字符选择处理分支。
// L：后面跟 0/1/2 等级和正文，表示写入一条日志。
// R：后面跟 Service 名称，建立 source handle 到可读名称的映射。
// U：不带正文，注销当前 source handle 的名称映射。
// F：不带正文，请求立即刷新当前日志文件。
constexpr char command_log        = 'L';
constexpr char command_register   = 'R';
constexpr char command_unregister = 'U';
constexpr char command_flush      = 'F';

// 返回日志级别的展示名称。
// 无内存分配、无 I/O、无共享状态；未知枚举按 ERROR 展示，避免静默降低严重程度。
inline const char* level_name(LogLevel level)
{
    switch (level)
    {
    case LogLevel::Debug:
        return "DEBUG";
    case LogLevel::Normal:
        return "NORMAL";
    default:
        return "ERROR";
    }
}

// 判断当前进程是否由 FlyWow Logger 接管日志。
// context 必须属于当前 Service；GETENV 返回值由 Skynet 管理，调用方只读不释放。
// 该查询不写盘、不修改配置；未启用时调用方应回退到普通 skynet_error。
inline bool enabled(skynet_context* context)
{
    if (context == nullptr)
    {
        return false;
    }

    const char* service = skynet_command(context, "GETENV", "logservice");
    return service != nullptr && std::strcmp(service, "flywow_logger") == 0;
}

// 向当前进程的 Logger 投递一条分级日志。
// level 决定过滤等级；message 只借用到本次调用结束，最长处理 8 KiB，超出部分会标记截断。
// 函数可能进行一次 std::string 分配，但不会 I/O、加锁、yield 或抛出异常；失败静默丢弃，不能破坏业务控制流。
// 未启用 FlyWow 时发送可读的普通文本；启用后使用内部标记，让 Native Logger 保留等级。
inline void log_write(skynet_context* context, LogLevel level, const char* message) noexcept
{
    if (context == nullptr || message == nullptr)
    {
        return;
    }

    try
    {
        const int severity = level == LogLevel::Debug ? 0 :
            level == LogLevel::Normal ? 1 : 2;
        const bool custom = enabled(context);

        // 过滤尽量在发送前完成，避免低等级日志占用 Skynet 消息队列。
        if (custom)
        {
            const char* threshold = skynet_command(context, "GETENV", "flywow_logger_level");
            const int minimum = threshold != nullptr && std::strcmp(threshold, "error") == 0 ? 2 :
                threshold != nullptr && std::strcmp(threshold, "debug") == 0 ? 0 : 1;
            if (severity < minimum)
            {
                return;
            }
        }

        const std::size_t length = ::strnlen(message, max_message_size + 1);
        std::string text(message, length);
        if (text.size() > max_message_size)
        {
            text.resize(max_message_size);
            text += " [TRUNCATED]";
        }

        if (custom)
        {
            // Native Logger 会识别 L 和等级，去掉两个命令字节后写盘。
            skynet_error(context, "%c%d%s", command_log, severity, text.c_str());
        }
        else
        {
            skynet_error(context, "[%s] %s", level_name(level), text.c_str());
        }
    }
    catch (...)
    {
        // 日志是辅助能力；分配失败不能让业务请求失败，也不能递归记录错误。
    }
}

// 登记当前 Native Service 的展示名称。
// name 只借用到本次调用，最多发送 128 字节；Logger 用 source handle 作为真实身份。
// 未启用 FlyWow 时无副作用；启用时异步投递，不等待、不直接写盘。
inline void register_service(skynet_context* context, const char* name)
{
    if (context == nullptr || name == nullptr || !enabled(context))
    {
        return;
    }

    skynet_error(context, "%c%.*s", command_register,
        static_cast<int>(max_service_name_size), name);
}
}
