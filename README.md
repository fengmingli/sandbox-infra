# sandbox-infra

macOS 上一键搭建**通用开发沙箱基础环境**：代码留在 Mac（bind mount 挂载），语言工具链与 AI agent 全部运行在 Linux 容器内。装好即用，按需拓展。

```
宿主机 macOS
├── ~/Workspace/<你的项目>/        ← 代码（唯一真实来源）
│   ├── Dockerfile / compose.yaml  ← 安装脚本生成
│   └── sandbox.sh                 ← 快捷命令
└── Docker Desktop
    └── dev 容器（语言工具链 + AI agent + gh + zsh）
        ├── /workspace ← 挂载项目目录（双向实时）
        ├── 包/编译缓存 → docker 卷（不占挂载区）
        └── 端口 8080 → localhost:8080
```

## 特性

- 一条命令安装：clone 后运行（或海外网络 curl 直装），无需任何其他工具
- **三种语言栈可选**：`--stack go|node|python`（默认 go）
- **多 AI agent 可组合**：`--with claude|codex|pi|opencode`（默认 claude），凭据目录自动挂载持久化
- 代码双向实时挂载，Mac 保持干净（语言环境、依赖、编译产物全在容器）
- 包缓存走 docker 卷，重建容器不重新下载依赖
- 附带 VS Code Dev Container 配置（Reopen in Container 一键进入）

## 前置要求

- macOS（Apple Silicon 最佳；Intel 可用但走模拟，性能受限）
- Docker Desktop（脚本会自动启动它；未安装时给出安装指引）

## 快速开始

```bash
# 方式一（推荐，不依赖 raw.githubusercontent.com）：clone 后运行
git clone --depth 1 https://github.com/fengmingli/sandbox-infra /tmp/sandbox-infra \
  && bash /tmp/sandbox-infra/install.sh ~/Workspace/myapp \
  && rm -rf /tmp/sandbox-infra

# 方式二：海外网络可直接 curl（raw.githubusercontent.com 国内通常不可达）
curl -fsSL https://raw.githubusercontent.com/fengmingli/sandbox-infra/main/install.sh | bash -s -- ~/Workspace/myapp
```

安装过程：检查并启动 Docker → 生成沙箱配置 → 构建镜像 → 启动 → 自动验证（工具链版本、agent 可用、挂载双向读写）。空目录会附带 hello world 示例，装完即可运行；已有项目只生成沙箱配置，不动你的代码。

### 选择栈与 agent

```bash
bash install.sh --stack node --with codex,pi ~/Workspace/webapp
```

| 栈 | 基础镜像 | 缓存卷 |
|---|---|---|
| `go`（默认） | devcontainers/go:1.25 | go-mod + go-build |
| `node` | devcontainers/javascript-node:22 | npm |
| `python` | devcontainers/python:3.13 | pip |

| agent | CLI 命令 | 挂载的凭据目录 |
|---|---|---|
| `claude`（默认） | `claude` | `~/.claude` `~/.claude.json` |
| `codex` | `codex` | `~/.codex` |
| `pi` | `pi` | `~/.pi`（配置在 `~/.pi/agent`） |
| `opencode` | `opencode` | `~/.local/share/opencode` |

非 claude 的 agent 首次在容器内运行时按提示登录一次，凭据落在挂载目录里，之后容器随便删重建。

## 日常使用

```bash
cd ~/Workspace/myapp
./sandbox.sh up        # 构建并启动
./sandbox.sh in        # 进入沙箱 shell（zsh）
./sandbox.sh ai        # 在沙箱内运行 Claude Code
./sandbox.sh down      # 停止
./sandbox.sh rebuild   # 无缓存重建镜像
./sandbox.sh logs      # 查看容器日志
```

VS Code 用户：装 Dev Containers 扩展后打开项目，命令面板执行 **Dev Containers: Reopen in Container**（配置已指向同一套 compose 服务）。

## 拓展指南

沙箱是基础环境，所有拓展都只改两个生成文件，改完 `./sandbox.sh rebuild` 生效。

**加工具**（如 fzf、tmux）：`Dockerfile` 的 `USER root` 段加一行

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends fzf tmux \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
```

**加 AI agent**（npm 系，如 opencode）：

```dockerfile
# Dockerfile 的 npm install -g 行追加包名
npm install -g @anthropic-ai/claude-code opencode-ai;
```

```yaml
# compose.yaml 的 volumes 追加凭据目录（以 opencode 为例）
      - ${HOME}/.local/share/opencode:/home/vscode/.local/share/opencode
```

**加端口**：`compose.yaml` 的 `ports` 追加，如 `- "5173:5173"`

**加语言栈**：`install.sh` 里的栈配置表加一段（镜像、容器用户、缓存卷、示例文件四项），或直接改生成后的 `Dockerfile` 第一行镜像 tag（如 go 1.24、node 20）

**国内加速**：`Dockerfile` 加 `ENV GOPROXY=https://goproxy.cn,direct`（Go）或 `npm config set registry https://registry.npmmirror.com`（Node）

**amd64 构建验证**（Rosetta）：

```bash
docker compose run --rm --platform linux/amd64 dev go test ./...
```

## 挂载设计

| 宿主机 | 容器内 | 方式 | 说明 |
|---|---|---|---|
| 项目目录 | `/workspace` | bind mount | 双向实时，代码唯一来源在 Mac |
| docker 卷 | 包/编译缓存目录 | named volume | 快且持久 |
| `~/.claude` `~/.codex` `~/.pi` `~/.local/share/opencode` … | 同路径 | bind mount | agent 凭据持久化（按所选 agent） |
| `~/.gitconfig` | 同路径 | 只读 | 容器内提交用本机身份 |
| `~/.ssh` | 同路径 | 只读 | 容器内可 git push（SSH 方式） |

以上宿主机侧文件按「存在才挂载」处理，缺什么就跳过，不影响安装。

## 隔离边界

- **物理隔离范围**：挂载之外的一切 —— Mac 系统、家目录、其他项目，容器内进程无法触碰。
- **挂载边界之内**：容器对项目目录本身有写权限（bind mount 的固有代价）。
- **网络**：默认不限制。如需收紧，可在 Dockerfile 中加防火墙白名单（仅放行 api.anthropic.com、github.com、proxy.golang.org）。

## 常见问题

**容器内 git push 报错 / 想用 HTTPS 凭证？**
macOS 的 `osxkeychain` credential helper 在 Linux 容器里不可用。用 SSH remote（`~/.ssh` 已挂入），或在容器内执行 `gh auth login` 让 gh 充当 credential helper。

**Docker daemon 没启动？**
脚本会自动 `open -a Docker` 并等待就绪（最长约 2 分钟）。

**想换 OrbStack？**
完全兼容：装好 OrbStack 后配置一个字都不用改，`docker compose` 自动走 OrbStack。

## 仓库结构

```
install.sh    # 唯一核心：自包含安装脚本，所有模板内嵌（heredoc）
README.md
LICENSE
```

## License

MIT
