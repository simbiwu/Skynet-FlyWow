-- 职责：以可控 Skynet/socket 替身验证 Gateway 异步合同与资源边界。
-- 边界：Test；加载真实 Gateway/endpoint 源码，替换 transport、registry 和 codec。
-- 输入/输出：FlyWow 根路径 -> 断言或 GATEWAY_ASYNC_UNIT_OK。
-- 生命周期：每场景重建 Lua State 模块状态；不启动网络，不冒充真实集成验证。
-- 不负责：不验证 Protobuf 字节或真实 Skynet 调度，它们由宿主集成测试覆盖。
local root = assert(arg[1]) -- 被测 FlyWow 根路径；由测试入口显式传入。
package.path = root .. "/common/lualib/?.lua;" ..
    root .. "/gateway/lualib/?.lua;" .. package.path
local flywow_result = require "flywow_result"

-- 创建独立的可控场景；overrides 为配置覆盖，无 I/O；返回由测试拥有的控制对象。
---@param overrides table|nil 可覆盖 TCP/WebSocket 模式等本场景启动配置；不会修改调用方的 table。
---@return table 包含替身状态、注入入口和已注册 Service 命令回调的测试场景。
local function scenario(overrides)
    local e = -- 当前场景的可控观测状态，由替身写入并由断言读取。
    {
        now     = 0,
        sends   = {},
        forks   = {},
        streams = {},
        started = {},
        writes  = {},
        closed  = {},
    }
    local config = -- Gateway 的测试启动配置副本；overrides 只作用于当前场景。
    {
        host             = "127.0.0.1",
        port             = 19021,
        protocol_version = 4,
        descriptor_path  = "stub",
        registry_module  = "test.registry",
    }
    for k, v in pairs(overrides or {}) do
        config[k] = v
    end

    -- 注册 Skynet 替身，记录消息和协程，不启动真实 Service 调度。
    local skynet = {} -- 记录并控制 Gateway 使用的 Skynet API 替身。
    -- 替身不允许数据平面出现同步 call；任何意外等待立即使测试失败。
    ---@return nil 测试中 Gateway 不应同步调用 handler；调用即抛出断言失败。
    function skynet.call()
        error("Gateway must never call handler")
    end

    -- 固定签名记录本地异步消息；返回值模拟 pinned Skynet 的成功标志。
    ---@param address string 测试目标服务名。
    ---@param protocol string Skynet 消息协议名。
    ---@param command string Lua 命令名。
    ---@param message table 发送的 Gateway 消息记录。
    ---@return boolean 测试消息成功入队时返回 true。
    function skynet.send(address, protocol, command, message)
        e.sends[#e.sends + 1] = { address, command, message }
        return true
    end

    -- 注册但不抢先执行任务；测试自行控制协程推进，无 OS 线程。
    ---@param fn fun() Gateway 注册的协程函数；由测试手动推进。
    ---@return nil 保存协程，不立即执行。
    function skynet.fork(fn)
        e.forks[#e.forks + 1] = coroutine.create(fn)
    end

    -- 在测试调度器等待下一次扫描。
    ---@return nil 挂起当前测试协程，交回测试调度器。
    function skynet.sleep()
        coroutine.yield("sleep")
    end

    -- 返回测试时钟 tick。
    ---@return integer 当前测试控制的 10ms tick。
    function skynet.now()
        return e.now
    end

    -- 固定 Service handle。
    ---@return integer 固定测试 Service handle。
    function skynet.self()
        return 99
    end

    -- 每场景由外部隔离状态，固定高精度 tick 足够验证不同 epoch 的拒绝。
    ---@return integer 固定高精度 tick，用于构造确定性 epoch。
    function skynet.hpc()
        return 12345
    end

    -- 忽略诊断日志；结果通过状态断言检查。
    ---@return nil 忽略诊断日志，测试只检查可观察状态。
    function skynet.error()
    end

    -- 捕获管理调用返回 record。
    ---@param result table Service start 命令的返回 record。
    ---@return nil 保存 RPC 返回值供测试读取。
    function skynet.retpack(result)
        e.result = result
    end

    -- 保存真实 Service 的分发回调。
    ---@param protocol string 注册的 Skynet 消息协议。
    ---@param fn function Service 命令分发回调。
    ---@return nil 保存分发回调供测试调用。
    function skynet.dispatch(protocol, fn)
        e.dispatch = fn
    end

    -- 同步初始化入口，不执行真实调度。
    ---@param fn function Service 初始化回调。
    ---@return nil 同步执行初始化，不创建真实调度器。
    function skynet.start(fn)
        fn()
    end

    -- 注册 TCP Socket 替身；输入字节由场景提供，关闭和写入只更新测试状态。
    local socket = {} -- 记录 fd、读写和关闭行为的 Socket 替身。
    -- 固定监听 fd 和地址；无 I/O。
    ---@param host string Gateway 监听地址。
    ---@param port integer Gateway 监听端口。
    ---@return integer, string, integer 固定 fd、原地址和原端口。
    function socket.listen(host, port)
        return 1, host, port
    end

    -- 监听回调保存供测试注入连接；客户端 start 不执行 I/O。
    ---@param fd integer 要登记为 Socket 的 fd。
    ---@param fn function|nil 监听 Socket 的 accept 回调；客户端 Socket 不提供。
    ---@return nil 记录启动状态和 accept 回调，不执行 I/O。
    function socket.start(fd, fn)
        e.started[fd] = true
        if fn then
            e.accept = fn
        end
        return fd
    end

    -- 缓冲限制由真实集成验证；替身保持签名。
    ---@return nil 测试不验证真实写缓冲限制。
    function socket.limit()
    end

    -- 警告回调无需触发，真实集成另测写队列。
    ---@param fd integer Gateway 连接 fd。
    ---@param callback function 写缓冲 warning 回调。
    ---@return nil 保存回调供测试调度。
    function socket.warning(fd, callback)
        e.warning = callback
    end

    -- 精确读取已有字节，不足时挂起；模仿 Socket read 的等待条件。
    ---@param fd integer Gateway TCP 连接 fd。
    ---@param size integer 本次读取所需的字节数。
    ---@return string|false, string|nil 字节齐全时返回数据；不足时挂起并模拟 EOF。
    function socket.read(fd, size)
        local data = e.streams[fd] or "" -- 当前 fd 尚未被测试读出的 TCP 字节尾部。
        if #data < size then
            -- 让 Gateway 等待下一次读取；测试通过 resume 控制何时返回。
            coroutine.yield("read")
            return false, ""
        end

        -- 字节齐全时消费长度前缀对应的字节，再把数据交给 Gateway。
        e.streams[fd] = data:sub(size + 1)
        return data:sub(1, size)
    end

    -- 记录完整 TCP frame；写入失败场景通过标志注入。
    ---@param fd integer Gateway TCP 连接 fd。
    ---@param bytes string 要记录的完整 frame。
    ---@return boolean 是否接受写入；fail_write 用于注入失败。
    function socket.write(fd, bytes)
        if e.fail_write then
            -- 按 Skynet Socket 合同报告底层写入拒绝。
            return false
        end

        -- 正常写入只记录 frame，测试随后按字节验证 Gateway 输出。
        e.writes[#e.writes + 1] = { fd, bytes }
        return true
    end

    -- 记录关闭，不复用 fd。
    ---@param fd integer 已登记的 TCP fd。
    ---@return nil 记录关闭并释放测试中的启动标记。
    function socket.close(fd)
        e.closed[fd] = true
        e.started[fd] = nil
    end

    -- 接管前的 accepted fd 必须通过 close_fd 释放。
    ---@param fd integer 尚未进入 Socket pool 的 accepted fd。
    ---@return nil 记录关闭；若已登记则抛出断言失败。
    function socket.close_fd(fd)
        assert(not e.started[fd], "close_fd is only valid before socket.start")
        e.closed[fd] = true
    end

    -- 与 pinned socket_pool ownership 保持一致。
    ---@param fd integer 要检查的测试 fd。
    ---@return boolean fd 尚未登记到 Socket pool 时为 true。
    function socket.invalid(fd)
        return not e.started[fd]
    end

    -- 注册 WebSocket 替身；将 HTTP Upgrade 和 binary 消息回调交给 Gateway。
    local websocket = {} -- 将 WebSocket 回调交回 Gateway 的传输替身。
    -- 接受握手后模拟收到一个 binary 消息，再挂起等待后续消息。
    ---@param fd integer 新接入的 WebSocket fd。
    ---@param handler table Gateway 注册的 WebSocket 回调表。
    ---@return boolean accept 正常返回时为 true；可能挂起等待 WebSocket session。
    function websocket.accept(fd, handler)
        if e.fail_ws_accept then
            -- 模拟 pinned WebSocket accept 在 Upgrade 前抛出原生错误。
            error("injected websocket accept failure")
        end

        -- Upgrade 通过后回调 Gateway，并挂起以模拟 WebSocket session 存续。
        e.ws = handler
        handler.handshake(fd, {}, "/")
        handler.message(fd, "1", "binary")
        coroutine.yield("ws")
        return true
    end

    -- 记录 WS 完整消息写入；不 yield。
    ---@param fd integer WebSocket 连接编号。
    ---@param bytes string 完整 binary message。
    ---@return nil 记录测试写入。
    function websocket.write(fd, bytes)
        e.writes[#e.writes + 1] = { fd, bytes }
    end

    -- 记录 WS 关闭。
    ---@param fd integer WebSocket 连接编号。
    ---@return nil 记录测试中的传输关闭。
    function websocket.close(fd)
        e.closed[fd] = true
    end

    -- 返回握手前是否尚未建立 WS 对象。
    ---@param id integer WebSocket 连接编号。
    ---@return boolean 测试 WebSocket 尚未建立或已被关闭时为 true。
    function websocket.is_close(id)
        return e.ws == nil or e.closed[id] == true
    end

    -- 提供单个 request/response command，供请求解码和主动下发路径共用。
    local registry = {} -- 为场景提供单一命令定义的 registry 替身。
    -- 提供只读测试索引。
    ---@return table 提供一个命令的只读测试索引。
    function registry.build_index()
        return flywow_result.success(
        {
            count = 1, -- 测试索引只暴露一个命令。
        })
    end

    -- 只登记 command=1001。
    ---@param index table 测试 registry 索引。
    ---@param command integer 要查询的 command id。
    ---@return table|nil command 为 1001 时返回测试定义，其他值返回 nil。
    function registry.find_command(index, command)
        if command == 1001 then
            return
            {
                id            = 1001, -- 唯一测试命令 ID。
                name          = "QueryCell", -- 测试请求名称。
                response_type = ".demo.QueryCellResponse", -- 测试响应类型。
            }
        end
    end

    -- 用最小 codec 替身验证 Gateway 转发；Protobuf 字节由真实集成测试覆盖。
    local codec = {} -- 只模拟 Envelope/body 编解码边界，不验证 Protobuf wire bytes。
    -- payload 的数字只用于构造可重复的测试 request data。
    ---@param payload string 测试用 Envelope bytes。
    ---@return FlyWowResult<table> 解码得到的 Envelope record；bad 输入返回模拟解码失败。
    function codec.decode_envelope(payload)
        if payload == "bad" then
            return flywow_result.failure("TEST_DECODE", "malformed envelope")
        end
        return flywow_result.success(
        {
            protocol_version = 4,
            command          = 1001,
            body             = "",
        })
    end

    -- 请求 body 替身，与业务无关。
    ---@return FlyWowResult<table> 固定的业务 request record。
    function codec.decode_request()
        return flywow_result.success({ test_id = 1, map_id = 1001 })
    end

    -- 响应结果编码为文本，fail 注入编码异常。
    ---@param definition table Registry 中的 response 定义。
    ---@param version integer 当前 Gateway 协议版本。
    ---@param response table handler 返回的 response record。
    ---@return FlyWowResult<string> 固定响应值编码；fail 字段触发模拟编码错误。
    function codec.encode_response(definition, version, response)
        if response.fail then
            return flywow_result.failure("TEST_ENCODE", "encode failure")
        end
        return flywow_result.success(tostring(response.result))
    end

    -- 安装依赖替身后加载真实 Gateway 源码；本场景不访问文件或网络。
    package.loaded["skynet"] = skynet
    package.loaded["skynet.socket"] = socket
    package.loaded["http.websocket"] = websocket
    package.loaded["test.registry"] = {}
    package.loaded["registry"] = registry
    package.loaded["codec"] =
    {
        new = function() -- 为 Gateway 返回本场景创建的 codec 替身。
            return flywow_result.success(codec)
        end,
    }
    package.loaded["flywow_gateway_crypto"] = {}
    package.loaded["handshake"] =
    {
        -- 每个连接使用独立替身上下文；真实密码学握手由 Native 测试覆盖。
        new = function() -- Gateway 每个连接创建独立握手上下文。
            local manager =
            {
                ---@return FlyWowResult<table> 测试握手上下文；调用方负责在连接结束时关闭。
                accept = function()
                    return flywow_result.success({})
                end,
                ---@return nil 释放测试握手上下文。
                close = function()
                end,
                ---@return boolean 显式设置 ready=false 时表示业务握手尚未完成。
                ready = function()
                    return e.ready ~= false
                end,
                ---@return boolean 测试场景中的握手不会自行过期。
                expired = function()
                    return false
                end,
                -- 纯业务场景不应调用握手 receive；意外调用时显式失败供断言捕获。
                receive = function()
                    return flywow_result.failure("TEST_HANDSHAKE", "unexpected handshake")
                end,
                -- 测试握手确认无副作用，只返回空成功结果。
                confirm = function()
                    return flywow_result.success()
                end,
            }
            return flywow_result.success(manager)
        end,
    }
    dofile(root .. "/gateway/service/gateway/flywow_gateway.lua")
    -- Gateway 不再隐式加载宿主 config.gateway；测试显式传入运行所需配置。
    -- descriptor/registry 在本测试中由上方 package.loaded 替身提供，不读取磁盘协议产物。
    -- 传入当前场景配置建立真实 Service 运行状态；覆盖项因此能驱动 TCP/WS 分支。
    config.handler_service = ".test_handler"
    e.dispatch(1, 8, "start", config)
    assert(e.result.ok and e.result.value.port == config.port, "start must return FlyWowResult")
    return e
end

-- 推进一个替身协程到下一个等待点；异常以断言传播。
---@param co thread 已由测试捕获的 Gateway 协程。
---@return nil 推进到下一个等待点；协程错误会以断言失败。
local function resume(co)
    local ok, err = coroutine.resume(co)
    assert(ok, err)
end

-- 将数字请求构造成真实 TCP 长度帧，返回调用方拥有的 string。
---@param id integer 用于构造可识别测试 payload 的整数。
---@return string TCP uint16 大端长度前缀加 payload。
local function frame(id)
    local payload = tostring(id)
    return string.pack(">I2", #payload) .. payload
end

local e = scenario()
e.streams[10] = frame(1) .. frame(2)
e.accept(10, "peer")
resume(e.forks[2])

assert(#e.sends == 2)
assert(e.sends[1][1] == ".test_handler", "Gateway must send to the configured service name")
assert(e.sends[1][2] == "send_data")
assert(e.sends[1][3].connection_id == 1)
assert(e.sends[2][3].connection_id == 1)
assert(e.sends[1][3].request_id == nil and e.sends[2][3].request_id == nil)
assert(#e.writes == 0, "Gateway must not write before handler sends data")

local message = e.sends[1][3]
local current_epoch = message.gateway_epoch
message.data = { result = 1 }
e.dispatch(0, 7, "send_data", message)
assert(e.writes[1][2] == frame(1))

message.gateway_epoch = "old"
e.dispatch(0, 7, "send_data", message)
assert(#e.writes == 1, "old Gateway epoch must be dropped")

message.gateway_epoch = current_epoch
message.data = { fail = true }
e.dispatch(0, 7, "send_data", message)
assert(#e.writes == 1, "encoding failure must not close healthy connection")

message.data = { result = 2 }
e.dispatch(0, 999, "send_data", message)
assert(#e.writes == 2, "Gateway does not validate the reply source identity")

local push =
{
    gateway_epoch = current_epoch,
    connection_id = 0,
    command_id = 1001,

    data = { result = 3 },
}
e.dispatch(0, 7, "send_data", push)
assert(#e.writes == 3, "one active connection receives broadcast")

e.dispatch(0, 999, "close",
{
    gateway_epoch = current_epoch,
    connection_id = message.connection_id,
})
resume(e.forks[3])
assert(e.closed[10])

e = scenario()
e.streams[10] = frame(1)
e.accept(10, "peer")
resume(e.forks[2])
assert(e.sends[1][2] == "send_data")
e.dispatch(0, 999, "close", e.sends[1][3])
resume(e.forks[3])
assert(e.closed[10])


-- 两连接定向push审计；与旧用例独立，不修改旧用例的fork下标。
e = scenario()
e.streams[10] = frame(1)
e.streams[11] = frame(2)
e.accept(10, "peer-a")
resume(e.forks[2])
e.accept(11, "peer-b")
resume(e.forks[3])

local targeted =
{
    gateway_epoch = e.sends[1][3].gateway_epoch,
    connection_id = e.sends[1][3].connection_id,
    command_id    = 1001,

    data          = { result = 7 },
}
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 1 and e.writes[1][1] == 10, "target push must not broadcast")
assert(e.writes[1][2] == frame(7), "push needs no correlation field")

local epoch = targeted.gateway_epoch
targeted.gateway_epoch = "old"
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 1, "old epoch push must be dropped")

targeted.gateway_epoch = epoch
e.ready = false
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 1, "not-ready push must be dropped")

e.ready = true
targeted.connection_id = 0
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 3, "broadcast still reaches both ready connections")

targeted.connection_id = 1
e.dispatch(0, 7, "close", targeted)
resume(e.forks[4])
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 3, "closed target must not fall back to broadcast")
targeted.connection_id = 9999
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 3, "unknown target must be dropped")

e = scenario({ transport = "websocket" })
e.fail_ws_accept = true
e.accept(12, "peer")
resume(e.forks[2])
assert(e.closed[12], "WebSocket accept exceptions must release the accepted fd")
assert(e.sends[1][2] == "gateway_disconnect", "failed WebSocket accept must detach its connection")
print("GATEWAY_ASYNC_UNIT_OK")
