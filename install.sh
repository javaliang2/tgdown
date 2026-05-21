#!/usr/bin/env bash
# =============================================================
#  Telegram 自动下载机器人 · 一键安装脚本 (增强交互版)
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

if [[ ! -f "$SCRIPT_DIR/bot.py" ]]; then
  info "检测到远程执行，正在克隆仓库..."
  command -v git &>/dev/null || die "请先安装 git"
  git clone https://github.com/javaliang2/tgdown.git
  cd tgdown
  exec bash install.sh  
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 1 · 环境自检 (已修复: Python版本/curl缺失/venv检测)
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[1/5] 环境自检${N}"
sep

detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macos"
  elif [[ -f /etc/os-release ]]; then
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

IS_ROOT=false
[[ $EUID -eq 0 ]] && IS_ROOT=true
$IS_ROOT && info "以 root 身份运行" || info "以普通用户运行（sudo 将按需调用）"

SUDO=""
if ! $IS_ROOT && command -v sudo &>/dev/null; then
  SUDO="sudo"
fi

check_python() {
  local py=""
  for cmd in python3.12 python3.11 python3.10 python3.9 python3 python; do
    if command -v "$cmd" &>/dev/null; then
      local ver_tuple
      ver_tuple=$("$cmd" -c "import sys; print(sys.version_info[:2])" 2>/dev/null || true)
      if [[ -n "$ver_tuple" ]]; then
        local major minor
        major=$(echo "$ver_tuple" | grep -oP '\d+(?=,)' | head -1)
        minor=$(echo "$ver_tuple" | grep -oP '(?<=, )\d+' | tail -1)
        if [[ -n "$major" && -n "$minor" ]]; then
          if (( major > 3 || ( major == 3 && minor >= 9 ) )); then
            py="$cmd"
            break
          fi
        fi
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
      $SUDO apt-get install -y python3 python3-venv python3-pip || true
      ;;
    redhat)
      if command -v dnf &>/dev/null; then
        $SUDO dnf install -y python3 python3-pip || true
      else
        $SUDO yum install -y python3 python3-pip || true
      fi
      ;;
    arch)
      $SUDO pacman -Sy --noconfirm python python-pip || true
      ;;
    macos)
      if command -v brew &>/dev/null; then
        brew install python3 || true
      else
        die "请先安装 Homebrew（https://brew.sh）或手动安装 Python 3.9+"
      fi
      ;;
    *) die "无法自动安装 Python，请手动安装 Python 3.9+ 后重试" ;;
  esac

  PYTHON=$(check_python)
  if [[ -z "$PYTHON" ]]; then
    warn "自动安装后仍未找到 Python 3.9+"
    info "Debian/Ubuntu 用户可添加 deadsnakes PPA 安装高版本 Python："
    info "  sudo add-apt-repository ppa:deadsnakes/ppa"
    info "  sudo apt install python3.9  （或 python3.10 / 3.11 等）"
    die "请手动安装 Python 3.9+ 后重新运行本脚本"
  fi
fi

PY_VER=$("$PYTHON" -c "import sys; v=sys.version_info; print(f'{v.major}.{v.minor}.{v.micro}')")
ok "Python $PY_VER  ($PYTHON)"

if ! "$PYTHON" -m pip --version &>/dev/null; then
  warn "pip 未找到，尝试安装..."
  case "$OS" in
    debian) $SUDO apt-get install -y python3-pip || true ;;
    redhat) $SUDO yum install -y python3-pip 2>/dev/null || $SUDO dnf install -y python3-pip || true ;;
    arch)   $SUDO pacman -Sy --noconfirm python-pip || true ;;
    macos)  "$PYTHON" -m ensurepip --upgrade || true ;;
    *)      die "请手动安装 pip" ;;
  esac
  if ! "$PYTHON" -m pip --version &>/dev/null; then
    die "pip 安装失败，请手动处理"
  fi
fi
ok "pip 可用"

if ! "$PYTHON" -m venv --help &>/dev/null 2>&1; then
  warn "python3-venv 缺失，尝试安装..."
  case "$OS" in
    debian) $SUDO apt-get install -y python3-venv || true ;;
    *) warn "请手动安装 venv 模块" ;;
  esac
  if ! "$PYTHON" -m venv --help &>/dev/null 2>&1; then
    die "venv 模块安装失败，请手动安装 python3-venv 或对应系统包"
  fi
fi
ok "venv 模块可用"

check_network() {
  if command -v curl &>/dev/null; then
    curl -sf --max-time 5 https://api.telegram.org > /dev/null 2>&1
  elif command -v wget &>/dev/null; then
    wget -q --timeout=5 -O /dev/null https://api.telegram.org > /dev/null 2>&1
  else
    return 1
  fi
}
if check_network; then
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

source "$VENV_DIR/bin/activate"
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

info "升级 pip..."
"$VENV_PIP" install --upgrade pip -q

REQUIREMENTS="$INSTALL_DIR/requirements.txt"
if [[ ! -f "$REQUIREMENTS" ]]; then
  cat > "$REQUIREMENTS" << 'REQ'
pyrogram==2.0.106
TgCrypto==1.2.5
python-dotenv==1.0.1
REQ
fi

info "安装依赖包..."
"$VENV_PIP" install -r "$REQUIREMENTS" -q --no-warn-script-location 2>&1 \
  | grep -E "^(Successfully|ERROR|error)" || true

for pkg in pyrogram dotenv; do
  if "$VENV_PYTHON" -c "import $pkg" 2>/dev/null; then
    ok "import $pkg"
  else
    die "包 $pkg 安装失败，请检查网络或手动运行: $VENV_PIP install -r requirements.txt"
  fi
done

# ═══════════════════════════════════════════════════════════════
#  STEP 3 · 交互式信息采集 (优化版)
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[3/5] 填写配置信息${N}"
sep
echo -e "${Y}  所有信息仅写入本地 .env 文件，不会上传到任何地方${N}\n"

# ── 工具函数：清空输入中的任何空白字符（空格、制表、换行） ──
sanitize() {
  local val="$1"
  # 删除所有空白字符
  val="${val//[[:space:]]/}"
  echo "$val"
}

# ── 辅助：读取非空输入（带重试上限） ──
prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local secret="${3:-false}"
  local max_retries=5
  local attempt=0
  local value=""

  while true; do
    if $secret; then
      read -rsp "  ${C}${prompt_text}${N}: " value
      echo
    else
      read -rp "  ${C}${prompt_text}${N}: " value
    fi
    value=$(sanitize "$value")

    if [[ -n "$value" ]]; then
      printf -v "$var_name" '%s' "$value"
      return 0
    fi

    ((attempt++))
    if [[ $attempt -ge $max_retries ]]; then
      err "已达到最大重试次数 ($max_retries)，安装终止"
      exit 1
    fi
    err "输入不能为空，剩余重试次数：$((max_retries - attempt))"
  done
}

# ── 辅助：读取可选输入（带默认值） ──
prompt_optional() {
  local var_name="$1"
  local prompt_text="$2"
  local default="$3"
  local value=""
  read -rp "  ${C}${prompt_text}${N} [${Y}${default}${N}]: " value
  value=$(sanitize "$value")
  [[ -z "$value" ]] && value="$default"
  printf -v "$var_name" '%s' "$value"
}

# ── 配置采集函数（返回 0 表示确认，1 表示需要重新填写） ──
collect_config() {
  echo -e "\n  ${W}▸ Telegram API 凭据${N}"
  echo -e "  获取地址：${B}https://my.telegram.org/apps${N}  （登录后创建 App）\n"

  # API_ID
  while true; do
    prompt_required API_ID "API_ID（纯数字，例如 12345678）"
    if [[ "$API_ID" =~ ^[0-9]+$ ]]; then
      break
    else
      err "API_ID 必须是纯数字，请重新输入"
    fi
  done

  # API_HASH
  while true; do
    prompt_required API_HASH "API_HASH（32位十六进制字符串）"
    if [[ "${#API_HASH}" -eq 32 && "$API_HASH" =~ ^[0-9a-fA-F]+$ ]]; then
      break
    else
      err "API_HASH 应为 32 位十六进制字符串（当前长度 ${#API_HASH}），请重新输入"
    fi
  done

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

  echo -e "\n  ${W}▸ 下载目录配置${N}\n"
  prompt_optional DOWNLOAD_ROOT "下载根目录" "$INSTALL_DIR/downloads"

  prompt_optional ORGANIZE_BY_DATE "按日期子目录归档（true/false）" "true"
  [[ "$ORGANIZE_BY_DATE" != "false" ]] && ORGANIZE_BY_DATE="true"

  prompt_optional PROGRESS_UPDATE_SEC "进度消息刷新间隔（秒）" "2.0"

  echo -e "\n  ${W}▸ 用户白名单${N}"
  echo -e "  ${Y}留空 = 所有人均可使用；多个 ID 用逗号分隔${N}"
  echo -e "  获取自己的 user_id：在 Telegram 找 ${B}@userinfobot${N} 发任意消息\n"
  read -rp "  ${C}ALLOWED_USERS${N}（可留空）: " ALLOWED_USERS
  ALLOWED_USERS=$(sanitize "$ALLOWED_USERS")

  # 如果非空，验证每个 ID 是否为数字
  if [[ -n "$ALLOWED_USERS" ]]; then
    IFS=',' read -ra IDS <<< "$ALLOWED_USERS"
    for id in "${IDS[@]}"; do
      if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        err "白名单包含非法 user_id: '$id'（必须为纯数字），请重新填写"
        return 1
      fi
    done
  fi

  return 0
}

# ── 主交互循环：采集 → 预览 → 确认/修改 ──
while true; do
  # 重置变量
  API_ID=""; API_HASH=""; BOT_TOKEN=""
  DOWNLOAD_ROOT=""; ORGANIZE_BY_DATE=""; PROGRESS_UPDATE_SEC=""; ALLOWED_USERS=""

  # 采集所有配置
  if ! collect_config; then
    echo -e "\n${Y}  重新填写所有配置项...${N}\n"
    continue
  fi

  # ── 预览配置 ──
  echo -e "\n${W}${BOLD}  ═══════════ 配置预览 ═══════════${N}"
  echo -e "  API_ID            : ${G}${API_ID}${N}"
  echo -e "  API_HASH          : ${G}${API_HASH:0:6}****${N}"
  echo -e "  BOT_TOKEN         : ${G}${BOT_TOKEN%%:*}:****${N}"
  echo -e "  下载根目录        : ${G}${DOWNLOAD_ROOT}${N}"
  echo -e "  按日期归档        : ${G}${ORGANIZE_BY_DATE}${N}"
  echo -e "  进度刷新间隔      : ${G}${PROGRESS_UPDATE_SEC}s${N}"
  if [[ -z "$ALLOWED_USERS" ]]; then
    echo -e "  白名单            : ${Y}(所有人可用)${N}"
  else
    echo -e "  白名单            : ${G}${ALLOWED_USERS}${N}"
  fi
  echo -e "${W}  ═════════════════════════════════${N}"

  # 确认操作
  read -rp $'\n  '"${C}是否确认以上配置？${N} [${G}Y${N}/${Y}n${N}/${Y}m${N}(修改单项)]: " CONFIRM
  CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')

  case "$CONFIRM" in
    y|yes|"")
      echo -e "\n${G}  配置已确认，即将写入...${N}"
      break
      ;;
    m|modify)
      echo -e "\n  ${Y}  请选择要修改的项：${N}"
      echo "    1) API_ID"
      echo "    2) API_HASH"
      echo "    3) BOT_TOKEN"
      echo "    4) 下载根目录"
      echo "    5) 按日期归档"
      echo "    6) 进度刷新间隔"
      echo "    7) 白名单"
      echo "    8) 全部重新填写"
      read -rp "  ${C}输入数字 (1-8)${N}: " MOD_OPT
      case "$MOD_OPT" in
        1) echo; prompt_required API_ID "API_ID（纯数字）"; continue ;;
        2) echo; prompt_required API_HASH "API_HASH（32位十六进制）"; continue ;;
        3) echo; prompt_required BOT_TOKEN "BOT_TOKEN" true; continue ;;
        4) echo; prompt_optional DOWNLOAD_ROOT "下载根目录" "$DOWNLOAD_ROOT"; continue ;;
        5) echo; prompt_optional ORGANIZE_BY_DATE "按日期子目录归档（true/false）" "$ORGANIZE_BY_DATE"; continue ;;
        6) echo; prompt_optional PROGRESS_UPDATE_SEC "进度消息刷新间隔（秒）" "$PROGRESS_UPDATE_SEC"; continue ;;
        7) echo; read -rp "  ${C}ALLOWED_USERS${N}（可留空）: " ALLOWED_USERS
           ALLOWED_USERS=$(sanitize "$ALLOWED_USERS"); continue ;;
        8) echo -e "\n${Y}  重新填写全部配置...${N}\n"; continue ;;
        *) err "无效选项，返回预览"; continue ;;
      esac
      ;;
    n|no)
      echo -e "\n${Y}  已取消，您可以重新运行脚本填写配置。${N}"
      exit 0
      ;;
    *)
      err "请输入 Y (确认) / n (取消) / m (修改单项)"
      ;;
  esac
done

# 输出确认成功日志（可选）
ok "配置信息采集完成"

# ═══════════════════════════════════════════════════════════════
#  STEP 4 · 写入 .env 文件
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[4/5] 写入配置文件${N}"
sep

ENV_FILE="$INSTALL_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  info "已备份旧 .env"
fi

cat > "$ENV_FILE" << EOF
# Telegram 自动下载机器人配置
# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')
# !! 请勿将此文件提交到 Git !!

API_ID=${API_ID}
API_HASH=${API_HASH}
BOT_TOKEN=${BOT_TOKEN}
DOWNLOAD_ROOT=${DOWNLOAD_ROOT}
ORGANIZE_BY_DATE=${ORGANIZE_BY_DATE}
PROGRESS_UPDATE_SEC=${PROGRESS_UPDATE_SEC}
ALLOWED_USERS=${ALLOWED_USERS}
EOF

chmod 600 "$ENV_FILE"
ok ".env 已写入 → $ENV_FILE（权限 600）"

mkdir -p "$DOWNLOAD_ROOT"
ok "下载目录已创建 → $DOWNLOAD_ROOT"

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
