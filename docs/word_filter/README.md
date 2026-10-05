# WordFilter 接入

本模块按宿主词库匹配 UTF-8 文本，可用于聊天、角色名或公会名。
复用 FCLib 的 FCKeywordFilter.cpp/.h 中 AC 自动机、UTF-8 解码、归一化、
compact 及原文 byte 映射算法；移除 FCLib 类型/导出宏及文件配置解析依赖。
不提供聊天 Service、业务禁用词库、拼音/谐音识别或自动更新。

## 构建与加载

固定使用 C++14、CMake/Linux/WSL2、Skynet v1.8.0 自带 Lua 5.4.7。
在 FlyWow 根目录运行：

~~~bash
bash scripts/build_flywow.sh /path/to/skynet word_filter
~~~

宿主统一构建入口仍为 server/scripts/linux/run_server.sh build。
中间目录 build/cmake/word_filter/，产物 build/native/flywow_word_filter_native.so。
构建会执行 C++ 与 Lua 测试；单独复测：

~~~bash
ctest --test-dir build/cmake/word_filter --output-on-failure
~~~

使用模块的 Skynet 进程配置在既有 lua_path、lua_cpath 中追加以下路径，
基准为 server/ 工作目录（保留原有其它模块路径）：

~~~lua
-- lua_path 追加：
-- ./third_party/skynet-flywow/word_filter/lualib/?.lua;
-- lua_cpath 追加：
-- ./third_party/skynet-flywow/build/native/?.so;
~~~

Wrapper flywow_word_filter.lua 加载 flywow_word_filter_native.so。
无需独立 Service，不改 Gateway/Battle 配置或业务协议。

## 最小调用

在聊天业务 Service 的普通 Lua 代码中调用：

~~~lua
local word_filter = require "flywow_word_filter"
local filter, err = word_filter.new(
{
    keywords = {"外挂", "广告词"},
    compact  = false,
})
assert(filter, err)

local matched, find_error = filter:contains("这里有外挂")
assert(matched ~= nil, find_error)
local output, replace_error = filter:replace("这里有外挂", "*")
assert(output, replace_error)
assert(output == "这里有*")
~~~

以上示例只演示调用。业务自行决定命中后的拒绝、替换及错误处理。
词库由宿主加载并传入，模块不读文件。对象由当前 Lua State 独占、GC 释放；
词库创建后只读，更新时创建新对象，再由业务替换引用。
所有调用同步、无 I/O、无 yield，会分配内存。

## API 与参数

- new({keywords=连续字符串数组, compact=false})：返回 filter 或 nil,error。
  关键词 ID 为词库数组的 1-based 索引。空词库合法；空关键词非法；
  重复词保留各自 ID；未知选项拒绝。
- filter:find(text)：返回命中数组或 nil,error。每项 keyword_id、offset、length；
  offset 为原文 1-based byte 索引，length 为原文字节数。返回全部重叠项，
  按 offset、keyword_id 排序。
- filter:contains(text)：返回 true/false 或 nil,error，限制与 find 相同。
- filter:replace(text, replacement="*")：返回新字符串或 nil,error；
  重叠命中合并，每个合并区间替换一次，相邻但不重叠区间分别替换。
  replacement 允许空串，必须为合法 UTF-8、最多 256 bytes。

默认对词库和文本统一做 ASCII 小写、全角 ASCII 折叠和开头 UTF-8 BOM 去除；
没有完整 Unicode 大小写折叠、简繁转换或英文单词边界规则。
text 允许内嵌 NUL；非法 UTF-8 拒绝，不返回部分结果。

compact=true 复用旧算法，删除空白/控制字符、ASCII 标点及常见零宽字符，
原文映射包含中间被忽略部分；单次命中最多跨原文 256 bytes。
可能将正常分隔内容连成关键词，因此默认关闭；不是完整防绕过能力。
词库按普通归一化构建，compact 用于输入文本；词库应提供连续关键词，
包含分隔符的词仍建议使用普通模式。

固定资源边界：最多 16384 词、每词 4096 bytes、词库原文总计 1 MiB、
262144 trie 节点、构建后的后缀输出总计 1048576 项；
每次文本最多 65536 bytes、命中最多 4096 项；超限失败，不截断。
错误码：invalid_options、invalid_keyword、invalid_text、invalid_utf8、
invalid_replacement、dictionary_limit、text_limit、match_limit、
out_of_memory、internal_error。Native 对已释放对象返回 closed。
业务不得把 nil,error 当作“无命中”。

## 源码阅读与算法边界

先读 word_filter/lualib/flywow_word_filter.lua 的公开合同，再读
word_filter/native/word_filter.h 的内部字段与单位，最后按 word_filter.cpp 的
add_keyword → build → find 顺序查看核心。lua_word_filter.cpp 负责 userdata、GC、
异常转换和 C++/Lua 的索引转换；业务不需要直接调用 Native 入口。

AC 自动机按完整 Unicode 码点建立 trie，build 用 BFS 建立 fail 链并继承后缀输出。
例如词库同时含 she/he，输入 she 会返回两项；Lua replace 合并两项的重叠区间，
输出一次替换文本。出边使用有序 vector 和二分查找，沿用 FCLib 算法，不新增搜索策略。

归一化位置与原文位置使用不同单位：normalized_code_point_offset/length 是码点，
source_byte_offset/length 是原文 bytes。核心偏移从 0 开始，Lua offset 从 1 开始。
例如“前外-挂后”的 compact 命中起点为 C++ byte 3 / Lua byte 4，跨度为
3+1+3=7 bytes；替换只覆盖“外-挂”，其余原文保持不变。

词库只读不代表查询容器可以共用。C++ 并发查询须各自持有 results；
Lua 每个对象持有自己的查询容器，调用不 yield。导出 Lua table 时，
查询容器保留在 userdata owner 内，避免 Lua 分配失败的 longjmp 跳过栈上
C++ 容器析构。C++ 异常转换为 nil,error；Lua 自身分配失败仍由 Lua 抛异常。

## 验证与兼容

C++ 测试覆盖后缀/重叠命中、重复 build、中文原文偏移、NUL、非法 UTF-8、
compact 和同一只读核心的多线程查询。
Lua 测试覆盖公开接口、排序/替换、全角、词库失败、容量边界及 GC。
Skynet 测试从宿主 server/ 启动两个 worker Service，验证独立 Lua State 的真实调用。
已有 Skynet 可执行文件时 CTest 自动运行此项；没有时该集成边界未验证。
模块不承诺现有 FCLib C++ API 兼容；宿主通过 FlyWow Lua 入口接入。
尚未验证正式聊天流量、真实大词库容量及 Windows Native 构建。
