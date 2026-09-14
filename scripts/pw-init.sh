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

# 若有 node_modules,跑本地的 playwright;否则用全局
if [ -x node_modules/.bin/playwright ]; then
    BIN=./node_modules/.bin/playwright
else
    BIN=npx --no-install playwright
fi

echo "[pw] cwd=$(pwd)"
echo "[pw] reporters=html,junit"
echo "[pw] artifacts: /root/workspace/e2e/{reports,videos,traces}"
exec $BIN test --reporter=html,junit "$@"