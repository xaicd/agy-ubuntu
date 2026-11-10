#!/usr/bin/env bash
#==============================================================================
# verify-tools-persistence.sh — 模型 CLI 工具链持久化验收
#
# 验证点:
#   1. 五个 CLI 在容器内可执行(agy/claude/cmd/copilot/kiro-cli)
#   2. 二进制落在持久化卷里(prefix/bin 与 ~/.local/bin),不在容器可写层
#   3. 登录态/配置目录是 bind mount(宿主可见),且有内容
#   4. 容器经代理出口可达(首页 200 无跳转 + agy 资格端点)
#
# 用法: bash scripts/verify-tools-persistence.sh
#==============================================================================
set -uo pipefail
C="${CONTAINER:-agy-ubuntu-container}"
TOOLS_PREFIX="/opt/agy-tools"
fail=0

ok(){   echo "  ✅ $*"; }
bad(){  echo "  ❌ $*"; fail=1; }
warn(){ echo "  ⚠️  $*"; }

echo "=== 1. CLI 可执行性 ==="
for b in agy claude cmd copilot kiro-cli; do
    p=$(docker exec "$C" sh -c "command -v $b 2>/dev/null" 2>/dev/null)
    if [ -n "$p" ]; then ok "$b → $p"; else bad "$b 不可用"; fi
done

echo "=== 2. 二进制落在持久化卷 ==="
for b in claude cmd copilot; do
    p=$(docker exec "$C" sh -c "ls ${TOOLS_PREFIX}/bin/$b 2>/dev/null" 2>/dev/null)
    [ -n "$p" ] && ok "$b 在卷 ${TOOLS_PREFIX}/bin" || bad "$b 不在 prefix/bin(会在重建后丢)"
done
for b in agy kiro-cli; do
    p=$(docker exec "$C" sh -c "ls /root/.local/bin/$b 2>/dev/null" 2>/dev/null)
    [ -n "$p" ] && ok "$b 在卷 /root/.local/bin" || bad "$b 不在 ~/.local/bin(会在重建后丢)"
done

echo "=== 3. 登录态/配置 bind mount ==="
docker inspect "$C" --format '{{range .Mounts}}{{if eq .Destination "/root/.commandcode"}}{{.Source}} → {{.Destination}}{{end}}{{end}}' 2>/dev/null | grep -q . \
    && ok "/root/.commandcode 是 bind mount" || warn "/root/.commandcode 非 bind mount(cmd 登录态会丢)"
for d in /root/.claude /root/.copilot /root/.kiro; do
    n=$(docker exec "$C" sh -c "ls -A $d 2>/dev/null | wc -l" 2>/dev/null)
    [ "${n:-0}" -gt 0 ] && ok "$d 有内容(${n} 项)" || warn "$d 为空"
done

echo "=== 4. 代理出口 ==="
h=$(docker exec "$C" curl -s -o /dev/null -w '%{http_code}|%{redirect_url}' --max-time 12 http://www.google.com 2>/dev/null)
a=$(docker exec "$C" curl -s -o /dev/null -w '%{http_code}' -X POST --max-time 15 \
    "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist" 2>/dev/null)
if [ "${h%%|*}" = "200" ] && ! echo "$h" | grep -q 'google.com.hk'; then
    ok "首页 200 无跳转(${h})"
else
    bad "首页异常: ${h}"; fi
[ "$a" != "000" ] && [ -n "$a" ] && ok "agy 资格端点可达($a)" || bad "agy 资格端点不可达($a)"

echo
[ "$fail" = "0" ] && echo "✅ 全部通过" || echo "❌ 有失败项(见上)"
exit "$fail"
