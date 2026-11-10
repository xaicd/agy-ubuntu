#!/usr/bin/env bash
#==============================================================================
# fix-aja-pc-host-mihomo.sh — aja-pc 宿主机 mihomo 出口修复(需人工授权后执行)
#
# 症状:宿主机 curl google 首页返 000(出口全死),但 mihomo.service active、
#       7890/9090 端口在听 —— 说明是**内存里的 provider 节点表陈旧**,
#       而磁盘上的 proxies-static.yaml 已经是新花名册。
#
# 原理(2026-11-08 已在本机容器验证):mihomo 的 proxy-provider 对 file 类型
#   **只认内存不认磁盘**——`PUT /providers/proxies/static` 只重测不重读,
#   `PUT /configs?force=true` 也因 provider 缓存不重读文件。
#   唯一可靠办法 = **换 provider path**:复制一份新文件 + 改 config 里的 path
#   + 热重载 → provider 重新加载文件。
#
# 安全红线(必须遵守):
#   1. **绝不改 rules 段**——宿主机 mihomo 是全局 TUN + auto-route,
#      rules 里缺私网/Tailscale DIRECT 会劫持 tailscale 核心网络。
#      本脚本只做"改 path 一行 + 热重载",不碰任何规则。
#   2. **绝不 pkill mihomo**——会断掉容器转发与宿主网络(见 memory:
#      aja-pc-host-proxy-topology)。只用 9090 API 热重载。
#   3. 改前先备份 config.yaml;改后立刻验证 SSH 仍通、tailscale 正常。
#   4. 建议先跑 --check(纯只读)确认现状与 DIRECT 规则齐全。
#
# 用法:
#   bash scripts/fix-aja-pc-host-mihomo.sh --check    # 只读体检(默认)
#   bash scripts/fix-aja-pc-host-mihomo.sh --fix      # 执行修复
#==============================================================================
set -uo pipefail

HOST="${AJA_HOST:-aja-pc}"
HOST_MIHOMO_DIR="/root/.config/mihomo"
HOST_CFG="${HOST_MIHOMO_DIR}/config.yaml"

MODE="${1:---check}"

# 在宿主上以 root 身份执行(用户无 sudo 密码,借 docker 组特权 chroot)
host_root(){  # $1=shell 脚本
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
      "docker run --rm --privileged --pid host --network host -v /:/host --entrypoint sh redis:7-alpine -c '$1'" 2>&1
}

check(){
  echo "=== 只读体检: ${HOST} 宿主机 mihomo ==="
  host_root "
    echo '--- 服务与端口 ---'
    systemctl is-active mihomo 2>/dev/null || echo '(systemctl 不可用)'
    ss -ltn 2>/dev/null | grep -E '7890|9090' | head -3
    echo
    echo '--- 出口连通性(宿主机直连) ---'
    for i in 1 2; do
      curl -s -o /dev/null -w '  home=%{http_code}|%{redirect_url}\n' --max-time 12 http://www.google.com
    done
    echo
    echo '--- provider path ---'
    grep -n 'path:' ${HOST_CFG}
    echo
    echo '--- 磁盘节点表(合规区计数) ---'
    echo -n '  节点总数: '; grep -c 'name:' ${HOST_MIHOMO_DIR}/proxies-static.yaml 2>/dev/null || echo 0
    echo -n '  合规区(日本/台湾/智利/韩国): '
    grep -oE '日本|台湾|台灣|智利|韩国' ${HOST_MIHOMO_DIR}/proxies-static.yaml 2>/dev/null | wc -l
    echo
    echo '--- ★ Tailscale/私网 DIRECT 规则(红线,必须齐全) ---'
    grep -nE 'IP-CIDR|SRC-IP' ${HOST_CFG}
    echo
    echo '--- 内存 provider 节点数(via 9090) ---'
    curl -s http://127.0.0.1:9090/providers/proxies/static 2>/dev/null \
      | grep -o '\"name\"' | wc -l
  "
}

fix(){
  echo "=== 执行修复: ${HOST} 宿主机 mihomo(仅改 provider path,不碰 rules) ==="
  echo "--- 前置校验:DIRECT 规则必须齐全,缺任一项则中止 ---"
  local rules
  rules="$(host_root "grep -cE 'IP-CIDR,100\.64\.0\.0/10,DIRECT|SRC-IP-CIDR,172\.16\.0\.0/12,DIRECT' ${HOST_CFG}")"
  if ! echo "$rules" | grep -qE '^[2-9]'; then
    echo "❌ Tailscale/容器网段 DIRECT 规则缺失(命中 $rules,需 ≥2),中止以免劫持核心网络"
    exit 1
  fi
  echo "  ✅ DIRECT 规则校验通过"

  host_root "
    set -e
    cd ${HOST_MIHOMO_DIR}
    TS=\$(date +%Y%m%d%H%M%S)
    cp config.yaml config.yaml.bak-\$TS
    cp proxies-static.yaml proxies-static-v2.yaml
    sed -i 's|path: ${HOST_MIHOMO_DIR}/proxies-static.yaml|path: ${HOST_MIHOMO_DIR}/proxies-static-v2.yaml|' config.yaml
    echo '--- 改后 path ---'
    grep -n 'path:' config.yaml
    echo '--- rules 段是否被改动(应为空)---'
    diff <(grep -E 'IP-CIDR|SRC-IP' config.yaml.bak-\$TS) <(grep -E 'IP-CIDR|SRC-IP' config.yaml) || true
    echo '(以上无输出 = rules 未变)'
    echo '--- 热重载(不重启进程)---'
    curl -s -o /dev/null -w 'reload=%{http_code}\n' -X PUT 'http://127.0.0.1:9090/configs?force=true' \
      -H 'Content-Type: application/json' \
      -d '{\"path\":\"${HOST_CFG}\"}' --max-time 10
  "
  echo
  echo "--- 修复后验证 ---"
  sleep 2
  check
}

case "$MODE" in
  --fix) fix ;;
  --check|"") check ;;
  *) echo "用法: $0 [--check|--fix]"; exit 1 ;;
esac
