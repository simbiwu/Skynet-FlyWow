-- 职责：以可控 Skynet/socket 替身验证 Gateway 异步合同与资源边界。
-- 边界：Test；加载真实 Gateway/endpoint 源码，替换 transport、registry 和 codec。
-- 输入/输出：FlyWow 根路径 -> 断言或 GATEWAY_ASYNC_UNIT_OK。
-- 生命周期：每场景重建 Lua State 模块状态；不启动网络，不冒充真实集成验证。
-- 不负责：不验证 Protobuf 字节或真实 Skynet 调度，它们由宿主集成测试覆盖。
local root = assert(arg[1])
package.path = root .. "/lualib/?.lua;" .. package.path

-- 创建独立的可控场景；overrides 为配置覆盖，无 I/O；返回由测试拥有的控制对象。
local function scenario(overrides)
    local e =
    {
        now     = 0,
        sends   = {},
        forks   = {},
        streams = {},
        started = {},
        writes  = {},
        closed  = {},
    }
    local config =
    {
        host             = "127.0.0.1",
        port             = 19021,
        protocol_version = 3,
        descriptor_path  = "stub",
        registry_module  = "test.registry",
    }
    for k, v in pairs(overrides or {}) do config[k] = v end
    local skynet = {}
    -- 替身不允许数据平面出现同步 call；任何意外等待立即使测试失败。
    function skynet.call() error("Gateway must never call handler") end
    -- 固定签名记录本地异步消息；返回 session=0，符合 pinned Skynet send。
    function skynet.send(handle, protocol, command, message)
        e.sends[#e.sends + 1] = { handle, command, message }
        return 0
    end
    -- 注册但不抢先执行任务；测试自行控制协程推进，无 OS 线程。
    function skynet.fork(fn) e.forks[#e.forks + 1] = coroutine.create(fn) end
    -- 在测试调度器等待下一次扫描。
    function skynet.sleep() coroutine.yield("sleep") end
    -- 返回测试时钟 tick。
    function skynet.now() return e.now end
    -- 固定 Service handle。
    function skynet.self() return 99 end
    -- 每场景由外部隔离状态，固定高精度 tick 足够验证不同 epoch 的拒绝。
    function skynet.hpc() return 12345 end
    -- 忽略诊断日志；结果通过状态断言检查。
    function skynet.error() end
    -- 捕获管理调用返回 record。
    function skynet.retpack(result) e.result = result end
    -- 保存真实 Service 的分发回调。
    function skynet.dispatch(protocol, fn) e.dispatch = fn end
    -- 同步初始化入口，不执行真实调度。
    function skynet.start(fn) fn() end
    local socket = {}
    -- 固定监听 fd 和地址；无 I/O。
    function socket.listen(host, port) return 1, host, port end
    -- 监听回调保存供测试注入连接；客户端 start 不执行 I/O。
    function socket.start(fd, fn)
        e.started[fd] = true
        if fn then e.accept = fn end
    end
    -- 缓冲限制由真实集成验证；替身保持签名。
    function socket.limit() end
    -- 警告回调无需触发，真实集成另测写队列。
    function socket.warning(fd, callback) e.warning = callback end
    -- 精确读取已有字节，不足时挂起；模仿 Socket read 的等待条件。
    function socket.read(fd, size)
        local data = e.streams[fd] or ""
        if #data < size then coroutine.yield("read"); return false, "" end
        e.streams[fd] = data:sub(size + 1)
        return data:sub(1, size)
    end
    -- 记录完整 TCP frame；写入失败场景通过标志注入。
    function socket.write(fd, bytes)
        if e.fail_write then return false end
        e.writes[#e.writes + 1] = { fd, bytes }
        return true
    end
    -- 记录关闭，不复用 fd。
    function socket.close(fd) e.closed[fd] = true; e.started[fd] = nil end
    -- 接管前的 accepted fd 必须通过 close_fd 释放。
    function socket.close_fd(fd)
        assert(not e.started[fd], "close_fd is only valid before socket.start")
        e.closed[fd] = true
    end
    -- 与 pinned socket_pool ownership 保持一致。
    function socket.invalid(fd) return not e.started[fd] end
    local websocket = {}
    -- 接受握手后模拟收到一个 binary 消息，再挂起等待后续消息。
    function websocket.accept(fd, handler)
        e.ws = handler
        handler.handshake(fd, {}, "/")
        handler.message(fd, "1", "binary")
        coroutine.yield("ws")
        return true
    end
    -- 记录 WS 完整消息写入；不 yield。
    function websocket.write(fd, bytes) e.writes[#e.writes + 1] = { fd, bytes } end
    -- 记录 WS 关闭。
    function websocket.close(fd) e.closed[fd] = true end
    -- 返回握手前是否尚未建立 WS 对象。
    function websocket.is_close(id) return e.ws == nil or e.closed[id] == true end
    local registry = {}
    -- 提供只读测试索引。
    function registry.load() return
    {
        count = 1,
    }
    end
    -- 只登记 command=1001。
    function registry.find(index, command)
        if command == 1001 then return
        {
            id   = 1001,
            name = "QueryCell",
        }
        end
    end
    local codec = {}
    -- payload 的数字表示 request_id；bad 用于模拟损坏协议。
    function codec.decode_envelope(payload)
        assert(payload ~= "bad", "malformed envelope")
        return
        {
            protocol_version = 3,
            command          = 1001,
            request_id       = tonumber(payload),
            body             = "",
        }
    end
    -- 请求 body 替身，与业务无关。
    function codec.decode_request() return {} end
    -- 响应编号编码为文本，允许测试确定顺序；fail 注入编码异常。
    function codec.encode_response(definition, id, version, response)
        assert(not response.fail, "encode failure")
        return tostring(id)
    end
    package.loaded["skynet"] = skynet
    package.loaded["skynet.socket"] = socket
    package.loaded["http.websocket"] = websocket
    package.loaded["config.gateway"] = config
    package.loaded["test.registry"] = {}
    package.loaded["flywow.gateway.registry"] = registry
    package.loaded["flywow.gateway.codec"] =
    {
        new = function() return codec end,
    }
    package.loaded["flywow_gateway_crypto"] = {}
    package.loaded["flywow.gateway.handshake"] =
    {
        new = function()
            return
            {
                accept = function() return {} end,
                close = function() end,
                ready = function() return true end,
                expired = function() return false end,
            }
        end,
    }
    package.loaded["flywow.gateway.endpoint"] = nil
    dofile(root .. "/service/flywow_gateway.lua")
    e.dispatch(1, 8, "start",
    {
        handler_service = 7,
    }
    )
    return e
end

-- 推进一个替身协程到下一个等待点；异常以断言传播。
local function resume(co)
    local ok, err = coroutine.resume(co)
    assert(ok, err)
end

-- 将数字请求构造成真实 TCP 长度帧，返回调用方拥有的 string。
local function frame(id)
    local payload = tostring(id)
    return string.pack(">I2", #payload) .. payload
end

local e = scenario()
e.streams[10] = frame(1) .. frame(2)
e.accept(10, "peer")
resume(e.forks[2])
assert(#e.sends == 2 and e.sends[1][2] == "gateway_dispatch" and e.sends[2][3].request_id == 2)
assert(#e.writes == 0, "B must be read before any response")
local endpoint = require "flywow.gateway.endpoint"
local a = endpoint.new(
{
    gateway_service = 99,
    request         = e.sends[1][3],
}
)
local b = endpoint.new(
{
    gateway_service = 99,
    request         = e.sends[2][3],
}
)
assert(b:reply({}))
assert(a:reply({}))
assert(not a:reply({}))
e.dispatch(0, 7, "gateway_response", e.sends[3][3])
e.dispatch(0, 7, "gateway_response", e.sends[4][3])
assert(e.writes[1][2] == frame(2) and e.writes[2][2] == frame(1))
local reply = e.sends[3][3]
e.dispatch(0, 999, "gateway_response", reply)
assert(#e.writes == 2, "unauthorized source must be dropped")
reply.gateway_epoch = "old"
e.dispatch(0, 7, "gateway_response", reply)
assert(#e.writes == 2, "old Gateway epoch must be dropped")
reply.gateway_epoch = e.sends[1][3].gateway_epoch
reply.response =
{
    fail = true,
}
e.dispatch(0, 7, "gateway_response", reply)
assert(not e.closed[10], "encoding failure must not close healthy connection")
reply.response, reply.request_id = {}, 0
e.dispatch(0, 7, "gateway_response", reply)
assert(e.writes[3][2] == frame(0), "registered response push must work")
e.dispatch(1, 8, "stop")
e.dispatch(0, 7, "gateway_response", reply)
assert(#e.writes == 3 and e.closed[10])

e = scenario(
{
    max_requests_per_second = 1,
}
)
e.streams[10] = frame(1) .. frame(2)
e.accept(10, "peer")
resume(e.forks[2])
assert(e.closed[10] and #e.sends == 2 and e.sends[2][2] == "gateway_disconnect")

e = scenario(
{
    read_timeout_ticks = 20,
}
)
e.streams[10] = "\0"
e.accept(10, "peer")
resume(e.forks[2])
resume(e.forks[1])
e.now = 30
resume(e.forks[1])
assert(e.closed[10], "partial header must time out")

e = scenario(
{
    max_clients = 1,
}
)
e.accept(10, "peer")
e.accept(11, "peer")
assert(e.closed[11], "connection count must be bounded")

e = scenario(
{
    transport   = "websocket",
    max_clients = 1,
}
)
e.accept(10, "peer")
e.accept(11, "peer")
assert(e.closed[11], "pending handshake counts against connection limit")
resume(e.forks[2])
e.ws.message(10, "2", "binary")
assert(#e.sends == 2)
e.ws.message(10, "bad", "binary")
assert(e.closed[10])
-- 写失败摘除连接；清理协程不占用业务等待状态。
e = scenario()
e.streams[10] = frame(1)
e.accept(10, "peer")
resume(e.forks[2])
endpoint = require "flywow.gateway.endpoint"
local context = endpoint.new(
{
    gateway_service = 99,
    request         = e.sends[1][3],
}
)
context:reply({})
e.fail_write = true
e.dispatch(0, 7, "gateway_response", e.sends[2][3])
e.dispatch(1, 8, "stats")
assert(e.result.clients == 0)
resume(e.forks[3])
assert(e.closed[10])

-- 写缓冲告警是网络策略，达到阈值后释放连接。
e = scenario()
e.accept(10, "peer")
resume(e.forks[2])
e.warning(10, 1024)
assert(e.closed[10])

-- 同一实例的总速率限制独立于单连接限制。
e = scenario(
{
    max_total_requests_per_second = 1,
}
)
e.streams[10], e.streams[11] = frame(1), frame(2)
e.accept(10, "peer")
resume(e.forks[2])
e.accept(11, "peer")
resume(e.forks[3])
assert(e.closed[11])

-- 自定义返回函数发送失败后可以显式重试；options 修改不改变已有上下文。
e = scenario()
e.streams[10] = frame(1)
e.accept(10, "peer")
resume(e.forks[2])
endpoint = require "flywow.gateway.endpoint"
local fail, calls = true, 0
local options =
{
    request = e.sends[1][3],
}
-- 测试发送函数只记录调用次数，失败不表示客户端收到，成功也不做交付承诺。
function options.send(message)
    calls = calls + 1
    return not fail
end
context = endpoint.new(options)
options.send = nil
local ok, code = context:reply({})
assert(not ok and code == "SEND_FAILED")
fail = false
assert(context:reply({}) and calls == 2)
assert(not context:reply({}))
-- stop 在读任务启动前也必须关闭 accepted fd；重复 stop 保持幂等。
for _, transport in ipairs({ "tcp", "websocket" }) do
    e = scenario(
    {
        transport = transport,
    }
    )
    e.accept(10, "peer")
    e.dispatch(1, 8, "stop")
    assert(e.closed[10] and e.result.closed_connections == 1)
    e.dispatch(1, 8, "stop")
    assert(e.result.closed_connections == 0)
    resume(e.forks[2])
end

-- 连接编号达到 maxinteger 后拒绝接入，不能回绕复用。
e = scenario()
for index = 1, 20 do
    local name, value = debug.getupvalue(e.dispatch, index)
    if name == "state" then value.next_connection_id = math.maxinteger; break end
end
e.accept(10, "peer")
assert(e.closed[10])
-- 主动关闭只允许 handler；旧实例、重复命令不影响当前连接，通知仅发一次。
for _, transport in ipairs({ "tcp", "websocket" }) do
    e = scenario(
    {
        transport = transport,
    }
    )
    e.streams[10] = frame(1)
    e.accept(10, "peer")
    resume(e.forks[2])
    endpoint = require "flywow.gateway.endpoint"
    context = endpoint.new(
    {
        gateway_service = 99,
        request         = e.sends[1][3],
    }
    )
    assert(context:close())
    ok, code = context:close()
    assert(not ok and code == "DUPLICATE_CLOSE")
    ok, code = context:reply({})
    assert(not ok and code == "CONNECTION_CLOSING")
    local message = e.sends[2][3]
    e.dispatch(0, 8, "gateway_close", message)
    e.dispatch(1, 8, "stats")
    assert(e.result.clients == 1, "unauthorized close must be rejected")
    local original = message.gateway_epoch
    message.gateway_epoch = "old"
    e.dispatch(0, 7, "gateway_close", message)
    e.dispatch(1, 8, "stats")
    assert(e.result.clients == 1)
    message.gateway_epoch = original
    e.dispatch(0, 7, "gateway_close", message)
    e.dispatch(0, 7, "gateway_close", message)
    assert(#e.sends == 3 and e.sends[3][2] == "gateway_disconnect")
    e.dispatch(1, 8, "stats")
    assert(e.result.clients == 0)
    resume(e.forks[3])
    assert(e.closed[10])
    -- fd 被新连接复用后，原关闭命令不能关闭新连接。
    e.streams[10] = frame(2)
    e.closed[10] = nil
    e.accept(10, "peer")
    resume(e.forks[4])
    e.dispatch(0, 7, "gateway_close", message)
    e.dispatch(1, 8, "stats")
    assert(e.result.clients == 1 and not e.closed[10])
end

-- 项目自定义返回路径要显式提供关闭函数；失败允许重试，且 options 修改不影响快照。
e = scenario()
e.streams[10] = frame(1)
e.accept(10, "peer")
resume(e.forks[2])
endpoint = require "flywow.gateway.endpoint"
options =
{
    request = e.sends[1][3],
}
-- 自定义发送函数由项目提供，测试只需要声明合法返回值。
function options.send() return true end
context = endpoint.new(options)
ok, code = context:close()
assert(not ok and code == "CLOSE_UNAVAILABLE")
fail = true
-- 自定义关闭的失败不会把上下文永久标记为已关闭。
function options.close(message) return not fail end
context = endpoint.new(options)
options.close = nil
ok, code = context:close()
assert(not ok and code == "SEND_FAILED")
fail = false
assert(context:close())
print("GATEWAY_ASYNC_UNIT_OK")
