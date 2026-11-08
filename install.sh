#!/usr/bin/env bash
#
# go-dev-sandbox — macOS 本地开发沙箱一键安装
#
# 在目标目录生成一套基于 Docker 的 Go 开发沙箱：
# 代码通过 bind mount 挂载留在 Mac，Go 工具链与 Claude Code 全部运行在容器内。
# 安装过程自动完成：启动 Docker → 生成配置 → 构建镜像 → 启动 → 验证。
#
# 用法:
#   ./install.sh [目标目录] [选项]
#   curl -fsSL https://raw.githubusercontent.com/fengmingli/go-dev-sandbox/main/install.sh | bash -s -- ~/Workspace/myapp
#
# 选项:
#   --force    覆盖已存在的沙箱配置文件
#   -h,--help  显示本帮助

set -euo pipefail

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

FORCE=0
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) TARGET="$1" ;;
  esac
  shift
done

info() { printf '\033[1;32m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 前置检查 ----------
[ "$(uname -s)" = "Darwin" ] || die "此脚本面向 macOS。其他平台请参考 README 手动配置。"
[ "$(uname -m)" = "arm64" ] || warn "当前架构 $(uname -m) 非 Apple Silicon，容器将走 Rosetta 模拟，性能明显受限。"

command -v docker >/dev/null 2>&1 || die "未安装 docker。请先安装 Docker Desktop:  brew install --cask docker-desktop"

if ! docker info >/dev/null 2>&1; then
  info "Docker daemon 未运行，正在启动 Docker Desktop ..."
  open -a Docker || die "无法启动 Docker.app，请手动打开后重试。"
  i=0
  until docker info >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -ge 60 ] && die "等待 Docker daemon 超时（约 2 分钟），请手动启动 Docker Desktop 后重试。"
    sleep 2
  done
  info "Docker daemon 已就绪"
fi

docker compose version >/dev/null 2>&1 || die "docker compose 不可用，请升级 Docker Desktop。"

# ---------- 目标目录 ----------
TARGET="${TARGET:-$PWD}"
TARGET="${TARGET/#\~/$HOME}"
mkdir -p "$TARGET" || die "无法创建目录: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"

if [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
  SCAFFOLD_DEMO=0
  info "目标目录非空: ${TARGET}（不生成示例代码）"
else
  SCAFFOLD_DEMO=1
  info "目标目录为空: ${TARGET}（将附带 hello world 示例）"
fi

emit() { # emit <path>  — 内容从 stdin 读入；已存在则跳过，--force 覆盖
  local path="$1" rel="${1#"$TARGET"/}"
  if [ -e "$path" ] && [ "$FORCE" -eq 0 ]; then
    info "已存在，跳过: ${rel}（--force 可覆盖）"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  info "写入: $rel"
}

# ---------- 按宿主机现状决定挂载（compose 运行时再展开 ${HOME}）----------
MOUNTS="      - .:/workspace
      - go-mod-cache:/go/pkg/mod
      - go-build-cache:/home/vscode/.cache/go-build
      - \${HOME}/.claude:/home/vscode/.claude"
if [ -f "$HOME/.gitconfig" ]; then
  MOUNTS+=$'\n      - ${HOME}/.gitconfig:/home/vscode/.gitconfig:ro'
fi
if [ -f "$HOME/.claude.json" ]; then
  MOUNTS+=$'\n      - ${HOME}/.claude.json:/home/vscode/.claude.json'
fi
if [ -d "$HOME/.ssh" ]; then
  MOUNTS+=$'\n      - ${HOME}/.ssh:/home/vscode/.ssh:ro'
fi

# ---------- 生成配置文件 ----------
emit "$TARGET/Dockerfile" <<'DOCKERFILE'
FROM mcr.microsoft.com/devcontainers/go:1.25

USER root
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    npm install -g @anthropic-ai/claude-code; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# 预建缓存目录并赋予 vscode 属主：否则 named volume 首次挂载时挂载点归 root，
# 容器内用户无法写入（go build / module cache 会报 permission denied）。
RUN mkdir -p /home/vscode/.cache/go-build /go/pkg/mod \
 && chown -R vscode:vscode /home/vscode/.cache /go

USER vscode
RUN git config --global --add safe.directory '*'
DOCKERFILE

emit "$TARGET/compose.yaml" <<COMPOSE
services:
  dev:
    build: .
    init: true
    tty: true
    stdin_open: true
    working_dir: /workspace
    command: sleep infinity
    ports:
      - "8080:8080"
    volumes:
$MOUNTS

volumes:
  go-mod-cache:
  go-build-cache:
COMPOSE

emit "$TARGET/.devcontainer/devcontainer.json" <<'DEVCONTAINER'
{
  "name": "go-sandbox",
  "dockerComposeFile": "../compose.yaml",
  "service": "dev",
  "workspaceFolder": "/workspace",
  "remoteUser": "vscode",
  "customizations": {
    "vscode": {
      "extensions": ["golang.go", "anthropic.claude-code"]
    }
  }
}
DEVCONTAINER

emit "$TARGET/sandbox.sh" <<'SANDBOX_SH'
#!/usr/bin/env bash
# 沙箱快捷命令
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  up)      docker compose up -d --build ;;
  in)      docker compose exec dev zsh ;;
  ai)      docker compose exec dev claude ;;
  down)    docker compose down ;;
  rebuild) docker compose build --no-cache && docker compose up -d ;;
  logs)    docker compose logs -f ;;
  *)
    cat <<'USAGE'
用法: ./sandbox.sh <命令>
  up        构建并启动沙箱
  in        进入沙箱 shell
  ai        在沙箱内运行 Claude Code
  down      停止沙箱
  rebuild   无缓存重建镜像并启动
  logs      查看容器日志
USAGE
    exit 1
    ;;
esac
SANDBOX_SH
chmod +x "$TARGET/sandbox.sh"

if [ "$SCAFFOLD_DEMO" -eq 1 ]; then
  emit "$TARGET/go.mod" <<'GO_MOD'
module hello

go 1.25
GO_MOD
  emit "$TARGET/main.go" <<'GO_MAIN'
package main

import "fmt"

func main() {
	fmt.Println("hello from sandbox 🐳")
}
GO_MAIN
fi

# ---------- 构建、启动、验证 ----------
dc() { docker compose -f "$TARGET/compose.yaml" --project-directory "$TARGET" "$@"; }

info "构建并启动沙箱（首次需拉取基础镜像，可能耗时数分钟）..."
dc up -d --build

info "验证 Go 工具链: $(dc exec -T dev go version)"
if dc exec -T dev claude --version >/dev/null 2>&1; then
  info "验证 Claude Code ✓"
else
  warn "claude --version 未通过（不影响沙箱本身，可稍后运行 ./sandbox.sh ai 检查）"
fi

if dc exec -T dev bash -c 'echo ok > /workspace/.sandbox-write-test' \
  && [ -f "$TARGET/.sandbox-write-test" ]; then
  rm -f "$TARGET/.sandbox-write-test"
  info "验证挂载双向读写 ✓"
else
  warn "挂载读写验证未通过，请检查 compose.yaml"
fi

cat <<EOF

✅ 沙箱就绪: $TARGET

常用命令:
  cd "$TARGET"
  ./sandbox.sh in        # 进入沙箱 shell
  ./sandbox.sh ai        # 在沙箱内运行 Claude Code
  ./sandbox.sh down      # 停止沙箱

EOF
