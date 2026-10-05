// 职责：从 FCLib FCKeywordFilter 移植的 UTF-8 归一化、AC 匹配与原文 byte 映射。
// Runtime 核心不依赖 Skynet 或业务词库；构建后只读，查询临时数据由调用者独占。
#include "word_filter.h"
#include <queue>
#include <stdexcept>

namespace flywow_word_filter
{
    // 非法 byte 的内部标记基址，不属于可输出的 Unicode 标量值。
    constexpr std::uint32_t flywow_invalid_byte_base = 0x110000;

    flywow_normalize_options::flywow_normalize_options()
        : lower_ascii(true), fullwidth_to_ascii(true), drop_utf8_bom(true), keep_invalid_bytes(false)
    {
    }

    flywow_compact_options::flywow_compact_options()
        : ignore_space(true), ignore_control(true), ignore_ascii_punctuation(true), ignore_zero_width(true),
          max_source_span_bytes(0)
    {
    }

    void flywow_normalized_text::clear()
    {
        text.clear();
        source_byte_offsets.clear();
        source_byte_lengths.clear();
        code_points.clear();
    }

    flywow_match::flywow_match()
        : keyword_id(0), normalized_code_point_offset(0), normalized_code_point_length(0), source_byte_offset(0),
          source_byte_length(0)
    {
    }

    flywow_filter::flywow_filter() : built_(false)
    {
        // 索引 0 永远为根节点；即使词库为空也允许查询。
        nodes_.push_back(flywow_node());
    }

    flywow_filter::~flywow_filter()
    {
    }

    void flywow_filter::clear()
    {
        keywords_.clear();
        nodes_.clear();
        nodes_.push_back(flywow_node());
        built_                 = false;
        dictionary_byte_count_ = 0;
    }

    bool flywow_filter::add_keyword(const std::string &keyword, std::int32_t keyword_id,
                                    const flywow_normalize_options &normalization_options)
    {
        if (built_)
        {
            throw std::runtime_error("already_built");
        }
        if (keywords_.size() >= flywow_max_keywords || keyword.size() > flywow_max_keyword_bytes ||
            keyword.size() > flywow_max_dictionary_bytes - dictionary_byte_count_)
        {
            throw std::runtime_error("dictionary_limit");
        }
        flywow_normalized_text normalized;
        if (!normalize_utf8(keyword, normalized, normalization_options))
        {
            return false;
        }

        if (normalized.code_points.empty())
        {
            return false;
        }

        flywow_keyword keyword_info;
        keyword_info.keyword_id     = keyword_id >= 0 ? keyword_id : static_cast<std::int32_t>(keywords_.size());
        keyword_info.source_keyword = keyword;
        keyword_info.code_points    = normalized.code_points;

        std::int32_t keyword_index = static_cast<std::int32_t>(keywords_.size());
        keywords_.push_back(keyword_info);
        dictionary_byte_count_ += keyword.size();

        // trie 的边使用完整码点；例如“外”是一个节点，而不是三个 UTF-8 字节节点。
        std::int32_t node_index = 0;
        for (std::size_t index = 0; index < normalized.code_points.size(); ++index)
        {
            std::int32_t next_node_index = find_child_node(nodes_[node_index], normalized.code_points[index]);
            if (next_node_index < 0)
            {
                next_node_index = static_cast<std::int32_t>(nodes_.size());
                if (nodes_.size() >= flywow_max_nodes)
                {
                    throw std::runtime_error("dictionary_limit");
                }
                nodes_.push_back(flywow_node());
                set_child_node(nodes_[node_index], normalized.code_points[index], next_node_index);
            }
            node_index = next_node_index;
        }
        nodes_[node_index].outputs.push_back(keyword_index);
        built_ = false;
        return true;
    }

    bool flywow_filter::build()
    {
        // 阶段一：确认是否已构建，并准备根节点。
        if (built_)
        {
            return true;
        }
        if (nodes_.empty())
        {
            nodes_.push_back(flywow_node());
        }

        // 阶段二：初始化根节点的直接子节点。
        // 后缀输出会复制到节点；限制总项数，避免密集后缀词库在 build 时耗尽内存。
        std::size_t              output_count = keywords_.size();
        std::queue<std::int32_t> pending_nodes;
        for (std::size_t index = 0; index < nodes_[0].children.size(); ++index)
        {
            std::int32_t child_node_index            = nodes_[0].children[index].second;
            nodes_[child_node_index].fail_node_index = 0;
            pending_nodes.push(child_node_index);
        }

        // 阶段三：BFS 保证父节点和较短后缀已经构建；“she”的尾节点继承“he”的命中。
        // built_ 为 true 后直接返回，避免重复继承后缀输出。
        while (!pending_nodes.empty())
        {
            std::int32_t node_index = pending_nodes.front();
            pending_nodes.pop();

            for (std::size_t index = 0; index < nodes_[node_index].children.size(); ++index)
            {
                std::uint32_t code_point          = nodes_[node_index].children[index].first;
                std::int32_t  child_node_index    = nodes_[node_index].children[index].second;
                std::int32_t  fallback_node_index = nodes_[node_index].fail_node_index;

                while (fallback_node_index != 0 && find_child_node(nodes_[fallback_node_index], code_point) < 0)
                {
                    fallback_node_index = nodes_[fallback_node_index].fail_node_index;
                }

                std::int32_t fallback_child_index        = find_child_node(nodes_[fallback_node_index], code_point);
                nodes_[child_node_index].fail_node_index = fallback_child_index >= 0 ? fallback_child_index : 0;

                const std::vector<std::int32_t> &fallback_outputs =
                    nodes_[nodes_[child_node_index].fail_node_index].outputs;
                if (fallback_outputs.size() > flywow_max_outputs - output_count)
                {
                    throw std::runtime_error("dictionary_limit");
                }
                output_count += fallback_outputs.size();
                nodes_[child_node_index].outputs.insert(nodes_[child_node_index].outputs.end(),
                                                        fallback_outputs.begin(), fallback_outputs.end());
                pending_nodes.push(child_node_index);
            }
        }

        // 阶段四：全部节点成功处理后才发布只读状态。
        built_ = true;
        return true;
    }

    bool flywow_filter::find(const std::string &source_text, std::vector<flywow_match> &results,
                             const flywow_normalize_options &normalization_options) const
    {
        flywow_normalized_text normalized;
        bool                   normalized_ok = normalize_utf8(source_text, normalized, normalization_options);
        if (!normalized_ok)
        {
            results.clear();
            return false;
        }
        if (!find_normalized(normalized, results))
        {
            return false;
        }
        return normalized_ok;
    }

    bool flywow_filter::find_normalized(const flywow_normalized_text &normalized,
                                        std::vector<flywow_match>    &results) const
    {
        results.clear();
        if (!built_)
        {
            return false;
        }

        const std::vector<std::uint32_t> &code_points = normalized.code_points;
        if (code_points.size() != normalized.source_byte_offsets.size() ||
            code_points.size() != normalized.source_byte_lengths.size())
        {
            return false;
        }

        std::int32_t node_index = 0;
        for (std::size_t index = 0; index < code_points.size(); ++index)
        {
            // 不回退输入位置，只沿 fail 链寻找仍能接上当前码点的最长后缀。
            // 出边为有序 vector，查找使用二分；扫描成本另加每次出边查找和命中输出。
            while (node_index != 0 && find_child_node(nodes_[node_index], code_points[index]) < 0)
            {
                node_index = nodes_[node_index].fail_node_index;
            }

            std::int32_t next_node_index = find_child_node(nodes_[node_index], code_points[index]);
            node_index                   = next_node_index >= 0 ? next_node_index : 0;

            const std::vector<std::int32_t> &outputs = nodes_[node_index].outputs;
            for (std::size_t output_index = 0; output_index < outputs.size(); ++output_index)
            {
                const flywow_keyword &keyword                  = keywords_[outputs[output_index]];
                std::uint32_t         keyword_code_point_count = static_cast<std::uint32_t>(keyword.code_points.size());
                if (keyword_code_point_count == 0 || index + 1 < keyword_code_point_count)
                {
                    continue;
                }

                // 先取得命中的码点区间，再取首字符起点和末字符末尾，恢复原文字节区间。
                // “外-挂”压缩成两个码点，但原文区间仍覆盖 3+1+3=7 bytes。
                std::uint32_t normalized_begin_index = static_cast<std::uint32_t>(index + 1 - keyword_code_point_count);
                std::uint32_t normalized_end_index   = static_cast<std::uint32_t>(index);
                std::uint32_t source_begin_byte      = normalized.source_byte_offsets[normalized_begin_index];
                std::uint32_t source_end_byte        = normalized.source_byte_offsets[normalized_end_index] +
                                                normalized.source_byte_lengths[normalized_end_index];

                flywow_match result;
                result.keyword_id                   = keyword.keyword_id;
                result.source_keyword               = keyword.source_keyword;
                result.normalized_code_point_offset = normalized_begin_index;
                result.normalized_code_point_length = keyword_code_point_count;
                result.source_byte_offset           = source_begin_byte;
                result.source_byte_length =
                    source_end_byte >= source_begin_byte ? source_end_byte - source_begin_byte : 0;
                if (results.size() >= flywow_max_matches)
                {
                    throw std::runtime_error("match_limit");
                }
                results.push_back(result);
            }
        }
        return true;
    }

    bool flywow_filter::find_compact(const std::string &source_text, std::vector<flywow_match> &results,
                                     const flywow_normalize_options &normalization_options,
                                     const flywow_compact_options   &compact_options) const
    {
        flywow_normalized_text normalized;
        bool                   normalized_ok = normalize_utf8(source_text, normalized, normalization_options);
        if (!normalized_ok)
        {
            results.clear();
            return false;
        }
        if (!find_compact_normalized(normalized, results, compact_options))
        {
            return false;
        }
        return normalized_ok;
    }

    bool flywow_filter::find_compact_normalized(const flywow_normalized_text &normalized,
                                                std::vector<flywow_match>    &results,
                                                const flywow_compact_options &compact_options) const
    {
        flywow_normalized_text compacted;
        if (!compact_normalized_text(normalized, compacted, compact_options))
        {
            results.clear();
            return false;
        }
        if (!find_normalized(compacted, results))
        {
            return false;
        }
        // span 衡量原文 bytes，包含被删除的分隔符；它不是 compact 后码点数。
        if (compact_options.max_source_span_bytes > 0)
        {
            std::vector<flywow_match> filtered;
            for (std::size_t index = 0; index < results.size(); ++index)
            {
                if (results[index].source_byte_length <= compact_options.max_source_span_bytes)
                {
                    filtered.push_back(results[index]);
                }
            }
            results.swap(filtered);
        }
        return true;
    }

    bool flywow_filter::normalize_utf8(const std::string &source_text, flywow_normalized_text &result,
                                       const flywow_normalize_options &normalization_options)
    {
        if (source_text.size() > flywow_max_text_bytes)
        {
            throw std::runtime_error("text_limit");
        }
        result.clear();

        const std::uint8_t *bytes       = reinterpret_cast<const std::uint8_t *>(source_text.data());
        std::uint32_t       byte_count  = static_cast<std::uint32_t>(source_text.size());
        std::uint32_t       byte_offset = 0;
        bool                valid_utf8  = true;

        // BOM 只在输入开头跳过；后续位置仍记录原文偏移，不从零重新编号。
        if (normalization_options.drop_utf8_bom && byte_count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB &&
            bytes[2] == 0xBF)
        {
            byte_offset = 3;
        }

        // 位置映射按码点存储；全角“Ａ”折叠为一个 ASCII byte，来源仍是原文 3 bytes。
        while (byte_offset < byte_count)
        {
            std::uint32_t source_byte_offset   = byte_offset;
            std::uint32_t code_point           = 0;
            std::uint32_t character_byte_count = 0;
            if (!decode_utf8_char(bytes, byte_count, byte_offset, code_point, character_byte_count))
            {
                valid_utf8 = false;
                if (normalization_options.keep_invalid_bytes)
                {
                    result.text.push_back(static_cast<char>(bytes[source_byte_offset]));
                    result.source_byte_offsets.push_back(source_byte_offset);
                    result.source_byte_lengths.push_back(1);
                    // 此保留模式仅供核心使用；Lua 入口固定拒绝非法 UTF-8。
                    // 0x110000 超出 Unicode 标量范围，避免非法 byte 与真实字符相等。
                    result.code_points.push_back(flywow_invalid_byte_base + bytes[source_byte_offset]);
                }
                byte_offset = source_byte_offset + 1;
                continue;
            }

            code_point = normalize_code_point(code_point, normalization_options);
            append_utf8_char(code_point, result.text);
            result.source_byte_offsets.push_back(source_byte_offset);
            result.source_byte_lengths.push_back(character_byte_count);
            result.code_points.push_back(code_point);
        }

        return valid_utf8 || normalization_options.keep_invalid_bytes;
    }

    bool flywow_filter::compact_normalized_text(const flywow_normalized_text &normalized,
                                                flywow_normalized_text       &result,
                                                const flywow_compact_options &compact_options)
    {
        result.clear();
        if (normalized.code_points.size() != normalized.source_byte_offsets.size() ||
            normalized.code_points.size() != normalized.source_byte_lengths.size())
        {
            return false;
        }

        for (std::size_t index = 0; index < normalized.code_points.size(); ++index)
        {
            std::uint32_t code_point = normalized.code_points[index];
            if (is_compact_ignored(code_point, compact_options))
            {
                continue;
            }

            append_normalized_code_point(code_point, result.text);
            result.source_byte_offsets.push_back(normalized.source_byte_offsets[index]);
            result.source_byte_lengths.push_back(normalized.source_byte_lengths[index]);
            result.code_points.push_back(code_point);
        }
        return true;
    }

    bool flywow_filter::decode_utf8_char(const std::uint8_t *bytes, std::uint32_t byte_count,
                                         std::uint32_t &byte_offset, std::uint32_t &code_point,
                                         std::uint32_t &character_byte_count)
    {
        if (byte_offset >= byte_count)
        {
            return false;
        }

        std::uint8_t leading_byte = bytes[byte_offset];
        if (leading_byte < 0x80)
        {
            code_point           = leading_byte;
            character_byte_count = 1;
            ++byte_offset;
            return true;
        }

        std::uint32_t required_bytes     = 0;
        std::uint32_t decoded_code_point = 0;
        std::uint32_t minimum_code_point = 0;
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
        character_byte_count = required_bytes;
        byte_offset += required_bytes;
        return true;
    }

    void flywow_filter::append_utf8_char(std::uint32_t code_point, std::string &text)
    {
        if (code_point < 0x80)
        {
            text.push_back(static_cast<char>(code_point));
        }
        else if (code_point < 0x800)
        {
            text.push_back(static_cast<char>(0xC0 | (code_point >> 6)));
            text.push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
        }
        else if (code_point < 0x10000)
        {
            text.push_back(static_cast<char>(0xE0 | (code_point >> 12)));
            text.push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3F)));
            text.push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
        }
        else
        {
            text.push_back(static_cast<char>(0xF0 | (code_point >> 18)));
            text.push_back(static_cast<char>(0x80 | ((code_point >> 12) & 0x3F)));
            text.push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3F)));
            text.push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
        }
    }

    std::uint32_t flywow_filter::normalize_code_point(std::uint32_t                   code_point,
                                                      const flywow_normalize_options &normalization_options)
    {
        if (normalization_options.fullwidth_to_ascii)
        {
            if (code_point == 0x3000)
            {
                code_point = ' ';
            }
            else if (code_point >= 0xFF01 && code_point <= 0xFF5E)
            {
                // 全角 U+FF01..U+FF5E 与 ASCII 相差 0xFEE0；例如 U+FF21“Ａ” -> U+0041“A”。
                code_point -= 0xFEE0;
            }
        }

        if (normalization_options.lower_ascii && code_point >= 'A' && code_point <= 'Z')
        {
            code_point += 'a' - 'A';
        }
        return code_point;
    }

    bool flywow_filter::is_compact_ignored(std::uint32_t code_point, const flywow_compact_options &compact_options)
    {
        // compact 保留字母、数字和中日韩文字，只忽略下面列出的分隔字符。
        // 这些固定 Unicode 范围沿用 FCLib，不表示完整 Unicode 标点或空白分类。
        if (compact_options.ignore_space &&
            (code_point == ' ' || code_point == '\t' || code_point == '\r' || code_point == '\n'))
        {
            return true;
        }
        if (compact_options.ignore_control &&
            ((code_point < 0x20 && code_point != '\t' && code_point != '\r' && code_point != '\n') ||
             code_point == 0x7F))
        {
            return true;
        }
        if (compact_options.ignore_ascii_punctuation &&
            ((code_point >= 0x21 && code_point <= 0x2F) || (code_point >= 0x3A && code_point <= 0x40) ||
             (code_point >= 0x5B && code_point <= 0x60) || (code_point >= 0x7B && code_point <= 0x7E)))
        {
            return true;
        }
        if (compact_options.ignore_zero_width &&
            ((code_point >= 0x200B && code_point <= 0x200F) || code_point == 0x2028 || code_point == 0x2029 ||
             code_point == 0x2060 || code_point == 0xFEFF))
        {
            return true;
        }
        return false;
    }

    void flywow_filter::append_normalized_code_point(std::uint32_t code_point, std::string &text)
    {
        if (code_point >= flywow_invalid_byte_base && code_point <= flywow_invalid_byte_base + 0xFF)
        {
            text.push_back(static_cast<char>(code_point - flywow_invalid_byte_base));
            return;
        }
        append_utf8_char(code_point, text);
    }

    std::int32_t flywow_filter::find_child_edge(const flywow_node &node, std::uint32_t code_point)
    {
        // 搜索区间为 [left,right)，返回边在 children 中的位置，不是目标节点编号。
        std::size_t left  = 0;
        std::size_t right = node.children.size();
        while (left < right)
        {
            std::size_t middle = left + (right - left) / 2;
            if (node.children[middle].first == code_point)
            {
                return static_cast<std::int32_t>(middle);
            }
            if (node.children[middle].first < code_point)
            {
                left = middle + 1;
            }
            else
            {
                right = middle;
            }
        }
        return -1;
    }

    std::int32_t flywow_filter::find_child_node(const flywow_node &node, std::uint32_t code_point)
    {
        std::int32_t edge_index = find_child_edge(node, code_point);
        return edge_index >= 0 ? node.children[edge_index].second : -1;
    }

    void flywow_filter::set_child_node(flywow_node &node, std::uint32_t code_point, std::int32_t next_node_index)
    {
        std::int32_t edge_index = find_child_edge(node, code_point);
        if (edge_index >= 0)
        {
            node.children[edge_index].second = next_node_index;
        }
        else
        {
            std::vector<std::pair<std::uint32_t, std::int32_t>>::iterator edge = node.children.begin();
            while (edge != node.children.end() && edge->first < code_point)
            {
                ++edge;
            }
            node.children.insert(edge, std::make_pair(code_point, next_node_index));
        }
    }
} // namespace flywow_word_filter
