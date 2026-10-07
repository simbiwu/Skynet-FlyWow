// 职责：word_filter 的 Lua 5.4 Binding；通过通用 LuaBinding
// 适配词库和查询结果。 边界：不直接维护 Lua 栈、不 yield、不进行文件
// I/O；词库文件由 Lua Wrapper 读取。 生命周期：LuaFilter 由 full userdata
// 独占，GC 负责析构；查询结果复制到 Lua table。
#include "lua_binding.h"
#include "lua_table.h"
#include "word_filter.h"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;
using flywow_word_filter::flywow_filter;
using flywow_word_filter::flywow_match;

const std::string kFilterMeta = "flywow_word_filter";

struct LuaFilter {
  flywow_filter filter;
  std::vector<flywow_match> query_matches;
  bool compact_enabled = false;
};

void setFilterError(LuaBinding &lua_binding, const char *code) {
  lua_binding.setError(code, code);
}

bool readFilter(LuaBinding &lua_binding, LuaFilter *&output) {
  return lua_binding.readUserdata(1, kFilterMeta, output);
}

int createFilter(lua_State *state)
{
  LuaBinding lua_binding(state);
  LuaTable keywords;
  if (!lua_binding.readTable(1, keywords)) {
    return lua_binding.pushError();
  }

  bool compact_enabled = false;
  if (!lua_binding.readValue(2, compact_enabled)) {
    return lua_binding.pushError();
  }

  std::size_t keyword_count = 0;
  if (!keywords.denseArrayLength(keyword_count)) {
    return lua_binding.pushError();
  }

  if (keyword_count > flywow_word_filter::flywow_max_keywords) {
    setFilterError(lua_binding, "dictionary_limit");
    return lua_binding.pushError();
  }

  LuaFilter *filter = nullptr;
  if (!lua_binding.newUserdata(kFilterMeta, filter)) {
    return lua_binding.pushError();
  }
  filter->compact_enabled = compact_enabled;

  for (std::size_t index = 1; index <= keyword_count; ++index) {
    std::string keyword;
    if (!keywords.readValue(index, keyword)) {
      return lua_binding.pushError();
    }
    if (keyword.size() > flywow_word_filter::flywow_max_keyword_bytes) {
      setFilterError(lua_binding, "dictionary_limit");
      return lua_binding.pushError();
    }
    try {
      if (!filter->filter.add_keyword(keyword,
                                      static_cast<std::int32_t>(index))) {
        setFilterError(lua_binding, "invalid_keyword");
        return lua_binding.pushError();
      }
    } catch (const std::runtime_error &error) {
      setFilterError(lua_binding, error.what());
      return lua_binding.pushError();
    }
  }

  try {
    filter->filter.build();
  } catch (const std::runtime_error &error) {
    setFilterError(lua_binding, error.what());
    return lua_binding.pushError();
  }

  return lua_binding.returnValues(filter);
}

int findMatches(lua_State *state)
{
  LuaBinding lua_binding(state);
  LuaFilter *filter = nullptr;
  if (!readFilter(lua_binding, filter)) {
    return lua_binding.pushError();
  }
  std::string text;
  if (!lua_binding.readValue(2, text)) {
    return lua_binding.pushError();
  }
  if (text.size() > flywow_word_filter::flywow_max_text_bytes) {
    setFilterError(lua_binding, "text_limit");
    return lua_binding.pushError();
  }

  bool found = false;
  try {
    if (filter->compact_enabled) {
      flywow_word_filter::flywow_compact_options options;
      options.max_source_span_bytes =
          flywow_word_filter::flywow_max_compact_span;
      found = filter->filter.find_compact(
          text, filter->query_matches,
          flywow_word_filter::flywow_normalize_options(), options);
    } else {
      found =
          filter->filter.find(text, filter->query_matches,
                              flywow_word_filter::flywow_normalize_options());
    }
  } catch (const std::runtime_error &error) {
    filter->query_matches.clear();
    setFilterError(lua_binding, error.what());
    return lua_binding.pushError();
  }

  if (!found) {
    filter->query_matches.clear();
    setFilterError(lua_binding, "invalid_utf8");
    return lua_binding.pushError();
  }

  LuaTable matches = lua_binding.newTable();
  for (std::size_t index = 0; index < filter->query_matches.size(); ++index) {
    const flywow_match &match = filter->query_matches[index];
    LuaTable item = lua_binding.newTable();
    if (!item.writeValue("keyword_id", match.keyword_id) ||
        !item.writeValue("offset", match.source_byte_offset + 1) ||
        !item.writeValue("length", match.source_byte_length) ||
        !matches.writeValue(index + 1, item)) {
      filter->query_matches.clear();
      return lua_binding.pushError();
    }
  }
  filter->query_matches.clear();
  return lua_binding.returnValues(matches);
}

} // namespace

extern "C" int luaopen_flywow_word_filter_native(lua_State *state)
{
  LuaBinding lua_binding(state);
  LuaTable metatable;
  if (!lua_binding.registerUserdata<LuaFilter>(kFilterMeta, metatable)) {
    return lua_binding.pushError();
  }

  LuaTable methods = lua_binding.newTable();
  if (!methods.setFunction("find", findMatches) ||
      !metatable.writeValue("__index", methods)) {
    return lua_binding.pushError();
  }

  LuaTable module = lua_binding.newTable();
  if (!module.setFunction("new", createFilter) ||
      !module.setFunction("find", findMatches)) {
    return lua_binding.pushError();
  }
  return lua_binding.returnValues(module);
}
