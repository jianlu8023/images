FROM node:24-bookworm-slim AS product

ARG PI_AGENT_VERSION=v0.87.1
ARG CODEGRAPH_VERSION=1.6.0
ARG AOCI_VERSION=v0.1.0-rc14
ARG UA_VERSION=v2.9.0
ARG MCP_FS_VERSION=2026.8.31
ARG CONTEXT7_VERSION=4.1.1

# fd ubuntu/debian apt install fd-find ripgrep && ln -s "$(command -v fdfind) /usr/local/bin/fd)"
# fd alpine        apk add --no-cache fd ripgrep
# python3 + PyYAML: skill-creator/scripts/*.py 仅依赖标准库 + yaml
RUN npm config set registry https://registry.npmmirror.com \
  && sed -i 's/deb.debian.org/mirror.nju.edu.cn/g' /etc/apt/sources.list.d/debian.sources \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
     bash ca-certificates git ripgrep fd-find \
     curl jq zip unzip \
     python3 python3-yaml \
  && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
  && mkdir -p /root/.pi/agent/bin \
  && rm -rf /var/lib/apt/lists/*

# uv/uvx：edge-tts、markdown-converter 两个技能的运行依赖（首次调用自动拉包）
# 官方单文件静态版，免装 python3-pip
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# pi 主程序（--ignore-scripts 保持原有行为）
# esbuild 把全平台二进制（darwin/win32/android/freebsd/其余 linux arch...约 20 个平台）
# 都打进 node_modules，同层删掉非本平台部分（删在同层才真正减小镜像），省约 270MB
RUN --mount=type=cache,target=/root/.npm \
  npm install -g --ignore-scripts @earendil-works/pi-coding-agent@$PI_AGENT_VERSION \
  && find /usr/local/lib/node_modules \
       -regextype posix-extended -type d -regex '.*/node_modules/@esbuild/[^/]+' \
       ! -name esbuild ! -name "linux-$(dpkg --print-architecture | sed -e 's/^amd64$/x64/' -e 's/^aarch64$/arm64/')" \
       -prune -exec rm -rf '{}' +

# 浏览器自动化（playwright-cli + chromium）在容器里比较麻烦，暂不安装：
#   RUN --mount=type=cache,target=/root/.npm \
#     npm install -g @playwright/cli@latest
#   RUN node /usr/local/lib/node_modules/@playwright/cli/node_modules/playwright/cli.js install --with-deps chromium
#   并把 skills-offline/playwright-cli 移回 skills/ 后重新构建

# codegraph（本地代码知识图谱 MCP）：
#   npm 包只是 thin-installer（bin 是 npm-shim.js），真正的 per-platform 二进制
#   走 optionalDependencies（esbuild 模式）。部分国内镜像源（npmmirror 等）不
#   提供这些 optionalDependencies，shim 会自愈式回退从 GitHub Releases 下载到
#   ~/.codegraph。构建期跑一次 --version 触发解析，运行时无需联网
RUN --mount=type=cache,target=/root/.npm \
  npm install -g @colbymchenry/codegraph@$CODEGRAPH_VERSION \
  && codegraph --version

# aoci-code（仓库认知索引 MCP，FSL-1.1-MIT）：
#   Go 静态单二进制（CGO-free），从 GitHub Releases 下载即可，无需运行时依赖
RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  ver="${AOCI_VERSION#v}"; \
  curl -fsSL -o /tmp/aoci.tar.gz \
    "https://github.com/aoci-spec/aoci-code/releases/download/${AOCI_VERSION}/aoci_${ver}_linux_${arch}.tar.gz"; \
  tar -xzf /tmp/aoci.tar.gz -C /tmp aoci; \
  install -m 0755 /tmp/aoci /usr/local/bin/aoci; \
  rm -f /tmp/aoci.tar.gz /tmp/aoci; \
  aoci --version

# understand-anything（代码库知识图谱技能包，非 MCP）：
#   官方 install.sh 的 pi 路径 = 克隆仓库到 ~/.understand-anything/repo +
#   把 understand-anything-plugin/skills/* 逐个软链到 ~/.agents/skills/
#   （pi 原生读取该目录）+ ~/.understand-anything-plugin 插件根软链。
#   这里按 tag 固定版本复刻该流程；不直接跑 install.sh 是因为它对已存在的
#   checkout 会执行 git pull --ff-only，tag 浅克隆是 detached HEAD 会失败
RUN git clone --depth 1 --branch $UA_VERSION \
      "https://github.com/Egonex-AI/Understand-Anything.git" /root/.understand-anything/repo \
  && mkdir -p /root/.agents/skills \
  && for d in /root/.understand-anything/repo/understand-anything-plugin/skills/*/; do \
       ln -sfn "$d" "/root/.agents/skills/$(basename "$d")"; \
     done \
  && ln -sfn /root/.understand-anything/repo/understand-anything-plugin /root/.understand-anything-plugin

# mcp-server-filesystem（官方文件系统 MCP，stdio：mcp-server-filesystem <目录>）：
#   目录传 /workspace（容器 WORKDIR），允许读写的工作区即挂载点
# context7（Upstash 文档上下文 MCP，stdio：context7-mcp，运行时需联网）：
#   纯 JS 包，无原生依赖
RUN --mount=type=cache,target=/root/.npm \
  npm install -g --ignore-scripts \
    @modelcontextprotocol/server-filesystem@$MCP_FS_VERSION \
    @upstash/context7-mcp@$CONTEXT7_VERSION \
  && command -v mcp-server-filesystem && context7-mcp --version

# MCP 自动初始化 wrapper：项目没建索引时，MCP 首次连接前自动跑一次 init，
# 保证连上即可用（真身分别挪到 .codegraph-real / .aoci-real）
COPY mcp-wrappers/ /tmp/mcp-wrappers/
RUN mv /usr/local/bin/codegraph /usr/local/bin/.codegraph-real \
  && install -m 0755 /tmp/mcp-wrappers/codegraph /usr/local/bin/codegraph \
  && mv /usr/local/bin/aoci /usr/local/bin/.aoci-real \
  && install -m 0755 /tmp/mcp-wrappers/aoci /usr/local/bin/aoci \
  && rm -rf /tmp/mcp-wrappers

# 先拷配置，pi install 会把包列表写进 settings.json
COPY models.json settings.json AGENTS.md /root/.pi/agent/
# MCP 配置放标准全局位置（pi-mcp-adapter 原生读取，与 Claude Code/Cursor 等共享；
# 不要再放 ~/.pi/agent/mcp.json，新版 adapter 会报迁移警告）
COPY mcp.json /root/.config/mcp/mcp.json
COPY skills/ /root/.pi/agent/skills/

WORKDIR /workspace

# 构建期固化，运行时无需联网：
#   pi-web-access          联网搜索/网页抓取/PDF 抽取（零配置）
#   pi-subagents           子代理委派与多代理工作流
#   pi-mcp-adapter         MCP 支持（项目里放 .mcp.json 即可）
#   @narumitw/pi-btw       /btw 旁路提问，不污染主上下文
#   @narumitw/pi-plan-mode /plan-mode 只读规划模式
#   @narumitw/pi-goal      /goal 自主完成单一目标
#   @quintinshaw/pi-dynamic-workflows 动态工作流
#   @wechatbot/pi-agent    /wechat 微信接入（扫码后微信里对话）—— 暂时不安装
#   @juicesharp/rpiv-ask-user-question  ask_user_question 终端结构化提问对话框（替代模型瞎猜）
#   @dietrichgebert/ponytail     极简主义编码规则集 + /ponytail* 系列技能
#   pi-memory              跨会话记忆：MEMORY.md 长期记忆 / daily 日志 / scratchpad，
#                          纯 markdown 存于 ~/.pi/agent/memory/ —— 暂时不安装：
#                          ① 记忆是全局的、不按项目隔离，一个容器跑多个仓库会串味
#                          ② ~/.pi/agent 未挂卷，容器重建记忆即丢
#                          需要时在下方 RUN 追加一行：pi install --no-approve npm:pi-memory
#                          （核心 6 个工具零配置即装即用；语义搜索需另装 npm i -g @tobilu/qmd，
#                           首次运行要联网下载 embedding 模型，且记忆目录建议挂卷持久化）
# MCP server（pi-mcp-adapter 读 ~/.config/mcp/mcp.json 全局接入，项目 .mcp.json 可覆盖）：
#   codegraph              本地代码知识图谱，stdio：codegraph serve --mcp（wrapper 自动 init，见 mcp-wrappers/）
#   aoci                   仓库认知索引，stdio：aoci mcp（wrapper 自动 init，见 mcp-wrappers/）
#   mcp-server-filesystem  文件系统读写，stdio：mcp-server-filesystem /workspace（工作区即挂载点）
#   context7               Upstash 文档上下文，stdio：context7-mcp（需联网）
# 技能包：
#   understand-anything    /understand 系列技能（知识图谱生成/问答/看板），装在 ~/.agents/skills/
# npm 缓存走 cache mount 不进镜像层；扩展里的多余平台二进制同层删掉
RUN --mount=type=cache,target=/root/.npm \
  pi install --no-approve npm:pi-web-access \
  && pi install --no-approve npm:pi-subagents \
  && pi install --no-approve npm:pi-mcp-adapter \
  && pi install --no-approve npm:@narumitw/pi-btw \
  && pi install --no-approve npm:@narumitw/pi-plan-mode \
  && pi install --no-approve npm:@narumitw/pi-goal \
  && pi install --no-approve npm:@quintinshaw/pi-dynamic-workflows \
  && pi install --no-approve npm:@juicesharp/rpiv-ask-user-question \
  && pi install --no-approve npm:@dietrichgebert/ponytail \
  && find /root/.pi/agent/npm -regextype posix-extended -type d \
       \( -regex '.*/node_modules/@esbuild/[^/]+' \
          ! -name esbuild \
          ! -name "linux-$(dpkg --print-architecture | sed -e 's/^amd64$/x64/' -e 's/^aarch64$/arm64/')" \
          -o -path '*fs-native-extensions/prebuilds/*' ! -name 'linux-*' \
       \) -prune -exec rm -rf '{}' +


# 进程标记（AI_AGENT=pi / PI_CODING_AGENT=true）不设 ENV：
#   pi CLI 启动时自己设置这两个标记，子进程（bash 工具、MCP server 等）自动继承；
#   设成容器级 ENV 会把容器内所有进程都误标为"运行在 pi 中"，故刻意不设

STOPSIGNAL SIGTERM

ENTRYPOINT ["pi"]
