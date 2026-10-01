# FlyWow Gateway 握手合同

首次接入先按[完整接入指南](INTEGRATION.md)构建、配置和连接；本文件供实现其他客户端或审阅字节合同使用。

## 范围与流程

Gateway和客户端SDK完成P-256密钥交换、32字节随机挑战、HKDF-SHA256和双向HMAC-SHA256证明，完成后进入ready。合法客户端指成功完成协议握手的客户端，不附带账号授权。无需登录、宿主会话表或Watchdog。业务Service使用本框架的异步收发合同，见[模块说明](README.md)。

不增加包头加密、CRC、逐包HMAC、账号或自动重连。Envelope和业务协议版本3不变；连接协议不兼容旧客户端，双端一起更新，不自动降级。

```text
接纳连接 -> CLIENT_HELLO -> SERVER_CHALLENGE -> CLIENT_PROOF -> SERVER_READY
                                                            |
                                                            v
                                                           ready
                                                            |
                       读业务帧 -> 解码 -> send handler
                       独立响应入口 -> 编码 -> 写客户端
```

Gateway拥有fd及连接；`flywow.gateway.handshake`拥有状态机、并发计数和期限；`flywow_gateway_crypto` Native userdata拥有敏感数据。握手模块不写Socket、不引用业务、不创建Service或协程。同步密码运算只在握手执行，不yield。

## 固定字节合同

| 类型 | 内容 | 长度 |
| --- | --- | ---: |
| 1 HELLO | 类型1B、握手版本1B、公钥65B | 67B |
| 2 CHALLENGE | 类型1B、握手版本1B、公钥65B、随机挑战32B | 99B |
| 3 CLIENT_PROOF | 类型1B、HMAC32B | 33B |
| 4 SERVER_READY | 类型1B、HMAC32B | 33B |

偏移以单条应用消息的第一个字节为0；不含TCP长度头或WebSocket frame头：

| 消息 | 字段 | 偏移 | 字节数 |
| --- | --- | ---: | ---: |
| HELLO | type=1 / version=1 | 0 / 1 | 各1 |
| HELLO | 客户端公钥04 + X + Y | 2..66 | 65 |
| CHALLENGE | type=2 / version=1 | 0 / 1 | 各1 |
| CHALLENGE | 服务端公钥04 + X + Y | 2..66 | 65 |
| CHALLENGE | 随机挑战，用作HKDF salt | 67..98 | 32 |
| PROOF | type=3 / client-proof HMAC | 0 / 1..32 | 1 / 32 |
| READY | type=4 / server-ready HMAC | 0 / 1..32 | 1 / 32 |

握手版本1；公钥为P-256非压缩`04 || X[32] || Y[32]`，X/Y大端。TCP继续使用uint16大端长度头；WS每条binary message是一条消息。transcript不含TCP长度头。握手类型不占业务command，不加入宿主.proto。

```text
Z = ECDH原始32字节结果
T = SHA256(HELLO完整消息 || CHALLENGE完整消息)
K = HKDF-SHA256(Z, salt=CHALLENGE末尾32字节随机挑战, info=ASCII("flywow/handshake/v1") || T, length=32)
客户端证明 = HMAC-SHA256(K, ASCII("client-proof") || T)
服务端证明 = HMAC-SHA256(K, ASCII("server-ready") || T)
```

HKDF为Extract+Expand；不得把平台默认散列式ECDH结果当成Z。没有空字符、JSON、hex或base64转换。每次连接重新生成密钥。Gateway成功提交READY写入后才置ready；SDK验证服务端证明后才开放业务。握手共232字节，TCP包含长度头共240字节。

## 状态与资源

- Gateway：hello -> proof -> confirm -> ready；失败释放上下文。
- 未ready不投递或缓存业务包；出站业务入口也拒绝未ready连接。
- TCP先检查该阶段精确长度再读body；WS完整消息交给握手模块。
- 待握手计入max_clients；max_pending_handshakes默认min(128,max_clients)。
- handshake_timeout_ticks默认1000，即10秒，从连接登记开始，包含WS Upgrade；消息不刷新期限，复用扫描协程。
- 错误类型/版本/公钥/证明/顺序/写入失败关闭，不在同连接重试，不记录secret、证明或payload。
- 成功后释放临时私钥及派生密钥，只留ready标记；不需要登录会话或重连编号。
- Native擦除敏感数组；Unity托管私钥与Web Crypto内部内存由平台回收，不保证内部副本零残留。
- disconnect合同保持现状，包括握手失败连接；handler应允许从未收到请求的连接断开。

## 独立构建与SDK

```bash
bash scripts/build_gateway_crypto.sh /path/to/pinned-skynet /path/to/host/luaclib
```

使用OpenSSL 3的libcrypto EVP和固定Skynet的Lua头；构建通过pkg-config libcrypto取得头文件与链接参数，只链接libcrypto，不链接libssl、不启用SSL/TLS。运行部署需要匹配的libcrypto.so.3；宿主lua_cpath加入显式输出目录。当前验收版本OpenSSL 3.5.5，部署固定实际包版本。缺少绑定启动失败，不自动降级。Native状态由userdata拥有，API不输出secret。

Unity源码为clients/unity/FlyWowHandshake.cs，构建入口为clients/unity/build.ps1，固定BouncyCastle.Cryptography 2.6.2并校验包哈希；公开API为Begin/Respond/Complete/Ready/Dispose。transport按67/99/33/33字节消息顺序驱动，Complete成功才开放业务；传输失败Dispose并关闭连接。

H5源码为clients/h5/handshake.mjs，connectGateway Promise完成后返回send/close，不要求业务管理secret。需要Web Crypto安全上下文。example.mjs用于接入示例和Node 22互通验收，其QueryCell字节属于示例宿主协议，不由Gateway解释。

## 兼容与验证

握手是连接协议的不兼容升级；Client/Server一起更新，回滚也一起进行，没有旧客户端自动绕过开关。业务Envelope与.proto不改。FRAME_VERSION=1属于框架握手，不是业务协议版本。

测试设置SKYNET_LUA和SKYNET_LUACLIB，然后运行python3 -m unittest discover -s tests -p 'test_*.py'。状态机、Native与Python参考实现互通、重复释放和非法公钥均独立验证；没有显式解释器或绑定时测试skip，不表示通过。

课程集成已验证TCP/WS正常及错误握手、重放拒绝、并发/期限、ready后的异步与主动关闭。Node SDK和C#真实客户端完成Skynet互通。IL2CPP和商业容量未验证，不能扩大结论。

## 独立模块 API

`require "flywow.gateway.handshake".new(options)`接收`crypto`、`now`、`max_pending`、`timeout_ticks`，复制配置标量。`now`返回10ms tick；配置不合法启动失败。

| manager 方法 | 合同 |
| --- | --- |
| accept() | 返回连接独占context，容量耗尽返回nil/HANDSHAKE_CAPACITY；尚不生成密钥 |
| expected_size(context) | 当前入站阶段的精确字节数；TCP读body前检查 |
| receive({context, bytes}) | 只读借用完整帧，返回输出bytes、失败码、是否待确认；失败释放令牌 |
| confirm(context) | transport写成功后提交ready；过期或阶段错误返回false |
| ready(context) / expired(context) | 只读阶段与绝对期限 |
| close(context) | 幂等释放令牌和Native对象；成功连接保留ready标记 |

所有方法不I/O、不yield；关闭实际Socket属于Gateway。Native绑定的`new(hello)`及userdata `verify(proof)`只处理固定字节合同，不能作为Socket或业务接口。

客户端公开合同：Unity使用`HandshakeClient.Begin/Respond/Complete/Ready/Dispose`；H5使用`connectGateway(url, {onmessage, timeoutMs})`，等待Promise返回后调用`send(bytes)`或`close()`。Unity宿主负责transport，H5封装拥有WebSocket。
