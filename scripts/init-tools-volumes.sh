#!/usr/bin/env bash
#==============================================================================
# init-tools-volumes.sh — 模型 CLI 工具链卷初始化/校验
#
# 背景:claude / cmd / copilot / kiro-cli 都要吃容器这条合规出口,但它们原本
#   装在容器可写层,`docker rm` 重建即全失(登录态还得重登一遍)。
# 方案(见 docker-compose*.yml):
#   命名卷 agy-tools    → /opt/agy-tools   npm 全局 prefix(NPM_CONFIG_PREFIX)
#   命名卷 agy-local-bin → /root/.local/bin kiro-cli / agy 等二进制
#   bind mount          → /root/.claude /root/.copilot /root/.kiro /root/.gemini
#                         /root/.commandcode  登录态与配置
#
# 用法:
#   bash scripts/init-tools-volumes.sh          # 校验卷内容(只读)
#   bash scripts/init-tools-volumes.sh --seed   # 首次播种(往卷里装包,较慢)
#==============================================================================
set -uo pipefail

CONTAINER="${CONTAINER:-agy-ubuntu-container}"
TOOLS_PREFIX="/opt/agy-tools"
VOL_TOOLS="agy-tools"
VOL_LOCALBIN="agy-local-bin"

NPM_PKGS=(
  "@anthropic-ai/claude-code:claude"
  "command-code:cmd"
  "@github/copilot:copilot"
)

log(){ echo "[$(date '+%F %T')] $*"; }

ensure_volumes(){
  for v in "$VOL_TOOLS" "$VOL_LOCALBIN"; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
      log "卷已存在: $v"
    else
      docker volume create "$v" >/dev/null && log "已创建卷: $v" || { log "❌ 创建卷失败: $v"; return 1; }
    fi
  done
}

# 把宿主已装好的 CLI 包从容器可写层搬进卷(避免重新下载)
seed_npm_from_container(){
  local pkgs=()
  for e in "${NPM_PKGS[@]}"; do pkgs+=("${e%%:*}"); done
  log "从容器可写层迁移 npm 包 → ${TOOLS_PREFIX}(不重下,快)"
  local list="" p
  for p in "${pkgs[@]}"; do
    # 全局布局(/usr/local/lib/node_modules)与本地布局(/opt/agy-tools/node_modules)都算
    if [ -e "/usr/local/lib/node_modules/${p}/package.json" ] || [ -e "/opt/agy-tools/node_modules/${p}/package.json" ]; then
      list="${list} ${p}"
    fi
  done
  if [ -z "$list" ]; then
    log "容器可写层没有可迁移的包,改为在卷内重新安装"
    return 1
  fi
  for p in $list; do
    log "  · $p"
  done
  # 用一次性容器把包目录拷进卷,并按全局布局补 bin 软链
  docker run --rm -v "$VOL_TOOLS":"$TOOLS_PREFIX" \
    --volumes-from "$CONTAINER" \
    --entrypoint sh chw717/ai-agy:latest-arm64 -c "
      set -e
      mkdir -p '${TOOLS_PREFIX}/lib/node_modules' '${TOOLS_PREFIX}/bin'
      for p in $list; do
        src=''
        [ -d \"/usr/local/lib/node_modules/\$p\" ] && src=\"/usr/local/lib/node_modules/\$p\"
        [ -z \"\$src\" ] && [ -d \"/opt/agy-tools/node_modules/\$p\" ] && src=\"/opt/agy-tools/node_modules/\$p\"
        [ -z \"\$src\" ] && continue
        rm -rf '${TOOLS_PREFIX}/lib/node_modules/\$p'
        cp -a \"\$src\" '${TOOLS_PREFIX}/lib/node_modules/'
        # 补 bin 软链(bin 可能是字符串或对象)
        node -e \"
          const p=require('${TOOLS_PREFIX}/lib/node_modules/\$p/package.json');
          const b=p.bin||{};
          const m=(typeof b==='string')?{cmd:b}:b;
          for(const [k,v] of Object.entries(m)) console.log(k+' '+v);
        \" 2>/dev/null | while read -r bname brel; do
          [ -e \"${TOOLS_PREFIX}/lib/node_modules/\$p/\$brel\" ] || continue
          ln -sf \"${TOOLS_PREFIX}/lib/node_modules/\$p/\$brel\" \"${TOOLS_PREFIX}/bin/\$bname\"
        done
      done
      echo seeded
    " 2>&1 | tail -2
}

seed_npm_fresh(){
  log "在卷内全新安装 npm 包(需下载,较慢)…"
  # 必须 -g(全局布局:prefix/lib/node_modules + prefix/bin);不带 -g 会装成
  # local 布局(prefix/node_modules + node_modules/.bin),PATH 里找不到命令。
  # 串行安装 + 超时:并发会打满容器代理连接池卡死(2026-11-10 实测)。
  for e in "${NPM_PKGS[@]}"; do
    local pkg="${e%%:*}"
    log "  · installing ${pkg} ..."
    docker run --rm -v "$VOL_TOOLS":"$TOOLS_PREFIX" \
      -e NPM_CONFIG_PREFIX="$TOOLS_PREFIX" \
      --entrypoint sh chw717/ai-agy:latest-arm64 -c "
        npm install -g --prefix '${TOOLS_PREFIX}' --fetch-timeout=90000 --fetch-retries=1 '${pkg}'
      " 2>&1 | tail -3
  done
}

seed_localbin_from_container(){
  log "迁移 ~/.local/bin 二进制(kiro-cli / agy)→ 卷"
  docker run --rm -v "$VOL_LOCALBIN":/dst \
    --volumes-from "$CONTAINER" \
    --entrypoint sh chw717/ai-agy:latest-arm64 -c "
      cp -a /root/.local/bin/. /dst/ 2>/dev/null || true
      ls -la /dst
    " 2>&1 | tail -5
}

verify(){
  log "=== 校验卷内容 ==="
  docker run --rm -v "$VOL_TOOLS":"$TOOLS_PREFIX" -v "$VOL_LOCALBIN":/root/.local/bin \
    --entrypoint sh chw717/ai-agy:latest-arm64 -c "
      echo '--- npm 包 ---'
      ls '${TOOLS_PREFIX}/lib/node_modules' 2>/dev/null || echo '(空)'
      echo '--- bin ---'
      ls '${TOOLS_PREFIX}/bin' 2>/dev/null || echo '(空)'
      echo '--- local/bin ---'
      ls /root/.local/bin 2>/dev/null || echo '(空)'
    "
}

case "${1:-}" in
  --seed)
    ensure_volumes || exit 1
    seed_npm_from_container || seed_npm_fresh
    seed_localbin_from_container
    verify
    ;;
  *)
    ensure_volumes || exit 1
    verify
    ;;
esac
