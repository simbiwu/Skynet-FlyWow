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
