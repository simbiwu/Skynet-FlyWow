# 目录迁移、兼容与回滚

本次是尚未发布的开发迁移。提交和发布前，宿主用显式 `FLYWOW_ROOT` 指向开发源；不把旧 submodule gitlink 当成已经支持新布局的正式版本。

| 旧入口 | 新入口 |
| --- | --- |
| FlyWow `lualib/...` | `gateway/lualib/flywow/gateway/...` |
| FlyWow `service/flywow_gateway.lua` 或 `service/gateway/flywow_gateway.lua` | `gateway/service/flywow_gateway.lua` |
| `native/gateway_crypto` | `gateway/native/gateway_crypto` |
| `clients/unity` / `clients/h5` | `gateway/unity` / `gateway/h5` |
| Gateway registry 生成工具 | `gateway/tools/generate_gateway_registry.py` |
| Gateway crypto 构建脚本 | `gateway/scripts/build_gateway_crypto.sh` |
| 宿主 `native/grid_map` 源码 | `navigation/native/grid_map` |
| 宿主 `native/lua_battle_nav` 源码 | `navigation/native/lua` |
| `require "battle_nav"` | `require "flywow.navigation"` |
| `battle_nav.so` / `luaopen_battle_nav` | `flywow_navigation.so` / `luaopen_flywow_navigation` |
| Unity `BattleMap*` 通用组件 | `FlyWow.Navigation.NavigationMap*`，原脚本 GUID 保留 |

宿主旧 Native make 入口可以保留为薄适配器；它们委托 FlyWow 构建，不保留第二份算法。UPM 包、Native 模块、Lua 调用方和路径配置必须成套更新。已有 Scene 保留参数；课程 SceneBuilder 要显式设置课程 ID/原点，不能依赖通用包默认值。

Gateway 采用宿主已验证的当前合同：Envelope 只有 version/command/body，CommandId 生成 registry，双向 `send_data`，`close` 控制消息。早期 sibling 开发版本的 `gateway_dispatch/gateway_response`、request_id、rpc 生成规则以及 endpoint helper 不再与现行实现混放。该兼容变化由 D011 记录，旧消费者需按 Gateway 接入指南迁移双方协议，不能只更换目录。

BMAP V1 内容保持兼容，Manifest 新增空间与 SHA-256 是发布门禁要求。已有 BMAP 可保持字节不变，用完整文件计算 SHA-256 并补齐清单，然后验证；不要虚构 hash。正式发布仍需锁定 map_id/map_version/hash。

回滚使用原框架提交、原宿主 Adapter、原 Unity 文件/包和原协议产物的完整组合。地图格式未改变，可使用已验证的旧 BMAP。不要让新 Lua 加载旧 `.so`，不要同时安装旧脚本和保留同 GUID 的新 Package。发布后再同步固定 submodule 提交；本迁移不自动 commit、push 或发布 Release。
