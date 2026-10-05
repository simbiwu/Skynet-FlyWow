// 职责：WordFilter 的内部 C++ 核心合同，复用 FCLib 的 AC 自动机和 UTF-8 位置映射。
// 输入为宿主词库与文本，输出为命中区间；不负责文件读取、聊天策略或 Lua 对象管理。
// 宿主公开入口为 flywow_word_filter.lua；以下类型不承诺兼容原 FCLib API。
#ifndef FLYWOW_WORD_FILTER_H
#define FLYWOW_WORD_FILTER_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace flywow_word_filter
{
    // 固定容量只限制当前实际持有的词库、自动机和查询结果；超限报错，不截断。
    constexpr std::size_t   flywow_max_keywords         = 16384;
    constexpr std::size_t   flywow_max_keyword_bytes    = 4096;
    constexpr std::size_t   flywow_max_dictionary_bytes = 1048576; // 原始词库总字节数。
    constexpr std::size_t   flywow_max_nodes            = 262144;  // 包含根节点。
    constexpr std::size_t   flywow_max_outputs          = 1048576; // 含复制的后缀命中项。
    constexpr std::size_t   flywow_max_text_bytes       = 65536;
    constexpr std::size_t   flywow_max_matches          = 4096; // 重叠和重复词分别计数。
    constexpr std::uint32_t flywow_max_compact_span     = 256;  // 原文区间，单位 bytes。

    // 词库和查询须使用相同归一化选项；Lua 入口固定使用此默认配置。
    struct flywow_normalize_options
    {
        flywow_normalize_options();

        bool lower_ascii;        // ASCII A..Z 转为 a..z，不进行 Unicode 全量大小写折叠。
        bool fullwidth_to_ascii; // 全角 ASCII 和全角空格折叠。
        bool drop_utf8_bom;      // 只忽略原文开头的 BOM，保留后续原文字节偏移。
        bool keep_invalid_bytes; // 核心可用的保留模式；Lua 入口固定 false。
    };

    // 核心保留 FCLib 的 compact 分类；Lua 仅暴露开关，并固定 span 为 256 bytes。
    struct flywow_compact_options
    {
        flywow_compact_options();

        bool          ignore_space;             // 忽略空格、tab、CR、LF。
        bool          ignore_control;           // 忽略剩余 ASCII 控制字符及 DEL。
        bool          ignore_ascii_punctuation; // 忽略 ASCII 标点，不扩展到全部 Unicode 标点。
        bool          ignore_zero_width;        // 忽略实现列出的零宽、方向标记及行段分隔符。
        std::uint32_t max_source_span_bytes;    // 原文命中跨度上限；核心中 0 表示不限制。
    };

    // 四个容器由调用者独占；三个映射数组与 code_points 一一对应。
    // 例如全角“Ａ”变为 text 中一个 byte，source_byte_lengths 仍记录原文 3 bytes。
    struct flywow_normalized_text
    {
        std::string                text;                // 归一化后的编码文本。
        std::vector<std::uint32_t> source_byte_offsets; // 每个码点在原文的 0-based byte 起点。
        std::vector<std::uint32_t> source_byte_lengths; // 每个码点在原文的 byte 长度。
        std::vector<std::uint32_t> code_points;         // AC 实际扫描的码点序列。

        void clear();
    };

    struct flywow_match
    {
        flywow_match();

        std::int32_t  keyword_id;                   // 调用者 ID；Lua 使用词库 1-based 索引。
        std::string   source_keyword;               // 原始关键词副本，归返回结果所有。
        std::uint32_t normalized_code_point_offset; // 归一化序列的 0-based 码点位置。
        std::uint32_t normalized_code_point_length; // 命中的码点数，不是 UTF-8 字节数。
        std::uint32_t source_byte_offset;           // 原文的 0-based byte 起点。
        std::uint32_t source_byte_length;           // 原文字节跨度，compact 时含中间分隔符。
    };

    // 对象独占词库和自动机。add_keyword/build/clear 不得与查询并发；
    // build 成功后可只读并发查询，各调用必须独占自己的临时数据及 results。
    // 所有核心操作无 I/O、无锁、无 yield；会分配内存，bad_alloc 交由 Binding 转换。
    class flywow_filter
    {
      public:
        flywow_filter();
        ~flywow_filter();

        // 清空全部词库与构建状态，恢复空 trie；保留对象供重新添加词库。
        void clear();

        // 复制并归一化关键词；keyword_id<0 时使用 0-based 添加序号。
        // 空词或不合法 UTF-8 返回 false；容量超限/已构建抛 runtime_error。
        // 添加失败若抛异常，对象应销毁或 clear 后重建，不能继续使用部分状态。
        bool add_keyword(const std::string &keyword, std::int32_t keyword_id = -1,
                         const flywow_normalize_options &normalization_options = flywow_normalize_options());

        // 构建 fail 链和后缀输出，成功返回 true；空词库合法，成功后的重复 build 幂等。
        // 后缀输出超限抛 dictionary_limit；异常后须销毁或 clear 后重建。
        bool build();

        // 归一化原文并返回全部命中，不排序、不合并；source_text 允许内嵌 NUL。
        // 未构建/非法 UTF-8 返回 false 并清空 results；容量超限抛 text_limit/match_limit。
        // results 归调用者所有；异常时可能含部分结果，Binding 必须清空后再返回错误。
        bool find(const std::string &source_text, std::vector<flywow_match> &results,
                  const flywow_normalize_options &normalization_options = flywow_normalize_options()) const;

        // 复用 normalize_utf8/compact_normalized_text 产生的映射，避免再次归一化。
        // 未构建或映射数组长度不一致返回 false；仅接受内部生成、原文偏移有序的映射。
        bool find_normalized(const flywow_normalized_text &normalized, std::vector<flywow_match> &results) const;

        // 归一化、忽略配置中的分隔字符，再匹配；返回/异常语义与 find 相同。
        // span 上限按原文 bytes 检查，而不是 compact 后码点数。
        bool find_compact(const std::string &source_text, std::vector<flywow_match> &results,
                          const flywow_normalize_options &normalization_options = flywow_normalize_options(),
                          const flywow_compact_options   &compact_options       = flywow_compact_options()) const;

        // 复用已归一化的映射做 compact 查询；失败清空 results，超限异常同 find。
        bool find_compact_normalized(const flywow_normalized_text &normalized, std::vector<flywow_match> &results,
                                     const flywow_compact_options &compact_options = flywow_compact_options()) const;

        // 生成归一化文本、码点及原文 byte 映射，覆盖 result；超长输入抛 text_limit。
        // 非法 UTF-8 且不保留时返回 false，result 仅为部分归一化数据，不可继续匹配。
        static bool normalize_utf8(const std::string &source_text, flywow_normalized_text &result,
                                   const flywow_normalize_options &normalization_options = flywow_normalize_options());

        // 删除配置中的分隔码点并复制其余原文映射；输入输出不得是同一对象。
        // 映射长度不一致返回 false；不改变 normalized，结果归调用者所有。
        static bool compact_normalized_text(const flywow_normalized_text &normalized, flywow_normalized_text &result,
                                            const flywow_compact_options &compact_options = flywow_compact_options());

      private:
        struct flywow_keyword
        {
            std::int32_t               keyword_id;
            std::string                source_keyword;
            std::vector<std::uint32_t> code_points;
        };

        struct flywow_node
        {
            std::int32_t                                        fail_node_index; // 当前前缀的最长可用后缀；0 为根。
            std::vector<std::pair<std::uint32_t, std::int32_t>> children;        // 有序的“码点 -> 节点索引”边。
            std::vector<std::int32_t>                           outputs; // keywords_ 的索引，包含本节点及后缀命中。

            flywow_node() : fail_node_index(0)
            {
            }
        };

        // 解码一个完整 Unicode 标量；成功推进 byte_offset，失败不推进，由调用者处理非法 byte。
        static bool decode_utf8_char(const std::uint8_t *bytes, std::uint32_t byte_count, std::uint32_t &byte_offset,
                                     std::uint32_t &code_point, std::uint32_t &character_byte_count);
        static void append_utf8_char(std::uint32_t code_point, std::string &text);
        static std::uint32_t normalize_code_point(std::uint32_t                   code_point,
                                                  const flywow_normalize_options &normalization_options);
        static bool is_compact_ignored(std::uint32_t code_point, const flywow_compact_options &compact_options);
        static void append_normalized_code_point(std::uint32_t code_point, std::string &text);

        // find_child_edge 返回边的位置；find_child_node 返回目标节点索引；缺失都用 -1。
        // set_child_node 必须维持 children 按码点排序，二分查找依赖此不变量。
        static std::int32_t find_child_edge(const flywow_node &node, std::uint32_t code_point);
        static std::int32_t find_child_node(const flywow_node &node, std::uint32_t code_point);
        static void         set_child_node(flywow_node &node, std::uint32_t code_point, std::int32_t next_node_index);

        std::vector<flywow_keyword> keywords_;
        std::vector<flywow_node>    nodes_; // 索引 0 永远为根节点。
        bool                        built_;
        std::size_t                 dictionary_byte_count_ = 0; // 原始词库总字节数，clear 时归零。
    };
} // namespace flywow_word_filter

#endif
