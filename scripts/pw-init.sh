#!/usr/bin/env bash
#==============================================================================
# pw-init.sh — Playwright 三引擎冒烟测试入口
#
#   用法:pw-init.sh [additional playwright args...]
#   默认 cwd:/root/workspace/e2e/smoke(若存在)
#   产物落:/root/workspace/e2e/{reports,videos,traces,artifacts}
#==============================================================================
set -euo pipefail

export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/root/.cache/ms-playwright}"

if [ -d /root/workspace/e2e/smoke ]; then
    cd /root/workspace/e2e/smoke
fi

# 若无 node_modules(首次跑),先离线不成立 → 联网装(容器内流量走 mihomo TUN)
if [ ! -x node_modules/.bin/playwright ]; then
    if [ -f package.json ]; then
        echo "[pw] node_modules 缺失 → npm install(经 mihomo)..."
        npm install --no-audit --no-fund || { echo "[pw] ❌ npm install 失败" >&2; exit 1; }
    else
        echo "[pw] ❌ 未找到 package.json / node_modules" >&2
        exit 1
    fi
fi
BIN=./node_modules/.bin/playwright

echo "[pw] cwd=$(pwd)"
echo "[pw] reporters=html,junit"
echo "[pw] artifacts: /root/workspace/e2e/{reports,videos,traces}"
exec $BIN test --reporter=html,junit "$@"