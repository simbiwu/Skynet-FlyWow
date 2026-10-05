// 本文件解决的问题：实现 FlyWow Logger 的 Skynet Native Service 入口和消息分发。
// 所属边界：Runtime / Module；Skynet 创建本模块实例，callback 串行修改 Logger 状态。
// 主要输入和输出：输入是 Skynet 文本消息与控制消息，输出是按日期追加的日志文件和 flush 响应。
// 生命周期与所有权：Logger 由 flywow_logger_create 创建、由 Skynet 持有，release 负责销毁；
// LogSink 归 Logger 独占，消息 data 只借用到 callback 返回，不能保存指针。
// 明确不负责的事情：不创建写线程、不清理历史日志、不解析业务协议、不让业务 Service 直接调用 create/init。

#include "flywow_logger.h"
#include "log_sink.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace
{
// 每个来源 Service 的登记信息。
struct ServiceEntry
{
    // name 只用于日志展示；source handle 才是来源的真实身份。
    std::string name;
};

// 一个 Logger 对应一个 Skynet Native Service 实例。
// 所有可变状态都由 callback 串行访问，因此不需要额外的 Logger 锁。
struct Logger
{
    // Logger 独占 LogSink；释放 Logger 时先刷新并关闭文件。
    std::unique_ptr<flywow_logger::LogSink> sink;

    // 以 source handle 为键登记来源，容量受 max_sources 限制。
    std::unordered_map<uint32_t, ServiceEntry> services;

    // 最低日志级别：0=debug，1=normal，2=error。
    int minimum = 1;

    // 累计写盘失败次数；失败本身不再递归写入 Logger。
    uint64_t failures = 0;

    // 来源登记表满后使用的共享记录，不保存新的来源名称。
    ServiceEntry overflow;
};

constexpr std::size_t max_sources = 4096;
constexpr int error_level = static_cast<int>(flywow_logger::LogLevel::Error);
constexpr std::size_t log_header_size = 2;

// 回复控制请求的调用方。
// source 和 session 来自当前消息；session 为 0 表示单向消息，不应发送响应。
// skynet_send 会复制传入的文本，因此局部字符串在函数返回后仍然安全。
void reply(skynet_context* context, uint32_t source, int session, bool ok)
{
    if (session == 0)
    {
        return;
    }

    const char* text = ok ? "OK" : "ERROR";
    skynet_send(context, 0, source, PTYPE_RESPONSE, session,
        const_cast<char*>(text), std::strlen(text));
}

// 获取来源记录，并限制登记表的最大容量。
// 表满时返回 overflow；这样临时 Service 洪水不会让 unordered_map 无限增长。
ServiceEntry& source_entry(Logger& logger, uint32_t source)
{
    const auto found = logger.services.find(source);
    if (found != logger.services.end())
    {
        return found->second;
    }

    if (logger.services.size() < max_sources)
    {
        return logger.services.emplace(source, ServiceEntry{}).first->second;
    }

    return logger.overflow;
}

// 从 Skynet 的 LAUNCH 文本中提取初始 Service 名称。
// preload 安装前可能已经产生 LAUNCH，因此这里为尚未登记的来源补充可读名称。
void learn_launch_name(ServiceEntry& entry, const char* bytes, std::size_t size)
{
    if (!entry.name.empty() || size <= 7 ||
        std::memcmp(bytes, "LAUNCH ", 7) != 0)
    {
        return;
    }

    const std::string launch(bytes + 7,
        std::min(size - 7, static_cast<std::size_t>(256)));
    const std::size_t first = launch.compare(0, 6, "snlua ") == 0 ? 6 : 0;
    const std::size_t end = launch.find(' ', first);
    entry.name = launch.substr(first,
        end == std::string::npos ? flywow_logger::max_service_name_size : std::min(end - first, flywow_logger::max_service_name_size));
}

// 处理 Logger Service 的消息。
// PTYPE_TEXT 的第一个字符是 Logger 命令：
// L=分级日志，R=登记名称，U=注销来源，F=刷新文件。
// 消息 data 只在本次 callback 中借用；异常必须在 C callback 边界内消化。
int callback(skynet_context* context, void* ud, int type, int session,
            uint32_t source, const void* data, size_t size)
{
    auto& logger = *static_cast<Logger*>(ud);

    try
    {
        // 第一阶段：处理 Skynet 的周期刷新和系统关闭通知。
        if (type == PTYPE_RESPONSE && source == 0)
        {
            if (!logger.sink->flush())
            {
                ++logger.failures;
            }

            // TIMEOUT 100 表示约一秒后再次触发 response。
            skynet_command(context, "TIMEOUT", "100");
            return 0;
        }

        if (type == PTYPE_SYSTEM)
        {
            if (!logger.sink->flush())
            {
                ++logger.failures;
            }

            return 0;
        }

        // 第二阶段：Logger 只处理文本消息；其它消息类型交给 Skynet 丢弃。
        if (type != PTYPE_TEXT || data == nullptr)
        {
            return 0;
        }

        const char* bytes = static_cast<const char*>(data);
        const char command = size > 0 ? bytes[0] : '\0';

        // 第三阶段：先处理不产生普通日志行的控制消息。
        // F 是同步刷新请求，必须使用原 session 唤醒 skynet.call。
        if (command == flywow_logger::command_flush && size == 1)
        {
            reply(context, source, session, logger.sink->flush());
            return 0;
        }

        // 控制消息不接受普通响应 session，避免调用方误把日志当响应。
        if (session != 0)
        {
            reply(context, source, session, false);
            return 0;
        }

        // U 不带正文，只删除当前 source 的名称登记。
        if (command == flywow_logger::command_unregister && size == 1)
        {
            logger.services.erase(source);
            return 0;
        }

        ServiceEntry& entry = source_entry(logger, source);

        // R 后面的内容是 Lua Service 名称；Native Logger 保存它用于日志展示。
        // overflow 来源不保存名称，防止来源登记表继续增长。
        if (command == flywow_logger::command_register)
        {
            if (&entry != &logger.overflow && size > 1)
            {
                const std::size_t name_size = std::min(
                    size - 1, flywow_logger::max_service_name_size);
                entry.name.assign(bytes + 1, name_size);
            }

            return 0;
        }

        // 第四阶段：补充来源名称并解析日志级别。
        // preload 安装前可能已经产生 LAUNCH，因此先尝试学习标准启动日志中的名称。
        if (&entry != &logger.overflow)
        {
            learn_launch_name(entry, bytes, size);
        }

        // L 消息的第二个字节是等级；没有合法等级的文本按原生日志处理。
        int level = error_level;
        std::size_t offset = 0;
        const bool is_log_command = command == flywow_logger::command_log;
        const bool has_level_byte = size >= log_header_size;
        const char level_byte = has_level_byte ? bytes[1] : '\0';
        const bool has_valid_level = is_log_command &&
            has_level_byte &&
            level_byte >= '0' &&
            level_byte <= '2';

        if (has_valid_level)
        {
            level = level_byte - '0';
            offset = log_header_size;
        }

        if (level < logger.minimum)
        {
            return 0;
        }

        // 第五阶段：构造日志来源标识。
        // 名称只用于展示，source handle 才是来源身份；Logger 不在这里丢弃日志。
        char identity[180];
        std::snprintf(identity, sizeof(identity), "%s:%08x",
            entry.name.empty() ? "unknown" : entry.name.c_str(), source);

        // 第六阶段：复制并限制正文，再交给 LogSink。
        // data 只借用到 callback 返回，不能把 bytes 指针保存到 Logger 状态。
        const std::size_t length = size - offset;
        std::string text(bytes + offset, std::min(length, flywow_logger::max_message_size));
        if (length > flywow_logger::max_message_size)
        {
            text += " [TRUNCATED]";
        }

        if (!logger.sink->write(level, identity, text))
        {
            ++logger.failures;
        }
    }
    catch (const std::exception& exception)
    {
        // 异常不能穿过 Skynet C callback；控制请求收到失败，普通日志被丢弃。
        std::fprintf(stderr, "[flywow_logger] 接收失败: %s\n", exception.what());
        reply(context, source, session, false);
    }

    return 0;
}
}

extern "C"
{
// Skynet 模块入口：创建尚未绑定 Service context 的实例。
// 返回值由 Skynet 保存；分配失败返回 nullptr，启动流程会据此失败。
Logger* flywow_logger_create()
{
    try
    {
        return new Logger;
    }
    catch (...)
    {
        return nullptr;
    }
}

// Skynet 模块入口：解析 log_path 和等级，打开当天文件并注册 callback。
// parm 是配置传入的日志目录；Logger 拥有复制后的路径，不借用 parm 指针。
// 返回 0 表示 Service 已可接收日志，非 0 表示启动失败。
int flywow_logger_init(Logger* logger, skynet_context* context, const char* parm)
{
    if (logger == nullptr || context == nullptr)
    {
        return 1;
    }

    try
    {
        // 第一阶段：读取并校验最低日志等级。
        const char* configured_level =
            skynet_command(context, "GETENV", "flywow_logger_level");
        const std::string threshold =
            configured_level == nullptr ? "normal" : configured_level;

        if (threshold != "debug" &&
            threshold != "normal" &&
            threshold != "error")
        {
            throw std::runtime_error("非法日志级别");
        }

        if (threshold == "debug")
        {
            logger->minimum = 0;
        }
        else if (threshold == "normal")
        {
            logger->minimum = 1;
        }
        else
        {
            logger->minimum = 2;
        }

        // 第二阶段：创建 LogSink，并立即确认当天文件可写。
        const char* log_path = parm == nullptr ? "" : parm;
        logger->sink.reset(new flywow_logger::LogSink(log_path));

        if (!logger->sink->open_day(std::chrono::system_clock::now()))
        {
            throw std::runtime_error("无法打开当天日志");
        }

        // 第三阶段：把 callback 交给 Skynet，并启动周期 flush。
        skynet_callback(context, logger, callback);
        skynet_command(context, "TIMEOUT", "100");
        return 0;
    }
    catch (const std::exception& exception)
    {
        std::fprintf(stderr, "[flywow_logger] 启动失败: %s\n", exception.what());
        return 1;
    }
}

// Skynet 模块入口：释放 Logger 及其 LogSink。
// unique_ptr 先析构 LogSink，刷新并关闭当前文件；历史文件和目录保留。
void flywow_logger_release(Logger* logger)
{
    delete logger;
}
}
