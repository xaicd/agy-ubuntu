# agy-ubuntu

Ubuntu 24.04 沙盒开发容器:内嵌 **Mihomo (Clash Meta) TUN** 全流量隔离 + 预装 **Google Antigravity CLI (`agy`)**。

- 100% 内部流量经 `clash0` TUN 虚拟网卡走代理
- 完全隔离于宿主机网络(默认 bridge,非 `--network host`)
- DNS 劫持(`resolv.conf → 127.0.0.1 → mihomo`)

## 快速开始

```bash
# 1. 配置订阅(必填)
cp .env.example .env
# 编辑 .env,填入你的 mihomo 订阅链接(CLASH_URL)

# 2. 启动(自动拉取 Docker Hub 镜像 chw717/ai-agy:latest,无需本地构建)
docker compose up -d

# 3. 进入
docker attach agy-ubuntu-container
agy   # 登录并开始
```

## 共享 git / SSH

宿主机 `~/.gitconfig`(身份)与 `~/.ssh`(SSH 密钥)会自动挂载进容器,容器内可直接 `git commit` / `git push`:

- 身份沿用宿主机配置(user.name / user.email)
- GitHub HTTPS 远程自动重写为 SSH(走 `ssh.github.com:443`,无需 PAT)
- 密钥在容器内已修正权限(chmod 600)

## 构建说明

镜像已发布到 **Docker Hub**(`chw717/ai-agy:latest`),`docker compose up -d` 会自动拉取,**无需本地构建**。

只有需要本地重新构建时(`docker compose up -d --build`)才需要 `downloads/` 目录——镜像采用**离线构建**:`downloads/` 存放预下载产物(mihomo 二进制、agy 二进制、apt 的 .deb 包),构建过程不联网。`downloads/` 未纳入 git,克隆后一键准备:

```bash
bash prepare-downloads.sh        # 默认走 127.0.0.1:7890 代理
PROXY= bash prepare-downloads.sh # 直连(不代理)
```

脚本会下载:

- `downloads/mihomo` — mihomo v1.19.30+ Linux amd64(需支持订阅中的 `anytls` 协议)
- `downloads/agy.tar.gz` — agy CLI(内含 `antigravity` 二进制,自动校验 sha512)
- `downloads/debs/*.deb` — 基础工具的完整依赖闭包(77 个,通过 WSL Ubuntu 解析)

### 订阅(base64)

订阅通常是 **base64 编码的 URI 列表**(非 YAML),entrypoint 用 mihomo 的 `proxy-providers` 自动拉取解码,无需手动处理。

### 节点与地域

Gemini / Google AI 对**香港、澳门、台湾、俄罗斯**等地区不提供支持,entrypoint 已用 `exclude-filter` 排除这些地区,url-test 自动在美/日/新/韩等支持地区选择最快节点。

## 环境依赖

- Docker Desktop(需 `/dev/net/tun` + `NET_ADMIN` capacity)
- 若容器出网大文件传输异常,需将 daemon `mtu` 调低(本机为 1400,见 `daemon.json`)
