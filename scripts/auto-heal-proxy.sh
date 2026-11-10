#!/usr/bin/env bash
#==============================================================================
# auto-heal-proxy.sh — agy 代理自动自愈(Mac 侧定时跑)
#
# 背景:机场(阡陌星云)会在服务端漂移节点出口 IP(订阅快照不变),容器/宿主机
#   mihomo 会因此卡在坏出口上。2026-10-31 ~ 11-07 三次故障,药方固定:
#   踢健康检查 + 强制热重载 + 必要时 PIN 探测换干净节点。本脚本把药方自动化。
#
# 每轮流程(设计原则:健康就不打扰,零进程重启,全程 9090 API):
#   1. App config.yaml 比 static 文件新时才重新导出(export-nodes-mac.sh)
#   2. 本地容器体检(首页 redirect,不用瞎的 generate_204)→ 坏则踢+重载 → 还坏则 PIN 换节点
#   3. 各宿主机:static md5 变了才推送;容器同 2;宿主机 mihomo(systemd)同 2(PIN 需 chroot)
#
# 用法: bash scripts/auto-heal-proxy.sh        # launchd 每 2h 调用,也可手动
# 日志: ~/Library/Logs/agy-proxy-heal.log      # 退出码 0=全部健康/已治愈 1=有不治之症
#==============================================================================
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${HOME}/Library/Logs/agy-proxy-heal.log"
CONTAINER="agy-ubuntu-container"
CFG="/root/.config/mihomo/config.yaml"
STATIC_LOCAL="${REPO_DIR}/mihomo-conf/proxies-static.yaml"
HOSTS=(
  "aja-pc:/home/beye/workspace/zhuangyuan/agy-ubuntu"
  # cwall 纳管(2026-11-10):静态节点停留在 10-10 未推送 → GEO 全挂 → 降级 RESCUE 落到香港02
  #   → agy 资格端点 flaky,墨斗 agy_local 报 "authentication required"。
  "cwall:/home/cw/workspace/agy-ubuntu"
)
# 需要纳管更多宿主机时在此追加(格式: 别名:仓库路径):
#   "tc-coolie-claw:/opt/coolie/docker/agy-ubuntu"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# ---------- 通用动作(H=ssh 别名,"-"=本地) ----------
GY_API="https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
vfy(){  # 容器体检: 输出 "code|redirect|apicode" (apicode=agy 端点连测2次,任一 000 即记 000——出口 flaky 必须抓出来)
  local H="$1"
  if [ "$H" = "-" ]; then
    local r a x
    r=$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}|%{redirect_url}' --max-time 12 http://www.google.com 2>/dev/null)
    a="ok"
    for x in 1 2; do
      [ "$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' -X POST --max-time 15 "$GY_API" 2>/dev/null)" = "000" ] && a="000"
    done
    echo "${r}|${a}"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$H" "a=ok; for x in 1 2; do c=\$(docker exec $CONTAINER curl -s -o /dev/null -w '%{http_code}' -X POST --max-time 15 '$GY_API'); [ \"\$c\" = '000' ] && a=000; done; docker exec $CONTAINER curl -s -o /dev/null -w '%{http_code}|%{redirect_url}' --max-time 12 http://www.google.com; echo -n \"|\$a\"" 2>/dev/null
  fi
}
kick(){  # 踢 provider 健康检查 + 强制热重载
  local H="$1"
  if [ "$H" = "-" ]; then
    docker exec "$CONTAINER" curl -s -o /dev/null -X PUT "http://127.0.0.1:9090/providers/proxies/static" --max-time 15
    docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:9090/configs?force=true" -H 'Content-Type: application/json' -d "{\"path\":\"$CFG\"}" --max-time 10
  else
    ssh -o BatchMode=yes "$H" "docker exec $CONTAINER curl -s -o /dev/null -X PUT http://127.0.0.1:9090/providers/proxies/static --max-time 15; docker exec $CONTAINER curl -s -o /dev/null -w '%{http_code}' -X PUT 'http://127.0.0.1:9090/configs?force=true' -H 'Content-Type: application/json' -d '{\"path\":\"$CFG\"}' --max-time 10" 2>/dev/null
  fi
}
getcfg(){  # 容器 config.yaml → stdout
  local H="$1"
  if [ "$H" = "-" ]; then docker exec "$CONTAINER" cat "$CFG" 2>/dev/null; else ssh -o BatchMode=yes "$H" "docker exec $CONTAINER cat $CFG" 2>/dev/null; fi
}
putcfg(){  # 本地文件流式截断写回容器 config.yaml(保 inode)
  local H="$1" F="$2"
  if [ "$H" = "-" ]; then docker exec -i "$CONTAINER" sh -c "cat > $CFG" < "$F"
  else ssh -o BatchMode=yes "$H" "docker exec -i $CONTAINER sh -c 'cat > $CFG'" < "$F" 2>/dev/null; fi
}
reload(){  # 热重载,输出 http code
  local H="$1"
  if [ "$H" = "-" ]; then
    docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:9090/configs?force=true" -H 'Content-Type: application/json' -d "{\"path\":\"$CFG\"}" --max-time 10
  else
    ssh -o BatchMode=yes "$H" "docker exec $CONTAINER curl -s -o /dev/null -w '%{http_code}' -X PUT 'http://127.0.0.1:9090/configs?force=true' -H 'Content-Type: application/json' -d '{\"path\":\"$CFG\"}' --max-time 10" 2>/dev/null
  fi
}
sel_pin(){  # PUT /proxies/PIN 切到指定节点
  local H="$1" N="$2"
  if [ "$H" = "-" ]; then
    docker exec "$CONTAINER" curl -s -o /dev/null -X PUT "http://127.0.0.1:9090/proxies/PIN" -H 'Content-Type: application/json' -d "{\"name\":\"$N\"}" --max-time 6
  else
    ssh -o BatchMode=yes "$H" "docker exec $CONTAINER curl -s -o /dev/null -X PUT http://127.0.0.1:9090/proxies/PIN -H 'Content-Type: application/json' -d '{\"name\":\"$N\"}' --max-time 6" 2>/dev/null
  fi
}
clean(){  # "code|redirect|apicode" 是否干净(首页 200 无跳转 且 agy API 端点非 000)
  local R="$1" home api
  home="${R%%|*}"; api="${R##*|}"
  [ "$home" = "200" ] && [ "$api" != "000" ] && [ -n "$api" ]; }

# ---------- PIN 探测自愈 ----------
pin_heal(){  # $1=H  返回 0=治愈 1=失败
  local H="$1"
  getcfg "$H" > "$TMP/orig.yaml" || { log "  [pin] 取不到原配置,放弃"; return 1; }
  grep -q 'name: PIN' "$TMP/orig.yaml" && { log "  [pin] PIN 组已存在(上次残留),基于现配置继续"; cp "$TMP/orig.yaml" "$TMP/orig.yaml"; }

  # 候选节点:本地 static 文件里 日/台/智/韩,3X 核心优先
  local CANDS
  CANDS="$(grep -oE 'name: "?【[^",}]+' "$STATIC_LOCAL" 2>/dev/null | sed 's/name: *//; s/"//g' | grep -E '日本|台湾|台灣|智利|韩国' | sort -u | awk '/3X/{a[++n]=$0} /1X/{b[++m]=$0} END{for(i=1;i<=n;i++)print a[i]; for(i=1;i<=m;i++)print b[i]}')"
  [ -n "$CANDS" ] || { log "  [pin] 抽不到候选节点,放弃"; return 1; }

  python3 - "$TMP/orig.yaml" "$TMP/pin.yaml" <<'PY' || return 1
import sys
src, dst = sys.argv[1], sys.argv[2]
content = open(src).read()
has_pin = '  - name: PIN' in content
# 关键: 探测流量必须真走 PIN —— 规则 MATCH,PROXY 要临时改写为 MATCH,PIN,
# 否则 sel_pin 切了不影响流量,所有候选测的都是同一个默认出口(2026-11-08 实锤)
has_reroute = '  - MATCH,PIN' in content
out = []
for l in content.splitlines(True):
    if l.startswith('rules:') and not has_pin:
        out.append('  - name: PIN\n    type: select\n    use:\n      - static\n    filter: "(日本|台湾|台灣|智利|韩国)"\n')
    if l.rstrip('\n') == '  - MATCH,PROXY' and not has_reroute:
        out.append('  - MATCH,PIN\n'); continue
    out.append(l)
open(dst, 'w').write(''.join(out))
sys.exit(0 if '  - MATCH,PIN' in ''.join(out) else 1)
PY
  putcfg "$H" "$TMP/pin.yaml" || { log "  [pin] 写回失败"; return 1; }
  local rc; rc="$(reload "$H")"
  [ "$rc" = "204" ] || { log "  [pin] 注入重载失败($rc),还原"; putcfg "$H" "$TMP/orig.yaml"; reload "$H" >/dev/null; return 1; }
  sleep 2

  local GOOD="" n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    sel_pin "$H" "$n"; sleep 1
    if clean "$(vfy "$H")"; then log "  [pin] ✅ 干净出口: $n"; GOOD="${GOOD}${n}\n"; else log "  [pin] ❌ $n"; fi
  done <<< "$CANDS"

  if [ -z "$GOOD" ]; then  # 全灭:还原原配置,报告机场级故障
    log "  [pin] 候选全灭,还原原配置"
    putcfg "$H" "$TMP/orig.yaml"; reload "$H" >/dev/null
    return 1
  fi

  # 把 PROXY-GEO 的 filter 改写为「只匹配干净节点」的正则
  # (group 的 proxies: 不能引用 provider 节点,必须保留 use: static,靠 filter 圈定)
  printf '%b' "$GOOD" > "$TMP/good.txt"
  python3 - "$TMP/pin.yaml" "$TMP/final.yaml" "$TMP/good.txt" <<'PY' || return 1
import sys, re
src, dst, good_f = sys.argv[1], sys.argv[2], sys.argv[3]
good = [l.strip() for l in open(good_f) if l.strip()]
filter_re = '(' + '|'.join(re.escape(g) for g in good) + ')'
# filter 用单引号标量: re.escape 产生的 \[ 在 YAML 双引号里是非法转义,reload 必 400
c = open(src).read().replace('  - MATCH,PIN\n', '  - MATCH,PROXY\n')
block = ['  - name: PROXY-GEO', '    type: fallback', '    use:',
         '      - static', "    filter: '" + filter_re + "'",
         '    url: http://www.google.com', '    expected-status: "200"', '    interval: 300']
out, i, done = c.splitlines(True), 0, False
res = []
while i < len(out):
    l = out[i]
    if l.rstrip('\n') == '  - name: PROXY-GEO' and not done:
        res.extend(x + '\n' for x in block); done = True
        i += 1
        while i < len(out) and not out[i].startswith('  - name:'):
            i += 1
        continue
    res.append(l); i += 1
open(dst, 'w').write(''.join(res))
print('replaced' if done else 'not-found', file=sys.stderr)
sys.exit(0 if done else 1)
PY
  putcfg "$H" "$TMP/final.yaml" || { log "  [pin] 终态写回失败,还原"; putcfg "$H" "$TMP/orig.yaml"; reload "$H" >/dev/null; return 1; }
  rc="$(reload "$H")"
  [ "$rc" = "204" ] || { log "  [pin] 终态重载失败($rc),还原"; putcfg "$H" "$TMP/orig.yaml"; reload "$H" >/dev/null; return 1; }
  sleep 2
  if clean "$(vfy "$H")"; then log "  [pin] ✅ 已固定干净节点,体检通过"; return 0; fi
  log "  [pin] 固定后体检仍不过"; return 1
}

heal_one(){  # $1=H(容器) 0=健康 2=踢好后健康 3=PIN治愈 1=不治
  local H="$1" tag; [ "$H" = "-" ] && tag="本地" || tag="$H"
  local r; r="$(vfy "$H")"
  if clean "$r"; then log "✅ [$tag] 健康 (google ${r%%|*} 无跳转, agy-api ${r##*|})"; return 0; fi
  log "⚠️  [$tag] 不健康 (google ${r%%|*}, agy-api ${r##*|} → 踢健康检查+重载)"
  kick "$H" >/dev/null; sleep 3
  r="$(vfy "$H")"
  if clean "$r"; then log "✅ [$tag] 踢后恢复"; return 2; fi
  log "⚠️  [$tag] 仍不健康 → PIN 逐节点探测"
  if pin_heal "$H"; then return 3; fi
  r="$(vfy "$H")"; clean "$r" && return 3
  log "❌ [$tag] 自愈失败,需人工介入 (google ${r%%|*}, agy-api ${r##*|})"; return 1
}

# ---------- 宿主机 mihomo(systemd, 非容器) ----------
heal_host_mihomo(){  # $1=H; 无 systemd 单元则静默跳过
  local H="$1"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$H" "systemctl is-active mihomo 2>/dev/null" 2>/dev/null | grep -q active || return 0
  local r
  r="$(ssh -o BatchMode=yes "$H" "curl -s -o /dev/null -w '%{http_code}|%{redirect_url}' --max-time 12 http://www.google.com" 2>/dev/null)|n/a"
  if clean "$r"; then log "✅ [$H 宿主机mihomo] 健康"; return 0; fi
  log "⚠️  [$H 宿主机mihomo] 不健康(${r%%|*}) → 踢+重载"
  ssh -o BatchMode=yes "$H" "curl -s -o /dev/null -X PUT http://127.0.0.1:9090/providers/proxies/static --max-time 15; curl -s -o /dev/null -w '%{http_code}' -X PUT 'http://127.0.0.1:9090/configs?force=true' -H 'Content-Type: application/json' -d '{\"path\":\"/root/.config/mihomo/config.yaml\"}' --max-time 10" 2>/dev/null
  sleep 3
  r="$(ssh -o BatchMode=yes "$H" "curl -s -o /dev/null -w '%{http_code}|%{redirect_url}' --max-time 12 http://www.google.com" 2>/dev/null)|n/a"
  if clean "$r"; then log "✅ [$H 宿主机mihomo] 踢后恢复"; return 0; fi
  log "❌ [$H 宿主机mihomo] 踢后仍不健康(${r%%|*}),chroot PIN 自愈较重,留待人工(参考 memory: aja-pc-host-proxy-topology)"
  return 1
}

# ================= 主流程 =================
log "===== 自愈轮开始 ====="
rc_all=0

# 1. 导出(仅当 App 配置比静态文件新)
APP_CFG="${HOME}/Library/Application Support/com.qianmoltd.qianmo/config.yaml"
if [ "$APP_CFG" -nt "$STATIC_LOCAL" ]; then
  log "[导出] App 配置有更新,重新导出..."
  cp "$STATIC_LOCAL" "$TMP/static.bak" 2>/dev/null
  bash "${REPO_DIR}/scripts/export-nodes-mac.sh" >> "$LOG" 2>&1 || log "[导出] ⚠️ 导出脚本非零,沿用现有文件"
  # 合规门禁: 机场 2026-11-08 换过一次花名册(日/台/智/韩全下架,只剩美/新=agy 拒用区)。
  # 新快照若没有合规区节点,回滚保留旧花名册(cat > 截断写,保 inode 不破容器挂载)
  if ! grep -qE '日本|台湾|台灣|智利|韩国' "$STATIC_LOCAL" 2>/dev/null && [ -s "$TMP/static.bak" ]; then
    log "[导出] ⚠️ 新快照无合规区节点(日/台/智/韩),回滚保留旧花名册"
    cat > "$STATIC_LOCAL" < "$TMP/static.bak"
  fi
else
  log "[导出] App 配置无更新,跳过"
fi

# 2. 本地容器(返回 0=健康 2=踢后治愈 3=PIN治愈 都算本轮成功;1=不治才置失败)
r=0; heal_one "-" || r=$?
[ "$r" = "1" ] && rc_all=1

# 3. 各宿主机
for t in "${HOSTS[@]}"; do
  H="${t%%:*}"; P="${t#*:}"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$H" "test -d '$P/mihomo-conf'" 2>/dev/null; then
    log "⏭  [$H] SSH 不通或路径不存在,跳过"; continue
  fi
  # 推送(md5 没变不推)
  lmd5="$(md5 -q "$STATIC_LOCAL" 2>/dev/null)"
  rmd5="$(ssh -o BatchMode=yes "$H" "md5sum '$P/mihomo-conf/proxies-static.yaml' 2>/dev/null | cut -d' ' -f1" 2>/dev/null)"
  if [ -n "$lmd5" ] && [ "$lmd5" != "$rmd5" ]; then
    log "[推送] $H 快照有变,推送中..."
    base64 < "$STATIC_LOCAL" | ssh -o BatchMode=yes "$H" "f='$P/mihomo-conf/proxies-static.yaml'; base64 -d > \"\$f\"" 2>/dev/null \
      && log "[推送] $H 完成" || { log "[推送] $H ❌ 失败"; rc_all=1; }
  else
    log "[推送] $H 快照一致,跳过"
  fi
  r=0; heal_one "$H" || r=$?
  [ "$r" = "1" ] && rc_all=1
  heal_host_mihomo "$H" || rc_all=1
done

log "===== 自愈轮结束 (exit=$rc_all) ====="
exit "$rc_all"
