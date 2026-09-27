# Docker 部署

本目录提供 `Dockerfile` 和 `docker-compose.yml`，一键打包运行 Deen 音乐下载器。

## 镜像大小

- 解压后约 **~280 MB**
- 压缩后约 **~115 MB**
- 其中三个内置 API 二进制（ncm / qqmusic / kugou）约占 141 MB

## 国内镜像源（默认）

为加速国内构建，`Dockerfile` 默认把 apt 和 pip 源替换为：

| 类型 | 默认源 | 说明 |
|------|--------|------|
| apt | `mirrors.aliyun.com` | Debian 完整镜像，安全/CVE 覆盖一致 |
| pip | `https://mirrors.aliyun.com/pypi/simple` | 阿里云 PyPI 镜像 |

海外用户构建时如需恢复官方源：

```bash
docker build \
  --build-arg APT_MIRROR=deb.debian.org \
  --build-arg PIP_INDEX_URL=https://pypi.org/simple \
  -t deen-music-downloader:latest .

# compose：编辑 docker-compose.yml 中的 build.args 段（已提供注释示例）
```

## 快速开始

```bash
# 构建并后台启动
docker compose up -d --build

# 查看日志
docker compose logs -f

# 浏览器访问 http://<宿主机IP>:45600
# 默认账号/密码：admin / admin123（首次登录后请立即修改）
```

## 数据持久化

| 挂载点 | 用途 | 类型 |
|--------|------|------|
| `/data` | SQLite（账号/歌单/任务/设置）+ 日志 + ncm-api 临时缓存 | 命名卷 `deen-data` |
| `/downloads` | 下载的音乐文件 | 命名卷 `deen-downloads` |

如需把下载目录落到宿主机可见位置，编辑 `docker-compose.yml`：

```yaml
volumes:
  - deen-data:/data
  - /mnt/nas/music:/downloads   # 改成宿主机绝对路径
```

## 常用命令

```bash
docker compose ps              # 查看容器状态
docker compose restart         # 重启
docker compose pull && docker compose up -d   # 升级镜像
docker compose down            # 停止并删除容器（保留数据卷）
docker compose down -v         # 停止并删除容器 + 数据卷（**会清空所有数据**）
```

## 修改配置

大部分配置（端口、定时同步、音质、下载路径等）通过 Web UI 修改即可，无需重启容器。
**例外**：`web_port`（监听地址）修改后需要重启：

```bash
docker compose restart
```

## 直接使用 docker（不通过 compose）

```bash
# 构建
docker build -t deen-music-downloader:latest .

# 运行
docker run -d --name deen \
  -p 45600:45600 \
  -v deen-data:/data \
  -v deen-downloads:/downloads \
  -e TZ=Asia/Shanghai \
  --restart unless-stopped \
  deen-music-downloader:latest
```

## 镜像内架构

```
debian:bookworm-slim  (75 MB)
├── /usr/local        ← Python 3.11 工具链（从 builder 复制，~30 MB）
├── /opt/venv         ← pip 依赖：Flask + SQLAlchemy + APScheduler + requests + mutagen (~30 MB)
├── /usr/bin/tini     ← PID 1，信号转发 + 僵尸回收
├── /usr/bin/{useradd,groupadd} (shadow)
├── /app/api/         ← 三个 API 二进制（ncm / qqmusic / kugou，141 MB）
├── /app/core/        ← 下载器核心
├── /app/webapp/      ← Flask Web
├── /data             ← 持久化数据卷（SQLite + 日志）
└── /downloads        ← 下载卷
```

以 `deen`（UID/GID 1000）非 root 用户运行。