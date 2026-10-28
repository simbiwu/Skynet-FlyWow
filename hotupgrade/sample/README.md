# HotUpgrade 可运行示例

本目录提供一套可独立运行的 HotUpgrade 示例和对应的源码实战教程。master_course/ 是完整示例工程：包含 V1 宿主、V2 正常更新包、故障 Patch、V3 修复包、管理端入口和 Skynet 配置。

## 环境要求

- 从 FlyWow 根目录运行命令。
- Skynet 已在相邻的 ../skynet 目录构建，且 ../skynet/skynet 可执行。
- 如果 build/native/flywow_hotupgrade_native.so 不存在，运行脚本会调用 scripts/build_flywow.sh 构建 HotUpgrade Native 模块。

## 运行

~~~bash
bash hotupgrade/sample/master_course/run.sh ../skynet v1
bash hotupgrade/sample/master_course/run.sh ../skynet normal
bash hotupgrade/sample/master_course/run.sh ../skynet queue
bash hotupgrade/sample/master_course/run.sh ../skynet forward
~~~

每次运行都会启动一个新的 Skynet 进程，并从 master_course/host_v1/ 复制宿主文件、从 master_course/patches/ 复制发布包。脚本只重建专用运行目录 build/hotupgrade-master-course/，不会修改示例源码。日志保存在该运行目录的 course.log。

| 场景 | 观察内容 | 成功标记 |
| --- | --- | --- |
| v1 | V1 初始状态、Service handle 和模块身份 | MASTER_V1_OK |
| normal | 原 Service 原地更新；随后创建的新 Service 从 V2 文件启动 | MASTER_NORMAL_OK |
| queue | 已进入业务 queue 的请求先完成，批次期间的新请求由门禁拒绝 | MASTER_QUEUE_OK |
| forward | 故意使状态恢复失败，再从现场状态发布 V3 修复 | MASTER_FORWARD_OK |

运行失败时先检查终端输出和 build/hotupgrade-master-course/course.log；脚本还会校验 Skynet 退出码及对应成功标记。

## 教程

[从零实现一次完整的 HotUpgrade](./从零实现一次完整的hotupgrade.md) 从 V1 开始，逐步实现同一套示例，再沿真实调用链阅读 HotUpgrade 源码、运行并发实验和故障修复实验。示例目录保留最终完整工程，教程中的“你要编写”步骤仍用于学习者逐阶段搭建，不要求复制旧 Sample 或依赖未说明的文件。
