#!/usr/bin/env bash
#==============================================================================
# sync-nodes-to-hosts.sh — 把本机导出的静态节点推送到其它宿主机,并热重载其容器
#
# 背景:机场官方已停用动态订阅,容器只能吃"官方客户端导出的静态节点"。mac 上有
#   官方客户端(阡陌星云)可直接导出;其它 Linux 宿主机(cwall / aja-pc /
#   tc-coolie-claw)没有,故统一由 mac 导出后推送:
#     1. base64 管道推送 → <repo>/mihomo-conf/proxies-static.yaml(先备份旧文件)
#     2. 调容器内 9090 API 无缝热重载(不重启、不杀进程)
#   注意:写入用 `base64 -d >` 就地截断(保持 inode),否则 RO 文件挂载会因
#   rename 换 inode 而与容器脱钩(见 entrypoint.sh 的 deleted-inode 坑)。
#
# 前置:先跑 scripts/export-nodes-mac.sh 生成 mihomo-conf/proxies-static.yaml;
#   本脚本默认直接推送它,加 --export 则先自动导出一遍。
#
# 用法:
#   bash scripts/sync-nodes-to-hosts.sh                          # 推送默认主机
#   bash scripts/sync-nodes-to-hosts.sh --export                 # 先导出再推送
#   bash scripts/sync-nodes-to-hosts.sh aja-pc:/home/beye/workspace/zhuangyuan/agy-ubuntu
#
# 目标格式: <ssh别名|user@host>:<该主机 agy-ubuntu 仓库绝对路径>
#   默认目标里的路径请按各主机实际仓库位置核对,不存在会自动跳过。
#==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC="${REPO_DIR}/mihomo-conf/proxies-static.yaml"
CONTAINER="agy-ubuntu-container"

# 默认目标: 主机别名:仓库绝对路径(按需增删/核对)
DEFAULT_TARGETS=(
    "aja-pc:/home/beye/workspace/zhuangyuan/agy-ubuntu"
    "cwall:/home/cw/workspace/agy-ubuntu"
    "tc-coolie-claw:/home/ubuntu/workspace/agy-ubuntu"
)

DO_EXPORT=0
TARGETS=()
for arg in "$@"; do
    case "$arg" in
        --export)  DO_EXPORT=1 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        -*)        echo "未知参数: $arg" >&2; exit 2 ;;
        *)         TARGETS+=("$arg") ;;
    esac
done
[ "${#TARGETS[@]}" -eq 0 ] && TARGETS=("${DEFAULT_TARGETS[@]}")

if [ "$DO_EXPORT" -eq 1 ]; then
    echo "[sync] 先执行本机导出 (export-nodes-mac.sh) ..."
    bash "${REPO_DIR}/scripts/export-nodes-mac.sh" >/dev/null 2>&1 \
        || echo "[sync] ⚠️  导出脚本返回非零,继续使用现有文件" >&2
fi

[ -s "$STATIC" ] || { echo "❌ 节点文件不存在: $STATIC(请先跑 scripts/export-nodes-mac.sh)" >&2; exit 1; }
NODES="$(grep -cE 'server: ' "$STATIC" || true)"
echo "[sync] 源: ${STATIC} (${NODES} 节点, $(wc -c < "$STATIC" | tr -d ' ') bytes)"

rc=0
for t in "${TARGETS[@]}"; do
    host="${t%%:*}"; path="${t#*:}"
    echo "---------------------------------------------------------------------"
    echo "[sync] → ${host}:${path}"

    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "test -d '${path}/mihomo-conf'" 2>/dev/null; then
        echo "  ⏭  跳过: SSH 不通或远程路径不存在 (${path}/mihomo-conf)"
        rc=1; continue
    fi

    # 1) 备份 + 就地写入(truncate 保 inode)
    if ! base64 < "$STATIC" | ssh -o BatchMode=yes "$host" "
        f='${path}/mihomo-conf/proxies-static.yaml'
        cp -a \"\$f\" \"\$f.bak.\$(date +%Y%m%d%H%M)\" 2>/dev/null || true
        base64 -d > \"\$f\"
        echo \"  → 写入 \$(wc -c < \"\$f\" | tr -d ' ') bytes\"
    "; then
        echo "  ❌ 推送失败"; rc=1; continue
    fi

    # 2) 热重载容器内的 mihomo(仅当容器在跑)
    if ! ssh -o BatchMode=yes "$host" "docker ps --format '{{.Names}}' | grep -qx '${CONTAINER}'" 2>/dev/null; then
        echo "  ⚠️  容器 ${CONTAINER} 未运行,文件已就位(启动时自动生效)"
        continue
    fi

    ssh -o BatchMode=yes "$host" "docker exec -i '${CONTAINER}' bash -s" <<'REMOTE'
        for p in static local; do
            curl -s -o /dev/null -X PUT "http://127.0.0.1:9090/providers/proxies/$p" --max-time 8 || true
        done
        curl -s -o /dev/null -X PUT "http://127.0.0.1:9090/configs?force=true" \
            -H 'Content-Type: application/json' \
            -d '{"path":"/root/.config/mihomo/config.yaml"}' --max-time 10 || true
        for _ in 1 2 3; do curl -s --max-time 4 http://127.0.0.1:9090/proxies/PROXY-GEO | grep -q '"now"' && break; sleep 1; done
        echo -n "  → node: "; curl -s --max-time 4 http://127.0.0.1:9090/proxies/PROXY-GEO | sed -n 's/.*"now":"\([^"]*\)".*/\1/p'
        code=000
        for _ in 1 2 3 4 5; do
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://www.google.com/generate_204)
            [ "$code" = "204" ] && break; sleep 2
        done
        echo "  → google 204: ${code}"
REMOTE
    echo "  ✅ ${host} 完成"
done
echo "---------------------------------------------------------------------"
echo "[sync] 全部完成。"
exit $rc
