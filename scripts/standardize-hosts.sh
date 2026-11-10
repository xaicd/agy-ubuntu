#!/usr/bin/env bash
#==============================================================================
# standardize-hosts.sh — 统一各宿主机 agy 容器规范(节点同步 + 卷 + CLI + 验证)
#
# 一条命令做完四件事(每台主机):
#   1. 同步本机节点表 → <repo>/mihomo-conf/proxies-static.yaml + 容器内热重载
#      (只写容器 provider 文件、只调容器内 9090 API —— 不碰宿主 mihomo,不动 tailscale)
#   2. 建持久化命名卷 (agy-tools / agy-local-bin / agy-npm-cache)
#   3. 确认容器内五个 CLI 就位(agy/claude/cmd/copilot/kiro-cli)
#   4. 跑 verify-tools-persistence.sh 出验收结论
#
# 用法:
#   bash scripts/standardize-hosts.sh                      # 默认三台(见 TARGETS)
#   bash scripts/standardize-hosts.sh cwall:/path/to/repo  # 指定主机
#
# 目标格式: <ssh别名>:<该主机 agy-ubuntu 仓库绝对路径>
#==============================================================================
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="agy-ubuntu-container"
STATIC="${REPO_DIR}/mihomo-conf/proxies-static.yaml"

TARGETS=(
  "cwall:/home/cw/workspace/agy-ubuntu"
  "tc-coolie-claw:/opt/coolie/docker/agy-ubuntu"
  "aja-pc:/home/beye/workspace/zhuangyuan/agy-ubuntu"
)
[ $# -gt 0 ] && TARGETS=("$@")

log(){ echo "[$(date '+%F %T')] $*"; }

for t in "${TARGETS[@]}"; do
  host="${t%%:*}"; path="${t#*:}"
  echo "======================================================================"
  log "→ ${host}:${path}"

  ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "test -d '${path}/mihomo-conf'" 2>/dev/null \
    || { log "  ⏭ 跳过:SSH 不通或路径不存在"; continue; }

  # --- 1. 节点同步 + 容器热重载 ---
  if ! ssh -o BatchMode=yes "$host" "test -f '${path}/mihomo-conf/proxies-static.yaml'" 2>/dev/null; then
    log "  ⚠️ 远端节点文件缺失,跳过同步"
  else
    if base64 < "$STATIC" | ssh -o BatchMode=yes "$host" "
        f='${path}/mihomo-conf/proxies-static.yaml'
        cp -a \"\$f\" \"\$f.bak.\$(date +%Y%m%d%H%M%S)\" 2>/dev/null || true
        base64 -d > \"\$f\"
        echo \"写入完成\"
    "; then
      log "  ✅ 节点表已同步"
    else
      log "  ❌ 节点表同步失败"
    fi
  fi

  # --- 2. 建卷 ---
  ssh -o BatchMode=yes "$host" \
    'for v in agy-tools agy-local-bin agy-npm-cache; do docker volume inspect "$v" >/dev/null 2>&1 || docker volume create "$v" >/dev/null; done; echo "卷: $(docker volume ls -q | grep agy- | tr "\n" " ")"' 2>/dev/null | sed 's/^/  /'

  # --- 3. 容器重建(让新 compose 的卷/规则生效) ---
  if ssh -o BatchMode=yes "$host" "docker inspect ${CONTAINER} >/dev/null 2>&1" 2>/dev/null; then
    ssh -o BatchMode=yes "$host" "cd '${path}' && docker compose up -d 2>&1 | tail -3" 2>/dev/null | sed 's/^/  /'
    sleep 8
  fi

  # --- 4. 容器内热重载(强制 provider 重读:换 path 不可用时至少 reload) ---
  ssh -o BatchMode=yes "$host" "docker exec --workdir / ${CONTAINER} sh -lc '
      curl -s -o /dev/null -X PUT http://127.0.0.1:9090/providers/proxies/static --max-time 10 || true
      curl -s -o /dev/null -w \"reload=%{http_code}\n\" -X PUT \"http://127.0.0.1:9090/configs?force=true\" \
        -H \"Content-Type: application/json\" -d \"{\\\"path\\\":\\\"/root/.config/mihomo/config.yaml\\\"}\" --max-time 10
  '" 2>/dev/null | sed 's/^/  /'

  # --- 5. 出口与 CLI 体检 ---
  ssh -o BatchMode=yes "$host" "docker exec --workdir / ${CONTAINER} sh -lc '
      echo -n \"  出口: \"; curl -s -o /dev/null -w \"%{http_code}|%{redirect_url}\" --max-time 12 http://www.google.com; echo
      echo -n \"  节点数: \"; curl -s http://127.0.0.1:9090/providers/proxies/static 2>/dev/null | grep -o \"\\\"name\\\"\" | wc -l
      export PATH=/opt/agy-tools/bin:\$PATH
      for b in agy claude cmd copilot kiro-cli; do printf \"    %-10s %s\n\" \$b \"\$(command -v \$b || echo 缺)\"; done
  '" 2>/dev/null

  # --- 6. tailscale/局域网安全校验(红线:宿主网络不得受影响) ---
  ssh -o BatchMode=yes "$host" "docker exec --workdir / ${CONTAINER} sh -lc '
      echo -n \"  容器直连规则: \"; grep -cE \"IP-CIDR,(100\\\\.64\\\\.0\\\\.0/10|172\\\\.16\\\\.0\\\\.0/12),DIRECT\" /root/.config/mihomo/config.yaml
  '" 2>/dev/null | sed 's/^/  /'
done
echo "======================================================================"
log "全部处理完毕"
