// 本文件解决的问题：定义 Logger 的单实例日期文件写入边界。
// 所属边界：Runtime / File I/O；只管理日志目录、当天文件、缓冲和失败重试。
// 主要输入和输出：输入是已解析的等级、来源、正文和时间；输出是按日期追加的日志文件及可选 stdout 镜像。
// 生命周期与所有权：LogSink 由一个 Logger 独占；不跨线程共享，不把 FILE* 借给调用方。
// 明确不负责的事情：不调度 Skynet、不解析内部协议、不创建写线程、不清理历史日志。
#pragma once

#include <chrono>
#include <cstdio>
#include <string>

namespace flywow_logger
{
class LogSink
{
public:
    /// path 是日志目录，不能为空；构造阶段创建目录并解析为绝对路径。
    /// 目录或路径非法时抛出异常，由 Logger init 转换成启动失败。
    /// console 默认开启；设为 false 保留只写文件。stdout 由进程持有，本对象不关闭它。
    explicit LogSink(const std::string& path, bool console = true);

    /// 刷新并关闭当前文件；析构不会删除目录或历史日志。
    /// fclose 失败只写 stderr，避免析构阶段再次进入 Logger。
    ~LogSink();

    LogSink(const LogSink&) = delete;
    LogSink& operator=(const LogSink&) = delete;

    /// 按 now 的本地日期追加一行日志。
    /// level 使用 0/1/2 表示 DEBUG/NORMAL/ERROR；source 是展示文本，真实身份由上层附带 handle。
    /// 普通文件日志保留 stdio 缓冲，ERROR 立即 fflush；stdout 镜像每条刷新。
    /// 返回值仍仅表示文件写入/刷新结果，stdout 错误不覆盖文件失败语义。
    bool write(int level, const std::string& source, const std::string& text,
               std::chrono::system_clock::time_point now = std::chrono::system_clock::now());

    /// 刷新用户态 stdio 缓冲，不执行 fsync；没有打开文件或刷新失败时返回 false。
    bool flush();

    /// 确保 now 对应日期的文件已经打开；跨天时关闭旧文件并以追加方式打开新文件。
    /// 打开失败会进入限频重试，避免每条日志都重复产生系统调用和 stderr 噪声。
    bool open_day(std::chrono::system_clock::time_point now);

private:
    /// 记录一次失败并关闭失效句柄；下一次 open_day 到达重试时间后再尝试恢复。
    void reportFailure();

    bool console_;                                        ///< 构造时固定的 stdout 镜像开关；由同一 Logger callback 串行使用。
    std::string path_;                                    ///< 构造阶段解析的日志目录绝对路径，切换日期文件时复用。
    std::string day_;                                     ///< 当前文件对应的本地日期；与 write 输入日期比较以触发切换。
    FILE* file_ = nullptr;                                ///< 本对象独占的追加文件句柄；失败或析构时关闭。
    std::chrono::steady_clock::time_point retry_after_{}; ///< 写盘失败后的下次允许重开时间，使用单调时钟。
};
}
