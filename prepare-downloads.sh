#!/usr/bin/env bash
#==============================================================================
# prepare-downloads.sh — 一次性下载离线构建所需的所有产物到 ./downloads/
#
#   1. mihomo  二进制(GitHub,需代理)
#   2. agy     CLI 二进制(Google,需代理)
#   3. apt 依赖包(通过 WSL Ubuntu 解析完整依赖闭包,阿里云镜像)
#   4. Node.js 22 LTS 二进制(自带 npm/npx)
#   5. pnpm standalone 二进制(Next.js 开发用)
#   --- E2E 镜像扩展(仅 Dockerfile.e2e 需要)---
#   6. JDK 17   Temurin 离线 tarball(Android emulator 运行时)
#   7. Android  commandlinetools + 离线 SDK 包(emulator + system-image)
#   8. agent-device SDK(npm pack + postinstall 完整解析树)
#   9. Playwright 浏览器(chromium + firefox + webkit)
#  10. Playwright 系统依赖 .deb(16 个 apt 包,offline 必备)
#
# 依赖:curl、gunzip、wsl(仅 apt 部分需要)、node + npm(8/9)、unzip(7)
# 代理:默认 http://127.0.0.1:7890(Clash),可用环境变量 PROXY 覆盖;留空则直连
#
# 用法:
#   bash prepare-downloads.sh                       # 走默认代理
#   PROXY= bash prepare-downloads.sh                # 直连(不代理)
#   MIHOMO_VERSION=v1.19.30 bash prepare-downloads.sh
#   NODE_VERSION=v22.23.2 bash prepare-downloads.sh # 指定 Node(默认自动取最新 v22)
#   JDK_VERSION=17.0.13 bash prepare-downloads.sh   # 指定 JDK 17 小版本
#   ANDROID_API=30 bash prepare-downloads.sh        # Android 系统镜像 API 级别
#   AGENT_DEVICE_VERSION=latest bash prepare-downloads.sh
#   PLAYWRIGHT_VERSION=1.49.0 bash prepare-downloads.sh
#   SKIP_E2E=1 bash prepare-downloads.sh            # 只下基础镜像产物
#==============================================================================
set -euo pipefail

# ---------- 可配置 ----------
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.30}"   # 需支持订阅中的 anytls 协议(≥ v1.19)
PROXY="${PROXY:-http://127.0.0.1:7890}"        # 留空 = 直连
WSL_DISTRO="${WSL_DISTRO:-Ubuntu-22.04}"       # 用于 apt 依赖解析的 WSL 发行版
AGY_MANIFEST="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json"
NODE_VERSION="${NODE_VERSION:-}"               # Node 完整版本(如 v22.23.2),留空自动取最新 v22
PNPM_VERSION="${PNPM_VERSION:-v11.25.0}"       # pnpm standalone 版本

# E2E 镜像扩展(默认全部下载;SKIP_E2E=1 时只下基础镜像)
SKIP_E2E="${SKIP_E2E:-0}"
JDK_VERSION="${JDK_VERSION:-17.0.13}"          # Temurin 17 小版本
ANDROID_API="${ANDROID_API:-30}"               # Android system-image API 级别
ANDROID_VARIANT="${ANDROID_VARIANT:-google_apis}" # google_apis(不含 Play Store)
AGENT_DEVICE_VERSION="${AGENT_DEVICE_VERSION:-latest}"  # npm 上 agent-device 版本
PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.49.0}"      # playwright npm 版本

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

if [ "$SKIP_E2E" = "1" ]; then
    echo ""
    echo "✅ 完成(SKIP_E2E=1,只下基础镜像产物)!downloads/ 已就绪。"
    exit 0
fi

#==============================================================================
# E2E 镜像扩展 —— 以下产物只供 Dockerfile.e2e 使用
#==============================================================================

# ---------- 6. JDK 17(Temurin Linux x64) ----------
echo "[6/10] JDK ${JDK_VERSION} (Temurin)"
JDK_DIR="$DL_DIR/jdk-${JDK_VERSION}"
if [ -x "$JDK_DIR/bin/java" ]; then
    echo "    已存在,跳过 ($(du -sh "$JDK_DIR" | cut -f1))"
else
    rm -rf "$JDK_DIR"
    mkdir -p "$JDK_DIR"
    # Adoptium 路径:https://github.com/adoptium/temurin17-binaries/releases
    JDK_URL="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-${JDK_VERSION}%2B10/OpenJDK17U-jdk_x64_linux_hotspot_${JDK_VERSION}_10.tar.gz"
    curldl "$JDK_URL" "$DL_DIR/jdk.tar.gz"
    tar -xzf "$DL_DIR/jdk.tar.gz" -C "$JDK_DIR" --strip-components=1
    rm -f "$DL_DIR/jdk.tar.gz"
    echo "    ✓ $(du -sh "$JDK_DIR" | cut -f1)"
fi

# ---------- 7. Android SDK(命令行工具 + 离线 SDK 包) ----------
echo "[7/10] Android SDK (API ${ANDROID_API} ${ANDROID_VARIANT} x86_64)"
ANDROID_SDK_DIR="$DL_DIR/android-sdk"
CMDLINE_TOOLS_VERSION="${CMDLINE_TOOLS_VERSION:-11076708}"  # latest

if [ -d "$ANDROID_SDK_DIR/emulator" ] && [ -d "$ANDROID_SDK_DIR/system-images" ]; then
    echo "    已存在,跳过 ($(du -sh "$ANDROID_SDK_DIR" | cut -f1))"
else
    # 7a) commandlinetools zip
    if [ ! -f "$DL_DIR/cmdline-tools.zip" ]; then
        curldl "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip" "$DL_DIR/cmdline-tools.zip"
    fi
    mkdir -p "$ANDROID_SDK_DIR/cmdline-tools"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$DL_DIR/cmdline-tools.zip" -d "$ANDROID_SDK_DIR/cmdline-tools/"
    else
        # fallback:Git Bash 的 tar 可解 zip?不行,需 unzip;给出明确错误
        echo "    ❌ 需要 unzip 命令(Git Bash 自带或 WSL Ubuntu)" >&2
        exit 1
    fi
    # 重命名 cmdline-tools/* → cmdline-tools/latest(sdkmanager 要求)
    if [ -d "$ANDROID_SDK_DIR/cmdline-tools/cmdline-tools" ]; then
        mv "$ANDROID_SDK_DIR/cmdline-tools/cmdline-tools" "$ANDROID_SDK_DIR/cmdline-tools/latest"
    fi

    # 7b) 用 sdkmanager 离线下载其他组件(走代理)
    export ANDROID_HOME="$ANDROID_SDK_DIR"
    export ANDROID_SDK_ROOT="$ANDROID_SDK_DIR"
    export PATH="$ANDROID_SDK_DIR/cmdline-tools/latest/bin:$ANDROID_SDK_DIR/platform-tools:$PATH"
    # 接受 license(无声模式)
    yes 2>/dev/null | sdkmanager --licenses >/dev/null 2>&1 || true

    echo "    安装 platform-tools / platforms / emulator / system-image..."
    sdkmanager ${PROXY:+--proxy=http} ${PROXY:+--proxy_host=127.0.0.1} ${PROXY:+--proxy_port=7890} \
        "platform-tools" \
        "platforms;android-${ANDROID_API}" \
        "emulator" \
        "system-images;android-${ANDROID_API};${ANDROID_VARIANT};x86_64"

    # 7c) 备份 licenses(供 Dockerfile.e2e COPY,免去运行时 sdkmanager --licenses)
    mkdir -p "$DL_DIR/android-sdk-licenses"
    if [ -d "$ANDROID_SDK_DIR/licenses" ]; then
        cp -r "$ANDROID_SDK_DIR/licenses/." "$DL_DIR/android-sdk-licenses/"
    fi

    echo "    ✓ $(du -sh "$ANDROID_SDK_DIR" | cut -f1)"
fi

# ---------- 8. agent-device SDK(npm pack + postinstall 完整解析树) ----------
echo "[8/10] agent-device ${AGENT_DEVICE_VERSION}"
if [ -s "$DL_DIR/agent-device.tgz" ]; then
    echo "    已存在,跳过 ($(du -h "$DL_DIR/agent-device.tgz" | cut -f1))"
else
    if ! command -v npm >/dev/null 2>&1; then
        echo "    ❌ 需要 npm 命令(先装 Node.js)" >&2
        exit 1
    fi
    STAGE_DIR="$(mktemp -d)"
    trap "rm -rf '$STAGE_DIR'" EXIT
    (cd "$STAGE_DIR" && \
        npm pack agent-device@${AGENT_DEVICE_VERSION} ${PROXY:+--proxy "$PROXY"} && \
        mkdir -p _pkg && tar -xzf agent-device-*.tgz -C _pkg && \
        cd _pkg && \
        npm install --omit=dev --no-audit --no-fund ${PROXY:+--proxy "$PROXY"} && \
        tar -czf "$DL_DIR/agent-device.tgz" -C node_modules .)
    echo "    ✓ $(du -h "$DL_DIR/agent-device.tgz" | cut -f1)"
fi

# ---------- 9. Playwright 浏览器(chromium + firefox + webkit) ----------
echo "[9/10] Playwright ${PLAYWRIGHT_VERSION} 浏览器"
PW_DIR="$DL_DIR/pw-browsers"
mkdir -p "$PW_DIR"
if [ -d "$PW_DIR/chromium-"* ] || [ -d "$PW_DIR/firefox-"* ] || [ -d "$PW_DIR/webkit-"* ]; then
    echo "    已存在,跳过 ($(du -sh "$PW_DIR" | cut -f1))"
else
    if ! command -v npm >/dev/null 2>&1; then
        echo "    ❌ 需要 npm 命令(先装 Node.js)" >&2
        exit 1
    fi
    STAGE_DIR="$(mktemp -d)"
    trap "rm -rf '$STAGE_DIR'" EXIT
    (cd "$STAGE_DIR" && \
        npm init -y >/dev/null && \
        npm install playwright@${PLAYWRIGHT_VERSION} --no-audit --no-fund ${PROXY:+--proxy "$PROXY"} >/dev/null && \
        PLAYWRIGHT_BROWSERS_PATH="$PW_DIR" npx playwright install chromium firefox webkit)
    echo "    ✓ $(du -sh "$PW_DIR" | cut -f1)"
fi

# ---------- 10. Playwright 系统依赖 .deb ----------
echo "[10/10] Playwright 系统依赖 .deb"
PW_DEBS="$DL_DIR/debs-playwright"
mkdir -p "$PW_DEBS"
PW_DEB_COUNT="$(ls "$PW_DEBS"/*.deb 2>/dev/null | wc -l | tr -d ' ')"
if [ "${PW_DEB_COUNT:-0}" -ge 15 ]; then
    echo "    已有 $PW_DEB_COUNT 个 .deb,跳过"
else
    if ! command -v wsl >/dev/null 2>&1; then
        echo "    ⚠ 未检测到 WSL,无法自动解析 apt 依赖;请手动准备 downloads/debs-playwright/" >&2
        exit 1
    fi
    wsl_pw_debs="$(echo "$PW_DEBS" | sed 's|^/\([a-zA-Z]\)|/mnt/\1|')"
    echo "    通过 WSL($WSL_DISTRO)+ 阿里云镜像解析 Playwright 系统依赖..."
    wsl -d "$WSL_DISTRO" -u root -- bash -c "
set -e
echo 'deb [trusted=yes] https://mirrors.aliyun.com/ubuntu noble main universe restricted multiverse' > /etc/apt/sources.list
echo 'deb [trusted=yes] https://mirrors.aliyun.com/ubuntu noble-updates main universe' >> /etc/apt/sources.list
echo 'deb [trusted=yes] https://mirrors.aliyun.com/ubuntu noble-security main universe' >> /etc/apt/sources.list
apt-get update >/dev/null
apt-get install --download-only -y --no-install-recommends \
    -o Dir::State::status=/dev/null -o Dir::State::extended_states=/dev/null \
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libdbus-1-3 libxkbcommon0 libatspi2.0-0 libx11-6 libxcomposite1 \
    libxdamage1 libxext6 libxfixes3 libxrandr2 libgbm1 \
    libpango-1.0-0 libcairo2 libasound2t64 >/dev/null
mkdir -p '$wsl_pw_debs'
cp -f /var/cache/apt/archives/*.deb '$wsl_pw_debs/' 2>/dev/null || true
# apt 不会重复下载已装的包,但目标系统是 noble,镜像用 noble,所以应该全装
echo '    共下载:' \$(ls '$wsl_pw_debs'/*.deb 2>/dev/null | wc -l) '个 .deb'
"
    echo "    ✓ $(ls "$PW_DEBS"/*.deb 2>/dev/null | wc -l) 个 .deb"
fi

echo ""
echo "✅ 完成!downloads/ 已就绪,可运行:"
echo "  docker compose up -d --build                         # 基础 agy-box"
echo "  docker compose -f docker-compose.e2e.yml up -d --build  # E2E agy-e2e"
