# 📥 Telegram 自动下载机器人 · 增强版 v3.1

> **完全优化、生产级 Telegram 下载机器人**

## ✨ 核心功能（V3.1 增强）

### 基础功能（V3.0 保留）
- ✅ 8 种媒体类型自动分类（图片、视频、音频、语音、文档、贴纸、动画、视频笔记）
- ✅ SQLite 持久化存储（重启不丢失）
- ✅ 文件浏览器（分页、搜索）
- ✅ 单文件/批量删除（二次确认）
- ✅ 文件回传（发回 Telegram）
- ✅ 按日期子目录归档
- ✅ 用户白名单
- ✅ 实时进度条（速度/剩余时间）
- ✅ 内联按钮菜单

### 【NEW】性能和稳定性优化
- ✨ **并发下载控制** - 防止资源溢出，设置下载并发数
- ✨ **智能重试机制** - 指数退避重试，最大可重试 3 次
- ✨ **断点续传支持** - 大文件支持断点续传（video/audio/document）
- ✨ **磁盘空间预检** - 下载前检查磁盘空间，防止写入失败
- ✨ **内存监控** - 实时监控内存/磁盘使用率，超限警告
- ✨ **日志轮转** - 日志自动轮转（10MB/个，保留 10 个）
- ✨ **数据库自动备份** - 每日自动备份，保留 7 天备份
- ✨ **过期文件清理** - 可配置自动清理超过 N 天的文件
- ✨ **文件完整性校验** - 计算文件 MD5 哈希值

### 【NEW】高级搜索
- 🔍 文件名模糊搜索
- 🔍 按文件大小范围过滤
- 🔍 按媒体类型过滤
- 🔍 搜索结果分页

---

## 🚀 快速开始

### 方式一：Docker Compose（推荐）

```bash
# 1. 克隆仓库
git clone https://github.com/javaliang2/tgdown.git
cd tgdown

# 2. 生成 .env 配置
bash gen-env.sh

# 3. 编辑 .env，填写 API_ID、API_HASH、BOT_TOKEN
nano .env

# 4. 启动容器
docker-compose up -d

# 5. 查看日志
docker-compose logs -f tg-downloader

# 6. 停止服务
docker-compose down
```

### 方式二：本地安装（支持所有平台）

```bash
# 1. 克隆仓库
git clone https://github.com/javaliang2/tgdown.git
cd tgdown

# 2. 运行安装脚本
chmod +x install.sh
./install.sh

# 3. 脚本会自动：
#    - 检测系统环境
#    - 安装 Python 依赖
#    - 交互式填写配置
#    - 启动 Bot
```

### 方式三：手动安装

```bash
# 1. 安装 Python 3.9+
python3 --version

# 2. 创建虚拟环境
python3 -m venv venv
source venv/bin/activate  # Linux/macOS
# 或
venv\\Scripts\\activate     # Windows

# 3. 安装依赖
pip install -r requirements-enhanced.txt

# 4. 配置文件
cp .env.example .env
# 编辑 .env，填写 Telegram API 凭据

# 5. 初始化数据库
python3 bot-enhanced.py
```

---

## 📋 配置说明

### 必填项

```bash
# Telegram API（从 https://my.telegram.org/apps 获取）
API_ID=123456789
API_HASH=a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6
BOT_TOKEN=1234567890:ABCdefGHIJKlmnoPQRstUVWXYZabcdef
```

### 性能配置（V3.1 新增）

```bash
# 并发下载数（1-5 推荐）
CONCURRENT_DOWNLOADS=3

# 下载失败重试次数（建议 3）
MAX_RETRIES=3

# 最小可用磁盘空间（MB，当低于此值时停止下载）
MIN_FREE_SPACE_MB=100

# 内存警告阈值（%，超过时显示警告）
MEMORY_WARN_PERCENT=80
```

### 维护配置（V3.1 新增）

```bash
# 数据库自动备份（保留天数）
DB_BACKUP_DAYS=1

# 自动清理过期文件（天数，0=禁用）
CLEANUP_OLD_FILES_DAYS=0

# 日志目录
LOG_DIR=./logs
```

---

## 🎮 使用方式

### Bot 命令

| 命令 | 说明 |
|------|------|
| `/start` | 显示欢迎菜单 |
| `/menu` | 主菜单 |
| `/status` | 下载统计 + 系统状态 |
| `/dirs` | 目录结构 |
| `/browse` | 浏览文件 |
| `/delete` | 删除文件 |
| `/search 关键词` | 搜索文件 |

---

## 📊 性能监控

### 查看日志

```bash
# 本地运行
tail -f logs/bot.log

# Docker 运行
docker-compose logs -f tg-downloader
```

### 数据库备份

```bash
# 备份自动保存在
ls -lh backups/

# 手动备份
cp tg_downloader.db backups/manual_backup_$(date +%Y%m%d_%H%M%S).db

# 恢复备份
cp backups/tg_downloader_YYYYMMDD.db tg_downloader.db
```

---

## 🔧 高级配置

### Supervisor 进程管理（生产环境推荐）

```bash
# 1. 安装 Supervisor
sudo apt-get install supervisor

# 2. 复制配置
sudo cp supervisord.conf /etc/supervisor/conf.d/tg-downloader.conf

# 3. 重加载
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start tg-downloader

# 4. 查看状态
sudo supervisorctl status tg-downloader
```

### Nginx 文件分享服务

```bash
# 启动 Nginx 文件服务器
docker-compose up -d file-server

# 访问下载的文件
http://localhost:8080/downloads/
```

---

## 🐛 故障排除

| 问题 | 解决方案 |
|------|----------|
| 无法连接 Telegram API | 检查网络、API_ID、API_HASH |
| 磁盘空间不足 | 手动清理或启用自动清理 |
| 内存占用过高 | 降低 CONCURRENT_DOWNLOADS |
| Bot 无响应 | 重启 Bot、检查日志 |

---

## 📈 版本历史

### v3.1 Enhanced（当前版本）
- ✨ 并发下载控制
- ✨ 智能重试机制
- ✨ 系统监控
- ✨ Docker 支持

### v3.0
- SQLite 持久化
- 文件搜索
- 文件回传

---

**祝你使用愉快！ 🎉**