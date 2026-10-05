// 本文件解决的问题：定义 Logger 的单实例日期文件写入边界。
// 所属边界：Runtime / File I/O；只管理日志目录、当天文件、缓冲和失败重试。
// 主要输入和输出：输入是已解析的等级、来源、正文和时间；输出是按日期追加的日志文件。
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
    // path 是日志目录，不能为空；构造阶段创建目录并解析为绝对路径。
    // 目录或路径非法时抛出异常，由 Logger init 转换成启动失败。
    explicit LogSink(const std::string& path);

    // 刷新并关闭当前文件；析构不会删除目录或历史日志。
    // fclose 失败只写 stderr，避免析构阶段再次进入 Logger。
    ~LogSink();

    LogSink(const LogSink&) = delete;
    LogSink& operator=(const LogSink&) = delete;

    // 按 now 的本地日期追加一行日志。
    // level 使用 0/1/2 表示 DEBUG/NORMAL/ERROR；source 是展示文本，真实身份由上层附带 handle。
    // 普通日志保留 stdio 缓冲，ERROR 写入后立即 fflush；返回值表示本次写入是否成功。
    bool write(int level, const std::string& source, const std::string& text,
               std::chrono::system_clock::time_point now = std::chrono::system_clock::now());

    // 刷新用户态 stdio 缓冲，不执行 fsync；没有打开文件或刷新失败时返回 false。
    bool flush();

    // 确保 now 对应日期的文件已经打开；跨天时关闭旧文件并以追加方式打开新文件。
    // 打开失败会进入限频重试，避免每条日志都重复产生系统调用和 stderr 噪声。
    bool open_day(std::chrono::system_clock::time_point now);

private:
    // 记录一次失败并关闭失效句柄；下一次 open_day 到达重试时间后再尝试恢复。
    void report_failure();

    std::string path_;
    std::string day_;
    FILE* file_ = nullptr;
    std::chrono::steady_clock::time_point retry_after_{};
};
}
