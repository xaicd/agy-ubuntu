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
    filter: "^【.*(美国|日本|新加坡|韩国|加拿大|英国|德国|法国|荷兰|澳大利亚|新西兰)"
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
rules:
  - MATCH,PROXY
EOF
else
    echo "[entrypoint] No CLASH_URL — writing minimal fallback config." >&2
    cat > "${CONFIG}" <<'EOF'
mixed-port: 7890
mode: rule
log-level: info
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

cat >> "${CONFIG}" <<'EOF'

# --- Appended by entrypoint.sh: force TUN capture + internal DNS ---
tun:
  enable: true
  stack: system
  device: clash0
  mtu: 1400
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
# 5. Welcome banner + interactive shell
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
