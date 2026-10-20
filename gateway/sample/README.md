# Gateway 运行示例

本示例启动真实 WebSocket Gateway，以 FlyWow H5 SDK 完成握手，发送 Lesson 3 FrameJoin，由宿主 handler 返回响应，再校验响应并关闭连接。主流程依次经过客户端、握手、Envelope 解码、handler、Gateway 响应编码、客户端验收和连接关闭。

从 FlyWow 根目录执行命令：bash gateway/sample/run_gateway_sample.sh ../skynet

运行前需要生成 Server 的 Lesson 3 descriptor 和 Gateway Registry，并安装 Node.js 22 或更高版本（提供内置 WebSocket 和 Web Crypto）。脚本在缺少 Gateway Native 库时调用现有构建脚本，在 build/gateway-sample/ 保存日志。

flywow_gateway_sample.lua 负责启动 Gateway 并处理 FrameJoin；gateway_client.mjs 使用公开 H5 SDK 完成握手、编码请求并检查业务响应；skynet_config.lua 提供运行路径。成功时客户端输出校验结果，进程输出 FLYWOW_GATEWAY_SAMPLE_OK。
