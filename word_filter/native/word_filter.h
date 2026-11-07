// 职责：WordFilter 的内部 C++ 核心合同，复用 FCLib 的 AC 自动机和 UTF-8 位置映射。
// 输入为宿主词库与文本，输出为命中区间；不负责文件读取、聊天策略或 Lua 对象管理。
// 宿主公开入口为 flywow_word_filter.lua；以下类型不承诺兼容原 FCLib API。
#ifndef FLYWOW_WORD_FILTER_H
#define FLYWOW_WORD_FILTER_H

#include <cstddef>
#include <cstdint>
#include <string_view>
#include <utility>
#include <vector>

namespace flywow_word_filter
{
    // 固定容量只限制当前实际持有的词库、自动机和查询结果；超限报错，不截断。
    constexpr std::size_t   kMaxKeywords         = 16384;
    constexpr std::size_t   kMaxKeywordBytes    = 4096;
    constexpr std::size_t   kMaxDictionaryBytes = 1048576; // 原始词库总字节数。
    constexpr std::size_t   kMaxNodes            = 262144;  // 包含根节点。
    constexpr std::size_t   kMaxOutputs          = 1048576; // 含复制的后缀命中项。
    constexpr std::size_t   kMaxTextBytes       = 65536;
    constexpr std::size_t   kMaxMatches          = 4096; // 重叠和重复词分别计数。
    constexpr std::uint32_t kMaxCompactSpan     = 256;  // 原文区间，单位 bytes。

    struct Match
    {
        std::int32_t keyword_id;         // 调用方指定的 ID，Lua 使用 1-based 数组下标。
        std::uint32_t source_byte_offset; // 原文 0-based byte 起点。
        std::uint32_t source_byte_length; // 原文跨度，包含 compact 跳过的中间字符。
    };

    enum class BuildError
    {
        kNone,
        kAlreadyBuilt,
        kInvalidKeyword,
        kDictionaryLimit,
    };

    enum class QueryError
    {
        kNone,
        kNotBuilt,
        kInvalidUtf8,
        kTextLimit,
        kMatchLimit,
    };

    struct QueryResult
    {
        QueryError error;        // 查询失败原因；kNone 表示完整扫描成功。
        std::size_t match_count; // 成功时统计有效命中，失败时为零。
    };

    // 对象独占词库和自动机。addKeyword/build 不得与查询并发；
    // build 成功后可只读并发查询，各调用必须独占自己的临时数据及 results。
    // 所有核心操作无 I/O、无锁、无 yield；分配失败由运行时处理。
    class Filter
    {
      public:
        Filter();
        /// 构建词库时加入一个词，只保存其 ID 和归一化后的码点数。
        /// @param keyword 宿主词库中的原始 UTF-8 词条。
        /// @param keyword_id 调用方为该词条分配的 ID，Lua 使用数组下标。
        /// @return 成功返回 kNone；已构建、非法词条和超限分别返回对应原因。
        /// @note 添加失败后销毁候选词库，部分 trie 不可继续使用。
        BuildError addKeyword(std::string_view keyword, std::int32_t keyword_id);

        /// 添加完词条后建立 fail 链和后缀输出；成功后重复调用不修改词库。
        /// @return 成功返回 kNone；后缀输出超限返回 kDictionaryLimit。
        /// @note 构建失败后销毁候选词库，部分后缀输出不可重用。
        BuildError build();

        /// 校验完整原文后扫描已构建词库，检查跨度与命中上限。
        /// @param source_text 宿主传入的 UTF-8 原文。
        /// @param compact 是否忽略指定分隔码点并检查原文跨度。
        /// @param matches 接收命中的容器；传 nullptr 时只计数。返回预期错误时清空容器。
        /// @return 有效命中数，或本次查询的失败原因。
        QueryResult query(std::string_view source_text, bool compact, std::vector<Match> *matches) const;

      private:
        struct SourcePoint
        {
            std::uint32_t code_point; // 归一化后用于查找 trie 出边。
            std::uint32_t source_byte_begin;      // 原文 byte 起点。
            std::uint32_t source_byte_end;        // 原文 byte 结束位置，不包含该位置。
        };

        struct Keyword
        {
            std::int32_t keyword_id;      // 调用方指定的 ID，Lua 使用 1-based 数组下标。
            std::size_t code_point_count; // 通过结束位置反推命中起点。
        };

        using Edges = std::vector<std::pair<std::uint32_t, std::int32_t>>;

        struct Node
        {
            std::int32_t                                        fail_node_index; // 当前前缀的最长可用后缀；0 为根。
            Edges children;        // 有序的“码点 -> 节点索引”边。
            std::vector<std::int32_t> output_keyword_indices; // 本节点和后缀的词条索引，按码点数从长到短排列。

            Node() : fail_node_index(0)
            {
            }
        };

        // 解码一个完整 Unicode 标量；成功推进 byte_offset，失败不推进，由调用者处理非法 byte。
        static bool decodeUtf8Char(const std::uint8_t *bytes, std::uint32_t byte_count, std::uint32_t &byte_offset,
                                     std::uint32_t &code_point);
        static bool normalizeUtf8(std::string_view source_text, std::vector<SourcePoint> &points, bool compact);
        static std::uint32_t normalizeCodePoint(std::uint32_t code_point);
        static bool isCompactIgnored(std::uint32_t code_point);

        // 按码点定位已有出边或新边的插入位置。
        static Edges::const_iterator lowerBoundEdge(const Edges &children, std::uint32_t code_point);
        // 构建和扫描共用 fail 链查找。没有可用后缀时返回根节点。
        std::int32_t followEdge(std::int32_t node_index, std::uint32_t code_point) const;

        std::vector<Keyword> keywords_;
        std::vector<Node>    nodes_; // 索引 0 永远为根节点。
        bool built_ = false; // build 完整建立后缀输出后置为 true，随后只读。
        std::size_t                 dictionary_byte_count_ = 0; // 原始词库总字节数。
    };
} // namespace flywow_word_filter

#endif
