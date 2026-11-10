#!/usr/bin/env bash
# ==============================================================================
# copilot.sh / copilot-host-wrapper.sh
# 
# 宿主机 / 容器双模透明代理执行器 (通过 agy-ubuntu-container 容器无缝运行 GitHub Copilot CLI)
# 
# 特性:
#   1. 最大权限运行 (Zero Approval / YOLO Mode):
#      - 默认注入 COPILOT_ALLOW_ALL=true
#      - 默认追加 --allow-all (--allow-all-tools, --allow-all-paths, --allow-all-urls)
#      - 关闭辅助审慎审批，不提示任何文件写/命令执行审批
#   2. 智能动态识别宿主机当前路径与容器 Mounts 挂载映射
#   3. 自动透传 COPILOT_*, GITHUB_*, GH_*, PAPERCLIP_*, OPENAI_*, ANTHROPIC_* 环境变量
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

# --- 2. 组装最大权限参数 ---
export COPILOT_ALLOW_ALL="true"
export COPILOT_ASSISTED_APPROVAL="false"
export COPILOT_AUTO_UPDATE="false"

# 检查是否为管理类/只读类子命令 (不需要注入 --allow-all)
PASSTHROUGH_CMD=false
for arg in "$@"; do
    case "$arg" in
        login|logout|version|update|config|mcp|plugin|skill|completion|-v|--version|-h|--help)
            PASSTHROUGH_CMD=true
            break
            ;;
    esac
done

FINAL_ARGS=()
HAS_ALLOW_ALL=false
for arg in "$@"; do
    if [[ "$arg" == "--allow-all" || "$arg" == "--yolo" || "$arg" == "--allow-all-tools" ]]; then
        HAS_ALLOW_ALL=true
    fi
    FINAL_ARGS+=("$arg")
done

if [ "$PASSTHROUGH_CMD" = false ] && [ "$HAS_ALLOW_ALL" = false ]; then
    FINAL_ARGS=("--allow-all" "${FINAL_ARGS[@]}")
fi

# --- 3. 容器内原生直接执行 ---
if [ "$IN_CONTAINER" = true ]; then
    exec copilot "${FINAL_ARGS[@]}"
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
done < <(compgen -e | grep -E '^(COPILOT_|GITHUB_|GH_|PAPERCLIP_|ANTHROPIC_|CLAUDE_|GEMINI_|OPENAI_)' || true)

EXTRA_ENV_ARGS+=(
    "-e" "COPILOT_ALLOW_ALL=true"
    "-e" "COPILOT_ASSISTED_APPROVAL=false"
    "-e" "COPILOT_AUTO_UPDATE=false"
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
    copilot "${FINAL_ARGS[@]}" 2>/tmp/.copilot_err.$$; then

    ERR=$(cat /tmp/.copilot_err.$$ 2>/dev/null || true)
    rm -f /tmp/.copilot_err.$$
    if [[ "$ERR" =~ "is not running" ]] || [[ "$ERR" =~ "No such container" ]]; then
        echo "[提示] 容器未启动，正在拉起 $CONTAINER_NAME..." >&2
        docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
        sleep 1
        exec docker exec $EXEC_FLAGS \
            "${EXTRA_ENV_ARGS[@]}" \
            -w "$CONTAINER_CWD" \
            "$CONTAINER_NAME" \
            copilot "${FINAL_ARGS[@]}"
    else
        echo "$ERR" >&2
        exit 1
    fi
fi
rm -f /tmp/.copilot_err.$$ 2>/dev/null || true
