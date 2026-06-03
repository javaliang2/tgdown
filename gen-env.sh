#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  Telegram 下载机器人 · 配置模板生成脚本
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# ── 如果 .env 已存在，备份后退出 ──
if [[ -f "$ENV_FILE" ]]; then
    BACKUP_FILE="${ENV_FILE}.example.$(date +%Y%m%d%H%M%S)"
    cp "$ENV_FILE" "$BACKUP_FILE"
    echo "⚠️  .env 已存在，已备份为 $BACKUP_FILE"
    exit 0
fi

# ── 生成 .env 模板 ──
cat > "$ENV_FILE" << 'EOF'
# ═══════════════════════════════════════════════════════════════
#  Telegram 自动下载机器人 · 配置文件 v3.1 Enhanced
# ═══════════════════════════════════════════════════════════════

# ── Telegram API 凭据（必填）────────────────────────────────
# 获取地址：https://my.telegram.org/apps（登录后创建 App）
API_ID=YOUR_API_ID
API_HASH=YOUR_API_HASH

# ── Bot Token（必填）──────────────────────────────────────
# 获取方式：在 Telegram 找 @BotFather → /newbot
BOT_TOKEN=YOUR_BOT_TOKEN

# ── 下载配置────────────────────────────────────────────────
# 下载文件保存的根目录
DOWNLOAD_ROOT=./downloads

# 是否按日期（YYYY-MM-DD）子目录归档
ORGANIZE_BY_DATE=true

# 日志目录
LOG_DIR=./logs

# ── 用户白名单────────────────────────────────────────────────
# 留空 = 所有人可用；多个 ID 用逗号分隔
# 获取自己的 user_id：在 Telegram 找 @userinfobot 发任意消息
ALLOWED_USERS=

# ── 进度显示────────────────────────────────────────────────
# 下载进度更新间隔（秒）
PROGRESS_UPDATE_SEC=2.0

# ── 分页配置────────────────────────────────────────────────
# 浏览文件时每页显示的条数
PAGE_SIZE=8

# ── 数据库配置──────────────────────────────────────────────
# SQLite 数据库路径
DB_PATH=./tg_downloader.db

# ════════════════════════════════════════════════════════════
#  【NEW】性能优化配置
# ════════════════════════════════════════════════════════════

# 【NEW】并发下载数（同时下载的最大文件数）
# 设置太高会导致内存占用过大；建议 1-5
CONCURRENT_DOWNLOADS=3

# 【NEW】单个下载超时时间（秒）
DOWNLOAD_TIMEOUT_SEC=3600

# 【NEW】下载失败最大重试次数
# 使用指数退避（2^n 秒）重试间隔
MAX_RETRIES=3

# 【NEW】重试退避基数
# 重试间隔 = RETRY_BACKOFF_BASE ^ 重试次数
RETRY_BACKOFF_BASE=2.0

# 【NEW】最小可用磁盘空间（MB）
# 低于此值时停止下载
MIN_FREE_SPACE_MB=100

# 【NEW】内存使用率警告阈值（%）
# 超过此值时在菜单中显示警告
MEMORY_WARN_PERCENT=80

# 【NEW】数据库备份保留天数（0=禁用）
# 自动备份数据库，保留 N*7 天的备份
DB_BACKUP_DAYS=1

# 【NEW】自动清理过期文件（天数，0=禁用）
# 删除超过 N 天未修改的下载文件
CLEANUP_OLD_FILES_DAYS=0

# ════════════════════════════════════════════════════════════
#  注意事项
# ════════════════════════════════════════════════════════════
# • 生产环境建议：CONCURRENT_DOWNLOADS=2, MAX_RETRIES=3
# • 请定期备份数据库：backups/tg_downloader_*.db
# • 超大文件下载可能需要调整：DOWNLOAD_TIMEOUT_SEC
# • 日志文件存放在 LOG_DIR，自动轮转（max 10MB，保留 10 个）
EOF

chmod 600 "$ENV_FILE"
echo "✅ .env 模板已生成：$ENV_FILE"
echo "⚠️  请编辑文件，填写 API_ID、API_HASH、BOT_TOKEN"
