// 职责：从 FCLib FCKeywordFilter 移植的 UTF-8 归一化、AC 匹配与原文 byte 映射。
// Runtime 核心不依赖 Skynet 或业务词库；构建后只读，查询临时数据由调用者独占。
#include "word_filter.h"
#include <algorithm>
#include <queue>

namespace flywow_word_filter
{
    Filter::Filter()
    {
        // 索引 0 永远为根节点；即使词库为空也允许查询。
        nodes_.emplace_back();
    }

    BuildError Filter::addKeyword(std::string_view keyword, std::int32_t keyword_id)
    {
        if (built_)
        {
            return BuildError::kAlreadyBuilt;
        }

        if (keywords_.size() >= kMaxKeywords || keyword.size() > kMaxKeywordBytes ||
            keyword.size() > kMaxDictionaryBytes - dictionary_byte_count_)
        {
            return BuildError::kDictionaryLimit;
        }

        std::vector<SourcePoint> points; // 词条归一化后的码点，用于建立 trie 路径。
        if (!normalizeUtf8(keyword, points, false))
        {
            return BuildError::kInvalidKeyword;
        }

        if (points.empty())
        {
            return BuildError::kInvalidKeyword;
        }

        // 终止节点用词条索引引用 ID 和码点长度，重复词仍有独立索引。
        const auto keyword_index = static_cast<std::int32_t>(keywords_.size());
        keywords_.push_back({keyword_id, points.size()});
        dictionary_byte_count_ += keyword.size();

        // trie 的边使用完整码点；例如“外”是一个节点，而不是三个 UTF-8 字节节点。
        std::int32_t node_index = 0;
        for (std::size_t index = 0; index < points.size(); ++index)
        {
            const auto code_point = points[index].code_point; // 词条当前码点，用于查找或新增出边。
            auto &children = nodes_[node_index].children;
            const auto edge = lowerBoundEdge(children, code_point);
            if (edge != children.end() && edge->first == code_point)
            {
                node_index = edge->second;
                continue;
            }

            if (nodes_.size() >= kMaxNodes)
            {
                return BuildError::kDictionaryLimit;
            }

            // 先插入出边，再追加节点；追加可能使 nodes_ 中的引用失效。
            const auto next_node_index = static_cast<std::int32_t>(nodes_.size());
            children.emplace(edge, code_point, next_node_index);
            nodes_.emplace_back();
            node_index = next_node_index;
        }
        nodes_[node_index].output_keyword_indices.push_back(keyword_index);
        return BuildError::kNone;
    }

    BuildError Filter::build()
    {
        // 已构建的词库不能再次继承后缀输出。
        if (built_)
        {
            return BuildError::kNone;
        }

        // 总输出从词条自身的命中开始计数，之后累加复制的后缀命中。
        std::size_t output_count = keywords_.size();
        // 根的子节点默认回退到根；先入队，之后按 BFS 顺序补全更深节点。
        std::queue<std::int32_t> pending_nodes;
        for (std::size_t index = 0; index < nodes_[0].children.size(); ++index)
        {
            pending_nodes.push(nodes_[0].children[index].second);
        }

        // BFS 保证父节点和较短后缀已经构建；“she”的尾节点继承“he”的命中。
        while (!pending_nodes.empty())
        {
            std::int32_t node_index = pending_nodes.front();
            pending_nodes.pop();

            for (std::size_t index = 0; index < nodes_[node_index].children.size(); ++index)
            {
                std::uint32_t code_point          = nodes_[node_index].children[index].first;
                std::int32_t  child_node_index    = nodes_[node_index].children[index].second;
                // 从父节点的后缀开始查找子节点的最长可用后缀。
                nodes_[child_node_index].fail_node_index =
                    followEdge(nodes_[node_index].fail_node_index, code_point);

                const std::vector<std::int32_t> &suffix_keyword_indices =
                    nodes_[nodes_[child_node_index].fail_node_index].output_keyword_indices;
                if (suffix_keyword_indices.size() > kMaxOutputs - output_count)
                {
                    return BuildError::kDictionaryLimit;
                }
                // 本节点词条最长，后缀节点的输出已经有序；追加后仍按码点数递减。
                output_count += suffix_keyword_indices.size();
                nodes_[child_node_index].output_keyword_indices.insert(nodes_[child_node_index].output_keyword_indices.end(),
                                                        suffix_keyword_indices.begin(), suffix_keyword_indices.end());
                pending_nodes.push(child_node_index);
            }
        }

        // 全部节点成功处理后才允许只读查询。
        built_ = true;
        return BuildError::kNone;
    }

    QueryResult Filter::query(std::string_view source_text, bool compact, std::vector<Match> *matches) const
    {
        if (matches)
        {
            matches->clear();
        }
        if (!built_)
        {
            return {QueryError::kNotBuilt, 0};
        }
        if (source_text.size() > kMaxTextBytes)
        {
            return {QueryError::kTextLimit, 0};
        }

        // 先校验完整 UTF-8，保证文本尾部的编码错误优先于命中数量超限。
        std::vector<SourcePoint> points; // 保存匹配码点和其原文 byte 区间。
        if (!normalizeUtf8(source_text, points, compact))
        {
            return {QueryError::kInvalidUtf8, 0};
        }

        std::size_t match_count = 0; // 只统计通过 compact 原文跨度校验的命中。
        std::int32_t node_index = 0;
        for (std::size_t index = 0; index < points.size(); ++index)
        {
            // 不回退输入位置；当前码点沿 fail 链找可用出边。
            node_index = followEdge(node_index, points[index].code_point);

            // 同一结束位置下，词条越长，原文起点越靠前。超跨度候选构成有序前缀。
            const auto &output_keyword_indices = nodes_[node_index].output_keyword_indices;
            const auto source_byte_end = points[index].source_byte_end;
            const auto source_byte_begin_for = [&](std::int32_t keyword_index)
            {
                return points[index + 1 - keywords_[keyword_index].code_point_count].source_byte_begin;
            };

            auto first_valid_output = output_keyword_indices.begin();
            if (compact && first_valid_output != output_keyword_indices.end())
            {
                const auto exceeds_span = [&](std::int32_t keyword_index)
                {
                    return source_byte_end - source_byte_begin_for(keyword_index) > kMaxCompactSpan;
                };
                if (exceeds_span(output_keyword_indices.back()))
                {
                    continue; // 最短词条也超跨度，整组候选都无效。
                }
                if (exceeds_span(*first_valid_output))
                {
                    first_valid_output = std::partition_point(first_valid_output, output_keyword_indices.end(), exceeds_span);
                }
            }

            // 有效后缀数量可直接取得；重复词仍分别占用额度。
            const auto valid_output_count =
                static_cast<std::size_t>(output_keyword_indices.end() - first_valid_output);
            if (valid_output_count > kMaxMatches - match_count)
            {
                if (matches)
                {
                    matches->clear();
                }
                return {QueryError::kMatchLimit, 0};
            }
            match_count += valid_output_count;
            if (!matches)
            {
                continue;
            }

            // find 才需要逐项还原区间并写入缓冲。
            for (auto match_it = first_valid_output; match_it != output_keyword_indices.end(); ++match_it)
            {
                const auto source_byte_begin = source_byte_begin_for(*match_it);
                matches->push_back({keywords_[*match_it].keyword_id, source_byte_begin,
                                    source_byte_end - source_byte_begin});
            }
        }
        return {QueryError::kNone, match_count};
    }

    // 校验原文并保存参与匹配的码点，compact 只跳过已经验证合法的分隔字符。
    bool Filter::normalizeUtf8(std::string_view source_text, std::vector<SourcePoint> &points,
                                       bool compact)
    {
        const std::uint8_t *bytes       = reinterpret_cast<const std::uint8_t *>(source_text.data());
        std::uint32_t       byte_count  = static_cast<std::uint32_t>(source_text.size());
        std::uint32_t       byte_offset = 0;

        // BOM 只在输入开头跳过；后续位置仍记录原文偏移，不从零重新编号。
        if (byte_count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB &&
            bytes[2] == 0xBF)
        {
            byte_offset = 3;
        }

        // 位置映射按码点存储；全角“Ａ”折叠为一个 ASCII byte，来源仍是原文 3 bytes。
        while (byte_offset < byte_count)
        {
            std::uint32_t source_byte_offset   = byte_offset;
            std::uint32_t code_point           = 0;
            if (!decodeUtf8Char(bytes, byte_count, byte_offset, code_point))
            {
                return false;
            }

            code_point = normalizeCodePoint(code_point);
            if (!compact || !isCompactIgnored(code_point))
            {
                points.push_back({code_point, source_byte_offset, byte_offset});
            }
        }

        return true;
    }

    bool Filter::decodeUtf8Char(const std::uint8_t *bytes, std::uint32_t byte_count,
                                         std::uint32_t &byte_offset, std::uint32_t &code_point)
    {
        if (byte_offset >= byte_count)
        {
            return false;
        }

        std::uint8_t leading_byte = bytes[byte_offset];
        if (leading_byte < 0x80)
        {
            code_point           = leading_byte;
            ++byte_offset;
            return true;
        }

        std::uint32_t required_bytes     = 0;
        std::uint32_t decoded_code_point = 0;
        std::uint32_t minimum_code_point = 0; // 当前 UTF-8 序列长度允许的最小码点，用于拒绝过长编码。
        if ((leading_byte & 0xE0) == 0xC0)
        {
            required_bytes     = 2;
            decoded_code_point = leading_byte & 0x1F;
            minimum_code_point = 0x80;
        }
        else if ((leading_byte & 0xF0) == 0xE0)
        {
            required_bytes     = 3;
            decoded_code_point = leading_byte & 0x0F;
            minimum_code_point = 0x800;
        }
        else if ((leading_byte & 0xF8) == 0xF0)
        {
            required_bytes     = 4;
            decoded_code_point = leading_byte & 0x07;
            minimum_code_point = 0x10000;
        }
        else
        {
            return false;
        }

        if (byte_offset + required_bytes > byte_count)
        {
            return false;
        }

        for (std::uint32_t index = 1; index < required_bytes; ++index)
        {
            std::uint8_t continuation_byte = bytes[byte_offset + index];
            if ((continuation_byte & 0xC0) != 0x80)
            {
                return false;
            }
            decoded_code_point = (decoded_code_point << 6) | (continuation_byte & 0x3F);
        }

        // minimum_code_point 排除过长编码；同时拒绝代理项及大于 U+10FFFF 的值。
        if (decoded_code_point < minimum_code_point || decoded_code_point > 0x10FFFF ||
            (decoded_code_point >= 0xD800 && decoded_code_point <= 0xDFFF))
        {
            return false;
        }

        code_point           = decoded_code_point;
        byte_offset += required_bytes;
        return true;
    }

    // 将全角 ASCII 和大写 ASCII 折叠为词库与查询共用的码点。
    std::uint32_t Filter::normalizeCodePoint(std::uint32_t code_point)
    {
        if (code_point == 0x3000)
        {
            code_point = ' ';
        }
        else if (code_point >= 0xFF01 && code_point <= 0xFF5E)
        {
            code_point -= 0xFEE0;
        }

        if (code_point >= 'A' && code_point <= 'Z')
        {
            code_point += 'a' - 'A';
        }

        return code_point;
    }

    bool Filter::isCompactIgnored(std::uint32_t code_point)
    {
        // compact 保留字母、数字和中日韩文字，只忽略下面列出的分隔字符。
        // 这些固定 Unicode 范围沿用 FCLib，不表示完整 Unicode 标点或空白分类。
        // ASCII 控制字符和空格是相邻范围，DEL 单独位于 0x7F。
        if (code_point <= 0x20 || code_point == 0x7F)
        {
            return true;
        }

        if (((code_point >= 0x21 && code_point <= 0x2F) || (code_point >= 0x3A && code_point <= 0x40) ||
             (code_point >= 0x5B && code_point <= 0x60) || (code_point >= 0x7B && code_point <= 0x7E)))
        {
            return true;
        }

        if (((code_point >= 0x200B && code_point <= 0x200F) || code_point == 0x2028 || code_point == 0x2029 ||
             code_point == 0x2060 || code_point == 0xFEFF))
        {
            return true;
        }
        return false;
    }

    // 有序出边按码点定位；不存在时返回应插入的位置。
    Filter::Edges::const_iterator Filter::lowerBoundEdge(const Edges &children, std::uint32_t code_point)
    {
        return std::lower_bound(children.begin(), children.end(), code_point,
                                [](const auto &edge, std::uint32_t target)
                                {
                                    return edge.first < target;
                                });
    }

    // 从指定节点尝试接上当前码点，必要时沿 fail 链回退，根也无边时返回根。
    std::int32_t Filter::followEdge(std::int32_t node_index, std::uint32_t code_point) const
    {
        while (true)
        {
            const Node &node = nodes_[node_index]; // 当前可用前缀，缺边时改查其后缀。
            const auto edge = lowerBoundEdge(node.children, code_point);
            if (edge != node.children.end() && edge->first == code_point)
            {
                return edge->second;
            }
            if (node_index == 0)
            {
                return 0;
            }
            node_index = node.fail_node_index;
        }
    }
} // namespace flywow_word_filter
