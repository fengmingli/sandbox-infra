# go-dev-sandbox

macOS 上一键搭建本地开发沙箱：**代码留在 Mac（bind mount 挂载），Go 工具链与 AI（Claude Code）全部运行在 Linux 容器内**。

```
宿主机 macOS
├── ~/Workspace/<你的项目>/        ← 代码（唯一真实来源）
│   ├── Dockerfile / compose.yaml  ← 安装脚本生成
│   └── sandbox.sh                 ← 快捷命令
└── Docker Desktop
    └── dev 容器（Go + Node + Claude Code + gh）
        ├── /workspace ← 挂载项目目录（双向实时）
        ├── Go 模块/编译缓存 → docker 卷（不占挂载区）
        └── 端口 8080 → localhost:8080
```

## 特性

- 一条命令安装：`curl` 直装或 clone 后运行，无需任何其他工具
- 代码双向实时挂载，Mac 保持干净（语言环境、依赖、编译产物全在容器）
- Go 模块缓存、编译缓存走 docker 卷，重建容器不重新下载依赖
- 容器内 `claude` 直接复用宿主机登录态；`git`、`gh`、`zsh` 开箱即用
- 默认 Linux arm64 原生速度；需要 amd64 验证时走 Rosetta 一条命令切换
- 附带 VS Code Dev Container 配置（Reopen in Container 一键进入）

## 前置要求

- macOS（Apple Silicon 最佳；Intel 可用但走模拟，性能受限）
- Docker Desktop（脚本会自动启动它；未安装时给出安装指引）

## 快速开始

```bash
# 方式一：curl 直接安装到指定项目（无需 clone 本仓库）
curl -fsSL https://raw.githubusercontent.com/fengmingli/go-dev-sandbox/main/install.sh | bash -s -- ~/Workspace/myapp

# 方式二：clone 后运行
git clone https://github.com/fengmingli/go-dev-sandbox.git
./go-dev-sandbox/install.sh ~/Workspace/myapp
```

安装过程：检查并启动 Docker → 生成沙箱配置 → 构建镜像 → 启动 → 自动验证（Go 版本、Claude Code、挂载双向读写）。空目录会附带 hello world 示例，装完即可 `go run .`。

对已有项目同样适用：非空目录只生成沙箱配置，不动你的代码。

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

## 挂载设计

| 宿主机 | 容器内 | 方式 | 说明 |
|---|---|---|---|
| 项目目录 | `/workspace` | bind mount | 双向实时，代码唯一来源在 Mac |
| docker 卷 | `/go/pkg/mod` | named volume | 模块缓存，快且持久 |
| docker 卷 | `~/.cache/go-build` | named volume | 编译缓存 |
| `~/.claude` / `~/.claude.json` | 同路径 | bind mount | 容器内 claude 复用登录态 |
| `~/.gitconfig` | 同路径 | 只读 | 容器内提交用本机身份 |
| `~/.ssh` | 同路径 | 只读 | 容器内可 git push（SSH 方式） |

以上宿主机侧文件按「存在才挂载」处理，缺什么就跳过，不影响安装。

## 隔离边界

- **物理隔离范围**：挂载之外的一切 —— Mac 系统、家目录、其他项目，容器内进程无法触碰。
- **挂载边界之内**：容器对项目目录本身有写权限（bind mount 的固有代价）。
- **网络**：默认不限制。如需收紧，可在 Dockerfile 中加防火墙白名单（仅放行 api.anthropic.com、github.com、proxy.golang.org）。

## 自定义

- **Go 版本**：改 `Dockerfile` 第一行 tag（`1.25` / `1.24` …）
- **端口**：改 `compose.yaml` 的 `ports`
- **国内加速 Go 模块**：`Dockerfile` 加一行 `ENV GOPROXY=https://goproxy.cn,direct`
- **amd64 构建验证**（Rosetta）：
  ```bash
  docker compose run --rm --platform linux/amd64 dev go test ./...
  ```

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
