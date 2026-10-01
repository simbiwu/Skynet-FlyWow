---
name: skynet-flywow-coding-standard
description: 实现或评审 Skynet-FlyWow 的 Lua、C、C++、Shell、Proto、CMake、配置、测试或示例时，应用 P0 编码、中文注释、API 合同和评审规范。
---

# Skynet-FlyWow 编码规范

本 Skill 是发布门槛，不是可选的风格建议。它适用于生产源码、构建和部署脚本、协议、配置、测试、供接入方复制的示例以及代码评审。

源码注释、工程文档、模块 README、接入说明、错误语义说明和示例说明统一使用中文。代码标识符、协议字段、命令、日志键和无法准确替代的技术名词保留英文；不要为了中文化翻译稳定 API 名称。

## 修改代码前

完整阅读仓库 `AGENTS.md` 和受影响模块的合同，确认：

- 模块公开 API 与禁止依赖；
- 状态、Service、Lua State、native 对象、buffer 和连接的 owner；
- I/O、内存分配、锁和 yield 边界；
- 版本、兼容性和资源上限；
- 本次修改必须交付的最小真实行为。

没有当前调用者和可测试合同时，不创建推测性的接口、空模块树、通用 Manager 或公共抽象。

## P0 全仓库排版

FlyWow 中所有使用花括号的语言都必须采用 Allman 排版：多行代码块、Lua table、Python dict、C/C++ 类型与控制块、Proto message/service 等的左右花括号各自独占一行，左花括号位于所属声明或表达式的下一行。短小的空容器或简单字面量可保持单行。

具名 record/table/dict 的字段名（或键）及分隔符按列对齐，值从同一列开始；Lua/C++/Proto 对齐等号，Python dict 对齐冒号。连续且属于同一逻辑组的变量赋值也对齐变量名、等号和值列；不跨不相关语句强行对齐。嵌套结构按层级缩进，并在各自 record 内单独对齐。此要求适用于生产源码、生成器输出、测试、工程文档和可复制示例，也适用于未来加入的 Native C++ 源码。

示例：

~~~lua
return
{
    envelope_type = definitions.envelope_type,
    by_id         = by_id,
    count         = count,
}
~~~

Native C++ 示例：

~~~cpp
class NativeRuntime
{
public:
    void start()
    {
        port    = requested_port;
        running = false;
    }

private:
    int  port    = 0;
    bool running = false;
};
~~~

不为了对齐数组式 positional entries 增加无意义空格。该排版要求属于 P0；格式不符合时，代码评审与发布门禁视为未完成。C++ 控制结构、类型和函数均使用 Allman 花括号，相关成员赋值与具名初始化字段遵守列对齐规则。

## P0 源码要求

每个源码、脚本、协议和构建文件必须在文件头用中文说明：

```text
本文件解决的问题
所属边界：Runtime / Module / Adapter / Build / Test / Debug
主要输入和输出
生命周期、所有权或运行时机
明确不负责的事情
```

每个函数、方法、构造函数和可执行入口前必须有中文合同注释。公开 API、跨模块入口和包含领域判断的私有函数还必须说明：

- 解决的具体问题；
- 每个参数的业务意义、单位、坐标系、合法范围和所有权；
- 返回状态的意义和所有权；
- 显式错误、错误码或异常；
- 是否执行 I/O、分配内存、加锁、yield 或修改共享状态；
- 适用时的前置条件、复杂度和调用时机。

每个字段和配置项都要说明用途、单位/范围、owner、生命周期，以及是否跨越存储、资产或网络边界。紧凑 record 优先使用简短同行尾注释；ownership、不变量和多步推理使用相邻上方注释。

注释按读者理解代码的顺序组织：先用直白的一句话说明函数或代码块要解决什么问题、产生什么结果；再说明参数/状态的意义、单位、前置条件和 ownership；最后解释关键算法步骤及必须保持的不变量。不要先堆实现细节，让读者猜代码用途。

公式、坐标换算、插值、索引映射、边界遍历等不容易从名称看懂的逻辑，应配一个短小的输入/输出例子，再解释实现细节。例如：插值从 100 到 500，线段长 400、已走 100，结果为 200。简单直观的赋值或返回不必形式化举例；禁止逐行翻译语法，也不要把教程正文搬进源码注释。

函数内部必须在对应代码前解释领域 WHY 和不变量，至少覆盖适用的：

- byte offset、length、endian 和 CRC 覆盖范围；
- socket framing、半包/粘包状态和 buffer ownership；
- fd 复用、connection identity 和 close race；
- Service ownership 与 yield 后重新验证；
- 坐标换算、取整与边界；
- 状态迁移、热更兼容与回滚；
- 有界队列、内存增长与背压。

禁止只翻译语法的注释、容易失真的作者/日期/手工版本头，以及掩盖真实合同的大段样板注释。

## API 与实现规则

- 模块依赖保持单向；框架模块不得导入具体 Battle、SLG 或宿主项目 DTO。
- 配置与 Service handle 显式注入，不用全局服务名、进程路径或环境中的可变全局隐藏必要依赖。
- 公开结果与失败必须显式、可版本化；不得用 `nil`、日志文本或进程退出表达未记录的多状态 API。
- 稳定 Lua API 使用命名参数或有注解的 request/result record；项目稳定接口不使用 `...`，也不转发未知 varargs。
- 可能 yield 的函数必须在合同中声明，不得跨 yield 保留 borrowed buffer 或未重新验证的身份。
- queue、frame、client、request、retry、timer 和 cache 必须有明确上限与过载行为。
- 热更是包含兼容验证、状态迁移和回滚的生命周期操作，不是无限制清空 `package.loaded`。
- 多个 Skynet Service 可能运行在不同 OS Thread 时，native mutable scratch 不得是无保护的 process-global 状态。
- 示例只使用公开 API 且保持可运行，不为缩短篇幅绕过 ownership、校验或错误处理。

## 验证门槛

声明完成前必须：

1. 构建受影响的语言和 native target。
2. 运行聚焦的成功、边界和失败路径测试。
3. 适用时验证资源上限、清理以及 yield/ownership 行为。
4. 在同一次修改中更新公开 API 示例、模块文档和兼容说明。
5. 逐个检查变更的函数和字段；缺少合同注释视为 P0 失败。

最终报告必须区分实际完成的 build、运行和测试；不能把编译通过描述成运行或集成测试成功。
