// 职责：真实文件测试每日轮转、同日追加、转义与非法目录；测试时钟不改变系统时间。
// 临时目录归测试拥有；不启动 Skynet，不删除开发者日志。
#include "log_sink.h"
#include <cassert>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <unistd.h>

// 读取测试产生的文件；失败通过 assert 暴露，只读 I/O，结果归调用者。
static std::string read_file(const std::string& path)
{
    std::ifstream input(path);
    assert(input.good());
    return std::string(std::istreambuf_iterator<char>(input), {});
}

// 测试入口：用 UTC 固定时间验证跨天，不依赖机器日期；结束清理自己创建的三个文件。
int main()
{
    ::setenv("TZ", "UTC", 1);
    ::tzset();
    char pattern[] = "/tmp/flywow_logger_test_XXXXXX";
    const char* directory = ::mkdtemp(pattern);
    assert(directory);
    const std::string path = directory;
    const auto first = std::chrono::system_clock::from_time_t(1767225599); // 2025-12-31 23:59:59 UTC。
    const auto next = first + std::chrono::seconds(2);
    {
        flywow_logger::LogSink sink(path);
        assert(sink.write(1, "worker:12", "first\nline", first));
        assert(sink.write(2, "worker:12", "next", next));
        assert(sink.flush());
    }
    {
        flywow_logger::LogSink sink(path);
        assert(sink.write(2, "worker:12", "append", next));
    }
    const auto old = read_file(path + "/2025-12-31.log");
    const auto fresh = read_file(path + "/2026-01-01.log");
    assert(old.find("first\\nline") != std::string::npos);
    assert(fresh.find("next") != std::string::npos && fresh.find("append") != std::string::npos);
    bool failed = false;
    try
    {
        flywow_logger::LogSink invalid(path + "/2026-01-01.log/child");
    }
    catch (const std::runtime_error&)
    {
        failed = true;
    }
    assert(failed);
    {
        // /dev/full 模拟打开成功但刷新失败；移除故障后验证受控重试恢复。
        const std::string failure = path + "/failure";
        flywow_logger::LogSink sink(failure);
        assert(::symlink("/dev/full", (failure + "/2026-01-01.log").c_str()) == 0);
        assert(!sink.write(2, "worker:12", "failure", next));
        assert(!sink.flush());
        ::unlink((failure + "/2026-01-01.log").c_str());
        ::usleep(1100000);
        assert(sink.write(2, "worker:12", "recovered", next));
        assert(read_file(failure + "/2026-01-01.log").find("recovered") != std::string::npos);
        ::unlink((failure + "/2026-01-01.log").c_str());
        ::rmdir(failure.c_str());
    }
    ::unlink((path + "/2025-12-31.log").c_str());
    ::unlink((path + "/2026-01-01.log").c_str());
    ::rmdir(path.c_str());
    return 0;
}
