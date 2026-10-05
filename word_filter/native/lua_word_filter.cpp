// 职责：word_filter 的 Lua 5.4 Binding；词库与查询结果由 userdata 独占。
// 不进行 I/O、yield 或共享全局可变状态；C++ 异常转换为 nil,error。
#include "word_filter.h"
extern "C"
{
#include <lauxlib.h>
#include <lua.h>
}
#include <cstring>
#include <new>
#include <stdexcept>

namespace
{
    using namespace flywow_word_filter;
    const char *const flywow_filter_metatable = "flywow_word_filter";

    // 查询存储放在 userdata owner 内，Lua 分配 longjmp 时不会遗失栈上 C++ 容器。
    struct flywow_lua_filter
    {
        flywow_filter             filter;                  // 创建时构建，之后只读。
        std::vector<flywow_match> query_matches;           // 当前对象独占的临时结果，导出后 clear。
        bool                      compact_enabled = false; // 创建时确定，后续不变。
    };

    // userdata 内只放堆对象指针；错误类型是调用约定错误，由 luaL_checkudata 抛 Lua 异常。
    flywow_lua_filter **check_filter_slot(lua_State *state)
    {
        return static_cast<flywow_lua_filter **>(luaL_checkudata(state, 1, flywow_filter_metatable));
    }

    // 仅运行不调用 Lua API 的 C++ 操作；成功返回 nullptr，失败返回静态错误码。
    // 先退出 catch 和临时对象作用域，再 push Lua 值，避免 longjmp 跳过 C++ 析构。
    template <typename Operation> const char *run_native_operation(Operation operation)
    {
        try
        {
            operation();
            return nullptr;
        }
        catch (const std::bad_alloc &)
        {
            return "out_of_memory";
        }
        catch (const std::runtime_error &error)
        {
            const char *codes[] = {"dictionary_limit", "text_limit", "match_limit", "invalid_keyword", "invalid_utf8"};
            for (const char *code : codes)
            {
                if (std::strcmp(error.what(), code) == 0)
                {
                    return code;
                }
            }
            return "internal_error";
        }
        catch (...)
        {
            return "internal_error";
        }
    }

    // 返回栈顶两个值 nil,error；Lua 内存分配失败仍遵循 Lua 自身异常机制。
    int push_failure(lua_State *state, const char *code)
    {
        lua_pushnil(state);
        lua_pushstring(state, code);
        return 2;
    }

    // __gc 可重复触发；先销毁 owner 再置空，避免再次回收同一堆对象。
    int collect_filter(lua_State *state)
    {
        auto filter_slot = check_filter_slot(state);
        delete *filter_slot;
        *filter_slot = nullptr;
        return 0;
    }

    void destroy_filter_owner(flywow_lua_filter **filter_slot)
    {
        delete *filter_slot;
        *filter_slot = nullptr;
    }

    const char *append_keyword(flywow_lua_filter *filter, lua_State *state, std::size_t index)
    {
        lua_rawgeti(state, 1, static_cast<lua_Integer>(index));

        if (lua_type(state, -1) != LUA_TSTRING)
        {
            lua_pop(state, 1);
            return "invalid_keyword";
        }

        std::size_t byte_length = 0;
        const char *text        = lua_tolstring(state, -1, &byte_length);

        if (byte_length > flywow_max_keyword_bytes)
        {
            lua_pop(state, 1);
            return "dictionary_limit";
        }

        const char *error = run_native_operation(
            [&]()
            {
                if (!filter->filter.add_keyword(std::string(text, byte_length), static_cast<std::int32_t>(index)))
                {
                    throw std::runtime_error("invalid_keyword");
                }
            });

        lua_pop(state, 1);
        return error;
    }

    // Lua 参数为 keywords 数组及 compact 开关；成功返回 userdata，业务失败返回 nil,error。
    // 注册 __gc 后才创建堆对象：Lua 分配 longjmp 时，未交付对象仍能被 GC 回收。
    int create_filter(lua_State *state)
    {
        luaL_checktype(state, 1, LUA_TTABLE);
        const std::size_t keyword_count = lua_rawlen(state, 1);
        if (keyword_count > flywow_max_keywords)
        {
            return push_failure(state, "dictionary_limit");
        }
        const bool compact_enabled = lua_toboolean(state, 2);
        auto filter_slot = static_cast<flywow_lua_filter **>(lua_newuserdatauv(state, sizeof(flywow_lua_filter *), 0));
        *filter_slot     = nullptr;
        luaL_setmetatable(state, flywow_filter_metatable);
        const char *error = run_native_operation(
            [&]()
            {
                *filter_slot                    = new flywow_lua_filter();
                (*filter_slot)->compact_enabled = compact_enabled;
            });
        if (error)
        {
            return push_failure(state, error);
        }
        for (std::size_t index = 1; index <= keyword_count; ++index)
        {
            error = append_keyword(*filter_slot, state, index);

            if (error)
            {
                destroy_filter_owner(filter_slot);

                return push_failure(state, error);
            }
        }
        error = run_native_operation(
            [&]()
            {
                (*filter_slot)->filter.build();
            });
        if (error)
        {
            delete *filter_slot;
            *filter_slot = nullptr;
            return push_failure(state, error);
        }
        return 1;
    }

    // Lua 参数为 userdata、原文；成功返回命中数组，失败返回 nil,error，不返回部分命中。
    // 导出 Lua table 时容器仍归 userdata 所有，不把 C++ 容器留在可能被 longjmp 跳过的栈上。
    int find_matches(lua_State *state)
    {
        auto filter_slot = check_filter_slot(state);
        if (!*filter_slot)
        {
            return push_failure(state, "closed");
        }
        if (lua_type(state, 2) != LUA_TSTRING)
        {
            return push_failure(state, "invalid_text");
        }
        std::size_t byte_length = 0;
        const char *text        = lua_tolstring(state, 2, &byte_length);
        if (byte_length > flywow_max_text_bytes)
        {
            return push_failure(state, "text_limit");
        }
        const char *error = run_native_operation(
            [&]()
            {
                std::string input(text, byte_length);
                bool        valid = false;
                if ((*filter_slot)->compact_enabled)
                {
                    flywow_compact_options options;
                    options.max_source_span_bytes = flywow_max_compact_span;
                    valid                         = (*filter_slot)
                                ->filter.find_compact(input, (*filter_slot)->query_matches, flywow_normalize_options(),
                                                      options);
                }
                else
                {
                    valid = (*filter_slot)->filter.find(input, (*filter_slot)->query_matches);
                }
                if (!valid)
                {
                    throw std::runtime_error("invalid_utf8");
                }
            });
        if (error)
        {
            (*filter_slot)->query_matches.clear();
            return push_failure(state, error);
        }
        // C++ offset 为 0-based byte 索引，Lua string.sub 为 1-based；length 保持原文 bytes。
        lua_createtable(state, static_cast<int>((*filter_slot)->query_matches.size()), 0);
        lua_Integer index = 1;
        for (const auto &match : (*filter_slot)->query_matches)
        {
            lua_createtable(state, 0, 3);
            lua_pushinteger(state, match.keyword_id);
            lua_setfield(state, -2, "keyword_id");
            lua_pushinteger(state, match.source_byte_offset + 1);
            lua_setfield(state, -2, "offset");
            lua_pushinteger(state, match.source_byte_length);
            lua_setfield(state, -2, "length");
            lua_rawseti(state, -2, index++);
        }
        (*filter_slot)->query_matches.clear();
        return 1;
    }
} // namespace

// 不链接其它 FlyWow 模块；Lua State 注册自己的 metatable，userdata 由 GC 释放。
extern "C" int luaopen_flywow_word_filter_native(lua_State *state)
{
    /*
     * Lua 执行：
     *
     *     require("flywow_word_filter_native")
     *
     * 时，会进入这个函数。
     *
     * 这个函数最终需要完成两件事：
     *
     * 1. 注册 flywow_word_filter userdata 使用的 metatable。
     *    这个 metatable 主要负责 userdata 的生命周期管理，例如 __gc。
     *
     * 2. 创建并返回 Lua 模块 table：
     *
     *        {
     *            new  = create_filter,
     *            find = find_matches,
     *        }
     *
     * 注意：
     *
     *     userdata 的 metatable
     *
     * 和
     *
     *     require() 返回的 module table
     *
     * 是两个完全不同的 table。
     *
     * 下面所有栈示意都按照：
     *
     *     栈底 -> 栈顶
     *
     * 来表示，最右边永远是当前栈顶。
     */

    /*
     * 创建或者取得名为 flywow_filter_metatable 的 metatable。
     *
     * luaL_newmetatable() 会在 Lua Registry 中查找这个名字：
     *
     * - 如果不存在：
     *      创建一个新的 table；
     *      保存到 Registry；
     *      并把它压入 Lua 栈。
     *
     * - 如果已经存在：
     *      直接把之前的 metatable 压入 Lua 栈。
     *
     * 假设调用前 Lua 栈为：
     *
     *     [S]
     *
     * 调用后：
     *
     *     [S, metatable]
     *
     * 这里的 S 表示进入本函数前原本存在、但我们不关心的栈内容。
     *
     * Registry 中保存了这个 metatable 的引用，
     * 所以后面即使从 Lua 栈中 pop 掉，它也不会消失。
     */
    luaL_newmetatable(state, flywow_filter_metatable);

    /*
     * 把 C/C++ 函数 collect_filter 压入 Lua 栈。
     *
     * 当前：
     *
     *     [S, metatable]
     *
     * 执行后：
     *
     *     [S, metatable, collect_filter]
     */
    lua_pushcfunction(state, collect_filter);

    /*
     * 设置：
     *
     *     metatable.__gc = collect_filter
     *
     * lua_setfield(state, -2, "__gc")
     *
     * 此时：
     *
     *     -1 = collect_filter
     *     -2 = metatable
     *
     * lua_setfield 会把栈顶的 collect_filter 消耗掉，
     * 所以执行结束后 Lua 栈重新变成：
     *
     *     [S, metatable]
     *
     * __gc 是 Lua userdata 的垃圾回收元方法。
     *
     * 当使用这个 metatable 的 userdata 不再被 Lua 引用并被 GC 回收时，
     * Lua 会调用 collect_filter。
     *
     * collect_filter 通常负责释放 userdata 内部关联的 C/C++ 资源，
     * 例如调用析构函数、delete 对象等。
     *
     * 因此这里实际上是在给 C++ 对象和 Lua userdata 建立生命周期桥梁。
     */
    lua_setfield(state, -2, "__gc");

    /*
     * 压入字符串：
     *
     *     "flywow_word_filter"
     *
     * 当前栈：
     *
     *     [S, metatable]
     *
     * 执行后：
     *
     *     [S, metatable, "flywow_word_filter"]
     *
     * lua_pushliteral() 适合压入编译期固定字符串字面量。
     */
    lua_pushliteral(state, "flywow_word_filter");

    /*
     * 设置：
     *
     *     metatable.__metatable = "flywow_word_filter"
     *
     * 执行前：
     *
     *     [S, metatable, "flywow_word_filter"]
     *
     * 执行后：
     *
     *     [S, metatable]
     *
     * __metatable 的作用是保护真正的 metatable。
     *
     * 如果没有设置 __metatable，Lua 代码可以：
     *
     *     local mt = getmetatable(obj)
     *
     * 直接拿到真正的 metatable，然后修改里面的字段。
     *
     * 设置以后：
     *
     *     getmetatable(obj)
     *
     * 返回的不再是真正的 metatable，
     * 而是：
     *
     *     "flywow_word_filter"
     *
     * 因此普通业务 Lua 代码无法通过 getmetatable()
     * 直接取得并修改内部 metatable。
     *
     * 这里的字符串本身没有特殊语义，
     * 只是作为一个有意义的类型标识返回给 Lua。
     *
     * 注意：
     * __metatable 主要用于封装和防止误修改，
     * 不是严格的安全机制；Lua debug 库仍可能绕过这种保护。
     */
    lua_setfield(state, -2, "__metatable");

    /*
     * 当前 Lua 栈：
     *
     *     [S, metatable]
     *
     * 这里把 metatable 从 Lua 栈中弹出：
     *
     *     [S]
     *
     * metatable 并不会被销毁，因为 luaL_newmetatable()
     * 已经把它保存到了 Lua Registry 中。
     *
     * 后续创建 userdata 时，可以通过：
     *
     *     luaL_getmetatable(state, flywow_filter_metatable)
     *
     * 再次取得这个 metatable。
     */
    lua_pop(state, 1);

    /*
     * 定义这个 Native 模块要暴露给 Lua 的函数。
     *
     * luaL_Reg 本质上是一组：
     *
     *     Lua函数名 -> C函数
     *
     * 的映射。
     *
     * 最终 Lua 侧看到的效果等价于：
     *
     *     module.new  = create_filter
     *     module.find = find_matches
     *
     * create_filter / find_matches 必须满足 lua_CFunction 的签名：
     *
     *     int function(lua_State *L)
     *
     * 返回值不是业务结果本身，
     * 而是“这个 C 函数向 Lua 栈压入了多少个返回值”。
     *
     * 最后的：
     *
     *     {nullptr, nullptr}
     *
     * 是数组结束标记。
     *
     * Lua C API 会一直读取 luaL_Reg，
     * 直到遇到 name == nullptr。
     */
    const luaL_Reg functions[] = {
        {"new", create_filter},
        {"find", find_matches},
        {nullptr, nullptr},
    };

    /*
     * 创建一个新的 Lua table，
     * 并把 functions 中定义的所有 C 函数注册进去。
     *
     * 可以把 luaL_newlib() 理解为：
     *
     *     创建 module table
     *     +
     *     把 luaL_Reg 中的函数写入 table
     *
     * 大致等价于 Lua：
     *
     *     local module =
     *     {
     *         new  = create_filter,
     *         find = find_matches,
     *     }
     *
     * 假设调用前 Lua 栈为：
     *
     *     [S]
     *
     * 调用后：
     *
     *     [S, module]
     *
     * 这里使用 luaL_newlib() 而不是手动 lua_pushcclosure()，
     * 是因为 create_filter 和 find_matches 当前不需要绑定 upvalue。
     *
     * 如果某个 C 函数注册时需要绑定额外上下文，例如：
     *
     *     MapRegistry*
     *
     * 那么通常会使用：
     *
     *     lua_pushlightuserdata(L, registry);
     *     lua_pushcclosure(L, function, 1);
     *     lua_setfield(L, -2, "function_name");
     *
     * lua_pushcclosure(..., 1) 会从 Lua 栈顶消费 1 个值，
     * 并把它保存为这个 C Closure 的第 1 个 upvalue。
     *
     * 而 luaL_newlib() 适合这种不需要额外 upvalue 的普通模块函数注册。
     */
    luaL_newlib(state, functions);

    /*
     * 当前 Lua 栈顶就是刚刚创建的 module table：
     *
     *     [S, module]
     *
     * Lua C 函数的 return 值表示：
     *
     *     “本函数向 Lua 返回多少个值”
     *
     * 而不是返回数字 1 给 Lua。
     *
     * return 1 表示：
     *
     *     把 Lua 栈顶的 1 个值返回给调用者。
     *
     * 因此：
     *
     *     local word_filter = require("flywow_word_filter_native")
     *
     * 最终 word_filter 得到的就是：
     *
     *     {
     *         new  = create_filter,
     *         find = find_matches,
     *     }
     */
    return 1;
}
