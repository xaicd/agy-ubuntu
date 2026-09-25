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

if [ -n "${CLASH_URL:-}" ]; then
    echo "[entrypoint] CLASH_URL detected — configuring proxy-provider subscription..."
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
      url: https://www.gstatic.com/generate_204
      interval: 300
proxy-groups:
  - name: PROXY
    type: url-test
    use:
      - sub
    filter: ".*(日本|美国|智利|台湾).*"
    exclude-filter: ".*(香港|HK|Hong Kong|澳门|新加坡|SG).*"
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 200
rules:
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
      url: https://www.gstatic.com/generate_204
      interval: 300
proxy-groups:
  - name: PROXY
    type: url-test
    use:
      - static
    filter: ".*(日本|美国|智利|台湾).*"
    exclude-filter: ".*(香港|HK|Hong Kong|澳门|新加坡|SG).*"
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 200
rules:
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
# 3. Launch mihomo in the background, logs redirected
#------------------------------------------------------------------------------
echo "[entrypoint] Starting mihomo (logs: ${LOG_FILE}) ..."
mihomo -d "${MIHOMO_DIR}" > "${LOG_FILE}" 2>&1 &

#------------------------------------------------------------------------------
# 4. Give the clash0 TUN interface a moment to spin up, then lock down DNS.
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
# 5. Share host git identity + SSH keys (so git commit/push works in-container).
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
    chmod 600 /root/.ssh/id_* 2>/dev/null
    chmod 644 /root/.ssh/*.pub /root/.ssh/known_hosts* 2>/dev/null
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
# 5.1 Claude / Antigravity 全局 Commands & Skills 联动与初始化
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


#------------------------------------------------------------------------------
# 6. Welcome banner + interactive shell
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

   Mihomo logs : /root/mihomo.log
   Config      : /root/.config/mihomo/config.yaml

==========================================================================

BANNER

exec /bin/bash
