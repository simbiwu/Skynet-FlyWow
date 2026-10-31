# FlyWow Gateway 独立源码实战教程（源码深入增强版）

> **两名玩家进入新手村：从零完成连接、握手、Protobuf、请求响应、单播/广播、主动断开、TCP 与故障实验**
>
> 源码基线：`simbiwu/Skynet-FlyWow` `7509b289fdd05a63b24c9c11b2a1eafc1e836a4a`（2026-10-29）。Skynet 固定 `v1.8.0`，Lua 使用该 Skynet 自带版本，协议版本 `4`；宿主协议工具固定版本以 `shared/protocol/VERSIONS.env` 为准。
>
> **代码身份**：标为「亲手新建」的是本课程的完整教学文件，不是仓库现存源码；标为「真实源码」的路径、函数、合同已在上述提交中核对；日志均为**预期现象，不是本课程实测结果**。本次只编写教程，不替学习者创建示例或修改仓库。

---

## 导学：业务问题和学习结果

一个传统 MMO 网关收到玩家发来的网络包，需要知道：这条连接是谁管理的？包的边界在哪里？消息该交给哪个业务服务？业务服务怎样把结果送回原连接？广播与关闭由谁执行？客户端握手失败、读超时、写缓冲积压又该由谁清理？

我们选一个**不需要数据库或登录系统**的业务：玩家 `1001`（A）和 `1002`（B）先后进入新手村 `scene_id=7`。A 进入时在线人数为 1；B 进入时为 2。服务端先给 B 单播欢迎语，再向两人广播公告，随后主动断开 B；A 主动退出。两人断线后，演示业务 Service 清理映射以及 Gateway 停止。业务玩家 ID 只是演示字段，**不是 Gateway 身份认证**；不能据此设计真实账号鉴权。

我们真正研究的是 Gateway，世界场景仅在一个小型 Lua Service 的 table 中保存两条连接记录。学完应该能沿真实源码解释：

```text
Node 客户端
  -> TCP/WS 建连
  -> CLIENT_HELLO -> SERVER_CHALLENGE -> CLIENT_PROOF -> SERVER_READY
  -> Envelope{version=4, command=1001, body=EnterWorldRequest{player_id=1001}}
  -> Gateway 解帧/查 Registry/解 Protobuf
  -> skynet.send(WorldService, "lua", "send_data", request)  [不等待业务结果]
  -> WorldService 处理玩家进入
  -> skynet.send(Gateway, "lua", "send_data", response)
  -> Gateway 编码并写回客户端
  -> 服务端 Push / 广播 / close
  -> gateway_disconnect / 清理连接 / stop
```

**课程分六阶段**：协议与构建；启动及握手；一条请求与响应；两个客户端与 Push；TCP 对照；故障与生命周期。第一阶段开始就把工程文件逐一写出来；后续阶段通过真实现象进入函数内部，不分散成互不关联的 API 讲义。

**源码阅读约定**：教程中「亲手新建/完整替换」代码块才是应复制实施的完整文件；「真实源码局部」为从固定提交中选择的关键语句，可能删去源文件中的注释、日志或错误分支，并用“省略”提示衔接，**不是可以直接替换生产文件的完整函数**。读到这类片段时先确认入口及调用者，再阅读仓库中同名函数的完整上下文。时间线与示例 fd、tick 是为了推导而设的数值，不代表实际日志。每个源码专题的最后都要回到真实业务主线。

### 工程约束和真正的「从零」

从空目录 `gateway/sample/master_course/` 开始。只使用 FlyWow 当前公开接口；不修改 Gateway、Skynet 或任何第三方源码。不使用现成 `gateway/sample/` 中的协议、客户端或运行入口，也不使用以前的 Battle/Lesson 3 协议。**仅复用已经安装并固定版本的基础工具链**：Skynet 及其自带 Lua、lua-protobuf、protoc、OpenSSL 3，以及 FlyWow 自身的 Registry 生成器、Native 构建脚本和 H5 握手 SDK。

以下命令约定真实仓库布局：

```text
skynet-battle-navigation-commercial-learning/
├── server/
│   └── third_party/
│       ├── skynet/                 # 固定 v1.8.0
│       ├── skynet-flywow/          # 当前 FlyWow
│       ├── lua-protobuf/           # 宿主固定源码（只读依赖）
│       ├── lua-protobuf-runtime/   # 宿主自己的 pb.so 构建产物
│       └── protoc-36.2/           # 以宿主 VERSIONS.env 为准
└── shared/protocol/VERSIONS.env
```

使用 WSL2/Linux，从**宿主仓库根目录**准备环境；以下脚本来自真实宿主工程，不是旧课程步骤：

```bash
bash server/scripts/linux/build_skynet.sh
bash server/scripts/linux/bootstrap_protocol_tools.sh
bash server/scripts/linux/build_lua_protobuf.sh
bash server/third_party/skynet-flywow/scripts/build_flywow.sh server/third_party/skynet gateway
node --version     # 要求 Node.js 22+ 且支持 Web Crypto、WebSocket
```

`bootstrap_protocol_tools.sh` 按 `VERSIONS.env` 拉取固定版本的构建依赖；不可自行替换或更改第三方源码。若本地工具链已经具备，可跳过重复构建。以下命令默认在 **`server/third_party/skynet-flywow`（FlyWow 根目录）**执行；`run.sh` 会自己切换到宿主 `server/` 作为 Skynet 的工作目录。

最终你将逐步亲手创建：

```text
gateway/sample/master_course/
├── proto/
│   ├── wire_header.proto
│   └── world.proto
├── generated/                 # 由脚本生成，不手写
│   ├── world.pb
│   └── world_registry.lua
├── service/
│   └── world_service.lua
├── client/
│   ├── protobuf.mjs
│   ├── world_scenario.mjs
│   ├── websocket_client.mjs
│   └── tcp_client.mjs
├── skynet_config.lua
├── bootstrap.sh
├── build_protocol.sh
└── run.sh
```

---

# 第一阶段：从协议源到 Gateway 可读取的产物

## 1. 为什么不能直接发送 `{player_id=1001}`

Gateway 的公开合同不是收 JSON 或 Lua table。网络载荷是 Protobuf `Envelope`，其中 `command` 决定解码 `body` 的具体消息类型。`Gateway` 运行期间不扫描 `.proto`，它在启动前读取**构建产物**：一个 FileDescriptorSet（`.pb`）及一个 Lua Registry（命令到 Request/Response 类型的映射）。

本例的命令编号：

| 命令            | 数值   | 定义                                       | 发起方                 |
| --------------- | ------:| ------------------------------------------ | ---------------------- |
| `ENTER_WORLD`   | `1001` | `EnterWorldRequest` + `EnterWorldResponse` | 客户端请求、服务端响应 |
| `SYSTEM_NOTICE` | `1002` | **仅** `SystemNoticeResponse`              | 服务端单播或广播       |

`gateway_disconnect` 是 Gateway 发送给宿主的 Skynet Lua 消息名，**不是**网络 command，更不写进 `.proto`。

### 1.1 亲手新建 `proto/wire_header.proto`

在 FlyWow 根目录运行：

```bash
mkdir -p gateway/sample/master_course/{proto,generated,service,client}
```

文件：`gateway/sample/master_course/proto/wire_header.proto`。它定义课程专属的共享 Envelope 声明；`protocol_version` 是业务协议版本 4，跟握手版本 1 无关。

```proto
syntax = "proto3";
package battle.transport.v1;

message Envelope {
  uint32 protocol_version = 1;
  uint32 command = 2;
  bytes body = 3;
}
```

### 1.2 亲手新建 `proto/world.proto`

文件：`gateway/sample/master_course/proto/world.proto`。Registry 构建器通过 `enum CommandId` 将 `ENTER_WORLD` 转成 `EnterWorld`，据此查找同前缀的 Request/Response；`SYSTEM_NOTICE` 只有 Response，因此客户端不能用它发请求。

```proto
syntax = "proto3";
package flywow.gateway.course;

enum CommandId {
  COMMAND_UNSPECIFIED = 0;
  ENTER_WORLD = 1001;
  SYSTEM_NOTICE = 1002;
}

message EnterWorldRequest {
  uint32 player_id = 1;
}

message EnterWorldResponse {
  uint32 player_id = 1;
  uint32 scene_id = 2;
  uint32 online_count = 3;
}

message SystemNoticeResponse {
  string content = 1;
}
```

### 1.3 亲手新建 `build_protocol.sh`

文件：`gateway/sample/master_course/build_protocol.sh`。你从 FlyWow 根执行它。它先从宿主固定版本文件取得 `protoc` 版本，再编译两个 `.proto` 为一个包含两种 package 的 Descriptor，最后调用**真实** `gateway/tools/generate_gateway_registry.py` 生成本课 Lua Registry。路径不依赖旧课程文件。

```bash
#!/usr/bin/env bash
set -euo pipefail

COURSE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FLYWOW_ROOT="$(cd "$COURSE_DIR/../../.." && pwd)"
SERVER_ROOT="$(cd "$FLYWOW_ROOT/../.." && pwd)"
HOST_ROOT="$(cd "$SERVER_ROOT/.." && pwd)"

# 使用宿主唯一版本清单；绝不调用系统中不明版本的 protoc。
source "$HOST_ROOT/shared/protocol/VERSIONS.env"
PROTOC="$SERVER_ROOT/third_party/protoc-$PROTOC_VERSION/bin/protoc"
[[ -x "$PROTOC" ]] || { echo "缺少固定 protoc：$PROTOC" >&2; exit 1; }
[[ "$($PROTOC --version)" == "libprotoc $PROTOC_VERSION" ]] || {
    echo "protoc 版本不匹配" >&2; exit 1;
}

mkdir -p "$COURSE_DIR/generated"
"$PROTOC" \
    -I "$COURSE_DIR/proto" \
    --include_imports \
    --descriptor_set_out="$COURSE_DIR/generated/world.pb" \
    "$COURSE_DIR/proto/wire_header.proto" \
    "$COURSE_DIR/proto/world.proto"

python3 "$FLYWOW_ROOT/gateway/tools/generate_gateway_registry.py" \
    --proto "$COURSE_DIR/proto/world.proto" \
    --envelope-type ".battle.transport.v1.Envelope" \
    --output "$COURSE_DIR/generated/world_registry.lua"

test -s "$COURSE_DIR/generated/world.pb"
test -s "$COURSE_DIR/generated/world_registry.lua"
echo "COURSE_PROTOCOL_OK"
```

运行：

```bash
bash gateway/sample/master_course/build_protocol.sh
sed -n '1,80p' gateway/sample/master_course/generated/world_registry.lua
```

**预期** `COURSE_PROTOCOL_OK`，Registry 含 `.battle.transport.v1.Envelope`；命令 `1001` 对应 `.flywow.gateway.course.EnterWorldRequest` 和 `EnterWorldResponse`；`1002` 的 `request_type=nil`，`response_type=SystemNoticeResponse`。

### 1.4 源码切入：Registry 到底是谁生成的

**【真实源码】** `gateway/tools/generate_gateway_registry.py`：`main()` → `parse_protos()` → `render()` → `write_if_changed()`。这是**构建期 Python 进程**，不属于任何 Skynet Service。

`parse_protos` 扫描当前 `world.proto` 的唯一 `CommandId`、消息声明和 ID；`render` 生成 `commands[1001]` / `commands[1002]`；`--envelope-type` 显式将生成 Registry 中的 Envelope 名指向另一个 package。`write_if_changed` 只在内容变化时更新文件。

**返回主线**：生成器结束后，这两份产物仍在磁盘。下一阶段 `WorldService` 向 Gateway 传入 `descriptor_path` 和 `registry_module`，**Gateway 启动时**才加载它们。`.proto` 本身不会被网络 Service 解析。

**阶段验收**：从空目录生成两份文件；解释清楚 `.proto`、`.pb`、`.lua Registry` 分别是什么，以及由谁、在什么阶段消费。

---

### 1.5 源码精读：生成物为什么能决定网关该解哪种消息

这一步先看构建期生成器，再看 Gateway 启动时的只读校验。请打开 `gateway/tools/generate_gateway_registry.py` 的 `parse_protos()` 和 `render()`，再打开 `gateway/service/gateway/flywow_gateway.lua` 的 `validate_generated_registry()`。生成文件就是 Gateway 查询的命令表，不再复制第二份索引。

**【真实源码局部：`gateway/tools/generate_gateway_registry.py` / `parse_protos()`，省略输入列表的 package 验证】**

```python
method_name = _pascal_name(enum_name)
request_name = f"{method_name}Request"
response_name = f"{method_name}Response"
request_type = (
    f".{package}.{request_name}"
    if request_name in message_names else None
)
response_type = (
    f".{package}.{response_name}"
    if response_name in message_names else None
)
```

此处 `enum_name` 来自 `world.proto` 的 `CommandId`，`message_names` 来自同一批 proto 的消息声明。以 `ENTER_WORLD` 为例：`_pascal_name` 得到 `EnterWorld`，生成器查到 `EnterWorldRequest` 与 `EnterWorldResponse`，便形成双向定义。`SYSTEM_NOTICE` 只能查到 `SystemNoticeResponse`，因此生成 Lua 文件里的 `request_type` 是 `nil`。

不要从 `response_type ~= nil` 推断“必须先收到相同 command 的 Request”。Gateway 只有一张命令表，**入站使用 request_type，出站使用 response_type**；客户端协议并没有 request_id 或请求关联字段。

**【生成产物局部：`gateway/sample/master_course/generated/world_registry.lua`】**

```lua
commands =
{
    [1001] =
    {
        request_type  = ".flywow.gateway.course.EnterWorldRequest",
        response_type = ".flywow.gateway.course.EnterWorldResponse",
    },
}
```

Gateway 启动时只读校验每个数字 key 与消息类型，并计算命令数量；`dispatch_payload()` 随后直接用 `module_state.registry.commands[envelope.command]` 找到定义。`1001` 是表的 key，不在命令定义中重复保存。生成文件还保留 `command_ids.ENTER_WORLD` 等名称到数字的映射，供宿主业务代码引用协议命令号；Gateway 查表本身不使用这组名称。这个协议表属于 Gateway Service，与 WorldService 的 `state.players` 无关。

`Descriptor` 则提供每一个字段的 wire type 和类型结构；Registry 只是**选择**具体类型。若有 Registry，却没有包含消息定义的 `.pb`，`codec_module.new()` 会在 Gateway 启动时拒绝，而不会等客户端首个请求才发现。

**验证实验**：生成产物后，打开 `generated/world_registry.lua` 并记录两条 command；然后在第二阶段 `start()` 前把 `registry_module` 临时改成一个不存在的模块名，观察 `GATEWAY_REGISTRY_LOAD_FAILED`。恢复原值、重新启动。由此确认 Python 生成器不参与运行时消息收发，Gateway 只消费文件结果。

**返回主线**：第一阶段只有两种静态产物；接下来进入 WorldService 启动 Gateway，观察它们何时进入 `module_state.registry` 和 `module_state.codec`。

---

# 第二阶段：让真实 Gateway 监听 WebSocket

## 2. 服务启动涉及哪几个执行环境

本课程只创建一个小型 `WorldService` 来兼任启动者和业务 handler，再由它通过 `skynet.newservice("gateway/flywow_gateway")` 启动独立的 Gateway Service。它们是两个不同 Skynet Service、两个 Lua State；**WorldService 不拥有 fd，不持有 Gateway 的连接 table**。

第一步准备运行时配置。然后写 WorldService：它起初只需要把 Gateway 正确启动；第三阶段再加入业务处理。阶段 2 先观察 listener，阶段 3 才连接真实客户端。

### 2.1 亲手新建 `skynet_config.lua`

路径：`gateway/sample/master_course/skynet_config.lua`。**Skynet 进程的当前工作目录是宿主 `server/`**；所以搜索路径都以 `./third_party/...` 开头。`start` 对应 `service/world_service.lua` 文件名。

```lua
thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "world_service"
lualoader = "./third_party/skynet/lualib/loader.lua"

luaservice = "./third_party/skynet-flywow/gateway/service/?.lua;"
    .. "./third_party/skynet-flywow/gateway/sample/master_course/service/?.lua;"
    .. "./third_party/skynet/service/?.lua"

lua_path = "./third_party/skynet/lualib/?.lua;"
    .. "./third_party/skynet/lualib/?/init.lua;"
    .. "./third_party/skynet-flywow/common/lualib/?.lua;"
    .. "./third_party/skynet-flywow/gateway/lualib/?.lua;"
    .. "./third_party/skynet-flywow/gateway/sample/master_course/generated/?.lua"

lua_cpath = "./third_party/skynet/luaclib/?.so;"
    .. "./third_party/lua-protobuf-runtime/?.so;"
    .. "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so"
```

### 2.2 亲手新建 WorldService 启动版

路径：`gateway/sample/master_course/service/world_service.lua`。这是**第 2 阶段的完整文件**；第 3 阶段会明确要求将其**整体替换**为带业务的最终版。当前不接收业务请求，因此只用「server」模式验证监听。

```lua
local skynet = require "skynet"
require "skynet.manager"

skynet.start(function()
    -- Gateway 会向该本地服务名发送 send_data/gateway_disconnect。
    skynet.name(".gateway_course_world", skynet.self())
    skynet.dispatch("lua", function(session, _, command)
        skynet.error("课程暂未处理业务消息：", command)
        if session ~= 0 then
            skynet.retpack(true)
        end
    end)

    local gateway = skynet.newservice("gateway/flywow_gateway")
    local transport = os.getenv("GATEWAY_COURSE_TRANSPORT") or "websocket"
    local port = tonumber(os.getenv("GATEWAY_COURSE_PORT")) or 19221
    local config =
    {
        host            = "127.0.0.1", -- 课程仅对本机开放。
        port            = port, -- Shell 本次指定的监听端口。
        transport       = transport, -- 当前 Gateway 固定为 TCP 或 WebSocket。
        handler_service = ".gateway_course_world", -- 已注册的业务接收 Service。
        descriptor_path = "./third_party/skynet-flywow/gateway/sample/master_course/generated/world.pb", -- 启动时读取的类型描述文件。
        registry_module = "world_registry", -- 构建脚本生成的命令表模块名。
        protocol_version = 4, -- 当前示例 Envelope 兼容版本。
        max_clients      = 4, -- 足以接入两个玩家的连接容量。
    }

    -- start 是同步 RPC；该协程可能等待，业务收发才使用异步 send。
    local result = skynet.call(gateway, "lua", "start", config)
    if not result.ok then
        skynet.error("COURSE_START_FAILED ", result.code, " ", result.message)
        skynet.abort()
        return
    end
    skynet.error("COURSE_GATEWAY_READY transport=", result.value.transport,
        " port=", result.value.port, " commands=", result.value.command_count)
end)
```

### 2.3 新建课程依赖准备脚本 `bootstrap.sh`

路径：`gateway/sample/master_course/bootstrap.sh`。它按顺序复用宿主现有固定版本 bootstrap 和构建入口：准备 Skynet 与协议工具；缺少 Skynet 可执行文件时编译 Skynet；缺少 `pb.so` 时编译 lua-protobuf；缺少 Gateway Crypto 时只构建 FlyWow 的 `gateway` 模块。脚本会校验最后需要的产物，并输出 `GATEWAY_MASTER_COURSE_PREPARE_OK`。它不安装系统软件，也不修改 Skynet 源码。

```bash
bash gateway/sample/master_course/run.sh prepare
```

`run.sh prepare` 会调用本课程自己的 bootstrap，因此本步骤可从其他当前目录执行。它准备工具和运行依赖；协议 Descriptor/Registry 仍由后续普通运行过程通过 `build_protocol.sh` 生成。

**完整文件**：

```bash
#!/usr/bin/env bash
# 用途：准备 Master Course Gateway Sample 的固定运行依赖。
# 工作目录：可从任意目录启动；脚本按自身位置定位 FlyWow、Server 和课程目录。
# 调用：bash /absolute/path/to/skynet-flywow/gateway/sample/master_course/bootstrap.sh
# 输入：Server 的版本清单、Skynet/Lua protobuf 固定源码版本及 FlyWow Gateway Native 源码。
# 输出：Skynet 可执行文件、protoc、lua-protobuf pb.so 和 Gateway Crypto Native 运行产物。
# 过程：只在对应产物缺失时编译；固定源码准备脚本负责版本核对，版本冲突时明确失败。
# 不负责：不安装系统软件、不启动 Gateway、不修改 Skynet 或其他第三方源码。
# Bash 语法：$0 是当前脚本路径；dirname 取脚本目录；命令替换 $(...) 把 pwd 输出作为路径文本。
# Bash 语法：[[ -x 文件 ]] 判断文件可执行，[[ -s 文件 ]] 判断文件存在且非空；! 表示条件取反。
# Bash 语法：&& 要求左边成功后再执行右边；|| 在左边失败时执行右边；set -euo pipefail 让未处理的失败尽早终止。
set -euo pipefail

# 由脚本所在位置推导各仓库根目录，因此从其他目录调用也使用同一套依赖路径。
COURSE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FLYWOW_ROOT="$(cd -- "$COURSE_DIR/../../.." && pwd)"
SERVER_ROOT="$(cd -- "$FLYWOW_ROOT/../.." && pwd)"
SKYNET_ROOT="$SERVER_ROOT/third_party/skynet"

# for 会把列表中的工具名逐个放进 tool；例如第一轮 tool=curl、下一轮 tool=python3。
# command -v 在 PATH 中查找该命令；重定向丢弃探测输出，只保留成功或失败状态。
# 检查本课程后续会直接使用的构建和运行命令。
for tool in bash curl python3 tar cmake make cc c++ node timeout; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '缺少必需工具：%s\n' "$tool" >&2
        exit 1
    fi
done

# 固定版本 Bootstrap 会验证已准备的源码；若源码不存在，则下载锁定版本快照。
bash "$SERVER_ROOT/scripts/linux/bootstrap_skynet.sh"
bash "$SERVER_ROOT/scripts/linux/bootstrap_protocol_tools.sh"

# Skynet 的 bundled Lua ABI 是 pb.so 的编译依据；仅在可执行文件缺失时构建 Skynet。
if [[ ! -x "$SKYNET_ROOT/skynet" || ! -s "$SKYNET_ROOT/3rd/lua/lua.h" ]]; then
    bash "$SERVER_ROOT/scripts/linux/build_skynet.sh"
fi

# lua-protobuf 需要匹配刚检查的 Skynet Lua 头文件；只在运行库缺失时编译。
if [[ ! -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]]; then
    bash "$SERVER_ROOT/scripts/linux/build_lua_protobuf.sh"
fi

# Gateway Crypto 由 FlyWow 已有统一构建脚本生成；限定 gateway 模块避免构建无关 Native。
if [[ ! -s "$FLYWOW_ROOT/build/native/flywow_gateway_crypto.so" ]]; then
    bash "$FLYWOW_ROOT/scripts/build_flywow.sh" "$SKYNET_ROOT" gateway
fi

# 再检查所有本课程运行时会加载的产物；失败时指出应当存在的具体文件。
if [[ ! -x "$SKYNET_ROOT/skynet" || ! -s "$SKYNET_ROOT/3rd/lua/lua.h" ]]; then
    printf 'Skynet 构建后仍不可执行：%s/skynet\n' "$SKYNET_ROOT" >&2
    exit 1
fi
if [[ ! -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]]; then
    printf 'lua-protobuf 构建产物缺失：%s\n' "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" >&2
    exit 1
fi
if [[ ! -s "$FLYWOW_ROOT/build/native/flywow_gateway_crypto.so" ]]; then
    printf 'Gateway Crypto 构建产物缺失：%s\n' "$FLYWOW_ROOT/build/native/flywow_gateway_crypto.so" >&2
    exit 1
fi

printf 'GATEWAY_MASTER_COURSE_PREPARE_OK\n'
```

### 2.4 亲手新建 `run.sh`

路径：`gateway/sample/master_course/run.sh`。这个脚本只编排**本课程**：`prepare` 调用 `bootstrap.sh` 准备依赖；普通运行检查固定产物、生成本课协议并启动真实 Skynet。命令 `bash .../run.sh websocket server` 仅在前台启动服务器，供分阶段实验；省略 `server` 时运行客户端并等待服务正常退出。`tcp` 模式使用同一 WorldService、协议和进程入口。

```bash
#!/usr/bin/env bash
# 用途：构建 Gateway 课程协议并启动服务端，或启动客户端完成一次 WebSocket/TCP 示例。
# 工作目录：可从任意目录运行；脚本根据自身位置查找 FlyWow、Server 和 Skynet，不依赖调用者当前目录。
# 参数：prepare 独立准备依赖；运行模式下第一个参数是 websocket/tcp（默认 websocket），第二个是 client/server（默认 client）。
# 示例：bash /path/to/skynet-flywow/gateway/sample/master_course/run.sh prepare
# 示例：bash /path/to/skynet-flywow/gateway/sample/master_course/run.sh websocket client
# 示例：bash gateway/sample/master_course/run.sh tcp server
# 前置条件：固定 Skynet、宿主 lua-protobuf、FlyWow Gateway Native 和 Node.js 均已构建/安装。
# 行为：client 模式会启动临时服务、运行客户端并在退出时清理服务；server 模式以前台方式运行服务。
# Bash 语法：变量用 "$NAME" 引用；双引号保护空格；# 开头是注释；本脚本用缩进展示 if/for 函数块。
# Bash 语法：[[ ... ]] 是条件判断；&& 表示前项成功后继续；|| 表示前项失败时执行后项。
# Bash 语法：$(命令) 捕获命令输出；${变量:-默认值} 在变量未设置时采用默认值；for 循环中的 _ 表示本脚本不需要循环序号。
# Bash 语法：>&2 把错误信息写到标准错误；> 与 2>&1 分别重定向标准输出和标准错误。
# Bash 语法：& 将进程放到后台；$! 是最近后台进程的 PID；trap 在脚本退出时执行清理函数；exec 用程序替换当前脚本进程。
set -euo pipefail

# 计算脚本和依赖仓库的绝对路径。dirname "$0" 取得脚本所在目录；cd 后用 pwd 得到绝对路径。
# -- 结束 cd 的选项解析，避免路径以短横线开头时被当成选项。
COURSE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FLYWOW_ROOT="$(cd "$COURSE_DIR/../../.." && pwd)"
SERVER_ROOT="$(cd "$FLYWOW_ROOT/../.." && pwd)"
SKYNET_ROOT="$SERVER_ROOT/third_party/skynet"

# ${1:-} 在没有第一个参数时展开为空；只有第一个参数恰好是 prepare 才进入准备分支。
# 例如 run.sh prepare 调用 bootstrap；不带参数会继续使用默认 websocket/client 运行模式。
# $# 表示位置参数个数；此分支只接受一个参数。exec 用 bootstrap 替换当前 Shell，并沿用其退出状态。
if [[ "${1:-}" == "prepare" ]]; then
    if [[ "$#" -ne 1 ]]; then
        echo "prepare 不接受其他参数；用法：bash run.sh prepare" >&2
        exit 2
    fi
    exec bash "$COURSE_DIR/bootstrap.sh"
fi

# Bash 把脚本名后面的参数按顺序编号：$1 是第一个参数（传输方式），$2 是第二个参数（启动方式）。
# ${1:-websocket} 的意思是：如果没有给第一个参数，或第一个参数是空字符串，就把 MODE 设为 websocket；否则使用第一个参数原值。
# 例如：run.sh tcp client 会令 MODE=tcp；只运行 run.sh 会令 MODE=websocket。
MODE="${1:-websocket}"

# ${2:-client} 同理：没有给第二个参数或它为空时，ACTION 取 client；否则取第二个参数原值。
# 例如：run.sh tcp server 会令 ACTION=server；run.sh websocket 或只运行 run.sh 都会令 ACTION=client。
ACTION="${2:-client}"

# 只接受本课程支持的两种传输和两种启动方式；错误时打印用法并以状态码 2 结束。
if [[ "$MODE" != websocket && "$MODE" != tcp ]]; then
    echo "第一个参数只能是 websocket 或 tcp" >&2
    echo "用法：bash run.sh [websocket|tcp] [client|server]" >&2
    exit 2
fi
if [[ "$ACTION" != server && "$ACTION" != client ]]; then
    echo "第二个参数只能是 client 或 server" >&2
    echo "用法：bash run.sh [websocket|tcp] [client|server]" >&2
    exit 2
fi

# -x 检查 Skynet 文件存在且可执行；-s 检查依赖文件存在且大小大于零。
# 缺少构建产物时提前退出，避免启动到一半才出现加载错误；首次使用请运行 `bash run.sh prepare`。
if [[ ! -x "$SKYNET_ROOT/skynet" ]]; then
    echo "请先构建固定 Skynet：$SKYNET_ROOT/skynet" >&2
    exit 1
fi
if [[ ! -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]]; then
    echo "请先构建宿主 lua-protobuf：$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" >&2
    exit 1
fi
if [[ ! -s "$FLYWOW_ROOT/build/native/flywow_gateway_crypto.so" ]]; then
    echo "请先构建 Gateway Native：$FLYWOW_ROOT/build/native/flywow_gateway_crypto.so" >&2
    exit 1
fi

# 先用课程目录中的脚本生成 Descriptor 和 Registry；bash 显式调用它，不要求它有可执行权限。
bash "$COURSE_DIR/build_protocol.sh"

# export 让新启动的 Skynet Service 也能读取传输类型和端口环境变量。
# 若调用者已设置端口则沿用，否则使用课程默认端口 19221。
export GATEWAY_COURSE_TRANSPORT="$MODE"
# 端口环境变量未设置或为空时使用 19221；例如 GATEWAY_COURSE_PORT=19300 会让服务端和客户端都使用 19300。
export GATEWAY_COURSE_PORT="${GATEWAY_COURSE_PORT:-19221}"

# Skynet 配置中的相对路径以 Server 根目录为基准，所以启动前切换到该目录。
cd "$SERVER_ROOT"

# server 模式将当前 Bash 进程替换为 Skynet，并以前台方式运行。
# exec 后脚本不会继续执行，下面 client 模式的后台进程和 cleanup 逻辑都不会参与；按 Ctrl+C 可停止前台 Skynet。
if [[ "$ACTION" == server ]]; then
    exec "$SKYNET_ROOT/skynet" "$COURSE_DIR/skynet_config.lua"
fi

# client 模式把服务端日志写到 FlyWow build 目录，按传输方式分开保存。
# mkdir -p 会在目录不存在时创建它，目录已存在时不会报错。
LOG_DIR="$FLYWOW_ROOT/build/gateway-master-course/$MODE"
mkdir -p "$LOG_DIR"
SERVER_LOG="$LOG_DIR/server.log"

# client 模式需要同时运行服务端和客户端：Skynet 放在后台，Node 客户端稍后在前台运行。
# > 将服务端标准输出写入日志，2>&1 再把标准错误接到同一个日志；末尾的 & 让 Bash 不等待 Skynet 结束。
# $! 是刚刚启动的后台 Skynet 进程号，之后用它判断服务是否仍在运行并负责清理。
"$SKYNET_ROOT/skynet" "$COURSE_DIR/skynet_config.lua" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# cleanup 由当前 Bash Shell 调用，专门结束本脚本刚启动的 Skynet，不会按名称查找或关闭其他服务。
cleanup() {
    # kill -0 只探测进程是否存在，不发送信号；进程还活着时才发送 TERM 请求它退出。
    # 若进程已自行退出，跳过 kill，避免把正常完成报告成清理失败。
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
    fi

    # wait 回收这个后台子进程。这里忽略其退出状态，避免清理阶段覆盖脚本原本的失败原因。
    wait "$SERVER_PID" 2>/dev/null || true
}

# trap 把 cleanup 注册为当前 Bash 的 EXIT 钩子；Bash 正常结束或因 set -e 遇到未处理错误退出时都会调用它。
# 这不是 Skynet 或 Node 调用 cleanup；它们结束后只是让 Bash 继续或退出，最终由 Bash 执行钩子。
trap cleanup EXIT

# 等待服务在日志中报告就绪，最多 200 次，每次间隔 0.1 秒，合计约 20 秒。
# ready=0 表示目前还没找到就绪标记；找到后改为 1 并结束循环。
ready=0
for _ in $(seq 1 200); do
    if grep -q 'COURSE_GATEWAY_READY transport=' "$SERVER_LOG"; then
        ready=1
        break
    fi

    # 服务进程提前退出时打印完整日志，帮助定位启动错误，然后以失败状态结束。
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        cat "$SERVER_LOG" >&2
        exit 1
    fi

    sleep 0.1
done

# [[ ... ]] 在这里要求 ready 必须等于 1；否则报告启动超时并输出服务端日志。
if [[ "$ready" != 1 ]]; then
    cat "$SERVER_LOG" >&2
    echo "Gateway 就绪超时" >&2
    exit 1
fi

# 启动与传输模式对应的 Node 客户端。该命令没有 &，所以客户端在前台运行，Bash 会等它结束后才执行下面的代码。
# timeout 最多允许运行 20 秒；超时或客户端失败会产生非零退出状态，set -e 会结束脚本并触发上面的 EXIT 清理钩子。
# 端口作为客户端的第一个位置参数；客户端正常完成后进程退出，控制权回到当前 Bash。
if [[ "$MODE" == websocket ]]; then
    timeout 20s node "$COURSE_DIR/client/websocket_client.mjs" "$GATEWAY_COURSE_PORT"
else
    timeout 20s node "$COURSE_DIR/client/tcp_client.mjs" "$GATEWAY_COURSE_PORT"
fi

# 客户端完成后，WorldService 会在 disconnect 事件处理完后停止服务。
# 最多等 100 次、每次 0.1 秒；如果服务没有自行退出，则打印日志并报超时。
finished=0
for _ in $(seq 1 100); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        finished=1
        break
    fi
    sleep 0.1
done
if [[ "$finished" != 1 ]]; then
    cat "$SERVER_LOG" >&2
    echo "服务器退出超时" >&2
    exit 1
fi

# 服务端已从上面的进程检查中确认退出；wait 负责回收后台进程并取得其退出状态。
# Skynet 非零退出时，set -e 会让脚本失败并触发 cleanup；成功退出后继续核对课程完成标记。
wait "$SERVER_PID"
grep -q 'COURSE_GATEWAY_OK' "$SERVER_LOG"

# 输出完整服务端日志。此命令结束后 Bash 正常退出，仍会执行 EXIT 钩子；此时服务端已结束，cleanup 不会再发 TERM。
cat "$SERVER_LOG"
```

第 2 阶段先准备依赖并以前台启动服务：

```bash
bash gateway/sample/master_course/run.sh prepare
```

随后启动服务：

```bash
bash gateway/sample/master_course/run.sh websocket server
```

预期日志含 `COURSE_GATEWAY_READY transport=websocket port=19221 commands=2`。按 `Ctrl+C` 结束；**这个阶段不带客户端参数运行自动场景**，因为客户端及完整业务处理尚未编写。

### 2.4 真实源码跟踪：start 如何从一个 RPC 变成监听

**【真实源码】** `gateway/service/gateway/flywow_gateway.lua`：

```text
WorldService 的 skynet.start 协程
  -> skynet.newservice("gateway/flywow_gateway")
  -> skynet.call(gateway, "lua", "start", config)   [调用方挂起]
Gateway Service 自己的 Lua State
  -> skynet.start -> skynet.dispatch("lua", ...)
  -> start(config)
       -> normalize_config(config)
       -> require("world_registry")
       -> validate_generated_registry(generated)
       -> codec_module.new(...)     [读取 .pb，pb.load，校验消息类型]
       -> require("flywow_gateway_crypto")
       -> handshake_module.new(...)
       -> socket.listen(host, port, backlog)
       -> socket.start(listen_fd, accept_client)
       -> module_state.phase = "running"
       -> skynet.fork(timeout_loop)
       -> FlyWowResult<GatewayStartResult>
  -> skynet.retpack(result)
WorldService 的原调用协程被唤醒，继续检查 result.ok/value
```

这里必须注意两个不同的 `start`：`skynet.start` 是 **Service 入口初始化回调**；Gateway 的 `start(config)` 是**宿主发送的业务命令处理函数**。`skynet.call` 等待应答，不能把它与后面的请求投递 `skynet.send` 混淆。

`normalize_config` 先处理所有必需字段和默认值；例如 `transport="websocket"` 合法，`host=false` 不会被当成缺省地址。`validate_generated_registry` 只读校验生成表；`codec_module.new` 在当前 Gateway Lua State 里加载 Descriptor；Handshake manager 在本 Service 里持有握手名额，**此时还没有一个客户端连接**。

**回到主线**：只有 listener 创建且 `socket.start` 成功后才进入 `running`。`WorldService` 收到 Result 后才打印课程 READY；下一阶段才会发生 accept 和握手。

**阶段验收**：会区分构建期 Python 进程、WorldService Lua State、Gateway Lua State、Skynet socket driver，以及 `start` 调用中的等待关系。

---

### 2.5 源码精读：`module_state` 究竟属于谁

上一节的调用栈已经到达 Gateway 的 `start(config)`。现在暂停在 `start()` 入口，看它操作的模块级表。**【真实源码局部：`gateway/service/gateway/flywow_gateway.lua`，文件顶层】**：

```lua
local module_state =
{
    phase              = "created",
    gateway_config     = nil,
    registry           = nil,
    handshake          = nil,
    codec              = nil,
    listen_fd          = nil,
    connections        = {},
    connections_by_fd  = {},
    next_connection_id = 0,
    rate_started       = 0,
    rate_count         = 0,
    epoch              = nil,
    client_count       = 0,
}
```

这只是原文件中的状态表片段，**已去掉逐字段源码注释**；详细说明应以源码本身为准。它在 Gateway Service 的 Lua State 加载时创建。WorldService 另有自己的 `state`，两份 table 没有共享引用。不同 OS Worker Thread 可以执行不同 Service 的消息，但不能把这个 `module_state` 理解成多线程共享的全局 C++ 单例。

| 状态                 | 写入者/时机          | 真正消费者                      | 生命周期               |
| -------------------- | -------------------- | ------------------------------- | ---------------------- |
| `phase`              | `start`/`stop`       | `accept_client`、超时与出站入口 | 当前 Gateway Service   |
| `gateway_config`     | `start` 校验后设置   | 网络、握手、限流入口            | 启动后到停止           |
| `registry` / `codec` | `start` 装载         | `dispatch_payload` / 出站编码   | 当前 Gateway Lua State |
| `handshake`          | `start` 构造 manager | 每个连接的握手与 detach         | 当前 Gateway Service   |
| `listen_fd`          | 监听成功后持有       | `stop`                          | 监听期                 |
| `connections`        | 创建/摘除连接        | 出站单播、广播、超时、stop      | 每条连接登记期         |
| `connections_by_fd`  | 创建/摘除连接        | WS 回调、关闭安全检查           | 每条连接登记期         |
| `epoch`              | `start` 生成         | 识别旧实例的消息                | 当前 Service 实例      |
| `client_count`       | 连接登记 / detach    | `max_clients` 检查              | 当前 Service 实例      |

**不要为了教学实现另一张表。** 这份表就是课程后面全部状态实验的唯一源码入口。

### 2.6 逐段追 `start()`：何时才能宣布 READY

执行现场：WorldService 的启动协程已向 Gateway 发出 `skynet.call(gateway,"lua","start",config)`，处于等待；Gateway 通过文件末尾的 `skynet.dispatch("lua", ...)` 收到 `start`，调用它自己的 `start(startup_config)`。此时还没有监听 fd，也没有连接上下文。

**【真实源码局部：`gateway/service/gateway/flywow_gateway.lua` / `start()`，初始化依赖阶段】**：

```lua
local config_result = normalize_config(startup_config)
if not config_result.ok then
    return config_result
end

local gateway_config = config_result.value
local generated_ok, generated = pcall(require, gateway_config.registry_module)
if not generated_ok then
    return flywow_result.failure(
        "GATEWAY_REGISTRY_LOAD_FAILED",
        tostring(generated),
        { module = gateway_config.registry_module }
    )
end
local registry_result = validate_generated_registry(generated)
if not registry_result.ok then
    return registry_result
end
```

`startup_config` 是从 WorldService 通过 Skynet RPC 传过来的**配置副本值**；`config_result.value` 才是 Gateway 通过 `normalize_config()` 验证过的配置记录。`generated` 是 `require("world_registry")` 返回的构建产物 table；`registry_result.value` 是校验时计算的命令数量；Gateway 与 Codec 直接共享 `generated`，不建立第二份查询索引。

后续真实调用为 `codec_module.new({descriptor_path, registry})`、`require("flywow_gateway_crypto")`、`handshake_module.new({crypto, now, max_pending, timeout_ticks})`。分别在运行时验证 Descriptor、初始化 Native 模块、建立握手管理器。任一步失败都返回 `FlyWowResult`，**不会提前创建 listener**。

**【真实源码局部：同一 `start()` / 监听和发布运行状态】**：

```lua
module_state.gateway_config = gateway_config
module_state.registry = registry
module_state.codec = codec
module_state.handshake = handshake
module_state.epoch = tostring(skynet.self()) .. ":" .. tostring(skynet.hpc())
module_state.phase = "starting"

local listen_ok, listen_fd, address, port = pcall(
    socket.listen,
    gateway_config.host,
    gateway_config.port,
    gateway_config.backlog
)
```

注意：这一段只是 `start()` 中间片段，**不是完整函数**。监听返回后还要检查阶段是否仍为 `starting`，保存 `listen_fd`，调用 `socket.start(listen_fd, accept_client)`，再检查阶段与 fd 所有权；这些判断让在 yield 中发生的 stop 不会被后续启动逻辑覆盖。

最后源码执行的是：

```lua
module_state.phase = "running"
skynet.fork(timeout_loop)
```

之后才生成 `FlyWowResult.success({address,port,transport,command_count})`，由 `skynet.retpack(start_result)` 应答 WorldService。**`socket.listen` 与 `socket.start` 可能 yield**；只有取得最终 Result 后，WorldService 才从 `skynet.call` 恢复，向日志打印课程 READY。

这里真正有三层独立的“就绪”：Skynet Service 已加载 Lua 入口、Gateway 已监听并进入 `running`、某一个客户端已完成应用握手进入 `ready`。它们不是同一个布尔值。

### 2.7 从 Skynet 源码解释为什么 `call` 会等待

打开固定版本 `cloudwu/skynet` `v1.8.0` 的 `lualib/skynet.lua`，找到 `skynet.call()`、`yield_call()` 和 `skynet.send()`。这里跨越了两个 Service、两份 Lua State 和 Skynet 消息队列。

**【真实源码局部：固定 Skynet `lualib/skynet.lua`】**：

```lua
function skynet.send(addr, typename, ...)
    local p = proto[typename]
    return c.send(addr, p.id, 0 , p.pack(...))
end

local function yield_call(service, session)
    watching_session[session] = service
    session_id_coroutine[session] = running_thread
    local succ, msg, sz = coroutine_yield "SUSPEND"
    watching_session[session] = nil
    if not succ then
        error "call failed"
    end
    return msg,sz
end
```

`skynet.call` 会先创建非零 session 并发送请求，再在 `yield_call` 建立 session→当前协程的关联并 yield；收到匹配 RESPONSE 后，Skynet 将该协程恢复。相对地 `skynet.send` 明确传入 `session=0`，不建立“等对方返回”的状态。`send` 成功返回值 `0` 也**不是业务 Service 对请求的响应**。

针对本课程画出的时间线：

```text
T0  WorldService 启动协程 : skynet.call(gateway,"lua","start",config)
T1  WorldService 启动协程 : yield，等待匹配 session 的响应
T2  Gateway 消息分发协程 : 接收 "start"，执行 start(config)
T3  Gateway 消息分发协程 : 完成监听，skynet.retpack(result)
T4  WorldService 启动协程 : 因该 RPC RESPONSE 恢复，检查 result.ok
T5  Gateway 后续连接协程 : 另一次 accept 才创建 connection
```

这解释了：Gateway 启动阶段使用 `call` 可以确保宿主知道启动成功与否；业务请求阶段反而要用 `send`，因为 Gateway 不应该等待每个玩家业务处理完成。

**小实验**：把课程配置中的 `registry_module` 临时改为不存在的值，重启。预期打印启动失败码而不是 READY；因为失败 Result 也是正常 RPC 应答，WorldService 的 `call` 会恢复。然后恢复配置，继续第三阶段。

**返回主线**：到这里 WorldService 得到了 `gateway` handle，Gateway 的 `module_state.phase` 是 `running`，`connections` 仍为空。下一阶段客户端连接后，`accept_client` 将成为入口。

---

# 第三阶段：完成握手并让第一条业务请求往返

## 3. 第一个可观测的请求

接下来让玩家 A 发出 `EnterWorldRequest{player_id=1001}`，服务端应返回 `EnterWorldResponse{player_id=1001,scene_id=7,online_count=1}`。

为了第四阶段直接接入 B 和 Push，本阶段一次把 WorldService 的最终处理逻辑写全；先只分析 A 的正常请求，第四阶段再走 B 的分支。这让服务端示例始终是一份完整可运行文件，不在各阶段维护多个难以拼接的片段。

### 3.1 完整替换 `service/world_service.lua`

**修改位置**：`gateway/sample/master_course/service/world_service.lua`。删除第二阶段的启动版，**完整替换为以下文件**。业务部分也在同一个 WorldService 的 Lua State 中执行；`connections` 仅保存“逻辑连接编号 → 示例玩家 ID”的业务关联，不是 fd 索引。Gateway 的 `connection_id` 只在本次 `gateway_epoch` 内有效。

```lua
--- 课程宿主：启动一个 Gateway、处理新手村进入、单播/广播并观察连接关闭。
local skynet = require "skynet"
require "skynet.manager"

local HANDLER_NAME = ".gateway_course_world" -- Gateway 异步投递业务消息使用的固定本地 Service 名。
local COMMAND_ENTER_WORLD = 1001 -- EnterWorldRequest/EnterWorldResponse 使用同一个 command。
local COMMAND_NOTICE = 1002 -- SystemNoticeResponse 只允许服务器主动下发。
local state =
{
    gateway = nil, -- 本 Service 创建的 Gateway handle；所有出站消息都发送到它。
    players = {}, -- Gateway 逻辑 connection_id -> 已进入新手村的 player_id；收到 disconnect 时删除。
    online_count = 0, -- 本课程新手村已进入且未断开的玩家数。
    disconnected = 0, -- 本轮实际完成进入后又收到 disconnect 的玩家数；达到 2 用于结束样例。
}

--- 将一个业务 Response 或 Push 异步交给 Gateway；是否真正写到网络由 Gateway 决定。
---@param epoch string 入站请求给出的当前 Gateway 实例身份；广播也要使用它。
---@param connection_id integer 正数表示指定连接，0 表示向本 Gateway 全部 ready 连接广播。
---@param command_id integer Registry 中定义了 response_type 的命令编号。
---@param data table 本次响应或公告消息的 Protobuf 字段 table。
---@return nil 只提交 Skynet 异步消息，不等待客户端回包。
local function send_to_gateway(epoch, connection_id, command_id, data)
    skynet.send(state.gateway, "lua", "send_data",
    {
        gateway_epoch = epoch, -- Gateway 用于拒绝上一轮实例的迟到消息。
        connection_id = connection_id, -- 此处不是底层 Socket fd。
        command_id    = command_id, -- 决定响应数据采用哪一种 protobuf 类型。
        data          = data, -- 由 Gateway 编码并填入 Envelope.body。
    })
end

--- Gateway 解出 EnterWorldRequest 后调用；业务记录只在当前 WorldService Lua State 中保存。
---@param request table Gateway 发来的记录，使用 gateway_epoch、connection_id、command_id、data。
---@return nil 发送业务响应；第二个玩家入场时额外发送单播和广播。
local function on_enter_world(request)
    if request.command_id ~= COMMAND_ENTER_WORLD or type(request.data) ~= "table" then
        skynet.error("COURSE_UNEXPECTED_COMMAND")
        return
    end

    local player_id = request.data.player_id -- 从 Protobuf 解码出来的演示玩家编号，并非鉴权身份。
    local connection_id = request.connection_id -- 当前 Gateway 分配的逻辑连接编号。
    if (player_id ~= 1001 and player_id ~= 1002) or state.players[connection_id] then
        skynet.error("COURSE_INVALID_PLAYER ", tostring(player_id))
        return
    end

    -- 业务 Service 只记录玩家与逻辑连接的对应，不持有也不操作网络 Socket。
    state.players[connection_id] = player_id
    state.online_count = state.online_count + 1
    skynet.error("COURSE_ENTER player=", player_id, " connection=", connection_id,
        " online=", state.online_count)

    send_to_gateway(request.gateway_epoch, connection_id, COMMAND_ENTER_WORLD,
    {
        player_id    = player_id, -- 说明本次完成进入的是哪一名演示玩家。
        scene_id     = 7, -- 固定的新手村场景编号。
        online_count = state.online_count, -- 此请求完成时的在线人数快照。
    })

    if player_id == 1002 then
        -- B 入场后先向 B 单播；随后向本 Gateway 的两条 ready 连接广播。
        send_to_gateway(request.gateway_epoch, connection_id, COMMAND_NOTICE,
        {
            content = "欢迎玩家1002", -- 只有 B 能收到的定向消息。
        })
        send_to_gateway(request.gateway_epoch, 0, COMMAND_NOTICE,
        {
            content = "新手村已开放", -- 连接编号 0 是广播约定，不是玩家 0。
        })

        -- 给出站消息留下一个小的可观察窗口，然后使用 Gateway 公开 close 命令断开 B。
        local epoch = request.gateway_epoch -- 延迟回调必须沿用收到 B 请求时的 Gateway 实例身份。
        local target_id = connection_id -- 延迟回调仅操作 B 的逻辑连接，不能拿 Socket fd 当身份。
        skynet.timeout(30, function()
            skynet.send(state.gateway, "lua", "close",
            {
                gateway_epoch = epoch, -- 拒绝旧 Gateway 实例的迟到关闭命令。
                connection_id = target_id, -- 仅要求 Gateway 关闭玩家 B 的连接。
            })
            skynet.error("COURSE_CLOSE_B_REQUESTED")
        end)
    end
end

--- Gateway 摘除连接后通知宿主；只清理由本业务 Service 保存的玩家关系。
---@param message table 读取 Gateway 发来的 connection_id 和 gateway_epoch；本例只有一个 Gateway 实例。
---@return nil 未进入的握手失败连接不影响业务在线人数。
local function on_disconnect(message)
    local player_id = state.players[message.connection_id] -- 可能不存在：握手阶段的失败连接同样会通知断开。
    if not player_id then
        return
    end

    state.players[message.connection_id] = nil
    state.online_count = state.online_count - 1
    state.disconnected = state.disconnected + 1
    skynet.error("COURSE_DISCONNECT player=", player_id,
        " online=", state.online_count)
end

skynet.start(function()
    -- 先注册 handler，再创建和启动 Gateway；否则请求可能没有接收方。
    skynet.name(HANDLER_NAME, skynet.self())
    skynet.dispatch("lua", function(session, _, command, message)
        if command == "send_data" then
            on_enter_world(message)
        elseif command == "gateway_disconnect" then
            on_disconnect(message)
        else
            skynet.error("COURSE_UNEXPECTED_SERVICE_MESSAGE ", tostring(command))
        end

        if session ~= 0 then
            skynet.retpack(true)
        end
    end)

    state.gateway = skynet.newservice("gateway/flywow_gateway")
    local transport = os.getenv("GATEWAY_COURSE_TRANSPORT") or "websocket" -- Shell 选择本次使用 WS 或 TCP。
    local port = tonumber(os.getenv("GATEWAY_COURSE_PORT")) or 19221 -- 宿主选取的本地端口。
    local config =
    {
        host                          = "127.0.0.1", -- 仅允许本机连接。
        port                          = port, -- 本轮 Gateway 监听端口。
        transport                     = transport, -- 每个实例只使用一种 transport。
        handler_service               = HANDLER_NAME, -- 此 Service 已注册的本地名字。
        descriptor_path               = "./third_party/skynet-flywow/gateway/sample/master_course/generated/world.pb", -- 当前课程构建的 descriptor。
        registry_module               = "world_registry", -- 当前课程生成的 Lua Registry。
        protocol_version              = 4, -- Envelope 的业务协议版本。
        max_clients                   = 4, -- 本例最多同时接入 4 个客户端。
        max_requests_per_second       = tonumber(os.getenv("GATEWAY_COURSE_RPS")) or 200, -- 故障实验可缩小接纳速率。
        idle_timeout_ticks            = tonumber(os.getenv("GATEWAY_COURSE_IDLE_TICKS")) or 30000, -- 完整业务消息空闲期限，单位 10ms tick。
    }

    -- 这是等待 Gateway 返回 Result 的控制面 call；它与请求处理阶段的 send 不同。
    local result = skynet.call(state.gateway, "lua", "start", config)
    if not result.ok then
        skynet.error("COURSE_START_FAILED ", result.code, " ", result.message)
        skynet.abort()
        return
    end
    skynet.error("COURSE_GATEWAY_READY transport=", result.value.transport,
        " port=", result.value.port, " commands=", result.value.command_count)

    -- 两位已经进入过新手村的玩家均断开后，走 Gateway 正式 stop 合同并结束课程进程。
    skynet.fork(function()
        for _ = 1, 300 do
            if state.disconnected == 2 then
                local stop_result = skynet.call(state.gateway, "lua", "stop") -- 停止 listener，返回本次关闭连接数量。
                if not stop_result.ok then
                    skynet.error("COURSE_STOP_FAILED ", stop_result.code)
                    os.exit(1)
                end
                skynet.error("COURSE_GATEWAY_OK closed=", stop_result.value.closed_connections)
                io.stdout:flush()
                io.stderr:flush()
                os.exit(0)
            end
            skynet.sleep(10)
        end
        skynet.error("COURSE_TIMEOUT_WAITING_FOR_TWO_DISCONNECTS")
        os.exit(1)
    end)
end)
```

**上下文检查**：此文件没有创建额外 PlayerService/Manager，也没有账号表、存储层或业务重试。`state.players` 只关联当前两个连接；`gateway_disconnect` 对尚未进入的连接是正常可达路径，因此忽略它。`state.disconnected` 只用于本示例在两人实际退出后结束进程，**不是 Gateway 内部状态**。

## 4. 写一个没有第三方 Node Protobuf 依赖的最小客户端编解码器

正式商业客户端应使用对应 `.proto` 生成的 Protobuf SDK。本教程只使用 `uint32/string/bytes` 三种基础字段，为了让网络上到底发送了哪些字节更直观，用一个小文件手写本示例所需的 wire format。它**不替代 Gateway 的真实 `pb` Codec**，也不扩张成通用 Protobuf 框架。

### 4.1 亲手新建 `client/protobuf.mjs`

此文件被 WebSocket 和 TCP 两个真实客户端共同使用。`encodeEnterWorld()` 生成的 `Uint8Array` 是不带 TCP 长度头、也不带 WebSocket 帧头的完整 Envelope；TCP 的 2-byte framing 由 TCP 客户端另外添加。

```javascript
const utf8 = new TextDecoder(); // 将课程公告的 bytes 字段解释为 UTF-8 字符串。

// 拼接短字节片段，保留每段原始字节，不做 JSON/hex 转换。
function join(...parts) {
    const out = new Uint8Array(parts.reduce((size, part) => size + part.length, 0));
    let offset = 0;
    for (const part of parts) {
        out.set(part, offset);
        offset += part.length;
    }
    return out;
}

// Protobuf 无符号 uint32 的 varint 编码；本例只使用合法 uint32。
function varint(number) {
    const out = [];
    let n = number >>> 0;
    while (n >= 128) {
        out.push((n & 127) | 128);
        n >>>= 7;
    }
    out.push(n);
    return Uint8Array.from(out);
}

function integerField(number, value) {
    return join(varint(number * 8), varint(value));
}

function bytesField(number, bytes) {
    return join(varint(number * 8 + 2), varint(bytes.length), bytes);
}

// 供故障实验自定义协议版本或命令号；正常调用方只使用 encodeEnterWorld。
export function encodeEnvelope(command, body, version = 4) {
    return join(integerField(1, version), integerField(2, command), bytesField(3, body));
}

export function encodeEnterWorld(playerId, version = 4) {
    return encodeEnvelope(1001, integerField(1, playerId), version);
}

// 解码本课程会出现的 varint 与 length-delimited 字段，并拒绝截断输入。
function parseFields(bytes) {
    const data = new Uint8Array(bytes);
    const fields = new Map();
    let pos = 0;
    function readVarint() {
        let result = 0;
        let shift = 0;
        for (let i = 0; i < 5; ++i) {
            if (pos >= data.length) throw new Error("TRUNCATED_VARINT");
            const byte = data[pos++];
            result += (byte & 127) * 2 ** shift;
            if ((byte & 128) === 0) return result >>> 0;
            shift += 7;
        }
        throw new Error("INVALID_VARINT");
    }
    while (pos < data.length) {
        const tag = readVarint();
        const field = tag >>> 3;
        const wire = tag & 7;
        if (field === 0) throw new Error("INVALID_FIELD_NUMBER");
        if (wire === 0) {
            fields.set(field, readVarint());
        } else if (wire === 2) {
            const size = readVarint();
            if (pos + size > data.length) throw new Error("TRUNCATED_BYTES");
            fields.set(field, data.subarray(pos, pos + size));
            pos += size;
        } else {
            throw new Error("UNSUPPORTED_WIRE_TYPE");
        }
    }
    return fields;
}

// 根据 Envelope.command 区分服务器的 EnterWorldResponse 和 SystemNoticeResponse。
export function decodeServerMessage(bytes) {
    const envelope = parseFields(bytes);
    if (envelope.get(1) !== 4) throw new Error("UNEXPECTED_PROTOCOL_VERSION");
    const command = envelope.get(2);
    const body = parseFields(envelope.get(3));
    if (command === 1001) {
        return {
            command, // 与入站请求共用 1001。
            playerId: body.get(1), // 服务器确认进入新手村的玩家编号。
            sceneId: body.get(2), // 示例场景 ID。
            onlineCount: body.get(3), // 本次进入时的在线人数。
        };
    }
    if (command === 1002) {
        return { command, content: utf8.decode(body.get(1)) };
    }
    throw new Error("UNEXPECTED_SERVER_COMMAND: " + command);
}
```

**手算一组字节**：`EnterWorldRequest{player_id=1001}` 的字段 1 tag 为 `0x08`，1001 的 varint 为 `E9 07`；因此 body 是 `08 E9 07`。外层 Envelope 的版本字段为 `08 04`，command `1001` 为 `10 E9 07`，bytes body tag 为 `1A`，长度为 `03`。最终 Envelope 是：

```text
08 04 10 E9 07 1A 03 08 E9 07
```

这 10 字节是**业务 Envelope**。走 TCP 时还要再加 `00 0A` 两字节长度头；走 WebSocket 时它是单条 WebSocket binary message 的 payload，**不另外加 TCP 头**。后面会拿同一组数据对比 `ws_handler.message()` 与 `run_tcp()`。

### 4.2 亲手新建 `client/world_scenario.mjs`

此文件只组织本课程的**两名玩家真实业务流程**，由 WS/TCP 各自注入连接函数；不用额外的 PlayerManager。注意 Node `next()` 是测试代码等待网络消息，和 Gateway 是否 `skynet.call` 是两码事。

```javascript
import { encodeEnterWorld, decodeServerMessage } from "./protobuf.mjs";

// 为一条真实客户端连接建立消息邮箱；onmessage 收到完整 Envelope 后再交给测试断言。
async function enter(connector, playerId) {
    const messages = []; // 当前客户端已经收到但还未被业务测试消费的消息。
    const waiters = []; // 当前尚未收到回复的 next() 调用。
    const transport = await connector(bytes => {
        const message = decodeServerMessage(bytes);
        console.log(`玩家${playerId}收到`, message);
        if (waiters.length) waiters.shift()(message);
        else messages.push(message);
    });
    transport.send(encodeEnterWorld(playerId));
    return {
        next() {
            if (messages.length) return Promise.resolve(messages.shift());
            return new Promise(resolve => waiters.push(resolve));
        },
        close: () => transport.close(),
    };
}

function check(ok, explanation) {
    if (!ok) throw new Error("COURSE_CLIENT_ASSERT: " + explanation);
}

// A 进入 -> B 进入 -> B 单播 -> 两人广播 -> A 主动退出；B 由服务器主动关闭。
export async function runWorldScenario(connector) {
    const a = await enter(connector, 1001);
    const aJoin = await a.next();
    check(aJoin.command === 1001 && aJoin.playerId === 1001 &&
        aJoin.sceneId === 7 && aJoin.onlineCount === 1, "玩家 A 进入结果");

    const b = await enter(connector, 1002);
    const bJoin = await b.next();
    check(bJoin.command === 1001 && bJoin.playerId === 1002 &&
        bJoin.sceneId === 7 && bJoin.onlineCount === 2, "玩家 B 进入结果");

    const bPrivate = await b.next();
    check(bPrivate.command === 1002 && bPrivate.content === "欢迎玩家1002", "B 单播");

    const aPublic = await a.next();
    const bPublic = await b.next();
    check(aPublic.command === 1002 && aPublic.content === "新手村已开放", "A 收到广播");
    check(bPublic.command === 1002 && bPublic.content === "新手村已开放", "B 收到广播");

    a.close();
    console.log("COURSE_CLIENT_OK 两人响应、B 单播、双人广播全部验证；A 主动退出，等待服务器关闭 B");
    // 不关闭 B：若服务端没有执行 close，Node 进程不会正常结束，run.sh 会超时失败。
}
```

### 4.3 亲手新建 `client/websocket_client.mjs`

**文件归属**：本课程客户端入口；它依赖的是生产代码 `gateway/clients/h5/handshake.mjs` 所提供的 `connectGateway()`，该 SDK 自己创建 WebSocket 并执行应用层握手。`connector(onmessage)` 只有完成 READY 校验才返回可发送业务数据的对象。

```javascript
import { connectGateway } from "../../../clients/h5/handshake.mjs";
import { runWorldScenario } from "./world_scenario.mjs";

const port = Number(process.argv[2] || 19221); // run.sh 指定的本机 Gateway WebSocket 端口。
const address = `ws://127.0.0.1:${port}`;

await runWorldScenario(onmessage =>
    connectGateway(address, { onmessage, timeoutMs: 10000 }));
```

> 从 `master_course/client/` 向上三层是 `gateway/`，所以 `../../../clients/h5/handshake.mjs` 指向真正的 FlyWow SDK，并非 Lesson 3 的演示脚本。

### 4.4 真正运行 WebSocket 双人流程

现在第四阶段所需的双人逻辑已经具备，可完整运行一次，用 A 的第一条响应开始分析：

```bash
bash gateway/sample/master_course/run.sh websocket
```

客户端**预期**依次看到：

```text
玩家1001收到 { command: 1001, playerId: 1001, sceneId: 7, onlineCount: 1 }
玩家1002收到 { command: 1001, playerId: 1002, sceneId: 7, onlineCount: 2 }
玩家1002收到 { command: 1002, content: '欢迎玩家1002' }
玩家1001收到 { command: 1002, content: '新手村已开放' }
玩家1002收到 { command: 1002, content: '新手村已开放' }
COURSE_CLIENT_OK ...
```

Server 日志（位于 `build/gateway-master-course/websocket/server.log`）**预期**含 `COURSE_ENTER player=1001`、`COURSE_ENTER player=1002`、两个 `COURSE_DISCONNECT` 和最终 `COURSE_GATEWAY_OK`。这些是预期标记，实际打印格式由 Skynet 日志封装决定；请以真实输出核对。

### 4.5 源码深挖（一）：从 Socket 到 READY

**【真实源码】**：

- `gateway/service/gateway/flywow_gateway.lua`：`accept_client(fd,peer)` → `websocket.accept(fd,ws_handler,"ws",peer)` → `ws_handler.handshake`/`ws_handler.message`。
- `gateway/lualib/handshake.lua`：`new`、`accept`、`receive`、`confirm`、`ready`、`close`。
- `gateway/native/gateway_crypto.cpp`：真实 P-256 ECDH、HKDF-SHA256、HMAC-SHA256。
- `gateway/clients/h5/handshake.mjs`：`HandshakeClient.begin/respond/complete` 和 `connectGateway`。
- 固定 Skynet `lualib/http/websocket.lua`：`M.accept`、`resolve_accept`、`read_frame`。

**按真实发生的顺序观察**：

1. Socket Driver 的 accept 事件交给 Gateway Service 的 `accept_client(fd,peer)`；它调用 `create_connection`，占用 `max_clients`/握手名额，建立 `connection_id=1` 与 `fd` 两张索引。
2. Gateway fork 一条 WebSocket 会话协程；`websocket.accept` 先 `socket.start`，做 HTTP Upgrade，然后回调 Gateway 的 `ws_handler.handshake`。此时**只是 WebSocket 升级成功，不代表业务握手 ready**。
3. 客户端 SDK 发送 **67 字节** `CLIENT_HELLO`。`ws_handler.message` 发现尚未 ready，调用 `process_handshake` → `handshake.receive` → Native。Gateway 把 **99 字节** `SERVER_CHALLENGE` 写给客户端。
4. 客户端 SDK 校验 challenge 并发送 **33 字节** `CLIENT_PROOF`。Gateway 验证证明，先写 **33 字节** `SERVER_READY`，再调用 `handshake.confirm` 进入 ready。
5. SDK 的 `complete` 验证服务端 HMAC，清除握手密钥引用；`connectGateway` Promise 此时才 resolve，业务代码才可 `send(Envelope)`。

四段字节合同：`67 → 99 → 33 → 33`。TCP 在每条应用握手消息外额外有 2 字节长度头，WebSocket 则是独立 binary message。

**执行环境**：客户端 Web Crypto 的 Promise 可能等待平台密码运算；服务端 Native 密码计算是 Gateway Service 内同步调用，不因为使用 C++ 就自动切到其他 OS 线程。Gateway 的 WebSocket 会话读 Socket 时可能 yield；独立的 `timeout_loop` 由 Skynet 调度。密钥 userdata 归该连接的 Handshake 上下文，连接 detach 时释放。

**回到主线**：`ws_handler.message` 完成握手处理后返回给 WebSocket `resolve_accept` 的读循环，等待**下一条完整 binary message**。A 的 `encodeEnterWorld(1001)` 下一条消息才进入业务 `dispatch_payload()`。

#### 4.5.1 拿到 fd 的第一行代码在哪里

先观察客户端 A 的 WebSocket 已建立但尚未 `connectGateway()` resolve。此时进入 Gateway Service 的 `accept_client(fd,peer)`，调用者是 **Skynet listener 的 accept 回调**，而不是 WorldService 的 `skynet.dispatch`。`fd` 是底层 Socket Driver 分配的整数，`peer` 是诊断用对端地址。

**【真实源码局部：`gateway/service/gateway/flywow_gateway.lua` / `accept_client()`】**：

```lua
if module_state.gateway_config.transport == "websocket" then
    local accepted = create_connection(fd, peer, "websocket")
    if not accepted then
        socket.close_fd(fd)
        return
    end

    accepted.read_started = skynet.now()
    skynet.fork(function()
        if accepted.closed then
            return
        end
        local call_succeeded, accepted_by_websocket, failure = pcall(
            websocket.accept, fd, ws_handler, "ws", peer
        )
        -- 此后还会检查 accept 结果并清理；这里没有展示整个分支。
    end)
    return
end
```

这段分出两条不同的执行路径：监听回调完成 `create_connection` 并启动一个协程后**直接返回**；真正的 WS Upgrade 和持续收消息都在新 fork 的协程中。`accepted.read_started` 的用途是让扫描协程在 Upgrade 期间检查读取超时；它不是客户端业务消息时间。

`create_connection(fd, peer, "websocket")` 发生在**底层 `websocket.accept` 接管 fd 之前**。失败时尚未进入 Skynet `socket_pool`，所以这里选择 `socket.close_fd(fd)`，与已接管连接使用的 `socket.close(fd)` 不同。

#### 4.5.2 两张连接索引为什么都存在

进入 `create_connection`（真实路径仍为 `gateway/service/gateway/flywow_gateway.lua`），按顺序做三件事：检查 `client_count` 和 `next_connection_id` 上限、通过 `module_state.handshake.accept()` 占一个握手名额、构造 `connection` 并同时登记两张索引。

**【真实源码局部：`create_connection()`，省略容量拒绝与日志分支】**：

```lua
local handshake_result = module_state.handshake.accept()
if not handshake_result.ok then
    return nil
end
local handshake = handshake_result.value
module_state.next_connection_id = module_state.next_connection_id + 1
local connection =
{
    handshake       = handshake,
    id              = module_state.next_connection_id,
    fd              = fd,
    peer            = peer,
    transport       = transport,
    close_requested = false,
    closed          = false,
    read_started    = nil,
    last_message    = skynet.now(),
    rate_started    = skynet.now(),
    rate_count      = 0,
}
module_state.connections[connection.id] = connection
module_state.connections_by_fd[fd] = connection
module_state.client_count = module_state.client_count + 1
```

所有字段均是一个 **GatewayConnection** 的属性，`handshake` 指向该连接自己的 HandshakeContext。上述摘录删除了源码中的逐字段注释以便聚焦，但记录字段和赋值顺序与仓库一致。

举例：A 的 fd 假设为 `18`，Gateway 给它逻辑连接号 `1`。此时两张表实际指向的是**同一个连接对象**：

```text
module_state.connections[1] -----------+
                                       +--> connectionA {id=1, fd=18, ...}
module_state.connections_by_fd[18] ----+
connectionA.handshake ----------------------> handshakeContextA {phase="hello", held=true}
```

这里没有复制两个对象；两张索引用于不同入口：WorldService 的出站命令拿的是 `connection_id`，所以查 `connections[1]`；WebSocket 回调给的是 `fd`，所以查 `connections_by_fd[18]`。将 `player_id=1001` 塞进这两张表会跨越网关与业务的职责边界。

**生命周期验证**：连接未 ready 就关闭时，也应从两张表删除并释放握手名额。你可以在第六阶段发送错误 HELLO，再看 `gateway_disconnect` 及后续新连接是否仍能被接受；不能因为失败发生在业务之前就假定它不会占资源。

#### 4.5.3 HTTP WebSocket Upgrade 与 FlyWow 应用握手的层次

进入固定 Skynet `v1.8.0` 的 `lualib/http/websocket.lua`，`M.accept()` 会调用 `socket.start(socket_id)`，创建 `ws_obj`，注册 warning，然后进入 `resolve_accept()`。这段逻辑在 **Gateway Service fork 的 WS 会话协程**中执行，读取网络时可能挂起。HTTP Upgrade 成功，`resolve_accept()` 调用 `try_handle(self,"handshake",header,url)`，触发 `ws_handler.handshake(id,...)`。

**【真实源码局部：固定 Skynet `lualib/http/websocket.lua` / `resolve_accept()`】**：

```lua
local header = err
try_handle(self, "handshake", header, url)
local recv_count = 0
local recv_buf = {}
local first_op
while true do
    if _isws_closed(self.id) then
        try_handle(self, "close")
        return
    end
    local fin, op, payload_data = read_frame(self)
    -- 接下来分流 close / ping / pong / message；这里仅展示进入读循环。
end
```

此处的 `"handshake"` 是**HTTP WebSocket 升级回调名称**，并不等于应用层的 P-256 握手完成。真实 `ws_handler.handshake()` 此时只清空 `connection.read_started` 并设置 `last_message`；它不会调用 `handshake.confirm()`。

之后客户端发来的 67 字节 HELLO 才被 `read_frame` 解成一条 `binary message`，经 `try_handle(self,"message",payload_data,op)` 进入 `ws_handler.message()`。

**回到调用者**：`ws_handler.handshake` 返回后，Skynet 的 `resolve_accept` 继续 while 读帧；`ws_handler.message` 返回后也是继续 while 读下一帧。Gateway 并没有另起一个线程执行 WS 回调。

#### 4.5.4 Handshake 的状态不是一个 ready 布尔值

**【真实源码：`gateway/lualib/handshake.lua` / `M.new()` 返回的 manager】**。`manager.accept()` 由 `create_connection` 调用；`manager.receive()` 由 `process_handshake` 调用；`manager.confirm()` 由 Gateway 在 SERVER_READY 写成功之后调用；`manager.close()` 在确认 ready 或连接 detach 时释放资源。

| `context.phase` | 客户端下一条消息     | 状态变更                                     | Native/名额状态                   |
| --------------- | -------------------- | -------------------------------------------- | --------------------------------- |
| `hello`         | `CLIENT_HELLO` 67B   | `receive()` 成功后变 `proof`                 | Native userdata 创建，pending=1   |
| `proof`         | `CLIENT_PROOF` 33B   | 验证成功后变 `confirm`                       | Native 擦除验证密钥，仍占握手名额 |
| `confirm`       | **不应再接收下一条** | SERVER_READY 写成功后 `confirm()` 变 `ready` | 归还 pending 名额                 |
| `ready`         | 业务 Envelope        | `ready()` 返回 true                          | 不再持有 Native 密钥              |
| `closed`        | 无                   | 失败释放/关闭                                | 令牌释放，拒绝继续推进            |

`pending` 是 `handshake.new()` 创建的**manager 闭包局部变量**，不是 `module_state.client_count`：

- `client_count` 统计已经登记的连接，包括 ready 和未 ready。
- `pending` 统计仍占用握手名额的连接；握手成功时即释放，连接可能继续在线很久。
- `context.held` 是令牌所有权标记，防止超时、出错和 Socket 断开重复扣减 `pending`。

**【真实源码局部：`gateway/lualib/handshake.lua` / `manager.receive()`，HELLO 分支】**：

```lua
if context.phase == "hello" then
    if bytes:byte(1) ~= 1 or bytes:byte(2) ~= 1 then
        manager.close(context)
        return flywow_result.failure(
            "HANDSHAKE_VERSION",
            "unsupported handshake message type or version"
        )
    end
    local call_succeeded, native_or_error, challenge_or_error =
        pcall(crypto.new, bytes)
    -- 失败后 manager.close(context)，返回 HANDSHAKE_CRYPTO。
    -- 成功分支如下：
    context.crypto = native_or_error
    context.phase = "proof"
    return flywow_result.success(
    {
        response_bytes = challenge_or_error,
        needs_confirmation = false,
    })
end
```

这里的 `crypto.new` 对应 Native 的公开 `new(hello)`，**不是 Lua 的 `handshake.new()`**。它返回 userdata 加 99 字节 challenge。失败时 Lua 状态机转换为 `FlyWowResult`，不会把 OpenSSL 异常作为业务响应抛给客户端。

**【真实源码局部：`gateway/lualib/handshake.lua` / `manager.receive()`，PROOF 分支与 `confirm()`】**：

```lua
context.phase = "confirm"
return flywow_result.success(
{
    response_bytes = ready_or_error,
    needs_confirmation = true,
})
```

上面发生在 `context.crypto.verify(...)` 验证成功之后。`manager.confirm()` 必须在确认仍为 `confirm`、未过期后才设置 `context.phase="ready"` 并调用 `manager.close(context)`，归还名额。这个顺序对应真实网络行为：**客户端看到的 SERVER_READY 证明已经被本地发送接口接受，Gateway 才允许业务包进入**。

#### 4.5.5 Gateway 是怎样决定何时调用 `confirm()` 的

执行现场重新回到 Gateway Service 的 `process_handshake(connection,bytes)`。它把 `connection.handshake` 和当前完整帧借给状态机；`handshake.receive` 不知道 Socket fd，也不负责写网络。

**【真实源码局部：`gateway/service/gateway/flywow_gateway.lua` / `process_handshake()`】**：

```lua
local handshake_result = module_state.handshake.receive(
{
    context = connection.handshake,
    bytes   = bytes,
})
if not handshake_result.ok then
    -- 记录原有错误码并返回失败 Result；调用者负责关闭连接。
end
local handshake_output = handshake_result.value
local response_bytes = handshake_output.response_bytes
-- TCP 用 socket.write 写长度头+response；WS 用 websocket.write 写 binary。
-- 若写入失败或连接已摘除，返回 HANDSHAKE_WRITE_FAILED。
connection.last_message = skynet.now()
if handshake_output.needs_confirmation then
    local confirm_result = module_state.handshake.confirm(connection.handshake)
    if not confirm_result.ok then
        return confirm_result
    end
end
return flywow_result.success()
```

这是**按实际源码顺序摘录的连续关键语句，中间写入分支做了注释省略**，不是一个可直接替换源码的函数。`connection.last_message` 是成功完成握手消息写入后的活动时间，和 `context.started`（绝对握手期限起点）不同。发送 CHALLENGE 不重置握手的绝对期限。

实际到达 `confirm` 时，`SERVER_READY` 已经生成并交给 `socket.write`/`websocket.write`，因此 `confirm()` 才把状态切到 `ready`。如果写失败，`process_handshake` 返回错误，`ws_handler.message` 或 `run_tcp` 沿失败路径关闭连接；没有“客户端提前发送业务包就自动缓存”的行为。

#### 4.5.6 Native 层究竟保存了什么，又什么时候释放

打开 `gateway/native/gateway_crypto.cpp`。入口是 `luaopen_flywow_gateway_crypto()`，它向 Lua 注册模块 `new` 以及 userdata 的 `verify/close`；不是直接向 Skynet 注册 Service。Lua 调用 `crypto.new(bytes)` 进入 C++ `createCryptoContext(lua_State*)`，成功时创建独占的 `CryptoContext`，调用 `buildChallenge()`。

**【真实源码局部：`gateway/native/gateway_crypto.cpp`】**：

```cpp
struct CryptoContext
{
    EVP_PKEY *server_key = nullptr;
    std::array<unsigned char, 32> proof_key = {};
    std::array<unsigned char, 32> transcript_hash = {};
    bool active = false;
    ~CryptoContext() noexcept;
};
```

这个 C++ record 由一个 Lua userdata 拥有。`buildChallenge()` 调用 OpenSSL EVP 生成 P-256 临时密钥对，验证客户端公钥点，计算原始 ECDH `Z`，再按合同生成：

```text
HELLO    = 01 01 + 客户端公钥65B
CHALLENGE= 02 01 + 服务端公钥65B + 32B随机挑战
T        = SHA256(HELLO || CHALLENGE)
Z        = ECDH(server_private, client_public) 原始32B
K        = HKDF-SHA256(Z, salt=随机挑战32B,
           info="flywow/handshake/v1" || T, length=32)
PROOF    = 03 + HMAC-SHA256(K,"client-proof" || T)
READY    = 04 + HMAC-SHA256(K,"server-ready" || T)
```

这段是**协议推导式，不是 C++ 源码**。`Z` 的作用域使用 RAII `SharedSecret` 析构时擦除；`server_key` 在 `buildChallenge` 成功后立即释放。此后 userdata 保存 `proof_key`、`transcript_hash` 和 `active=true`，等待客户端 proof。

客户端发回 PROOF 后，C++ `verify()` 用 `CRYPTO_memcmp` 比较客户端 HMAC，构造 READY，调用 `clearCryptoContext()` 擦除 `proof_key`/`transcript_hash` 并设置 `active=false`。`manager.confirm()` 再调用 `manager.close(context)`，将 userdata 引用清空、释放握手名额。

**正常与失败路径的清理必须区分**：正常情况下密钥在 `verify()` 成功时已经擦除，`confirm()` 负责转 ready 和释放 Lua 持有关系；非法公钥、错误 proof 或超时时，`manager.close()`/Native close 走失败清理。C++ userdata 的内存最终由 Lua GC 回收，`__gc` 的重复清理是幂等的；不能把“清理内部密钥”误说成“立即释放 Lua userdata 内存”。

最后返回客户端：`gateway/clients/h5/handshake.mjs` 的 `HandshakeClient.complete()` 用 Web Crypto 验证服务器证明，成功后把自身阶段切 `ready` 并清掉密钥引用；`connectGateway()` Promise 随后 resolve。**服务端 ready 与客户端 SDK ready 是两次不同的确认动作**。

#### 4.5.7 本阶段动手验证什么

保持现有客户端代码不变，先执行正常 WS 流程，再使用第六阶段实验 A 的错误 HELLO：

1. 正常流程中，观察 `FLYWOW_GATEWAY_OPEN`、`FLYWOW_GATEWAY_READY` 及第一条 `COURSE_ENTER` 的先后关系。前者的 `READY` 在真实日志里有 Gateway 监听 ready 与连接 ready 两类上下文，必须读出具体字段与时间，不应只按字符串混为一类。
2. 错误 HELLO `Uint8Array([99])`：它只有 1 字节，会在 `manager.receive` 的**长度检查**阶段得到 `HANDSHAKE_FRAME`，不会执行 `crypto.new`；若要验证 `HANDSHAKE_VERSION`，应先发送**67 字节**、但类型/版本不符的消息。这两个实验的触发位置完全不同。
3. 根据错误路径画出 `accept → handshake.accept → receive失败 → detach → handshake.close → transport close`，检查从未进入 WorldService 的请求也会触发 `gateway_disconnect`。

**返回主线**：A 握手后 `ws_handler.message` 返回 Skynet 的 WS 读循环，下一条完整 binary message 才进入 `dispatch_payload`。下面继续从这条入站业务包追踪到 WorldService。

---

### 4.6 源码深挖（二）：A 的业务请求如何穿过两个 Service

执行现场：A 已 ready，Gateway 收到上述 10 字节 Envelope。仍在 Gateway Service 的 WS 消息回调，**未进入 WorldService**。

**【真实源码】** `gateway/service/gateway/flywow_gateway.lua`：`ws_handler.message` → `dispatch_payload(connection,payload)`：

1. `#payload` 检查 `max_frame_bytes`；不是 Skynet 接收内存的硬上限。
2. `module_state.codec.decode_envelope(payload)` → `gateway/lualib/codec.lua` 中 `pb.decode(Envelope,bytes)`；得到版本 4、command 1001、三字节 body。
3. `module_state.registry.commands[1001]` → 直接查询生成表；得到 `.flywow.gateway.course.EnterWorldRequest`。
4. `module_state.codec.decode_request(definition,body)` → `pb.decode`，获得 `{player_id=1001}`。
5. 检查连接级/实例级每秒速率，刷新成功接纳的业务消息活动时间。
6. 构造 `inbound_request = {gateway_epoch,connection_id,peer,transport,command_id,data}`，以 `skynet.send(handler_service,"lua","send_data",inbound_request)` 异步投递。

**重要区分**：

```text
Gateway Lua State                         WorldService Lua State
-----------------                         ----------------------
dispatch_payload(connection,payload)
  codec/registry/限流
  skynet.send(".gateway_course_world", "lua", "send_data", request)
  return FlyWowResult.success()  ----->     skynet.dispatch("lua", ...)
                                           on_enter_world(request)
                                           state.players[connection_id] = 1001
                                           skynet.send(gateway,"lua","send_data", response)
                                             |
Gateway 接收新的消息 <-------------------------+
  deliver_outbound_message(response)
  -> codec.encode_response
  -> write_connection -> websocket.write
```

这里 **没有 Gateway 等待 WorldService 回包的 `skynet.call`，也没有保存 pending request 或 `request_id`**。WorldService 处理请求的时间不会延迟 Gateway 对这一请求的异步投递完成。两个 Service 的 Lua table 不共享内存，消息需要经过 Skynet 的序列化与投递。

**【真实源码】** `deliver_outbound_message` 校验 `gateway_epoch`、逻辑 `connection_id`、command 和 ready，调用 `codec.encode_response` 生成 Envelope，再通过 `write_connection` 发送。`WorldService` 的 `{player_id=1001,scene_id=7,online_count=1}` 经过其 Registry `response_type` 编码，客户端按 command 1001 重新解码。这才算完整的一次请求响应。

**阶段验收**：沿程序实际位置画出 Gateway 与 WorldService 的两条协程/消息执行链，明确哪里产生网络读等待、哪里 RPC 等待、哪里只有异步 send。能解释 `0` 代表 Skynet 普通 `send` 已接受投递，而不是业务已处理成功。

---

### 4.7 源码精读：10 字节请求从哪里变成业务 table

先把上节的 `encodeEnterWorld(1001)` 写成可见字节，避免把 `Envelope` 与 TCP framing 混淆。客户端从 `client/protobuf.mjs` 得到的完整 **Protobuf Envelope** 是：

```text
08 04                       Envelope.protocol_version = 4
10 E9 07                    Envelope.command = 1001
1A 03                       Envelope.body 长度 = 3
   08 E9 07                 EnterWorldRequest.player_id = 1001
-------------------------
总计 10B（无 TCP 长度头 / WS 帧头）
```

`10` 是十六进制字节 `0x10`，不是业务 command；Protobuf key 使用 `field_number << 3 | wire_type`。实际把它发进 WebSocket 时，`http.websocket` 已经拼出单条完整 binary message，Gateway 不再执行 TCP `read_exact(2)`。

当前执行上下文仍为 **Gateway Service** 的 WebSocket 会话协程，文件 `gateway/service/gateway/flywow_gateway.lua`，函数 `ws_handler.message(id,payload,"binary")`。它取 `module_state.connections_by_fd[id]`，再判断：

```lua
if module_state.handshake.ready(connection.handshake) then
    frame_result = dispatch_payload(connection, payload)
else
    frame_result = process_handshake(connection, payload)
end
```

这是两个互斥分支。A 已 ready，因此这条 10 字节消息不可能再被当作 `CLIENT_HELLO`；如果 SDK 在未 ready 时误发 Protobuf，Handshake 会依据当前固定长度/阶段拒绝。

#### 4.7.1 `dispatch_payload()` 第一段：帧和 Envelope

**【真实源码局部：`gateway/service/gateway/flywow_gateway.lua` / `dispatch_payload()`】**：

```lua
if connection.closed or #payload == 0 or
    #payload > module_state.gateway_config.max_frame_bytes then
    -- 记录 FRAME_LIMIT 并返回失败结果，原文件包含完整 log_event 构造。
end

local envelope_result = module_state.codec.decode_envelope(payload)
if not envelope_result.ok then
    -- 返回 ENVELOPE_DECODE，details.cause_code 保留 Codec 错误类别。
end
local envelope = envelope_result.value
if envelope.protocol_version ~= module_state.gateway_config.protocol_version then
    -- 返回 PROTOCOL_VERSION。
end
```

这一段分开三类错误：大小或空帧属于 `FRAME_LIMIT`；bytes 无法按 `Envelope` 解码属于 `ENVELOPE_DECODE`；成功解码但业务版本不兼容属于 `PROTOCOL_VERSION`。不能只说“解包失败”。本课的 10 字节成功得到 `envelope={protocol_version=4, command=1001, body=<3字节>}`；Lua 的 `body` 是 bytes string，还不是 `EnterWorldRequest` table。

`codec.decode_envelope` 来自 `gateway/lualib/codec.lua`，内部调用 `pb.decode(codec_config.registry.envelope_type,payload)`。`pb` 加载的类型描述来自第一阶段生成的 `.pb`，不会每帧再加载文件；失败被 `pcall(pb.decode,...)` 转成 `FlyWowResult`。

#### 4.7.2 第二段：Registry 决定如何解释 body

**【真实源码局部：同一 `dispatch_payload()`】**：

```lua
local definition = module_state.registry.commands[envelope.command]
if definition == nil then
    -- 记录 UNKNOWN_COMMAND 并返回失败 Result。
end

local request_result = module_state.codec.decode_request(
    envelope.command, definition, envelope.body
)
if not request_result.ok then
    -- 记录 REQUEST_DECODE 并返回失败 Result。
end
local request = request_result.value
```

`definition` 来自 `world_registry.lua` 的生成命令表。本例的 `request_type=".flywow.gateway.course.EnterWorldRequest"`，Codec 内部再调用 `pb.decode(definition.request_type,body)`，最终得到 `{player_id=1001}`。

如果客户端发送 `SYSTEM_NOTICE=1002`，Registry 能找到定义，但 `request_type=nil`。这时**不是 `UNKNOWN_COMMAND`**，而是 Codec 的 `decode_request` 按不支持入站类型返回错误，Gateway 对外记 `REQUEST_DECODE`。要能准确描述“命令号不存在”与“命令仅允许服务端下发”这两种失败。

#### 4.7.3 第三段：限流、活动时间和跨 Service 投递

只有成功完成两层解码，才进入连接级/实例级请求速率统计。`connection.rate_started/rate_count` 属于这一条连接；`module_state.rate_started/rate_count` 属于当前 Gateway Service。两者均按约 100 tick 的窗口检查，**只在通过上限后增加接纳计数**。

**【真实源码局部：同一 `dispatch_payload()`，省略前面两套计数窗口重置】**：

```lua
if connection.rate_count >= module_state.gateway_config.max_requests_per_second or
    module_state.rate_count >= module_state.gateway_config.max_total_requests_per_second then
    -- 记录 INGRESS_RATE_LIMIT 并返回失败 Result。
end
connection.rate_count = connection.rate_count + 1
module_state.rate_count = module_state.rate_count + 1
connection.last_message = now

local inbound_request =
{
    gateway_epoch = module_state.epoch,
    connection_id = connection.id,
    peer          = connection.peer,
    transport     = connection.transport,
    command_id    = envelope.command,
    data          = request,
}
local call_succeeded, send_result_or_error = pcall(
    skynet.send,
    module_state.gateway_config.handler_service,
    "lua", "send_data", inbound_request
)
```

`inbound_request` 是**跨 Service 消息**，不是网络上的 Protobuf Envelope。此刻它装有 `data={player_id=1001}` 和 Gateway 分配的逻辑连接身份；`peer`、`transport` 供业务定位来源，但不代表玩家已经通过身份认证。

接着代码判断 `not call_succeeded` 或 `send_result_or_error==nil/false`：失败记录 `HANDLER_SEND` 并返回失败 Result；成功时普通 Skynet `send` 返回 `0`，`dispatch_payload` 返回 `FlyWowResult.success()`。**成功只表示本地异步投递被 Skynet 接受**；业务还没完成，可能连 WorldService 的消息回调都还没执行。

回到 `ws_handler.message()`：收到成功 Result 便结束本次回调；Skynet 的 WS 循环继续下一条消息。**网关没有 `pending[request_id]`、没有等待业务回包的 RPC，也没有阻塞客户端 A 直到 WorldService 返回。**

### 4.8 在两份 Lua State 之间追踪一次请求与响应

注意这里不是普通 Lua 函数调用：`WorldService` 和 `Gateway` 通过 Skynet 消息队列传递值，业务消息的接收由各自 `skynet.dispatch("lua",...)` 执行。

```text
Gateway Service，Lua State G            WorldService，Lua State W
  WS 会话协程 G-read                       业务消息协程 W-msg
  │                                       │
  ├─ dispatch_payload                     │
  ├─ skynet.send(".gateway_course_world", ───> Skynet 投递消息
  │    "lua","send_data",record)         ├─ skynet.dispatch("lua",...)
  ├─ return success                       ├─ on_enter_world(record)
  └─ 回到 WS read_frame 等待下一帧          ├─ state.players[id]=1001
                                          ├─ send_to_gateway(epoch,id,1001,response)
                                          └─ skynet.send(gateway,"lua","send_data",...)
           Gateway 后续收到独立的出站消息 <───┘
  Gateway 另一条消息分发协程 G-send
  ├─ deliver_outbound_message(outbound)
  ├─ codec.encode_response(...)
  ├─ write_connection(...)
  └─ return（无业务 RPC 返回）
```

两个接收回调在各自的 Service 内调度，不能假设它们共用一次 C++ 调用栈。WorldService 的 `state.players` 也**不会因为 Gateway 把 `connection.closed=true` 而被自动修改**；只有 `gateway_disconnect` 消息在 WorldService 被处理之后才删除该玩家记录。

### 4.9 出站源码精读：为什么回包能找到原来的连接

现在从 WorldService 的 `send_to_gateway(epoch,connection_id,1001,data)` 返回到 Gateway Service 的 `skynet.dispatch`。该入口匹配 `command="send_data"`，调用 `deliver_outbound_message(outbound_message)`；和前面的入站同名 `send_data` **只代表宿主与网关互发的消息命令**，消息方向由发起者决定。

**【真实源码局部：`gateway/service/gateway/flywow_gateway.lua` / `deliver_outbound_message()`】**：

```lua
if not module_state.gateway_config or type(outbound_message) ~= "table" or
    outbound_message.gateway_epoch ~= module_state.epoch or
    module_state.phase ~= "running" then
    return
end

local definition = module_state.registry.commands[outbound_message.command_id]
if not definition or definition.response_type == nil then
    return
end
local encode_result = module_state.codec.encode_response(
    outbound_message.command_id,
    definition,
    module_state.gateway_config.protocol_version,
    outbound_message.data
)
```

此前还存在对 `connection_id/command_id/data` 的类型检查，此处为聚焦主线略去。出站先校验 `epoch`，防止上一 Gateway 实例迟到响应；再通过 `response_type` 选择 protobuf 类型并编码。`codec.encode_response` 在 `gateway/lualib/codec.lua` 中先 `pb.encode(EnterWorldResponse,data)`，再包 `{protocol_version=4,command=1001,body=...}` 并 `pb.encode(Envelope,...)`。

**【真实源码局部：同一函数的目标连接选择】**：

```lua
if outbound_message.connection_id == 0 then
    for _, connection in pairs(module_state.connections) do
        if not connection.closed and
            module_state.handshake.ready(connection.handshake) then
            write_connection(connection, encoded)
        end
    end
    return
end

local connection = module_state.connections[outbound_message.connection_id]
if not connection or connection.closed or
    not module_state.handshake.ready(connection.handshake) then
    return
end
write_connection(connection, encoded)
```

这个索引就是 `create_connection()` 里创建的 `connections[id]`。若 A 的旧 fd 被后来新客户端复用，旧 A 的逻辑 `connection_id` 也不会被复用；当 A 已 detach 时，`connections[旧id]` 不存在，所以出站消息会被丢弃，不可能“顺手发给使用同一个 fd 的新人”。

`write_connection()` 在 WS 分支调用 `websocket.write(fd,encoded,"binary")`，TCP 分支调用 `socket.write(fd,string.pack(">I2",#encoded)..encoded)`。写失败会记录 `WRITE_FAILED`、摘除连接，并 fork transport 关闭；成功也**只表示本地写操作成功**，不等于客户端应用已经消费响应。

### 4.10 这一条主线结束后，必须能独立推导的问题

**实验**：在第六阶段使用未知 command `9999`，再把它换成合法的服务端专用 command `1002`，对比 Gateway 产生的错误类别。再思考 A 收到 `EnterWorldResponse` 时是否可以证明 WorldService 一定按某个 `request_id` 取回缓存的请求——答案不能这样推导，因为 Gateway 没有这样的关联状态；本例是 WorldService 主动带连接身份发送另一条独立消息。

此节返回第四阶段主线：A 的请求与回包已经完成，B 接入后将触发相同的入站与出站流程；区别是单播和广播由 `connection_id` 的值决定。

---

# 第四阶段：双连接、单播、广播、主动关闭

## 5. 为什么不能把 player_id 当成 Socket id

第 3 阶段运行时已经能看到完整两人场景。现在不增添模块，只观察**同一次运行中的第二条连接**，并沿源码解释它为什么不会误发到玩家 A。

| 业务事实           | Gateway 实际管理的东西                                       | WorldService 保存的东西                      |
| ------------------ | ------------------------------------------------------------ | -------------------------------------------- |
| 玩家 A（1001）接入 | fd、当前实例的 `connection_id=1`（示意值）和 `gateway_epoch` | `players[1]=1001`                            |
| 玩家 B（1002）接入 | 另一条 fd、另一 `connection_id=2`（示意值）                  | `players[2]=1002`                            |
| 发送 B 私信        | `send_data` 按 `connection_id=2` 选目标                      | 业务决定公告内容                             |
| 广播               | `connection_id=0`，当前 Gateway 的 ready 连接                | 不需要业务循环逐个写 Socket                  |
| B 主动断开         | `close` 指向 B 的逻辑连接                                    | `gateway_disconnect` 到达后删除 `players[2]` |

`fd` 是 Skynet Socket Driver 的底层编号，Gateway 不把它交给业务 Service；`connection_id` 是本 Gateway 实例内递增分配的逻辑编号，两个不同实例可能都有 `connection_id=1`。所以出站 `send_data`、`close` 必须带入本次请求携带的 `gateway_epoch`，而且广播 `0` **只到当前 Gateway 实例**，不是全服跨节点广播。

## 5.1 整体运行与逐步观察

从 FlyWow 根目录运行：

```bash
bash gateway/sample/master_course/run.sh websocket
```

观察 `WorldService` 源码 `on_enter_world` 中 B 分支的确切发送顺序：

```text
收到 B 的 EnterWorldRequest
    -> 回 B 的 EnterWorldResponse（1001）
    -> 单播 B 的 SystemNoticeResponse（1002，"欢迎玩家1002"）
    -> 广播 SystemNoticeResponse（1002，"新手村已开放"）
    -> 30 tick 后投递 close(B)
客户端 A 收到广播 -> A 自己调用 SDK.close()
网关分别收到 A/B 的 close -> 回报两个 gateway_disconnect
WorldService 清理 players，并调用 Gateway.stop()
```

本例 `skynet.timeout(30, ...)` 只是用于让教学过程的“先收到消息、再被主动断开”清晰可见，**不是 Gateway 的可靠送达 ACK**。正式业务若必须确认某条消息已被客户端处理，应在业务协议中另行定义确认合同；Gateway 当前不提供这种机制。

### 5.2 源码深入：单播与广播

**执行位置**：`gateway/service/gateway/flywow_gateway.lua` 的 `skynet.dispatch` 收到 `send_data`，调用 `deliver_outbound_message(outbound_message)`；其参数正是上一步 WorldService 的 `send_to_gateway()` 构造的 table。

1. 检查 `gateway_epoch` 和当前 Gateway 阶段；旧实例消息立即丢弃。
2. 直接查询 `registry.commands[1002]` 并检查 `1002` 的 `response_type`（本例仅下行，所以客户端不能用 `1002` 发请求）。
3. `codec.encode_response` 将 `{content="新手村已开放"}` 编为 `SystemNoticeResponse` 再包入 Envelope。
4. `connection_id>0`：只查 `module_state.connections[connection_id]`，连接存在且 ready 才写。
5. `connection_id==0`：遍历**当前 Gateway Service** 的 `module_state.connections`，只向尚未关闭且 ready 的连接写同一份已编码 bytes。
6. `write_connection`：WebSocket 调用 `websocket.write`；TCP 则在同一 Envelope 前添加两字节网络序长度。

本次广播的两个接收者在 Gateway 内只共享一次编码得到的不可变 bytes；业务 Service 没有直接遍历/拥有 Gateway 的 Socket。发送结果只表示本地写入尝试，**不是对端应用已处理**。

### 5.3 源码深入：close 与 gateway_disconnect

**调用方**：`WorldService.on_enter_world` 注册的延迟回调向 Gateway 发出：

```lua
skynet.send(state.gateway, "lua", "close",
{
    gateway_epoch = epoch, -- B 的请求对应的当前 Gateway 实例身份。
    connection_id = target_id, -- B 的逻辑连接编号，而不是 fd。
})
```

**【真实源码】** `gateway/service/gateway/flywow_gateway.lua`：

```text
Gateway 的 skynet.dispatch("lua", ...) 收到 command="close"
  -> request_close(close_request)
       -> 校验 gateway_epoch、connection_id
       -> module_state.connections[id]
       -> detach_connection(connection, "closed by handler")
            closed=true；释放 Handshake 上下文；移除 id/fd 双索引
            发送 skynet.send(handler, "lua", "gateway_disconnect", ...)
       -> skynet.fork(function() close_transport(connection,1008,"closed by server") end)
  -> 返回 Gateway 消息分发
关闭协程：
  -> close_transport()
       -> close_requested 标记；选择 websocket.close 或 socket.close
       -> 底层关闭可能 yield
WorldService 收到 gateway_disconnect
  -> on_disconnect(message)
       -> 从 state.players 删除 B；在线人数减 1
```

为什么 `detach_connection` 在底层关闭之前？因为 Socket close 可能 yield，不能让旧连接在等待过程中仍接受出站消息；而 `close_requested` 又避免两个关闭协程重复操作同一个 Socket。这里区分**逻辑摘除**和**物理传输关闭**，是理解 Gateway 生命周期的关键。

**回到主线**：B 被清理之后，A 的客户端 `close()` 也会触发自己的断开通知。`state.disconnected==2`，WorldService 的监视协程 `skynet.call(gateway,"lua","stop")`，Gateway 进入停止阶段，关闭监听；本例已无在线连接，所以 `closed_connections` 预期是 `0`。

**阶段验收**：能说明 `connection_id=0` 不会变成客户端 0；能区分 fd、connection_id、player_id、gateway_epoch；能追踪 B 的“请求关闭 → 摘除 → 发送通知 → transport 关闭”全过程，以及 A/B 各自独立的退出路径。

---

### 5.4 源码精读：为什么同一份出站消息可以广播

上一节 B 入场后，`WorldService.on_enter_world()` 连续发出三条 `skynet.send`：B 的响应、B 的私信、面向当前 Gateway 的公告。Gateway 收到的是**三条独立的 Service 消息**，每条单独进入 `deliver_outbound_message()`；并不是在一次 RPC 中返回三个值。

广播时 `connection_id=0` 并非特殊的 fd。Gateway 先根据 `command=1002` 将 `{content="新手村已开放"}` 编成**一份** Envelope bytes，再遍历当时存活的连接。它在读循环里不会向 WorldService 查询“谁属于新手村”，只判断连接尚未 `closed` 且握手 `ready`。因此两条 ready 连接都能收到，未 ready 的连接即使已占据 `max_clients` 名额也不能收到业务公告。

源码路径：`skynet.dispatch("lua", ...)` → `deliver_outbound_message()` → `codec.encode_response()` → `write_connection()`。这里没有 `skynet.call(handler)`，也没有广播批次的 ACK 状态；多 Gateway 节点的全局广播需要宿主分别向每个 Gateway 实例发送，当前 `connection_id=0` 的范围只限本实例。

**针对本案例的可观察推演**：

```text
A 已 ready: connection_id=1
B 已 ready: connection_id=2
A/B 对应不同 Socket fd（示意）

send_data(epoch, connection_id=2, command_id=1002, "欢迎玩家1002")
    -> connections[2] -> write(B)                 只一条

send_data(epoch, connection_id=0, command_id=1002, "新手村已开放")
    -> 遍历 connections
         A: closed=false, ready=true -> write(A)
         B: closed=false, ready=true -> write(B)   共两条
```

**实验**：在正常流程中核对客户端 A 并未收到 B 的私信，而两人都收到了广播。观察结果之后再按上面的源代码分支解释：不是业务客户端自己过滤了私信，而是 Gateway 只向 B 的 fd 执行了本地写入。

### 5.5 源码精读：逻辑摘除与物理关闭是两个阶段

现在看 B 被主动断开的过程。`WorldService` 30 tick 后 `skynet.send(gateway,"lua","close",{gateway_epoch,connection_id})`。Gateway **文件末尾的 Service 分发入口**先调用 `request_close(close_request)`；该函数不执行同步 RPC 给业务 Service。

**【真实源码局部：`gateway/service/gateway/flywow_gateway.lua` / `request_close()`，省略初始参数类型校验】**：

```lua
local connection = module_state.connections[close_request.connection_id]
if not connection or not detach_connection(connection, "closed by handler") then
    return
end
skynet.fork(function()
    close_transport(connection, 1008, "closed by server")
end)
```

`detach_connection` 是**当前 Gateway Service 内部的同步状态更改**，它先标记 `connection.closed=true`，释放握手 manager 对这条连接的引用，把 `connections[id]` 和 `connections_by_fd[fd]` 都删除，减少 `client_count`，最后异步投递 `gateway_disconnect` 给 WorldService。它本身不做 `socket.close`；出站路径从此立即查不到 B 了。

**【真实源码局部：同一文件 / `detach_connection()`】**：

```lua
if connection == nil or connection.closed then
    return false
end
connection.closed = true
module_state.handshake.close(connection.handshake)
module_state.connections[connection.id] = nil
module_state.connections_by_fd[connection.fd] = nil
module_state.client_count = module_state.client_count - 1
skynet.send(module_state.gateway_config.handler_service, "lua", "gateway_disconnect",
{
    gateway_epoch = module_state.epoch,
    connection_id = connection.id,
})
-- 原函数接着记录 close 日志，最后 return true。
```

这段仅省略最终 `log_event`。它给出一个非常重要的阶段区分：

| 时刻                        | Gateway 内部状态                      | Socket 层                              | WorldService                     |
| --------------------------- | ------------------------------------- | -------------------------------------- | -------------------------------- |
| B 还在线                    | 双索引能找到 B，`closed=false`        | WS 读循环仍在运行                      | `players[B_id]=1002`             |
| `detach_connection` 已完成  | 查不到 B；`closed=true`；握手资源释放 | fd 可能尚未关完                        | 断开通知可能尚在消息队列         |
| `close_transport` 执行中    | B 已不可出站/广播                     | 调用 WS close 或 TCP close，可能 yield | 正在处理或等待 disconnect        |
| `gateway_disconnect` 已处理 | B 仍不在连接表                        | 具体 Socket 释放按 transport 完成      | 删除 `players[B_id]`，在线数减 1 |

这正是传统 C++ MMO 网关里“先从玩家/连接管理结构摘除，再异步释放网络资源”常见做法的对应关系；Skynet 的不同点是后面的 Socket close 可能让出协程，而不是通过共享内存直接在另一个线程执行删除。

### 5.6 `close_requested` 与 `closed` 不是重复字段

**【真实源码局部：`gateway/service/gateway/flywow_gateway.lua` / `close_transport()`】**：

```lua
if connection.close_requested then
    return
end
local current = module_state.connections_by_fd[connection.fd]
if current and current ~= connection then
    return
end
connection.close_requested = true
if force_shutdown and not socket.invalid(connection.fd) then
    socket.shutdown(connection.fd)
end
if connection.transport == "websocket" and not websocket.is_close(connection.fd) then
    websocket.close(connection.fd, code or 1001, reason or "closed")
elseif socket.invalid(connection.fd) then
    socket.close_fd(connection.fd)
else
    socket.close(connection.fd)
end
```

`closed` 表示**逻辑身份已经摘除**；`close_requested` 表示**底层关闭已提交**。同一条连接可能先被超时扫描发现，随后又收到业务 `close` 或传输 error；`detach` 必须保证只减一次 `client_count`、只通知一次业务，而 `close_transport` 必须保证不在多个协程中反复关闭同一个 fd。

`current` 是从 `connections_by_fd[fd]` 反查当前 owner；如果 fd 已分配给新连接，旧 context 不能把它关掉。与 `next_connection_id` 单调递增一起，形成两层不同的保护：**业务消息按逻辑 ID 查找，物理清理按当下 fd 所有权检查**。这并非新加的设计，正是已有源码行为。

`force_shutdown` 仅背压超限时为 true。正常关连接调用 `websocket.close` 或 `socket.close`；WS close 内部会尝试发送关闭帧并清理 WebSocket 对象。需要精确理解“本地提交了关闭”与“客户端必定收到一个有序 close frame”的差别：后者不是 Gateway 当前可证明的 ACK 合同。

### 5.7 追到 Skynet 的 `websocket.close()`：谁释放 WS pool

固定 Skynet `v1.8.0` `lualib/http/websocket.lua` 自身管理 `ws_pool[id]`。`M.close(id,code,reason)` 找到 `ws_obj` 后尝试写 close frame，最后调用 `_close_websocket(ws_obj)`，后者移除 WS pool 对象并调用其 `close()`（普通 WS 进一步调用 `socket.close(id)`）。这是**Skynet 第三方已实现的逻辑**，教程只读取，不修改。

这一层不归 Gateway `module_state.connections` 管理。Gateway 维护的是本模块的业务连接记录；WebSocket 库维护的是 WS 协议对象；Skynet Socket 库维护的是 fd 对应的 socket pool 记录。正常断开时三层要分别结束各自持有的状态，但不需要 Gateway 为 Skynet 再建一张 WS pool。

```text
Gateway connections       http.websocket ws_pool         skynet.socket socket_pool
       │                         │                                │
       ├─ detach: 删除 A/B       │                                │
       └─ close_transport ------> M.close(fd) --------------------> socket.close(fd)
                                  删除 ws_obj                       底层释放，可能等待
```

**实验与回主线**：按第六阶段的握手失败实验检查关闭一次即可释放握手名额；再正常接入新客户端，确认 `connections` 不会返回旧编号。回到课程 WorldService：收到 `gateway_disconnect` 后删除的是 `players[connection_id]`，从不调用 `socket.close(fd)`。

---

# 第五阶段：换成 TCP，业务协议与 WorldService 不动

## 6. TCP 只有字节流，没有 WebSocket 的消息边界

前四阶段已经完整使用 WS。现在切换为 TCP，**不改 `.proto`、WorldService、Codec、Registry、业务响应或广播**。真正要更换的只有客户端连接方式以及 Gateway 的监听 `transport` 配置。

WebSocket 交给 Gateway 的是完整 `binary message`；TCP 则需要先读 **2 字节 uint16 big-endian 长度**，再按长度读 body。由于示例 Envelope 是 10 字节，所以 TCP 线上发送 `00 0A` + 上面的 10 字节。握手每条消息也有相同的两字节 TCP 长度头。

我们复用生产级握手算法 `HandshakeClient.begin/respond/complete`，只自己实现最小 TCP framing，不复制现有 `gateway/sample/gateway_tcp_support.mjs`。

## 6.1 亲手新建 `client/tcp_client.mjs`

此文件包含 TCP Socket 连接、拼帧、三个应用握手步骤，以及把完整业务帧交给第四阶段已经写好的 `runWorldScenario`。**每个新 TCP 客户端实例拥有自己的接收缓冲和握手对象**；共享的只有业务流程函数和 Protobuf 编解码器。

```javascript
import net from "node:net";
import { HandshakeClient } from "../../../clients/h5/handshake.mjs";
import { runWorldScenario } from "./world_scenario.mjs";

const port = Number(process.argv[2] || 19221); // 本次 TCP Gateway 监听端口。

// TCP 没有消息边界：累积 data 事件得到的 bytes，再取出一个或多个长度帧。
async function connectTcp(onmessage) {
    const socket = net.createConnection({host: "127.0.0.1", port}); // 当前 TCP 客户端独占的 Socket。
    socket.setTimeout(10000, () => socket.destroy(new Error("COURSE_TCP_TIMEOUT")));

    let buffer = Buffer.alloc(0); // Socket 已收到但尚未消费的 TCP 字节。
    const frames = []; // 已拼好的完整业务或握手帧。
    const waiters = []; // 尚在等待下一条完整握手帧的 Promise。
    let failure; // 当前连接的第一个传输错误；使未完成的 readFrame 失败。
    let ready = false; // 应用握手完成前只允许 readFrame 消费握手帧。

    function fail(error) {
        failure ??= error;
        while (waiters.length) waiters.shift().reject(failure);
    }
    function publish() {
        if (ready) {
            while (frames.length) onmessage(frames.shift());
            return;
        }
        while (frames.length && waiters.length) waiters.shift().resolve(frames.shift());
    }

    socket.on("data", chunk => {
        buffer = Buffer.concat([buffer, chunk]);
        while (buffer.length >= 2) {
            const size = buffer.readUInt16BE(0); // 头部长度不含本身两个字节。
            if (size === 0) {
                socket.destroy(new Error("COURSE_EMPTY_TCP_FRAME"));
                return;
            }
            if (buffer.length < size + 2) break;
            frames.push(buffer.subarray(2, size + 2));
            buffer = buffer.subarray(size + 2);
        }
        publish();
    });
    socket.on("error", fail);
    socket.on("close", () => fail(new Error("COURSE_TCP_CLOSED")));
    await new Promise((resolve, reject) => {
        socket.once("connect", resolve);
        socket.once("error", reject);
    });

    function writeFrame(bytes) {
        const payload = Buffer.from(bytes);
        if (payload.length === 0 || payload.length > 65535) throw new Error("COURSE_FRAME_LENGTH");
        const header = Buffer.alloc(2);
        header.writeUInt16BE(payload.length, 0);
        socket.write(Buffer.concat([header, payload]));
    }
    function readFrame() {
        if (frames.length) return Promise.resolve(frames.shift());
        if (failure) return Promise.reject(failure);
        return new Promise((resolve, reject) => waiters.push({resolve, reject}));
    }

    // HandshakeClient 是已有 H5 SDK 中的纯密码学状态机；TCP 负责收发完整应用帧。
    const handshake = new HandshakeClient(globalThis.crypto);
    writeFrame(await handshake.begin());
    writeFrame(await handshake.respond(await readFrame()));
    await handshake.complete(await readFrame());
    ready = true;
    publish();

    return {
        send: writeFrame,
        close() {
            handshake.close();
            socket.end();
        },
    };
}

await runWorldScenario(connectTcp);
```

**为何这里有 `buffer` / `frames` / `waiters`？** TCP 的一个 `data` 事件可能只有半条帧，也可能包含两条帧；`readFrame()` 必须拿到完整一条消息才能交给 `HandshakeClient`。这些字段是**客户端 TCP 拼帧真实需要的状态**，不属于服务端 Gateway，也不形成框架级队列。与此相对，WS SDK 已经把 framing 和异步握手封装在 `connectGateway()` 里。

## 6.2 实际运行 TCP 全流程

```bash
bash gateway/sample/master_course/run.sh tcp
```

**预期**：服务端 READY 显示 `transport=tcp`；业务客户端依然先得到 A/B 两个进入结果，再收到 B 的单播、两人公告，B 由服务端 `close`，A 通过 `socket.end` 主动退出，最终 `COURSE_GATEWAY_OK`。与 WebSocket 的区别只在传输层；业务 table 和 command 完全不变。

### 6.3 源码深入：run_tcp 和 read_exact

**【真实源码】** `gateway/service/gateway/flywow_gateway.lua`：`accept_client` → `skynet.fork(run_tcp)` → `socket.start(fd)` → `socket.warning` → `read_exact(connection,2)` → `string.unpack(">I2",header)` → 检查阶段所允许的长度 → `read_exact(connection,size)` → `process_handshake` 或 `dispatch_payload`。

`read_exact()` 调用固定 Skynet 的 `socket.read(fd,size)`；如果底层数据未读满，当前 **Gateway 的 TCP 读协程挂起**，Socket Driver 持续接收并在满足条件时唤醒它；其他客户端各自的读取协程和其他 Service 不因此全局阻塞。读取前 `connection.read_started=skynet.now()`，读取返回后清除，以供 timeout_loop 判断**当前这一次定长读取**是否超时。

第一次客户端发送 `00 43` 加 67 字节 HELLO，Gateway 在 `handshake.ready=false` 时要求当前握手阶段的**精确长度**，不能提前把任意字节当成业务 Envelope。四段握手结束后，同一个循环改为读取正常业务帧，验证 `size <= max_frame_bytes` 再解码。

这里有一个容易误解的边界：`max_frame_bytes` 限制**业务 Envelope 长度**，不是 TCP 或 WebSocket 的底层接收内存硬上限。源码已经移除了无效的 `socket.limit(fd,max_frame_bytes+2)`；不能在教程里把它说成“完整内存防护”。

**返回主线**：TCP `dispatch_payload` 完毕返回到 `run_tcp` 读取循环，继续等待下一条长度头。WorldService 接收到的 record 与 WS 完全一致，业务不知道 TCP 何时收满每个字节。

### 6.3.1 把 TCP 读拆成真正的两个等待点

回到 `gateway/service/gateway/flywow_gateway.lua` 的 `run_tcp(connection)`。调用者是 `accept_client` 为每一条 TCP 连接 fork 的读协程，传入的 `connection` 已经存入双索引，但 `socket.start(fd)` 可能尚未完成 Socket pool 接管。

**【真实源码局部：`run_tcp()`，已省略 warning 注册与错误日志】**：

```lua
local fd = connection.fd
local opened, open_error = socket.start(fd)
-- 检查 socket.start 的结果以及连接是否已被关闭。

while not connection.closed and module_state.phase == "running" do
    local header = read_exact(connection, 2)
    if not header then
        break
    end
    local size = string.unpack(">I2", header)
    local ready = module_state.handshake.ready(connection.handshake)
    if (not ready and size ~= module_state.handshake.expected_size(connection.handshake)) or
        (ready and (size < 1 or size > module_state.gateway_config.max_frame_bytes)) then
        -- 记录 FRAME_LIMIT 并 break。
    end
    local payload = read_exact(connection, size)
    if not payload then
        break
    end
    local frame_result
    if ready then
        frame_result = dispatch_payload(connection, payload)
    else
        frame_result = process_handshake(connection, payload)
    end
    if not frame_result.ok then
        break
    end
end
-- 最终 detach_connection + close_transport。
```

这段并非完整函数，注释明确了所省略的注册/清理分支。**第一次 read_exact(2)** 是读网络序长度头；**第二次 read_exact(size)** 是读当前阶段的完整应用消息。对于应用握手 HELLO：必须先读到 `00 43`（十六进制 67），长度才能通过 `expected_size(context)=67`。对于业务 `EnterWorld`：先读到 `00 0A`（十六进制 10），才按 10 字节解析 Envelope。

**真实客户端可能把这些字节分三次送达**：

```text
Socket 收到第1批: 00                   -> header 还差 1 字节，读协程挂起
Socket 收到第2批: 0A 08 04 10          -> header 满2B，返回；body 只有3B，第二次读挂起
Socket 收到第3批: E9 07 1A 03 08 E9 07 -> body 满10B，read_exact 返回完整 Envelope
```

这里表中的 1、3、7 字节只是**教学设定的分批到达情况**；网络的实际分包由 OS、TCP 和发送时机决定，不能把三次 `data` 当成协议固定行为。

### 6.3.2 `read_exact()` 为什么要在 yield 后再次检查 `closed`

**【真实源码：`gateway/service/gateway/flywow_gateway.lua` / `read_exact()` 关键实现】**：

```lua
local function read_exact(connection, size)
    connection.read_started = skynet.now()
    local received_bytes = socket.read(connection.fd, size)
    connection.read_started = nil
    if connection.closed then
        return nil
    end
    if not received_bytes then
        return nil
    end
    if #received_bytes ~= size then
        return nil
    end
    return received_bytes
end
```

`connection.read_started` 表示**这一轮定长读取开始的 tick**；timeout_loop 判断读超时时使用它。`socket.read` 可能 yield，恢复回来时连接可能已经被另一条超时/关闭路径逻辑摘除，因此首先判断 `connection.closed`，不允许把迟到 bytes 再当成有效业务请求。

### 6.3.3 深挖固定 Skynet：协程究竟在哪一行挂起

文件：固定 Skynet `v1.8.0` `lualib/skynet/socket.lua`。调用链不是简单的“Lua 读一个系统调用”：

```text
Gateway.run_tcp 的读协程 G-read
  -> read_exact(connection, size)
  -> skynet.socket.read(fd,size)
       -> driver.pop(socket.buffer, socket.pool, size)
          ├─ 已足够：直接返回 bytes
          └─ 不足：s.read_required=size
                   -> suspend(s)
                      -> s.co=coroutine.running()
                      -> skynet.wait(s.co)               [G-read yield]
Socket Driver 有更多数据到达
  -> Skynet 的 socket 消息分发协程
       -> socket_message[1](fd,size,data)
       -> driver.push(s.buffer,s.pool,data,size)
       -> 检查 s.read_required 是 number，且缓冲量 >= 所需字节
       -> s.read_required=nil
       -> wakeup(s) -> skynet.wakeup(s.co)
G-read 后续恢复
  -> driver.pop(...,size)
  -> socket.read 返回 bytes
  -> Gateway.read_exact 检查 closed 和实际长度
  -> 回到 run_tcp 当前 header/body 读取阶段
```

**【真实源码局部：固定 Skynet `lualib/skynet/socket.lua` / `socket.read()`】**：

```lua
local ret = driver.pop(s.buffer, s.pool, sz)
if ret then
    return ret
end
if s.closing or not s.connected then
    return false, driver.readall(s.buffer, s.pool)
end
assert(not s.read_required)
s.read_required = sz
suspend(s)
ret = driver.pop(s.buffer, s.pool, sz)
```

`suspend(s)` 将当前协程保存到 `s.co` 并执行 `skynet.wait(s.co)`。当达到读取要求时，`socket_message[1]` 由 Socket 协议分发器处理，调用 `wakeup(s)` 触发恢复。不要误以为 `socket.read(fd,size)` 在读不到数据时占住整个 OS Worker Thread；**等待的是这条协程**，其他连接协程以及 Service 的其他消息可继续运行。

但也别把“同一个 Service”简单理解为“永远只有一个正在使用的 coroutine”。一个 Gateway Lua State 中可以存在多条协程，`timeout_loop` 和 `run_tcp` 共享 `module_state.connections`。所以跨 yield 以后检查 `closed` 是必要的运行时约束。

### 6.3.4 为什么长度检查发生在 body 读取前

当 `run_tcp` 读取长度头 `00 43` 时，若该连接还在 HELLO 阶段，要求精确 67；若读到 `01 F4`（500），立即报 `FRAME_LIMIT`。此时不会再尝试 `read_exact(connection,500)`。一旦 ready，长度必须在 `1..max_frame_bytes` 以内，才会执行 body 读取。

注意两个不同上限：

- `max_frame_bytes`：Gateway 用 TCP 长度头和解码前大小检查限制**业务 Envelope**；它是业务单帧边界。
- Skynet 的 socket 接收缓存：并不是因为设置了 `max_frame_bytes` 就有同样大小的底层内存硬限制。之前无效的 `socket.limit(fd,max_frame_bytes+2)` 已从生产 TCP 定长读取路径删除。

固定 `lualib/skynet/socket.lua` 中，`socket_message[1]` 在 `read_required` 为 number 时检查是否已读满并唤醒协程；这条分支并不执行通用 `s.buffer_limit` 检查。因此课程应区分**在读取 body 前验证协议长度**与**给所有 TCP/WS 内存加硬上限**，两者不是同一回事。

### 6.3.5 TCP 与 WS 最终在哪一点合流

```text
TCP: accept_client
       -> run_tcp
       -> read_exact(2) / read_exact(size)
       -> process_handshake（未ready）或 dispatch_payload（已ready）

WS:  accept_client
       -> websocket.accept / resolve_accept / read_frame
       -> ws_handler.message
       -> process_handshake（未ready）或 dispatch_payload（已ready）

两者在 Gateway 内共用：Handshake / Codec / Registry / dispatch_payload
                       -> skynet.send(WorldService,"send_data",...)
```

二者传入 `process_handshake` 的都是**不带传输帧头**的应用消息原始字节。协议版本、命令编号、业务字段不需要因传输方式不同而重新定义。`WorldService` 的 `on_enter_world` 因而可以完全不变。

**阶段验收实验**：运行 WS 和 TCP 的 A/B 两人流程后，手工记录 TCP 收到的 `00 0A + 10B Envelope`，再在源码里定位 `read_exact(2)` 和 `socket.read(fd,size)` 的两次可能 yield；能够从一条断开的连接，独立推导“读取协程恢复后为什么会返回 nil”。

---

### 6.4 你应该能回答的区别

| 问题                              | WebSocket                                            | TCP                              |
| --------------------------------- | ---------------------------------------------------- | -------------------------------- |
| 谁组装网络消息边界？              | 固定 `http.websocket`                                | Gateway `run_tcp` + `read_exact` |
| 是否需要额外 2-byte 长度头？      | 否                                                   | 是                               |
| 应用层四段握手是否不同？          | 相同 payload                                         | 相同 payload，外加 TCP 长度头    |
| Protobuf Envelope 是否不同？      | 相同                                                 | 相同                             |
| 业务 Service 是否知道 transport？ | 入站 record 有诊断字段 `transport`，业务流程可不关心 | 同左                             |
| 谁持有 socket？                   | Gateway                                              | Gateway                          |

**阶段验收**：不修改 WorldService 仍能完成两人流程；给出 `00 0A` 的来源；指出 `socket.read` yield 对应的是哪条 Service 协程，以及另一个客户端为什么不需要等待它。

---

# 第六阶段：故障、连接资源与独立维护

## 7. 故障实验的统一执行方式

我们不是靠“想象一下失败”学习 Gateway。每个实验都会真正向 Gateway 发送错误输入，观察**哪一层拒绝、有没有进入 WorldService、何时释放连接**。实验之间重新启动进程，清空上一轮的内存状态，不复用上一次的连接、计数和日志。

在 FlyWow 根目录开两个终端。终端 A 启动手动模式：

```bash
bash gateway/sample/master_course/run.sh websocket server
```

终端 B 执行各实验的 Node 命令。**每做完一项，终端 A 结束进程并重新执行启动命令**。本课程的 WorldService 有 30 秒双人结束等待；故障实验不产生两次正常入场和退出，超时自动退出是测试宿主行为，不要当成 Gateway 的连接超时错误。

### 7.1 实验 A：握手消息类型错误

**初始条件**：Gateway 正常监听 WebSocket，客户端只完成 HTTP Upgrade，还没完成应用握手。终端 B：

```bash
node --input-type=module <<'JS'
const ws = new WebSocket("ws://127.0.0.1:19221");
ws.binaryType = "arraybuffer";
ws.onopen = () => ws.send(new Uint8Array([99]));
ws.onclose = event => console.log("错误握手后连接关闭", event.code);
ws.onerror = () => console.log("传输层观察到错误");
JS
```

**执行链**：`http.websocket` 完成 HTTP Upgrade → `ws_handler.message(id, bytes, "binary")` → `process_handshake` → `handshake.receive({context,bytes})`。此时固定 HELLO 必须是 67 字节、类型 1、版本 1；传入的 `[99]` 被握手状态机拒绝，Gateway 摘除连接，`close_transport` 关闭 WS。Handshake manager 释放该连接的 Native/握手名额。

**观察**：客户端连接被关闭；WorldService 的 `on_enter_world` 不应被调用；可能收到 `gateway_disconnect`，但因它没有进入过业务，`state.players` 不存在相应记录，因此在线人数保持 0。用真实日志判断具体失败错误码，不把这里的客户端提示文本冒充框架稳定错误码。

### 7.2 实验 B：合法握手后的错误协议版本

**初始条件**：重启 Gateway，SDK 正常完成握手，之后故意发送 `protocol_version=3`，而 Gateway 配置要求 4。终端 B：

```bash
node --input-type=module <<'JS'
import { connectGateway } from "./gateway/clients/h5/handshake.mjs";
import { encodeEnterWorld } from "./gateway/sample/master_course/client/protobuf.mjs";
const connection = await connectGateway("ws://127.0.0.1:19221");
connection.send(encodeEnterWorld(1001, 3));
console.log("已发送版本 3，等待 Gateway 拒绝并断开");
JS
```

**执行链**：`ws_handler.message` → `dispatch_payload` → `codec.decode_envelope` 成功 → `envelope.protocol_version ~= gateway_config.protocol_version` → `PROTOCOL_VERSION` → 摘除关闭。没有进入 Registry 查业务消息或 `skynet.send(WorldService)` 的成功路径。

**观察**：服务端应出现稳定错误类别 `PROTOCOL_VERSION`，没有 `COURSE_ENTER player=1001`。请指出：协议版本错误是在 Envelope **成功解码之后**被发现的，不是握手失败。

### 7.3 实验 C：合法版本、未知 command

重启后在终端 B：

```bash
node --input-type=module <<'JS'
import { connectGateway } from "./gateway/clients/h5/handshake.mjs";
import { encodeEnvelope } from "./gateway/sample/master_course/client/protobuf.mjs";
const connection = await connectGateway("ws://127.0.0.1:19221");
connection.send(encodeEnvelope(9999, new Uint8Array(0)));
console.log("已发送 command=9999，等待拒绝");
JS
```

**执行链**：Envelope 版本 4 通过 → `registry.commands[9999]` 返回 nil → `UNKNOWN_COMMAND` → 关闭当前连接。`SystemNoticeResponse` 的 command 1002 虽然存在，但它没有 `request_type`，同样不能当客户端请求使用，实际会在 `codec.decode_request` 失败路径被拒绝。

### 7.4 实验 D：单连接请求速率上限

把 Gateway 的每秒接纳上限缩小为 1。终端 A：

```bash
GATEWAY_COURSE_RPS=1 bash gateway/sample/master_course/run.sh websocket server
```

终端 B：

```bash
node --input-type=module <<'JS'
import { connectGateway } from "./gateway/clients/h5/handshake.mjs";
import { encodeEnterWorld } from "./gateway/sample/master_course/client/protobuf.mjs";
const connection = await connectGateway("ws://127.0.0.1:19221");
const request = encodeEnterWorld(1001);
connection.send(request);
connection.send(request);
console.log("同一连接连续发送两条完整业务请求");
JS
```

**执行链**：两个消息经过 WS framing → `dispatch_payload` → 解码后检查连接级 `rate_count`。第一条被接纳、计数加 1；第二条在同一秒窗口遇到 `max_requests_per_second=1`，报告 `INGRESS_RATE_LIMIT`，并关闭来源连接。WorldService **至多应接收到第一条**；它不会获得 Gateway 已拒绝的第二条。

注意这是已有 Gateway 自带的速率限制机制；教程只是配置它，不在业务 Service 另造限流器。

### 7.5 实验 E：只有 Ping/Pong 或完全无业务的空闲连接

重启，缩短业务消息空闲时间为 50 tick（约 0.5 秒）：

```bash
GATEWAY_COURSE_IDLE_TICKS=50 bash gateway/sample/master_course/run.sh websocket server
```

终端 B：

```bash
node --input-type=module <<'JS'
import { connectGateway } from "./gateway/clients/h5/handshake.mjs";
await connectGateway("ws://127.0.0.1:19221");
console.log("握手已完成，但不发送任何业务 Envelope");
JS
```

**执行链**：应用握手 ready → `timeout_loop` 每 `skynet.sleep(10)` 扫描活跃连接 → `connection.last_message` 维持最近一次完整活动的时间 → 空闲期限达到配置值 → `detach_connection` / `close_transport`。`idle_timeout_ticks` 的合同限制完整客户端业务消息的空闲时间，服务端 Push、WebSocket Ping/Pong 不刷新这个期限。

在生产中，心跳是否应算业务活动取决于宿主是否定义了真正的业务命令；TCP 可以在应用层定义心跳 command，但课程**不为了演示空闲机制额外添加新的业务协议**。

### 7.6 实验 F：TCP 长度头与握手阶段不符

重启为 TCP：

```bash
bash gateway/sample/master_course/run.sh tcp server
```

终端 B：

```bash
node --input-type=module <<'JS'
import net from "node:net";
const socket = net.createConnection({host: "127.0.0.1", port: 19221});
socket.on("connect", () => socket.write(Buffer.from([0x01, 0xF4]))); // 500 字节长度声明；HELLO 只接受 67。
socket.on("end", () => console.log("服务器已结束错误 TCP 连接"));
socket.on("close", () => console.log("TCP Socket 已关闭"));
socket.on("error", error => console.log(error.message));
JS
```

**执行链**：`run_tcp` → `read_exact(connection,2)` 得到 `0x01F4=500` → 此时握手尚未 ready，`handshake.expected_size(...)` 要求 67 → `FRAME_LIMIT`，**在读取完整 500 字节 body 前直接拒绝**。检查本例是否出现 `COURSE_ENTER`：不应出现。

这跟实验 B 不同：长度错误在 TCP framing 层发生，连完整的应用握手消息都没交给 `handshake.receive`。

## 8. 写缓冲积压、服务端主动停止和回收

### 8.1 已有背压处理的真实边界

**【真实源码】** `gateway/service/gateway/flywow_gateway.lua` 的 TCP `socket.warning` 回调、`ws_handler.warning`、`close_transport(force_shutdown)`。固定 Skynet 首次写队列警告约从 1 MiB 发生，后续按底层 warning 粒度触发；`write_warning_close_kb` 只在**收到 warning 时**判断，**不是精确的 1 KiB/64 KiB 内存硬阈值**。`size==0` 是缓冲恢复通知，不属于背压超限。超过配置时 TCP 和 WS 都通过显式 `force_shutdown=true` 使用 `socket.shutdown`，随后仍走对应 transport 清理。

本课程不靠给两名玩家狂发公告模拟一个不受控的真实网络压力测试。使用仓库已有 `gateway/tests/gateway_async_test.lua` 查看模拟 warning 的断言，再结合 Skynet `lualib/skynet/socket.lua` 的 `socket.warning`、`socket.shutdown` 以及 `skynet-src/socket_server.c` 的 warning 机制，理解真实可达的回调时机。**模拟测试通过只证明回调逻辑，不等于真实 TCP/WS 高负载已测。**

### 8.2 stop 的状态和资源 owner

**【真实源码】** `gateway/service/gateway/flywow_gateway.lua`：`stop()`：

```text
WorldService 的监视协程
  -> skynet.call(gateway,"lua","stop")  [控制面 RPC 等待]
Gateway Service
  -> skynet.dispatch("lua", ...)
  -> stop()
       phase = "stopping"
       关闭监听 listen_fd
       快照当前 connections
       对每条连接 detach_connection + close_transport
       phase = "stopped"
       返回 FlyWowResult<GatewayStopResult>
WorldService 恢复，检查 ok 与 closed_connections；本课程结束进程
```

课程的正常场景已经等待 A/B 的断线通知，`stop()` 时通常不再持有两个业务连接，因此 `closed_connections=0` 是合理结果：这个值是**本次 stop 主动关闭的数量**，不是服务创建以来的连接总数。若 stop 发生时尚有活跃连接，它会先快照、逐条摘除和关闭；此时 Socket close 可能 yield，不能把 stop 误认为纯内存操作。

### 8.3 一张连接生命周期状态表

| 阶段             | Gateway 持有什么                           | WorldService 持有什么                       | 可能的退出原因                 |
| ---------------- | ------------------------------------------ | ------------------------------------------- | ------------------------------ |
| `accepted`       | fd、逻辑 ID、Handshake context、连接索引   | 尚无玩家记录                                | 容量/接管失败                  |
| `upgraded`（WS） | WS transport 对象、握手名额                | 尚无玩家记录                                | HTTP/业务握手失败              |
| `ready`          | 连接索引、计时器字段，Handshake 仅留 ready | 尚无，直到业务请求被处理                    | 业务非法帧、超时、关闭         |
| `entered`        | 同一连接对象；不存业务请求 pending         | `players[id]=player_id`                     | 客户端断开、服务器 close、错误 |
| `detached`       | 从连接索引移除，资源释放进入关闭链路       | 收到 `gateway_disconnect` 后删除对应 player | 关闭已提交，不可继续 Push      |
| `stopped`        | listener 关闭；已登记连接全部清理          | 业务实例可按宿主生命周期退出                | Service 正常停止               |

**重要区别**：业务 `player_id` 存在于 WorldService；Handshake 的 ready 不是登录成功；应用层 ECDH/HMAC 握手也不等于 TCP/WS 自动具备 TLS 和逐包加密。真实公网接入应按既有部署合同在 Gateway 前终止 TLS，不能把此教学握手误认为传输加密。

### 8.4 深入 `timeout_loop()`：一条连接为什么会被判定超时

前面的实验 E 看到了约半秒后连接断开。现在进入执行原因。**调用者**：Gateway `start()` 完成监听后执行 `skynet.fork(timeout_loop)`；它是 Gateway Lua State 中的一条独立扫描协程，不属于某个客户端。该协程每 `skynet.sleep(10)`（按本工程 10ms tick 约 100ms）醒来一次，检查当时登记在 `module_state.connections` 的全部连接。

**【真实源码局部：`gateway/service/gateway/flywow_gateway.lua` / `timeout_loop()`】**：

```lua
while module_state.phase == "running" do
    skynet.sleep(10)
    local now = skynet.now()
    local expired = {}
    for _, connection in pairs(module_state.connections) do
        local since = connection.read_started or connection.last_message
        local limit = connection.read_started
            and module_state.gateway_config.read_timeout_ticks
            or module_state.gateway_config.idle_timeout_ticks
        if module_state.handshake.expired(connection.handshake) or
            (now - since) % 0x100000000 >= limit then
            expired[#expired + 1] = connection
        end
    end
    for _, connection in ipairs(expired) do
        if detach_connection(connection, "network read timeout") then
            close_transport(connection, 1001, "network timeout")
        end
    end
end
```

这是原函数完整控制流程的去注释版；逐字段说明应以真实源码为准。两个超时条件不同：

1. `module_state.handshake.expired(context)`：从 `handshake.accept()` 记录的 `context.started` 起算，直到 confirm/close 归还名额之前都是**绝对握手期限**；中间收到 HELLO 并回复 CHALLENGE 也不重置。
2. `read_started`/`last_message`：若正在一次 TCP 定长读取或 WS HTTP Upgrade，使用读取起点及 `read_timeout_ticks`；否则使用最近完整消息活动时刻及 `idle_timeout_ticks`。

假设 WebSocket 已在 tick 0 完成应用握手，之后一直没有业务包，`idle_timeout_ticks=50`。在 tick 10、20、30、40 的扫描都还没超时；在 tick 50 才满足 `(50-0) >= 50`，执行 detach 和 transport close。**这是按源码推导的理想化时间线**：实际执行会受到 Skynet 消息调度、计时起点与网络收包时刻影响，不应声称毫秒级精确。

若在 tick 30 收到一个已通过 Registry/Codec/速率检查的完整业务请求，`dispatch_payload` 更新 `connection.last_message=30`，那么 tick 50 时差值是 20，不会超时，直到新的期限达到。反过来，WebSocket ping/pong 由底层 `http.websocket` 处理，不进入 `dispatch_payload`，因此**不会刷新**本课 Gateway 的业务空闲起点。服务端 Push 走的是 `deliver_outbound_message`，也不会刷新该时间。

`expired` 不是持久的“超时状态表”，而是这次扫描产生的临时快照：遍历期间不删 `module_state.connections`，第二个 for 循环才依次 detach/close；因为 `close_transport` 可能 yield，采用快照后不会因删除键或关闭让出协程而破坏本轮遍历。

### 8.5 具体推演：读协程和扫描协程怎样交错

以 A 的 TCP 客户端为例，假定长度头已经到达并通过校验，但是 body 还欠 3 字节：

```text
时刻        TCP 读协程 G-read                扫描协程 G-timeout
----------------------------------------------------------------------
T0          read_exact(connection,10)
            read_started=T0
            socket.read(fd,10) -> wait
T0+若干                                      skynet.sleep(10) 恢复
                                              检查 read_started，尚未超时
T1                                             读期限已到
                                               detach(connection)
                                                 closed=true，双索引删除
                                               close_transport(connection)
T2          socket.read 因关闭事件恢复
            read_started=nil
            发现 connection.closed==true
            return nil
T3          run_tcp 得到 nil，退出循环
            重复 detach 返回 false；transport 关闭以 close_requested 防重复
```

这是根据源码和 Skynet 的 `socket.read`/`socket.close` 行为推导的**一种可能交错**，不是固定调度顺序。重要的正确性条件是：`G-read` 恢复后不能因为读到了过去的字节又把已关闭连接重新当成有效连接，`read_exact` 的 `closed` 复查正是为此存在。

WS 的对应行为：`websocket.accept` 所在的会话协程正读下一个 WS frame；扫描协程认为超时，先 detach 再 `websocket.close`，后续 WS `close/error` 回调因索引已删除不会重复发 disconnect。它不需要为了超时再创建每连接一个 timer Service。

### 8.6 背压回调与真正的内存限制：按底层事实理解

已有 Gateway 的 TCP `socket.warning(fd,callback)` 和 WS `ws_handler.warning(ws_obj,size)`，最终都依据 `size >= write_warning_close_kb` 判断是否 `detach_connection` 并 `close_transport(...,true)`。但触发入口的 `size` 来自**Skynet 底层写缓冲告警，单位 KB**；它不是 Gateway 每次 `socket.write` 之后主动同步检查的队列大小。

**【真实源码局部：`gateway/service/gateway/flywow_gateway.lua` / `ws_handler.warning()`】**：

```lua
function ws_handler.warning(ws_object, size)
    if size == 0 then
        return
    end
    local connection = module_state.connections_by_fd[ws_object.id]
    if connection then
        -- 原函数先记录 WRITE_BACKPRESSURE 诊断事件。
        if size >= module_state.gateway_config.write_warning_close_kb then
            detach_connection(connection, "write backpressure")
            close_transport(connection, 1013, "server backpressure", true)
        end
    end
end
```

Skynet 的 warning 回调最初在约 1 MiB 写缓冲时触发，后续按底层告警粒度报告。设置 `write_warning_close_kb=64` **不表示 64 KiB 时必定及时断开**，因为当时尚未必有 warning 回调；`size=0` 代表发送缓冲恢复，Gateway 直接忽略。这个限制属于写侧，不能和 `max_frame_bytes`（业务接收 Envelope 限长）混为一个“内存 cap”。

**【真实源码局部：固定 Skynet `lualib/skynet/socket.lua` / `socket.shutdown()`】**：

```lua
function socket.shutdown(id)
    local s = socket_pool[id]
    if s then
        -- the framework would send SKYNET_SOCKET_TYPE_CLOSE , need close(id) later
        driver.shutdown(id)
    end
end
```

Skynet 源码明确提示 `shutdown` 以后仍需要后续 close；因此当前 Gateway 在 `force_shutdown=true` 时先 `socket.shutdown`，随后继续调用 `websocket.close` 或 `socket.close`。不要将 `shutdown` 误当作“所有 Lua/WS 状态已同步清理完毕”。

本课程的两人业务消息体量很小，不刻意制造数 MiB 的真实写队列。要验证这条分支，使用现成 `gateway/tests/gateway_async_test.lua` 的 warning 替身测试可以证明回调路径，但**不能等价宣称验证过内核层发送缓冲在高负载下的所有时序**。

### 8.7 `stop()` 的真实控制流：为何要先关闭 listener 再清连接

进入终局时，WorldService 的监视协程调用 `skynet.call(state.gateway,"lua","stop")`，这是**控制面 RPC**。Gateway 在自己的消息分发入口进入 `stop()`，等待由它管理的 Socket 资源回收后返回 `FlyWowResult`；并非进程收到一个特殊的全局退出信号。

**【真实源码局部：`gateway/service/gateway/flywow_gateway.lua` / `stop()`，按阶段整理关键语句】**：

```lua
if module_state.phase == "stopped" then
    return flywow_result.success({ closed_connections = 0 })
end
module_state.phase = "stopping"
local listen_fd = module_state.listen_fd
module_state.listen_fd = nil
-- 原函数通过 pcall(socket.close,listen_fd) 关闭监听并记录错误。

local closed = 0
local snapshot = {}
for _, connection in pairs(module_state.connections) do
    snapshot[#snapshot + 1] = connection
end
for index = 1, #snapshot do
    local connection = snapshot[index]
    if not connection.closed then
        closed = closed + 1
        detach_connection(connection, "server shutdown")
        -- 原函数通过 pcall(close_transport,connection,1001,"server shutdown")
        -- 关闭资源并记录失败，随后仍继续处理其他连接。
    end
end
module_state.phase = "stopped"
```

`phase="stopping"` 必须在 listener 关闭前设置：如 listener 的关闭期间还有迟到 accept，`accept_client` 一看 phase 不是 running 就按未接管 fd 的规则关闭，不会把新连接登记进来。

`module_state.listen_fd=nil` 是 listener 所有权退出运行状态的标记；后续创建 `snapshot` 是为了避免一边遍历 `connections` 一边删除键。`closed` 统计这一次 stop **新摘除的连接数量**；此前已经正常断开的 A/B 不算入。每个底层关闭错误会累积到 `close_error_count`，最终返回 `GATEWAY_STOP_CLOSE_FAILED`，但不会因为第一条关闭失败就跳过其他连接的处理。

随后 WorldService 的 `skynet.call` 恢复；本课程如果 A/B 已收到断线并被清理，`closed_connections=0` 是正常预期。服务器进程退出只是课程启动器的收尾行为，不要理解为 Gateway 自己自动调用了 `os.exit`。

### 8.8 连接生命周期最终核对：四种资源、三个关闭入口

| 资源/记录                                | 真实 owner                     | 创建或登记                          | 正常释放入口                                       | 异常释放入口                               |
| ---------------------------------------- | ------------------------------ | ----------------------------------- | -------------------------------------------------- | ------------------------------------------ |
| GatewayConnection / 双索引               | Gateway Service `module_state` | `create_connection`                 | `detach_connection`                                | 协议失败/超时/stop 调用 detach             |
| HandshakeContext / pending 名额          | Gateway 中的 Handshake manager | `manager.accept`                    | `manager.confirm` 归还名额；连接 detach 也 close   | `manager.receive` 失败/过期时 close        |
| Native CryptoContext userdata 的内部密钥 | 每连接 userdata                | `crypto.new`                        | Native `verify` 清理敏感数据；Lua manager 清除引用 | Native 失败与 `manager.close`/`__gc`       |
| Socket pool / WS pool 对象               | 固定 Skynet transport          | `socket.start` / `websocket.accept` | `socket.close` / `websocket.close`                 | 关闭协程/协议 error/stop                   |
| `state.players[connection_id]`           | WorldService                   | `on_enter_world`                    | `on_disconnect`                                    | 任何 Gateway detach 发出的 disconnect 通知 |

请结合正常 B 主动关闭、错误 HELLO 和 TCP 半包超时三个场景，分别指出：**谁第一次把 `closed` 设为 true、谁发 `gateway_disconnect`、谁最终释放 Socket、WorldService 在何时删除玩家记录**。当你能沿真实函数给出具体顺序，Gateway 生命周期的核心原理才算掌握。

---

## 9. 故障定位的固定顺序

当某阶段和预期不符，不需要重新设计模块，先沿对应的真实责任边界检查：

1. **启动失败**：`COURSE_START_FAILED` 的 `result.code`；检查 `world.pb`、`world_registry.lua`、`lua_path`、`lua_cpath` 与 Native .so。`GATEWAY_REGISTRY_LOAD_FAILED`、`GATEWAY_DESCRIPTOR_READ_FAILED`、`GATEWAY_CRYPTO_LOAD_FAILED` 分属不同入口，不要混为一类。
2. **连接建立但业务未到**：先辨别 HTTP Upgrade、应用四段握手、`ready`，再查 `ws_handler.message` / `run_tcp`。如果 `COURSE_ENTER` 没出现，先看 Gateway 是否完成 `dispatch_payload`，不先改业务 Service。
3. **业务到达但没有响应**：确认 WorldService 收到的 `command_id`、`connection_id`、`gateway_epoch`；再查出站 `deliver_outbound_message` 是否因旧 epoch、不在 registry、连接已关闭或编码失败丢弃消息。
4. **断线后玩家在线数未减**：追踪 `detach_connection` 是否发出 `gateway_disconnect`，以及 `on_disconnect` 查到的逻辑连接是否曾进入新手村。
5. **测试卡住**：对照 `run.sh` 的服务器日志与 Node 输出，不仅仅看 20 秒超时。区分没收到 READY、没有业务回包、B 未收到服务器 close 和 WorldService 未观察到两次 disconnect。

---

# 总复盘：离开教程也要能独立回答

## 10. 源码阅读地图

| 真正的生产文件                               | 本课程何时进入              | 阅读后必须掌握的东西                                                                                                                                                                                |
| -------------------------------------------- | --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gateway/service/gateway/flywow_gateway.lua` | 启动、接收请求、回包、关闭  | `start/normalize_config/accept_client/run_tcp/read_exact/ws_handler.message/dispatch_payload/deliver_outbound_message/request_close/detach_connection/close_transport/timeout_loop/stop` 的调用顺序 |
| `gateway/tools/generate_gateway_registry.py` | 第一阶段生成协议表 | 直接输出按数字 command ID 查询的消息类型映射 |
| `gateway/lualib/codec.lua`                   | 第一条业务请求              | `new/decode_envelope/decode_request/encode_response`：Descriptor 与 pb 编解码                                                                                                                       |
| `gateway/lualib/handshake.lua`               | 连接握手                    | `accept/receive/confirm/ready/expired/close` 和握手上下文所有权                                                                                                                                     |
| `gateway/native/gateway_crypto.cpp`          | 握手源码深挖                | P-256、随机 challenge、HKDF/HMAC 和 Native userdata 生命周期                                                                                                                                        |
| `gateway/clients/h5/handshake.mjs`           | WebSocket、TCP 客户端       | H5 SDK 的 `connectGateway` 与 `HandshakeClient` 的状态、异步密码学流程                                                                                                                              |
| 固定 Skynet `lualib/http/websocket.lua`      | WS 升级与消息回调           | `accept/resolve_accept/read_frame/write/close`，业务 callback 何时被触发                                                                                                                            |
| 固定 Skynet `lualib/skynet/socket.lua`       | TCP read、warning、shutdown | `socket.read` yield/wakeup、读缓冲与 Socket ownership                                                                                                                                               |
| `gateway/tools/generate_gateway_registry.py` | 构建协议                    | 与运行时隔离的 `CommandId` → Request/Response 类型生成过程                                                                                                                                          |

## 10.1 源码理解的独立验收题（不增加业务代码）

完成六阶段后，合上教程，仅借助真实工程源码回答以下问题。每题要指出真实文件、函数、执行协程、关键变量的 owner、必要时的返回路径；不能只回答抽象原理。

1. 客户端 A 的 TCP HELLO 长度头已到，body 还差 10 字节。此时 `run_tcp` 停在哪个函数？Socket Driver 再收到 10 字节，Skynet 怎样唤醒哪条协程？
2. WebSocket HTTP Upgrade 已成功，但 A 的 `HandshakeContext.phase="proof"`。A 此时发 `EnterWorldRequest`，Gateway 会把它交给 WorldService 吗？依据哪个具体分支？
3. 两名玩家的底层 fd 是 `18` 和 `21`，业务逻辑 ID 是 `1` 和 `2`。为什么 Gateway 既保存 `connections` 又保存 `connections_by_fd`？哪条入口分别读取？
4. `crypto.new()` 创建的 C++ userdata 与 Lua `HandshakeContext` 是不是同一对象？派生密钥在 proof 验证完毕、Gateway confirm、连接断开这三个时刻分别发生什么？
5. 同一条 WS 连接只发底层 ping/pong，从不发业务 Envelope，为什么 `idle_timeout_ticks` 仍会触发？`last_message` 实际在哪些代码分支更新？
6. Gateway 接受第一条 A 请求后执行 `skynet.send(WorldService,...)`。它随后等待的是 WorldService 回包，还是下一个 WS frame？如果 WorldService 迟迟不处理，Gateway 自己保留了哪些 pending 状态？
7. B 刚 detach，但底层 WS close 正在 yield。WorldService 又发一次旧 B 的单播和 close，哪个路径拒绝？`closed` 和 `close_requested` 的职责分别是什么？
8. B 的 Socket fd 被后来连接重用，但 WorldService 迟到的 A/B 响应仍带旧 `gateway_epoch/connection_id`。为什么不会发给新连接？
9. TCP 一次性收到长度头 `01 F4`，握手阶段要求 HELLO 67 字节。源码哪一层拒绝？为什么没有先给 500 字节分配业务包？这个检查是否等于底层 Socket 接收内存硬上限？
10. 一轮 `stop()` 关闭 3 条当前活跃连接，但此前已经断开 2 条。`closed_connections` 应该怎样理解？为什么需要快照表，哪里可能发生 yield？

建议你将第 1、6、7、10 题各画一张只有 **两个 Service 和相关协程** 的时序图；能从代码推导，不需要凭日志猜。遇到问题回看本教程对应的实战步骤，而不是额外编造新组件。

---

## 11. 综合验收清单

- [ ] 从空的 `gateway/sample/master_course/` 开始，亲手创建所有源文件，没有从旧课程复制业务协议产物。
- [ ] `build_protocol.sh` 能生成本课程 `.pb` 和 Registry，并解释构建期与运行期职责边界。
- [ ] 手动模式 `run.sh websocket server` 能启动真实 Gateway，Result 的 `command_count` 为 2。
- [ ] `run.sh websocket` 中，玩家 A/B 完成真实四段握手，并接收 1、2 人在线的 EnterWorldResponse。
- [ ] B 独占私信，A/B 都收到广播；B 由 Gateway close，A 主动关闭；业务收到两个 disconnect，Gateway 正常 stop。
- [ ] `run.sh tcp` 使用同一协议/业务处理跑通等价流程，并能画出 TCP framing。
- [ ] 至少亲手重复错误握手、错误版本、未知 command、速率限制、空闲超时、TCP 错误长度六类故障实验。
- [ ] 能画出 **两个 Service、两份 Lua State、读协程和 timeout_loop** 的真实关系；知道哪个 RPC yield，哪个 send 不等待。
- [ ] 能沿源码解释每个连接 ID、epoch、fd、Handshake context、WorldService 玩家映射各自的 owner 与释放时机。
- [ ] 能根据实验日志辨别「真实运行结果」「源码可确定的行为」「没有做过的压力/安全验证」。

最后可以自己做一个不增加代码的推演：**如果玩家 A 的连接在 WorldService 发回 EnterWorldResponse 之前已经关闭，Gateway 为什么不会把这个响应发送给后来复用相同 fd 的另一条连接？** 答案应该能从 `gateway_epoch`、递增的逻辑 `connection_id`、`module_state.connections` 索引和 `detach_connection` 的顺序推导出来，而不是靠猜测 Socket 的行为。

---

## 本次深入增强说明

相对初版，本次保持了所有「亲手新建」的业务文件与六阶段流程，讲清了构建期 Registry 被 Gateway 直接使用的关系、Gateway `module_state` 字段所有权、RPC 等待、Socket accept 与双索引、Handshake Lua 五阶段与 Native userdata、实际请求的 Protobuf 字节、`dispatch_payload` 三段解码/限流/投递、跨 Service 时序、出站编解码与广播、逻辑摘除/物理关闭、Skynet `socket.read` yield/wakeup、读超时与业务空闲超时的交错、背压的底层语义、`stop` 的实际释放顺序，以及十道独立源码推演题。

**源码基线仍为 `7509b289`**。所有新增的“预期、推导、示意”仍需使用你自己的固定 Skynet 环境验证；本次补充是**源码分析和教学内容增强**，没有声称已经运行新的端到端 Sample，更没有修改生产仓库。

## 版本与教学交付说明

1. 本文以 `7509b289` 为代码基线，不把之后的变更自动视为兼容；正式实施前若已切换提交，应先核对 Gateway/SDK/生成器与现有签名。
2. 命令和代码均已按该基线的公开接口设计；**本次环境没有固定 Skynet、protoc 和对应宿主编译产物，因此未实际运行这一套新 Sample**。完成课程时应以你运行的真实日志为准；出现不一致应先检查教程与当前源码/依赖，不修改第三方源码，也不通过伪造日志交付。
3. 教程里的 WorldService 是极小的宿主业务示例；它不是一个 MMO 玩家管理系统。没有会话鉴权、持久化、路由重试、跨 Gateway 广播或可靠客户端 ACK。学习 Gateway 不需要为这些未承诺功能增加新的框架层。
4. 本教程遵循 `.agents/skills/source-based-practical-teaching/SKILL.md` 的从零实施、真实源码调用链和阶段验收规则；代码注释与状态所有权遵守工程 Skill。原 Gateway/Skynet/客户端 SDK 的既有代码均保持不变。
