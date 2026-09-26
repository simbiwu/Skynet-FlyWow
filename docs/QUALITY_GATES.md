# 质量门禁

## 1. 基线原则

每次修改都要给出与风险匹配的证据。文档和仓库配置至少通过仓库自检；具体模块还必须执行自己的 build、运行、成功/边界/失败测试。CI 绿色不能替代尚未纳入 CI 的验证。

## 2. 当前可执行门禁

在仓库根目录运行：

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/ci/check_repository.py
```

第一条验证自检工具本身的成功和失败判断。第二条检查：

- 必要工程文档和 P0 Skill 是否存在；
- 受控文本是否为 UTF-8、LF 且有末尾换行；
- Markdown 是否包含中文正文、代码围栏是否闭合；
- Skill 名称、中文触发描述和初始化占位符是否符合合同。

## 3. CI 边界

GitHub Actions 在 push 到 `main` 和 Pull Request 时执行相同命令。Workflow 使用最小只读权限、并发取消和五分钟超时，并将第三方 Action 固定到审核过的 commit。

当前 CI 只证明仓库基线通过。未来模块进入仓库时，必须在同一变更中增加对应编译、测试、资源清理和必要的集成验证，不能让通用检查器假装覆盖业务行为。

## 4. 结果报告

提交或发布说明分别列出：

```text
build：实际构建的 target
run：实际启动和执行的场景
test：运行的成功、边界和失败用例
benchmark：版本、硬件、负载、时长和 GC 条件
not verified：本次没有验证的边界
```

任何失败都先修复首个根因，不通过关闭校验、减少断言或吞掉错误让门禁变绿。

