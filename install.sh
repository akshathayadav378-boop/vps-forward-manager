#!/bin/sh
set -e

REALM_BIN="/usr/local/bin/realm"
REALM_DIR="/etc/realm"
REALM_CONF="$REALM_DIR/config.toml"
REALM_RULES="$REALM_DIR/rules-realm.conf"
NFT_RULES="$REALM_DIR/rules-nft.conf"
DNS_REFRESH_SCRIPT="/usr/local/bin/realm-dns-refresh.sh"
NFT_APPLY_SCRIPT="/usr/local/bin/realm-nft-apply.sh"
SHORTCUT_BIN="/usr/local/bin/vfm"
LOW_MEMORY_SYSCTL="/etc/sysctl.d/99-vfm-low-memory.conf"
SWAP_FILE="/swapfile-vfm"

SYSTEMD_REALM="/etc/systemd/system/realm.service"
SYSTEMD_NFT="/etc/systemd/system/realm-nft-forward.service"
SYSTEMD_DNS_SERVICE="/etc/systemd/system/realm-dns-refresh.service"
SYSTEMD_DNS_TIMER="/etc/systemd/system/realm-dns-refresh.timer"
OPENRC_REALM="/etc/init.d/realm"
OPENRC_NFT="/etc/init.d/realm-nft-forward"

CRON_BEGIN="# BEGIN VPS FORWARD MANAGER DNS REFRESH"
CRON_END="# END VPS FORWARD MANAGER DNS REFRESH"

OS_FAMILY=""
SERVICE_MANAGER=""
REALM_ARCH=""
MODE=""
ACTION=""
PROTO="tcp"
LISTEN_PORT=""
REMOTE_HOST=""
REMOTE_PORT=""
REMOTE_ADDR=""
ENABLE_DNS_REFRESH="no"
DNS_REFRESH_INTERVAL="10"

TOTAL_MEM_MB="0"
MEM_PROFILE="normal"
REALM_MEM_MAX_MB="128"
REALM_MEM_HIGH_MB="96"
REALM_NOFILE="16384"
SOMAXCONN="4096"
BACKLOG="8192"
RMEM_MAX="8388608"
WMEM_MAX="8388608"
SWAPPINESS="30"
VFS_CACHE_PRESSURE="120"

line() {
    echo "======================================"
}

read_input() {
    prompt="$1"
    var="$2"

    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        printf "%s" "$prompt" > /dev/tty
        IFS= read -r val < /dev/tty
    else
        printf "%s" "$prompt"
        IFS= read -r val
    fi

    eval "$var=\$val"
}

confirm_input() {
    read_input "$1" ans
    case "$ans" in
        y|Y|yes|YES) eval "$2=yes" ;;
        0) eval "$2=back" ;;
        *) eval "$2=no" ;;
    esac
}

header() {
    line
    echo " VPS 端口转发一键管理脚本"
    echo " 支持系统：Debian / Ubuntu / Alpine"
    echo " 转发方式：realm / nftables"
    echo " 优化：128M 小内存 / 内存限制 / 进程守护 / 缓存清理"
    line
    echo
}

need_root() {
    [ "$(id -u)" = "0" ] || {
        echo "错误：请使用 root 用户运行。"
        exit 1
    }
}

detect_os() {
    [ -f /etc/os-release ] || {
        echo "错误：无法检测系统。"
        exit 1
    }

    . /etc/os-release

    case "${ID:-}" in
        debian|ubuntu)
            OS_FAMILY="debian"
            SERVICE_MANAGER="systemd"
            ;;
        alpine)
            OS_FAMILY="alpine"
            SERVICE_MANAGER="openrc"
            ;;
        *)
            case "${ID_LIKE:-}" in
                *debian*)
                    OS_FAMILY="debian"
                    SERVICE_MANAGER="systemd"
                    ;;
                *)
                    echo "错误：仅支持 Debian / Ubuntu / Alpine。"
                    exit 1
                    ;;
            esac
            ;;
    esac

    if [ "$SERVICE_MANAGER" = "systemd" ] && ! command -v systemctl >/dev/null 2>&1; then
        echo "错误：当前系统没有 systemctl。"
        exit 1
    fi

    if [ "$SERVICE_MANAGER" = "openrc" ] && ! command -v rc-service >/dev/null 2>&1; then
        echo "错误：当前 Alpine 没有 OpenRC。"
        exit 1
    fi
}

mem_mb() {
    awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}

calc_memory() {
    TOTAL_MEM_MB="$(mem_mb)"
    [ -z "$TOTAL_MEM_MB" ] && TOTAL_MEM_MB=0

    if [ "$TOTAL_MEM_MB" -gt 0 ] && [ "$TOTAL_MEM_MB" -le 160 ]; then
        MEM_PROFILE="128M/low"
        REALM_MEM_MAX_MB=48
        REALM_MEM_HIGH_MB=40
        REALM_NOFILE=4096
        SOMAXCONN=1024
        BACKLOG=2048
        RMEM_MAX=2097152
        WMEM_MAX=2097152
        SWAPPINESS=60
        VFS_CACHE_PRESSURE=200
    elif [ "$TOTAL_MEM_MB" -gt 0 ] && [ "$TOTAL_MEM_MB" -le 256 ]; then
        MEM_PROFILE="256M/low"
        REALM_MEM_MAX_MB=64
        REALM_MEM_HIGH_MB=52
        REALM_NOFILE=8192
        SOMAXCONN=2048
        BACKLOG=4096
        RMEM_MAX=4194304
        WMEM_MAX=4194304
        SWAPPINESS=50
        VFS_CACHE_PRESSURE=180
    elif [ "$TOTAL_MEM_MB" -gt 0 ] && [ "$TOTAL_MEM_MB" -le 512 ]; then
        MEM_PROFILE="512M/balanced"
        REALM_MEM_MAX_MB=128
        REALM_MEM_HIGH_MB=96
        REALM_NOFILE=16384
        SOMAXCONN=4096
        BACKLOG=8192
        RMEM_MAX=8388608
        WMEM_MAX=8388608
        SWAPPINESS=30
        VFS_CACHE_PRESSURE=150
    elif [ "$TOTAL_MEM_MB" -gt 0 ] && [ "$TOTAL_MEM_MB" -le 1024 ]; then
        MEM_PROFILE="1G/normal"
        REALM_MEM_MAX_MB=256
        REALM_MEM_HIGH_MB=192
        REALM_NOFILE=32768
        SOMAXCONN=8192
        BACKLOG=16384
        RMEM_MAX=16777216
        WMEM_MAX=16777216
        SWAPPINESS=20
        VFS_CACHE_PRESSURE=120
    else
        MEM_PROFILE="normal"
        REALM_MEM_MAX_MB=512
        REALM_MEM_HIGH_MB=384
        REALM_NOFILE=65535
        SOMAXCONN=16384
        BACKLOG=32768
        RMEM_MAX=33554432
        WMEM_MAX=33554432
        SWAPPINESS=10
        VFS_CACHE_PRESSURE=100
    fi
}

install_base_deps() {
    echo "[1/10] 正在安装基础依赖..."

    case "$OS_FAMILY" in
        debian)
            apt-get update >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar ca-certificates iproute2 procps grep coreutils >/dev/null 2>&1
            ;;
        alpine)
            apk update >/dev/null 2>&1 || true
            apk add --no-cache curl tar ca-certificates iproute2 procps grep gawk coreutils openrc >/dev/null 2>&1
            ;;
    esac
}

install_dns_deps() {
    case "$OS_FAMILY" in
        debian)
            apt-get update >/dev/null 2>&1 || true
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
    echo "正在安装 nftables 依赖..."

    case "$OS_FAMILY" in
        debian)
            apt-get update >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y nftables >/dev/null 2>&1
            ;;
        alpine)
            apk add --no-cache nftables >/dev/null 2>&1
            ;;
    esac
}

cleanup_cache() {
    case "$OS_FAMILY" in
        debian)
            apt-get clean >/dev/null 2>&1 || true
            rm -rf /var/cache/apt/archives/*.deb >/dev/null 2>&1 || true
            ;;
        alpine)
            rm -rf /var/cache/apk/* >/dev/null 2>&1 || true
            ;;
    esac
}

detect_arch() {
    arch="$(uname -m)"

    case "$arch" in
        x86_64|amd64) cpu="x86_64" ;;
        aarch64|arm64) cpu="aarch64" ;;
        armv7l|armv7) cpu="armv7" ;;
        *)
            echo "错误：不支持 CPU 架构：$arch"
            exit 1
            ;;
    esac

    case "$OS_FAMILY:$cpu" in
        debian:x86_64) REALM_ARCH="x86_64-unknown-linux-gnu" ;;
        debian:aarch64) REALM_ARCH="aarch64-unknown-linux-gnu" ;;
        debian:armv7) REALM_ARCH="armv7-unknown-linux-gnueabihf" ;;
        alpine:x86_64) REALM_ARCH="x86_64-unknown-linux-musl" ;;
        alpine:aarch64) REALM_ARCH="aarch64-unknown-linux-musl" ;;
        alpine:armv7) REALM_ARCH="armv7-unknown-linux-musleabihf" ;;
    esac
}

install_shortcut() {
    [ "$0" = "$SHORTCUT_BIN" ] && return

    if [ -f "$0" ]; then
        cp "$0" "$SHORTCUT_BIN" >/dev/null 2>&1 || true
        chmod +x "$SHORTCUT_BIN" >/dev/null 2>&1 || true
    fi
}

low_mem_swap() {
    [ "$TOTAL_MEM_MB" -gt 0 ] && [ "$TOTAL_MEM_MB" -le 192 ] || return

    awk 'NR > 1 {found=1} END {exit !found}' /proc/swaps 2>/dev/null && return

    echo "检测到小内存机器，正在尝试创建 256M swap 防止 OOM..."

    if [ ! -f "$SWAP_FILE" ]; then
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l 256M "$SWAP_FILE" >/dev/null 2>&1 || true
        fi

        [ -f "$SWAP_FILE" ] || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=256 >/dev/null 2>&1 || true
    fi

    if [ -f "$SWAP_FILE" ]; then
        chmod 600 "$SWAP_FILE" >/dev/null 2>&1 || true
        mkswap "$SWAP_FILE" >/dev/null 2>&1 || true

        if swapon "$SWAP_FILE" >/dev/null 2>&1; then
            grep -q "^$SWAP_FILE " /etc/fstab 2>/dev/null || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
            echo "swap 已启用：$SWAP_FILE"
        else
            echo "提示：当前系统不允许启用 swap，已跳过。"
        fi
    fi
}

apply_low_mem_sysctl() {
    mkdir -p /etc/sysctl.d >/dev/null 2>&1 || true

    cat > "$LOW_MEMORY_SYSCTL" <<EOF
# VPS Forward Manager low-memory tuning
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = ${VFS_CACHE_PRESSURE}
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${BACKLOG}
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
EOF

    sysctl -p "$LOW_MEMORY_SYSCTL" >/dev/null 2>&1 || true
}

show_info() {
    echo
    echo "[2/10] 当前系统信息"
    echo "--------------------------------------"
    echo "系统类型       ：$OS_FAMILY"
    echo "服务管理器     ：$SERVICE_MANAGER"
    echo "CPU 架构       ：$(uname -m)"
    echo "内存总量       ：${TOTAL_MEM_MB} MB"
    echo "低内存档位     ：$MEM_PROFILE"
    echo "realm内存上限  ：${REALM_MEM_MAX_MB} MB"
    echo "realm文件句柄  ：$REALM_NOFILE"
    echo "快捷命令       ：vfm"
    echo "--------------------------------------"
    echo
}

valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac

    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_ipv4() {
    echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

is_ipv6() {
    echo "$1" | grep -q ':'
}

is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}

format_remote() {
    if is_ipv6 "$1"; then
        case "$1" in
            \[*\]) REMOTE_ADDR="$1:$2" ;;
            *) REMOTE_ADDR="[$1]:$2" ;;
        esac
    else
        REMOTE_ADDR="$1:$2"
    fi
}

ask_action() {
    line
    echo " 主菜单"
    line
    echo "1) 新建转发规则"
    echo "2) 查看目前转发规则"
    echo "3) 删除转发规则"
    echo "4) 卸载脚本安装的全部内容"
    echo "0) 退出脚本"
    echo

    read_input "请输入选项 [0-4]: " c

    case "$c" in
        1) ACTION="create" ;;
        2) ACTION="view" ;;
        3) ACTION="delete" ;;
        4) ACTION="uninstall" ;;
        0)
            echo "已退出脚本。"
            exit 0
            ;;
        *)
            echo "错误：无效选项。"
            return 1
            ;;
    esac
}

ask_mode() {
    echo
    echo "[4/10] 请选择转发方式"
    echo "--------------------------------------"
    echo "1) realm    - 用户态转发，支持域名/IP，适合动态域名"
    echo "2) nftables - 内核级 DNAT/SNAT，性能更好，目标必须固定IPv4"
    echo "0) 返回主菜单"
    echo "--------------------------------------"

    read_input "请输入选项 [0-2]: " c

    case "$c" in
        1) MODE="realm" ;;
        2) MODE="nftables" ;;
        0) return 1 ;;
        *)
            echo "错误：无效选项。"
            return 1
            ;;
    esac

    echo "已选择：$MODE"
}

dup_in_file() {
    [ -f "$1" ] && awk -F'|' -v p="$2" -v port="$3" '$1==p && $2==port {f=1} END{exit !f}' "$1"
}

check_dup_one() {
    if dup_in_file "$REALM_RULES" "$1" "$2"; then
        echo "错误：realm 已存在 $1/$2。"
        return 1
    fi

    if dup_in_file "$NFT_RULES" "$1" "$2"; then
        echo "错误：nftables 已存在 $1/$2。"
        return 1
    fi
}

check_dup() {
    case "$PROTO" in
        tcp) check_dup_one tcp "$LISTEN_PORT" ;;
        udp) check_dup_one udp "$LISTEN_PORT" ;;
        both) check_dup_one tcp "$LISTEN_PORT" && check_dup_one udp "$LISTEN_PORT" ;;
    esac
}

ask_forward() {
    step=1

    while true; do
        case "$step" in
            1)
                echo
                echo "[5/10] 配置转发信息"
                echo "--------------------------------------"
                read_input "第一步 - 请输入本机监听端口 (输入0返回): " LISTEN_PORT

                [ "$LISTEN_PORT" = 0 ] && return 1

                valid_port "$LISTEN_PORT" || {
                    echo "错误：端口必须是 1-65535。"
                    continue
                }

                step=2
                ;;

            2)
                read_input "第二步 - 请输入目标域名或 IP (输入0返回): " REMOTE_HOST

                [ "$REMOTE_HOST" = 0 ] && {
                    step=1
                    continue
                }

                [ -n "$REMOTE_HOST" ] || {
                    echo "错误：目标不能为空。"
                    continue
                }

                step=3
                ;;

            3)
                read_input "第三步 - 请输入目标端口 (输入0返回): " REMOTE_PORT

                [ "$REMOTE_PORT" = 0 ] && {
                    step=2
                    continue
                }

                valid_port "$REMOTE_PORT" || {
                    echo "错误：端口必须是 1-65535。"
                    continue
                }

                step=4
                ;;

            4)
                echo
                echo "请选择协议："
                echo "1) TCP"
                echo "2) UDP"
                echo "3) TCP + UDP"
                echo "0) 返回上一步"
                echo

                read_input "请输入选项 [默认1]: " c

                case "$c" in
                    ""|1) PROTO=tcp ;;
                    2) PROTO=udp ;;
                    3) PROTO=both ;;
                    0)
                        step=3
                        continue
                        ;;
                    *)
                        echo "错误：无效协议。"
                        continue
                        ;;
                esac

                format_remote "$REMOTE_HOST" "$REMOTE_PORT"

                if [ "$MODE" = nftables ] && ! is_ipv4 "$REMOTE_HOST"; then
                    echo "错误：nftables 模式仅支持固定 IPv4，域名/IPv6 请用 realm。"
                    step=2
                    continue
                fi

                check_dup || {
                    step=1
                    continue
                }

                step=5
                ;;

            5)
                ENABLE_DNS_REFRESH=no

                if [ "$MODE" = realm ] && ! is_ip "$REMOTE_HOST"; then
                    echo
                    echo "检测到目标为域名，是否启用 DNS 自动刷新？"
                    echo "y) 启用"
                    echo "N) 不启用"
                    echo "0) 返回上一步"
                    echo

                    read_input "请输入选项 [y/N/0]: " c

                    case "$c" in
                        y|Y|yes|YES)
                            ENABLE_DNS_REFRESH=yes

                            while true; do
                                read_input "DNS 刷新间隔分钟数 [默认10，输入0返回]: " t

                                [ "$t" = 0 ] && {
                                    step=4
                                    continue 2
                                }

                                [ -n "$t" ] && DNS_REFRESH_INTERVAL="$t"

                                case "$DNS_REFRESH_INTERVAL" in
                                    ''|*[!0-9]*)
                                        echo "错误：必须是数字。"
                                        continue
                                        ;;
                                esac

                                [ "$DNS_REFRESH_INTERVAL" -ge 1 ] || {
                                    echo "错误：不能小于1。"
                                    continue
                                }

                                break
                            done
                            ;;
                        0)
                            step=4
                            continue
                            ;;
                    esac
                fi

                step=6
                ;;

            6)
                echo
                line
                echo " 配置确认"
                line
                echo "转发方式 ：$MODE"
                echo "监听地址 ：0.0.0.0:$LISTEN_PORT"
                echo "目标地址 ：$REMOTE_ADDR"
                echo "协议     ：$PROTO"
                [ "$MODE" = realm ] && echo "DNS 刷新 ：$ENABLE_DNS_REFRESH"
                echo

                confirm_input "确认安装？[y/N/0返回]: " ok

                case "$ok" in
                    yes) return 0 ;;
                    back) step=5 ;;
                    *)
                        echo "已取消本次新建。"
                        return 1
                        ;;
                esac
                ;;
        esac
    done
}

stop_realm() {
    if [ "$SERVICE_MANAGER" = systemd ]; then
        systemctl disable --now realm >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_REALM"
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rc-service realm stop >/dev/null 2>&1 || true
        rc-update del realm default >/dev/null 2>&1 || true
        rm -f "$OPENRC_REALM"
    fi
}

stop_nft() {
    if [ "$SERVICE_MANAGER" = systemd ]; then
        systemctl disable --now realm-nft-forward >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_NFT"
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rc-service realm-nft-forward stop >/dev/null 2>&1 || true
        rc-update del realm-nft-forward default >/dev/null 2>&1 || true
        rm -f "$OPENRC_NFT"
    fi

    command -v nft >/dev/null 2>&1 && nft delete table ip realm_forward >/dev/null 2>&1 || true
}

remove_dns_refresh() {
    if [ "$SERVICE_MANAGER" = systemd ]; then
        systemctl disable --now realm-dns-refresh.timer >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_DNS_SERVICE" "$SYSTEMD_DNS_TIMER"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if command -v crontab >/dev/null 2>&1; then
        tmp="$(mktemp)"
        crontab -l 2>/dev/null | awk "/$CRON_BEGIN/ {s=1; next} /$CRON_END/ {s=0; next} s!=1 {print}" > "$tmp" || true
        crontab "$tmp" >/dev/null 2>&1 || true
        rm -f "$tmp"
    fi
}

install_realm_bin() {
    echo
    echo "[6/10] 正在安装 realm..."

    tmp="$(mktemp -d)"
    cd "$tmp"

    url="https://github.com/zhboner/realm/releases/latest/download/realm-${REALM_ARCH}.tar.gz"
    echo "下载地址：$url"

    curl -L --fail --retry 3 --connect-timeout 15 -o realm.tar.gz "$url" || {
        echo "错误：realm 下载失败。"
        cd /
        rm -rf "$tmp"
        exit 1
    }

    tar -xzf realm.tar.gz || {
        echo "错误：realm 解压失败。"
        cd /
        rm -rf "$tmp"
        exit 1
    }

    [ -f realm ] || {
        echo "错误：未找到 realm 可执行文件。"
        cd /
        rm -rf "$tmp"
        exit 1
    }

    install -m 755 realm "$REALM_BIN"

    cd /
    rm -rf "$tmp"
}

append_rule() {
    mkdir -p "$REALM_DIR"
    touch "$1"
    chmod 600 "$1"

    case "$PROTO" in
        tcp)
            echo "tcp|$LISTEN_PORT|$REMOTE_HOST|$REMOTE_PORT" >> "$1"
            ;;
        udp)
            echo "udp|$LISTEN_PORT|$REMOTE_HOST|$REMOTE_PORT" >> "$1"
            ;;
        both)
            echo "tcp|$LISTEN_PORT|$REMOTE_HOST|$REMOTE_PORT" >> "$1"
            echo "udp|$LISTEN_PORT|$REMOTE_HOST|$REMOTE_PORT" >> "$1"
            ;;
    esac
}

rule_remote() {
    if echo "$1" | grep -q ':'; then
        case "$1" in
            \[*\]) echo "$1:$2" ;;
            *) echo "[$1]:$2" ;;
        esac
    else
        echo "$1:$2"
    fi
}

regen_realm_conf() {
    mkdir -p "$REALM_DIR"
    : > "$REALM_CONF"

    [ -s "$REALM_RULES" ] || return

    while IFS='|' read -r p l h r; do
        [ -z "$p" ] && continue

        rr="$(rule_remote "$h" "$r")"

        if [ "$p" = tcp ]; then
            cat >> "$REALM_CONF" <<EOF

[[endpoints]]
listen = "0.0.0.0:$l"
remote = "$rr"
EOF
        elif [ "$p" = udp ]; then
            cat >> "$REALM_CONF" <<EOF

[[endpoints]]
listen = "udp://0.0.0.0:$l"
remote = "udp://$rr"
EOF
        fi
    done < "$REALM_RULES"

    chmod 644 "$REALM_CONF"
}

write_nft_apply() {
    cat > "$NFT_APPLY_SCRIPT" <<'EOF'
#!/bin/sh
set -e

RULES="/etc/realm/rules-nft.conf"

if [ ! -s "$RULES" ]; then
    nft delete table ip realm_forward >/dev/null 2>&1 || true
    exit 0
fi

nft delete table ip realm_forward >/dev/null 2>&1 || true
nft add table ip realm_forward
nft 'add chain ip realm_forward prerouting { type nat hook prerouting priority dstnat; policy accept; }'
nft 'add chain ip realm_forward postrouting { type nat hook postrouting priority srcnat; policy accept; }'

while IFS='|' read -r p l h r; do
    [ -z "$p" ] && continue

    case "$p" in
        tcp) nft add rule ip realm_forward prerouting tcp dport "$l" dnat to "$h:$r" ;;
        udp) nft add rule ip realm_forward prerouting udp dport "$l" dnat to "$h:$r" ;;
    esac

    nft add rule ip realm_forward postrouting ip daddr "$h" masquerade
done < "$RULES"
EOF

    chmod +x "$NFT_APPLY_SCRIPT"
}

apply_nft() {
    [ -x "$NFT_APPLY_SCRIPT" ] || write_nft_apply
    "$NFT_APPLY_SCRIPT" >/dev/null 2>&1
}

service_realm_systemd() {
    cat > "$SYSTEMD_REALM" <<EOF
[Unit]
Description=Realm Port Forwarding Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
LimitNOFILE=${REALM_NOFILE}
TasksMax=64
MemoryAccounting=true
MemoryHigh=${REALM_MEM_HIGH_MB}M
MemoryMax=${REALM_MEM_MAX_MB}M
OOMPolicy=kill
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

service_realm_openrc() {
    cat > "$OPENRC_REALM" <<EOF
#!/sbin/openrc-run
name="realm"
description="Realm Port Forwarding Service"
supervisor="supervise-daemon"
command="${REALM_BIN}"
command_args="-c ${REALM_CONF}"
command_user="root"
respawn_delay=3
respawn_max=0
respawn_period=30
start_pre() {
    ulimit -n ${REALM_NOFILE}
    ulimit -v $((REALM_MEM_MAX_MB * 1024)) || true
}
depend() { need net; after firewall; }
EOF

    chmod +x "$OPENRC_REALM"
    rc-update add realm default >/dev/null 2>&1 || true
    rc-service realm restart >/dev/null 2>&1 || rc-service realm start >/dev/null 2>&1
}

install_realm_service() {
    echo
    echo "[8/10] 正在创建 realm 守护服务..."

    if [ "$SERVICE_MANAGER" = systemd ]; then
        service_realm_systemd
    else
        service_realm_openrc
    fi
}

write_dns_script() {
    cat > "$DNS_REFRESH_SCRIPT" <<'EOF'
#!/bin/sh
RULES="/etc/realm/rules-realm.conf"
STATE="/run/realm_dns_rules_state"

[ -s "$RULES" ] || exit 0

resolve() {
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$1" 2>/dev/null | awk '{print $1}' | head -n 1
        return
    fi

    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$1" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n 1
        return
    fi
}

tmp="$(mktemp)"

while IFS='|' read -r p l h r; do
    [ -z "$h" ] && continue
    echo "$h" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && continue
    echo "$h" | grep -q ':' && continue

    ip="$(resolve "$h")"
    [ -n "$ip" ] && echo "$h=$ip" >> "$tmp"
done < "$RULES"

[ -s "$tmp" ] || {
    rm -f "$tmp"
    exit 0
}

if [ ! -f "$STATE" ] || ! cmp -s "$tmp" "$STATE"; then
    mv "$tmp" "$STATE"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart realm >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service realm restart >/dev/null 2>&1 || true
    fi
else
    rm -f "$tmp"
fi
EOF

    chmod +x "$DNS_REFRESH_SCRIPT"
}

install_dns_refresh() {
    echo
    echo "[9/10] 正在配置 DNS 自动刷新..."

    [ "$MODE" = realm ] && [ "$ENABLE_DNS_REFRESH" = yes ] || {
        echo "DNS 自动刷新未启用。"
        return
    }

    install_dns_deps
    write_dns_script
    remove_dns_refresh

    if [ "$SERVICE_MANAGER" = systemd ]; then
        cat > "$SYSTEMD_DNS_SERVICE" <<EOF
[Unit]
Description=Refresh realm DNS targets if domain IP changed
[Service]
Type=oneshot
MemoryAccounting=true
MemoryMax=32M
ExecStart=${DNS_REFRESH_SCRIPT}
EOF

        cat > "$SYSTEMD_DNS_TIMER" <<EOF
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
    else
        tmp="$(mktemp)"
        crontab -l 2>/dev/null > "$tmp" || true
        {
            echo "$CRON_BEGIN"
            echo "*/${DNS_REFRESH_INTERVAL} * * * * ${DNS_REFRESH_SCRIPT} >/dev/null 2>&1"
            echo "$CRON_END"
        } >> "$tmp"
        crontab "$tmp"
        rm -f "$tmp"
    fi
}

enable_ip_forward() {
    echo
    echo "正在开启 IPv4 内核转发..."

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    if grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    fi
}

service_nft_systemd() {
    cat > "$SYSTEMD_NFT" <<EOF
[Unit]
Description=Realm nftables Port Forwarding Rules
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
MemoryAccounting=true
MemoryMax=32M
ExecStart=${NFT_APPLY_SCRIPT}
ExecStop=/bin/sh -c 'nft delete table ip realm_forward >/dev/null 2>&1 || true'
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm-nft-forward >/dev/null 2>&1
    systemctl restart realm-nft-forward
}

service_nft_openrc() {
    cat > "$OPENRC_NFT" <<EOF
#!/sbin/openrc-run
name="realm-nft-forward"
description="Realm nftables Port Forwarding Rules"
depend() { need net; after firewall; }
start() { ebegin "Applying realm nftables forwarding rules"; ${NFT_APPLY_SCRIPT}; eend \$?; }
stop() { ebegin "Removing realm nftables forwarding rules"; nft delete table ip realm_forward >/dev/null 2>&1 || true; eend 0; }
EOF

    chmod +x "$OPENRC_NFT"
    rc-update add realm-nft-forward default >/dev/null 2>&1 || true
    rc-service realm-nft-forward restart >/dev/null 2>&1 || rc-service realm-nft-forward start >/dev/null 2>&1
}

install_nft_service() {
    echo
    echo "[8/10] 正在创建 nftables 转发服务..."

    if [ "$SERVICE_MANAGER" = systemd ]; then
        service_nft_systemd
    else
        service_nft_openrc
    fi
}

install_realm_mode() {
    apply_low_mem_sysctl
    low_mem_swap
    install_realm_bin
    echo
    echo "[7/10] 正在追加 realm 规则..."
    append_rule "$REALM_RULES"
    regen_realm_conf
    install_realm_service
    install_dns_refresh
    cleanup_cache
}

install_nftables_mode() {
    apply_low_mem_sysctl
    low_mem_swap
    install_nft_deps
    enable_ip_forward
    echo
    echo "[7/10] 正在追加 nftables 规则..."
    append_rule "$NFT_RULES"
    write_nft_apply
    apply_nft
    install_nft_service
    cleanup_cache
}

print_rules() {
    f="$1"

    [ -s "$f" ] || {
        echo "  暂无规则。"
        return
    }

    awk -F'|' '{printf "  %d. 协议：%s | 监听：0.0.0.0:%s | 目标：%s:%s\n", NR, $1, $2, $3, $4}' "$f"
}

view_rules() {
    while true; do
        echo
        line
        echo " 当前脚本管理的全部转发规则"
        line
        echo

        echo "【 realm 规则 】"
        echo "--------------------------------------"
        print_rules "$REALM_RULES"
        echo

        echo "【 nftables 规则 】"
        echo "--------------------------------------"
        print_rules "$NFT_RULES"
        echo

        read_input "输入 0 返回主菜单: " c
        [ "$c" = 0 ] && return
    done
}

delete_all_rules() {
    confirm_input "确认删除全部规则？[y/N/0返回]: " ok

    [ "$ok" = yes ] || {
        echo "已取消删除。"
        return
    }

    stop_realm
    stop_nft
    remove_dns_refresh

    rm -f "$REALM_RULES" "$NFT_RULES" "$REALM_CONF"

    command -v nft >/dev/null 2>&1 && nft delete table ip realm_forward >/dev/null 2>&1 || true

    echo "全部转发规则已删除。"
}

delete_rules() {
    while true; do
        echo
        line
        echo " 删除转发规则"
        line
        echo

        rc=0
        nc=0
        start=1

        [ -s "$REALM_RULES" ] && rc=$(wc -l < "$REALM_RULES" | tr -d ' ')
        [ -s "$NFT_RULES" ] && nc=$(wc -l < "$NFT_RULES" | tr -d ' ')

        total=$((rc + nc))

        echo "【 realm 规则 】"
        echo "--------------------------------------"

        if [ "$rc" -gt 0 ]; then
            awk -F'|' -v s="$start" '{printf "  [%d] 协议：%s | 监听：0.0.0.0:%s | 目标：%s:%s\n", s+NR-1, $1, $2, $3, $4}' "$REALM_RULES"
            start=$((start+rc))
        else
            echo "  暂无规则。"
        fi

        echo
        echo "【 nftables 规则 】"
        echo "--------------------------------------"

        if [ "$nc" -gt 0 ]; then
            awk -F'|' -v s="$start" '{printf "  [%d] 协议：%s | 监听：0.0.0.0:%s | 目标：%s:%s\n", s+NR-1, $1, $2, $3, $4}' "$NFT_RULES"
        else
            echo "  暂无规则。"
        fi

        echo
        echo "[数字编号] 删除单条规则    [a] 删除全部规则    [0] 返回主菜单"
        echo

        read_input "请输入选项: " c

        case "$c" in
            0) return ;;
            a|A)
                delete_all_rules
                continue
                ;;
            ''|*[!0-9]*)
                echo "错误：无效选项。"
                continue
                ;;
        esac

        [ "$total" -gt 0 ] || {
            echo "当前没有可删除的规则。"
            continue
        }

        [ "$c" -ge 1 ] && [ "$c" -le "$total" ] || {
            echo "错误：编号超出范围。"
            continue
        }

        if [ "$c" -le "$rc" ]; then
            f="$REALM_RULES"
            line_no="$c"
            name=realm
        else
            f="$NFT_RULES"
            line_no=$((c-rc))
            name=nftables
        fi

        row="$(sed -n "${line_no}p" "$f")"

        echo
        echo "即将删除 [$name] 规则：$row"
        echo

        confirm_input "确认删除？[y/N/0返回]: " ok

        [ "$ok" = yes ] || {
            echo "已取消删除。"
            continue
        }

        tmp="$(mktemp)"
        awk -v n="$line_no" 'NR != n {print}' "$f" > "$tmp"
        mv "$tmp" "$f"

        if [ "$name" = realm ]; then
            regen_realm_conf

            if [ -s "$f" ]; then
                if [ "$SERVICE_MANAGER" = systemd ]; then
                    systemctl restart realm >/dev/null 2>&1 || true
                else
                    rc-service realm restart >/dev/null 2>&1 || true
                fi
            else
                stop_realm
                rm -f "$REALM_CONF"
            fi
        else
            if [ -s "$f" ]; then
                apply_nft
            else
                stop_nft
            fi
        fi

        echo "已成功删除该规则。"
    done
}

uninstall_all() {
    echo
    line
    echo " 卸载脚本安装的全部内容"
    line
    echo "仅卸载脚本相关文件，不卸载 curl、nftables 等系统依赖。"
    echo

    confirm_input "确认卸载全部内容？[y/N/0返回]: " ok

    [ "$ok" = yes ] || {
        echo "已取消卸载。"
        return
    }

    stop_realm
    stop_nft
    remove_dns_refresh

    rm -f "$REALM_BIN" "$DNS_REFRESH_SCRIPT" "$NFT_APPLY_SCRIPT"
    rm -rf "$REALM_DIR"

    if [ "$SERVICE_MANAGER" = systemd ]; then
        rm -f "$SYSTEMD_REALM" "$SYSTEMD_NFT" "$SYSTEMD_DNS_SERVICE" "$SYSTEMD_DNS_TIMER"
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rm -f "$OPENRC_REALM" "$OPENRC_NFT"
    fi

    command -v nft >/dev/null 2>&1 && nft delete table ip realm_forward >/dev/null 2>&1 || true

    grep -q "^$SWAP_FILE " /etc/fstab 2>/dev/null && sed -i "\|^$SWAP_FILE |d" /etc/fstab >/dev/null 2>&1 || true

    swapoff "$SWAP_FILE" >/dev/null 2>&1 || true
    rm -f "$SWAP_FILE" "$LOW_MEMORY_SYSCTL" "$SHORTCUT_BIN"

    echo "卸载完成。"
    exit 0
}

show_result() {
    echo
    echo "[10/10] 安装结果汇总"
    echo "--------------------------------------"
    echo "转发方式 ：$MODE"
    echo "监听地址 ：0.0.0.0:$LISTEN_PORT"
    echo "目标地址 ：$REMOTE_ADDR"
    echo "协议     ：$PROTO"
    echo "内存档位 ：$MEM_PROFILE"
    echo "realm内存限制：${REALM_MEM_MAX_MB} MB"
    echo "--------------------------------------"
    echo

    if [ "$MODE" = realm ]; then
        echo "【 realm 当前规则 】"
        print_rules "$REALM_RULES"
    else
        echo "【 nftables 当前规则 】"
        print_rules "$NFT_RULES"
    fi

    echo
    echo "注意：请在安全组/防火墙放行监听端口 $LISTEN_PORT。realm 已启用守护，异常退出会自动重启。"
    echo "128M 小内存机器会自动应用低内存参数，并尝试启用 256M swap。"
    echo "日常管理可直接输入：vfm"
    echo
}

header
need_root
detect_os
calc_memory
install_base_deps
detect_arch
install_shortcut
show_info

while true; do
    ask_action || continue

    case "$ACTION" in
        create)
            while true; do
                ask_mode || break
                ask_forward || continue

                if [ "$MODE" = realm ]; then
                    install_realm_mode
                else
                    install_nftables_mode
                fi

                show_result
                break
            done
            ;;
        view)
            view_rules
            ;;
        delete)
            delete_rules
            ;;
        uninstall)
            uninstall_all
            ;;
    esac
done
