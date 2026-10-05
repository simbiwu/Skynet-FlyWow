// 职责：验证移植 AC 算法、原文映射、重复构建和只读并发；失败非零退出。
#include "word_filter.h"
#include <future>
#include <iostream>
#include <stdexcept>
using namespace flywow_word_filter;

// 每个检查携带场景名称，失败时能定位具体合同；异常由 main 转成非零退出。
void flywow_check(bool value, const char *scenario)
{
    if (!value)
    {
        throw std::runtime_error(scenario);
    }
}

int main()
{
    try
    {
        // “she”同时命中“he”，覆盖 fail 输出继承和重复构建的回归。
        flywow_filter filter;
        flywow_check(filter.add_keyword("he", 1), "添加后缀词 he");
        flywow_check(filter.add_keyword("she", 2), "添加前缀词 she");
        flywow_check(filter.add_keyword("外挂", 3), "添加中文词库");
        flywow_check(filter.build(), "首次 build");
        flywow_check(filter.build(), "重复 build 必须幂等");
        std::vector<flywow_match> matches;
        flywow_check(filter.find("SHE", matches), "ASCII 大小写折叠");
        flywow_check(matches.size() == 2, "she 必须同时返回 she 和 he");
        flywow_check(filter.find("前外挂后", matches), "中文原文查询");
        flywow_check(matches.size() == 1 && matches[0].source_byte_offset == 3 && matches[0].source_byte_length == 6,
                     "中文命中 byte 区间映射");
        flywow_check(filter.find(std::string("x\0she", 5), matches), "NUL 不截断文本");
        flywow_check(matches.size() == 2 && matches[0].source_byte_offset >= 2, "NUL 后仍有后缀命中");
        flywow_check(!filter.find(std::string("\xff", 1), matches), "非法 UTF-8 应拒绝");
        flywow_check(filter.find_compact("外-挂", matches), "compact 忽略 ASCII 分隔符");
        flywow_check(matches.size() == 1 && matches[0].source_byte_length == 7, "compact 保留原文 7 bytes 跨度");
        // 两个线程共享已构建的只读核心，每次调用使用自己的输出容器。
        auto query_repeatedly = [&filter]()
        {
            for (int index = 0; index < 1000; ++index)
            {
                std::vector<flywow_match> thread_matches;
                flywow_check(filter.find("she外挂", thread_matches) && thread_matches.size() == 3, "只读并发查询");
            }
        };
        auto first_query_task  = std::async(std::launch::async, query_repeatedly);
        auto second_query_task = std::async(std::launch::async, query_repeatedly);
        first_query_task.get();
        second_query_task.get();
        std::cout << "FLYWOW_WORD_FILTER_CORE_OK\n";
        return 0;
    }
    catch (const std::exception &error)
    {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
