#!/bin/bash

# ========================================================
# sing-box 综合管理脚本  v2.1
# ========================================================

RED='\033[1;31m'
GREEN='\033[1;32m'
PURPLE='\033[0;35m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
LINK_DIR="/etc/sing-box/links"
CERT_DIR="/etc/sing-box/certs"
BACKUP_DIR="/root/singbox_backup"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行！${PLAIN}" && exit 1

# ============================================================
# 辅助工具
# ============================================================
pause() {
    echo ""
    read -p "操作完成，按回车键继续..."
}

# [F15] URL解码与查询串工具提升到全局，避免 parse_proxy_link 每次重定义
_urldecode() {
    python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null || cat
}
# 用法: _qs_get <query_string> <key>
_qs_get() {
    echo "$1" | tr '&' '\n' | grep -i "^${2}=" | head -1 | cut -d= -f2- | _urldecode
}

# ============================================================
# [F01] 临时文件管理
# ============================================================
_TMP_JSON=""
trap 'rm -f "$_TMP_JSON"' EXIT

make_tmp() {
    _TMP_JSON=$(mktemp /tmp/sb_XXXXXX.json)
}

# [F09] 返回新 mktemp 路径（调用方负责清理）
make_safe_tmp() {
    mktemp /tmp/sb_XXXXXX.json
}

# [F14] 原子写入并重启；restart 失败时明确报错
save_and_restart() {
    if [[ -z "$_TMP_JSON" || ! -f "$_TMP_JSON" ]]; then
        echo -e "${RED}错误: 临时配置文件不存在。${PLAIN}"
        return 1
    fi

    if ! $SB_BIN check -c "$_TMP_JSON" > /dev/null 2>&1; then
        echo -e "${RED}✘ 配置语法检查失败，旧配置已保留。${PLAIN}"
        echo -e "${YELLOW}错误详情:${PLAIN}"
        $SB_BIN check -c "$_TMP_JSON" 2>&1 | head -20
        rm -f "$_TMP_JSON"; _TMP_JSON=""
        return 1
    fi

    mv "$_TMP_JSON" "$CONFIG_FILE"
    _TMP_JSON=""

    if systemctl restart sing-box 2>&1; then
        sleep 0.5
        if systemctl is-active --quiet sing-box; then
            return 0
        else
            echo -e "${RED}✘ sing-box 启动失败！请检查日志: journalctl -u sing-box -n 30${PLAIN}"
            return 1
        fi
    else
        echo -e "${RED}✘ systemctl restart 失败，请手动检查服务状态。${PLAIN}"
        return 1
    fi
}

# ============================================================
# [F02] 数组越界保护
# ============================================================
validate_index() {
    local input=$1 max=$2
    if [[ ! "$input" =~ ^[0-9]+$ ]] || (( input < 1 || input > max )); then
        echo -e "${RED}✘ 无效序号，请输入 1 ~ $max 之间的数字。${PLAIN}"
        return 1
    fi
    return 0
}

# ============================================================
# [F03] 端口占用检测（TCP+UDP，纯 ss，无需 lsof）
# ============================================================
check_port() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo -e "${RED}✘ 端口号无效，请输入 1 ~ 65535 之间的数字。${PLAIN}"
        return 1
    fi
    # -t TCP -u UDP -l LISTEN -n 数字 -p 进程；同时覆盖 TCP 和 UDP
    if ss -tulnp 2>/dev/null | grep -qP ":${port}(?:\s|$)"; then
        local proc
        proc=$(ss -tulnp 2>/dev/null | grep -P ":${port}(?:\s|$)" | awk '{print $NF}' | head -1)
        echo -e "${RED}✘ 端口 $port 已被占用！进程: $proc${PLAIN}"
        echo -e "${YELLOW}  提示: 换一个端口，或用 'ss -tulnp | grep :$port' 查看详情。${PLAIN}"
        return 1
    fi
    return 0
}

# 在候选目录下扫描证书文件（依次尝试 sing-box 自身目录 与 certbot 默认目录）
find_certs() {
    local domain=$1
    local search_dirs=("$CERT_DIR/$domain" "/etc/letsencrypt/live/$domain")
    CERT_PATH=""; KEY_PATH=""
    local c_names=("server.crt" "fullchain.cer" "fullchain.pem" "$domain.cer" "cert.pem")
    local k_names=("server.key" "$domain.key" "privkey.pem" "cert.key")
    for search_dir in "${search_dirs[@]}"; do
        [[ -d "$search_dir" ]] || continue
        for f in "${c_names[@]}"; do [[ -z "$CERT_PATH" && -f "$search_dir/$f" ]] && CERT_PATH="$search_dir/$f"; done
        for f in "${k_names[@]}"; do [[ -z "$KEY_PATH" && -f "$search_dir/$f" ]] && KEY_PATH="$search_dir/$f"; done
        [[ -n "$CERT_PATH" && -n "$KEY_PATH" ]] && break
    done
}

init_config() {
    mkdir -p /etc/sing-box "$LINK_DIR" "$CERT_DIR"
    if [[ ! -f "$CONFIG_FILE" || ! -s "$CONFIG_FILE" ]]; then
        echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
    fi
}
# ============================================================
# 节点订阅辅助函数：刷新订阅文件
# ============================================================
refresh_sub() {
    if [[ -d "/var/www/singbox-sub" ]]; then
        local sub_file="sub"
        [[ -f "/var/www/singbox-sub/.path_cache" ]] && sub_file=$(cat /var/www/singbox-sub/.path_cache)

        # 清理上一次生成的订阅旧文件
        find /var/www/singbox-sub -maxdepth 1 -type f -not -name ".*" -not -name "*.py" -delete 2>/dev/null

        # 检查有没有 .link 文件
        local count=$(ls -1 "$LINK_DIR"/*.link 2>/dev/null | wc -l)
        if [[ $count -gt 0 ]]; then
            
            # 【核心纠错优化】：遍历所有缓存文件，校验其 Tag 是否在当前的 config.json 中
            for f in "$LINK_DIR"/*.link; do
                [ -e "$f" ] || continue
                
                # 从文件名提取出 Tag 名字 (例如把 /root/links/node1.link 变成 node1)
                local filename=$(basename "$f")
                local current_tag="${filename%.link}"
                
                # 去 config.json 里查询该 Tag 的节点是否存在
                local tag_exists=$(jq -r ".inbounds[] | select(.tag==\"$current_tag\") | .tag" "$CONFIG_FILE" 2>/dev/null)
                
                if [[ -z "$tag_exists" ]]; then
                    # 如果 json 里找不到这个 Tag，说明是已删除的“僵尸节点”，直接在硬盘上抹除它
                    rm -f "$f"
                    continue
                fi
                
                # 如果通过校验，才输出内容用于生成订阅
                cat "$f" | tr -d '\r\n'
                echo ""
            done | awk NF | base64 -w 0 > "/var/www/singbox-sub/$sub_file"
            
        else
            echo "" > "/var/www/singbox-sub/$sub_file"
        fi
    fi
}

get_ip() {
    local mode=${1:-"all"}
    local ip4 ip6
    ip4=$(curl -s4 --connect-timeout 3 icanhazip.com 2>/dev/null || curl -s4 --connect-timeout 3 ifconfig.me 2>/dev/null)
    ip6=$(curl -s6 --connect-timeout 3 icanhazip.com 2>/dev/null || curl -s6 --connect-timeout 3 ifconfig.me 2>/dev/null)
    case $mode in
        4) echo "$ip4" ;;
        6) [[ -n "$ip6" ]] && echo "[$ip6]" ;;
        "all")
            if   [[ -n "$ip4" ]]; then echo "$ip4"
            elif [[ -n "$ip6" ]]; then echo "[$ip6]"
            else echo "127.0.0.1"; fi ;;
    esac
}

show_status() {
    local PID STATUS ENABLE VER MEM WARP_STATUS
    PID=$(systemctl show -p MainPID sing-box 2>/dev/null | cut -d= -f2)
    STATUS=$(systemctl is-active --quiet sing-box && echo -e "${GREEN}运行中${PLAIN}" || echo -e "${RED}已停止${PLAIN}")
    ENABLE=$(systemctl is-enabled --quiet sing-box 2>/dev/null && echo -e "${GREEN}已启用${PLAIN}" || echo -e "${RED}已禁用${PLAIN}")
    VER=$($SB_BIN version 2>/dev/null | awk '/version/ {print $3}')
    MEM=$(ps -o rss= -p "$PID" 2>/dev/null | awk '{printf "%.2fMB", $1/1024}' || echo "0MB")

    # 获取 WARP 状态
    if command -v warp-cli &> /dev/null; then
        local raw_warp
        raw_warp=$(warp-cli --accept-tos status 2>/dev/null | grep -i "Status update" | awk -F': ' '{print $2}')
        # 清理可能存在的回车换行符，防止排版错乱
        raw_warp=${raw_warp//$'\r'/} 
        
        if [[ "$raw_warp" == "Connected" ]]; then
            WARP_STATUS="${GREEN}已连接 (Connected)${PLAIN}"
        elif [[ "$raw_warp" == "Connecting" ]]; then
            WARP_STATUS="${YELLOW}连接中 (Connecting)${PLAIN}"
        elif [[ -n "$raw_warp" ]]; then
            WARP_STATUS="${RED}${raw_warp}${PLAIN}"
        else
            WARP_STATUS="${RED}未运行或异常${PLAIN}"
        fi
    else
        WARP_STATUS="${YELLOW}未安装${PLAIN}"
    fi

    echo -e "${YELLOW}--- 服务监控 ---${PLAIN}"
    echo -e "运行状态: $STATUS\t\t开机自启: $ENABLE"
    echo -e "版本信息: ${BLUE}${VER:-未知}${PLAIN}\t\t内存占用: ${CYAN}${MEM}${PLAIN}"
    echo -e "WARP状态: $WARP_STATUS"
}

# ============================================================
# [F04] 日志查看
# ============================================================
view_logs() {
    while true; do
        clear
        echo -e "${YELLOW}--- 日志查看 ---${PLAIN}"
        echo "1. 查看最近 50 条日志"
        echo "2. 查看最近 200 条日志"
        echo "3. 实时跟踪日志 (Ctrl+C 退出)"
        echo "4. 查看错误日志 (仅 error/warn)"
        echo "5. 导出日志到文件 (/root/singbox_$(date +%Y%m%d).log)"
        echo "0. 返回"
        read -p "请选择: " log_choice
        case $log_choice in
            1) echo -e "\n${CYAN}--- 最近 50 条日志 ---${PLAIN}"
               journalctl -u sing-box -n 50 --no-pager; pause ;;
            2) echo -e "\n${CYAN}--- 最近 200 条日志 ---${PLAIN}"
               journalctl -u sing-box -n 200 --no-pager | less ;;
            3) echo -e "\n${CYAN}--- 实时日志 (Ctrl+C 退出) ---${PLAIN}"
               journalctl -u sing-box -f ;;
            4) echo -e "\n${CYAN}--- 错误/警告日志 ---${PLAIN}"
               journalctl -u sing-box -n 200 --no-pager -p warning; pause ;;
            5) local LOG_FILE="/root/singbox_$(date +%Y%m%d).log"
               journalctl -u sing-box --no-pager > "$LOG_FILE"
               echo -e "${GREEN}✔ 日志已导出至: ${BLUE}$LOG_FILE${PLAIN}"; pause ;;
            0) return ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ============================================================
# 功能模块
# ============================================================

apply_cert() {
    echo -e "${YELLOW}--- ACME 域名证书申请 ---${PLAIN}"
    read -p "请输入解析到本机的域名: " domain
    [[ -z "$domain" ]] && echo -e "${RED}✘ 域名不能为空${PLAIN}" && pause && return

    echo -e "${CYAN}安装依赖...${PLAIN}"
    if   command -v apt  &>/dev/null; then apt update -qq && apt install -y socat cron curl uuid-runtime
    elif command -v yum  &>/dev/null; then yum  install -y socat crontabs curl util-linux
    elif command -v dnf  &>/dev/null; then dnf  install -y socat crontabs curl util-linux
    fi

    local ACME_BIN="$HOME/.acme.sh/acme.sh"
    [[ ! -f "$ACME_BIN" ]] && curl https://get.acme.sh | sh -s email=admin@$domain

    # [F12] 统一用 ss 检测 80 端口，备用 fuser，不依赖 lsof
    if ss -tulnp 2>/dev/null | grep -qP ":80(?:\s|$)"; then
        echo -e "${YELLOW}80 端口被占用，尝试临时释放...${PLAIN}"
        systemctl stop nginx apache2 sing-box 2>/dev/null
        if command -v fuser &>/dev/null; then fuser -k 80/tcp 2>/dev/null
        elif command -v lsof  &>/dev/null; then kill -9 $(lsof -ti:80) 2>/dev/null; fi
    fi

    echo -e "${YELLOW}申请 Let's Encrypt 证书...${PLAIN}"
    "$ACME_BIN" --issue -d "$domain" --standalone --server letsencrypt --log

    if [[ $? -eq 0 ]]; then
        local tdir="$CERT_DIR/$domain"; mkdir -p "$tdir"
        "$ACME_BIN" --install-cert -d "$domain" \
            --key-file  "$tdir/server.key" \
            --fullchain-file "$tdir/server.crt"
        echo -e "${GREEN}✔ 证书安装成功！路径: ${BLUE}$tdir${PLAIN}"
    else
        echo -e "${RED}✘ 申请失败，常见原因：${PLAIN}"
        echo "  1. DNS 未解析到本机  2. 80端口被云防火墙拦截  3. Let's Encrypt 频率限制"
    fi
    systemctl start sing-box 2>/dev/null; pause
}

auto_backup() {
    mkdir -p "$BACKUP_DIR"
    local TIME=$(date +%Y%m%d_%H%M%S) TMP_BAK
    TMP_BAK=$(mktemp -d)
    [[ -f /usr/local/bin/sing-box ]] && cp /usr/local/bin/sing-box "$TMP_BAK/"
    [[ -d /etc/sing-box           ]] && cp -r /etc/sing-box/*       "$TMP_BAK/"
    tar -czf "$BACKUP_DIR/auto_bak_before_update_$TIME.tar.gz" -C "$TMP_BAK" . >/dev/null 2>&1
    rm -rf "$TMP_BAK"
    echo -e "${YELLOW}[自动快照] 已备份: auto_bak_before_update_$TIME.tar.gz${PLAIN}"
}

backup_restore() {
    clear
    echo -e "${YELLOW}--- 备份与还原 ---${PLAIN}"
    echo "1. 立即备份 (内核 + 配置)  2. 还原备份  0. 返回"
    read -p "选择: " br_choice
    [[ "$br_choice" == "0" ]] && return
    mkdir -p "$BACKUP_DIR"

    if [[ "$br_choice" == "1" ]]; then
        local TIME=$(date +%Y%m%d_%H%M%S) TMP_BAK
        TMP_BAK=$(mktemp -d)
        [[ -f /usr/local/bin/sing-box ]] && cp /usr/local/bin/sing-box "$TMP_BAK/"
        [[ -d /etc/sing-box           ]] && cp -r /etc/sing-box        "$TMP_BAK/"
        tar -czf "$BACKUP_DIR/singbox_full_$TIME.tar.gz" -C "$TMP_BAK" .
        rm -rf "$TMP_BAK"
        echo -e "${GREEN}✔ 备份完成: singbox_full_$TIME.tar.gz${PLAIN}"

    elif [[ "$br_choice" == "2" ]]; then
        local files=( $(ls "$BACKUP_DIR" 2>/dev/null | grep "\.tar\.gz") )
        if [[ ${#files[@]} -eq 0 ]]; then
            echo -e "${RED}没有找到备份文件${PLAIN}"
        else
            ls "$BACKUP_DIR" | grep "\.tar\.gz" | cat -n
            read -p "选择要还原的序号: " r_idx
            if ! validate_index "$r_idx" "${#files[@]}"; then pause; return; fi
            local R_FILE="${files[$((r_idx-1))]}" TMP_RST
            TMP_RST=$(mktemp -d)
            systemctl stop sing-box
            tar -xzf "$BACKUP_DIR/$R_FILE" -C "$TMP_RST"
            [[ -f "$TMP_RST/sing-box"     ]] && cp    "$TMP_RST/sing-box"    /usr/local/bin/sing-box
            [[ -d "$TMP_RST/sing-box"     ]] && cp -r "$TMP_RST/sing-box/"*  /etc/sing-box/
            rm -rf "$TMP_RST"
            systemctl restart sing-box
            echo -e "${GREEN}✔ 还原 $R_FILE 完成${PLAIN}"
        fi
    fi
    pause
}

install_base() {
    echo -e "${GREEN}>>> 安装依赖并检测架构...${PLAIN}"
    if   command -v apt &>/dev/null; then apt update -y && apt install -y curl jq tar wget uuid-runtime
    elif command -v yum &>/dev/null; then yum install -y curl jq tar wget util-linux
    else echo -e "${RED}不支持的包管理器${PLAIN}"; pause; return; fi

    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64"  ;;
        aarch64) arch="arm64"  ;;
        armv7l)  arch="armv7"  ;;
        *) echo -e "${RED}不支持的架构: $(uname -m)${PLAIN}"; pause; return ;;
    esac

    echo -e "${CYAN}获取 sing-box 最新版本...${PLAIN}"
    local TAG
    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    [[ -z "$TAG" ]] && echo -e "${RED}无法获取版本号，检查网络或 GitHub API 限制${PLAIN}" && pause && return
    echo -e "${CYAN}架构: $arch  版本: $TAG${PLAIN}"

    local TMP_DIR; TMP_DIR=$(mktemp -d)
    local url="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${arch}.tar.gz"

    wget -q --show-progress -O "$TMP_DIR/sing-box.tar.gz" "$url" || {
        echo -e "${RED}下载失败${PLAIN}"; rm -rf "$TMP_DIR"; pause; return; }
    tar -xzf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR" || {
        echo -e "${RED}解压失败${PLAIN}"; rm -rf "$TMP_DIR"; pause; return; }

    local BIN; BIN=$(find "$TMP_DIR" -type f -name "sing-box" -executable | head -1)
    [[ -z "$BIN" ]] && { echo -e "${RED}未找到可执行文件${PLAIN}"; rm -rf "$TMP_DIR"; pause; return; }
    cp "$BIN" /usr/local/bin/sing-box && chmod +x /usr/local/bin/sing-box
    rm -rf "$TMP_DIR"

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box
    init_config

    [[ "$0" != "/usr/local/bin/ssb" ]] && cp "$0" /usr/local/bin/ssb && chmod +x /usr/local/bin/ssb
    systemctl start sing-box
    echo -e "${GREEN}✔ 安装完成${PLAIN}"; pause
}

add_node() {
    if [[ ! -f "$SB_BIN" ]] && ! command -v sing-box &>/dev/null; then
        echo -e "${RED}✘ 未检测到 sing-box，请先安装！${PLAIN}"; pause; return; fi

    clear
    echo -e "${YELLOW}--- 添加节点配置 ---${PLAIN}"
    echo " 1. VLESS + Reality"
    echo " 2. TUIC v5"
    echo " 3. Hysteria2"
    echo " 4. Shadowsocks"
    echo " 5. VLESS + WS + CF"
    echo " 6. Socks5"
    echo " 7. HTTPS Proxy"
    echo " 8. Trojan"
    echo " 9. AnyTLS"
    echo " 0. 返回"
    read -p "请选择 [0-9]: " choice
    [[ "$choice" == "0" || -z "$choice" ]] && return

    local IP UUID LINK TAG
    IP=$(get_ip)
    UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    
    # 修复：使用 hex 直接生成 16 位字符，避免 tr 过滤导致的长度不足和程序阻塞
    gen_pass() { openssl rand -hex 8; } 

    case $choice in
        1) # VLESS + Reality
            read -p "端口 (默认 443): " PORT; PORT=${PORT:-443}
            if ! check_port "$PORT"; then pause; return; fi
            read -p "目标 SNI (默认 music.apple.com): " SNI; SNI=${SNI:-"music.apple.com"}
            TAG="reality-${PORT}"
            local KEYS PRIVATE PUBLIC SID
            KEYS=$($SB_BIN generate reality-keypair)
            PRIVATE=$(echo "$KEYS" | awk -F': ' '/Private/{print $2}' | tr -d '[:space:]')
            PUBLIC=$(echo "$KEYS"  | awk -F': ' '/Public/{print $2}'  | tr -d '[:space:]')
            SID=$(openssl rand -hex 8)
            make_tmp
            jq --arg port "$PORT" --arg uuid "$UUID" --arg sni "$SNI" \
               --arg priv "$PRIVATE" --arg sid "$SID" --arg tag "$TAG" \
               '.inbounds += [{"type":"vless","tag":$tag,"listen":"::","listen_port":($port|tonumber),
                 "users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],
                 "tls":{"enabled":true,"server_name":$sni,
                   "reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},
                     "private_key":$priv,"short_id":[$sid]}}}]' \
               "$CONFIG_FILE" > "$_TMP_JSON"
            LINK="vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SID&type=tcp&flow=xtls-rprx-vision#$TAG"
            ;;

        2|3|7|8) # 需要证书的协议
            local p_type def_p usr_json tls_json PASS SNI_NAME ALLOW_INS
            case $choice in
                2) p_type="tuic";     def_p=8443 ;;
                3) p_type="hysteria2";def_p=443  ;;
                7) p_type="http";     def_p=443  ;;
                8) p_type="trojan";   def_p=443  ;;
            esac
            read -p "端口 (默认 $def_p): " PORT; PORT=${PORT:-$def_p}
            if ! check_port "$PORT"; then pause; return; fi
            read -p "密码 (回车随机生成): " PASS; PASS=${PASS:-$(gen_pass)}
            TAG="${p_type}-${PORT}"

            echo -e "\n----------------------------------------"
            # 安全修复：对于 TCP 协议增加自签名证书高危警告
            if [[ "$p_type" == "trojan" || "$p_type" == "http" ]]; then
                echo -e "${YELLOW}⚠️ 警告: [$p_type] 属于 TCP 协议！${PLAIN}"
                echo -e "${YELLOW}在公网使用自签名证书极易被防火墙特征识别并秒封 IP！${PLAIN}"
                echo -e "${YELLOW}👉 强烈建议优先选择 [2. 自动检测 ACME 证书]${PLAIN}"
            fi
            
            echo " 1. 自签名证书  2. 自动检测 ACME 证书 ($CERT_DIR)"
            read -p "证书类型: " c_choice
            if [[ "$c_choice" == "2" ]]; then
                read -p "对应域名: " domain; find_certs "$domain"
                [[ -z "$CERT_PATH" ]] && echo -e "${RED}✘ 未找到证书${PLAIN}" && pause && return
                SNI_NAME="$domain"; ALLOW_INS=0
            else
                CERT_PATH="/etc/sing-box/${p_type}.crt"; KEY_PATH="/etc/sing-box/${p_type}.key"
                [[ ! -f "$CERT_PATH" ]] && openssl req -x509 -nodes \
                    -newkey ec:<(openssl ecparam -name prime256v1) \
                    -keyout "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=icloud.com" -days 3650 2>/dev/null
                SNI_NAME="icloud.com"; ALLOW_INS=1
            fi

            tls_json="{\"enabled\":true,\"certificate_path\":\"$CERT_PATH\",\"key_path\":\"$KEY_PATH\"}"
            case "$p_type" in
                tuic)
                    usr_json="[{\"uuid\":\"$UUID\",\"password\":\"$PASS\"}]"
                    tls_json="{\"enabled\":true,\"certificate_path\":\"$CERT_PATH\",\"key_path\":\"$KEY_PATH\",\"alpn\":[\"h3\"]}"
                    LINK="tuic://$UUID:$PASS@$IP:$PORT?sni=$SNI_NAME&alpn=h3&allow_insecure=$ALLOW_INS&congestion_control=bbr#$TAG" ;;
                hysteria2)
                    usr_json="[{\"password\":\"$PASS\"}]"
                    LINK="hysteria2://$PASS@$IP:$PORT?insecure=$ALLOW_INS&sni=$SNI_NAME#$TAG" ;;
                trojan)
                    usr_json="[{\"password\":\"$PASS\"}]"
                    LINK="trojan://$PASS@$IP:$PORT?security=tls&sni=$SNI_NAME&allowInsecure=$ALLOW_INS#$TAG" ;;
                http)
                    usr_json="[{\"username\":\"$PASS\",\"password\":\"$PASS\"}]"
                    LINK="https://$PASS:$PASS@$IP:$PORT?security=tls&sni=$SNI_NAME&allowInsecure=$ALLOW_INS#$TAG" ;;
            esac
            make_tmp
            jq --arg port "$PORT" --arg type "$p_type" --arg tag "$TAG" \
               --argjson users "$usr_json" --argjson tls "$tls_json" \
               '.inbounds += [{"type":$type,"tag":$tag,"listen":"::","listen_port":($port|tonumber),
                 "users":$users,"tls":$tls}]' \
               "$CONFIG_FILE" > "$_TMP_JSON"
            ;;

        4) # Shadowsocks 2022
            read -p "端口 (默认 8388): " PORT; PORT=${PORT:-8388}
            if ! check_port "$PORT"; then pause; return; fi
            local PASS METHOD
            PASS=$(openssl rand -base64 16); METHOD="2022-blake3-aes-128-gcm"; TAG="ss-${PORT}"
            make_tmp
            jq --arg port "$PORT" --arg pass "$PASS" --arg method "$METHOD" --arg tag "$TAG" \
               '.inbounds += [{"type":"shadowsocks","tag":$tag,"listen":"::","listen_port":($port|tonumber),
                 "method":$method,"password":$pass}]' \
               "$CONFIG_FILE" > "$_TMP_JSON"
            LINK="ss://$(echo -n "$METHOD:$PASS" | base64 -w 0)@$IP:$PORT#$TAG"
            ;;

        5) # VLESS + WS + CF
            read -p "域名: " domain; find_certs "$domain"
            [[ -z "$CERT_PATH" ]] && echo -e "${RED}✘ 证书不存在${PLAIN}" && pause && return
            read -p "端口 (默认 443): " PORT; PORT=${PORT:-443}
            if ! check_port "$PORT"; then pause; return; fi
            
            # 安全修复：使用 openssl 生成真随机 6 位路径
            local rand_path="/$(openssl rand -hex 3)"
            read -p "WS 路径 (默认 $rand_path): " WSPATH; WSPATH=${WSPATH:-"$rand_path"}
            
            TAG="vless-ws-${PORT}"
            make_tmp
            jq --arg port "$PORT" --arg uuid "$UUID" --arg path "$WSPATH" \
               --arg domain "$domain" --arg tag "$TAG" \
               --arg cert "$CERT_PATH" --arg key "$KEY_PATH" \
               '.inbounds += [{"type":"vless","tag":$tag,"listen":"::","listen_port":($port|tonumber),
                 "users":[{"uuid":$uuid}],
                 "transport":{"type":"ws","path":$path},
                 "tls":{"enabled":true,"server_name":$domain,
                   "certificate_path":$cert,"key_path":$key}}]' \
               "$CONFIG_FILE" > "$_TMP_JSON"
            LINK="vless://$UUID@$domain:$PORT?encryption=none&security=tls&type=ws&path=${WSPATH//\//%2F}#$TAG"
            ;;

        6) # Socks5
            read -p "端口: " PORT
            if ! check_port "$PORT"; then pause; return; fi
            read -p "用户名: " USER; read -p "密码: " PASS; TAG="socks-${PORT}"
            make_tmp
            jq --arg port "$PORT" --arg user "$USER" --arg pass "$PASS" --arg tag "$TAG" \
               '.inbounds += [{"type":"socks","tag":$tag,"listen":"::","listen_port":($port|tonumber),
                 "users":[{"username":$user,"password":$pass}]}]' \
               "$CONFIG_FILE" > "$_TMP_JSON"
            LINK="socks5://$USER:$PASS@$IP:$PORT#$TAG"
            ;;
            
        9) # AnyTLS
            read -p "端口 (默认 443): " PORT; PORT=${PORT:-443}
            if ! check_port "$PORT"; then pause; return; fi
            read -p "密码 (回车随机生成): " PASS; PASS=${PASS:-$(gen_pass)}
            TAG="anytls-${PORT}"

            echo -e "\n----------------------------------------"
            # 安全修复：AnyTLS 自签警告
            echo -e "${YELLOW}⚠️ 警告: [AnyTLS] 属于 TCP 协议！${PLAIN}"
            echo -e "${YELLOW}在公网使用自签名证书极易被防火墙特征识别并秒封 IP！${PLAIN}"
            echo -e "${YELLOW}👉 强烈建议优先选择 [2. 自动检测 ACME 证书]${PLAIN}"
            
            echo " 1. 自签名证书  2. 自动检测 ACME 证书 ($CERT_DIR)"
            read -p "证书类型: " c_choice
            if [[ "$c_choice" == "2" ]]; then
                read -p "对应域名: " domain; find_certs "$domain"
                [[ -z "$CERT_PATH" ]] && echo -e "${RED}✘ 未找到证书${PLAIN}" && pause && return
                SNI_NAME="$domain"; ALLOW_INS=0
            else
                CERT_PATH="/etc/sing-box/anytls.crt"; KEY_PATH="/etc/sing-box/anytls.key"
                [[ ! -f "$CERT_PATH" ]] && openssl req -x509 -nodes \
                    -newkey ec:<(openssl ecparam -name prime256v1) \
                    -keyout "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=icloud.com" -days 3650 2>/dev/null
                SNI_NAME="icloud.com"; ALLOW_INS=1
            fi

            make_tmp
            jq --arg port "$PORT" --arg pass "$PASS" --arg tag "$TAG" \
               --arg sni "$SNI_NAME" --arg cert "$CERT_PATH" --arg key "$KEY_PATH" \
               '.inbounds += [{"type":"anytls","tag":$tag,"listen":"::","listen_port":($port|tonumber),
                 "users":[{"name":"default_user","password":$pass}],
                 "tls":{"enabled":true,"server_name":$sni,"certificate_path":$cert,"key_path":$key}}]' \
               "$CONFIG_FILE" > "$_TMP_JSON"
            
            LINK="anytls://${PASS}@${IP}:${PORT}?sni=${SNI_NAME}&allow_insecure=${ALLOW_INS}#${TAG}"
            ;;
    esac

    if [[ -n "$_TMP_JSON" && -f "$_TMP_JSON" ]]; then
        if save_and_restart; then
            [[ -n "$LINK" ]] && echo "$LINK" > "$LINK_DIR/${TAG}.link"
            refresh_sub
            echo -e "${GREEN}✔ 节点添加成功！${PLAIN}"
            echo -e "分享链接:\n${BLUE}$LINK${PLAIN}"
        fi
    fi
    pause
}

manage_configs() {
    clear
    echo -e "${YELLOW}--- 节点配置查看 ---${PLAIN}"
    local count; count=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [[ "$count" -eq 0 ]]; then echo "暂无入站节点"; pause; return; fi

    jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | cat -n
    read -p "请选择序号 (q返回): " idx
    [[ "$idx" == "q" ]] && return
    if ! validate_index "$idx" "$count"; then pause; return; fi

    local TAG CONF TYPE PORT IP SNI HOST
    TAG=$(jq -r ".inbounds[$((idx-1))].tag"  "$CONFIG_FILE")
    CONF=$(jq -c ".inbounds[$((idx-1))]"      "$CONFIG_FILE")
    TYPE=$(echo "$CONF" | jq -r .type)
    PORT=$(echo "$CONF" | jq -r .listen_port)
    IP=$(get_ip)

    echo -e "\n${GREEN}================ 原始 JSON 配置 ================${PLAIN}"
    echo "$CONF" | jq .
    echo -e "${GREEN}===============================================${PLAIN}"
    echo -e "\n${YELLOW}>>>> 节点分享链接 <<<<${PLAIN}"

    # ================== 新增：Cloudflare CDN 入站优选拦截 ==================
    local IS_CDN_VLESS=false
    if [[ "$TYPE" == "vless" ]]; then
        local SID; SID=$(echo "$CONF" | jq -r '.tls.reality.short_id[0] // ""')
        local WSPATH; WSPATH=$(echo "$CONF" | jq -r '.transport.path // ""')
        if [[ -z "$SID" && -n "$WSPATH" ]]; then
            IS_CDN_VLESS=true
        fi
    fi

    if [[ "$IS_CDN_VLESS" == "true" ]]; then
        read -p "提示：检测到该节点为 WebSocket 节点，是否启用 Cloudflare 入站优选生成链接？(y/N): " choice_cf
        if [[ "${choice_cf,,}" == "y" ]]; then
            echo -e "\n------------------------------------------------"
            echo -e "请选择要注入客户端的 Cloudflare 优选 CNAME 方案："
            echo -e "  ${GREEN}1.${PLAIN} 自动轮询方案 (推荐: 汇聚多方测速，每15分钟动态更新)"
            echo -e "  ${GREEN}2.${PLAIN} 台湾全网优化方案 (适配各大运营商优质节点)"
            echo -e "------------------------------------------------"
            read -p "请选择 [1-2, 默认1]: " cname_choice
            
            local target_server="cf.090227.xyz"
            [[ "$cname_choice" == "2" ]] && target_server="icook.tw"
            
            local UUID; UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
            SNI=$(echo "$CONF" | jq -r '.tls.server_name // ""')
            WSPATH=$(echo "$CONF" | jq -r '.transport.path // ""')
            
            # 核心调包点：拼接优选链接
            local CF_LINK="vless://$UUID@$target_server:$PORT?encryption=none&security=tls&type=ws&host=$SNI&sni=$SNI&path=$WSPATH#${TAG}-CF优选入站"
            
            echo -e "\n${GREEN}✔ 优选配置生成成功！${PLAIN}"
            echo -e "${BLUE}${CF_LINK}${PLAIN}"
            
            # 修复核心：将生成的优选链接覆盖写入 .link 文件，使得一键订阅可以读取到
            mkdir -p "$LINK_DIR"
            echo "$CF_LINK" > "$LINK_DIR/${TAG}.link"
            echo -e "${YELLOW}>> 提示：该优选链接已成功保存，您的一键订阅现已更新！ <<${PLAIN}"

            echo ""; pause; return
        fi
    fi
    # =====================================================================
    if [[ -f "$LINK_DIR/${TAG}.link" ]]; then
        echo -e "${BLUE}$(cat "$LINK_DIR/${TAG}.link")${PLAIN}"
    else
        echo -e "${RED}未找到持久化链接文件，尝试从配置生成...${PLAIN}"
        SNI=$(echo "$CONF" | jq -r '.tls.server_name // ""')
        HOST=${SNI:-$IP}
        case $TYPE in
            vless)
                local UUID; UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                local SID;  SID=$(echo  "$CONF" | jq -r '.tls.reality.short_id[0] // ""')
                if [[ -n "$SID" ]]; then
                    echo -e "${RED}Reality 节点公钥 (pbk) 未存储于 config.json。${PLAIN}"
                    echo -e "${YELLOW}请查看 $LINK_DIR/${TAG}.link，或删除重建该节点. ${PLAIN}"
                else
                    local WSPATH; WSPATH=$(echo "$CONF" | jq -r '.transport.path // ""')
                    echo -e "${BLUE}vless://$UUID@$HOST:$PORT?encryption=none&security=tls&type=ws&host=$SNI&path=$WSPATH#$TAG${PLAIN}"
                fi ;;
            tuic)
                local UUID PASS
                UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                PASS=$(echo "$CONF" | jq -r '.users[0].password')
                echo -e "${BLUE}tuic://$UUID:$PASS@$HOST:$PORT?congestion_control=bbr&sni=$SNI&alpn=h3#$TAG${PLAIN}" ;;
            hysteria2)
                local PASS; PASS=$(echo "$CONF" | jq -r '.users[0].password')
                echo -e "${BLUE}hysteria2://$PASS@$HOST:$PORT?sni=$SNI#$TAG${PLAIN}" ;;
            shadowsocks)
                local METHOD PASS
                METHOD=$(echo "$CONF" | jq -r .method)
                PASS=$(echo   "$CONF" | jq -r .password)
                echo -e "${BLUE}ss://$(echo -n "$METHOD:$PASS" | base64 -w 0)@$IP:$PORT#$TAG${PLAIN}" ;;
            anytls)
                local PASS; PASS=$(echo "$CONF" | jq -r '.users[0].password // ""')
                local INS;  INS=$(echo  "$CONF" | jq -r '.tls.insecure // false')
                local IV=0; [[ "$INS" == "true" ]] && IV=1
                echo -e "${BLUE}anytls://$PASS@$HOST:$PORT?sni=$SNI&insecure=$IV#$TAG${PLAIN}" ;;
            http)
                local USER PASS
                USER=$(echo "$CONF" | jq -r '.users[0].username // ""')
                PASS=$(echo "$CONF" | jq -r '.users[0].password // ""')
                [[ -n "$USER" ]] && echo -e "${BLUE}https://$USER:$PASS@$HOST:$PORT#$TAG${PLAIN}" \
                                 || echo -e "${BLUE}https://$HOST:$PORT#$TAG${PLAIN}" ;;
            trojan)
                local PASS; PASS=$(echo "$CONF" | jq -r '.users[0].password // ""')
                local INS;  INS=$(echo  "$CONF" | jq -r '.tls.insecure // false')
                local IV=0; [[ "$INS" == "true" ]] && IV=1
                echo -e "${BLUE}trojan://$PASS@$HOST:$PORT?security=tls&sni=$SNI&allowInsecure=$IV#$TAG${PLAIN}" ;;
            *) echo -e "${RED}暂不支持该协议 ($TYPE) 的链接还原${PLAIN}" ;;
        esac
    fi
    echo ""; pause
}

edit_node() {
    if [[ ! -f "$SB_BIN" ]] && ! command -v sing-box &>/dev/null; then
        echo -e "${RED}✘ 未检测到 sing-box，请先安装${PLAIN}"; pause; return; fi

    clear
    echo -e "${YELLOW}--- 修改/删除节点配置 ---${PLAIN}"
    local count; count=$(jq '.inbounds | length' "$CONFIG_FILE")
    [[ "$count" -eq 0 ]] && echo "暂无入站节点" && pause && return

    jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | cat -n
    read -p "请选择序号 (q返回): " idx
    [[ "$idx" == "q" || -z "$idx" ]] && return
    if ! validate_index "$idx" "$count"; then pause; return; fi

    local i=$((idx-1))
    local TAG; TAG=$(jq -r ".inbounds[$i].tag"  "$CONFIG_FILE")
    local TYPE;TYPE=$(jq -r ".inbounds[$i].type" "$CONFIG_FILE")
    [[ "$TAG" == "null" ]] && echo -e "${RED}选择无效${PLAIN}" && pause && return

    echo -e "\n${CYAN}当前节点: $TAG ($TYPE)${PLAIN}"
    echo "1. 修改端口"
    echo "2. 修改 UUID / 密码"
    echo "3. 修改 SNI"
    echo "4. 删除此节点 (自动清理关联路由)"
    echo "0. 返回"
    read -p "请选择操作: " op

    case $op in
        1)
            read -p "新端口: " NEW_PORT; [[ -z "$NEW_PORT" ]] && return
            if ! check_port "$NEW_PORT"; then pause; return; fi
            make_tmp
            jq ".inbounds[$i].listen_port = ($NEW_PORT|tonumber)" "$CONFIG_FILE" > "$_TMP_JSON"
            ;;
        2)
            # [F10] TUIC 同时有 uuid 和 password，分别处理
            if [[ "$TYPE" == "tuic" ]]; then
                read -p "新 UUID (回车跳过): " NEW_UUID
                read -p "新密码   (回车跳过): " NEW_PASS
                [[ -z "$NEW_UUID" && -z "$NEW_PASS" ]] && return
                make_tmp
                local JQ_F="."
                [[ -n "$NEW_UUID" ]] && JQ_F="$JQ_F | .inbounds[$i].users[0].uuid     = \"$NEW_UUID\""
                [[ -n "$NEW_PASS" ]] && JQ_F="$JQ_F | .inbounds[$i].users[0].password = \"$NEW_PASS\""
                jq "$JQ_F" "$CONFIG_FILE" > "$_TMP_JSON"
            else
                local AUTH_FIELD=".users[0].uuid"
                [[ "$TYPE" =~ ^(trojan|hysteria2|http)$ ]] && AUTH_FIELD=".users[0].password"
                [[ "$TYPE" == "shadowsocks" ]]              && AUTH_FIELD=".password"
                read -p "新凭证: " NEW_AUTH; [[ -z "$NEW_AUTH" ]] && return
                make_tmp
                jq ".inbounds[$i]$AUTH_FIELD = \"$NEW_AUTH\"" "$CONFIG_FILE" > "$_TMP_JSON"
            fi
            ;;
        3)
            read -p "新 SNI: " NEW_SNI; [[ -z "$NEW_SNI" ]] && return
            make_tmp
            jq ".inbounds[$i].tls.server_name = \"$NEW_SNI\" |
                if .inbounds[$i].tls.reality then
                    .inbounds[$i].tls.reality.handshake.server = \"$NEW_SNI\"
                else . end" "$CONFIG_FILE" > "$_TMP_JSON"
            ;;
        4)
            read -p "确定删除 $TAG 及关联路由？(y/n): " confirm
            [[ "$confirm" != "y" ]] && return
            make_tmp
            jq --arg tag "$TAG" '
                (if .route.rules then del(.route.rules[] | select(
                    .inbound == $tag or
                    ((.inbound|type)=="array" and (.inbound|any(.==$tag)))
                )) else . end) |
                del(.inbounds[] | select(.tag == $tag))
            ' "$CONFIG_FILE" > "$_TMP_JSON"
            if save_and_restart; then
                rm -f "$LINK_DIR/${TAG}.link"
                refresh_sub
                echo -e "${GREEN}✔ 节点及关联路由已删除${PLAIN}"
            fi
            pause; return
            ;;
        *) return ;;
    esac

    if [[ -n "$_TMP_JSON" && -f "$_TMP_JSON" ]]; then
        if save_and_restart; then
            echo -e "${GREEN}✔ 配置已更新！${PLAIN}"
            local CONF PORT IP SNI NEW_LINK
            CONF=$(jq -c ".inbounds[] | select(.tag == \"$TAG\")" "$CONFIG_FILE")
            [[ -z "$CONF" ]] && pause && return
            PORT=$(echo "$CONF" | jq -r .listen_port)
            IP=$(get_ip)
            SNI=$(echo "$CONF" | jq -r '.tls.server_name // ""')

            case $TYPE in
                vless)
                    local UUID SID FLOW
                    UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                    SID=$(echo  "$CONF" | jq -r '.tls.reality.short_id[0] // ""')
                    FLOW=$(echo "$CONF" | jq -r '.users[0].flow // ""')
                    if [[ -n "$SID" ]]; then
                        # [F07] 从旧 .link 文件读取 pbk，避免丢失
                        local OLD_PBK=""
                        [[ -f "$LINK_DIR/${TAG}.link" ]] && \
                            OLD_PBK=$(grep -oP '(?<=pbk=)[^&]+' "$LINK_DIR/${TAG}.link" 2>/dev/null || true)
                        if [[ -n "$OLD_PBK" ]]; then
                            NEW_LINK="vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$OLD_PBK&sid=$SID&type=tcp&flow=$FLOW#$TAG"
                        else
                            echo -e "${YELLOW}⚠ 无法获取 Reality 公钥，建议删除重建节点。${PLAIN}"
                        fi
                    else
                        local WSPATH; WSPATH=$(echo "$CONF" | jq -r '.transport.path // ""')
                        NEW_LINK="vless://$UUID@${SNI:-$IP}:$PORT?encryption=none&security=tls&type=ws&host=$SNI&path=$WSPATH#$TAG"
                    fi ;;
                trojan)
                    local PASS; PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    NEW_LINK="trojan://$PASS@$IP:$PORT?security=tls&sni=$SNI&allowInsecure=1#$TAG" ;;
                hysteria2)
                    local PASS; PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    NEW_LINK="hysteria2://$PASS@$IP:$PORT?sni=$SNI&insecure=1#$TAG" ;;
                tuic)
                    local UUID PASS
                    UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                    PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    NEW_LINK="tuic://$UUID:$PASS@$IP:$PORT?congestion_control=bbr&sni=$SNI&alpn=h3&allow_insecure=1#$TAG" ;;
                shadowsocks)
                    local METHOD PASS
                    METHOD=$(echo "$CONF" | jq -r .method)
                    PASS=$(echo   "$CONF" | jq -r .password)
                    NEW_LINK="ss://$(echo -n "$METHOD:$PASS" | base64 -w 0)@$IP:$PORT#$TAG" ;;
            esac
            if [[ -n "$NEW_LINK" ]]; then
                echo "$NEW_LINK" > "$LINK_DIR/${TAG}.link"
                echo -e "新分享链接:\n${BLUE}$NEW_LINK${PLAIN}"
            fi
        fi
    fi
    pause
}

# ==============================================================
# parse_proxy_link — 全协议解析
# 支持: ss:// socks5:// https:// vless:// trojan:// hysteria2:// hy2:// tuic://
# 输出全局变量: hop_type R_ADDR R_PORT R_PASS R_USER R_METHOD
#               R_UUID R_SNI R_FLOW R_PBK R_SID R_ALPN
#               R_TLS_INSECURE R_TRANSPORT R_WS_PATH R_NAME
# ==============================================================
parse_proxy_link() {
    local link=$1
    local content qs host_port user_info

    hop_type="" R_ADDR="" R_PORT="" R_PASS="" R_USER="" R_METHOD=""
    R_UUID="" R_SNI="" R_FLOW="" R_PBK="" R_SID="" R_ALPN=""
    R_TLS_INSECURE="0" R_TRANSPORT="tcp" R_WS_PATH="" R_NAME=""

    R_NAME=$(echo "$link" | grep -oP '(?<=#)[^#]*$' | _urldecode 2>/dev/null || true)

    if [[ "$link" =~ ^ss:// ]]; then
        hop_type=1
        content=$(echo "$link" | sed 's|ss://||' | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            local b64_part; b64_part=$(echo "$content" | cut -d'@' -f1)
            host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'/' -f1 | cut -d'?' -f1)
            local decoded; decoded=$(echo "$b64_part" | tr '_-' '/+' | \
                awk '{l=length($0)%4;if(l==2)$0=$0"==";else if(l==3)$0=$0"=";print}' | base64 -d 2>/dev/null)
            R_METHOD=$(echo "$decoded" | cut -d':' -f1)
            R_PASS=$(echo   "$decoded" | cut -d':' -f2-)
        else
            local decoded; decoded=$(echo "$content" | tr '_-' '/+' | \
                awk '{l=length($0)%4;if(l==2)$0=$0"==";else if(l==3)$0=$0"=";print}' | base64 -d 2>/dev/null)
            if [[ "$decoded" =~ ^(.+):(.+)@(.+):([0-9]+) ]]; then
                R_METHOD="${BASH_REMATCH[1]}"; R_PASS="${BASH_REMATCH[2]}"
                host_port="${BASH_REMATCH[3]}:${BASH_REMATCH[4]}"
            fi
        fi
        R_ADDR=$(echo "$host_port" | cut -d':' -f1)
        R_PORT=$(echo "$host_port" | cut -d':' -f2)

    elif [[ "$link" =~ ^socks5?:// ]]; then
        hop_type=2
        content=$(echo "$link" | sed 's|socks5\?://||' | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            user_info=$(echo "$content" | cut -d'@' -f1)
            host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'/' -f1 | cut -d'?' -f1)
            R_USER=$(echo "$user_info" | cut -d':' -f1)
            R_PASS=$(echo "$user_info" | cut -d':' -f2-)
        else
            host_port=$(echo "$content" | cut -d'/' -f1 | cut -d'?' -f1)
        fi
        R_ADDR=$(echo "$host_port" | cut -d':' -f1)
        R_PORT=$(echo "$host_port" | cut -d':' -f2)

    elif [[ "$link" =~ ^https:// ]]; then
        hop_type=3
        content=$(echo "$link" | sed 's|https://||' | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            user_info=$(echo "$content" | cut -d'@' -f1)
            host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'/' -f1 | cut -d'?' -f1)
            R_USER=$(echo "$user_info" | cut -d':' -f1)
            R_PASS=$(echo "$user_info" | cut -d':' -f2-)
        else
            host_port=$(echo "$content" | cut -d'/' -f1 | cut -d'?' -f1)
        fi
        R_ADDR=$(echo "$host_port" | cut -d':' -f1)
        R_PORT=$(echo "$host_port" | cut -d':' -f2)

    elif [[ "$link" =~ ^vless:// ]]; then
        hop_type=4
        content=$(echo "$link" | sed 's|vless://||' | cut -d'#' -f1)
        R_UUID=$(echo "$content" | cut -d'@' -f1)
        host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'?' -f1)
        qs=$(echo "$content" | grep -o '?.*' | cut -c2-)
        if [[ "$host_port" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
            R_ADDR="${BASH_REMATCH[1]}"; R_PORT="${BASH_REMATCH[2]}"
        else
            R_ADDR=$(echo "$host_port" | cut -d':' -f1)
            R_PORT=$(echo "$host_port" | cut -d':' -f2)
        fi
        R_SNI=$(_qs_get "$qs" "sni"); [[ -z "$R_SNI" ]] && R_SNI=$(_qs_get "$qs" "host")
        R_FLOW=$(_qs_get "$qs" "flow")
        R_PBK=$(_qs_get "$qs" "pbk")
        R_SID=$(_qs_get "$qs" "sid")
        R_TRANSPORT=$(_qs_get "$qs" "type"); R_TRANSPORT=${R_TRANSPORT:-tcp}
        R_WS_PATH=$(_qs_get "$qs" "path")
        local ins; ins=$(_qs_get "$qs" "allowInsecure")
        [[ "$ins" == "1" || "$ins" == "true" ]] && R_TLS_INSECURE="1"
        R_PASS="$R_UUID"

    elif [[ "$link" =~ ^trojan:// ]]; then
        hop_type=5
        content=$(echo "$link" | sed 's|trojan://||' | cut -d'#' -f1)
        R_PASS=$(echo "$content" | cut -d'@' -f1)
        host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'?' -f1)
        qs=$(echo "$content" | grep -o '?.*' | cut -c2-)
        if [[ "$host_port" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
            R_ADDR="${BASH_REMATCH[1]}"; R_PORT="${BASH_REMATCH[2]}"
        else
            R_ADDR=$(echo "$host_port" | cut -d':' -f1)
            R_PORT=$(echo "$host_port" | cut -d':' -f2)
        fi
        R_SNI=$(_qs_get "$qs" "sni"); [[ -z "$R_SNI" ]] && R_SNI=$(_qs_get "$qs" "host")
        R_TRANSPORT=$(_qs_get "$qs" "type"); R_TRANSPORT=${R_TRANSPORT:-tcp}
        R_WS_PATH=$(_qs_get "$qs" "path")
        local ins; ins=$(_qs_get "$qs" "allowInsecure")
        [[ "$ins" == "1" || "$ins" == "true" ]] && R_TLS_INSECURE="1"

    elif [[ "$link" =~ ^(hysteria2|hy2):// ]]; then
        hop_type=6
        content=$(echo "$link" | sed 's|hysteria2://||;s|hy2://||' | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            R_PASS=$(echo "$content" | cut -d'@' -f1)
            host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'?' -f1)
        else
            host_port=$(echo "$content" | cut -d'?' -f1)
        fi
        qs=$(echo "$content" | grep -o '?.*' | cut -c2-)
        if [[ "$host_port" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
            R_ADDR="${BASH_REMATCH[1]}"; R_PORT="${BASH_REMATCH[2]}"
        else
            R_ADDR=$(echo "$host_port" | cut -d':' -f1)
            R_PORT=$(echo "$host_port" | cut -d':' -f2)
        fi
        R_SNI=$(_qs_get "$qs" "sni")
        local ins; ins=$(_qs_get "$qs" "insecure")
        [[ "$ins" == "1" || "$ins" == "true" ]] && R_TLS_INSECURE="1"

    elif [[ "$link" =~ ^tuic:// ]]; then
        hop_type=7
        content=$(echo "$link" | sed 's|tuic://||' | cut -d'#' -f1)
        local auth_part; auth_part=$(echo "$content" | cut -d'@' -f1)
        host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'?' -f1)
        qs=$(echo "$content" | grep -o '?.*' | cut -c2-)
        R_UUID=$(echo "$auth_part" | cut -d':' -f1)
        R_PASS=$(echo "$auth_part" | cut -d':' -f2-)
        if [[ "$host_port" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
            R_ADDR="${BASH_REMATCH[1]}"; R_PORT="${BASH_REMATCH[2]}"
        else
            R_ADDR=$(echo "$host_port" | cut -d':' -f1)
            R_PORT=$(echo "$host_port" | cut -d':' -f2)
        fi
        R_SNI=$(_qs_get "$qs" "sni")
        R_ALPN=$(_qs_get "$qs" "alpn")
        local ins; ins=$(_qs_get "$qs" "allow_insecure")
        [[ "$ins" == "1" || "$ins" == "true" ]] && R_TLS_INSECURE="1"

    elif [[ "$link" =~ ^anytls:// ]]; then
        hop_type=8 # <-- 为 AnyTLS 分配新的 hop_type
        content=$(echo "$link" | sed 's|anytls://||' | cut -d'#' -f1)
        R_PASS=$(echo "$content" | cut -d'@' -f1)
        host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'?' -f1)
        qs=$(echo "$content" | grep -o '?.*' | cut -c2-)
        if [[ "$host_port" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
            R_ADDR="${BASH_REMATCH[1]}"; R_PORT="${BASH_REMATCH[2]}"
        else
            R_ADDR=$(echo "$host_port" | cut -d':' -f1)
            R_PORT=$(echo "$host_port" | cut -d':' -f2)
        fi
        R_SNI=$(_qs_get "$qs" "sni"); [[ -z "$R_SNI" ]] && R_SNI=$(_qs_get "$qs" "host")
        local ins; ins=$(_qs_get "$qs" "insecure")
        [[ "$ins" == "1" || "$ins" == "true" ]] && R_TLS_INSECURE="1"
    fi
}

# ==============================================================
# link_to_outbound_json — 把 parse_proxy_link 结果转为出站 JSON
# [F05] 修正 Socks5/HTTP jq 双对象 + 语法
# [F06] insecure 统一转为 jq boolean 字面量
# ==============================================================
link_to_outbound_json() {
    local tag=${1:-"node-$(date +%s)"}
    local ins_bool; ins_bool=$([[ "$R_TLS_INSECURE" == "1" ]] && echo "true" || echo "false")
    local json=""

    case "$hop_type" in
        1) # Shadowsocks
            json=$(jq -n \
                --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                --arg m "$R_METHOD" --arg pw "$R_PASS" \
                '{"type":"shadowsocks","tag":$t,"server":$s,
                  "server_port":($p|tonumber),"method":$m,"password":$pw}')
            ;;
        2) # Socks5 — [F05]
            if [[ -n "$R_USER" ]]; then
                json=$(jq -n \
                    --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                    --arg u "$R_USER" --arg pw "$R_PASS" \
                    '{"type":"socks","tag":$t,"server":$s,
                      "server_port":($p|tonumber),"version":"5",
                      "username":$u,"password":$pw}')
            else
                json=$(jq -n \
                    --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                    '{"type":"socks","tag":$t,"server":$s,
                      "server_port":($p|tonumber),"version":"5"}')
            fi
            ;;
        3) # HTTP/HTTPS 代理 — [F05][F06]
            if [[ -n "$R_USER" ]]; then
                json=$(jq -n \
                    --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                    --arg u "$R_USER" --arg pw "$R_PASS" \
                    --argjson ins "$ins_bool" \
                    '{"type":"http","tag":$t,"server":$s,
                      "server_port":($p|tonumber),
                      "username":$u,"password":$pw,
                      "tls":{"enabled":true,"insecure":$ins}}')
            else
                json=$(jq -n \
                    --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                    --argjson ins "$ins_bool" \
                    '{"type":"http","tag":$t,"server":$s,
                      "server_port":($p|tonumber),
                      "tls":{"enabled":true,"insecure":$ins}}')
            fi
            ;;
        4) # VLESS — [F06]
            local tls_obj transport_obj="null"
            if [[ -n "$R_PBK" ]]; then
                tls_obj=$(jq -n \
                    --arg sni "$R_SNI" --arg pbk "$R_PBK" --arg sid "$R_SID" \
                    --argjson ins "$ins_bool" \
                    '{"enabled":true,"server_name":$sni,"insecure":$ins,
                      "reality":{"enabled":true,"public_key":$pbk,"short_id":$sid}}')
            else
                tls_obj=$(jq -n \
                    --arg sni "$R_SNI" --argjson ins "$ins_bool" \
                    '{"enabled":true,"server_name":$sni,"insecure":$ins}')
            fi
            [[ "$R_TRANSPORT" == "ws"   ]] && transport_obj=$(jq -n --arg p "$R_WS_PATH" '{"type":"ws","path":$p}')
            [[ "$R_TRANSPORT" == "grpc" ]] && transport_obj=$(jq -n --arg p "$R_WS_PATH" '{"type":"grpc","service_name":$p}')
            if [[ -n "$R_FLOW" ]]; then
                json=$(jq -n \
                    --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                    --arg uuid "$R_UUID" --arg flow "$R_FLOW" \
                    --argjson tls "$tls_obj" --argjson tr "$transport_obj" \
                    '{"type":"vless","tag":$t,"server":$s,
                      "server_port":($p|tonumber),"uuid":$uuid,"flow":$flow,"tls":$tls}
                     + (if $tr != null then {"transport":$tr} else {} end)')
            else
                json=$(jq -n \
                    --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                    --arg uuid "$R_UUID" \
                    --argjson tls "$tls_obj" --argjson tr "$transport_obj" \
                    '{"type":"vless","tag":$t,"server":$s,
                      "server_port":($p|tonumber),"uuid":$uuid,"tls":$tls}
                     + (if $tr != null then {"transport":$tr} else {} end)')
            fi
            ;;
        5) # Trojan — [F06]
            local tls_obj transport_obj="null"
            tls_obj=$(jq -n --arg sni "$R_SNI" --argjson ins "$ins_bool" \
                '{"enabled":true,"server_name":$sni,"insecure":$ins}')
            [[ "$R_TRANSPORT" == "ws" ]] && transport_obj=$(jq -n --arg p "$R_WS_PATH" '{"type":"ws","path":$p}')
            json=$(jq -n \
                --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                --arg pw "$R_PASS" --argjson tls "$tls_obj" --argjson tr "$transport_obj" \
                '{"type":"trojan","tag":$t,"server":$s,
                  "server_port":($p|tonumber),"password":$pw,"tls":$tls}
                 + (if $tr != null then {"transport":$tr} else {} end)')
            ;;
        6) # Hysteria2 — [F06]
            local tls_obj
            tls_obj=$(jq -n --arg sni "$R_SNI" --argjson ins "$ins_bool" \
                '{"enabled":true,"server_name":$sni,"insecure":$ins}')
            json=$(jq -n \
                --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                --arg pw "$R_PASS" --argjson tls "$tls_obj" \
                '{"type":"hysteria2","tag":$t,"server":$s,
                  "server_port":($p|tonumber),"password":$pw,"tls":$tls}')
            ;;
        7) # TUIC — [F06]
            local alpn_json="[]"
            [[ -n "$R_ALPN" ]] && alpn_json=$(echo "$R_ALPN" | tr ',' '\n' | jq -R . | jq -s .)
            local tls_obj
            tls_obj=$(jq -n \
                --arg sni "$R_SNI" --argjson alpn "$alpn_json" --argjson ins "$ins_bool" \
                '{"enabled":true,"server_name":$sni,"insecure":$ins,"alpn":$alpn}')
            json=$(jq -n \
                --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                --arg uuid "$R_UUID" --arg pw "$R_PASS" --argjson tls "$tls_obj" \
                '{"type":"tuic","tag":$t,"server":$s,
                  "server_port":($p|tonumber),"uuid":$uuid,"password":$pw,
                  "congestion_control":"bbr","tls":$tls}')
            ;;
        8) # AnyTLS - 客户端/出站只需 password
            local tls_obj
            tls_obj=$(jq -n --arg sni "$R_SNI" --argjson ins "$ins_bool" \
                '{"enabled":true,"server_name":$sni,"insecure":$ins,"utls":{"enabled":true,"fingerprint":"chrome"}}')
            json=$(jq -n \
                --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                --arg pw "$R_PASS" --argjson tls "$tls_obj" \
                '{"type":"anytls","tag":$t,"server":$s,
                  "server_port":($p|tonumber),"password":$pw,"tls":$tls}')
            ;;
        *) echo ""; return 1 ;;
    esac
    echo "$json"
}

manage_routing() {
    local rt_choice IN_TAGS OUT_TAG OUT_JSON RULE_JSON
    local idx LOCAL_TAG RAW_LINK NEW_RULE_JSON

    while true; do
        clear
        echo -e "${YELLOW}================================================${PLAIN}"
        echo -e "${YELLOW}         路由分流与链式代理管理${PLAIN}"
        echo -e "${YELLOW}================================================${PLAIN}"
        echo -e "${CYAN}--- 常规网站分流 ---${PLAIN}"
        echo " 1. 添加分流规则"
        echo " 2. 查看当前分流规则"
        echo " 3. 删除特定分流规则"
        echo -e "\n${CYAN}--- 链式代理与跳板 ---${PLAIN}"
        echo " 4. 添加跳转节点 (链式代理)"
        echo " 5. 查看当前活跃链式链路"
        echo " 6. 重置入站规则 (恢复直连)"
        echo " 7. WireGuard 内网穿透与 DNS 劫持"
        echo "------------------------------------------------"
        echo " 0. 返回主菜单"
        echo "------------------------------------------------"
        read -p "请选择: " rt_choice

        case $rt_choice in
            1) # 添加分流规则
                echo -e "\n${CYAN}1. 选择来源入站:${PLAIN}"
                local in_count; in_count=$(jq '.inbounds | length' "$CONFIG_FILE")
                [[ "$in_count" -eq 0 ]] && echo -e "${RED}无入站配置${PLAIN}" && pause && continue
                jq -r '.inbounds | keys[] as $i | "\($i+1)) Tag: \(.[$i].tag) [\(.[$i].type)]"' "$CONFIG_FILE"
                read -p "序号 (逗号隔开, 回车=全部): " in_idxs

                if [[ -z "$in_idxs" ]]; then
                    IN_TAGS="null"
                else
                    local invalid=0
                    while IFS= read -r i; do
                        validate_index "$i" "$in_count" 2>/dev/null || invalid=1
                    done < <(echo "$in_idxs" | tr ',' '\n')
                    [[ "$invalid" -eq 1 ]] && pause && continue
                    IN_TAGS=$(echo "$in_idxs" | tr ',' '\n' | while read -r i; do
                        jq -r ".inbounds[$((i-1))].tag" "$CONFIG_FILE"
                    done | jq -R . | jq -s . -c)
                fi

                echo -e "\n${CYAN}2. 匹配目标:${PLAIN}"
                echo "1) 全部流量 | 2) 域名 | 3) GeoSite | 4) IP/CIDR"
                read -p "选择 [1-4]: " target_type
                local RULE_PART="{}"
                case $target_type in
                    2) read -p "域名: " val; RULE_PART=$(echo "$val" | tr ',' '\n' | jq -R . | jq -s '{"domain":.}' -c) ;;
                    3) read -p "GeoSite: " val; RULE_PART=$(echo "$val" | tr ',' '\n' | jq -R . | jq -s '{"geosite":.}' -c) ;;
                    4) read -p "IP/CIDR: " val; RULE_PART=$(echo "$val" | tr ',' '\n' | jq -R . | jq -s '{"ip_cidr":.}' -c) ;;
                esac

                echo -e "\n${CYAN}3. 目标出站:${PLAIN}"
                echo "1) 粘贴链接 | 2) 手动输入 | 3) 自动优选 | 4) 轮询分流"
                read -p "选择 [1-4]: " out_mode
                OUT_TAG="route-out-$(date +%s)"; OUT_JSON=""

                if [[ "$out_mode" == "1" ]]; then
                    # [F08] 全协议解析
                    read -p "链接: " RAW_LINK
                    parse_proxy_link "$RAW_LINK"
                    if [[ -z "$R_ADDR" ]]; then
                        echo -e "${RED}✘ 链接解析失败${PLAIN}"; pause; continue; fi
                    OUT_JSON=$(link_to_outbound_json "$OUT_TAG")
                    if [[ -z "$OUT_JSON" ]]; then
                        echo -e "${RED}✘ 不支持的协议 (hop_type=$hop_type)${PLAIN}"; pause; continue; fi

                elif [[ "$out_mode" == "2" ]]; then
                    echo "1) SS  2) Socks5  3) HTTP/HTTPS"
                    read -p "协议: " h_type
                    read -p "地址: " R_ADDR; read -p "端口: " R_PORT
                    case $h_type in
                        1) read -p "加密: " R_METHOD; read -p "密码: " R_PASS; hop_type=1 ;;
                        2) read -p "用户: " R_USER; read -p "密码: " R_PASS; hop_type=2 ;;
                        3) read -p "用户: " R_USER; read -p "密码: " R_PASS
                           read -p "跳过证书验证? [y/N]: " _skip
                           [[ "$_skip" =~ ^[yY]$ ]] && R_TLS_INSECURE="1" || R_TLS_INSECURE="0"
                           hop_type=3 ;;
                        *) echo -e "${RED}无效协议${PLAIN}"; continue ;;
                    esac
                    OUT_JSON=$(link_to_outbound_json "$OUT_TAG")

                elif [[ "$out_mode" == "3" || "$out_mode" == "4" ]]; then
                    echo -e "\n${YELLOW}选择代理成员:${PLAIN}"
                    local ob_count
                    ob_count=$(jq '[.outbounds[] | select(.type!="direct" and .type!="dns" and .type!="block")] | length' "$CONFIG_FILE")
                    jq -r '[.outbounds[] | select(.type!="direct" and .type!="dns" and .type!="block")] |
                        keys[] as $i | "\($i+1)) [\(.[$i].type)] \(.[$i].tag)"' "$CONFIG_FILE"
                    read -p "序号 (逗号隔开): " m_idxs
                    [[ -z "$m_idxs" ]] && continue
                    local MEMBER_TAGS
                    MEMBER_TAGS=$(echo "$m_idxs" | tr ',' '\n' | while read -r i; do
                        jq -r ".outbounds[$((i-1))].tag" "$CONFIG_FILE"
                    done | jq -R . | jq -s . -c)
                    OUT_TAG="group-out-$(date +%s)"
                    if [[ "$out_mode" == "3" ]]; then
                        OUT_JSON=$(jq -n --arg t "$OUT_TAG" --argjson m "$MEMBER_TAGS" \
                            '{"type":"urltest","tag":$t,"outbounds":$m,
                              "url":"https://www.gstatic.com/generate_204","interval":"3m0s"}')
                    else
                        OUT_JSON=$(jq -n --arg t "$OUT_TAG" --argjson m "$MEMBER_TAGS" \
                            '{"type":"selector","tag":$t,"outbounds":$m}')
                    fi
                fi

                # [F13] 写入前保护：OUT_JSON 不能为空
                if [[ -z "$OUT_JSON" ]]; then
                    echo -e "${RED}✘ 出站配置为空，已取消${PLAIN}"; pause; continue; fi

                RULE_JSON=$(echo "$RULE_PART" | jq --arg ot "$OUT_TAG" --argjson it "$IN_TAGS" \
                    '. + {"outbound":$ot} + (if $it != null then {"inbound":$it} else {} end)' -c)

                make_tmp
                jq --argjson out_obj "$OUT_JSON" --argjson rule_obj "$RULE_JSON" \
                   '.outbounds += [$out_obj] | .route.rules = [$rule_obj] + .route.rules' \
                   "$CONFIG_FILE" > "$_TMP_JSON"
                save_and_restart && echo -e "${GREEN}✔ 分流规则添加成功！${PLAIN}" \
                                 || echo -e "${RED}✖ 语法检查失败！${PLAIN}"
                pause ;;

            2) # 查看规则
                echo -e "\n${CYAN}当前分流规则:${PLAIN}"
                jq -r '.route.rules | keys[] as $i |
                    "\($i+1)) [入站: \(.[$i].inbound // "全部")] -> [出站: \(.[$i].outbound)]"' "$CONFIG_FILE"
                pause ;;

            3) # 删除规则 — [F16] 用 map+index 替代 del($idxs[])，兼容性更好
                echo -e "\n${YELLOW}删除分流规则序号 (all=全部):${PLAIN}"
                jq -r '.route.rules | keys[] as $i | "\($i+1)) \(.[$i].outbound)"' "$CONFIG_FILE"
                read -p "> " d_choice

                local T1; T1=$(make_safe_tmp)
                local T2; T2=$(make_safe_tmp)

                if [[ "$d_choice" == "all" ]]; then
                    jq '.route.rules = [] |
                        .outbounds |= map(select(
                            .tag | (startswith("route-out-") or startswith("group-out-")) | not))' \
                        "$CONFIG_FILE" > "$T1" && mv "$T1" "$CONFIG_FILE" && rm -f "$T2"
                else
                    # 转为0-based索引数组
                    local del_idxs
                    del_idxs=$(echo "$d_choice" | tr ',' '\n' | \
                        grep -E '^[0-9]+$' | awk '{print $1-1}' | jq -R . | jq -s .)
                    jq --argjson dels "$del_idxs" \
                        '.route.rules = [.route.rules | to_entries[] |
                            select(.key as $k | ($dels | index($k)) == null) | .value]' \
                        "$CONFIG_FILE" > "$T1"
                    # 清理不再被规则引用的 route-out/group-out 出站
                    jq '.outbounds |= map(select(
                        ((.tag | (startswith("route-out-") or startswith("group-out-"))) | not) or
                        (.tag as $t | any(.route.rules[]; .outbound == $t))
                    ))' "$T1" > "$T2" && rm -f "$T1"
                    if $SB_BIN check -c "$T2" > /dev/null 2>&1; then
                        mv "$T2" "$CONFIG_FILE"
                    else
                        echo -e "${RED}✖ 语法检查失败，已取消！${PLAIN}"
                        rm -f "$T2"; pause; continue
                    fi
                fi
                systemctl restart sing-box && echo -e "${GREEN}✔ 规则已更新${PLAIN}"
                pause ;;

            4) # 链式代理
                clear
                echo -e "${YELLOW}━━━ 链式代理配置 ━━━${PLAIN}"
                echo -e "${CYAN}架构: 入站 ──▶ 跳板1 ──▶ [跳板2…] ──▶ 落地组 ──▶ 互联网${PLAIN}\n"

                # 步骤1：选入站
                echo -e "${YELLOW}[步骤1] 选择入站:${PLAIN}"
                local in_count; in_count=$(jq '.inbounds | length' "$CONFIG_FILE")
                [[ "$in_count" -eq 0 ]] && echo -e "${RED}无入站配置${PLAIN}" && pause && continue
                jq -r '.inbounds | keys[] as $i |
                    "  \($i+1)) \(.[$i].tag)  [\(.[$i].type):\(.[$i].listen_port)]"' "$CONFIG_FILE"
                read -p "序号: " idx; [[ -z "$idx" ]] && continue
                if ! validate_index "$idx" "$in_count"; then pause; continue; fi
                LOCAL_TAG=$(jq -r ".inbounds[$((idx-1))].tag" "$CONFIG_FILE")
                echo -e "  ✔ 入站: ${GREEN}$LOCAL_TAG${PLAIN}\n"

                # 步骤2：落地节点
                echo -e "${YELLOW}[步骤2] 配置落地节点（无 detour）:${PLAIN}"
                _list_base_outbounds() {
                    jq -r '[.outbounds[] | select(
                        .type!="direct" and .type!="dns" and
                        .type!="block" and .type!="urltest" and .type!="selector"
                    )] | keys[] as $i |
                    "  \($i+1)) [\(.[$i].type)] \(.[$i].tag)  \(.[$i].server // ""):\(.[$i].server_port // "")"' "$CONFIG_FILE"
                }
                _count_base_outbounds() {
                    jq '[.outbounds[] | select(
                        .type!="direct" and .type!="dns" and
                        .type!="block" and .type!="urltest" and .type!="selector"
                    )] | length' "$CONFIG_FILE"
                }
                _get_base_ob_tag() {
                    jq -r "[.outbounds[] | select(
                        .type!=\"direct\" and .type!=\"dns\" and
                        .type!=\"block\" and .type!=\"urltest\" and .type!=\"selector\"
                    )] | .[$(($1-1))].tag" "$CONFIG_FILE"
                }

                local base_out_count; base_out_count=$(_count_base_outbounds)
                [[ "$base_out_count" -eq 0 ]] && echo -e "${RED}✘ 无可用出站节点，请先添加${PLAIN}" && pause && continue
                _list_base_outbounds

                echo -e "\n  落地模式: A) 单节点  B) 自动优选  C) 轮询"
                read -p "  [A/B/C]: " land_mode; land_mode=${land_mode^^}

                local LAND_FINAL_TAG="" LAND_NEW_JSON="" member_tags_arr=()

                case "$land_mode" in
                    A)
                        read -p "  序号: " l_idx
                        if ! validate_index "$l_idx" "$base_out_count"; then pause; continue; fi
                        LAND_FINAL_TAG=$(_get_base_ob_tag "$l_idx")
                        echo -e "  ✔ 落地: ${GREEN}$LAND_FINAL_TAG${PLAIN}" ;;
                    B|C)
                        read -p "  序号 (逗号隔开，≥2个): " m_idxs; [[ -z "$m_idxs" ]] && continue
                        local bad=0
                        while IFS= read -r mi; do
                            mi=$(echo "$mi" | tr -d ' ')
                            if ! validate_index "$mi" "$base_out_count" 2>/dev/null; then
                                echo -e "${RED}  序号 $mi 无效${PLAIN}"; bad=1; break; fi
                            member_tags_arr+=( "$(_get_base_ob_tag "$mi")" )
                        done < <(echo "$m_idxs" | tr ',' '\n')
                        [[ "$bad" -eq 1 ]] && pause && continue
                        [[ ${#member_tags_arr[@]} -lt 2 ]] && echo -e "${RED}  至少选 2 个${PLAIN}" && pause && continue
                        local MEMBER_JSON
                        MEMBER_JSON=$(printf '%s\n' "${member_tags_arr[@]}" | jq -R . | jq -s .)
                        LAND_FINAL_TAG="land-$(date +%s)"
                        if [[ "$land_mode" == "B" ]]; then
                            read -p "  测速 URL (回车默认): " test_url; test_url=${test_url:-"https://www.gstatic.com/generate_204"}
                            read -p "  间隔 (回车=3m): " test_iv; test_iv=${test_iv:-"3m0s"}
                            read -p "  容差 ms (回车=50): " tol; tol=${tol:-50}
                            [[ ! "$tol" =~ ^[0-9]+$ ]] && tol=50
                            LAND_NEW_JSON=$(jq -n \
                                --arg t "$LAND_FINAL_TAG" --argjson m "$MEMBER_JSON" \
                                --arg url "$test_url" --arg iv "$test_iv" --argjson tol "$tol" \
                                '{"type":"urltest","tag":$t,"outbounds":$m,"url":$url,"interval":$iv,"tolerance":$tol}')
                            echo -e "  ✔ 自动优选: ${GREEN}$LAND_FINAL_TAG${PLAIN} (${#member_tags_arr[@]} 节点)"
                        else
                            LAND_NEW_JSON=$(jq -n \
                                --arg t "$LAND_FINAL_TAG" --argjson m "$MEMBER_JSON" \
                                '{"type":"selector","tag":$t,"outbounds":$m,"default":($m[0])}')
                            echo -e "  ✔ 轮询组: ${GREEN}$LAND_FINAL_TAG${PLAIN} (${#member_tags_arr[@]} 节点)"
                        fi ;;
                    *) echo -e "${RED}无效${PLAIN}"; pause; continue ;;
                esac

                # 步骤3：跳板
                echo -e "\n${YELLOW}[步骤3] 配置跳板（从靠近落地的一跳开始）:${PLAIN}"
                echo -e "  ${CYAN}先加离落地最近的跳板，最后加离入站最近的跳板${PLAIN}\n"
                local hop_tags=() hop_jsons=()
                local next_tag="$LAND_FINAL_TAG"

                while true; do
                    local hop_num=$(( ${#hop_tags[@]} + 1 ))
                    echo -e "  ${YELLOW}── 跳板 #$hop_num (detour → $next_tag) ──${PLAIN}"
                    echo "  1) 粘贴链接  2) 已有出站  3) 手动输入  0) 完成"
                    read -p "  选择: " hop_src
                    [[ "$hop_src" == "0" ]] && break

                    local CUR_HOP_TAG="" CUR_HOP_JSON=""

                    case "$hop_src" in
                        1)
                            read -p "  链接: " RAW_LINK
                            parse_proxy_link "$RAW_LINK"
                            [[ -z "$R_ADDR" ]] && echo -e "${RED}  解析失败${PLAIN}" && continue
                            local ns; ns=$(echo "$R_NAME" | tr ' ' '_' | tr -dc 'a-zA-Z0-9._-')
                            CUR_HOP_TAG="hop${hop_num}-${ns:-$(date +%s)}"
                            local raw_j; raw_j=$(link_to_outbound_json "$CUR_HOP_TAG")
                            [[ -z "$raw_j" ]] && echo -e "${RED}  不支持的协议${PLAIN}" && continue
                            CUR_HOP_JSON=$(echo "$raw_j" | jq --arg d "$next_tag" '. + {"detour":$d}')
                            ;;
                        2)
                            local ao_count
                            ao_count=$(jq '[.outbounds[] | select(.type!="direct" and .type!="dns" and .type!="block")] | length' "$CONFIG_FILE")
                            jq -r '[.outbounds[] | select(.type!="direct" and .type!="dns" and .type!="block")] |
                                keys[] as $i | "  \($i+1)) [\(.[$i].type)] \(.[$i].tag)  detour=\(.[$i].detour // "无")"' "$CONFIG_FILE"
                            read -p "  序号: " h_idx
                            if ! validate_index "$h_idx" "$ao_count"; then continue; fi
                            CUR_HOP_TAG=$(jq -r "[.outbounds[] | select(.type!=\"direct\" and .type!=\"dns\" and .type!=\"block\")] | .[$(($h_idx-1))].tag" "$CONFIG_FILE")
                            CUR_HOP_JSON=""   # 已有节点，写入阶段直接 patch detour
                            ;;
                        3)
                            # [F11][F17] 用局部变量名避免遮蔽全局 hop_type；手动输入前清除污染
                            echo "  1) SS  2) Socks5  3) HTTPS"
                            read -p "  协议: " _proto
                            R_ADDR=""; R_PORT=""; R_USER=""; R_PASS=""; R_METHOD=""; R_TLS_INSECURE="0"
                            read -p "  地址: " R_ADDR; read -p "  端口: " R_PORT
                            CUR_HOP_TAG="hop${hop_num}-$(date +%s)"
                            case "$_proto" in
                                1) read -p "  加密: " R_METHOD; read -p "  密码: " R_PASS; hop_type=1 ;;
                                2) read -p "  用户: " R_USER;   read -p "  密码: " R_PASS; hop_type=2 ;;
                                3) read -p "  用户: " R_USER;   read -p "  密码: " R_PASS
                                   read -p "  跳过证书验证? [y/N]: " _sk
                                   [[ "$_sk" =~ ^[yY]$ ]] && R_TLS_INSECURE="1" || R_TLS_INSECURE="0"
                                   hop_type=3 ;;
                                *) echo -e "${RED}无效协议${PLAIN}"; continue ;;
                            esac
                            local raw_j; raw_j=$(link_to_outbound_json "$CUR_HOP_TAG")
                            [[ -z "$raw_j" ]] && echo -e "${RED}  JSON 生成失败${PLAIN}" && continue
                            CUR_HOP_JSON=$(echo "$raw_j" | jq --arg d "$next_tag" '. + {"detour":$d}')
                            ;;
                        *) echo -e "${RED}无效输入${PLAIN}"; continue ;;
                    esac

                    [[ -z "$CUR_HOP_TAG" ]] && continue
                    hop_tags+=("$CUR_HOP_TAG"); hop_jsons+=("$CUR_HOP_JSON")
                    next_tag="$CUR_HOP_TAG"
                    local prev_label; [[ ${#hop_tags[@]} -eq 1 ]] && prev_label="$LAND_FINAL_TAG" || prev_label="${hop_tags[-2]}"
                    echo -e "  ✔ 跳板 #$hop_num: ${GREEN}$CUR_HOP_TAG${PLAIN} ──▶ detour→${YELLOW}$prev_label${PLAIN}\n"
                done

                [[ ${#hop_tags[@]} -eq 0 ]] && echo -e "${RED}✘ 至少需要一个跳板${PLAIN}" && pause && continue

                local FIRST_HOP_TAG="${hop_tags[-1]}"

                # 步骤4：写入
                echo -e "\n${YELLOW}[步骤4] 写入配置...${PLAIN}"
                echo -ne "  预览: ${BLUE}$LOCAL_TAG${PLAIN}"
                for (( i=${#hop_tags[@]}-1; i>=0; i-- )); do echo -ne " ──▶ ${GREEN}${hop_tags[$i]}${PLAIN}"; done
                echo -e " ──▶ ${YELLOW}$LAND_FINAL_TAG${PLAIN} ──▶ 互联网"

                NEW_RULE_JSON=$(jq -n --arg itag "$LOCAL_TAG" --arg otag "$FIRST_HOP_TAG" \
                    '{"inbound":[$itag],"outbound":$otag}')

                make_tmp; local TMP_CFG="$_TMP_JSON"
                cp "$CONFIG_FILE" "$TMP_CFG"

                [[ -n "$LAND_NEW_JSON" ]] && \
                    jq --argjson o "$LAND_NEW_JSON" '.outbounds += [$o]' "$TMP_CFG" > "${TMP_CFG}.t" && mv "${TMP_CFG}.t" "$TMP_CFG"

                for (( i=0; i<${#hop_tags[@]}; i++ )); do
                    local htag="${hop_tags[$i]}" hjson="${hop_jsons[$i]}"
                    local hdetour; [[ $i -eq 0 ]] && hdetour="$LAND_FINAL_TAG" || hdetour="${hop_tags[$((i-1))]}"
                    if [[ -n "$hjson" ]]; then
                        jq --argjson o "$hjson" '.outbounds += [$o]' \
                            "$TMP_CFG" > "${TMP_CFG}.t" && mv "${TMP_CFG}.t" "$TMP_CFG"
                    else
                        jq --arg tag "$htag" --arg det "$hdetour" \
                            '(.outbounds[] | select(.tag==$tag)) |= (.+{"detour":$det})' \
                            "$TMP_CFG" > "${TMP_CFG}.t" && mv "${TMP_CFG}.t" "$TMP_CFG"
                    fi
                done

                jq --argjson rule "$NEW_RULE_JSON" --arg itag "$LOCAL_TAG" \
                    '.route.rules = ([$rule] + [.route.rules[] | select(
                        if .inbound then
                            if (.inbound|type)=="array"
                            then (.inbound|contains([$itag]))|not
                            else .inbound!=$itag end
                        else true end
                    )])' "$TMP_CFG" > "${TMP_CFG}.t" && mv "${TMP_CFG}.t" "$TMP_CFG"

                if $SB_BIN check -c "$TMP_CFG" > /dev/null 2>&1; then
                    mv "$TMP_CFG" "$CONFIG_FILE"; _TMP_JSON=""
                    systemctl restart sing-box
                    echo -e "\n${GREEN}✔ 链式配置成功，共 ${#hop_tags[@]} 跳！${PLAIN}"
                    [[ "$land_mode" == "B" ]] && echo -e "  落地: ${CYAN}自动优选 (${#member_tags_arr[@]} 节点)${PLAIN}"
                    [[ "$land_mode" == "C" ]] && echo -e "  落地: ${CYAN}轮询组 (${#member_tags_arr[@]} 节点)${PLAIN}"
                else
                    echo -e "${RED}✖ 配置校验失败，已回滚${PLAIN}"
                    $SB_BIN check -c "$TMP_CFG" 2>&1 | head -20
                    rm -f "$TMP_CFG" "${TMP_CFG}.t"; _TMP_JSON=""
                fi
                pause ;;

            5) # 链路可视化
                clear; echo -e "${YELLOW}━━━ 当前链式链路 ━━━${PLAIN}\n"
                local rules_count; rules_count=$(jq '[.route.rules[] | select(.inbound!=null)] | length' "$CONFIG_FILE")
                if [[ "$rules_count" -eq 0 ]]; then echo -e "  暂无链式规则"; pause; continue; fi
                jq -r '.route.rules[] | select(.inbound!=null) |
                    "\(.inbound | if type=="array" then join(",") else . end)|\(.outbound)"' \
                    "$CONFIG_FILE" | while IFS='|' read -r inbound first_out; do
                    echo -e "  ${BLUE}入站: $inbound${PLAIN}"
                    echo -ne "  路径: ${GREEN}$first_out${PLAIN}"
                    local cur="$first_out" visited="$first_out" depth=0
                    while true; do
                        (( depth++ )); [[ $depth -gt 20 ]] && echo -ne " ${RED}[可能循环!]${PLAIN}" && break
                        local nxt; nxt=$(jq -r --arg t "$cur" \
                            '.outbounds[] | select(.tag==$t) | .detour // ""' "$CONFIG_FILE" 2>/dev/null | head -1)
                        [[ -z "$nxt" ]] && break
                        echo "$visited" | grep -qF "$nxt" && echo -ne " ──▶ ${RED}[$nxt ← 循环!]${PLAIN}" && break
                        visited="$visited $nxt"
                        local nt; nt=$(jq -r --arg t "$nxt" '.outbounds[] | select(.tag==$t) | .type' "$CONFIG_FILE" 2>/dev/null | head -1)
                        case "$nt" in
                            urltest)  echo -ne " ──▶ ${CYAN}$nxt[优选组]${PLAIN}" ;;
                            selector) echo -ne " ──▶ ${PURPLE}$nxt[轮询组]${PLAIN}" ;;
                            "")       echo -ne " ──▶ ${YELLOW}互联网${PLAIN}" ;;
                            *)        echo -ne " ──▶ ${GREEN}$nxt${PLAIN}" ;;
                        esac
                        cur="$nxt"
                    done
                    local members; members=$(jq -r --arg t "$cur" \
                        '.outbounds[] | select(.tag==$t) | .outbounds // [] | join(", ")' "$CONFIG_FILE" 2>/dev/null | head -1)
                    [[ -n "$members" ]] && echo -ne "\n  成员: ${YELLOW}$members${PLAIN}"
                    echo -e "\n"
                done
                pause ;;

            6) # 重置直连 — [F09]
                echo -e "\n${YELLOW}选择要恢复直连的入站:${PLAIN}"
                local in_tags; in_tags=$(jq -r '.route.rules[] | select(.inbound!=null) | .inbound |
                    if type=="array" then .[0] else . end' "$CONFIG_FILE")
                echo "$in_tags" | cat -n
                read -p "序号: " del_idx
                local DEL_IN_TAG; DEL_IN_TAG=$(echo "$in_tags" | sed -n "${del_idx}p")
                if [[ -n "$DEL_IN_TAG" ]]; then
                    local T_RST; T_RST=$(make_safe_tmp)
                    jq --arg itag "$DEL_IN_TAG" '
                        .route.rules |= map(
                            if (if .inbound|type=="array"
                                then .inbound|contains([$itag])
                                else .inbound==$itag end)
                            then .outbound="direct" else . end)
                    ' "$CONFIG_FILE" > "$T_RST"
                    if $SB_BIN check -c "$T_RST" > /dev/null 2>&1; then
                        mv "$T_RST" "$CONFIG_FILE"
                        systemctl restart sing-box
                        echo -e "${GREEN}✔ [$DEL_IN_TAG] 已恢复直连${PLAIN}"
                    else
                        echo -e "${RED}✖ 语法校验失败${PLAIN}"; rm -f "$T_RST"
                    fi
                fi
                pause ;;
            7) # 专属内网穿透：修改 Hosts 劫持并注入 direct 路由 (支持多配置管理)
                while true; do
                    clear
                    echo -e "${YELLOW}━━━ 内网管理穿透 (WireGuard DNS 劫持) ━━━${PLAIN}"
                    echo -e "作用：绕过 CF，将后台域名直接解析到特定内网 IP 并走直连\n"
                    echo " 1. 添加内网域名映射 (支持多次添加)"
                    echo " 2. 查看当前映射列表"
                    echo " 3. 删除特定域名映射"
                    echo "------------------------------------------------"
                    echo " 0. 返回上一级"
                    read -p "请选择: " wg_choice

                    case $wg_choice in
                        1)
                            read -p "请输入要管理的后台域名 (如 wp.domain.com): " wg_domain
                            [[ -z "$wg_domain" ]] && continue
                            read -p "请输入该域名对应的 WG 内网 IP (如 10.0.0.5): " wg_ip
                            [[ -z "$wg_ip" ]] && continue

                            # 步骤 A：清理可能存在的旧记录，追加新记录，并打上脚本专属标签
                            sed -i "/[[:space:]]${wg_domain}[[:space:]]*#/d" /etc/hosts
                            echo "${wg_ip} ${wg_domain} # added_by_sb_wg_admin" >> /etc/hosts
                            echo -e "\n${GREEN}✔ [步骤 1] 域名 ${wg_domain} 已绑定至 ${wg_ip}${PLAIN}"

                            # 步骤 B：使用 jq 注入路由规则
                            # 无论执行多少次，这段逻辑都能保证 10.0.0.0/8 规则唯一且在最高优先级
                            make_tmp
                            jq --arg cidr "10.0.0.0/8" '
                                .route.rules = [
                                    {"ip_cidr": [$cidr], "outbound": "direct"}
                                ] + [
                                    .route.rules[] | select(
                                        if .ip_cidr then
                                            (.ip_cidr | contains([$cidr])) | not
                                        else true end
                                    )
                                ]
                            ' "$CONFIG_FILE" > "$_TMP_JSON"

                            if save_and_restart; then
                                echo -e "${GREEN}✔ [步骤 2] Sing-box 路由分流已更新！${PLAIN}"
                            else
                                echo -e "${RED}✖ 路由注入失败，配置已回滚。${PLAIN}"
                            fi
                            pause ;;
                            
                        2)
                            echo -e "\n${CYAN}--- 当前生效的内网域名劫持列表 ---${PLAIN}"
                            if grep -q "added_by_sb_wg_admin" /etc/hosts; then
                                grep "added_by_sb_wg_admin" /etc/hosts | awk '{printf "  %-15s -> %s\n", $1, $2}'
                            else
                                echo -e "  ${YELLOW}暂无任何配置${PLAIN}"
                            fi
                            pause ;;
                            
                        3)
                            echo -e "\n${CYAN}--- 请选择要删除的域名 ---${PLAIN}"
                            if ! grep -q "added_by_sb_wg_admin" /etc/hosts; then
                                echo -e "  ${YELLOW}暂无任何配置可删${PLAIN}"
                                pause; continue
                            fi
                            
                            grep "added_by_sb_wg_admin" /etc/hosts | awk '{printf "  %-15s -> %s\n", $1, $2}'
                            echo ""
                            read -p "请输入要移除的域名 (例如 wp.domain.com，直接回车取消): " del_domain
                            [[ -z "$del_domain" ]] && continue
                            
                            if grep -q "[[:space:]]${del_domain}[[:space:]]*# added_by_sb_wg_admin" /etc/hosts; then
                                sed -i "/[[:space:]]${del_domain}[[:space:]]*# added_by_sb_wg_admin/d" /etc/hosts
                                echo -e "${GREEN}✔ 域名 ${del_domain} 的本地劫持已移除。${PLAIN}"
                            else
                                echo -e "${RED}✖ 未找到关于 ${del_domain} 的记录。${PLAIN}"
                            fi
                            pause ;;
                            
                        0) break ;;
                        *) continue ;;
                    esac
                done
                ;;

            0) return 0 ;;
        esac
    done
}

add_outbound() {
    _write_one_node() {
        local tag=$1 json=$2
        [[ -z "$json" ]] && return 1
        make_tmp
        jq --argjson obj "$json" '.outbounds += [$obj]' "$CONFIG_FILE" > "$_TMP_JSON"
        if save_and_restart; then
            echo -e "${GREEN}  ✔ [$tag] 写入成功${PLAIN}"; return 0
        else
            echo -e "${RED}  ✖ [$tag] 校验失败，已跳过${PLAIN}"; return 1
        fi
    }

    while true; do
        clear
        echo -e "${YELLOW}--- 添加出站节点 ---${PLAIN}"
        echo "1. 粘贴单条链接 (SS/Socks5/HTTPS/VLESS/Trojan/Hysteria2/TUIC)"
        echo "2. 手动输入 (SS / Socks5 / HTTPS)"
        echo "3. 订阅导入 (URL 或本地文件，批量解析)"
        echo "0. 返回主菜单"
        echo "---"
        read -p "选择 [0-3]: " node_type
        [[ "$node_type" == "0" ]] && break

        if [[ "$node_type" == "1" ]]; then
            read -p "节点链接: " RAW_LINK
            parse_proxy_link "$RAW_LINK"
            if [[ -z "$R_ADDR" ]]; then echo -e "${RED}✘ 解析失败${PLAIN}"; pause; continue; fi
            local name_safe; name_safe=$(echo "$R_NAME" | tr ' ' '_' | tr -dc 'a-zA-Z0-9._-')
            local OUT_TAG="${name_safe:-hop-$(date +%s)}"
            local OUT_JSON; OUT_JSON=$(link_to_outbound_json "$OUT_TAG")
            [[ -z "$OUT_JSON" ]] && echo -e "${RED}✘ 不支持协议 (hop_type=$hop_type)${PLAIN}" && pause && continue
            _write_one_node "$OUT_TAG" "$OUT_JSON"

        elif [[ "$node_type" == "2" ]]; then
            echo "1) SS  2) Socks5  3) HTTPS"
            read -p "协议: " proto_choice
            read -p "地址: " R_ADDR; read -p "端口: " R_PORT
            R_USER=""; R_PASS=""; R_METHOD=""; R_TLS_INSECURE="0"
            local OUT_TAG="hop-$(date +%s)" OUT_JSON
            case $proto_choice in
                1) read -p "加密: " R_METHOD; read -p "密码: " R_PASS; hop_type=1 ;;
                2) read -p "用户 (可选): " R_USER; read -p "密码 (可选): " R_PASS; hop_type=2 ;;
                3) read -p "用户 (可选): " R_USER; read -p "密码 (可选): " R_PASS
                   read -p "跳过证书验证? [y/N]: " _sk
                   [[ "$_sk" =~ ^[yY]$ ]] && R_TLS_INSECURE="1"
                   hop_type=3 ;;
                *) echo -e "${RED}非法输入${PLAIN}"; continue ;;
            esac
            OUT_JSON=$(link_to_outbound_json "$OUT_TAG")
            _write_one_node "$OUT_TAG" "$OUT_JSON"

        elif [[ "$node_type" == "3" ]]; then
            clear; echo -e "${YELLOW}--- 订阅导入 ---${PLAIN}"
            echo "1. 从 URL 拉取  2. 本地文件  0. 返回"
            read -p "选择: " sub_mode; [[ "$sub_mode" == "0" ]] && continue
            local raw_content=""
            if [[ "$sub_mode" == "1" ]]; then
                read -p "订阅 URL: " SUB_URL; [[ -z "$SUB_URL" ]] && continue
                echo -e "${CYAN}拉取订阅...${PLAIN}"
                raw_content=$(curl -sL --connect-timeout 10 --max-time 30 "$SUB_URL")
                [[ -z "$raw_content" ]] && echo -e "${RED}✘ 拉取失败${PLAIN}" && pause && continue
            elif [[ "$sub_mode" == "2" ]]; then
                read -p "本地文件路径: " SUB_FILE
                [[ ! -f "$SUB_FILE" ]] && echo -e "${RED}✘ 文件不存在${PLAIN}" && pause && continue
                raw_content=$(cat "$SUB_FILE")
            else continue; fi

            local link_list="" decoded
            decoded=$(echo "$raw_content" | tr -d '\r\n ' | base64 -d 2>/dev/null)
            if echo "$decoded" | grep -qE '^(ss|socks5?|https|vless|trojan|hysteria2|hy2|tuic)://'; then
                link_list="$decoded"; echo -e "${CYAN}检测到 Base64 编码订阅，已解码${PLAIN}"
            elif echo "$raw_content" | grep -qE '^(ss|socks5?|https|vless|trojan|hysteria2|hy2|tuic)://'; then
                link_list="$raw_content"; echo -e "${CYAN}检测到明文链接订阅${PLAIN}"
            else
                echo -e "${RED}✘ 无法识别订阅格式${PLAIN}"; pause; continue; fi

            local total=0 ok=0 fail=0
            while IFS= read -r line; do
                [[ -z "$line" || "$line" =~ ^# ]] && continue
                [[ ! "$line" =~ ^(ss|socks5?|https|vless|trojan|hysteria2|hy2|tuic):// ]] && continue
                ((total++))
                parse_proxy_link "$line"
                if [[ -z "$R_ADDR" ]]; then
                    echo -e "${RED}  [$total] 解析失败: ${line:0:60}${PLAIN}"; ((fail++)); continue; fi
                local name_safe; name_safe=$(echo "$R_NAME" | tr ' ' '_' | tr -dc 'a-zA-Z0-9._-')
                local base_tag="${name_safe:-sub-$total}" final_tag dup=1
                final_tag="$base_tag"
                while jq -e --arg t "$final_tag" '.outbounds[] | select(.tag==$t)' \
                    "$CONFIG_FILE" > /dev/null 2>&1; do
                    final_tag="${base_tag}-${dup}"; ((dup++)); done
                local node_json; node_json=$(link_to_outbound_json "$final_tag")
                if [[ -z "$node_json" ]]; then
                    echo -e "${YELLOW}  [$total] 不支持协议，跳过: $R_ADDR${PLAIN}"; ((fail++)); continue; fi
                make_tmp
                jq --argjson obj "$node_json" '.outbounds += [$obj]' "$CONFIG_FILE" > "$_TMP_JSON"
                if $SB_BIN check -c "$_TMP_JSON" > /dev/null 2>&1; then
                    mv "$_TMP_JSON" "$CONFIG_FILE"; _TMP_JSON=""
                    echo -e "${GREEN}  [$total] ✔ $final_tag ($R_ADDR:$R_PORT)${PLAIN}"; ((ok++))
                else
                    rm -f "$_TMP_JSON"; _TMP_JSON=""
                    echo -e "${RED}  [$total] ✖ 校验失败: $R_ADDR${PLAIN}"; ((fail++)); fi
            done <<< "$link_list"

            echo -e "\n${YELLOW}共 $total 条，成功 ${GREEN}$ok${PLAIN}${YELLOW}，失败 ${RED}$fail${PLAIN}${YELLOW} 条${PLAIN}"
            if (( ok > 0 )); then
                systemctl restart sing-box && \
                    echo -e "${GREEN}✔ 重启完成，$ok 节点已生效${PLAIN}" || \
                    echo -e "${RED}✘ 重启失败，请检查配置${PLAIN}"
            fi
        fi
        pause
    done
}

# ============================================================
# 出站节点管理 (带关联路由安全清理)
# ============================================================
manage_outbounds() {
    while true; do
        clear
        echo -e "${YELLOW}--- 出站节点管理 (Outbounds) ---${PLAIN}"
        echo -e "当前配置文件中的出站节点："

        # 获取所有出站节点的 Tag 和类型
        local tags=($(jq -r '.outbounds[].tag' "$CONFIG_FILE"))
        local types=($(jq -r '.outbounds[].type' "$CONFIG_FILE"))
        local count=${#tags[@]}

        if [[ $count -eq 0 ]]; then
            echo -e "${RED}没有找到任何出站配置！${PLAIN}"
            pause; return
        fi

        # 动态遍历列表并打印
        for ((i=0; i<$count; i++)); do
            local current_tag="${tags[$i]}"
            local current_type="${types[$i]}"
            
            # 标记并保护系统保留出站 (不能删)
            if [[ "$current_tag" == "direct" || "$current_tag" == "block" || "$current_tag" == "dns-out" ]]; then
                echo -e "  ${GREEN}$((i+1)).${PLAIN} [系统内置] Tag: ${CYAN}${current_tag}${PLAIN} (类型: ${current_type})"
            else
                echo -e "  ${GREEN}$((i+1)).${PLAIN} [可删除]   Tag: ${CYAN}${current_tag}${PLAIN} (类型: ${current_type})"
            fi
        done

        echo "-----------------------------------------------"
        echo "0. 返回主菜单"
        read -p "请输入要删除的节点序号: " del_idx

        if [[ "$del_idx" == "0" ]]; then
            return
        elif [[ "$del_idx" -gt 0 && "$del_idx" -le "$count" ]]; then
            local target_idx=$((del_idx-1))
            local target_tag="${tags[$target_idx]}"

            # 防呆保护机制：禁止删除维持网络运作的核心出站
            if [[ "$target_tag" == "direct" || "$target_tag" == "block" || "$target_tag" == "dns-out" ]]; then
                echo -e "${RED}✘ 警告: [ $target_tag ] 是维持 sing-box 正常运行的核心出站，禁止删除！${PLAIN}"
                pause; continue
            fi

            echo -e "${YELLOW}确认要彻底删除出站节点 [ $target_tag ] 吗？(y/n)${PLAIN}"
            read -p "选择: " confirm
            if [[ "${confirm,,}" == "y" ]]; then
                make_tmp
                
                # 核心逻辑：删除该出站，同时遍历 route 规则，把指向该出站的失效分流规则一并安全移除！
                jq --arg tag "$target_tag" '
                    del(.outbounds[] | select(.tag == $tag)) |
                    if .route and .route.rules then
                        .route.rules |= map(select(.outbound != $tag))
                    else
                        .
                    end
                ' "$CONFIG_FILE" > "$_TMP_JSON"

                if save_and_restart; then
                    echo -e "${GREEN}✔ 出站节点 [ $target_tag ] 及其关联的失效路由规则已成功清理！${PLAIN}"
                    
                    # 针对 WARP 的联动提示
                    if [[ "$target_tag" == "warp-out" ]]; then
                        echo -e "${YELLOW}提示: 如果你不想在后台继续运行 WARP 本地进程，可执行以下命令彻底卸载:${PLAIN}"
                        echo -e "warp-cli --accept-tos disconnect && apt-get purge -y cloudflare-warp"
                    fi
                else
                    echo -e "${RED}✘ 删除失败，配置文件已回滚。${PLAIN}"
                fi
            fi
        else
            echo -e "${RED}无效的序号输入！${PLAIN}"
        fi
        pause
    done
}

# ============================================================
# 节点订阅主管理模块
# ============================================================
manage_subscription() {
    while true; do
        clear
        echo -e "${YELLOW}--- 节点订阅服务管理 ---${PLAIN}"
        local sub_status
        if systemctl is-active --quiet singbox-sub 2>/dev/null; then
            sub_status="${GREEN}运行中${PLAIN}"
        else
            sub_status="${RED}已停止${PLAIN}"
        fi
        echo -e "当前状态: $sub_status"
        echo "-------------------------"
        echo "1. 开启/更新订阅服务 (生成安全 URL)"
        echo "2. 查看我的订阅链接"
        echo "3. 关闭订阅服务"
        echo "0. 返回主菜单"
        read -p "请选择: " sub_choice

        case $sub_choice in
            1)
                local count=$(ls -1 "$LINK_DIR"/*.link 2>/dev/null | wc -l)
                if [[ $count -eq 0 ]]; then
                    echo -e "${RED}✘ 当前没有已保存的节点链接，请先去添加节点！${PLAIN}"
                    pause; continue
                fi

                local LAST_PROTO; [[ -f "/etc/sing-box/.sub_proto" ]] && LAST_PROTO=$(cat /etc/sing-box/.sub_proto)
                LAST_PROTO=${LAST_PROTO:-2}
                
                echo "1. 普通 HTTP (明文，易被墙)   2. 安全 HTTPS (防嗅探，需已有证书)"
                read -p "请选择订阅协议 [当前/默认 ${LAST_PROTO}]: " sub_proto
                sub_proto=${sub_proto:-$LAST_PROTO}
                echo "$sub_proto" > /etc/sing-box/.sub_proto

                local SUB_PORT EXEC_CMD SUB_URL
                mkdir -p /var/www/singbox-sub

                # 【修复核心：固定订阅路径】
                # 检查是否已经存在路径缓存。如果存在，就复用老路径；如果不存在，再生成随机新路径。
                local SUB_PATH
                if [[ -f "/var/www/singbox-sub/.path_cache" ]]; then
                    SUB_PATH=$(cat /var/www/singbox-sub/.path_cache)
                    echo -e "${GREEN}检测到已有订阅链接，沿用原路径: ${SUB_PATH}${PLAIN}"
                else
                    SUB_PATH="sub_$(openssl rand -hex 8)"
                    echo "$SUB_PATH" > /var/www/singbox-sub/.path_cache
                    echo -e "${YELLOW}首次生成订阅，已创建安全路径: ${SUB_PATH}${PLAIN}"
                fi

                local LAST_PORT; [[ -f "/etc/sing-box/.sub_port" ]] && LAST_PORT=$(cat /etc/sing-box/.sub_port)

                if [[ "$sub_proto" == "2" ]]; then
                    read -p "请输入已申请证书的域名 (例如 node.example.com): " sub_domain
                    find_certs "$sub_domain"
                    if [[ -z "$CERT_PATH" || -z "$KEY_PATH" ]]; then
                        echo -e "${RED}✘ 未找到该域名的证书，请先在主菜单选 8 进行 ACME 申请！${PLAIN}"
                        pause; continue
                    fi

                    LAST_PORT=${LAST_PORT:-8443}
                    read -p "请输入 HTTPS 订阅服务端口 (当前/默认 ${LAST_PORT}): " SUB_PORT
                    SUB_PORT=${SUB_PORT:-$LAST_PORT}
                    echo "$SUB_PORT" > /etc/sing-box/.sub_port

                    cat > /var/www/singbox-sub/https_server.py <<EOF
import http.server, ssl
server_address = ('0.0.0.0', $SUB_PORT)
httpd = http.server.HTTPServer(server_address, http.server.SimpleHTTPRequestHandler)
protocol = ssl.PROTOCOL_TLS_SERVER if hasattr(ssl, 'PROTOCOL_TLS_SERVER') else ssl.PROTOCOL_TLS
context = ssl.SSLContext(protocol)
context.load_cert_chain(certfile="$CERT_PATH", keyfile="$KEY_PATH")
httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
print(f"HTTPS Subscription server running on port {$SUB_PORT}...")
httpd.serve_forever()
EOF
                    EXEC_CMD="/usr/bin/python3 /var/www/singbox-sub/https_server.py"
                    SUB_URL="https://$sub_domain:$SUB_PORT/$SUB_PATH"
                else
                    LAST_PORT=${LAST_PORT:-8080}
                    read -p "请输入 HTTP 订阅服务端口 (当前/默认 ${LAST_PORT}): " SUB_PORT
                    SUB_PORT=${SUB_PORT:-$LAST_PORT}
                    echo "$SUB_PORT" > /etc/sing-box/.sub_port

                    EXEC_CMD="/usr/bin/python3 -m http.server $SUB_PORT"
                    SUB_URL="http://$(get_ip):$SUB_PORT/$SUB_PATH"
                fi

                if ! check_port "$SUB_PORT"; then pause; continue; fi

                echo -e "${CYAN}生成/刷新订阅文件...${PLAIN}"
                refresh_sub

                # 重启服务而不是仅在首次启动
                cat > /etc/systemd/system/singbox-sub.service <<EOF
[Unit]
Description=Sing-box Subscription Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/var/www/singbox-sub
ExecStart=$EXEC_CMD
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                # 【修复核心：强制重启服务】确保 Python Server 挂掉时能重新拉起，并读取最新配置
                systemctl restart singbox-sub >/dev/null 2>&1
                systemctl enable singbox-sub >/dev/null 2>&1

                echo -e "${GREEN}✔ 订阅服务开启/刷新成功！${PLAIN}"
                echo -e "请在客户端导入以下专属订阅链接 (路径已随机加密):"
                echo -e "${BLUE}$SUB_URL${PLAIN}"
                
                echo "$SUB_URL" > /var/www/singbox-sub/.url_cache
                pause ;;

            2)
                if systemctl is-active --quiet singbox-sub 2>/dev/null && [[ -f "/var/www/singbox-sub/.url_cache" ]]; then
                    echo -e "\n你的专属订阅链接为:\n${BLUE}$(cat /var/www/singbox-sub/.url_cache)${PLAIN}"
                    echo -e "${YELLOW}提示: 路径具有唯一性，每次开启都会随机变化以保证安全。${PLAIN}"
                else
                    echo -e "\n${RED}✘ 订阅服务未开启，或链接缓存丢失！${PLAIN}"
                fi
                pause ;;

            3)
                systemctl stop singbox-sub >/dev/null 2>&1
                systemctl disable singbox-sub >/dev/null 2>&1
                rm -f /etc/systemd/system/singbox-sub.service
                systemctl daemon-reload
                rm -rf /var/www/singbox-sub
                echo -e "${GREEN}✔ 订阅服务已彻底关闭，相关缓存与脚本已清理。${PLAIN}"
                pause ;;
                
            0) return ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

update_kernel() {
    echo -e "${CYAN}更新前自动备份...${PLAIN}"; auto_backup
    
    echo -e "${YELLOW}正在停止服务以解除文件锁定...${PLAIN}"
    # 核心修复点：调用底层安装前，先杀掉进程释放文件锁
    systemctl stop sing-box >/dev/null 2>&1
    
    echo -e "${YELLOW}开始更新 sing-box 内核...${PLAIN}"
    install_base
    
    # 覆盖完成后，重新启动服务加载新内核
    systemctl start sing-box >/dev/null 2>&1
    
    # 稍微等一秒，确保服务完全启动后再去抓取版本号
    sleep 1
    
    local VER; VER=$($SB_BIN version 2>/dev/null | awk '/version/{print $3}')
    echo -e "${GREEN}✔ 更新完成！当前最新版本: ${VER:-未知}${PLAIN}"
    pause
}
    
# ============================================================
# 一键部署 WARP 并对接 Sing-box 出站 (适配最新版 warp-cli)
# ============================================================
setup_warp_outbound() {
    clear
    echo -e "${YELLOW}--- 一键部署 WARP 并对接 Sing-box 出站 ---${PLAIN}"
    
    # 1. 检查并安装 warp-cli
    if ! command -v warp-cli &> /dev/null; then
        echo -e "${CYAN}检测到未安装 warp-cli，开始自动拉取并安装...${PLAIN}"
        if command -v apt-get &> /dev/null; then
            apt-get update -y && apt-get install -y curl lsb-release gnupg
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -y && apt-get install -y cloudflare-warp
        elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
            curl -fsSl https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo
            if command -v dnf &> /dev/null; then
                dnf install -y cloudflare-warp
            else
                yum install -y cloudflare-warp
            fi
        else
            echo -e "${RED}✘ 不支持的系统包管理器，请手动安装 cloudflare-warp。${PLAIN}"
            pause; return
        fi
    fi

    # 2. 静默注册并配置本地 Socks5 代理模式
    echo -e "\n${CYAN}配置 WARP 本地代理隧道...${PLAIN}"
    
    # 强制重置可能存在的旧状态 (适配新版语法)
    warp-cli --accept-tos disconnect 2>/dev/null
    warp-cli --accept-tos registration delete 2>/dev/null

    # 先切换到代理模式并绑定端口，再注册/连接
    # 目的：避免注册后 warp-svc 按默认的全隧道 (warp) 模式自动发起连接，
    # 那样会把 VPS 全部流量（含 SSH）瞬间劫持进隧道，导致连接中断
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port 40000

    # 执行全自动流：代理模式 -> 绑定端口 -> 注册 -> 连接 (适配新版语法)
    # 用 yes 兜底，防止个别版本的 registration new 仍会弹出交互确认导致脚本卡死
    if yes | warp-cli --accept-tos registration new; then
        warp-cli --accept-tos connect
        
        echo -e "${YELLOW}等待 WARP 隧道建立...${PLAIN}"
        sleep 3

        if warp-cli --accept-tos status | grep -i "Connected" > /dev/null 2>&1; then
            echo -e "${GREEN}✔ WARP 代理已成功稳定运行在 127.0.0.1:40000${PLAIN}"
        else
            echo -e "${RED}✘ WARP 连接未生效，请检查服务器网络或尝试重启机器。${PLAIN}"
            warp-cli --accept-tos status
            pause; return
        fi
    else
        echo -e "${RED}✘ WARP 注册请求被拒。${PLAIN}"
        pause; return
    fi

    # 3. 注入 Sing-box 出站配置
    echo -e "\n${CYAN}正在将 WARP 节点写入 Sing-box 出站配置...${PLAIN}"
    make_tmp
    
    local has_warp
    has_warp=$(jq 'any(.outbounds[]; .tag == "warp-out")' "$CONFIG_FILE")
    
    if [[ "$has_warp" == "true" ]]; then
        echo -e "${YELLOW}检测到配置文件中已存在 Tag 为 [warp-out] 的出站节点，无需重复添加。${PLAIN}"
    else
        # 注意: WARP 本地代理模式只支持 TCP CONNECT，不支持 SOCKS5 UDP ASSOCIATE，
        # 所以这里显式声明 network 为 tcp，避免 UDP 流量（如 QUIC/HTTP3、DNS UDP 查询）
        # 被分流到 warp-out 后连接失败或长时间挂起
        jq '.outbounds += [{
            "type": "socks",
            "tag": "warp-out",
            "server": "127.0.0.1",
            "server_port": 40000,
            "version": "5",
            "network": "tcp"
        }]' "$CONFIG_FILE" > "$_TMP_JSON"
        
        if save_and_restart; then
            echo -e "${GREEN}✔ WARP 出站节点 (warp-out) 注入成功！${PLAIN}"
            echo -e "-----------------------------------------------"
            echo -e "${YELLOW}💡 进阶玩法提示：${PLAIN}"
            echo -e "你现在可以进入主菜单的【4. 路由分流管理】 -> 【1. 添加分流规则】"
            echo -e "将想要解锁的特定域名目标出站统统指向 ${CYAN}warp-out${PLAIN} 即可实现精准解锁！"
        else
            echo -e "${RED}✘ 写入 Sing-box 配置失败，已回滚。${PLAIN}"
        fi
    fi
    pause
}

enable_bbr() {
    echo -e "${YELLOW}检查 BBR 状态...${PLAIN}"
    local kv; kv=$(uname -r | cut -d- -f1)
    if [[ $(echo -e "4.9\n$kv" | sort -V | head -n1) == "4.9" ]]; then
        if lsmod | grep -q bbr; then
            echo -e "${GREEN}BBR 已运行${PLAIN}"
        else
            echo -e "${CYAN}开启 BBR...${PLAIN}"
            grep -q "default_qdisc=fq"     /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            grep -q "tcp_congestion.*bbr"  /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
            lsmod | grep -q bbr && echo -e "${GREEN}✔ BBR 已开启${PLAIN}" || echo -e "${RED}✘ 开启失败${PLAIN}"
        fi
    else
        echo -e "${RED}内核版本 $kv 过低，不支持 BBR${PLAIN}"
    fi
    pause
}

# ============================================================
# 主菜单
# ============================================================
while true; do
    clear
    echo -e "==============================================="
    echo -e "          ${GREEN}Sing-box 综合管理脚本  v2.1${PLAIN}"
    echo -e "==============================================="
    show_status
    echo -e "-----------------------------------------------"
    echo -e "  ${GREEN}1.${PLAIN} 安装/重装 sing-box"
    echo -e "  ${GREEN}2.${PLAIN} 节点快速配置"
    echo -e "  ${GREEN}3.${PLAIN} 配置/分享链接查看"
    echo -e "  ${GREEN}4.${PLAIN} 路由分流/链式代理"
    echo -e "  ${GREEN}5.${PLAIN} 更新 sing-box 内核"
    echo -e "  ${GREEN}6.${PLAIN} 备份/还原配置"
    echo -e "  ${GREEN}7.${PLAIN} 开启 BBR 加速"
    echo -e "  ${GREEN}8.${PLAIN} 申请 SSL 证书 (ACME)"
    echo -e "  ${GREEN}9.${PLAIN} 添加出站/自动优选/轮询"
    echo -e " ${GREEN}10.${PLAIN} 修改/删除节点"
    echo -e " ${GREEN}11.${PLAIN} 日志查看"
    echo -e " ${GREEN}12.${PLAIN} 一键订阅"
    echo -e " ${GREEN}13.${PLAIN} 一键部署WARP出站"
    echo -e " ${GREEN}14.${PLAIN} 出站管理"
    echo -e "-----------------------------------------------"
    echo -e " ${GREEN}88${PLAIN} 启动  ${GREEN}99${PLAIN} 停止  ${GREEN}66${PLAIN} 重启  ${RED}77${PLAIN} 卸载  ${RED}0${PLAIN} 退出"
    echo -e "==============================================="
    read -p " 请输入选项: " choice

    case "$choice" in
        1)  install_base ;;
        2)  add_node ;;
        3)  manage_configs ;;
        4)  manage_routing ;;
        5)  update_kernel ;;
        6)  backup_restore ;;
        7)  enable_bbr ;;
        8)  apply_cert ;;
        9)  add_outbound ;;
        10) edit_node ;;
        11) view_logs ;;
        12) manage_subscription ;;
        13) setup_warp_outbound ;;
        14) manage_outbounds ;;
        88) echo -e "${YELLOW}启动...${PLAIN}"; systemctl start sing-box; sleep 1 ;;
        99) echo -e "${YELLOW}停止...${PLAIN}"; systemctl stop  sing-box; sleep 1 ;;
        66) echo -e "${YELLOW}重启...${PLAIN}"; systemctl restart sing-box; sleep 1 ;;
        77)
            read -p "确定卸载？(y/n): " confirm
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                systemctl stop sing-box 2>/dev/null
                systemctl disable sing-box 2>/dev/null
                rm -f /etc/systemd/system/sing-box.service
                systemctl daemon-reload
                rm -f /usr/local/bin/ssb /usr/local/bin/sing-box
                rm -rf /etc/sing-box
                echo -e "${GREEN}✔ 已彻底卸载${PLAIN}"; exit 0
            fi ;;
        0)  exit 0 ;;
        *)  echo -e "${RED}✘ 无效输入${PLAIN}"; sleep 1 ;;
    esac
done
