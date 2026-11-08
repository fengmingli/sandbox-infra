#!/usr/bin/env bash
#
# sandbox-infra — macOS 本地开发沙箱一键安装（可拓展的基础环境）
#
# 在目标目录生成一套基于 Docker 的开发沙箱：代码 bind mount 留在 Mac，
# 语言工具链与 AI agent 全部运行在 Linux 容器内。默认 go 栈 + Claude Code。
#
# 用法:
#   ./install.sh [目标目录] [选项]
#
# 选项:
#   --stack go|node|python    语言栈（默认 go）
#   --with agent,agent,...    追加 AI agent，可选 claude|codex|gemini|opencode（默认 claude）
#   --force                   覆盖已存在的沙箱配置文件
#   -h, --help                显示本帮助
#
# 示例:
#   ./install.sh ~/Workspace/myapp
#   ./install.sh --stack node --with codex,gemini ~/Workspace/webapp
#   curl -fsSL https://raw.githubusercontent.com/fengmingli/sandbox-infra/main/install.sh | bash -s -- ~/myapp

set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

STACK="go"
AGENTS="claude"
FORCE=0
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --stack) STACK="${2:-}"; shift 2 ;;
    --with)  AGENTS="${AGENTS:+$AGENTS,}${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) TARGET="$1"; shift ;;
  esac
done

info() { printf '\033[1;32m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 语言栈配置 ----------
case "$STACK" in
  go)
    IMAGE="mcr.microsoft.com/devcontainers/go:1.25"
    C_USER="vscode"; C_HOME="/home/vscode"
    CACHE_VOLUMES=$'      - go-mod-cache:/go/pkg/mod\n      - go-build-cache:/home/vscode/.cache/go-build'
    VOLUME_DECLS=$'  go-mod-cache:\n  go-build-cache:'
    CHOWN_DIRS="/home/vscode/.cache/go-build /go/pkg/mod"
    RUN_CMD="go run ."
    DEMO_FILES="go"
    ;;
  node)
    IMAGE="mcr.microsoft.com/devcontainers/javascript-node:22"
    C_USER="node"; C_HOME="/home/node"
    CACHE_VOLUMES="      - npm-cache:/home/node/.npm"
    VOLUME_DECLS="  npm-cache:"
    CHOWN_DIRS="/home/node/.npm"
    RUN_CMD="node index.js"
    DEMO_FILES="node"
    ;;
  python)
    IMAGE="mcr.microsoft.com/devcontainers/python:3.13"
    C_USER="vscode"; C_HOME="/home/vscode"
    CACHE_VOLUMES="      - pip-cache:/home/vscode/.cache/pip"
    VOLUME_DECLS="  pip-cache:"
    CHOWN_DIRS="/home/vscode/.cache/pip"
    RUN_CMD="python3 main.py"
    DEMO_FILES="python"
    ;;
  *) die "未知 --stack: ${STACK}（可选 go|node|python）" ;;
esac

# ---------- AI agent 配置（npm 包名 / 凭据目录）----------
AGENT_NPM_CLAUDE="@anthropic-ai/claude-code";  AGENT_MOUNT_CLAUDE=".claude"
AGENT_NPM_CODEX="@openai/codex";               AGENT_MOUNT_CODEX=".codex"
AGENT_NPM_GEMINI="@google/gemini-cli";         AGENT_MOUNT_GEMINI=".gemini"
AGENT_NPM_OPENCODE="opencode-ai";              AGENT_MOUNT_OPENCODE=".local/share/opencode"
KNOWN_AGENTS="claude codex gemini opencode"

selected=""
seen=" "
IFS=',' read -ra _agents <<< "$AGENTS"
for a in "${_agents[@]}"; do
  a="$(printf '%s' "$a" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  [ -z "$a" ] && continue
  case " $KNOWN_AGENTS " in *" $a "*) ;; *) die "未知 agent: ${a}（可选 claude|codex|gemini|opencode）" ;; esac
  case "$seen" in *" $a "*) ;; *) seen="${seen}${a} "; selected="${selected}${a} " ;; esac
done
selected="${selected% }"
[ -n "$selected" ] || die "至少需要选择一个 agent"

AGENT_PACKAGES=""
AGENT_MOUNT_LINES=""
AGENT_CLIS=""
for a in $selected; do
  up="$(printf '%s' "$a" | tr '[:lower:]' '[:upper:]')"
  pkg_name="AGENT_NPM_${up}"    # 先拼出变量名再间接引用：bash 3.2 兼容
  mnt_name="AGENT_MOUNT_${up}"
  AGENT_PACKAGES="${AGENT_PACKAGES} ${!pkg_name}"
  mp="${!mnt_name}"
  AGENT_MOUNT_LINES+=$'      - ${HOME}/'"${mp}:${C_HOME}/${mp}"$'\n'
  AGENT_CLIS="${AGENT_CLIS} ${a}"
done

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

# ---------- 按宿主机现状补充挂载（compose 运行时再展开 ${HOME}）----------
EXTRA_MOUNTS=""
if [ -f "$HOME/.gitconfig" ]; then
  EXTRA_MOUNTS+=$'\n      - ${HOME}/.gitconfig:'"${C_HOME}/.gitconfig:ro"
fi
if [ -f "$HOME/.claude.json" ]; then
  EXTRA_MOUNTS+=$'\n      - ${HOME}/.claude.json:'"${C_HOME}/.claude.json"
fi
if [ -d "$HOME/.ssh" ]; then
  EXTRA_MOUNTS+=$'\n      - ${HOME}/.ssh:'"${C_HOME}/.ssh:ro"
fi

# ---------- 生成配置文件 ----------
emit "$TARGET/Dockerfile" <<DOCKERFILE
FROM ${IMAGE}

USER root
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    npm install -g ${AGENT_PACKAGES}; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# 预建缓存目录并赋予容器用户属主：否则 named volume 首次挂载时挂载点归 root，
# 容器内用户无法写入（包/编译缓存会报 permission denied）。
RUN mkdir -p ${CHOWN_DIRS} \
 && chown -R ${C_USER}:${C_USER} ${CHOWN_DIRS}

USER ${C_USER}
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
      - .:/workspace
${CACHE_VOLUMES}
${AGENT_MOUNT_LINES}${EXTRA_MOUNTS}

volumes:
${VOLUME_DECLS}
COMPOSE

emit "$TARGET/.devcontainer/devcontainer.json" <<'DEVCONTAINER'
{
  "name": "sandbox-infra",
  "dockerComposeFile": "../compose.yaml",
  "service": "dev",
  "workspaceFolder": "/workspace",
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
  case "$DEMO_FILES" in
    go)
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
      ;;
    node)
      emit "$TARGET/package.json" <<'PKG_JSON'
{
  "name": "hello-sandbox",
  "version": "1.0.0",
  "type": "module",
  "main": "index.js",
  "scripts": {
    "start": "node index.js"
  }
}
PKG_JSON
      emit "$TARGET/index.js" <<'NODE_MAIN'
console.log("hello from sandbox 🐳");
NODE_MAIN
      ;;
    python)
      emit "$TARGET/main.py" <<'PY_MAIN'
print("hello from sandbox 🐳")
PY_MAIN
      ;;
  esac
fi

# ---------- 构建、启动、验证 ----------
dc() { docker compose -f "$TARGET/compose.yaml" --project-directory "$TARGET" "$@"; }

info "构建并启动沙箱（首次需拉取基础镜像，可能耗时数分钟）..."
dc up -d --build

case "$STACK" in
  go)     TOOL_VER="$(dc exec -T dev go version)" ;;
  node)   TOOL_VER="$(dc exec -T dev node --version)" ;;
  python) TOOL_VER="$(dc exec -T dev python3 --version)" ;;
esac
info "验证语言工具链: ${TOOL_VER}"

for cli in $AGENT_CLIS; do
  if dc exec -T dev bash -c "command -v ${cli}" >/dev/null 2>&1; then
    info "验证 agent ${cli} ✓"
  else
    warn "agent ${cli} 未找到（不影响沙箱本身，可稍后检查）"
  fi
done

if dc exec -T dev bash -c 'echo ok > /workspace/.sandbox-write-test' \
  && [ -f "$TARGET/.sandbox-write-test" ]; then
  rm -f "$TARGET/.sandbox-write-test"
  info "验证挂载双向读写 ✓"
else
  warn "挂载读写验证未通过，请检查 compose.yaml"
fi

LOGIN_HINT=""
for a in $selected; do
  [ "$a" = "claude" ] && continue
  LOGIN_HINT="${LOGIN_HINT}  ${a}: 容器内执行 ${a} 后按提示登录（凭据已挂载持久化）"$'\n'
done

cat <<EOF

✅ 沙箱就绪: $TARGET  （栈: ${STACK} / agent:${AGENT_CLIS}）

常用命令:
  cd "$TARGET"
  ./sandbox.sh in        # 进入沙箱 shell
  ./sandbox.sh ai        # 在沙箱内运行 Claude Code
  ./sandbox.sh down      # 停止沙箱

运行示例代码: ${RUN_CMD}
${LOGIN_HINT}
EOF
