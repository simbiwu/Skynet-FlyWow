// 职责：word_filter 的 Lua 5.4 Binding；通过通用 LuaBinding
// 读写参数和结果由 LuaBinding 负责。只在检查词库原始键时直接遍历 Lua 栈。
// 回调无 yield 和文件 I/O；LuaFilter 由 full userdata 独占并由 GC 析构。
#include "lua_binding.h"
#include "lua_table.h"
#include "word_filter.h"

#include <cstddef>
#include <cstdint>
#include <string_view>
#include <string>
#include <vector>

namespace
{
using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;
using flywow_word_filter::BuildError;
using flywow_word_filter::Filter;
using flywow_word_filter::Match;
using flywow_word_filter::QueryError;
using flywow_word_filter::QueryResult;

const std::string kFilterMeta = "flywow_word_filter";
const std::string kMatchBufferMeta = "flywow_word_filter_match_buffer";
using MatchBuffer = std::vector<Match>;

struct LuaFilter
{
    Filter filter;                    // 构建完成后只读，由 userdata 析构。
    bool compact_enabled = false;    // 创建时设置，查询时决定是否跳过分隔码点。
};

void setFilterError(LuaBinding &lua_binding, const char *code)
{
    lua_binding.setError(code, code);
}

bool readFilter(LuaBinding &lua_binding, LuaFilter *&output)
{
    return lua_binding.readUserdata(1, kFilterMeta, output);
}

// 从 Lua 数组构建候选 userdata。失败只返回诊断，未发布对象由 Lua GC 回收。
int create_filter(lua_State *state)
{
    LuaBinding lua_binding(state);
    if (lua_type(state, 1) != LUA_TTABLE)
    {
        setFilterError(lua_binding, "invalid_keyword");
        return lua_binding.pushError();
    }

    bool compact_enabled = false;
    if (!lua_binding.readValue(2, compact_enabled))
    {
        return lua_binding.pushError();
    }

    // 先保留稠密数组超过词数上限时的诊断优先级。稀疏数组的 rawlen 不是实际词数。
    if (lua_rawlen(state, 1) > flywow_word_filter::kMaxKeywords)
    {
        setFilterError(lua_binding, "dictionary_limit");
        return lua_binding.pushError();
    }

    // 从第 1 个参数槽遍历原始键。正整数键唯一，最大下标等于键数才表示没有空洞。
    std::size_t keyword_count = 0;
    lua_Integer max_keyword_index = 0;
    lua_pushnil(state); // 参数栈后追加首轮遍历的 nil key。
    while (lua_next(state, 1) != 0)
    {
        // 栈顶依次为 key、value；每轮弹出 value，让 lua_next 继续消费 key。
        if (!lua_isinteger(state, -2) || lua_tointeger(state, -2) < 1)
        {
            lua_pop(state, 2); // 提前返回时恢复原参数栈。
            setFilterError(lua_binding, "invalid_keyword");
            return lua_binding.pushError();
        }
        const lua_Integer keyword_index = lua_tointeger(state, -2);
        if (keyword_index > max_keyword_index)
        {
            max_keyword_index = keyword_index;
        }
        ++keyword_count;
        lua_pop(state, 1);
    }

    // 正常结束时 lua_next 已弹出最后一个 key，原参数仍位于原槽。
    if (static_cast<std::uintmax_t>(max_keyword_index) != keyword_count)
    {
        setFilterError(lua_binding, "invalid_keyword");
        return lua_binding.pushError();
    }
    if (keyword_count > flywow_word_filter::kMaxKeywords)
    {
        setFilterError(lua_binding, "dictionary_limit");
        return lua_binding.pushError();
    }

    // 创建后由 userdata 持有候选词库，只有构建成功才交给 Lua Wrapper。
    LuaFilter *lua_filter = nullptr;
    if (!lua_binding.newUserdata(kFilterMeta, lua_filter))
    {
        return lua_binding.pushError();
    }
    lua_filter->compact_enabled = compact_enabled;

    // 下标是公开词条 ID；每轮读取的字符串在退出循环体时销毁。
    BuildError build_error = BuildError::kNone;
    for (std::size_t index = 1; index <= keyword_count; ++index)
    {
        // rawgeti 在原参数之后压入词条，不触发元方法；借用字节期间保留栈顶引用。
        lua_rawgeti(state, 1, static_cast<lua_Integer>(index));
        if (lua_type(state, -1) == LUA_TSTRING)
        {
            std::size_t keyword_size = 0; // Lua 原始字符串长度，包含内嵌 NUL。
            const char *keyword_bytes = lua_tolstring(state, -1, &keyword_size);
            build_error = lua_filter->filter.addKeyword({keyword_bytes, keyword_size},
                                                        static_cast<std::int32_t>(index));
        }
        else
        {
            build_error = BuildError::kInvalidKeyword;
        }
        lua_pop(state, 1); // 核心不保留字符串视图，恢复原参数栈。
        if (build_error != BuildError::kNone)
        {
            break;
        }
    }

    // 仅在词条全部加入后构建后缀输出。失败的 userdata 不发布，由 GC 回收。
    if (build_error == BuildError::kNone)
    {
        build_error = lua_filter->filter.build();
    }

    if (build_error != BuildError::kNone)
    {
        const char *error_code = "internal_error";
        if (build_error == BuildError::kInvalidKeyword)
        {
            error_code = "invalid_keyword";
        }
        else if (build_error == BuildError::kDictionaryLimit)
        {
            error_code = "dictionary_limit";
        }
        setFilterError(lua_binding, error_code);
        return lua_binding.pushError();
    }

    return lua_binding.returnValues(lua_filter);
}

// find 传 collect_matches=true 导出原文区间；contains 传 false，只返回是否命中。
int queryFilter(lua_State *state, bool collect_matches)
{
    LuaBinding lua_binding(state);
    LuaFilter *lua_filter = nullptr; // 当前 Lua State 持有的只读词库。
    if (!readFilter(lua_binding, lua_filter))
    {
        return lua_binding.pushError();
    }

    if (lua_type(state, 2) != LUA_TSTRING)
    {
        setFilterError(lua_binding, "invalid_text");
        return lua_binding.pushError();
    }
    // 参数槽保活原文；确认类型后 tolstring 不转换或复制内容，也不改变栈高度。
    std::size_t text_size = 0;
    const char *text_bytes = lua_tolstring(state, 2, &text_size);
    if (text_size > flywow_word_filter::kMaxTextBytes)
    {
        setFilterError(lua_binding, "text_limit");
        return lua_binding.pushError();
    }

    // 每次 find 使用自己的 Lua 托管缓冲。建表触发 __gc 重入时，内外两次结果互不覆盖。
    // Binding 保活缓冲直到回调结束；即使 Lua 分配抛错，vector 也不依赖栈上析构。
    MatchBuffer *query_matches = nullptr;
    if (collect_matches && !lua_binding.newUserdata(kMatchBufferMeta, query_matches))
    {
        return lua_binding.pushError();
    }
    const QueryResult query_result =
        lua_filter->filter.query({text_bytes, text_size}, lua_filter->compact_enabled, query_matches);

    // 核心只报告匹配失败原因，公开错误码由 Lua Binding 决定。
    const char *error_code = nullptr;
    switch (query_result.error)
    {
    case QueryError::kNone: break;
    case QueryError::kNotBuilt: error_code = "internal_error"; break;
    case QueryError::kInvalidUtf8: error_code = "invalid_utf8"; break;
    case QueryError::kTextLimit: error_code = "text_limit"; break;
    case QueryError::kMatchLimit: error_code = "match_limit"; break;
    }

    if (error_code)
    {
        setFilterError(lua_binding, error_code);
        return lua_binding.pushError();
    }

    if (!collect_matches)
    {
        return lua_binding.returnValues(query_result.match_count != 0);
    }

    // 每个 Lua record 拥有独立的原文 byte 坐标，结果不借用 Native 内存。
    LuaTable matches; // 返回给 Lua 调用方的命中数组。
    lua_binding.newTable(matches);
    for (std::size_t index = 0; index < query_matches->size(); ++index)
    {
        const Match &match = (*query_matches)[index];
        LuaTable item; // 当前命中的公开字段，转换为 Lua 的 1-based byte 偏移。
        lua_binding.newTable(item);
        if (!item.writeValue("keyword_id", match.keyword_id) ||
            !item.writeValue("offset", match.source_byte_offset + 1) ||
            !item.writeValue("length", match.source_byte_length) ||
            !matches.writeValue(index + 1, item))
        {
            return lua_binding.pushError();
        }
    }
    // 区间已复制到 Lua；立即释放本次 Native 容量，无需等待下一轮 GC。
    MatchBuffer{}.swap(*query_matches);
    return lua_binding.returnValues(matches);
}

// Lua find 返回全部原文区间，由 Wrapper 按公开规则排序。
int find(lua_State *state)
{
    return queryFilter(state, true);
}

// Lua contains 校验完整输入，只返回是否存在有效命中。
int contains(lua_State *state)
{
    return queryFilter(state, false);
}

} // namespace

extern "C" int luaopen_flywow_word_filter_native(lua_State *state)
{
    static const luaL_Reg methods[] = {
        {"find", &LuaBinding::nativeCallback<find>},
        {nullptr, nullptr},
    };
    static const luaL_Reg functions[] = {
        {"create_filter", &LuaBinding::nativeCallback<create_filter>},
        {"find", &LuaBinding::nativeCallback<find>},
        {"contains", &LuaBinding::nativeCallback<contains>},
        {nullptr, nullptr},
    };
    LuaBinding::registerUserdata<LuaFilter>(state, kFilterMeta.c_str(), methods);
    static const luaL_Reg buffer_methods[] = {{nullptr, nullptr}};
    LuaBinding::registerUserdata<MatchBuffer>(state, kMatchBufferMeta.c_str(), buffer_methods);
    luaL_newlib(state, functions);
    return 1;
}
