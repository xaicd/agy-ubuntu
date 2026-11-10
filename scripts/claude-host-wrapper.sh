#!/usr/bin/env bash
# ==============================================================================
# claude-host-wrapper.sh
#
# 宿主机 / 容器双模透明代理执行器 (通过 agy-ubuntu-container 容器运行 Claude Code)
#
# 特性:
#   1. 容器内原生直接执行(检测 /.dockerenv)
#   2. 宿主机调用时:把工作目录映射到容器挂载路径,自动注入代理环境变量
#      (容器内 TUN 已接管全部流量,宿主机侧无需再设 HTTP_PROXY —— 容器内直连即走 mihomo)
#   3. 自动透传 ANTHROPIC_*, CLAUDE_*, PAPERCLIP_*, GEMINI_*, OPENAI_* 等环境变量
#   4. 容器未启动时乐观秒级自动拉起
#   5. 交互式终端自动加 -it
# ==============================================================================
set -eo pipefail

CONTAINER_NAME="agy-ubuntu-container"

# --- 1. 容器内原生直接执行 ---
if [ -f /.dockerenv ] || ! command -v docker >/dev/null 2>&1; then
    exec claude "$@"
fi

# --- 2. 计算宿主机工作目录 → 容器内映射路径 ---
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

# --- 3. 环境变量透传 ---
EXTRA_ENV_ARGS=()
while IFS= read -r var_name; do
    if [[ -n "$var_name" ]]; then
        EXTRA_ENV_ARGS+=("-e" "$var_name")
    fi
done < <(compgen -e | grep -E '^(ANTHROPIC_|CLAUDE_|PAPERCLIP_|GEMINI_|OPENAI_|AWS_)' || true)

EXTRA_ENV_ARGS+=(
    "-e" "LANG=C.UTF-8"
    "-e" "LC_ALL=C.UTF-8"
)

# --- 4. 乐观直连进入容器执行 ---
if ! docker exec $EXEC_FLAGS \
    "${EXTRA_ENV_ARGS[@]}" \
    -w "$CONTAINER_CWD" \
    "$CONTAINER_NAME" \
    claude "$@" 2>/tmp/.claude_err.$$; then

    ERR=$(cat /tmp/.claude_err.$$ 2>/dev/null || true)
    rm -f /tmp/.claude_err.$$
    if [[ "$ERR" =~ "is not running" ]] || [[ "$ERR" =~ "No such container" ]]; then
        echo "[提示] 容器未启动，正在拉起 $CONTAINER_NAME..." >&2
        docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
        sleep 1
        exec docker exec $EXEC_FLAGS \
            "${EXTRA_ENV_ARGS[@]}" \
            -w "$CONTAINER_CWD" \
            "$CONTAINER_NAME" \
            claude "$@"
    else
        echo "$ERR" >&2
        exit 1
    fi
fi
rm -f /tmp/.claude_err.$$ 2>/dev/null || true
