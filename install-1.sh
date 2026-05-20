#!/usr/bin/env bash
# =============================================================
#  Telegram 自动下载机器人 · 一键安装脚本
#  支持：Ubuntu / Debian / CentOS / RHEL / Arch / macOS
# =============================================================
set -euo pipefail

# ── 颜色 & 符号 ───────────────────────────────────────────────
R='\033[0;31m'  G='\033[0;32m'  Y='\033[0;33m'
B='\033[0;34m'  C='\033[0;36m'  W='\033[1;37m'  N='\033[0m'
BOLD='\033[1m'

ok()   { echo -e "${G}  ✔  ${N}$*"; }
info() { echo -e "${B}  ℹ  ${N}$*"; }
warn() { echo -e "${Y}  ⚠  ${N}$*"; }
err()  { echo -e "${R}  ✘  ${N}$*" >&2; }
die()  { err "$*"; exit 1; }
sep()  { echo -e "${B}──────────────────────────────────────────────────${N}"; }

# ── 横幅 ─────────────────────────────────────────────────────
clear
echo -e "${C}${BOLD}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════╗
  ║   Telegram 自动下载机器人  ·  一键安装程序        ║
  ║   Pyrogram · MTProto · 无文件大小限制             ║
  ╚══════════════════════════════════════════════════╝
BANNER
echo -e "${N}"
sep

# ── 脚本位置 & 安装目录 ───────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════
#  STEP 1 · 环境自检
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[1/5] 环境自检${N}"
sep

# 检测 OS
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macos"
  elif [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    case "$ID" in
      ubuntu|debian|linuxmint|pop) echo "debian" ;;
      centos|rhel|fedora|rocky|almalinux) echo "redhat" ;;
      arch|manjaro|endeavouros) echo "arch" ;;
      *) echo "unknown" ;;
    esac
  else
    echo "unknown"
  fi
}

OS=$(detect_os)
info "操作系统：$(uname -s) / 发行版：$OS"

# 检查是否 root（Linux 安装系统包可能需要）
IS_ROOT=false
[[ $EUID -eq 0 ]] && IS_ROOT=true
$IS_ROOT && info "以 root 身份运行" || info "以普通用户运行（sudo 将按需调用）"

# sudo 助手
SUDO=""
if ! $IS_ROOT && command -v sudo &>/dev/null; then
  SUDO="sudo"
fi

# 检测 Python 3.9+
check_python() {
  local py=""
  for cmd in python3.12 python3.11 python3.10 python3.9 python3 python; do
    if command -v "$cmd" &>/dev/null; then
      local ver
      ver=$("$cmd" -c "import sys; print(sys.version_info[:2])" 2>/dev/null || true)
      if [[ "$ver" > "(3, 8)" ]]; then   # 字典序比较足够用
        py="$cmd"
        break
      fi
    fi
  done
  echo "$py"
}

PYTHON=$(check_python)

if [[ -z "$PYTHON" ]]; then
  warn "未找到 Python 3.9+，将尝试自动安装..."

  case "$OS" in
    debian)
      $SUDO apt-get update -qq
      $SUDO apt-get install -y python3 python3-venv python3-pip
      ;;
    redhat)
      if command -v dnf &>/dev/null; then
        $SUDO dnf install -y python3 python3-pip
      else
        $SUDO yum install -y python3 python3-pip
      fi
      ;;
    arch)
      $SUDO pacman -Sy --noconfirm python python-pip
      ;;
    macos)
      if command -v brew &>/dev/null; then
        brew install python3
      else
        die "请先安装 Homebrew（https://brew.sh）或手动安装 Python 3.9+"
      fi
      ;;
    *)
      die "无法自动安装 Python，请手动安装 Python 3.9+ 后重试"
      ;;
  esac

  PYTHON=$(check_python)
  [[ -z "$PYTHON" ]] && die "Python 安装失败，请手动处理"
fi

PY_VER=$("$PYTHON" -c "import sys; v=sys.version_info; print(f'{v.major}.{v.minor}.{v.micro}')")
ok "Python $PY_VER  ($PYTHON)"

# 检测 pip
if ! "$PYTHON" -m pip --version &>/dev/null; then
  warn "pip 未找到，尝试安装..."
  case "$OS" in
    debian) $SUDO apt-get install -y python3-pip ;;
    redhat) $SUDO yum install -y python3-pip 2>/dev/null || $SUDO dnf install -y python3-pip ;;
    arch)   $SUDO pacman -Sy --noconfirm python-pip ;;
    macos)  "$PYTHON" -m ensurepip --upgrade ;;
    *)      die "请手动安装 pip" ;;
  esac
fi
ok "pip 可用"

# 检测 venv 模块
if ! "$PYTHON" -m venv --help &>/dev/null 2>&1; then
  warn "python3-venv 缺失，尝试安装..."
  case "$OS" in
    debian) $SUDO apt-get install -y python3-venv ;;
    *) warn "请手动确认 venv 模块可用" ;;
  esac
fi
ok "venv 模块可用"

# 检测网络连通性（ping Telegram）
if curl -sf --max-time 5 https://api.telegram.org > /dev/null 2>&1; then
  ok "网络连通（Telegram 可达）"
else
  warn "无法访问 api.telegram.org，请检查网络 / 代理设置"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 2 · 创建虚拟环境 & 安装依赖
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[2/5] 安装 Python 依赖${N}"
sep

VENV_DIR="$INSTALL_DIR/venv"

if [[ -d "$VENV_DIR" ]]; then
  info "已存在虚拟环境，跳过创建"
else
  info "创建虚拟环境 → $VENV_DIR"
  "$PYTHON" -m venv "$VENV_DIR"
  ok "虚拟环境创建成功"
fi

# 激活 venv
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

info "升级 pip..."
"$VENV_PIP" install --upgrade pip -q

REQUIREMENTS="$INSTALL_DIR/requirements.txt"
if [[ ! -f "$REQUIREMENTS" ]]; then
  # 兜底：直接写入
  cat > "$REQUIREMENTS" << 'REQ'
pyrogram==2.0.106
TgCrypto==1.2.5
python-dotenv==1.0.1
REQ
fi

info "安装依赖包（首次可能需要 1-2 分钟）..."
"$VENV_PIP" install -r "$REQUIREMENTS" -q \
  --no-warn-script-location 2>&1 \
  | grep -E "^(Successfully|ERROR|error)" || true

# 验证关键包
for pkg in pyrogram dotenv; do
  if "$VENV_PYTHON" -c "import $pkg" 2>/dev/null; then
    ok "import $pkg"
  else
    die "包 $pkg 安装失败，请检查网络或手动运行: $VENV_PIP install -r requirements.txt"
  fi
done

# ═══════════════════════════════════════════════════════════════
#  STEP 3 · 交互式信息采集
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[3/5] 填写配置信息${N}"
sep
echo -e "${Y}  所有信息仅写入本地 .env 文件，不会上传到任何地方${N}\n"

# 辅助：读取非空输入
prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local secret="${3:-false}"
  local value=""
  while [[ -z "$value" ]]; do
    if $secret; then
      read -rsp "  ${C}${prompt_text}${N}: " value
      echo
    else
      read -rp "  ${C}${prompt_text}${N}: " value
    fi
    value="${value// /}"   # 去除空格
    [[ -z "$value" ]] && err "此项不能为空，请重新输入"
  done
  printf -v "$var_name" '%s' "$value"
}

# 辅助：读取可选输入（有默认值）
prompt_optional() {
  local var_name="$1"
  local prompt_text="$2"
  local default="$3"
  local value=""
  read -rp "  ${C}${prompt_text}${N} [${Y}${default}${N}]: " value
  value="${value// /}"
  [[ -z "$value" ]] && value="$default"
  printf -v "$var_name" '%s' "$value"
}

# ── 3a. API_ID ────────────────────────────────────────────────
echo -e "  ${W}▸ Telegram API 凭据${N}"
echo -e "  获取地址：${B}https://my.telegram.org/apps${N}  （登录后创建 App）\n"

while true; do
  prompt_required API_ID "API_ID（纯数字，例如 12345678）"
  if [[ "$API_ID" =~ ^[0-9]+$ ]]; then
    break
  else
    err "API_ID 必须是纯数字"
  fi
done
ok "API_ID = $API_ID"

# ── 3b. API_HASH ──────────────────────────────────────────────
while true; do
  prompt_required API_HASH "API_HASH（32位十六进制字符串）"
  if [[ "${#API_HASH}" -eq 32 && "$API_HASH" =~ ^[0-9a-fA-F]+$ ]]; then
    break
  else
    err "API_HASH 应为 32 位十六进制字符串，请重新输入"
  fi
done
ok "API_HASH = ${API_HASH:0:6}••••••••••••••••••••••••••"

# ── 3c. BOT_TOKEN ─────────────────────────────────────────────
echo -e "\n  ${W}▸ Bot Token${N}"
echo -e "  获取方式：在 Telegram 找 ${B}@BotFather${N} → /newbot\n"

while true; do
  prompt_required BOT_TOKEN "BOT_TOKEN（格式：数字:字母数字串）" true
  if [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
    break
  else
    err "Token 格式不正确（应为 123456:ABC...），请重新输入"
  fi
done
ok "BOT_TOKEN = ${BOT_TOKEN%%:*}:••••••••••••"

# ── 3d. 下载目录 ──────────────────────────────────────────────
echo -e "\n  ${W}▸ 下载目录配置${N}\n"
prompt_optional DOWNLOAD_ROOT "下载根目录" "$INSTALL_DIR/downloads"
ok "下载目录 = $DOWNLOAD_ROOT"

# ── 3e. 日期子目录 ────────────────────────────────────────────
prompt_optional ORGANIZE_BY_DATE "按日期子目录归档（true/false）" "true"
[[ "$ORGANIZE_BY_DATE" != "false" ]] && ORGANIZE_BY_DATE="true"
ok "按日期归档 = $ORGANIZE_BY_DATE"

# ── 3f. 进度刷新间隔 ──────────────────────────────────────────
prompt_optional PROGRESS_UPDATE_SEC "进度消息刷新间隔（秒）" "2.0"
ok "进度刷新间隔 = ${PROGRESS_UPDATE_SEC}s"

# ── 3g. 白名单 ────────────────────────────────────────────────
echo -e "\n  ${W}▸ 用户白名单${N}"
echo -e "  ${Y}留空 = 所有人均可使用；多个 ID 用逗号分隔${N}"
echo -e "  获取自己的 user_id：在 Telegram 找 ${B}@userinfobot${N} 发任意消息\n"
read -rp "  ${C}ALLOWED_USERS${N}（可留空）: " ALLOWED_USERS
ALLOWED_USERS="${ALLOWED_USERS// /}"

if [[ -z "$ALLOWED_USERS" ]]; then
  warn "白名单为空，所有人均可使用此 Bot"
else
  ok "白名单 = $ALLOWED_USERS"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 4 · 写入 .env 文件
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[4/5] 写入配置文件${N}"
sep

ENV_FILE="$INSTALL_DIR/.env"

# 备份已有的 .env
if [[ -f "$ENV_FILE" ]]; then
  cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  info "已备份旧 .env"
fi

cat > "$ENV_FILE" << EOF
# Telegram 自动下载机器人配置
# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')
# !! 请勿将此文件提交到 Git !!

# ── 必填 ──────────────────────────────
API_ID=${API_ID}
API_HASH=${API_HASH}
BOT_TOKEN=${BOT_TOKEN}

# ── 下载目录 ──────────────────────────
DOWNLOAD_ROOT=${DOWNLOAD_ROOT}

# ── 行为配置 ──────────────────────────
ORGANIZE_BY_DATE=${ORGANIZE_BY_DATE}
PROGRESS_UPDATE_SEC=${PROGRESS_UPDATE_SEC}

# ── 白名单（逗号分隔 user_id，空=所有人）
ALLOWED_USERS=${ALLOWED_USERS}
EOF

# 限制权限（仅 owner 可读）
chmod 600 "$ENV_FILE"
ok ".env 已写入 → $ENV_FILE（权限 600）"

# ── 创建下载目录 ──────────────────────
mkdir -p "$DOWNLOAD_ROOT"
ok "下载目录已创建 → $DOWNLOAD_ROOT"

# ─── 写入 systemd 服务（Linux only）─────────────────────────
if [[ "$OS" != "macos" && "$OS" != "unknown" ]]; then
  SERVICE_FILE="$INSTALL_DIR/tg-downloader.service"
  cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Telegram Auto Downloader Bot (Pyrogram)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV_DIR}/bin/python ${INSTALL_DIR}/bot.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
EnvironmentFile=${ENV_FILE}

[Install]
WantedBy=multi-user.target
EOF
  ok "systemd 服务文件已更新 → $SERVICE_FILE"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 5 · 启动确认
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[5/5] 启动机器人${N}"
sep

echo -e "\n  ${G}${BOLD}✅ 安装完成！${N}\n"
echo -e "  ${W}选择启动方式：${N}"
echo -e "  ${C}1${N}  立即在前台运行（调试用，Ctrl+C 退出）"
echo -e "  ${C}2${N}  后台运行（nohup，日志写入 bot.log）"
if [[ "$OS" != "macos" && "$OS" != "unknown" ]]; then
  echo -e "  ${C}3${N}  注册为 systemd 服务（推荐生产环境）"
fi
echo -e "  ${C}q${N}  不启动，稍后手动运行\n"

read -rp "  请选择 [1/2/3/q]: " LAUNCH_CHOICE

case "$LAUNCH_CHOICE" in
  1)
    echo -e "\n${G}  启动中... 按 Ctrl+C 停止${N}\n"
    cd "$INSTALL_DIR"
    exec "$VENV_PYTHON" bot.py
    ;;
  2)
    cd "$INSTALL_DIR"
    nohup "$VENV_PYTHON" bot.py > bot.log 2>&1 &
    BOT_PID=$!
    sleep 2
    if kill -0 "$BOT_PID" 2>/dev/null; then
      ok "Bot 已在后台运行，PID=$BOT_PID"
      info "查看日志：tail -f $INSTALL_DIR/bot.log"
      info "停止 Bot：kill $BOT_PID"
    else
      err "Bot 启动失败，请查看日志：cat $INSTALL_DIR/bot.log"
    fi
    ;;
  3)
    if [[ "$OS" == "macos" || "$OS" == "unknown" ]]; then
      warn "当前系统不支持 systemd，请选择其他方式"
    else
      SERVICE_SRC="$INSTALL_DIR/tg-downloader.service"
      SERVICE_DST="/etc/systemd/system/tg-downloader.service"
      $SUDO cp "$SERVICE_SRC" "$SERVICE_DST"
      $SUDO systemctl daemon-reload
      $SUDO systemctl enable tg-downloader
      $SUDO systemctl restart tg-downloader
      sleep 2
      if $SUDO systemctl is-active --quiet tg-downloader; then
        ok "systemd 服务已启动并设为开机自启"
        info "查看状态：sudo systemctl status tg-downloader"
        info "查看日志：journalctl -u tg-downloader -f"
        info "停止服务：sudo systemctl stop tg-downloader"
      else
        err "服务启动失败"
        $SUDO journalctl -u tg-downloader -n 20 --no-pager || true
      fi
    fi
    ;;
  q|Q|*)
    echo
    info "稍后可手动启动："
    echo -e "  ${C}cd ${INSTALL_DIR}${N}"
    echo -e "  ${C}source venv/bin/activate${N}"
    echo -e "  ${C}python bot.py${N}"
    ;;
esac

sep
echo -e "\n  ${W}Bot 命令：${N}"
echo -e "  /start  — 帮助  /status — 下载统计  /dirs — 目录结构\n"
echo -e "  ${G}享受你的 Telegram 自动下载机器人！🎉${N}\n"
