#!/usr/bin/env bash
# ==============================================================================
# agy - 宿主机透明代理执行器 (通过 agy-ubuntu-container 容器无缝运行 Antigravity)
# 
# 智能动态识别宿主机当前路径与容器 Mounts 挂载映射，绝不篡改容器挂载结构。
# 自动透传 PAPERCLIP_*, ANTHROPIC_*, CLAUDE_*, GEMINI_*, OPENAI_* 等数字员工环境变量。
# 支持平台: Linux (aja-pc, cwall, tc-coolie-claw) / macOS (mac)
# ==============================================================================
set -eo pipefail

CONTAINER_NAME="agy-ubuntu-container"

# 1. 智能计算当前工作目录在容器内的映射
HOST_CWD="$(pwd)"
CONTAINER_CWD="/root/workspace"

if [[ "$HOST_CWD" =~ ^$HOME/workspace(/.*)?$ ]]; then
    CONTAINER_CWD="/host-workspace${BASH_REMATCH[1]:-}"
elif [[ "$HOST_CWD" =~ ^/home/[^/]+/workspace(/.*)?$ ]]; then
    CONTAINER_CWD="/host-workspace${BASH_REMATCH[1]:-}"
elif [[ "$HOST_CWD" =~ ^/Users/[^/]+/workspace(/.*)?$ ]]; then
    CONTAINER_CWD="/host-workspace${BASH_REMATCH[1]:-}"
fi

# 2. 判断是否为交互式终端 (TTY)
EXEC_FLAGS="-i"
if [ -t 0 ] && [ -t 1 ]; then
    EXEC_FLAGS="-it"
fi

# 3. 动态收集数字员工与模型环境变量透传
EXTRA_ENV_ARGS=()
while IFS= read -r var_name; do
    if [[ -n "$var_name" ]]; then
        EXTRA_ENV_ARGS+=("-e" "$var_name")
    fi
done < <(compgen -e | grep -E '^(PAPERCLIP_|ANTHROPIC_|CLAUDE_|GEMINI_|OPENAI_)' || true)

# 4. 乐观直连进入容器执行 (消除前置两次 inspect 开销，未启动时自动拉起)
if ! docker exec $EXEC_FLAGS     "${EXTRA_ENV_ARGS[@]}"     -e LANG=C.UTF-8     -e LC_ALL=C.UTF-8     -e HTTP_PROXY=http://127.0.0.1:7890     -e HTTPS_PROXY=http://127.0.0.1:7890     -e NO_PROXY=localhost,127.0.0.1,100.84.124.71,100.118.232.61,100.101.22.109     -w "$CONTAINER_CWD"     "$CONTAINER_NAME"     agy "$@" 2>/tmp/.agy_err.$$; then

    ERR=$(cat /tmp/.agy_err.$$ 2>/dev/null || true)
    rm -f /tmp/.agy_err.$$
    if [[ "$ERR" =~ "is not running" ]] || [[ "$ERR" =~ "No such container" ]]; then
        echo "[提示] 容器未启动，正在拉起 $CONTAINER_NAME..." >&2
        docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
        sleep 1
        exec docker exec $EXEC_FLAGS             "${EXTRA_ENV_ARGS[@]}"             -e LANG=C.UTF-8             -e LC_ALL=C.UTF-8             -e HTTP_PROXY=http://127.0.0.1:7890             -e HTTPS_PROXY=http://127.0.0.1:7890             -e NO_PROXY=localhost,127.0.0.1,100.84.124.71,100.118.232.61,100.101.22.109             -w "$CONTAINER_CWD"             "$CONTAINER_NAME"             agy "$@"
    else
        echo "$ERR" >&2
        exit 1
    fi
fi
rm -f /tmp/.agy_err.$$ 2>/dev/null || true
