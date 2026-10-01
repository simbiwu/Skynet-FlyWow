# 工程决策

## D001 - 独立仓库

Skynet-FlyWow 使用独立 Git 仓库。课程项目是实现和教学来源之一，不作为框架运行时依赖，也不通过目录复制长期维护两份实现。

## D002 - 模块化而非全栈预制

框架提供可独立选择的基础模块。横向模块之间不建立不必要依赖，由宿主 composition root 组装。

## D003 - 真实需求后抽取

没有真实调用者、可运行实现和测试的能力不进入框架。第二个消费者或第二种实现出现后，再从事实中抽取公共扩展点。

## D004 - P0 编码与中文注释合同

`.agents/skills/skynet-flywow-coding-standard/SKILL.md` 是实现和评审的强制门槛。源码注释与工程文档使用中文，注释描述领域合同、ownership、失败、yield/I/O 和不变量，不只翻译语法。

## D005 - 远端已确定，发布和许可证暂缓

远端固定为 `https://github.com/simbiwu/Skynet-FlyWow.git`。许可证、首个固定 Skynet/Lua 版本和模块发布载体由用户后续确认；不得因为仓库公开就擅自假设开源许可、创建 Release 或建立不兼容承诺。

## D006 - UTF-8、LF 与自动质量门禁

源码注释和文档使用中文，需要跨 Windows、WSL 和 Linux Runner 保持稳定编码与 diff。仓库通过 `.editorconfig`、`.gitattributes`、自检工具及 GitHub CI 固定 UTF-8、LF、末尾换行、必要文档和 Skill 合同。该门禁只覆盖仓库基线，不能代替模块 build、运行或集成测试。
## D007 - 地图、寻路与战斗模块保持空间中立


FlyWow 后续可以承载静态地图、导航查询和确定性战斗，但不把任何游戏的 Battle/SLG DTO 放进框架。公共合同使用整数世界/逻辑坐标、地图 ID、版本和内容 hash；manifest 声明空间类型、坐标轴、原点、Cell 尺寸和资产格式版本。

当前真实调用者是 2.5D Ground Grid。未来 H5 俯视角 2D 可以复用 Grid A*、动态占位、BattleWorker 和 Replay，Unity 与 H5 只替换离线资产导入器及表现层 Adapter。横版平台的重力、跳跃和多层平台是不同运动模型，必须有独立实现和测试。

网络、地图、寻路和战斗模块形成单向依赖：Gateway 不依赖地图，地图/寻路不依赖网络，战斗核心不依赖客户端协议。只有第二个真实消费者或第二种空间实现出现后，才从共同调用面提取公开扩展点，不提前创建空接口。


## D008 - Gateway 数据平面采用双向异步本地消息

Gateway 按连接顺序读取、解码并 skynet.send 到显式 handler，投递后继续读下一帧。handler 完成后另 send gateway_response；Gateway 根据消息携带的实例、连接、命令和请求编号编码发送，不保存业务等待表，不依赖 Cluster，不负责业务路由或可靠性。endpoint 是薄的可选辅助模块；handler 自己负责业务错误和有界执行。

旧 call/retpack handler 必须连同宿主一起迁移。既有 Envelope 和 .proto RPC 定义不变；编号0保留给已登记响应类型的主动消息。连接身份不复用，Gateway 启动身份隔离重启前结果。公开合同、配置、资源限制和升级/回滚说明见 docs/gateway/README.md。速率限制不等于对任意下游 mailbox 的硬容量保证，未经容量/soak 验证不宣称商业部署规模。


## D009 - 业务侧主动断开采用异步控制消息

endpoint context:close 单向投递 gateway_close；关闭 record 只有 Gateway 启动身份和连接编号。Gateway 只接受绑定 handler 来源，先摘除并发出一次断线通知，再关闭 transport；重复/失效请求幂等忽略，不建立等待或 token 表。跨进程返回函数由宿主显式注入，FlyWow 不依赖 Cluster。关闭后当前 context 不再回复；投递成功不代表网络关闭帧或最后响应已经到达对端。

## D010 - Gateway 内置独立连接握手

Gateway与客户端SDK完成P-256 ECDH、32字节随机挑战、HKDF-SHA256及双向HMAC-SHA256，验证后ready。合法协议客户端仅指完成握手，无登录/账号授权前提；宿主不管理secret或会话，不要求Watchdog。独立handshake模块管理状态、并发及期限，不写Socket。Native仅链接OpenSSL 3的libcrypto EVP（不链接libssl、不启用SSL/TLS），拥有敏感状态，无共享可变scratch。成功/失败均释放。

业务协议和D008异步链路保持现状，不增加包头加密、CRC、逐包校验。握手使用现有TCP framing或WS binary，按连接状态区分控制/业务消息。固定字节、公开SDK、依赖与回滚见docs/gateway/HANDSHAKE.md。连接协议不兼容旧客户端，双端同时升级，不降级。
