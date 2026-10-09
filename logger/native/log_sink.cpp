// 本文件解决的问题：实现 Logger 的日期文件切换、单行格式化和失败恢复。
// 所属边界：Runtime / File I/O；LogSink 的全部可变文件状态只由 Logger callback 串行访问。
// 主要输入和输出：输入是日志记录和可注入时间；输出是 <log_path>/YYYY-MM-DD.log。
// 生命周期与所有权：path_ 是构造时解析出的绝对路径，file_ 由本对象打开并由本对象关闭。
// 明确不负责的事情：不创建线程、不清理旧文件、不发送 Skynet 消息、不改变系统时钟。
#include "log_sink.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <ctime>
#include <limits.h>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

namespace flywow_logger
{
namespace
{
constexpr std::size_t max_text_size = 8192;
constexpr std::size_t file_buffer_size = 64 * 1024;

// 按路径的每一级递归创建目录。
// 已存在且确实是目录时继续；若路径中有普通文件或权限不足，直接抛出启动错误。
void create_directory(const std::string& path)
{
    for (std::size_t i = 1; i <= path.size(); ++i)
    {
        if (i != path.size() && path[i] != '/')
        {
            continue;
        }

        const std::string part = path.substr(0, i);
        if (part.empty())
        {
            continue;
        }

        if (::mkdir(part.c_str(), 0750) != 0 && errno != EEXIST)
        {
            throw std::runtime_error("创建日志目录失败: " + part + ": " + std::strerror(errno));
        }

        struct stat status{};
        if (::stat(part.c_str(), &status) != 0 || !S_ISDIR(status.st_mode))
        {
            throw std::runtime_error("日志路径不是目录: " + part);
        }
    }
}

// 把一条日志限制为单行，防止正文中的换行伪造后续日志头。
// 控制字符替换为 '?'，换行和回车保留为可读转义；最多处理 8 KiB。
std::string single_line(const std::string& text)
{
    const std::size_t size = std::min(text.size(), max_text_size);
    std::string result;
    result.reserve(size + 32);

    for (std::size_t i = 0; i < size; ++i)
    {
        const unsigned char ch = text[i];
        if (ch == '\n')
        {
            result += "\\n";
        }
        else if (ch == '\r')
        {
            result += "\\r";
        }
        else if (ch < 32 || ch == 127)
        {
            result += '?';
        }
        else
        {
            result += static_cast<char>(ch);
        }
    }

    if (text.size() > size)
    {
        result += " [TRUNCATED]";
    }

    return result;
}

// 把时间转换为 YYYY-MM-DD；失败返回空字符串，调用者不应打开未知日期文件。
std::string local_day(std::chrono::system_clock::time_point now)
{
    const time_t seconds = std::chrono::system_clock::to_time_t(now);
    tm local{};
    if (::localtime_r(&seconds, &local) == nullptr)
    {
        return {};
    }

    char date[16]{};
    if (std::strftime(date, sizeof(date), "%Y-%m-%d", &local) == 0)
    {
        return {};
    }

    return date;
}
}

// 创建目录并锁定绝对路径，使运行过程中不依赖后续工作目录变化。
LogSink::LogSink(const std::string& path)
{
    if (path.empty() || path.size() >= PATH_MAX)
    {
        throw std::runtime_error("log_path 不能为空或超过系统路径上限");
    }

    create_directory(path);

    char resolved[PATH_MAX]{};
    if (::realpath(path.c_str(), resolved) == nullptr)
    {
        throw std::runtime_error("无法解析 log_path: " + path);
    }

    path_ = resolved;
}

// 正常释放时关闭当前文件；异常终止进程不属于析构可保证的范围。
LogSink::~LogSink()
{
    if (file_ == nullptr)
    {
        return;
    }

    if (std::fclose(file_) != 0)
    {
        std::fprintf(stderr, "[flywow_logger] 关闭日志失败\n");
    }

    file_ = nullptr;
}

// 确保当天文件已经打开。
// 同一天直接复用句柄；跨天先关闭旧文件，再以追加方式打开 YYYY-MM-DD.log。
// 打开失败不会立即循环重试，而是由 report_failure 限制为最多每秒一次。
bool LogSink::open_day(std::chrono::system_clock::time_point now)
{
    const std::string date = local_day(now);
    if (date.empty())
    {
        return false;
    }

    if (file_ != nullptr && day_ == date)
    {
        return true;
    }

    if (file_ == nullptr && std::chrono::steady_clock::now() < retry_after_)
    {
        return false;
    }

    if (file_ != nullptr)
    {
        const bool failed = std::fclose(file_) != 0;
        file_ = nullptr;
        if (failed)
        {
            report_failure();
            return false;
        }
    }

    const std::string filename = path_ + "/" + date + ".log";
    file_ = std::fopen(filename.c_str(), "a");
    if (file_ == nullptr)
    {
        report_failure();
        return false;
    }

    day_ = date;
    // 只设置 stdio 缓冲，不在每条普通日志后 fflush；ERROR 由 write 单独刷新。
    std::setvbuf(file_, nullptr, _IOFBF, file_buffer_size);
    return true;
}

// 写盘失败只向 stderr 报告，并关闭失效句柄。
// stderr 不能再经由 Logger，否则会形成“记录错误失败 -> 再记录错误”的递归。
void LogSink::report_failure()
{
    const auto now = std::chrono::steady_clock::now();
    if (now >= retry_after_)
    {
        std::fprintf(stderr, "[flywow_logger] 写盘失败: %s; 一秒后重试\n",
            std::strerror(errno));
    }

    retry_after_ = now + std::chrono::seconds(1);
    if (file_ != nullptr)
    {
        std::fclose(file_);
        file_ = nullptr;
    }
}

// 刷新当前文件的用户态缓冲；不保证物理磁盘已经 fsync。
bool LogSink::flush()
{
    if (file_ == nullptr)
    {
        return false;
    }

    if (std::fflush(file_) != 0)
    {
        report_failure();
        return false;
    }

    return true;
}

// 写入一行完整日志。
// now 注入是为了测试跨天切换；生产默认使用调用点提供的系统时间。
bool LogSink::write(int level, const std::string& source, const std::string& text,
                    std::chrono::system_clock::time_point now)
{
    if (!open_day(now))
    {
        return false;
    }

    const auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()).count();
    const time_t seconds = static_cast<time_t>(milliseconds / 1000);
    tm local{};
    if (::localtime_r(&seconds, &local) == nullptr)
    {
        return false;
    }

    char stamp[32]{};
    if (std::strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &local) == 0)
    {
        return false;
    }

    const char* label = level == 0 ? "DEBUG" :
        level == 1 ? "NORMAL" : "ERROR";
    const std::string body = single_line(text);
    const std::string name = single_line(source);

    if (std::fprintf(file_, "%s.%03lld [%s] [%s] %s\n", stamp,
        static_cast<long long>(milliseconds % 1000), label, name.c_str(), body.c_str()) < 0)
    {
        report_failure();
        return false;
    }

    // ERROR 是当前级别中最需要尽快可见的记录；普通日志保留缓冲以减少 fflush 次数。
    return level == 2 ? flush() : true;
}
}
