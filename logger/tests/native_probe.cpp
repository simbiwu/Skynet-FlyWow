// 职责：真实 Native Service 验证 SDK 分级发送与官方 Logger 回退；仅用于测试。
#include "flywow_logger.h"
extern "C"
{
// 无可变实例状态，静态哨兵仅标识创建成功。
void* flywow_logger_probe_native_create()
{
    static const char marker = 0;
    return const_cast<char*>(&marker);
}

// 在有效 context 内登记来源并发送三级日志；不保存 context 或创建线程。
int flywow_logger_probe_native_init(void*, skynet_context* context, const char*)
{
    flywow_logger::register_service(context, "native_probe");
    flywow_logger::log_write(context, flywow_logger::LogLevel::Debug, "NATIVE_DEBUG");
    flywow_logger::log_write(context, flywow_logger::LogLevel::Normal, "NATIVE_NORMAL");
    flywow_logger::log_write(context, flywow_logger::LogLevel::Error, "NATIVE_ERROR");
    return 0;
}

// 无动态资源，释放时不执行 I/O。
void flywow_logger_probe_native_release(void*)
{
}
}
