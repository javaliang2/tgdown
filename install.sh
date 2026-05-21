#!/usr/bin/env bash
# =============================================================
#  Telegram 自动下载机器人 · 一键安装脚本
#  支持：Ubuntu / Debian / CentOS / RHEL / Arch / macOS
# =============================================================
set -euo pipefail

# ── 颜色 & 输出工具 ───────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m'
B='\033[0;34m' C='\033[0;36m' W='\033[1;37m' N='\033[0m'
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
  git clone https://github.com/lje02/tgdown.git
  cd tgdown
  exec bash install.sh
fi

# ── 全局变量 ─────────────────────────────────────────────────
PYTHON=""
VENV_DIR="$INSTALL_DIR/venv"
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"
SUDO=""

# ═══════════════════════════════════════════════════════════════
#  STEP 1 · 环境自检
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[1/5] 环境自检${N}"
sep

# ── 检测操作系统 ──────────────────────────────────────────────
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macos"; return
  fi
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${ID:-}" in
      ubuntu|debian|linuxmint|pop)              echo "debian"  ;;
      centos|rhel|fedora|rocky|almalinux)       echo "redhat"  ;;
      arch|manjaro|endeavouros)                 echo "arch"    ;;
      *)                                        echo "unknown" ;;
    esac
  else
    echo "unknown"
  fi
}

OS=$(detect_os)
info "操作系统：$(uname -s) / 发行版：$OS"

# ── 权限检测 ──────────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
  info "以 root 身份运行"
else
  info "以普通用户运行（sudo 将按需调用）"
  command -v sudo &>/dev/null && SUDO="sudo"
fi

# ── Python 版本检测（要求 3.9+） ──────────────────────────────
find_python() {
  local cmd ver major minor
  for cmd in python3.12 python3.11 python3.10 python3.9 python3 python; do
    command -v "$cmd" &>/dev/null || continue
    # 直接用算术比较，避免正则解析
    read -r major minor < <(
      "$cmd" -c "import sys; v=sys.version_info; print(v.major, v.minor)" 2>/dev/null
    ) || continue
    if (( major > 3 || ( major == 3 && minor >= 9 ) )); then
      echo "$cmd"; return 0
    fi
  done
  return 1
}

# ── 安装包管理器辅助 ──────────────────────────────────────────
pkg_install() {
  # 用法: pkg_install <pkg_debian> [<pkg_redhat>] [<pkg_arch>]
  local deb="${1:-}" rpm="${2:-$1}" arc="${3:-$1}"
  case "$OS" in
    debian) $SUDO apt-get install -y "$deb" ;;
    redhat) command -v dnf &>/dev/null \
              && $SUDO dnf install -y "$rpm" \
              || $SUDO yum install -y "$rpm" ;;
    arch)   $SUDO pacman -Sy --noconfirm "$arc" ;;
    macos)  command -v brew &>/dev/null \
              && brew install python3 \
              || die "请先安装 Homebrew (https://brew.sh) 或手动安装 Python 3.9+" ;;
    *)      die "无法自动安装依赖，请手动安装 Python 3.9+" ;;
  esac
}

# ── 安装 Python ───────────────────────────────────────────────
install_python() {
  warn "未找到 Python 3.9+，正在自动安装..."
  case "$OS" in
    debian) $SUDO apt-get update -qq
            $SUDO apt-get install -y python3 python3-venv python3-pip ;;
    redhat) pkg_install python3 python3-pip ;;
    arch)   pkg_install python python-pip ;;
    macos)  pkg_install python3 ;;
    *)      die "无法自动安装 Python，请手动安装 Python 3.9+" ;;
  esac
}

# ── 安装 pip ──────────────────────────────────────────────────
ensure_pip() {
  "$PYTHON" -m pip --version &>/dev/null && return 0
  warn "pip 未找到，尝试安装..."
  case "$OS" in
    debian) $SUDO apt-get install -y python3-pip ;;
    redhat) pkg_install python3-pip ;;
    arch)   pkg_install python-pip ;;
    macos)  "$PYTHON" -m ensurepip --upgrade ;;
    *)      die "请手动安装 pip" ;;
  esac
  "$PYTHON" -m pip --version &>/dev/null || die "pip 安装失败"
  ok "pip 可用"
}

# ── 安装 venv ─────────────────────────────────────────────────
ensure_venv() {
  "$PYTHON" -m venv --help &>/dev/null && return 0
  warn "缺少 venv 模块，尝试安装..."
  local py_ver
  py_ver=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
  case "$OS" in
    debian) $SUDO apt-get update -qq
            $SUDO apt-get install -y "python${py_ver}-venv" ;;
    redhat) command -v dnf &>/dev/null \
              && $SUDO dnf reinstall -y python3 \
              || $SUDO yum reinstall -y python3 ;;
    arch)   warn "Arch 系 venv 应已内置，请检查 python 包完整性" ;;
    macos)  warn "请尝试 brew reinstall python3" ;;
    *)      warn "请手动安装 python${py_ver}-venv" ;;
  esac
  "$PYTHON" -m venv --help &>/dev/null \
    || die "venv 安装失败，请手动安装 python${py_ver}-venv"
  ok "venv 模块可用"
}

# ── 主流程：初始化 Python 环境 ────────────────────────────────
setup_python() {
  if ! PYTHON=$(find_python); then
    install_python
    PYTHON=$(find_python) || die "Python 安装后仍未找到，请手动安装 Python 3.9+"
  fi

  local py_ver
  py_ver=$("$PYTHON" -c "import sys; v=sys.version_info; print(f'{v.major}.{v.minor}.{v.micro}')")
  ok "Python $py_ver  ($PYTHON)"

  ensure_pip
  ensure_venv
}

setup_python

# ── 网络连通性检测 ────────────────────────────────────────────
check_network() {
  if command -v curl &>/dev/null; then
    curl -sf --max-time 5 https://api.telegram.org > /dev/null
  elif command -v wget &>/dev/null; then
    wget -q --timeout=5 -O /dev/null https://api.telegram.org
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

if [[ -d "$VENV_DIR" ]]; then
  info "虚拟环境已存在，跳过创建"
else
  info "创建虚拟环境 → $VENV_DIR"
  "$PYTHON" -m venv "$VENV_DIR"
  ok "虚拟环境创建成功"
fi

# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"

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
# 只显示成功/失败行，过滤掉无意义的进度输出
"$VENV_PIP" install -r "$REQUIREMENTS" -q --no-warn-script-location 2>&1 \
  | grep -E "^(Successfully|ERROR|error)" || true

for pkg in pyrogram dotenv; do
  if "$VENV_PYTHON" -c "import $pkg" 2>/dev/null; then
    ok "import $pkg"
  else
    die "包 $pkg 安装失败，请检查网络或手动运行：$VENV_PIP install -r requirements.txt"
  fi
done

# ═══════════════════════════════════════════════════════════════
#  STEP 3 · 交互式配置采集
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[3/5] 填写配置信息${N}"
sep
echo -e "${Y}  所有信息仅写入本地 .env 文件，不会上传到任何地方${N}\n"

# ── 工具：去除所有空白字符 ────────────────────────────────────
sanitize() { echo "${1//[[:space:]]/}"; }

# ── 读取必填项（带重试）────────────────────────────────────────
# 用法: prompt_required <varname> <提示文字> [secret=true]
prompt_required() {
  local var_name="$1" prompt_text="$2" secret="${3:-false}"
  local value="" attempt=0 max_retries=5
  while true; do
    if $secret; then
      read -rsp "  ${C}${prompt_text}${N}: " value; echo
    else
      read -rp  "  ${C}${prompt_text}${N}: " value
    fi
    value=$(sanitize "$value")
    if [[ -n "$value" ]]; then
      printf -v "$var_name" '%s' "$value"
      return 0
    fi
    (( attempt++ ))
    (( attempt >= max_retries )) && die "已达最大重试次数 ($max_retries)，安装终止"
    err "输入不能为空，剩余重试次数：$((max_retries - attempt))"
  done
}

# ── 读取可选项（带默认值）─────────────────────────────────────
# 用法: prompt_optional <varname> <提示文字> <默认值>
prompt_optional() {
  local var_name="$1" prompt_text="$2" default="$3" value=""
  read -rp "  ${C}${prompt_text}${N} [${Y}${default}${N}]: " value
  value=$(sanitize "$value")
  printf -v "$var_name" '%s' "${value:-$default}"
}

# ── 校验白名单格式（逗号分隔的纯数字 user_id）────────────────
validate_allowed_users() {
  local input="$1"
  [[ -z "$input" ]] && return 0  # 空值合法（不限用户）
  local id
  IFS=',' read -ra IDS <<< "$input"
  for id in "${IDS[@]}"; do
    [[ "$id" =~ ^[0-9]+$ ]] || { err "非法 user_id: '$id'（必须为纯数字）"; return 1; }
  done
  return 0
}

# ── 单项修改菜单 ──────────────────────────────────────────────
modify_single_field() {
  echo -e "\n  ${Y}请选择要修改的项：${N}"
  echo "    1) API_ID"
  echo "    2) API_HASH"
  echo "    3) BOT_TOKEN"
  echo "    4) 下载根目录"
  echo "    5) 按日期归档"
  echo "    6) 进度刷新间隔"
  echo "    7) 白名单"
  echo "    8) 全部重新填写"
  local opt
  read -rp "  ${C}输入数字 (1-8)${N}: " opt
  case "$opt" in
    1) echo; prompt_required API_ID   "API_ID（纯数字）" ;;
    2) echo; prompt_required API_HASH "API_HASH（32位十六进制）" ;;
    3) echo; prompt_required BOT_TOKEN "BOT_TOKEN" true ;;
    4) echo; prompt_optional DOWNLOAD_ROOT      "下载根目录"              "$DOWNLOAD_ROOT" ;;
    5) echo; prompt_optional ORGANIZE_BY_DATE   "按日期归档（true/false）" "$ORGANIZE_BY_DATE" ;;
    6) echo; prompt_optional PROGRESS_UPDATE_SEC "进度刷新间隔（秒）"      "$PROGRESS_UPDATE_SEC" ;;
    7) echo
       while true; do
         read -rp "  ${C}ALLOWED_USERS${N}（可留空）: " ALLOWED_USERS
         ALLOWED_USERS=$(sanitize "$ALLOWED_USERS")
         validate_allowed_users "$ALLOWED_USERS" && break
       done ;;
    8) return 1 ;;   # 信号：需要全部重填
    *) err "无效选项" ;;
  esac
  return 0
}

# ── 显示配置预览 ──────────────────────────────────────────────
show_preview() {
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
}

# ── 采集一轮完整配置（返回 0 成功，1 需重填）─────────────────
collect_config() {
  echo -e "\n  ${W}▸ Telegram API 凭据${N}"
  echo -e "  获取地址：${B}https://my.telegram.org/apps${N}  （登录后创建 App）\n"

  # API_ID：纯数字
  while true; do
    prompt_required API_ID "API_ID（纯数字，例如 12345678）"
    [[ "$API_ID" =~ ^[0-9]+$ ]] && break
    err "API_ID 必须是纯数字，请重新输入"
  done

  # API_HASH：32 位十六进制
  while true; do
    prompt_required API_HASH "API_HASH（32位十六进制字符串）"
    [[ ${#API_HASH} -eq 32 && "$API_HASH" =~ ^[0-9a-fA-F]+$ ]] && break
    err "API_HASH 应为 32 位十六进制字符串（当前 ${#API_HASH} 位），请重新输入"
  done

  echo -e "\n  ${W}▸ Bot Token${N}"
  echo -e "  获取方式：在 Telegram 找 ${B}@BotFather${N} → /newbot\n"

  # BOT_TOKEN：数字:字符串
  while true; do
    prompt_required BOT_TOKEN "BOT_TOKEN（格式：数字:字母数字串）" true
    [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] && break
    err "Token 格式不正确（应为 123456:ABC...），请重新输入"
  done

  echo -e "\n  ${W}▸ 下载目录配置${N}\n"
  prompt_optional DOWNLOAD_ROOT       "下载根目录"               "$INSTALL_DIR/downloads"
  prompt_optional ORGANIZE_BY_DATE    "按日期子目录归档（true/false）" "true"
  prompt_optional PROGRESS_UPDATE_SEC "进度消息刷新间隔（秒）"    "2.0"
  # 非 false 均视为 true
  [[ "$ORGANIZE_BY_DATE" == "false" ]] || ORGANIZE_BY_DATE="true"

  echo -e "\n  ${W}▸ 用户白名单${N}"
  echo -e "  ${Y}留空 = 所有人均可使用；多个 ID 用逗号分隔${N}"
  echo -e "  获取自己的 user_id：在 Telegram 找 ${B}@userinfobot${N} 发任意消息\n"

  while true; do
    read -rp "  ${C}ALLOWED_USERS${N}（可留空）: " ALLOWED_USERS
    ALLOWED_USERS=$(sanitize "$ALLOWED_USERS")
    validate_allowed_users "$ALLOWED_USERS" && break
    err "请重新输入白名单"
  done

  return 0
}

# ── 主交互循环 ────────────────────────────────────────────────
API_ID="" API_HASH="" BOT_TOKEN=""
DOWNLOAD_ROOT="" ORGANIZE_BY_DATE="" PROGRESS_UPDATE_SEC="" ALLOWED_USERS=""

while true; do
  collect_config || { echo -e "\n${Y}  重新填写所有配置项...${N}\n"; continue; }

  show_preview

  read -rp $'\n  '"${C}是否确认以上配置？${N} [${G}Y${N}/${Y}n${N}/${Y}m${N}(修改单项)]: " CONFIRM
  case "$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')" in
    y|yes|"")
      echo -e "\n${G}  配置已确认，即将写入...${N}"
      break
      ;;
    m|modify)
      modify_single_field || {
        # 选项 8：全部重填，先重置变量
        API_ID="" API_HASH="" BOT_TOKEN=""
        DOWNLOAD_ROOT="" ORGANIZE_BY_DATE="" PROGRESS_UPDATE_SEC="" ALLOWED_USERS=""
        echo -e "\n${Y}  重新填写所有配置项...${N}\n"
      }
      ;;
    n|no)
      echo -e "\n${Y}  已取消，您可以重新运行脚本填写配置。${N}"
      exit 0
      ;;
    *)
      err "请输入 Y（确认）/ n（取消）/ m（修改单项）"
      ;;
  esac
done

ok "配置信息采集完成"

# ═══════════════════════════════════════════════════════════════
#  STEP 4 · 写入 .env 文件
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[4/5] 写入配置文件${N}"
sep

ENV_FILE="$INSTALL_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  local_bak="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$ENV_FILE" "$local_bak"
  info "已备份旧 .env → $local_bak"
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

# ── 生成 systemd 服务文件（仅 Linux）─────────────────────────
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
ExecStart=${VENV_PYTHON} ${INSTALL_DIR}/bot.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
EnvironmentFile=${ENV_FILE}

[Install]
WantedBy=multi-user.target
EOF
  ok "systemd 服务文件已生成 → $SERVICE_FILE"
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
[[ "$OS" != "macos" && "$OS" != "unknown" ]] && \
  echo -e "  ${C}3${N}  注册为 systemd 服务（推荐生产环境）"
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
      info "停止 Bot ：kill $BOT_PID"
    else
      err "Bot 启动失败，请查看日志：cat $INSTALL_DIR/bot.log"
    fi
    ;;
  3)
    if [[ "$OS" == "macos" || "$OS" == "unknown" ]]; then
      warn "当前系统不支持 systemd，请选择其他启动方式"
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
        err "服务启动失败，最近日志："
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
