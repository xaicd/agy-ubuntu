#!/usr/bin/env bash
# ==============================================================================
# kiro-cli.sh / kiro-host-wrapper.sh
# 
# 宿主机 / 容器双模透明代理执行器 (通过 agy-ubuntu-container 容器无缝运行 Kiro CLI)
# 
# 特性:
#   1. 最大权限运行 (Zero Approval / Auto-Trust Mode):
#      - 默认注入 -a / --trust-all-tools (任何工具调用无需人工确认)
#      - 默认注入 --trust-workspace (跳过 Trust workspace 校验弹窗)
#   2. 智能动态识别宿主机当前路径与容器 Mounts 挂载映射
#   3. 自动透传 KIRO_*, AWS_*, PAPERCLIP_*, OPENAI_*, ANTHROPIC_* 环境变量
#   4. 容器未启动时乐观秒级自动拉起
#   5. 容器内自适应直接执行
# ==============================================================================
set -eo pipefail

CONTAINER_NAME="agy-ubuntu-container"

# --- 1. 判断是否已经在容器内 ---
IN_CONTAINER=false
if [ -f /.dockerenv ] || ! command -v docker >/dev/null 2>&1; then
    IN_CONTAINER=true
fi

# --- 2. 组装最大权限与参数路由 ---
# 检查是否为管理类/辅助类子命令
PASSTHROUGH_CMD=false
IS_CHAT_EXPLICIT=false
first_arg="${1:-}"

case "$first_arg" in
    login|logout|whoami|profile|settings|diagnostic|issue|crew|mcp|powers|update|integrations|serve|-v|--version|-h|--help)
        PASSTHROUGH_CMD=true
        ;;
    chat)
        IS_CHAT_EXPLICIT=true
        ;;
esac

FINAL_ARGS=()

if [ "$PASSTHROUGH_CMD" = true ]; then
    FINAL_ARGS=("$@")
elif [ "$IS_CHAT_EXPLICIT" = true ]; then
    # 用户显式调用了 kiro-cli chat ...
    FINAL_ARGS=("chat" "-a" "--trust-workspace")
    shift
    FINAL_ARGS+=("$@")
else
    # 用户没有传参或传了 prompt / chat 参数，默认走最大权限 chat 交互
    FINAL_ARGS=("chat" "-a" "--trust-workspace")
    if [ $# -gt 0 ]; then
        FINAL_ARGS+=("$@")
    fi
fi

# --- 3. 容器内原生直接执行 ---
if [ "$IN_CONTAINER" = true ]; then
    exec kiro-cli "${FINAL_ARGS[@]}"
fi

# --- 4. 宿主机透明代理执行 (参考 agy-host-wrapper.sh) ---
HOST_CWD="$(pwd)"
CONTAINER_CWD="/root/workspace"

if [[ "$HOST_CWD" =~ ^$HOME/workspace(/.*)?$ ]]; then
    CONTAINER_CWD="/host-workspace${BASH_REMATCH[1]:-}"
elif [[ "$HOST_CWD" =~ ^/home/[^/]+/workspace(/.*)?$ ]]; then
    CONTAINER_CWD="/host-workspace${BASH_REMATCH[1]:-}"
elif [[ "$HOST_CWD" =~ ^/Users/[^/]+/workspace(/.*)?$ ]]; then
    CONTAINER_CWD="/host-workspace${BASH_REMATCH[1]:-}"
fi

EXEC_FLAGS="-i"
if [ -t 0 ] && [ -t 1 ]; then
    EXEC_FLAGS="-it"
fi

EXTRA_ENV_ARGS=()
while IFS= read -r var_name; do
    if [[ -n "$var_name" ]]; then
        EXTRA_ENV_ARGS+=("-e" "$var_name")
    fi
done < <(compgen -e | grep -E '^(KIRO_|AWS_|PAPERCLIP_|ANTHROPIC_|CLAUDE_|GEMINI_|OPENAI_)' || true)

EXTRA_ENV_ARGS+=(
    "-e" "LANG=C.UTF-8"
    "-e" "LC_ALL=C.UTF-8"
    "-e" "HTTP_PROXY=http://127.0.0.1:7890"
    "-e" "HTTPS_PROXY=http://127.0.0.1:7890"
    "-e" "NO_PROXY=localhost,127.0.0.1,100.84.124.71,100.118.232.61,100.101.22.109"
)

# 乐观直连进入容器执行
if ! docker exec $EXEC_FLAGS \
    "${EXTRA_ENV_ARGS[@]}" \
    -w "$CONTAINER_CWD" \
    "$CONTAINER_NAME" \
    kiro-cli "${FINAL_ARGS[@]}" 2>/tmp/.kiro_err.$$; then

    ERR=$(cat /tmp/.kiro_err.$$ 2>/dev/null || true)
    rm -f /tmp/.kiro_err.$$
    if [[ "$ERR" =~ "is not running" ]] || [[ "$ERR" =~ "No such container" ]]; then
        echo "[提示] 容器未启动，正在拉起 $CONTAINER_NAME..." >&2
        docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
        sleep 1
        exec docker exec $EXEC_FLAGS \
            "${EXTRA_ENV_ARGS[@]}" \
            -w "$CONTAINER_CWD" \
            "$CONTAINER_NAME" \
            kiro-cli "${FINAL_ARGS[@]}"
    else
        echo "$ERR" >&2
        exit 1
    fi
fi
rm -f /tmp/.kiro_err.$$ 2>/dev/null || true
