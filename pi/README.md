# pi-docker

pi coding agent（[earendil-works/pi](https://github.com/earendil-works/pi)）及其 Web 界面
（[agegr/pi-web](https://github.com/agegr/pi-web)）的 Docker 镜像。两个镜像都在构建期
固化全部依赖（npm 包、MCP server、技能包、扩展），运行时无需联网装包，
仅模型 API 调用与个别在线功能（context7、联网搜索等）需要网络。

## 镜像变体

| Dockerfile | 主程序 | npm 包 | 入口 | 端口 | 说明 |
|---|---|---|---|---|---|
| `Dockerfile` | pi（CLI，终端 TUI） | `@earendil-works/pi-coding-agent` | `pi` | 无 | 终端交互，`docker run -it` 使用 |
| `Dockerfile-web` | pi-web（浏览器 UI） | `@agegr/pi-web` | `pi-web` | 30141 | 浏览器会话管理/文件浏览/模型配置；`pi` 命令软链到 pi-web 自带的 `pi-coding-agent` 嵌套副本，不重复安装 |

## 当前版本

| ARG | 版本 | 说明 |
|---|---|---|
| `PI_AGENT_VERSION` | v1.6.0 | pi 主程序（2026-11-20 发布，默认模型 GPT-6.2 Sol） |
| `PI_WEB_VERSION` | 0.18.0 | pi-web，其依赖锁定 `@earendil-works/pi-coding-agent:1.6.0`，与主镜像版本一致 |
| `CODEGRAPH_VERSION` | 1.6.0 | codegraph MCP（本地代码知识图谱） |
| `AOCI_VERSION` | v0.1.0-rc14 | aoci-code MCP（仓库认知索引，Go 单二进制） |
| `UA_VERSION` | v2.9.0 | Understand-Anything 技能包（git tag 浅克隆） |
| `MCP_FS_VERSION` | 2026.8.31 | mcp-server-filesystem（官方文件系统 MCP） |
| `CONTEXT7_VERSION` | 4.1.1 | context7-mcp（Upstash 文档上下文 MCP） |

基础镜像 `node:24-bookworm-slim`（两包均要求 Node ≥ 22.19.0）。

## 构建与运行


```shell
# CLI 镜像（无特性）
docker buildx build -t pi:1.6.0-bookworm-slim -f Dockerfile .

# Web 镜像（特性 web）
docker buildx build -t pi:0.18.0-web-bookworm-slim -f Dockerfile-web .

```

运行：

```shell
# CLI（终端交互）
docker run -it --rm --name pi \
  -v /path/to/your/project:/workspace \
  -v pi-agent-data:/root/.pi/agent \
  pi:1.6.0-bookworm-slim

# 非交互执行命令：CLI 镜像 ENTRYPOINT 是 pi，需 --entrypoint 覆盖
docker run --rm --entrypoint bash pi:1.6.0-bookworm-slim -c 'pi --version'

# Web（浏览器访问 http://<host>:30141）
docker run -it --rm --name pi-web \
  -p 30141:30141 \
  -e PI_WEB_PASSWORD=<强密码> \
  -v /path/to/your/project:/workspace \
  -v pi-agent-data:/root/.pi/agent \
  pi:0.18.0-web-bookworm-slim
```

- `PI_WEB_PASSWORD` 启用浏览器密码登录与 API Basic Auth（web 镜像强烈建议设置，
  不设时服务裸奔在 0.0.0.0，仅可信网络使用）；
- `-p 8080:30141` 换端口也能正常工作，健康检查从 `/proc/net/tcp` 动态取实际监听端口；
- 工作区即挂载点 `/workspace`，filesystem MCP 与 pi 的 cwd 都在该目录；
- `~/.pi/agent` 挂卷保留会话/模型配置/记忆，不挂则容器重建即丢。

## 内置组件

两个镜像均包含（web 镜像的 `pi` 指向 pi-web 嵌套副本，版本随 pi-web 锁定）：

**MCP server**（`mcp.json` 装于 `/root/.config/mcp/mcp.json`，经 pi-mcp-adapter 全局接入，
项目 `.mcp.json` 可覆盖）：

| server | 命令 | 说明 |
|---|---|---|
| codegraph | `codegraph serve --mcp` | 本地代码知识图谱；wrapper 首次连接前自动 init |
| aoci | `aoci mcp` | 仓库认知索引；wrapper 首次连接前自动 init |
| filesystem | `mcp-server-filesystem /workspace` | 官方文件系统 MCP |
| context7 | `context7-mcp` | Upstash 文档上下文（运行时需联网） |

**pi 扩展**（`pi install` 构建期固化）：pi-web-access（联网搜索/抓取）、pi-subagents、
pi-mcp-adapter、@narumitw/pi-btw、@narumitw/pi-plan-mode、@narumitw/pi-goal、
@quintinshaw/pi-dynamic-workflows、@dietrichgebert/ponytail、pi-lens、billion-context、
pi-cache-optimizer、pi-memory。CLI 镜像另装 @juicesharp/rpiv-ask-user-question
（终端提问对话框；web 镜像因无 TTY 不装）。

**技能包**：

- `skills/` → `/root/.pi/agent/skills/`（brainstorming、grilling、systematic-debugging、
  TDD、writing-plans 等 25 个）
- Understand-Anything v2.9.0 → `/root/.agents/skills/`（/understand 系列）
- `skills-offline/` 为未启用的技能（含 playwright-cli，容器内浏览器自动化暂不装）

**其他**：uv/uvx（edge-tts、markdown-converter 技能依赖）、qmd（pi-memory 语义搜索
embedding 引擎）、python3+PyYAML、ripgrep/fd/git/jq 等基础工具。

## 配置说明

- 模型 provider：`models.json` 拷入 `/root/.pi/agent/`，内含示例 custom provider
  （`http://127.0.0.1:3333` 的 Qwen3.8-27B-FP8），**需改成实际推理服务地址与 key**，
  或直接删掉在 pi/pi-web 的 Models 面板里配置；
- `settings.json`：主题、compaction（reserve 62000 / keep 20000）、retry、thinking 预算；
- `AGENTS.md`：拷入 `/root/.pi/agent/` 的全局 agent 规则；
- 进程标记 `AI_AGENT=pi` / `PI_CODING_AGENT=true` 不设容器级 ENV：pi 启动时自行设置并
  被子进程继承，设为 ENV 会误标容器内所有进程，故刻意不设；
- web 镜像设 `PI_WEB_NO_OPEN=1`（容器无浏览器）。

## 版本升级

升级 pi / pi-web 只需改对应 `ARG`（`Dockerfile` 的 `PI_AGENT_VERSION`、
`Dockerfile-web` 的 `PI_WEB_VERSION`）后重新构建；其余组件按需改各自 ARG。
pi-web 的 pi 版本由其 npm 依赖锁定，升级 pi-web 前用
`npm view @agegr/pi-web@<ver> dependencies` 确认其锁定的 pi 版本。
pi 的历史版本与变更见其 [CHANGELOG](https://github.com/earendil-works/pi/blob/main/CHANGELOG.md)。
