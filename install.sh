
#!/bin/sh
set -e

REALM_BIN="/usr/local/bin/realm"
REALM_DIR="/etc/realm"
REALM_CONF="/etc/realm/config.toml"
REALM_RULES="/etc/realm/rules-realm.conf"
NFT_RULES="/etc/realm/rules-nft.conf"

SYSTEMD_SERVICE="/etc/systemd/system/realm.service"
SYSTEMD_REFRESH_SERVICE="/etc/systemd/system/realm-dns-refresh.service"
SYSTEMD_REFRESH_TIMER="/etc/systemd/system/realm-dns-refresh.timer"

OPENRC_SERVICE="/etc/init.d/realm"
DNS_REFRESH_SCRIPT="/usr/local/bin/realm-dns-refresh.sh"

NFT_APPLY_SCRIPT="/usr/local/bin/realm-nft-apply.sh"
NFT_SYSTEMD_SERVICE="/etc/systemd/system/realm-nft-forward.service"
NFT_OPENRC_SERVICE="/etc/init.d/realm-nft-forward"

SHORTCUT_BIN="/usr/local/bin/vfm"

CRON_BEGIN="# BEGIN VPS FORWARD MANAGER DNS REFRESH"
CRON_END="# END VPS FORWARD MANAGER DNS REFRESH"

OS_FAMILY=""
SERVICE_MANAGER=""
CPU_ARCH=""
REALM_ARCH=""

ACTION=""
MODE=""
LISTEN_PORT=""
REMOTE_HOST=""
REMOTE_PORT=""
REMOTE_ADDR=""
PROTO="tcp"
ENABLE_DNS_REFRESH="no"
DNS_REFRESH_INTERVAL="10"

print_line() {
    echo "======================================"
}

read_input() {
    PROMPT_TEXT="$1"
    VAR_NAME="$2"

    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        printf "%s" "$PROMPT_TEXT" > /dev/tty
        IFS= read -r INPUT_VALUE < /dev/tty
    else
        printf "%s" "$PROMPT_TEXT"
        IFS= read -r INPUT_VALUE
    fi

    eval "$VAR_NAME=\$INPUT_VALUE"
}

confirm_input() {
    PROMPT_TEXT="$1"
    RESULT_VAR="$2"

    read_input "$PROMPT_TEXT" CONFIRM_VALUE

    case "$CONFIRM_VALUE" in
        y|Y|yes|YES)
            eval "$RESULT_VAR=yes"
            ;;
        0)
            eval "$RESULT_VAR=back"
            ;;
        *)
            eval "$RESULT_VAR=no"
            ;;
    esac
}

print_line
echo " VPS 端口转发一键管理脚本"
echo " 支持系统：Debian / Ubuntu / Alpine"
echo " 转发方式：realm / nftables"
print_line
echo ""

if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 root 用户运行此脚本。"
    exit 1
fi

detect_os() {
    if [ ! -f /etc/os-release ]; then
        echo "错误：无法检测系统，未找到 /etc/os-release。"
        exit 1
    fi

    . /etc/os-release

    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"

    case "$OS_ID" in
        debian|ubuntu)
            OS_FAMILY="debian"
            SERVICE_MANAGER="systemd"
            ;;
        alpine)
            OS_FAMILY="alpine"
            SERVICE_MANAGER="openrc"
            ;;
        *)
            case "$OS_LIKE" in
                *debian*)
                    OS_FAMILY="debian"
                    SERVICE_MANAGER="systemd"
                    ;;
                *)
                    echo "错误：不支持当前系统：$OS_ID"
                    echo "当前脚本仅支持 Debian / Ubuntu / Alpine。"
                    exit 1
                    ;;
            esac
            ;;
    esac

    if [ "$SERVICE_MANAGER" = "systemd" ] && ! command -v systemctl >/dev/null 2>&1; then
        echo "错误：未找到 systemctl。当前系统可能不是 systemd 环境。"
        exit 1
    fi

    if [ "$SERVICE_MANAGER" = "openrc" ] && ! command -v rc-service >/dev/null 2>&1; then
        echo "错误：未找到 rc-service。当前 Alpine 系统可能不是 OpenRC 环境。"
        exit 1
    fi
}

install_base_deps() {
    echo "[1/10] 正在安装基础依赖..."

    case "$OS_FAMILY" in
        debian)
            apt-get update >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                curl \
                tar \
                ca-certificates \
                iproute2 \
                procps \
                grep \
                coreutils >/dev/null 2>&1
            ;;
        alpine)
            apk update >/dev/null 2>&1 || true
            apk add --no-cache \
                curl \
                tar \
                ca-certificates \
                iproute2 \
                procps \
                grep \
                gawk \
                coreutils \
                openrc >/dev/null 2>&1
            ;;
    esac
}

install_dns_deps() {
    case "$OS_FAMILY" in
        debian)
            DEBIAN_FRONTEND=noninteractive apt-get install -y cron dnsutils >/dev/null 2>&1
            systemctl enable cron >/dev/null 2>&1 || true
            systemctl start cron >/dev/null 2>&1 || true
            ;;
        alpine)
            apk add --no-cache dcron bind-tools >/dev/null 2>&1
            rc-update add dcron default >/dev/null 2>&1 || true
            rc-service dcron start >/dev/null 2>&1 || true
            ;;
    esac
}

install_nft_deps() {
    echo ""
    echo "正在安装 nftables 依赖..."

    case "$OS_FAMILY" in
        debian)
            DEBIAN_FRONTEND=noninteractive apt-get install -y nftables >/dev/null 2>&1
            ;;
        alpine)
            apk add --no-cache nftables >/dev/null 2>&1
            ;;
    esac
}

detect_arch() {
    ARCH="$(uname -m)"

    case "$ARCH" in
        x86_64|amd64)
            CPU_ARCH="x86_64"
            ;;
        aarch64|arm64)
            CPU_ARCH="aarch64"
            ;;
        armv7l|armv7)
            CPU_ARCH="armv7"
            ;;
        *)
            echo "错误：不支持当前 CPU 架构：$ARCH"
            echo "当前脚本支持：x86_64 / aarch64 / armv7"
            exit 1
            ;;
    esac

    case "$OS_FAMILY" in
        debian)
            case "$CPU_ARCH" in
                x86_64) REALM_ARCH="x86_64-unknown-linux-gnu" ;;
                aarch64) REALM_ARCH="aarch64-unknown-linux-gnu" ;;
                armv7) REALM_ARCH="armv7-unknown-linux-gnueabihf" ;;
            esac
            ;;
        alpine)
            case "$CPU_ARCH" in
                x86_64) REALM_ARCH="x86_64-unknown-linux-musl" ;;
                aarch64) REALM_ARCH="aarch64-unknown-linux-musl" ;;
                armv7) REALM_ARCH="armv7-unknown-linux-musleabihf" ;;
            esac
            ;;
    esac
}

install_shortcut() {
    SCRIPT_PATH="$0"

    case "$SCRIPT_PATH" in
        "$SHORTCUT_BIN") return ;;
    esac

    if [ -f "$SCRIPT_PATH" ]; then
        cp "$SCRIPT_PATH" "$SHORTCUT_BIN" >/dev/null 2>&1 || true
        chmod +x "$SHORTCUT_BIN" >/dev/null 2>&1 || true
    fi
}

show_system_info() {
    echo ""
    echo "[2/10] 当前系统信息"
    echo "--------------------------------------"
    echo "系统类型       ：$OS_FAMILY"
    echo "服务管理器     ：$SERVICE_MANAGER"
    echo "CPU 架构       ：$(uname -m)"
    echo "快捷命令       ：vfm"
    echo "--------------------------------------"
    echo ""
}

is_valid_port() {
    PORT="$1"
    case "$PORT" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        return 1
    fi
    return 0
}

is_ipv4() {
    echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

is_ipv6() {
    echo "$1" | grep -q ':'
}

is_ip_address() {
    HOST="$1"
    if is_ipv4 "$HOST"; then return 0; fi
    if is_ipv6 "$HOST"; then return 0; fi
    return 1
}

format_remote_addr() {
    HOST="$1"
    PORT="$2"
    if is_ipv6 "$HOST"; then
        case "$HOST" in
            \[*\]) REMOTE_ADDR="${HOST}:${PORT}" ;;
            *) REMOTE_ADDR="[${HOST}]:${PORT}" ;;
        esac
    else
        REMOTE_ADDR="${HOST}:${PORT}"
    fi
}

ask_action() {
    print_line
    echo " 主菜单"
    print_line
    echo "1) 新建转发规则"
    echo "2) 查看目前转发规则"
    echo "3) 删除转发规则"
    echo "4) 卸载脚本安装的全部内容"
    echo "0) 退出脚本"
    echo ""

    read_input "请输入选项 [0-4]: " ACTION_CHOICE

    case "$ACTION_CHOICE" in
        1) ACTION="create" ;;
        2) ACTION="view" ;;
        3) ACTION="delete" ;;
        4) ACTION="uninstall" ;;
        0) echo "已退出脚本。"; exit 0 ;;
        *) echo "错误：无效选项。"; ACTION=""; return 1 ;;
    esac
    return 0
}

ask_mode() {
    echo ""
    echo "[4/10] 请选择转发方式"
    echo "--------------------------------------"
    echo "1) realm    - 用户态转发，支持域名/IP，适合动态域名"
    echo "2) nftables - 内核级 DNAT/SNAT，性能更好，目标必须固定IPv4"
    echo "0) 返回主菜单"
    echo "--------------------------------------"

    read_input "请输入选项 [0-2]: " MODE_CHOICE

    case "$MODE_CHOICE" in
        1) MODE="realm" ;;
        2) MODE="nftables" ;;
        0) MODE=""; return 1 ;;
        *) echo "错误：无效选项。"; MODE=""; return 1 ;;
    esac

    echo "已选择：$MODE"
    return 0
}

check_duplicate_rule_in_file() {
    RULE_FILE="$1"
    RULE_PROTO="$2"
    RULE_PORT="$3"

    if [ -f "$RULE_FILE" ]; then
        if awk -F'|' -v p="$RULE_PROTO" -v port="$RULE_PORT" '$1 == p && $2 == port {found=1} END {exit !found}' "$RULE_FILE"; then
            return 0
        fi
    fi
    return 1
}

check_duplicate_rule() {
    RULE_PROTO="$1"
    RULE_PORT="$2"

    if check_duplicate_rule_in_file "$REALM_RULES" "$RULE_PROTO" "$RULE_PORT"; then
        echo "错误：已存在 ${RULE_PROTO} 协议监听端口 ${RULE_PORT} 的 realm 规则。"
        return 1
    fi
    if check_duplicate_rule_in_file "$NFT_RULES" "$RULE_PROTO" "$RULE_PORT"; then
        echo "错误：已存在 ${RULE_PROTO} 协议监听端口 ${RULE_PORT} 的 nftables 规则。"
        return 1
    fi
    return 0
}

check_duplicate_for_new_rule() {
    if [ "$PROTO" = "tcp" ]; then
        check_duplicate_rule "tcp" "$LISTEN_PORT" || return 1
    elif [ "$PROTO" = "udp" ]; then
        check_duplicate_rule "udp" "$LISTEN_PORT" || return 1
    else
        check_duplicate_rule "tcp" "$LISTEN_PORT" || return 1
        check_duplicate_rule "udp" "$LISTEN_PORT" || return 1
    fi
    return 0
}

ask_forward_config() {
    STEP=1

    while true; do
        case "$STEP" in
            1)
                echo ""
                echo "[5/10] 配置转发信息"
                echo "--------------------------------------"
                read_input "第一步 - 请输入本机监听端口 (输入0返回): " LISTEN_PORT

                if [ "$LISTEN_PORT" = "0" ]; then return 1; fi
                if ! is_valid_port "$LISTEN_PORT"; then
                    echo "错误：监听端口必须是 1 到 65535 之间的数字。"
                    continue
                fi
                STEP=2
                ;;
            2)
                read_input "第二步 - 请输入目标域名或 IP (输入0返回): " REMOTE_HOST

                if [ "$REMOTE_HOST" = "0" ]; then STEP=1; continue; fi
                if [ -z "$REMOTE_HOST" ]; then
                    echo "错误：目标域名或 IP 不能为空。"
                    continue
                fi
                STEP=3
                ;;
            3)
                read_input "第三步 - 请输入目标端口 (输入0返回): " REMOTE_PORT

                if [ "$REMOTE_PORT" = "0" ]; then STEP=2; continue; fi
                if ! is_valid_port "$REMOTE_PORT"; then
                    echo "错误：目标端口必须是 1 到 65535 之间的数字。"
                    continue
                fi
                STEP=4
                ;;
            4)
                echo ""
                echo "请选择协议："
                echo "1) TCP"
                echo "2) UDP"
                echo "3) TCP + UDP"
                echo "0) 返回上一步"
                echo ""

                read_input "请输入选项 [默认1]: " PROTO_CHOICE

                case "$PROTO_CHOICE" in
                    ""|1) PROTO="tcp" ;;
                    2) PROTO="udp" ;;
                    3) PROTO="both" ;;
                    0) STEP=3; continue ;;
                    *) echo "错误：无效协议选项。"; continue ;;
                esac

                format_remote_addr "$REMOTE_HOST" "$REMOTE_PORT"

                if [ "$MODE" = "nftables" ]; then
                    if ! is_ipv4 "$REMOTE_HOST"; then
                        echo ""
                        echo "错误：当前脚本的 nftables 模式仅支持目标为固定 IPv4。"
                        echo "原因：nftables DNAT 规则应使用固定 IP，不适合直接使用动态域名。"
                        echo "如果你的目标是域名或 IPv6，请选择 realm 模式。"
                        STEP=2
                        continue
                    fi
                fi

                if ! check_duplicate_for_new_rule; then
                    STEP=1
                    continue
                fi
                STEP=5
                ;;
            5)
                ENABLE_DNS_REFRESH="no"

                if [ "$MODE" = "realm" ]; then
                    if is_ip_address "$REMOTE_HOST"; then
                        ENABLE_DNS_REFRESH="no"
                        echo ""
                        echo "提示：检测到目标是 IP 地址，已跳过 DNS 定时刷新配置。"
                    else
                        echo ""
                        echo "提示：检测到目标为域名。"
                        echo "是否启用 DNS 自动刷新？(域名 IP 变化时自动重启 realm)"
                        echo "y) 启用"
                        echo "N) 不启用"
                        echo "0) 返回上一步"
                        echo ""

                        read_input "请输入选项 [y/N/0]: " DNS_CONFIRM

                        case "$DNS_CONFIRM" in
                            y|Y|yes|YES)
                                ENABLE_DNS_REFRESH="yes"
                                while true; do
                                    read_input "请输入 DNS 刷新间隔分钟数 [默认 10，输入 0 返回]: " DNS_REFRESH_INTERVAL_INPUT

                                    if [ "$DNS_REFRESH_INTERVAL_INPUT" = "0" ]; then STEP=4; continue 2; fi
                                    if [ -n "$DNS_REFRESH_INTERVAL_INPUT" ]; then DNS_REFRESH_INTERVAL="$DNS_REFRESH_INTERVAL_INPUT"; fi

                                    case "$DNS_REFRESH_INTERVAL" in
                                        ''|*[!0-9]*) echo "错误：必须是数字。"; continue ;;
                                    esac
                                    if [ "$DNS_REFRESH_INTERVAL" -lt 1 ]; then echo "错误：不能小于1。"; continue; fi
                                    break
                                done
                                ;;
                            0) STEP=4; continue ;;
                            *) ENABLE_DNS_REFRESH="no" ;;
                        esac
                    fi
                fi
                STEP=6
                ;;
            6)
                echo ""
                print_line
                echo " 配置确认"
                print_line
                echo "转发方式 ：$MODE"
                echo "监听地址 ：0.0.0.0:${LISTEN_PORT}"
                echo "目标地址 ：${REMOTE_ADDR}"
                echo "协议     ：${PROTO}"

                if [ "$MODE" = "realm" ]; then
                    echo "DNS 刷新 ：${ENABLE_DNS_REFRESH}"
                fi

                echo ""
                confirm_input "确认安装？[y/N/0返回]: " CONFIRM
                
                case "$CONFIRM" in
                    yes) return 0 ;;
                    back) STEP=5; continue ;;
                    *) echo "已取消本次新建。"; return 1 ;;
                esac
                ;;
        esac
    done
}

stop_realm_service() {
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl disable --now realm >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_SERVICE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rc-service realm stop >/dev/null 2>&1 || true
        rc-update del realm default >/dev/null 2>&1 || true
        rm -f "$OPENRC_SERVICE"
    fi
}

stop_nft_service() {
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl disable --now realm-nft-forward >/dev/null 2>&1 || true
        rm -f "$NFT_SYSTEMD_SERVICE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rc-service realm-nft-forward stop >/dev/null 2>&1 || true
        rc-update del realm-nft-forward default >/dev/null 2>&1 || true
        rm -f "$NFT_OPENRC_SERVICE"
    fi

    if command -v nft >/dev/null 2>&1; then
        nft delete table ip realm_forward >/dev/null 2>&1 || true
    fi
}

remove_systemd_dns_refresh() {
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl disable --now realm-dns-refresh.timer >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_REFRESH_TIMER" "$SYSTEMD_REFRESH_SERVICE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

remove_openrc_dns_refresh() {
    if command -v crontab >/dev/null 2>&1; then
        TMP_CRON="$(mktemp)"
        crontab -l 2>/dev/null | awk "
            /$CRON_BEGIN/ {skip=1; next}
            /$CRON_END/ {skip=0; next}
            skip != 1 {print}
        " > "$TMP_CRON" || true
        crontab "$TMP_CRON" >/dev/null 2>&1 || true
        rm -f "$TMP_CRON"
    fi
}

cleanup_dns_refresh() {
    remove_systemd_dns_refresh
    remove_openrc_dns_refresh
}

install_realm_binary() {
    echo ""
    echo "[6/10] 正在安装 realm..."

    TMP_DIR="$(mktemp -d)"
    cd "$TMP_DIR"

    REALM_URL="https://github.com/zhboner/realm/releases/latest/download/realm-${REALM_ARCH}.tar.gz"
    echo "下载地址：$REALM_URL"

    if ! curl -L --fail --retry 3 --connect-timeout 15 -o realm.tar.gz "$REALM_URL"; then
        echo "错误：realm 下载失败，请检查网络或架构是否存在。"
        cd /; rm -rf "$TMP_DIR"; exit 1
    fi

    if ! tar -xzf realm.tar.gz; then
        echo "错误：realm 压缩包解压失败。"
        cd /; rm -rf "$TMP_DIR"; exit 1
    fi

    if [ ! -f realm ]; then
        echo "错误：未找到 realm 可执行文件。"
        cd /; rm -rf "$TMP_DIR"; exit 1
    fi

    install -m 755 realm "$REALM_BIN"
    cd /; rm -rf "$TMP_DIR"
    echo "realm 已成功安装到：$REALM_BIN"
}

append_rule_to_file() {
    RULE_FILE="$1"

    mkdir -p "$REALM_DIR"
    touch "$RULE_FILE"
    chmod 600 "$RULE_FILE"

    if [ "$PROTO" = "tcp" ]; then
        echo "tcp|${LISTEN_PORT}|${REMOTE_HOST}|${REMOTE_PORT}" >> "$RULE_FILE"
    elif [ "$PROTO" = "udp" ]; then
        echo "udp|${LISTEN_PORT}|${REMOTE_HOST}|${REMOTE_PORT}" >> "$RULE_FILE"
    else
        echo "tcp|${LISTEN_PORT}|${REMOTE_HOST}|${REMOTE_PORT}" >> "$RULE_FILE"
        echo "udp|${LISTEN_PORT}|${REMOTE_HOST}|${REMOTE_PORT}" >> "$RULE_FILE"
    fi
}

format_rule_remote_addr() {
    RULE_HOST="$1"
    RULE_PORT="$2"
    if echo "$RULE_HOST" | grep -q ':'; then
        case "$RULE_HOST" in
            \[*\]) echo "${RULE_HOST}:${RULE_PORT}" ;;
            *) echo "[${RULE_HOST}]:${RULE_PORT}" ;;
        esac
    else
        echo "${RULE_HOST}:${RULE_PORT}"
    fi
}

regenerate_realm_config() {
    mkdir -p "$REALM_DIR"
    : > "$REALM_CONF"

    if [ ! -f "$REALM_RULES" ] || [ ! -s "$REALM_RULES" ]; then
        return
    fi

    while IFS='|' read -r RULE_PROTO RULE_LISTEN RULE_HOST RULE_PORT; do
        [ -z "$RULE_PROTO" ] && continue
        [ -z "$RULE_LISTEN" ] && continue
        [ -z "$RULE_HOST" ] && continue
        [ -z "$RULE_PORT" ] && continue

        RULE_REMOTE="$(format_rule_remote_addr "$RULE_HOST" "$RULE_PORT")"

        if [ "$RULE_PROTO" = "tcp" ]; then
            cat >> "$REALM_CONF" <<EOF

[[endpoints]]
listen = "0.0.0.0:${RULE_LISTEN}"
remote = "${RULE_REMOTE}"
EOF
        elif [ "$RULE_PROTO" = "udp" ]; then
            cat >> "$REALM_CONF" <<EOF

[[endpoints]]
listen = "udp://0.0.0.0:${RULE_LISTEN}"
remote = "udp://${RULE_REMOTE}"
EOF
        fi
    done < "$REALM_RULES"
    chmod 644 "$REALM_CONF"
}

write_nft_apply_script() {
    cat > "$NFT_APPLY_SCRIPT" <<'EOF'
#!/bin/sh
set -e

RULES="/etc/realm/rules-nft.conf"

if [ ! -f "$RULES" ] || [ ! -s "$RULES" ]; then
    nft delete table ip realm_forward >/dev/null 2>&1 || true
    echo "没有 nftables 规则，已清理 realm_forward 表。"
    exit 0
fi

nft delete table ip realm_forward >/dev/null 2>&1 || true
nft add table ip realm_forward
nft 'add chain ip realm_forward prerouting { type nat hook prerouting priority dstnat; policy accept; }'
nft 'add chain ip realm_forward postrouting { type nat hook postrouting priority srcnat; policy accept; }'

while IFS='|' read -r RULE_PROTO RULE_LISTEN RULE_HOST RULE_PORT; do
    [ -z "$RULE_PROTO" ] && continue
    [ -z "$RULE_LISTEN" ] && continue
    [ -z "$RULE_HOST" ] && continue
    [ -z "$RULE_PORT" ] && continue

    case "$RULE_PROTO" in
        tcp) nft add rule ip realm_forward prerouting tcp dport "$RULE_LISTEN" dnat to "$RULE_HOST:$RULE_PORT" ;;
        udp) nft add rule ip realm_forward prerouting udp dport "$RULE_LISTEN" dnat to "$RULE_HOST:$RULE_PORT" ;;
    esac
    nft add rule ip realm_forward postrouting ip daddr "$RULE_HOST" masquerade
done < "$RULES"
EOF
    chmod +x "$NFT_APPLY_SCRIPT"
}

apply_nft_rules() {
    if [ ! -x "$NFT_APPLY_SCRIPT" ]; then
        write_nft_apply_script
    fi
    "$NFT_APPLY_SCRIPT" >/dev/null 2>&1
}

add_realm_rule() {
    echo ""
    echo "[7/10] 正在追加 realm 规则..."
    append_rule_to_file "$REALM_RULES"
    regenerate_realm_config
}

add_nft_rule() {
    echo ""
    echo "[7/10] 正在追加 nftables 规则..."
    append_rule_to_file "$NFT_RULES"
    write_nft_apply_script
    apply_nft_rules
}

install_realm_service_systemd() {
    cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Realm Port Forwarding Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
Restart=always
RestartSec=3
ExecStart=${REALM_BIN} -c ${REALM_CONF}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1
    systemctl restart realm
}

install_realm_service_openrc() {
    cat > "$OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run

name="realm"
description="Realm Port Forwarding Service"

command="${REALM_BIN}"
command_args="-c ${REALM_CONF}"
command_background="yes"
pidfile="/run/realm.pid"

start_pre() { ulimit -n 1048576; }
depend() { need net; after firewall; }
EOF
    chmod +x "$OPENRC_SERVICE"
    rc-update add realm default >/dev/null 2>&1 || true

    if rc-service realm status >/dev/null 2>&1; then
        rc-service realm restart >/dev/null 2>&1
    else
        rc-service realm start >/dev/null 2>&1
    fi
}

install_realm_service() {
    echo ""
    echo "[8/10] 正在创建 realm 系统服务..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        install_realm_service_systemd
    else
        install_realm_service_openrc
    fi
}

write_dns_refresh_script() {
    cat > "$DNS_REFRESH_SCRIPT" <<'EOF'
#!/bin/sh

RULES="/etc/realm/rules-realm.conf"
STATE_FILE="/run/realm_dns_rules_state"

if [ ! -f "$RULES" ] || [ ! -s "$RULES" ]; then exit 0; fi

resolve_domain() {
    DOMAIN="$1"
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -n 1
        return
    fi
    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n 1
        return
    fi
    return 1
}

TMP_STATE="$(mktemp)"

while IFS='|' read -r RULE_PROTO RULE_LISTEN RULE_HOST RULE_PORT; do
    [ -z "$RULE_HOST" ] && continue
    if echo "$RULE_HOST" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then continue; fi
    if echo "$RULE_HOST" | grep -q ':'; then continue; fi

    IP="$(resolve_domain "$RULE_HOST")"
    [ -z "$IP" ] && continue
    echo "${RULE_HOST}=${IP}" >> "$TMP_STATE"
done < "$RULES"

if [ ! -s "$TMP_STATE" ]; then rm -f "$TMP_STATE"; exit 0; fi

if [ ! -f "$STATE_FILE" ]; then
    mv "$TMP_STATE" "$STATE_FILE"
    if command -v systemctl >/dev/null 2>&1; then systemctl restart realm >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then rc-service realm restart >/dev/null 2>&1 || true; fi
    exit 0
fi

if ! cmp -s "$TMP_STATE" "$STATE_FILE"; then
    mv "$TMP_STATE" "$STATE_FILE"
    if command -v systemctl >/dev/null 2>&1; then systemctl restart realm >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then rc-service realm restart >/dev/null 2>&1 || true; fi
else
    rm -f "$TMP_STATE"
fi
EOF
    chmod +x "$DNS_REFRESH_SCRIPT"
}

install_dns_refresh_systemd() {
    write_dns_refresh_script
    cat > "$SYSTEMD_REFRESH_SERVICE" <<EOF
[Unit]
Description=Refresh realm DNS targets if domain IP changed

[Service]
Type=oneshot
ExecStart=${DNS_REFRESH_SCRIPT}
EOF
    cat > "$SYSTEMD_REFRESH_TIMER" <<EOF
[Unit]
Description=Run realm DNS refresh periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=${DNS_REFRESH_INTERVAL}min
Unit=realm-dns-refresh.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now realm-dns-refresh.timer >/dev/null 2>&1
}

install_dns_refresh_openrc() {
    install_dns_deps
    write_dns_refresh_script
    remove_openrc_dns_refresh

    TMP_CRON="$(mktemp)"
    crontab -l 2>/dev/null > "$TMP_CRON" || true
    {
        echo "$CRON_BEGIN"
        echo "*/${DNS_REFRESH_INTERVAL} * * * * ${DNS_REFRESH_SCRIPT} >/dev/null 2>&1"
        echo "$CRON_END"
    } >> "$TMP_CRON"
    crontab "$TMP_CRON"
    rm -f "$TMP_CRON"
}

configure_dns_refresh() {
    echo ""
    echo "[9/10] 正在配置 DNS 自动刷新..."
    if [ "$MODE" != "realm" ] || [ "$ENABLE_DNS_REFRESH" != "yes" ]; then
        echo "DNS 自动刷新未启用。"
        return
    fi

    install_dns_deps
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        remove_systemd_dns_refresh
        install_dns_refresh_systemd
    else
        install_dns_refresh_openrc
    fi
    echo "DNS 自动刷新已成功启用。"
}

enable_ip_forward() {
    echo ""
    echo "正在开启 IPv4 内核转发..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    if grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    fi
}

install_nft_service_systemd() {
    cat > "$NFT_SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Realm nftables Port Forwarding Rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${NFT_APPLY_SCRIPT}
ExecStop=/bin/sh -c 'nft delete table ip realm_forward >/dev/null 2>&1 || true'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable realm-nft-forward >/dev/null 2>&1
    systemctl restart realm-nft-forward
}

install_nft_service_openrc() {
    cat > "$NFT_OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run

name="realm-nft-forward"
description="Realm nftables Port Forwarding Rules"

depend() { need net; after firewall; }

start() {
    ebegin "Applying realm nftables forwarding rules"
    ${NFT_APPLY_SCRIPT}
    eend \$?
}

stop() {
    ebegin "Removing realm nftables forwarding rules"
    nft delete table ip realm_forward >/dev/null 2>&1 || true
    eend 0
}
EOF
    chmod +x "$NFT_OPENRC_SERVICE"
    rc-update add realm-nft-forward default >/dev/null 2>&1 || true

    if rc-service realm-nft-forward status >/dev/null 2>&1; then
        rc-service realm-nft-forward restart || true
    else
        rc-service realm-nft-forward start
    fi
}

install_nft_service() {
    echo ""
    echo "[8/10] 正在创建 nftables 转发服务..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        install_nft_service_systemd
    else
        install_nft_service_openrc
    fi
}

install_realm_mode() {
    install_realm_binary
    add_realm_rule
    install_realm_service
    configure_dns_refresh
}

install_nftables_mode() {
    install_nft_deps
    enable_ip_forward
    add_nft_rule
    install_nft_service
}

print_rule_file_numbered() {
    RULE_FILE="$1"
    if [ ! -f "$RULE_FILE" ] || [ ! -s "$RULE_FILE" ]; then
        echo "  暂无规则。"
        return
    fi
    awk -F'|' '{printf "  %d. 协议：%s | 监听：0.0.0.0:%s | 目标：%s:%s\n", NR, $1, $2, $3, $4}' "$RULE_FILE"
}

view_current_rules() {
    while true; do
        echo ""
        print_line
        echo " 当前脚本管理的全部转发规则"
        print_line
        echo ""

        echo "【 realm 规则 】"
        echo "--------------------------------------"
        print_rule_file_numbered "$REALM_RULES"
        echo ""

        echo "【 nftables 规则 】"
        echo "--------------------------------------"
        print_rule_file_numbered "$NFT_RULES"
        echo ""

        read_input "输入 0 返回主菜单: " VIEW_CHOICE

        if [ "$VIEW_CHOICE" = "0" ]; then
            return 0
        fi
    done
}

delete_all_rules() {
    echo ""
    confirm_input "确认删除全部规则？[y/N/0返回]: " CONFIRM_DELETE_ALL

    if [ "$CONFIRM_DELETE_ALL" != "yes" ]; then
        echo "已取消删除。"
        return
    fi

    stop_realm_service
    stop_nft_service
    cleanup_dns_refresh

    rm -f "$REALM_RULES" "$NFT_RULES" "$REALM_CONF"

    if command -v nft >/dev/null 2>&1; then
        nft delete table ip realm_forward >/dev/null 2>&1 || true
    fi
    echo "✅ 全部转发规则已删除。"
}

delete_current_rules() {
    while true; do
        echo ""
        print_line
        echo " 删除转发规则"
        print_line
        echo ""

        local START_IDX=1
        local REALM_COUNT=0
        local NFT_COUNT=0

        if [ -f "$REALM_RULES" ] && [ -s "$REALM_RULES" ]; then
            REALM_COUNT=$(wc -l < "$REALM_RULES" | tr -d ' ')
        fi

        if [ -f "$NFT_RULES" ] && [ -s "$NFT_RULES" ]; then
            NFT_COUNT=$(wc -l < "$NFT_RULES" | tr -d ' ')
        fi

        local TOTAL_RULES=$((REALM_COUNT + NFT_COUNT))

        echo "【 realm 规则 】"
        echo "--------------------------------------"
        if [ "$REALM_COUNT" -gt 0 ]; then
            awk -F'|' -v start="$START_IDX" '{printf "  [%d] 协议：%s | 监听：0.0.0.0:%s | 目标：%s:%s\n", start+NR-1, $1, $2, $3, $4}' "$REALM_RULES"
            START_IDX=$((START_IDX + REALM_COUNT))
        else
            echo "  暂无规则。"
        fi

        echo ""
        echo "【 nftables 规则 】"
        echo "--------------------------------------"
        if [ "$NFT_COUNT" -gt 0 ]; then
            awk -F'|' -v start="$START_IDX" '{printf "  [%d] 协议：%s | 监听：0.0.0.0:%s | 目标：%s:%s\n", start+NR-1, $1, $2, $3, $4}' "$NFT_RULES"
        else
            echo "  暂无规则。"
        fi

        echo ""
        echo "操作菜单："
        echo "  [数字编号] 删除对应单条规则"
        echo "  [a]        删除全部规则"
        echo "  [0]        返回主菜单"
        echo ""

        read_input "请输入选项: " DEL_CHOICE

        case "$DEL_CHOICE" in
            0) return 0 ;;
            a|A)
                delete_all_rules
                continue
                ;;
            ''|*[!0-9]*)
                echo "错误：无效选项或编号。"
                continue
                ;;
        esac

        if [ "$DEL_CHOICE" -lt 1 ] || [ "$DEL_CHOICE" -gt "$TOTAL_RULES" ]; then
            echo "错误：输入编号超出范围。"
            continue
        fi

        if [ "$DEL_CHOICE" -le "$REALM_COUNT" ]; then
            TARGET_FILE="$REALM_RULES"
            TARGET_LINE="$DEL_CHOICE"
            TARGET_NAME="realm"
        else
            TARGET_FILE="$NFT_RULES"
            TARGET_LINE=$((DEL_CHOICE - REALM_COUNT))
            TARGET_NAME="nftables"
        fi

        RULE_LINE="$(sed -n "${TARGET_LINE}p" "$TARGET_FILE")"
        RULE_PROTO="$(echo "$RULE_LINE" | awk -F'|' '{print $1}')"
        RULE_LISTEN="$(echo "$RULE_LINE" | awk -F'|' '{print $2}')"
        RULE_HOST="$(echo "$RULE_LINE" | awk -F'|' '{print $3}')"
        RULE_PORT="$(echo "$RULE_LINE" | awk -F'|' '{print $4}')"

        echo ""
        echo "即将删除以下 [${TARGET_NAME}] 规则："
        echo "协议：$RULE_PROTO | 监听：0.0.0.0:$RULE_LISTEN | 目标：$RULE_HOST:$RULE_PORT"
        echo ""

        confirm_input "确认删除？[y/N/0返回]: " CONFIRM_DELETE

        if [ "$CONFIRM_DELETE" = "back" ]; then continue; fi
        if [ "$CONFIRM_DELETE" != "yes" ]; then
            echo "已取消删除。"
            continue
        fi

        TMP_FILE="$(mktemp)"
        awk -v line="$TARGET_LINE" 'NR != line {print}' "$TARGET_FILE" > "$TMP_FILE"
        mv "$TMP_FILE" "$TARGET_FILE"

        if [ "$TARGET_NAME" = "realm" ]; then
            regenerate_realm_config
            if [ -s "$TARGET_FILE" ]; then
                if [ "$SERVICE_MANAGER" = "systemd" ]; then
                    systemctl restart realm >/dev/null 2>&1 || true
                else
                    rc-service realm restart >/dev/null 2>&1 || true
                fi
            else
                stop_realm_service
                rm -f "$REALM_CONF"
            fi
        else
            if [ -s "$TARGET_FILE" ]; then
                apply_nft_rules
            else
                stop_nft_service
            fi
        fi

        echo "✅ 已成功删除该规则。"
    done
}

uninstall_all() {
    echo ""
    print_line
    echo " 卸载脚本安装的全部内容"
    print_line
    echo ""
    echo "注意：仅卸载 realm/配置/定时任务/内部表，不会卸载 curl、nftables 等系统依赖包。"
    echo ""
    confirm_input "确认卸载全部内容？[y/N/0返回]: " CONFIRM_UNINSTALL

    if [ "$CONFIRM_UNINSTALL" != "yes" ]; then
        echo "已取消卸载。"
        return 0
    fi

    stop_realm_service
    stop_nft_service
    cleanup_dns_refresh

    rm -f "$REALM_BIN" "$DNS_REFRESH_SCRIPT" "$NFT_APPLY_SCRIPT"
    rm -rf "$REALM_DIR"

    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        rm -f "$SYSTEMD_SERVICE" "$NFT_SYSTEMD_SERVICE" "$SYSTEMD_REFRESH_SERVICE" "$SYSTEMD_REFRESH_TIMER"
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rm -f "$OPENRC_SERVICE" "$NFT_OPENRC_SERVICE"
    fi

    if command -v nft >/dev/null 2>&1; then
        nft delete table ip realm_forward >/dev/null 2>&1 || true
    fi

    rm -f "$SHORTCUT_BIN"

    echo ""
    echo "✅ 卸载完成！脚本相关服务和配置已被全数清除。"
    echo ""
    exit 0
}

show_result() {
    echo ""
    echo "[10/10] 安装结果汇总"
    echo "--------------------------------------"
    echo "转发方式 ：$MODE"
    echo "监听地址 ：0.0.0.0:${LISTEN_PORT}"
    echo "目标地址 ：${REMOTE_ADDR}"
    echo "协议     ：$PROTO"
    echo "--------------------------------------"
    echo ""

    if [ "$MODE" = "realm" ]; then
        echo "【 realm 当前规则 】："
        print_rule_file_numbered "$REALM_RULES"
        echo ""
    else
        echo "【 nftables 当前规则 】："
        print_rule_file_numbered "$NFT_RULES"
        echo ""
    fi

    echo "【 注意事项 】："
    echo "1. 请在云服务器安全组/防火墙中放行监听端口 [ ${LISTEN_PORT} ]"
    echo "2. nftables 模式下，端口处于内核 NAT 转发层级，使用 netstat 或 ss 将无法查看到 LISTEN 状态（这是正常现象）"
    echo "3. 日常管理可通过在终端直接输入快捷命令：vfm 打开本脚本"
    echo ""
}

detect_os
install_base_deps
detect_arch
install_shortcut
show_system_info

while true; do
    ask_action || continue

    case "$ACTION" in
        create)
            while true; do
                ask_mode || break
                ask_forward_config || continue

                if [ "$MODE" = "realm" ]; then
                    install_realm_mode
                else
                    install_nftables_mode
                fi

                show_result
                break
            done
            ;;
        view)
            view_current_rules
            ;;
        delete)
            delete_current_rules
            ;;
        uninstall)
            uninstall_all
            ;;
    esac
done
