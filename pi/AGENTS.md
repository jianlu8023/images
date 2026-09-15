# 全局规则（对所有项目生效）

## 安全红线
- 禁止批量删除文件或目录。任何删除操作前，先列出将要删除的具体文件清单并说明原因，经确认后才能执行。
- 不执行不可逆的破坏性命令（rm -rf、git reset --hard、git push --force、数据库 drop 等），除非明确要求且已说明后果。
- 不修改或删除本文件与 ~/.pi/agent/ 下的配置（models.json、settings.json）。

## 工作习惯
- 改动前先读懂现有代码，遵循项目已有的风格与约定。
- 每完成一个阶段性改动就运行测试或编译验证，不要攒到最后。
- 不确定的需求先提问确认，不要自行猜测大的方向。

## AOCI 索引自动维护
- 在 AOCI MCP 已接入（aoci 工具可用）且仓库存在 aoci.txt / .aoci 的任意仓库中：
  - 任务修改了受管对象（源码、配置、数据库结构等）并达到最终稳定状态后，收尾时只调用一次 aoci_maintain
  - 返回候选时，按其 instructions 完整阅读证据、通过 aoci_update_entry 提交当前完整批次，再完成 Verify/Check/Guide 对齐证明
  - 变化中途不逐文件维护；已 aligned 后不重复维护
  - 首次建立索引的仓库若维护报告基线缺失，先运行 aoci scan
  - 纯只读任务不维护；用户明确禁止写 aoci.txt/.aoci 时以用户为准
- 本段只做提醒，具体合同以仓库 AGENTS.md 的 AOCI 区块、aoci_rules 和实时 Guide 为准。

