// 职责：验证移植 AC 算法、原文映射、建库后的词条 ID 和只读并发；失败非零退出。
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
        // 单次构建后，“she”同时命中“he”，两个 ID 对应原始词库中的加入顺序。
        Filter filter;
        flywow_check(filter.addKeyword("he") == BuildError::kNone, "添加后缀词 he");
        flywow_check(filter.addKeyword("she") == BuildError::kNone, "添加前缀词 she");
        flywow_check(filter.addKeyword("外挂") == BuildError::kNone, "添加中文词库");
        flywow_check(filter.build() == BuildError::kNone, "构建词库");
        std::vector<Match> matches;
        flywow_check(filter.query("SHE", false, &matches).error == QueryError::kNone, "ASCII 大小写折叠");
        flywow_check(matches.size() == 2 && matches[0].keyword_id == 2 && matches[1].keyword_id == 1,
                     "she 必须同时返回自身和 he，两个 ID 对应加入顺序");
        flywow_check(filter.query("前外挂后", false, &matches).error == QueryError::kNone, "中文原文查询");
        flywow_check(matches.size() == 1 && matches[0].source_byte_offset == 3 && matches[0].source_byte_length == 6,
                     "中文命中 byte 区间映射");
        flywow_check(filter.query(std::string("x\0she", 5), false, &matches).error == QueryError::kNone, "NUL 不截断文本");
        flywow_check(matches.size() == 2 && matches[0].source_byte_offset >= 2, "NUL 后仍有后缀命中");
        flywow_check(filter.query(std::string("\xff", 1), false, &matches).error == QueryError::kInvalidUtf8, "非法 UTF-8 应拒绝");
        flywow_check(filter.query("外-挂", true, &matches).error == QueryError::kNone, "compact 忽略 ASCII 分隔符");
        flywow_check(matches.size() == 1 && matches[0].source_byte_length == 7, "compact 保留原文 7 bytes 跨度");
        // 两个线程共享已构建的只读核心，每次调用使用自己的输出容器。
        auto query_repeatedly = [&filter]()
        {
            for (int index = 0; index < 1000; ++index)
            {
                std::vector<Match> thread_matches;
                flywow_check(filter.query("she外挂", false, &thread_matches).error == QueryError::kNone && thread_matches.size() == 3, "只读并发查询");
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
