#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  Telegram 下载机器人 · 增强版 v3.1 · 一键部署脚本
# ═══════════════════════════════════════════════════════════════
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
  ║   Telegram 下载机器人 · 增强版 v3.1              ║
  ║   一键部署脚本  ·  支持多种启动方式               ║
  ╚══════════════════════════════════════════════════╝
BANNER
echo -e "${N}"
sep

# ── 脚本位置 & 安装目录 ───────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR"

# ── 全局变量 ─────────────────────────────────────────────────
PYTHON=""
VENV_DIR="$INSTALL_DIR/venv"
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"
SUDO=""

# ═══════════════════════════════════════════════════════════════
#  STEP 1 · 检测环境
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[1/6] 环境检测${N}"
sep

# ── 检测操作系统 ──────────────────────────────────────────────
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macos"; return
  fi
  if [[ -f /etc/os-release ]]; then
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

# ── 安装 Docker（可选） ──────────────────────────────────────
has_docker=false
if command -v docker &>/dev/null && command -v docker-compose &>/dev/null; then
  ok "已安装 Docker 和 Docker Compose"
  has_docker=true
else
  warn "未安装 Docker，将使用本地 Python 运行"
fi

# ── Python 版本检测 ────────────────────────────────────────
find_python() {
  for cmd in python3.11 python3.10 python3.9 python3 python; do
    command -v "$cmd" &>/dev/null || continue
    read -r major minor < <("$cmd" -c "import sys; v=sys.version_info; print(v.major, v.minor)" 2>/dev/null) || continue
    if (( major > 3 || ( major == 3 && minor >= 9 ) )); then
      echo "$cmd"; return 0
    fi
  done
  return 1
}

if PYTHON=$(find_python); then
  py_ver=$("$PYTHON" -c "import sys; v=sys.version_info; print(f'{v.major}.{v.minor}.{v.micro}')")
  ok "Python $py_ver  ($PYTHON)"
else
  die "Python 3.9+ 未找到，请先安装"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 2 · 选择部署方式
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[2/6] 选择部署方式${N}"
sep
echo -e "\n  ${Y}可用的部署方式：${N}"
[[ "$has_docker" == true ]] && echo -e "  ${C}1${N}  Docker Compose（推荐，最简单）"
echo -e "  ${C}2${N}  Supervisor（推荐，生产环境）"
echo -e "  ${C}3${N}  Systemd（推荐，Linux 系统）"
echo -e "  ${C}4${N}  本地运行（开发/测试）\n"

read -rp "  请选择 [1/2/3/4]: " DEPLOY_METHOD

case "$DEPLOY_METHOD" in
  1)
    if [[ "$has_docker" != true ]]; then
      warn "Docker 未安装，无法使用此方法"
      exit 1
    fi
    DEPLOY_TYPE="docker"
    ;;
  2) DEPLOY_TYPE="supervisor" ;;
  3) DEPLOY_TYPE="systemd" ;;
  4) DEPLOY_TYPE="local" ;;
  *) die "无效选择" ;;
esac

ok "选择部署方式：$DEPLOY_TYPE"

# ═══════════════════════════════════════════════════════════════
#  STEP 3 · 生成配置文件
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[3/6] 配置文件${N}"
sep

if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  info "生成 .env 模板"
  bash "$INSTALL_DIR/gen-env.sh"
  warn "请编辑 .env，填写 API_ID、API_HASH、BOT_TOKEN"
  read -rp "  编辑完成后按 Enter 继续..."
else
  ok ".env 文件已存在"
  read -rp "  是否重新生成？ [y/N]: " REGEN
  if [[ "$REGEN" == "y" ]]; then
    bash "$INSTALL_DIR/gen-env.sh"
    read -rp "  编辑完成后按 Enter 继续..."
  fi
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 4 · 安装依赖
# ═══════════════════════════════════════════════════════════════
if [[ "$DEPLOY_TYPE" != "docker" ]]; then
  echo -e "\n${W}${BOLD}[4/6] 安装 Python 依赖${N}"
  sep

  if [[ ! -d "$VENV_DIR" ]]; then
    info "创建虚拟环境"
    "$PYTHON" -m venv "$VENV_DIR"
    ok "虚拟环境创建成功"
  fi

  source "$VENV_DIR/bin/activate"
  "$VENV_PIP" install --upgrade pip -q

  info "安装依赖包"
  "$VENV_PIP" install -r "$INSTALL_DIR/requirements-enhanced.txt" -q

  ok "依赖安装完成"
else
  echo -e "\n${W}${BOLD}[4/6] Docker 准备${N}"
  sep
  ok "Docker 部署无需本地依赖"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 5 · 部署配置
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[5/6] 部署配置${N}"
sep

case "$DEPLOY_TYPE" in
  docker)
    ok "Docker Compose 部署就绪"
    info "使用方式："
    echo -e "  ${C}docker-compose up -d${N}  # 启动"
    echo -e "  ${C}docker-compose logs -f${N}  # 查看日志"
    echo -e "  ${C}docker-compose down${N}   # 停止"
    ;;

  supervisor)
    info "配置 Supervisor 进程管理"
    SUPERVISOR_DIR="/etc/supervisor/conf.d"
    SUPERVISOR_CONF="$SUPERVISOR_DIR/tg-downloader.conf"
    
    if [[ -d "$SUPERVISOR_DIR" ]]; then
      cat > /tmp/tg-downloader.conf << EOF
[program:tg-downloader]
directory=$INSTALL_DIR
command=$VENV_PYTHON $INSTALL_DIR/bot-enhanced.py
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=$INSTALL_DIR/logs/supervisor.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=10
EOF
      
      if [[ $EUID -eq 0 ]] || command -v sudo &>/dev/null; then
        $SUDO cp /tmp/tg-downloader.conf "$SUPERVISOR_CONF"
        ok "Supervisor 配置已生成"
        info "使用方式："
        echo -e "  ${C}sudo supervisorctl reread${N}"
        echo -e "  ${C}sudo supervisorctl update${N}"
        echo -e "  ${C}sudo supervisorctl start tg-downloader${N}"
      else
        warn "需要 sudo 权限来复制 Supervisor 配置"
      fi
    else
      warn "Supervisor 未安装或目录不存在"
    fi
    ;;

  systemd)
    info "配置 Systemd 服务"
    SYSTEMD_UNIT="/etc/systemd/system/tg-downloader.service"
    
    cat > /tmp/tg-downloader.service << EOF
[Unit]
Description=Telegram Downloader Bot Enhanced
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_PYTHON $INSTALL_DIR/bot-enhanced.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
EnvironmentFile=$INSTALL_DIR/.env

[Install]
WantedBy=multi-user.target
EOF

    if [[ $EUID -eq 0 ]] || command -v sudo &>/dev/null; then
      $SUDO cp /tmp/tg-downloader.service "$SYSTEMD_UNIT"
      ok "Systemd 服务配置已生成"
      info "使用方式："
      echo -e "  ${C}sudo systemctl daemon-reload${N}"
      echo -e "  ${C}sudo systemctl enable tg-downloader${N}"
      echo -e "  ${C}sudo systemctl start tg-downloader${N}"
      echo -e "  ${C}sudo systemctl status tg-downloader${N}"
    else
      warn "需要 sudo 权限来安装 Systemd 服务"
    fi
    ;;

  local)
    ok "本地运行配置完成"
    info "使用方式："
    echo -e "  ${C}source venv/bin/activate${N}"
    echo -e "  ${C}python bot-enhanced.py${N}"
    ;;
esac

# ═══════════════════════════════════════════════════════════════
#  STEP 6 · 启动 Bot
# ═══════════════════════════════════════════════════════════════
echo -e "\n${W}${BOLD}[6/6] 启动 Bot${N}"
sep

case "$DEPLOY_TYPE" in
  docker)
    read -rp $'\n  '"${C}是否立即启动 Docker？${N} [Y/n]: " START
    if [[ "$START" != "n" ]]; then
      cd "$INSTALL_DIR"
      docker-compose up -d
      sleep 2
      ok "Bot 已在 Docker 中启动"
      docker-compose logs tg-downloader | head -20
    fi
    ;;

  local)
    read -rp $'\n  '"${C}是否立即启动 Bot？${N} [Y/n]: " START
    if [[ "$START" != "n" ]]; then
      cd "$INSTALL_DIR"
      source "$VENV_DIR/bin/activate"
      python bot-enhanced.py
    fi
    ;;

  supervisor|systemd)
    ok "部署配置完成！"
    info "请按上面的提示启动服务"
    ;;
esac

# ── 最后的提示 ──────────────────────────────────────────────
sep
echo -e "\n  ${G}${BOLD}✨ 部署完成！${N}\n"
echo -e "  ${W}后续步骤：${N}"
echo -e "  1️⃣  配置文件：${C}$INSTALL_DIR/.env${N}"
echo -e "  2️⃣  查看日志：${C}tail -f $INSTALL_DIR/logs/bot.log${N}"
echo -e "  3️⃣  文档：${C}README-ENHANCED.md${N}"
echo -e "  4️⃣  在 Telegram 中运行：${C}/start${N}\n"
echo -e "  ${Y}常见命令：${N}"
echo -e "  • 状态查询：${C}docker-compose ps${N}"
echo -e "  • 查看日志：${C}docker-compose logs -f${N}"
echo -e "  • 重启服务：${C}docker-compose restart${N}"
echo -e "  • 停止服务：${C}docker-compose down${N}\n"
