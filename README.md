# agy-ubuntu

Ubuntu 24.04 沙盒开发容器:内嵌 **Mihomo (Clash Meta) TUN** 全流量隔离 + 预装 **Google Antigravity CLI (`agy`)**。

- 100% 内部流量经 `clash0` TUN 虚拟网卡走代理
- 完全隔离于宿主机网络(默认 bridge,非 `--network host`)
- DNS 劫持(`resolv.conf → 127.0.0.1 → mihomo`)
- 预装 **Node.js 22 LTS**(npm/npx)+ **pnpm**,可直接开发 Next.js

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
- `downloads/node.tar.gz` — Node.js 22 LTS Linux x64(自带 npm/npx)
- `downloads/pnpm.tar.gz` — pnpm standalone 单文件可执行
- `downloads/debs/*.deb` — 基础工具的完整依赖闭包(98 个,通过 WSL Ubuntu 解析)

### 订阅(base64)

订阅通常是 **base64 编码的 URI 列表**(非 YAML),entrypoint 用 mihomo 的 `proxy-providers` 自动拉取解码,无需手动处理。

### 节点与地域

Gemini / Google AI 对**香港、澳门、台湾、俄罗斯**等地区不提供支持,entrypoint 已用 `exclude-filter` 排除这些地区,url-test 自动在美/日/新/韩等支持地区选择最快节点。

## 版本标签与回滚

`latest` 标签每次构建都会被覆盖,无法回滚。为此提供 `build.sh`:本地构建时自动额外打一个**日期标签** `chw717/ai-agy:<YYYYMMDD>`,历史版本得以保留:

```bash
bash build.sh                       # 构建 + 打当天日期标签 + 启动
DATE_TAG=20260826 bash build.sh     # 指定日期(默认今天)
```

回滚到某天的镜像:

```bash
docker tag chw717/ai-agy:20260826 chw717/ai-agy:latest
docker compose up -d
```

查看所有历史版本:`docker images chw717/ai-agy`。旧镜像在未 `docker image prune` 前,也可按 image ID 找回。

## 环境依赖

- Docker Desktop(需 `/dev/net/tun` + `NET_ADMIN` capacity)
- 若容器出网大文件传输异常,需将 daemon `mtu` 调低(本机为 1400,见 `daemon.json`)
