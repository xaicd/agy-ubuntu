#!/usr/bin/env bash
#==============================================================================
# prepare-downloads.sh — 一次性下载离线构建所需的所有产物到 ./downloads/
#
#   1. mihomo  二进制(GitHub,需代理)
#   2. agy     CLI 二进制(Google,需代理)
#   3. apt 依赖包(通过 WSL Ubuntu 解析完整依赖闭包,阿里云镜像)
#   4. Node.js 22 LTS 二进制(自带 npm/npx)
#   5. pnpm standalone 二进制(Next.js 开发用)
#
# 依赖:curl、gunzip、wsl(仅 apt 部分需要)
# 代理:默认 http://127.0.0.1:7890(Clash),可用环境变量 PROXY 覆盖;留空则直连
#
# 用法:
#   bash prepare-downloads.sh                       # 走默认代理
#   PROXY= bash prepare-downloads.sh                # 直连(不代理)
#   MIHOMO_VERSION=v1.19.30 bash prepare-downloads.sh
#   NODE_VERSION=v22.23.2 bash prepare-downloads.sh # 指定 Node(默认自动取最新 v22)
#==============================================================================
set -euo pipefail

# ---------- 可配置 ----------
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.30}"   # 需支持订阅中的 anytls 协议(≥ v1.19)
PROXY="${PROXY:-http://127.0.0.1:7890}"        # 留空 = 直连
WSL_DISTRO="${WSL_DISTRO:-Ubuntu-22.04}"       # 用于 apt 依赖解析的 WSL 发行版
AGY_MANIFEST="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json"
NODE_VERSION="${NODE_VERSION:-}"               # Node 完整版本(如 v22.23.2),留空自动取最新 v22
PNPM_VERSION="${PNPM_VERSION:-v11.25.0}"       # pnpm standalone 版本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DL_DIR="$SCRIPT_DIR/downloads"
mkdir -p "$DL_DIR/debs"

# ---------- 工具函数 ----------
curldl() {  # $1=url  $2=输出文件(带重试)
    local url="$1" out="$2" px=()
    [ -n "$PROXY" ] && px=(-x "$PROXY")
    echo "    下载: $url"
    curl -fsSL --retry 8 --retry-all-errors --retry-delay 2 "${px[@]}" -o "$out" "$url"
}

# ---------- 1. mihomo ----------
echo "[1/5] mihomo ${MIHOMO_VERSION}"
if [ -s "$DL_DIR/mihomo" ]; then
    echo "    已存在,跳过 ($(du -h "$DL_DIR/mihomo" | cut -f1))"
else
    curldl "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-amd64-${MIHOMO_VERSION}.gz" "$DL_DIR/mihomo.gz"
    gunzip -c "$DL_DIR/mihomo.gz" > "$DL_DIR/mihomo"
    chmod +x "$DL_DIR/mihomo"
    rm -f "$DL_DIR/mihomo.gz"
    echo "    ✓ $(du -h "$DL_DIR/mihomo" | cut -f1)"
fi

# ---------- 2. agy ----------
echo "[2/5] agy CLI"
if [ -s "$DL_DIR/agy.tar.gz" ]; then
    echo "    已存在,跳过 ($(du -h "$DL_DIR/agy.tar.gz" | cut -f1))"
else
    manifest_json="$(curl -fsSL ${PROXY:+-x "$PROXY"} "$AGY_MANIFEST")"
    agy_url="$(echo "$manifest_json" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    agy_sha="$(echo "$manifest_json" | sed -n 's/.*"sha512"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$agy_url" ] || { echo "    ❌ 解析 manifest 失败" >&2; exit 1; }
    curldl "$agy_url" "$DL_DIR/agy.tar.gz"
    if command -v sha512sum >/dev/null 2>&1; then
        actual="$(sha512sum "$DL_DIR/agy.tar.gz" | cut -d' ' -f1)"
        [ "$actual" = "$agy_sha" ] || { echo "    ❌ agy sha512 校验失败!" >&2; exit 1; }
        echo "    ✓ $(du -h "$DL_DIR/agy.tar.gz" | cut -f1) (sha512 校验通过)"
    else
        echo "    ✓ $(du -h "$DL_DIR/agy.tar.gz" | cut -f1) (未校验 sha512,缺少 sha512sum)"
    fi
fi

# ---------- 3. apt debs ----------
echo "[3/5] apt 依赖包(ca-certificates/curl/git/iproute2/iptables/nano/tzdata/xdg-utils/libatomic1)"
DEB_COUNT="$(ls "$DL_DIR/debs"/*.deb 2>/dev/null | wc -l | tr -d ' ')"
if [ "${DEB_COUNT:-0}" -ge 50 ] && ls "$DL_DIR/debs"/libatomic1_*.deb >/dev/null 2>&1; then
    echo "    已有 $DEB_COUNT 个 .deb(含 libatomic1),跳过"
else
    if ! command -v wsl >/dev/null 2>&1; then
        echo "    ⚠ 未检测到 WSL,无法自动解析 apt 依赖;请手动准备 downloads/debs/ 目录" >&2
        exit 1
    fi
    # Git Bash 路径 -> WSL 挂载路径(/d/... -> /mnt/d/...)
    wsl_dl_dir="$(echo "$DL_DIR" | sed 's|^/\([a-zA-Z]\)|/mnt/\1|')"
    echo "    通过 WSL($WSL_DISTRO)+ 阿里云镜像解析依赖..."
    wsl -d "$WSL_DISTRO" -u root -- bash -c "
set -e
echo 'deb [trusted=yes] https://mirrors.aliyun.com/ubuntu noble main universe restricted multiverse' > /etc/apt/sources.list
echo 'deb [trusted=yes] https://mirrors.aliyun.com/ubuntu noble-updates main universe' >> /etc/apt/sources.list
echo 'deb [trusted=yes] https://mirrors.aliyun.com/ubuntu noble-security main universe' >> /etc/apt/sources.list
apt-get update >/dev/null
apt-get install --download-only -y --no-install-recommends -o Dir::State::status=/dev/null -o Dir::State::extended_states=/dev/null ca-certificates curl git iproute2 iptables nano tzdata xdg-utils libatomic1 >/dev/null
mkdir -p '$wsl_dl_dir/debs'
cp -f /var/cache/apt/archives/*.deb '$wsl_dl_dir/debs/'
"
    echo "    ✓ $(ls "$DL_DIR/debs"/*.deb 2>/dev/null | wc -l) 个 .deb"
fi

# ---------- 4. Node.js 22 LTS(自带 npm/npx) ----------
echo "[4/5] Node.js 22 LTS"
if [ -s "$DL_DIR/node.tar.gz" ]; then
    echo "    已存在,跳过 ($(du -h "$DL_DIR/node.tar.gz" | cut -f1))"
else
    if [ -z "$NODE_VERSION" ]; then
        # index.json 按发布倒序排列,取第一个 v22.* 即最新 LTS
        curl -fsSL ${PROXY:+-x "$PROXY"} https://nodejs.org/dist/index.json -o "$DL_DIR/node-index.json"
        NODE_VERSION="$(grep -m1 -o '"version":"v22\.[0-9.]*"' "$DL_DIR/node-index.json" | sed 's/.*"\(v[0-9.]*\)"/\1/')"
        rm -f "$DL_DIR/node-index.json"
        [ -n "$NODE_VERSION" ] || { echo "    ❌ 解析 Node 版本失败" >&2; exit 1; }
    fi
    echo "    使用 Node ${NODE_VERSION}"
    curldl "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.gz" "$DL_DIR/node.tar.gz"
    echo "    ✓ $(du -h "$DL_DIR/node.tar.gz" | cut -f1)"
fi

# ---------- 5. pnpm standalone ----------
echo "[5/5] pnpm ${PNPM_VERSION}"
if [ -s "$DL_DIR/pnpm.tar.gz" ]; then
    echo "    已存在,跳过 ($(du -h "$DL_DIR/pnpm.tar.gz" | cut -f1))"
else
    curldl "https://github.com/pnpm/pnpm/releases/download/${PNPM_VERSION}/pnpm-linux-x64.tar.gz" "$DL_DIR/pnpm.tar.gz"
    echo "    ✓ $(du -h "$DL_DIR/pnpm.tar.gz" | cut -f1)"
fi

echo ""
echo "✅ 完成!downloads/ 已就绪,可运行: docker compose up -d --build"
