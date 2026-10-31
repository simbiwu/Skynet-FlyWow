# Gateway 示例

三个 sample 都启动真实 Gateway，并完成同一业务流程：客户端握手后发送 FrameJoin；Gateway 解码请求并转给 handler；handler 返回 FrameJoinResponse，再通过 FramePush 主动推送；客户端校验回包和 Push 后断开。

从 FlyWow 根目录执行：

    bash gateway/sample/websocket/run.sh ../skynet
    bash gateway/sample/tcp_protobuf/run.sh ../skynet
    bash gateway/sample/tcp_binary/run.sh ../skynet

如果协议产物缺失，先从仓库根目录运行：bash server/protocol/build_protocol_lesson_03_frame_sync.sh。依赖：Node.js 22 或更高版本。缺少 flywow_gateway_crypto.so 时，脚本调用现有 scripts/build_flywow.sh 构建。日志在 build/gateway-sample/<模式>/；成功时客户端打印回包和 Push 校验，Skynet 输出 FLYWOW_GATEWAY_SAMPLE_OK mode=<模式>。

| Sample | 传输和消息 | 重点 |
| --- | --- | --- |
| [WebSocket](websocket/说明.md) | H5 SDK + WebSocket binary message + Protobuf Envelope | 握手、请求、回包和 Push |
| [TCP Protobuf](tcp_protobuf/说明.md) | TCP uint16 大端长度帧 + Protobuf Envelope | 字段编码和解码 |
| [TCP 二进制帧](tcp_binary/说明.md) | TCP 长度帧 + 固定 Protobuf wire bytes | 查看线上字节帧 |

Gateway 当前支持 TCP/WebSocket 两种传输；Envelope 和业务消息都使用 Protobuf。二进制帧 sample 展示线上 framing，不代表独立原始二进制 codec。

flywow_gateway_sample.lua 启动 handler 和 Gateway。请求命令 1101 FrameJoin；服务端回包使用命令 1101，主动下发使用命令 1103 FramePush。两者都通过 send_data 定向发送到当前连接，客户端实际接收并校验。


## Master Course TCP/WebSocket 示例

先准备固定依赖，再选择传输方式运行：

```bash
bash gateway/sample/master_course/run.sh prepare
bash gateway/sample/master_course/run.sh websocket client
bash gateway/sample/master_course/run.sh tcp client
```

`prepare` 会调用课程目录中的 `bootstrap.sh`，复用 Server 固定版本准备脚本，按需构建 Skynet、lua-protobuf 和 Gateway Crypto。运行脚本会在启动前生成本课程的 Descriptor 和 Registry。需要单独以前台启动服务时运行 `bash gateway/sample/master_course/run.sh websocket server`。
