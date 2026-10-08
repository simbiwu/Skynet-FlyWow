# 目录迁移、兼容与回滚

本次是尚未发布的开发迁移。提交和发布前，宿主用显式 `FLYWOW_ROOT` 指向开发源；不把旧 submodule gitlink 当成已经支持新布局的正式版本。

| 旧入口 | 新入口 |
| --- | --- |
| FlyWow `lualib/...` | `gateway/lualib/...` |
| FlyWow `service/flywow_gateway.lua` 或 `service/gateway/flywow_gateway.lua` | `gateway/service/gateway/flywow_gateway.lua` |
| `native/gateway_crypto` | `gateway/native/gateway_crypto` |
| `clients/unity` / `clients/h5` | `gateway/clients/unity` / `gateway/clients/h5` |
| Gateway registry 生成工具 | `gateway/tools/generate_gateway_registry.py` |
| Gateway crypto 构建脚本 | `scripts/build_flywow.sh` |
| 宿主 `native/grid_map` 源码 | `navigation/native/grid_map` |
| 宿主 `native/lua_battle_nav` 源码 | `navigation/native/lua` |
| `require "battle_nav"` | `require "flywow_navigation"` |
| `battle_nav.so` / `luaopen_battle_nav` | `flywow_navigation_native.so` / `luaopen_flywow_navigation_native` |
| Unity `BattleMap*` 通用组件 | `FlyWow.Navigation.NavigationMap*`，原脚本 GUID 保留 |

宿主旧 Native make 入口可以保留为薄适配器；它们委托 FlyWow 构建，不保留第二份算法。UPM 包、Native 模块、Lua 调用方和相对搜索路径必须成套更新。已有 Scene 保留参数；课程 SceneBuilder 要显式设置课程 ID/原点，不能依赖通用包默认值。

Gateway 采用宿主已验证的当前合同：Envelope 只有 version/command/body，CommandId 生成 registry，双向 `send_data`，`close` 控制消息。早期 sibling 开发版本的 `gateway_dispatch/gateway_response`、request_id、rpc 生成规则以及 endpoint helper 不再与现行实现混放。该兼容变化由 D011 记录，旧消费者需按 Gateway 接入指南迁移双方协议，不能只更换目录。

BMAP V1 内容保持兼容，Manifest 新增空间与 SHA-256 是发布门禁要求。已有 BMAP 可保持字节不变，用完整文件计算 SHA-256 并补齐清单，然后验证；不要虚构 hash。正式发布仍需锁定 map_id/map_version/hash。

回滚使用原框架提交、原宿主 Adapter、原 Unity 文件/包和原协议产物的完整组合。地图格式未改变，可使用已验证的旧 BMAP。不要让新 Lua 加载旧 `.so`，不要同时安装旧脚本和保留同 GUID 的新 Package。发布后再同步固定 submodule 提交；本迁移不自动 commit、push 或发布 Release。


## 单位边缘范围与部分路径

`find_path_to_range(profile_id, start, target, range_mm, mover_unit_id[, allow_partial])`
保持中心距离语义。`find_path` 也在最后增加同样的可选参数。省略、nil、false
均关闭部分路径；错误类型返回 `INVALID_ARGUMENT`。

新增 `find_path_to_unit_range(mover_profile_id, start_world, target_profile_id,
target_world, edge_range_mm, mover_unit_id[, allow_partial])`。双方半径来自 Context
构造时复制的 Profile，目标位置和 Profile 必须由调用者保持一致，不反查 Occupancy。
`mover_unit_id` 用于忽略移动者自身占位。允许重叠也不把目标圆形体型内部作为终点。
正范围的终点满足 `r_mover+r_target <= 中心距离 <= r_mover+r_target+edge_range_mm`。
这只约束终点，沿途仍使用原有格子重叠策略。

零范围采用 `ceil(sqrt(2)*cell_size_mm)` 接近容差，在容差内选择中心距离最小的
可达合法格，再按路径成本、格子索引打破平局。需要遍历当前可达区域，最坏与 NO_PATH
搜索相同。该规则是格子接近，不是几何接触；静态净空与动态占位仍可能返回 NO_PATH。

成功结果可调用 `path:status()`：`reached` 表示终点满足查询目标；`partial` 表示
搜索耗尽后返回最接近目标中心的可达合法格（单位查询排除体型内部）。距离相同按
最低已走成本、稳定格子索引选择。默认关闭；非法参数、越界、非法起点不会转为成功。
没有更接近目标的实际移动仍返回 NO_PATH。精确终点不可站立时默认返回
END_NOT_NAVIGABLE；开启 partial 后继续搜索。查询状态与 advance_path 的执行状态独立。
旧 Lua 调用保持兼容；新增 C++ 可选参数需要重新编译使用者。
