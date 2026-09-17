#!/usr/bin/env bash
# bypass.sh — 向运行中的 e2e 容器注入私网直连 CIDR，无需重打镜像
#
# 原理：Mihomo external-controller (127.0.0.1:9090) 支持热重载 config，
#       在容器内 sed 追加 DIRECT 规则后调用 PUT /configs?force=true 即可。
#
# 使用方式：
#   bash scripts/bypass.sh 192.144.0.0/16,100.64.0.0/10
#   bash scripts/bypass.sh 192.144.253.205/32,100.101.22.109/32
#
# 可选第二参数指定容器名（默认 agy-ubuntu-e2e）：
#   bash scripts/bypass.sh 192.144.0.0/16 my-container
#
# 注意：重启容器后 entrypoint 会重写 config，需再次执行本脚本。

set -euo pipefail

CIDRS="${1:-}"
CONTAINER="${2:-agy-ubuntu-e2e}"
MIHOMO_CONFIG="/root/.config/mihomo/config.yaml"
MIHOMO_API="http://127.0.0.1:9090"

if [ -z "$CIDRS" ]; then
  echo "用法: bash scripts/bypass.sh <CIDR1,CIDR2,...> [容器名]"
  echo "示例: bash scripts/bypass.sh 192.144.0.0/16,100.64.0.0/10"
  exit 1
fi

echo "[bypass] 目标容器: $CONTAINER"
echo "[bypass] 注入 CIDR: $CIDRS"

# 检查容器是否运行
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "[bypass] ❌ 容器 '$CONTAINER' 未运行，请先: docker compose -f docker-compose.e2e.yml up -d"
  exit 1
fi

docker exec "$CONTAINER" bash << INNEREOF
set -euo pipefail
CIDRS='$CIDRS'
CONFIG='$MIHOMO_CONFIG'

[ -f "\$CONFIG" ] || { echo '[bypass] ❌ Mihomo config 不存在，entrypoint 可能还未完成'; exit 1; }

IFS=',' read -ra CIDR_LIST <<< "\$CIDRS"
for cidr in "\${CIDR_LIST[@]}"; do
  cidr="\${cidr// /}"
  [ -z "\$cidr" ] && continue
  if grep -qF "IP-CIDR,\${cidr},DIRECT" "\$CONFIG"; then
    echo "[bypass] ⏭  \$cidr 已存在，跳过"
    continue
  fi
  sed -i "s|  - MATCH,|  - IP-CIDR,\${cidr},DIRECT\n  - MATCH,|g" "\$CONFIG"
  echo "[bypass] ✅ 已注入: \$cidr"
done

echo '[bypass] 热重载 Mihomo 配置...'
result=\$(curl -s -o /dev/null -w '%{http_code}' \
  -X PUT '${MIHOMO_API}/configs?force=true' \
  -H 'Content-Type: application/json' \
  -d "{\"path\":\"\$CONFIG\"}")

if [ "\$result" = "204" ] || [ "\$result" = "200" ]; then
  echo "[bypass] ✅ Mihomo 热重载成功 (HTTP \$result)"
else
  echo "[bypass] ⚠ 热重载返回 HTTP \$result，尝试重启 mihomo..."
  pkill mihomo 2>/dev/null || true
  sleep 1
  mihomo -d "\$(dirname \$CONFIG)" > /root/mihomo.log 2>&1 &
  sleep 2
  echo '[bypass] ✅ mihomo 已重启'
fi

echo '[bypass] 当前 DIRECT 规则:'
grep 'DIRECT' "\$CONFIG"
INNEREOF
