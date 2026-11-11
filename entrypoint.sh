#!/usr/bin/env bash
#==============================================================================
# entrypoint.sh — lifecycle manager for the isolated Mihomo (Clash Meta) sandbox
#
#   1. Fetch the subscription profile from $CLASH_URL (if provided)
#   2. Inject the mandatory TUN + DNS blocks into the config
#   3. Start mihomo in the background (TUN device: clash0)
#   4. Lock container DNS to 127.0.0.1 so ALL resolution goes through mihomo
#   5. Hand over to an interactive bash shell (run `agy` to authenticate)
#==============================================================================

set -euo pipefail

MIHOMO_DIR="/root/.config/mihomo"
CONFIG="${MIHOMO_DIR}/config.yaml"
LOG_FILE="/root/mihomo.log"

# 自动检测 eth0 的实际 MTU,让 TUN 与之匹配。
# Windows WSL2 的 eth0 是 1400(daemon 已降),原生 Linux 是 1500。
# 两者不一致会导致大响应被截断(EOF),所以不能硬编码。
ETH0_MTU="$(ip link show eth0 2>/dev/null | sed -n 's/.*mtu \([0-9]*\).*/\1/p')"
TUN_MTU="${TUN_MTU:-${ETH0_MTU:-1500}}"

#------------------------------------------------------------------------------
# 1. Build the base config.
#    If CLASH_URL is set, use mihomo's proxy-providers to fetch the subscription.
#    Most subscriptions are base64-encoded URI lists (NOT valid YAML), so they
#    cannot be dropped into config.yaml directly — mihomo must decode them.
#------------------------------------------------------------------------------
mkdir -p "${MIHOMO_DIR}/providers"

# bind-mount 源文件缺失时,Docker 会在挂载点建一个**目录**(而非文件);只靠 -f
# 判断会静默跳过本地兜底,导致"明明配了兜底却没生效"的隐性断网(容器侧仍表现为
# curl「Empty reply from server」)。这里显式提示,便于一眼定位。
if [ -e "${MIHOMO_DIR}/proxies-static.yaml" ] && [ ! -f "${MIHOMO_DIR}/proxies-static.yaml" ]; then
    echo "[entrypoint] ⚠️  ${MIHOMO_DIR}/proxies-static.yaml 不是普通文件(多为宿主机源文件缺失、被 Docker 建成目录),本地兜底节点未生效;" >&2
    echo "              请先在宿主机用 scripts/export-nodes-linux.sh 生成该文件,再重建容器。" >&2
fi

# 先置空:静态分支的 heredoc 同样展开 ${SUB_DIRECT_RULES},不初始化会触发 set -u
SUB_DIRECT_RULES=""

if [ -n "${CLASH_URL:-}" ]; then
    echo "[entrypoint] CLASH_URL detected — configuring proxy-provider subscription..."
    # 订阅服务器必须 DIRECT:provider 首拉发生在 TUN auto-route 接管之后,
    # 若命中 MATCH,PROXY 会形成「没节点 → 拉不到订阅 → 没节点」bootstrap 死循环
    # (日志特征:dial PROXY (match Match/) mihomo --> <订阅服务器> error)
    SUB_HOST="$(printf '%s' "${CLASH_URL}" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[:/?#].*$##')"
    if printf '%s' "${SUB_HOST}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        SUB_DIRECT_RULES="  - IP-CIDR,${SUB_HOST}/32,DIRECT"
    elif [ -n "${SUB_HOST}" ]; then
        SUB_DIRECT_RULES="  - DOMAIN,${SUB_HOST},DIRECT"
    fi

    # 本地兜底节点(可选):宿主机导出的 proxies-static.yaml。订阅入口域名被停权/
    # 轮换时,订阅里所有节点都拨不通,只有它还能救命 —— 并入 PROXY-RESCUE。
    LOCAL_PROVIDER_BLOCK=""
    USE_ITEMS="      - sub"
    if [ -f "${MIHOMO_DIR}/proxies-static.yaml" ]; then
        LOCAL_PROVIDER_BLOCK="  local:
    type: file
    path: ${MIHOMO_DIR}/proxies-static.yaml
    health-check:
      enable: true
      url: http://www.google.com
      expected-status: \"200\"
      interval: 300
"
        # 本地兜底节点排在订阅之前:订阅入口域名失效时,mihomo 启动即选中可用节点,
        # 不必等健康检查逐个淘汰死节点(否则启动后一段时间连接会卡 i/o timeout)
        USE_ITEMS="      - local
      - sub"
        echo "[entrypoint] 检测到本地兜底节点 proxies-static.yaml,优先并入 PROXY-GEO/RESCUE。"
    fi

    cat > "${CONFIG}" <<EOF
mixed-port: 7890
mode: rule
log-level: info
# 容器无 IPv6 路由:不关会去拨节点域名的 AAAA(CloudFront 2600::),
# 每次连接先在 v6 黑洞上烧掉超时预算 → url-test "all proxies timeout"
ipv6: false
external-controller: 127.0.0.1:9090
proxy-providers:
  sub:
    type: http
    url: "${CLASH_URL}"
    interval: 3600
    path: ${MIHOMO_DIR}/providers/sub.yaml
    health-check:
      enable: true
      url: http://www.google.com
      expected-status: "200"
      interval: 300
${LOCAL_PROVIDER_BLOCK}proxy-groups:
  # 结构:PROXY(统一出口) → [PROXY-GEO(合规主组) → PROXY-RESCUE(降级组)]
  #   正常走 GEO;GEO 内节点全部不可用(入口域名失效/健康检查全挂)时,
  #   outer fallback 自动降级到 RESCUE,尽量保住"有网可用"。
  #
  # 主组 fallback 按序故障转移,不用 url-test:延迟轮盘会选中出口被 Google
  # 判为不支持地区的节点 → Gemini 报 User location is not supported。
  # 健康检查用 google.com 期望 200:被判香港的出口会 302 → 检查失败,自动跳过
  - name: PROXY-GEO
    type: fallback
    use:
${USE_ITEMS}
    # 优先日/台/智核心加速档(2026-09-26 逐节点验证全通);美国档出口被 Google
    # 判为不支持地区(Gemini 报 User location is not supported),2026-10-27 起
    # 一并硬排除,不再依赖健康检查兜底
    filter: ".*(日本|台湾|台灣|Japan|Taiwan).*"
    # 2026-11-01:3X 核心/10X 专线 全部经同一 40.160.141.80 出口(Google 判 HK→302),
    # 改吃 1X 边缘加速(CloudFront,按地区正确落地 JP/CL/TW),故排除 3X/10X 核心/专线
    # 2026-11-11 修订:机场在**单节点背后轮换出口 IP**(同一节点前后测出 200/302),
    #   单档(只留 1X 或只留 3X)冗余为零,漂到坏出口就整组无合格节点。
    #   故【1X】边缘加速与【3X】核心加速**两档都留**,只硬排除真禁用区:
    #   美国(Google 判 Gemini 不支持地区)、香港/澳门/新加坡(agy 拒用)、
    #   智利(Antigravity 拒该出口,见 70a5645)、【10X】专线(与 3X 同出口)。
    exclude-filter: ".*(香港|HK|Hong Kong|澳门|新加坡|SG|美国|美國|USA|United States|🇺🇸|智利|Chile|【10X】|专线加速).*"
    url: http://www.google.com
    expected-status: "200"
    interval: 300
  # 降级组:兜底用,不设 filter —— 收进订阅全部节点,靠 google 200 健康检查
  # 自动跳过(被判香港的出口会 302 被淘汰);仅当 GEO 全挂时才会被启用
  - name: PROXY-RESCUE
    type: fallback
    use:
${USE_ITEMS}
    url: http://www.google.com
    expected-status: "200"
    interval: 300
  # 统一出口:先合规 GEO,GEO 全挂自动降级 RESCUE
  - name: PROXY
    type: fallback
    proxies:
      - PROXY-GEO
      - PROXY-RESCUE
    url: http://www.google.com
    expected-status: "200"
    interval: 300
rules:
${SUB_DIRECT_RULES}
  # Tailscale/CGNAT 段(100.64.0.0/10)直连:经宿主 tailscale0 转发,不进 TUN 代理
  - IP-CIDR,100.64.0.0/10,DIRECT
  # docker 网段(172.16/12)直连:容器转发/互访流量不被自己的 TUN 劫持
  # (否则容器访问宿主或其它容器会绕代理,表现为莫名超时)
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - MATCH,PROXY
EOF
elif [ -f "${MIHOMO_DIR}/proxies-static.yaml" ]; then
    # macOS/本地模式:宿主机已导出的节点文件(如从千陌/FlClash 提取),免订阅
    echo "[entrypoint] proxies-static.yaml detected — using static node list..."
    cat > "${CONFIG}" <<EOF
mixed-port: 7890
mode: rule
log-level: info
ipv6: false
external-controller: 127.0.0.1:9090
proxy-providers:
  static:
    type: file
    path: ${MIHOMO_DIR}/proxies-static.yaml
    health-check:
      enable: true
      url: http://www.google.com
      expected-status: "200"
      interval: 300
proxy-groups:
  # 结构:PROXY(统一出口) → [PROXY-GEO(合规主组) → PROXY-RESCUE(降级组)]
  #   正常走 GEO;GEO 内节点全部不可用(入口域名失效/健康检查全挂)时,
  #   outer fallback 自动降级到 RESCUE,尽量保住"有网可用"。
  #
  # 主组 fallback 按序故障转移,不用 url-test:延迟轮盘会选中出口被 Google
  # 判为不支持地区的节点 → Gemini 报 User location is not supported。
  # 健康检查用 google.com 期望 200:被判香港的出口会 302 → 检查失败,自动跳过
  - name: PROXY-GEO
    type: fallback
    use:
      - static
    # 优先日/台/智核心加速档(2026-09-26 逐节点验证全通);美国档出口被 Google
    # 判为不支持地区(Gemini 报 User location is not supported),2026-10-27 起
    # 一并硬排除,不再依赖健康检查兜底
    filter: ".*(日本|台湾|台灣|Japan|Taiwan).*"
    # 2026-11-01:3X 核心/10X 专线 全部经同一 40.160.141.80 出口(Google 判 HK→302),
    # 改吃 1X 边缘加速(CloudFront,按地区正确落地 JP/CL/TW),故排除 3X/10X 核心/专线
    #
    # 2026-11-02 修订(墨斗 agy_local 通道停摆实证):
    #   GEO 组只留【3X】美国02 一档时,该节点出口 40.160.141.86 已被 Google 判为
    #   "User location is not supported for the API use"(400),且其健康检查
    #   https://www.gstatic.com/generate_204 全部 timeout(delay=0)⇒ GEO 组整个
    #   退化成单节点死出口 ⇒ mihomo 对所有 HTTPS 返 SSL_ERROR_SYSCALL ⇒
    #   Antigravity OAuth 刷新失败 ⇒ "You are not logged into Antigravity" ⇒
    #   模型清单为空 ⇒ agy 报 "plan model not specified"(症状,非根因)。
    #   实测【3X】日本01(出口 45.95.212.34)与【3X】新加坡01(出口 152.175.66.145)
    #   被 Google 判为支持地区,agy 实跑 status=SUCCESS ⇒ GEO 组必须含多档
    #   跨地区节点,且健康检查 URL 换成 google 根页而非 generate_204。
    # 2026-11-11 修订:机场在**单节点背后轮换出口 IP**(同一节点前后测出 200/302),
    #   单档(只留 1X 或只留 3X)冗余为零,漂到坏出口就整组无合格节点。
    #   故【1X】边缘加速与【3X】核心加速**两档都留**,只硬排除真禁用区:
    #   美国(Google 判 Gemini 不支持地区)、香港/澳门/新加坡(agy 拒用)、
    #   智利(Antigravity 拒该出口,见 70a5645)、【10X】专线(与 3X 同出口)。
    exclude-filter: ".*(香港|HK|Hong Kong|澳门|新加坡|SG|美国|美國|USA|United States|🇺🇸|智利|Chile|【10X】|专线加速).*"
    url: http://www.google.com
    expected-status: "200"
    interval: 300
  # 降级组:兜底用,不设 filter —— 收进订阅全部节点,靠 google 200 健康检查
  # 自动跳过(被判香港的出口会 302 被淘汰);仅当 GEO 全挂时才会被启用
  - name: PROXY-RESCUE
    type: fallback
    use:
      - static
    url: http://www.google.com
    expected-status: "200"
    interval: 300
  # 统一出口:先合规 GEO,GEO 全挂自动降级 RESCUE
  - name: PROXY
    type: fallback
    proxies:
      - PROXY-GEO
      - PROXY-RESCUE
    url: http://www.google.com
    expected-status: "200"
    interval: 300
rules:
${SUB_DIRECT_RULES}
  # Tailscale/CGNAT 段(100.64.0.0/10)直连:经宿主 tailscale0 转发,不进 TUN 代理
  - IP-CIDR,100.64.0.0/10,DIRECT
  # docker 网段(172.16/12)与私网直连:容器转发/互访流量不被自己的 TUN 劫持
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - MATCH,PROXY
EOF
else
    echo "[entrypoint] No CLASH_URL — writing minimal fallback config." >&2
    cat > "${CONFIG}" <<'EOF'
mixed-port: 7890
mode: rule
log-level: info
ipv6: false
EOF
fi

#------------------------------------------------------------------------------
# 2. Seamlessly append TUN + DNS settings.
#    First strip any pre-existing top-level `tun:` / `dns:` sections from the
#    downloaded profile — duplicate YAML keys are fatal for mihomo — then
#    append the canonical block.
#------------------------------------------------------------------------------
awk '
    /^(tun|dns):/ { skip = 1; next }
    skip && /^[^[:space:]#]/ { skip = 0 }
    !skip { print }
' "${CONFIG}" > "${CONFIG}.clean" && mv -f "${CONFIG}.clean" "${CONFIG}"

cat >> "${CONFIG}" <<EOF

# --- Appended by entrypoint.sh: force TUN capture + internal DNS ---
tun:
  enable: true
  stack: system
  device: clash0
  mtu: ${TUN_MTU}
  auto-route: true
  auto-detect-interface: true

dns:
  enable: true
  listen: 127.0.0.1:53
  enhanced-mode: fake-ip
  nameserver:
    - 223.5.5.5
    - 114.114.114.114
EOF

#------------------------------------------------------------------------------
# 3. 入口域名存活自检函数
#    背景:机场轮换/停权入口域名后,订阅里所有节点的 server 域名都会 NXDOMAIN,
#    mihomo 只会在日志刷 "dns resolve failed" —— 容器侧看到的仅是 curl
#    "Empty reply from server",极易被误判成沙箱故障。启动时主动体检并告警。
#    注意:必须走 mihomo 的 /dns/query(真实解析);系统 getent 在 fake-ip 模式
#    下对任何域名都会返回 198.18.x 假 IP,拿不到 NXDOMAIN 真相。
#------------------------------------------------------------------------------
check_entry_domains() {
    local srcs="" files="" f d status ok=0 dead=0 dead_list="" ip_re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'

    for f in "${MIHOMO_DIR}/providers/sub.yaml" "${MIHOMO_DIR}/proxies-static.yaml"; do
        if [ -f "$f" ] && [ -s "$f" ]; then srcs="${srcs} $f"; files="${files} $(basename "$f")"; fi
    done
    if [ -z "$srcs" ]; then
        echo "[entry-domain] 未找到节点文件(provider/static),跳过入口域名自检。"
        return 0
    fi

    local domains
    domains="$(grep -hoE '(^|[^A-Za-z0-9_])server: *"?[^",}[:space:]]+' $srcs 2>/dev/null | sed -E 's/.*server: *"?//' | sort -u || true)"
    if [ -z "$domains" ]; then
        echo "[entry-domain] 节点文件无 server 字段,跳过自检。"
        return 0
    fi

    echo "[entry-domain] 自检节点入口域名解析(来源:${files# };经 mihomo 127.0.0.1:9090)..."
    for d in $domains; do
        if [[ "$d" =~ $ip_re ]]; then
            echo "  - ${d}  (裸 IP,跳过)"
            continue
        fi
        status="$(curl -s --max-time 6 "http://127.0.0.1:9090/dns/query?name=${d}&type=A" 2>/dev/null \
                  | sed -n 's/.*"Status":\([0-9]*\).*/\1/p' || true)"
        case "${status:-}" in
            0)  echo "  - ${d}  ✅ 可解析"; ok=$((ok + 1)) ;;
            3)  echo "  - ${d}  ❌ NXDOMAIN(域名不存在/被注册商停权)"; dead=$((dead + 1)); dead_list="${dead_list} ${d}" ;;
            2)  echo "  - ${d}  ⚠️  SERVFAIL(DNS 上游不可达)"; dead=$((dead + 1)); dead_list="${dead_list} ${d}" ;;
            *)  echo "  - ${d}  ⚠️  解析超时/无响应"; dead=$((dead + 1)); dead_list="${dead_list} ${d}" ;;
        esac
    done

    if [ "$ok" -eq 0 ] && [ "$dead" -gt 0 ]; then
        cat <<EOF

#########################################################################
 [entry-domain] ❌ 致命:订阅内所有节点入口域名都无法解析(${dead_list})。
   所有节点拨号都会 DNS 失败 —— 容器侧只会表现为 curl
   "Empty reply from server",而不是明确的连接错误,极易误判成沙箱故障。
   这几乎总是机场侧问题(域名 NXDOMAIN = 被注册商 clientHold/停权,
   或已轮换入口域名),本地配置无法修复。
   → 请更换 CLASH_URL 订阅,或联系机场客服(见订阅内 info 节点)。
#########################################################################
EOF
    elif [ "$dead" -gt 0 ]; then
        echo "[entry-domain] ⚠️  部分入口域名失效(${dead_list}):相关节点会被健康检查自动跳过。"
    else
        echo "[entry-domain] ✅ 全部入口域名可解析。"
    fi
}

#------------------------------------------------------------------------------
# 3. Validate the generated config BEFORE starting mihomo.
#    2026-11-02 事故复盘:容器内 config.yaml 曾残留未展开的 ${SUB_DIRECT_RULES}
#    占位符 ⇒ YAML 非法 ⇒ mihomo 下次启动即全盘失败,而当时进程仍靠 22:12 的
#    内存态侥幸存活 ⇒ 表面"已修复"实则一重启即断网。
#    这里用 mihomo 自带的 -t 做语法门禁:不通过就带着备份启动,绝不静默带病上岗。
#------------------------------------------------------------------------------
echo "[entrypoint] Validating generated config (mihomo -t) ..."
if mihomo -t -d "${MIHOMO_DIR}" >/tmp/mihomo-config-test.log 2>&1; then
    echo "[entrypoint] ✅ config.yaml 语法校验通过。"
else
    echo "[entrypoint] ❌ config.yaml 语法校验失败 —— 详见 /tmp/mihomo-config-test.log" >&2
    tail -5 /tmp/mihomo-config-test.log >&2
    if [ -f "${CONFIG}.bak.last-good" ]; then
        echo "[entrypoint]    回滚到上一份可用配置 ${CONFIG}.bak.last-good" >&2
        cp "${CONFIG}.bak.last-good" "${CONFIG}"
    else
        echo "[entrypoint]    无可用备份,中止启动(避免带病上岗导致全盘断网)。" >&2
        exit 1
    fi
    mihomo -t -d "${MIHOMO_DIR}" >/tmp/mihomo-config-test.log 2>&1 \
        && echo "[entrypoint] ✅ 回滚后配置校验通过。" \
        || { echo "[entrypoint] ❌ 回滚后仍校验失败,中止启动。" >&2; exit 1; }
fi
# 留一份"上一份可用配置"快照,供下次启动回滚用
cp -f "${CONFIG}" "${CONFIG}.bak.last-good"

#------------------------------------------------------------------------------
# 4. Launch mihomo in the background, logs redirected
#------------------------------------------------------------------------------
echo "[entrypoint] Starting mihomo (logs: ${LOG_FILE}) ..."
mihomo -d "${MIHOMO_DIR}" > "${LOG_FILE}" 2>&1 &

#------------------------------------------------------------------------------
# 5. Give the clash0 TUN interface a moment to spin up, then lock down DNS.
#    Overwrite /etc/resolv.conf — never append — so the container can only
#    ever resolve through mihomo.
#------------------------------------------------------------------------------
sleep 3

if ip link show clash0 >/dev/null 2>&1; then
    echo "[entrypoint] TUN interface 'clash0' is up."
else
    echo "[entrypoint] WARNING: 'clash0' not visible yet — check ${LOG_FILE}" >&2
fi

printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf

#------------------------------------------------------------------------------
# 4c. 入口域名存活自检(等 provider 拉取完成后执行;纯告警,不阻断启动)
#------------------------------------------------------------------------------
for _wait in $(seq 1 15); do
    if [ -s "${MIHOMO_DIR}/providers/sub.yaml" ] || [ -s "${MIHOMO_DIR}/proxies-static.yaml" ]; then
        break
    fi
    sleep 1
done
check_entry_domains || true

#------------------------------------------------------------------------------
# 4b. Disable agy's built-in auto-updater.
#     agy 检查更新时会偷偷下载新版 + 重置登录态,在容器里没有控制终端,
#     重置后 OAuth 浏览器跳转走不通,就出现「登录异常」。
#     把 last_check 推到 2099 强制跳过本次检查;update.lock 保留存在阻止重启检查。
#------------------------------------------------------------------------------
if [ -d /root/.gemini/antigravity-cli/updater ]; then
    touch /root/.gemini/antigravity-cli/updater/update.lock
    echo "9999999999" > /root/.gemini/antigravity-cli/last_check.timestamp 2>/dev/null || true
    echo "[entrypoint] agy auto-updater disabled (last_check 推到 2099).",
fi

#------------------------------------------------------------------------------
# 6. Share host git identity + SSH keys (so git commit/push works in-container).
#    Windows bind mounts give SSH keys wrong permissions — copy + chmod 600.
#    GitHub HTTPS remotes are rewritten to SSH (uses the shared key, no PAT),
#    routed over ssh.github.com:443 (SSH-over-HTTPS, reliable behind proxies).
#------------------------------------------------------------------------------
if [ -f /root/.gitconfig-host ]; then
    cp /root/.gitconfig-host /root/.gitconfig
    chmod 644 /root/.gitconfig
    cat >> /root/.gitconfig <<'EOF'

[url "git@github.com:"]
    insteadOf = https://github.com/
EOF
    # 绑定挂载的 Windows 文件会带来 CRLF / 权限差异,关闭这两项避免 git 误报
    git config --global core.autocrlf false
    git config --global core.filemode false
    echo "[entrypoint] git identity shared (GitHub HTTPS → SSH rewrite enabled)."
fi

if [ -d /root/.ssh-host ] && [ -n "$(ls -A /root/.ssh-host 2>/dev/null)" ]; then
    mkdir -p /root/.ssh
    cp -r /root/.ssh-host/. /root/.ssh/ 2>/dev/null
    chmod 700 /root/.ssh
    # 宿主机可能只有 authorized_keys / config(无 id_*/.*pub),未匹配的 glob
    # 在 set -e 下会让整个 entrypoint 退出 → 容器无限重启,故逐个兜底。
    chmod 600 /root/.ssh/id_* 2>/dev/null || true
    chmod 644 /root/.ssh/*.pub /root/.ssh/known_hosts* 2>/dev/null || true
    cat > /root/.ssh/config <<'EOF'
Host github.com
    HostName ssh.github.com
    Port 443
    User git
    StrictHostKeyChecking accept-new
EOF
    chmod 600 /root/.ssh/config
    echo "[entrypoint] SSH keys shared from host (~/.ssh)."
fi

#------------------------------------------------------------------------------
# 6.1 Claude / Antigravity 全局 Commands & Skills 联动与初始化
#------------------------------------------------------------------------------
mkdir -p /root/.claude/commands /root/.claude/skills /root/.agents/skills

for search_base in /root/workspace/agy-ubuntu /root/workspace/wenlv-next /root/workspace/palantir-agent-workflow-template; do
    if [ -d "${search_base}/.claude/commands" ]; then
        cp -n "${search_base}/.claude/commands/"*.md /root/.claude/commands/ 2>/dev/null || true
    fi
    if [ -d "${search_base}/.agents/skills" ]; then
        for sdir in "${search_base}/.agents/skills/"*; do
            if [ -d "$sdir" ]; then
                sname="$(basename "$sdir")"
                [ -e "/root/.claude/skills/$sname" ] || ln -sfn "$sdir" "/root/.claude/skills/$sname"
                [ -e "/root/.agents/skills/$sname" ] || ln -sfn "$sdir" "/root/.agents/skills/$sname"
            fi
        done
    fi
done
echo "[entrypoint] Global Claude commands & skills initialized."

# 6.2 Antigravity 全局记忆与拓扑同步 (GEMINI.md)
for gfile in /root/workspace/agy-ubuntu/GEMINI.md /host-workspace/agy-ubuntu/GEMINI.md /workspace/agy-ubuntu/GEMINI.md; do
    if [ -f "$gfile" ]; then
        mkdir -p /root/.gemini/config
        cp -f "$gfile" /root/.gemini/config/GEMINI.md
        echo "[entrypoint] Antigravity global environment memory synced."
        break
    fi
done

# 6.3 Copilot & Kiro CLI 全局状态自检、挂载与自愈
mkdir -p /root/.copilot /root/.kiro
if [ -d /root/.copilot-host ] && [ -f /root/.copilot-host/config.json ]; then
    if [ ! -f /root/.copilot/config.json ]; then
        cp -r /root/.copilot-host/. /root/.copilot/ 2>/dev/null || true
        chmod 700 /root/.copilot 2>/dev/null || true
        chmod 600 /root/.copilot/* 2>/dev/null || true
        echo "[entrypoint] Copilot auth & config initialized from host (~/.copilot)."
    fi
fi

#------------------------------------------------------------------------------
# 6.4 多 CLI 工具链持久化(npm 全局 prefix + ~/.local/bin 均为命名卷)
#
# 背景: claude / cmd / copilot / kiro-cli 都是模型 CLI,都必须吃容器这条合规出口。
#   但它们原本装在容器可写层(/usr/local/lib/node_modules、/root/.local/bin),
#   `docker rm` + 重建即全部消失 —— 这正是"重建后又要重登一遍"的根因。
# 方案:npm 全局 prefix 指向命名卷 /opt/agy-tools,~/.local/bin 也用命名卷;
#   二进制本体随卷留存,登录态/配置走 bind mount(见 compose)。
#   兼容旧容器:若 /usr/local/lib/node_modules 已有包(旧装法),迁进 prefix。
#------------------------------------------------------------------------------
TOOLS_PREFIX="${NPM_CONFIG_PREFIX:-/opt/agy-tools}"
mkdir -p "${TOOLS_PREFIX}/bin" /root/.local/bin

# PATH 兜底:compose 已设 PATH,此处对 docker exec 进容器的老路径再兜一层
case ":${PATH}:" in
    *":${TOOLS_PREFIX}/bin:"*) ;;
    *) export PATH="${TOOLS_PREFIX}/bin:${PATH}"; ;;
esac

# 旧装法迁移:把 /usr/local/lib/node_modules 里的第三方全局包搬进 prefix
if [ -d /usr/local/lib/node_modules ]; then
    for pkg in @anthropic-ai @github command-code; do
        [ -e "/usr/local/lib/node_modules/${pkg}" ] || continue
        [ -e "${TOOLS_PREFIX}/lib/node_modules/${pkg}" ] && continue
        mkdir -p "${TOOLS_PREFIX}/lib/node_modules"
        cp -a "/usr/local/lib/node_modules/${pkg}" "${TOOLS_PREFIX}/lib/node_modules/" 2>/dev/null || true
        echo "[entrypoint] migrated ${pkg} into persistent prefix ${TOOLS_PREFIX}."
    done
fi

# 四个模型 CLI 的安装(装进持久化 prefix,容器重建不丢)
ensure_npm_cli(){  # $1=包名  $2=命令名
    local pkg="$1" cmdname="$2"
    # 只认 prefix 里的:可写层(/usr/local/bin)的同名命令重建即失,不能算"已装"
    if [ -x "${TOOLS_PREFIX}/bin/${cmdname}" ]; then return 0; fi
    if [ -e "${TOOLS_PREFIX}/lib/node_modules/${pkg}/package.json" ]; then
        # 包体已在卷里,只是软链没重建(prefix 变更后常见)——手工补软链
        mkdir -p "${TOOLS_PREFIX}/bin"
        # 包可能声明多个 bin 别名(command-code: cmd/cmdc/command-code/commandcode),
        # 全部补齐,不然只有主命令能用
        node -e "
            const p=require('${TOOLS_PREFIX}/lib/node_modules/${pkg}/package.json');
            const b=p.bin||{};
            const m=(typeof b==='string')?{'${cmdname}':b}:b;
            for(const [k,v] of Object.entries(m)){
                console.log(k+' '+v);
            }
        " 2>/dev/null | while read -r bname brel; do
            [ -n "$bname" ] && [ -n "$brel" ] || continue
            [ -e "${TOOLS_PREFIX}/lib/node_modules/${pkg}/${brel}" ] || continue
            ln -sf "${TOOLS_PREFIX}/lib/node_modules/${pkg}/${brel}" "${TOOLS_PREFIX}/bin/${bname}" 2>/dev/null || true
        done
        [ -x "${TOOLS_PREFIX}/bin/${cmdname}" ] && return 0
    fi
    echo "[entrypoint] Installing ${cmdname} (${pkg}) into persistent prefix..."
    # -g 走全局布局(prefix/lib/node_modules + prefix/bin);必须显式 -g,
    # 否则装成 local 布局(prefix/node_modules + node_modules/.bin),PATH 找不到。
    # 串行 + 超时:并发装多个包会打满容器代理连接池卡死(2026-11-10 实测)。
    timeout 900 npm install -g --prefix "${TOOLS_PREFIX}" \
        --fetch-timeout=90000 --fetch-retries=1 "${pkg}" >/dev/null 2>&1 \
        || echo "[entrypoint] ⚠️ ${pkg} install failed (timeout or network)."
}

ensure_npm_cli "@anthropic-ai/claude-code" "claude"
ensure_npm_cli "command-code" "cmd"
ensure_npm_cli "@github/copilot" "copilot"

# kiro-cli:安装脚本落在 $HOME/.local/bin(已是命名卷),容器重建后仍在
if [ ! -x /root/.local/bin/kiro-cli ]; then
    echo "[entrypoint] Installing kiro-cli into /root/.local/bin (persistent)..."
    command -v unzip >/dev/null 2>&1 || (apt-get update && apt-get install -y unzip >/dev/null 2>&1 || true)
    curl -fsSL https://cli.kiro.dev/install | bash >/dev/null 2>&1 || echo "[entrypoint] ⚠️ kiro-cli install failed."
fi

# cmd(command-code) 登录态播种:宿主 ~/.commandcode 有 auth.json/providers.json,
# 容器首启复制一次(之后由 bind mount 持久化,不再重复)
if [ -d /root/.commandcode ] && [ ! -f /root/.commandcode/auth.json ] \
   && [ -f /root/.commandcode-host/auth.json ]; then
    cp /root/.commandcode-host/auth.json /root/.commandcode/ 2>/dev/null || true
    for f in providers.json config.json settings.json mcp.json; do
        [ -f "/root/.commandcode-host/$f" ] && cp "/root/.commandcode-host/$f" /root/.commandcode/ 2>/dev/null || true
    done
    chmod 600 /root/.commandcode/* 2>/dev/null || true
    echo "[entrypoint] cmd(command-code) auth & config seeded from host."
fi

# claude 登录态/配置播种:宿主 settings.json 是软链(provider 切换用,如 → settings.jsonglm),
# 必须解引用取真实文件;凭证 .credentials.json 同样复制
if [ -d /root/.claude ] && [ -d /root/.claude-host ]; then
    if [ ! -f /root/.claude/settings.json ] && [ -e /root/.claude-host/settings.json ]; then
        cp -L /root/.claude-host/settings.json /root/.claude/settings.json 2>/dev/null || true
        echo "[entrypoint] Claude settings.json seeded from host (symlink dereferenced)."
    fi
    if [ ! -f /root/.claude/.credentials.json ] && [ -f /root/.claude-host/.credentials.json ]; then
        cp /root/.claude-host/.credentials.json /root/.claude/ 2>/dev/null || true
        chmod 600 /root/.claude/.credentials.json 2>/dev/null || true
        echo "[entrypoint] Claude credentials seeded from host."
    fi
fi


#------------------------------------------------------------------------------
# 7. Welcome banner + interactive shell
#------------------------------------------------------------------------------
cat <<'BANNER'

==========================================================================
   AGY-UBUNTU SANDBOX :: ISOLATED PROXY IS ACTIVE
==========================================================================

   * Mihomo TUN mode  : ACTIVE  (all traffic routed via clash0)
   * DNS hijack       : LOCKED  (resolv.conf -> 127.0.0.1 -> mihomo)
   * Host isolation   : FULL    (default bridge, no host networking)

   100% of container traffic now flows through the proxy.

   Next step:
       >> run `agy` to authenticate Google Antigravity <<
       >> run `copilot` to start GitHub Copilot CLI     <<
       >> run `kiro-cli` to start Kiro AI assistant    <<
       >> run `claude` / `cmd` for Claude Code & cmd    <<

   Mihomo logs : /root/mihomo.log
   Config      : /root/.config/mihomo/config.yaml

==========================================================================

BANNER

exec /bin/bash
