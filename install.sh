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
DNS_REFRESH_INTERVAL="5"
SERVICE_TARGET=""
VFM_FORWARD_COMMENT="VFM_NFT_FORWARD"

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
echo " VPS 绔彛杞彂涓€閿鐞嗚剼鏈�"
echo " 鏀寔绯荤粺锛欴ebian / Ubuntu / Alpine"
echo " 杞彂鏂瑰紡锛歳ealm / nftables"
print_line
echo ""

if [ "$(id -u)" != "0" ]; then
    echo "閿欒锛氳浣跨敤 root 鐢ㄦ埛杩愯姝よ剼鏈€�"
    exit 1
fi

detect_os() {
    if [ ! -f /etc/os-release ]; then
        echo "閿欒锛氭棤娉曟娴嬬郴缁燂紝鏈壘鍒� /etc/os-release銆�"
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
                    echo "閿欒锛氫笉鏀寔褰撳墠绯荤粺锛�$OS_ID"
                    echo "褰撳墠鑴氭湰浠呮敮鎸� Debian / Ubuntu / Alpine銆�"
                    exit 1
                    ;;
            esac
            ;;
    esac

    if [ "$SERVICE_MANAGER" = "systemd" ] && ! command -v systemctl >/dev/null 2>&1; then
        echo "閿欒锛氭湭鎵惧埌 systemctl銆傚綋鍓嶇郴缁熷彲鑳戒笉鏄� systemd 鐜銆�"
        exit 1
    fi

    if [ "$SERVICE_MANAGER" = "openrc" ] && ! command -v rc-service >/dev/null 2>&1; then
        echo "閿欒锛氭湭鎵惧埌 rc-service銆傚綋鍓� Alpine 绯荤粺鍙兘涓嶆槸 OpenRC 鐜銆�"
        exit 1
    fi
}

install_base_deps() {
    echo "[1/10] 姝ｅ湪瀹夎鍩虹渚濊禆..."

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
                coreutils \
                iptables \
                netcat-openbsd >/dev/null 2>&1
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
                openrc \
                iptables \
                netcat-openbsd >/dev/null 2>&1
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
    echo "姝ｅ湪瀹夎 nftables 渚濊禆..."

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
            echo "閿欒锛氫笉鏀寔褰撳墠 CPU 鏋舵瀯锛�$ARCH"
            echo "褰撳墠鑴氭湰鏀寔锛歺86_64 / aarch64 / armv7"
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
    echo "[2/10] 褰撳墠绯荤粺淇℃伅"
    echo "--------------------------------------"
    echo "绯荤粺绫诲瀷       锛�$OS_FAMILY"
    echo "鏈嶅姟绠＄悊鍣�     锛�$SERVICE_MANAGER"
    echo "CPU 鏋舵瀯       锛�$(uname -m)"
    echo "蹇嵎鍛戒护       锛歷fm"
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

generate_random_port() {
    while true; do
        if command -v od >/dev/null 2>&1; then
            RAND_NUM="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')"
        else
            RAND_NUM="$(date +%s)"
        fi

        [ -z "$RAND_NUM" ] && RAND_NUM="$(date +%s)"

        RANDOM_PORT=$((20000 + RAND_NUM % 45001))

        if ! check_duplicate_rule_in_file "$REALM_RULES" "tcp" "$RANDOM_PORT" && \
           ! check_duplicate_rule_in_file "$REALM_RULES" "udp" "$RANDOM_PORT" && \
           ! check_duplicate_rule_in_file "$NFT_RULES" "tcp" "$RANDOM_PORT" && \
           ! check_duplicate_rule_in_file "$NFT_RULES" "udp" "$RANDOM_PORT"; then
            echo "$RANDOM_PORT"
            return 0
        fi
    done
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

cleanup_vfm_forward_rules() {
    if ! command -v iptables >/dev/null 2>&1; then
        return 0
    fi

    while true; do
        RULE_NUM="$(iptables -L FORWARD -n -v --line-numbers 2>/dev/null | awk '/VFM_NFT_FORWARD/ {print $1; exit}')"

        if [ -z "$RULE_NUM" ]; then
            break
        fi

        iptables -D FORWARD "$RULE_NUM" >/dev/null 2>&1 || break
    done

    return 0
}

install_test_deps() {
    if command -v nc >/dev/null 2>&1; then
        return 0
    fi

    echo "姝ｅ湪瀹夎杩為€氭€ф祴璇曞伐鍏� netcat-openbsd..."

    case "$OS_FAMILY" in
        debian)
            DEBIAN_FRONTEND=noninteractive apt-get install -y netcat-openbsd >/dev/null 2>&1 || true
            ;;
        alpine)
            apk add --no-cache netcat-openbsd >/dev/null 2>&1 || true
            ;;
    esac

    return 0
}

resolve_target_host() {
    TARGET_HOST="$1"

    if is_ip_address "$TARGET_HOST"; then
        echo "$TARGET_HOST"
        return 0
    fi

    if command -v getent >/dev/null 2>&1; then
        getent hosts "$TARGET_HOST" 2>/dev/null | awk '{print $1}' | head -n 1
        return 0
    fi

    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$TARGET_HOST" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n 1
        return 0
    fi

    return 0
}

test_target_port() {
    TEST_PROTO="$1"
    TEST_HOST="$2"
    TEST_PORT="$3"

    if ! command -v nc >/dev/null 2>&1; then
        echo "鏈娴嬪埌 nc锛屽凡璺宠繃鐩爣绔彛杩為€氭€ф祴璇曘€�"
        return 0
    fi

    case "$TEST_PROTO" in
        udp)
            if nc -vzu -w 5 "$TEST_HOST" "$TEST_PORT" >/dev/null 2>&1; then
                echo "鐩爣 UDP 绔彛娴嬭瘯锛氬彲杈�"
            else
                echo "鐩爣 UDP 绔彛娴嬭瘯锛氭湭纭鍙揪"
                echo "鎻愮ず锛歎DP 鐨� nc 娴嬭瘯涓嶄竴瀹氬噯纭紝鏈€缁堜互瀹㈡埛绔疄闄呰繛鎺ヤ负鍑嗐€�"
            fi
            ;;
        both)
            if nc -vz -w 5 "$TEST_HOST" "$TEST_PORT" >/dev/null 2>&1; then
                echo "鐩爣 TCP 绔彛娴嬭瘯锛氬彲杈�"
            else
                echo "鐩爣 TCP 绔彛娴嬭瘯锛氬け璐ユ垨瓒呮椂"
            fi

            if nc -vzu -w 5 "$TEST_HOST" "$TEST_PORT" >/dev/null 2>&1; then
                echo "鐩爣 UDP 绔彛娴嬭瘯锛氬彲杈�"
            else
                echo "鐩爣 UDP 绔彛娴嬭瘯锛氭湭纭鍙揪"
                echo "鎻愮ず锛歎DP 鐨� nc 娴嬭瘯涓嶄竴瀹氬噯纭紝鏈€缁堜互瀹㈡埛绔疄闄呰繛鎺ヤ负鍑嗐€�"
            fi
            ;;
        *)
            if nc -vz -w 5 "$TEST_HOST" "$TEST_PORT" >/dev/null 2>&1; then
                echo "鐩爣 TCP 绔彛娴嬭瘯锛氬彲杈�"
            else
                echo "鐩爣 TCP 绔彛娴嬭瘯锛氬け璐ユ垨瓒呮椂"
            fi
            ;;
    esac

    return 0
}

test_realm_forward() {
    echo ""
    print_line
    echo " realm 杞彂杩為€氭€ф祴璇�"
    print_line

    echo "realm 鏈嶅姟鐘舵€侊細$(get_service_status realm)"

    if [ "$PROTO" = "udp" ]; then
        if ss -lnup 2>/dev/null | grep -q ":${LISTEN_PORT} "; then
            echo "鏈満 UDP 鐩戝惉娴嬭瘯锛氬凡鐩戝惉 0.0.0.0:${LISTEN_PORT}"
        else
            echo "鏈満 UDP 鐩戝惉娴嬭瘯锛氭湭妫€娴嬪埌鐩戝惉锛岃妫€鏌� realm 鏈嶅姟銆�"
        fi
    elif [ "$PROTO" = "both" ]; then
        if ss -lntp 2>/dev/null | grep -q ":${LISTEN_PORT} "; then
            echo "鏈満 TCP 鐩戝惉娴嬭瘯锛氬凡鐩戝惉 0.0.0.0:${LISTEN_PORT}"
        else
            echo "鏈満 TCP 鐩戝惉娴嬭瘯锛氭湭妫€娴嬪埌鐩戝惉锛岃妫€鏌� realm 鏈嶅姟銆�"
        fi

        if ss -lnup 2>/dev/null | grep -q ":${LISTEN_PORT} "; then
            echo "鏈満 UDP 鐩戝惉娴嬭瘯锛氬凡鐩戝惉 0.0.0.0:${LISTEN_PORT}"
        else
            echo "鏈満 UDP 鐩戝惉娴嬭瘯锛氭湭妫€娴嬪埌鐩戝惉锛岃妫€鏌� realm 鏈嶅姟銆�"
        fi
    else
        if ss -lntp 2>/dev/null | grep -q ":${LISTEN_PORT} "; then
            echo "鏈満 TCP 鐩戝惉娴嬭瘯锛氬凡鐩戝惉 0.0.0.0:${LISTEN_PORT}"
        else
            echo "鏈満 TCP 鐩戝惉娴嬭瘯锛氭湭妫€娴嬪埌鐩戝惉锛岃妫€鏌� realm 鏈嶅姟銆�"
        fi
    fi

    RESOLVED_IP="$(resolve_target_host "$REMOTE_HOST")"
    if [ -n "$RESOLVED_IP" ]; then
        echo "鐩爣瑙ｆ瀽缁撴灉锛�${REMOTE_HOST} -> ${RESOLVED_IP}"
    else
        echo "鐩爣瑙ｆ瀽缁撴灉锛氭湭瑙ｆ瀽鍒� IP锛岃妫€鏌� DNS銆�"
    fi

    test_target_port "$PROTO" "$REMOTE_HOST" "$REMOTE_PORT"

    echo ""
    echo "鎻愮ず锛氬鏋滄湰鏈虹洃鍚甯革紝浣嗗鎴风浠嶆棤娉曡繛鎺ワ紝璇锋鏌ヤ簯鏈嶅姟鍣ㄥ畨鍏ㄧ粍鏄惁鏀捐鐩戝惉绔彛 ${LISTEN_PORT}銆�"
}

test_nft_forward() {
    echo ""
    print_line
    echo " nftables 杞彂杩為€氭€ф祴璇�"
    print_line

    IP_FORWARD_VALUE="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    if [ "$IP_FORWARD_VALUE" = "1" ]; then
        echo "IPv4 杞彂鐘舵€侊細宸插紑鍚�"
    else
        echo "IPv4 杞彂鐘舵€侊細鏈紑鍚�"
    fi

    if nft list table ip realm_forward >/dev/null 2>&1; then
        echo "nftables NAT 琛細宸插瓨鍦�"
    else
        echo "nftables NAT 琛細鏈壘鍒�"
    fi

    if nft list table ip realm_forward 2>/dev/null | grep -q "dport ${LISTEN_PORT} dnat to ${REMOTE_HOST}:${REMOTE_PORT}"; then
        echo "DNAT 瑙勫垯妫€鏌ワ細宸叉壘鍒扮洃鍚鍙� ${LISTEN_PORT} 鐨勮浆鍙戣鍒�"
    else
        echo "DNAT 瑙勫垯妫€鏌ワ細鏈‘璁ゆ壘鍒板搴旇鍒欙紝璇锋墽琛� nft list table ip realm_forward 妫€鏌ャ€�"
    fi

    if command -v iptables >/dev/null 2>&1; then
        if iptables -S FORWARD 2>/dev/null | grep -q "VFM_NFT_FORWARD"; then
            echo "FORWARD 鏀捐瑙勫垯锛氬凡瀛樺湪 VFM_NFT_FORWARD 鏍囪瑙勫垯"
        else
            echo "FORWARD 鏀捐瑙勫垯锛氭湭妫€娴嬪埌 VFM_NFT_FORWARD 鏍囪瑙勫垯"
        fi
    else
        echo "FORWARD 鏀捐瑙勫垯锛氭湭瀹夎 iptables锛屾棤娉曟鏌�"
    fi

    test_target_port "$PROTO" "$REMOTE_HOST" "$REMOTE_PORT"

    echo ""
    echo "鎻愮ず锛歯ftables 妯″紡涓嶄細鍑虹幇 LISTEN 鐩戝惉锛岃繖鏄甯哥幇璞°€�"
    echo "鎻愮ず锛氬鏋滄祴璇曚粛澶辫触锛岃妫€鏌ヤ簯鏈嶅姟鍣ㄥ畨鍏ㄧ粍鏄惁鏀捐鐩戝惉绔彛 ${LISTEN_PORT}銆�"
}

run_forward_test() {
    install_test_deps

    case "$MODE" in
        realm)
            test_realm_forward
            ;;
        nftables)
            test_nft_forward
            ;;
    esac

    return 0
}

count_rule_file() {
    RULE_FILE="$1"

    if [ -f "$RULE_FILE" ] && [ -s "$RULE_FILE" ]; then
        wc -l < "$RULE_FILE" | tr -d ' '
    else
        echo "0"
    fi
}

get_service_status() {
    SERVICE_NAME="$1"

    case "$SERVICE_NAME" in
        realm)
            SYSTEMD_FILE="$SYSTEMD_SERVICE"
            OPENRC_FILE="$OPENRC_SERVICE"
            SERVICE_ID="realm"
            ;;
        nftables)
            SYSTEMD_FILE="$NFT_SYSTEMD_SERVICE"
            OPENRC_FILE="$NFT_OPENRC_SERVICE"
            SERVICE_ID="realm-nft-forward"
            ;;
        *)
            echo "鏈煡"
            return 0
            ;;
    esac

    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        if [ ! -f "$SYSTEMD_FILE" ]; then
            echo "鏈畨瑁�"
            return 0
        fi

        if systemctl is-active --quiet "$SERVICE_ID" >/dev/null 2>&1; then
            echo "杩愯涓�"
        else
            echo "宸插仠姝�"
        fi
    else
        if [ ! -f "$OPENRC_FILE" ]; then
            echo "鏈畨瑁�"
            return 0
        fi

        if rc-service "$SERVICE_ID" status >/dev/null 2>&1; then
            echo "杩愯涓�"
        else
            echo "宸插仠姝�"
        fi
    fi
}

show_main_status() {
    REALM_STATUS="$(get_service_status realm)"
    NFT_STATUS="$(get_service_status nftables)"
    REALM_COUNT="$(count_rule_file "$REALM_RULES")"
    NFT_COUNT="$(count_rule_file "$NFT_RULES")"

    print_line
    echo " VPS 杞彂绠＄悊鍣�"
    print_line
    echo "realm 鏈嶅姟鐘舵€�      锛�$REALM_STATUS"
    echo "nftables 鏈嶅姟鐘舵€�   锛�$NFT_STATUS"
    echo "realm 瑙勫垯鏁伴噺      锛�${REALM_COUNT} 鏉�"
    echo "nftables 瑙勫垯鏁伴噺   锛�${NFT_COUNT} 鏉�"
    echo "蹇嵎鍛戒护            锛歷fm"
    print_line
}

select_service_target() {
    SERVICE_TARGET=""

    echo ""
    echo "璇烽€夋嫨鏈嶅姟锛�"
    echo "1) realm 鏈嶅姟"
    echo "2) nftables 鏈嶅姟"
    echo "3) realm + nftables 鍏ㄩ儴鏈嶅姟"
    echo "0) 杩斿洖涓婁竴姝�"
    echo ""

    read_input "璇疯緭鍏ラ€夐」 [0-3]: " SERVICE_CHOICE

    case "$SERVICE_CHOICE" in
        1)
            SERVICE_TARGET="realm"
            ;;
        2)
            SERVICE_TARGET="nftables"
            ;;
        3)
            SERVICE_TARGET="all"
            ;;
        0)
            return 1
            ;;
        *)
            echo "閿欒锛氭棤鏁堥€夐」銆�"
            return 1
            ;;
    esac

    return 0
}

service_file_exists() {
    SERVICE_NAME="$1"

    case "$SERVICE_NAME" in
        realm)
            if [ "$SERVICE_MANAGER" = "systemd" ]; then
                [ -f "$SYSTEMD_SERVICE" ]
            else
                [ -f "$OPENRC_SERVICE" ]
            fi
            ;;
        nftables)
            if [ "$SERVICE_MANAGER" = "systemd" ]; then
                [ -f "$NFT_SYSTEMD_SERVICE" ]
            else
                [ -f "$NFT_OPENRC_SERVICE" ]
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

start_one_service() {
    SERVICE_NAME="$1"

    case "$SERVICE_NAME" in
        realm)
            SERVICE_ID="realm"
            SERVICE_LABEL="realm"
            ;;
        nftables)
            SERVICE_ID="realm-nft-forward"
            SERVICE_LABEL="nftables"
            ;;
        *)
            echo "閿欒锛氭湭鐭ユ湇鍔°€�"
            return 0
            ;;
    esac

    if ! service_file_exists "$SERVICE_NAME"; then
        echo "鎻愮ず锛�${SERVICE_LABEL} 鏈嶅姟鏈畨瑁咃紝璇峰厛鏂板缓瀵瑰簲杞彂瑙勫垯銆�"
        return 0
    fi

    echo "姝ｅ湪寮€鍚� ${SERVICE_LABEL} 鏈嶅姟..."

    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl enable --now "$SERVICE_ID"
    else
        rc-update add "$SERVICE_ID" default >/dev/null 2>&1 || true
        rc-service "$SERVICE_ID" start
    fi

    echo "${SERVICE_LABEL} 鏈嶅姟鐘舵€侊細$(get_service_status "$SERVICE_NAME")"
}

stop_one_service() {
    SERVICE_NAME="$1"

    case "$SERVICE_NAME" in
        realm)
            SERVICE_ID="realm"
            SERVICE_LABEL="realm"
            ;;
        nftables)
            SERVICE_ID="realm-nft-forward"
            SERVICE_LABEL="nftables"
            ;;
        *)
            echo "閿欒锛氭湭鐭ユ湇鍔°€�"
            return 0
            ;;
    esac

    if ! service_file_exists "$SERVICE_NAME"; then
        echo "鎻愮ず锛�${SERVICE_LABEL} 鏈嶅姟鏈畨瑁呫€�"
        return 0
    fi

    echo "姝ｅ湪鍋滄 ${SERVICE_LABEL} 鏈嶅姟..."

    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl stop "$SERVICE_ID"
    else
        rc-service "$SERVICE_ID" stop
    fi

    echo "${SERVICE_LABEL} 鏈嶅姟鐘舵€侊細$(get_service_status "$SERVICE_NAME")"
}

restart_one_service() {
    SERVICE_NAME="$1"

    case "$SERVICE_NAME" in
        realm)
            SERVICE_ID="realm"
            SERVICE_LABEL="realm"
            ;;
        nftables)
            SERVICE_ID="realm-nft-forward"
            SERVICE_LABEL="nftables"
            ;;
        *)
            echo "閿欒锛氭湭鐭ユ湇鍔°€�"
            return 0
            ;;
    esac

    if ! service_file_exists "$SERVICE_NAME"; then
        echo "鎻愮ず锛�${SERVICE_LABEL} 鏈嶅姟鏈畨瑁咃紝璇峰厛鏂板缓瀵瑰簲杞彂瑙勫垯銆�"
        return 0
    fi

    echo "姝ｅ湪閲嶅惎 ${SERVICE_LABEL} 鏈嶅姟..."

    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl restart "$SERVICE_ID"
    else
        rc-service "$SERVICE_ID" restart
    fi

    echo "${SERVICE_LABEL} 鏈嶅姟鐘舵€侊細$(get_service_status "$SERVICE_NAME")"
}

show_one_service_log() {
    SERVICE_NAME="$1"

    case "$SERVICE_NAME" in
        realm)
            SERVICE_ID="realm"
            SERVICE_LABEL="realm"
            RULE_FILE="$REALM_RULES"
            ;;
        nftables)
            SERVICE_ID="realm-nft-forward"
            SERVICE_LABEL="nftables"
            RULE_FILE="$NFT_RULES"
            ;;
        *)
            echo "閿欒锛氭湭鐭ユ湇鍔°€�"
            return 0
            ;;
    esac

    echo ""
    print_line
    echo " ${SERVICE_LABEL} 鏈嶅姟鏃ュ織 / 鐘舵€�"
    print_line
    echo "鏈嶅姟鐘舵€侊細$(get_service_status "$SERVICE_NAME")"
    echo ""

    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        if service_file_exists "$SERVICE_NAME"; then
            journalctl -u "$SERVICE_ID" -n 80 --no-pager || true
        else
            echo "鎻愮ず锛�${SERVICE_LABEL} 鏈嶅姟鏈畨瑁呫€�"
        fi
    else
        if service_file_exists "$SERVICE_NAME"; then
            rc-service "$SERVICE_ID" status || true
        else
            echo "鎻愮ず锛�${SERVICE_LABEL} 鏈嶅姟鏈畨瑁呫€�"
        fi

        echo ""
        echo "OpenRC 绯荤粺娌℃湁缁熶竴 journalctl 鏃ュ織銆�"

        if [ -f /var/log/messages ]; then
            echo ""
            echo "鏈€杩戠郴缁熸棩蹇楋細"
            tail -n 80 /var/log/messages || true
        else
            echo "鏈壘鍒� /var/log/messages銆�"
        fi
    fi

    echo ""
    echo "褰撳墠瑙勫垯鏂囦欢锛�$RULE_FILE"
    if [ -f "$RULE_FILE" ] && [ -s "$RULE_FILE" ]; then
        cat "$RULE_FILE"
    else
        echo "鏆傛棤瑙勫垯銆�"
    fi
}

service_manage_menu() {
    while true; do
        echo ""
        print_line
        echo " 鏈嶅姟绠＄悊"
        print_line
        echo "1) 寮€鍚湇鍔�"
        echo "2) 鍋滄鏈嶅姟"
        echo "3) 閲嶅惎鏈嶅姟"
        echo "4) 鏌ョ湅鏃ュ織"
        echo "0) 杩斿洖涓昏彍鍗�"
        echo ""

        read_input "璇疯緭鍏ラ€夐」 [0-4]: " SERVICE_ACTION

        case "$SERVICE_ACTION" in
            1)
                select_service_target || continue
                case "$SERVICE_TARGET" in
                    realm) start_one_service realm ;;
                    nftables) start_one_service nftables ;;
                    all) start_one_service realm; start_one_service nftables ;;
                esac
                ;;
            2)
                select_service_target || continue
                case "$SERVICE_TARGET" in
                    realm) stop_one_service realm ;;
                    nftables) stop_one_service nftables ;;
                    all) stop_one_service realm; stop_one_service nftables ;;
                esac
                ;;
            3)
                select_service_target || continue
                case "$SERVICE_TARGET" in
                    realm) restart_one_service realm ;;
                    nftables) restart_one_service nftables ;;
                    all) restart_one_service realm; restart_one_service nftables ;;
                esac
                ;;
            4)
                select_service_target || continue
                case "$SERVICE_TARGET" in
                    realm) show_one_service_log realm ;;
                    nftables) show_one_service_log nftables ;;
                    all) show_one_service_log realm; show_one_service_log nftables ;;
                esac
                ;;
            0)
                return 0
                ;;
            *)
                echo "閿欒锛氭棤鏁堥€夐」銆�"
                ;;
        esac
    done
}

ask_action() {
    show_main_status
    echo " 涓昏彍鍗�"
    print_line
    echo "1) 鏂板缓杞彂瑙勫垯"
    echo "2) 鏌ョ湅鐩墠杞彂瑙勫垯"
    echo "3) 鍒犻櫎杞彂瑙勫垯"
    echo "4) 鏈嶅姟绠＄悊"
    echo "5) 鍗歌浇鑴氭湰瀹夎鐨勫叏閮ㄥ唴瀹�"
    echo "0) 閫€鍑鸿剼鏈�"
    echo ""

    read_input "璇疯緭鍏ラ€夐」 [0-5]: " ACTION_CHOICE

    case "$ACTION_CHOICE" in
        1) ACTION="create" ;;
        2) ACTION="view" ;;
        3) ACTION="delete" ;;
        4) ACTION="service" ;;
        5) ACTION="uninstall" ;;
        0) echo "宸查€€鍑鸿剼鏈€�"; exit 0 ;;
        *) echo "閿欒锛氭棤鏁堥€夐」銆�"; ACTION=""; return 1 ;;
    esac
    return 0
}

ask_mode() {
    echo ""
    echo "[4/10] 璇烽€夋嫨杞彂鏂瑰紡"
    echo "--------------------------------------"
    echo "1) realm    - 鐢ㄦ埛鎬佽浆鍙戯紝鏀寔鍩熷悕/IP锛岄€傚悎鍔ㄦ€佸煙鍚�"
    echo "2) nftables - 鍐呮牳绾� DNAT/SNAT锛屾€ц兘鏇村ソ锛岀洰鏍囧繀椤诲浐瀹欼Pv4"
    echo "0) 杩斿洖涓昏彍鍗�"
    echo "--------------------------------------"

    read_input "璇疯緭鍏ラ€夐」 [0-2]: " MODE_CHOICE

    case "$MODE_CHOICE" in
        1) MODE="realm" ;;
        2) MODE="nftables" ;;
        0) MODE=""; return 1 ;;
        *) echo "閿欒锛氭棤鏁堥€夐」銆�"; MODE=""; return 1 ;;
    esac

    echo "宸查€夋嫨锛�$MODE"
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
        echo "閿欒锛氬凡瀛樺湪 ${RULE_PROTO} 鍗忚鐩戝惉绔彛 ${RULE_PORT} 鐨� realm 瑙勫垯銆�"
        return 1
    fi
    if check_duplicate_rule_in_file "$NFT_RULES" "$RULE_PROTO" "$RULE_PORT"; then
        echo "閿欒锛氬凡瀛樺湪 ${RULE_PROTO} 鍗忚鐩戝惉绔彛 ${RULE_PORT} 鐨� nftables 瑙勫垯銆�"
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
                echo "[5/10] 閰嶇疆杞彂淇℃伅"
                echo "--------------------------------------"
                read_input "绗竴姝� - 璇疯緭鍏ユ湰鏈虹洃鍚鍙� (鍥炶溅榛樿闅忔満 20000-65000锛岃緭鍏�0杩斿洖): " LISTEN_PORT

                if [ "$LISTEN_PORT" = "0" ]; then return 1; fi
                if [ -z "$LISTEN_PORT" ]; then
                    LISTEN_PORT="$(generate_random_port)"
                    echo "宸查殢鏈虹敓鎴愮洃鍚鍙ｏ細$LISTEN_PORT"
                fi
                if ! is_valid_port "$LISTEN_PORT"; then
                    echo "閿欒锛氱洃鍚鍙ｅ繀椤绘槸 1 鍒� 65535 涔嬮棿鐨勬暟瀛椼€�"
                    continue
                fi
                STEP=2
                ;;
            2)
                read_input "绗簩姝� - 璇疯緭鍏ョ洰鏍囧煙鍚嶆垨 IP (杈撳叆0杩斿洖): " REMOTE_HOST

                if [ "$REMOTE_HOST" = "0" ]; then STEP=1; continue; fi
                if [ -z "$REMOTE_HOST" ]; then
                    echo "閿欒锛氱洰鏍囧煙鍚嶆垨 IP 涓嶈兘涓虹┖銆�"
                    continue
                fi
                STEP=3
                ;;
            3)
                read_input "绗笁姝� - 璇疯緭鍏ョ洰鏍囩鍙� (杈撳叆0杩斿洖): " REMOTE_PORT

                if [ "$REMOTE_PORT" = "0" ]; then STEP=2; continue; fi
                if ! is_valid_port "$REMOTE_PORT"; then
                    echo "閿欒锛氱洰鏍囩鍙ｅ繀椤绘槸 1 鍒� 65535 涔嬮棿鐨勬暟瀛椼€�"
                    continue
                fi
                STEP=4
                ;;
            4)
                echo ""
                echo "璇烽€夋嫨鍗忚锛�"
                echo "1) TCP"
                echo "2) UDP"
                echo "3) TCP + UDP"
                echo "0) 杩斿洖涓婁竴姝�"
                echo ""

                read_input "璇疯緭鍏ラ€夐」 [鍥炶溅榛樿 TCP]: " PROTO_CHOICE

                case "$PROTO_CHOICE" in
                    ""|1) PROTO="tcp" ;;
                    2) PROTO="udp" ;;
                    3) PROTO="both" ;;
                    0) STEP=3; continue ;;
                    *) echo "閿欒锛氭棤鏁堝崗璁€夐」銆�"; continue ;;
                esac

                format_remote_addr "$REMOTE_HOST" "$REMOTE_PORT"

                if [ "$MODE" = "nftables" ]; then
                    if ! is_ipv4 "$REMOTE_HOST"; then
                        echo ""
                        echo "閿欒锛氬綋鍓嶈剼鏈殑 nftables 妯″紡浠呮敮鎸佺洰鏍囦负鍥哄畾 IPv4銆�"
                        echo "鍘熷洜锛歯ftables DNAT 瑙勫垯搴斾娇鐢ㄥ浐瀹� IP锛屼笉閫傚悎鐩存帴浣跨敤鍔ㄦ€佸煙鍚嶃€�"
                        echo "濡傛灉浣犵殑鐩爣鏄煙鍚嶆垨 IPv6锛岃閫夋嫨 realm 妯″紡銆�"
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
                        echo "鎻愮ず锛氭娴嬪埌鐩爣鏄� IP 鍦板潃锛屽凡璺宠繃 DNS 瀹氭椂鍒锋柊閰嶇疆銆�"
                    else
                        echo ""
                        echo "鎻愮ず锛氭娴嬪埌鐩爣涓哄煙鍚嶃€�"
                        echo "鏄惁鍚敤 DNS 鑷姩鍒锋柊锛�(鍩熷悕 IP 鍙樺寲鏃惰嚜鍔ㄩ噸鍚� realm)"
                        echo "Y) 鍚敤"
                        echo "n) 涓嶅惎鐢�"
                        echo "0) 杩斿洖涓婁竴姝�"
                        echo ""

                        read_input "璇疯緭鍏ラ€夐」 [鍥炶溅榛樿鍚敤锛孻/n/0]: " DNS_CONFIRM

                        case "$DNS_CONFIRM" in
                            0)
                                STEP=4
                                continue
                                ;;
                            n|N|no|NO)
                                ENABLE_DNS_REFRESH="no"
                                ;;
                            ""|y|Y|yes|YES|*)
                                ENABLE_DNS_REFRESH="yes"
                                while true; do
                                    read_input "璇疯緭鍏� DNS 鍒锋柊闂撮殧鍒嗛挓鏁� [鍥炶溅榛樿 5锛岃緭鍏� 0 杩斿洖]: " DNS_REFRESH_INTERVAL_INPUT

                                    if [ "$DNS_REFRESH_INTERVAL_INPUT" = "0" ]; then STEP=4; continue 2; fi
                                    if [ -n "$DNS_REFRESH_INTERVAL_INPUT" ]; then DNS_REFRESH_INTERVAL="$DNS_REFRESH_INTERVAL_INPUT"; fi

                                    case "$DNS_REFRESH_INTERVAL" in
                                        ''|*[!0-9]*) echo "閿欒锛氬繀椤绘槸鏁板瓧銆�"; continue ;;
                                    esac
                                    if [ "$DNS_REFRESH_INTERVAL" -lt 1 ]; then echo "閿欒锛氫笉鑳藉皬浜�1銆�"; continue; fi
                                    break
                                done
                                ;;
                        esac
                    fi
                fi
                STEP=6
                ;;
            6)
                echo ""
                print_line
                echo " 閰嶇疆纭"
                print_line
                echo "杞彂鏂瑰紡 锛�$MODE"
                echo "鐩戝惉鍦板潃 锛�0.0.0.0:${LISTEN_PORT}"
                echo "鐩爣鍦板潃 锛�${REMOTE_ADDR}"
                echo "鍗忚     锛�${PROTO}"

                if [ "$MODE" = "realm" ]; then
                    echo "DNS 鍒锋柊 锛�${ENABLE_DNS_REFRESH}"
                fi

                echo ""
                read_input "纭瀹夎锛焄鍥炶溅榛樿瀹夎锛孻/n/0杩斿洖]: " CONFIRM_INSTALL

                case "$CONFIRM_INSTALL" in
                    ""|y|Y|yes|YES) return 0 ;;
                    0) STEP=5; continue ;;
                    *) echo "宸插彇娑堟湰娆℃柊寤恒€�"; return 1 ;;
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

    cleanup_vfm_forward_rules
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
    echo "[6/10] 姝ｅ湪瀹夎 realm..."

    TMP_DIR="$(mktemp -d)"
    cd "$TMP_DIR"

    REALM_URL="https://github.com/zhboner/realm/releases/latest/download/realm-${REALM_ARCH}.tar.gz"
    echo "涓嬭浇鍦板潃锛�$REALM_URL"

    if ! curl -L --fail --retry 3 --connect-timeout 15 -o realm.tar.gz "$REALM_URL"; then
        echo "閿欒锛歳ealm 涓嬭浇澶辫触锛岃妫€鏌ョ綉缁滄垨鏋舵瀯鏄惁瀛樺湪銆�"
        cd /; rm -rf "$TMP_DIR"; exit 1
    fi

    if ! tar -xzf realm.tar.gz; then
        echo "閿欒锛歳ealm 鍘嬬缉鍖呰В鍘嬪け璐ャ€�"
        cd /; rm -rf "$TMP_DIR"; exit 1
    fi

    if [ ! -f realm ]; then
        echo "閿欒锛氭湭鎵惧埌 realm 鍙墽琛屾枃浠躲€�"
        cd /; rm -rf "$TMP_DIR"; exit 1
    fi

    install -m 755 realm "$REALM_BIN"
    cd /; rm -rf "$TMP_DIR"
    echo "realm 宸叉垚鍔熷畨瑁呭埌锛�$REALM_BIN"
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
COMMENT="VFM_NFT_FORWARD"

cleanup_vfm_forward_rules() {
    if ! command -v iptables >/dev/null 2>&1; then
        return 0
    fi

    while true; do
        RULE_NUM="$(iptables -L FORWARD -n -v --line-numbers 2>/dev/null | awk '/VFM_NFT_FORWARD/ {print $1; exit}')"

        if [ -z "$RULE_NUM" ]; then
            break
        fi

        iptables -D FORWARD "$RULE_NUM" >/dev/null 2>&1 || break
    done

    return 0
}

apply_vfm_forward_rules() {
    if ! command -v iptables >/dev/null 2>&1; then
        echo "璀﹀憡锛氭湭鎵惧埌 iptables锛屾棤娉曡嚜鍔ㄦ坊鍔� FORWARD 鏀捐瑙勫垯銆�"
        return 0
    fi

    cleanup_vfm_forward_rules

    iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || true

    while IFS='|' read -r RULE_PROTO RULE_LISTEN RULE_HOST RULE_PORT; do
        [ -z "$RULE_PROTO" ] && continue
        [ -z "$RULE_LISTEN" ] && continue
        [ -z "$RULE_HOST" ] && continue
        [ -z "$RULE_PORT" ] && continue

        case "$RULE_PROTO" in
            tcp)
                iptables -I FORWARD 1 -p tcp -d "$RULE_HOST" --dport "$RULE_PORT" -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || true
                ;;
            udp)
                iptables -I FORWARD 1 -p udp -d "$RULE_HOST" --dport "$RULE_PORT" -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || true
                ;;
        esac
    done < "$RULES"

    return 0
}

if [ ! -f "$RULES" ] || [ ! -s "$RULES" ]; then
    nft delete table ip realm_forward >/dev/null 2>&1 || true
    cleanup_vfm_forward_rules
    echo "娌℃湁 nftables 瑙勫垯锛屽凡娓呯悊 realm_forward 琛ㄥ拰 FORWARD 鏀捐瑙勫垯銆�"
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

apply_vfm_forward_rules
EOF
    chmod +x "$NFT_APPLY_SCRIPT"
}
apply_nft_rules() {
    if [ ! -x "$NFT_APPLY_SCRIPT" ]; then
        write_nft_apply_script
    fi

    if ! "$NFT_APPLY_SCRIPT"; then
        echo "閿欒锛歯ftables 瑙勫垯搴旂敤澶辫触锛岃妫€鏌ヤ笂鏂硅緭鍑恒€�"
        return 1
    fi

    return 0
}

add_realm_rule() {
    echo ""
    echo "[7/10] 姝ｅ湪杩藉姞 realm 瑙勫垯..."
    append_rule_to_file "$REALM_RULES"
    regenerate_realm_config
}

add_nft_rule() {
    echo ""
    echo "[7/10] 姝ｅ湪杩藉姞 nftables 瑙勫垯..."
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
    echo "[8/10] 姝ｅ湪鍒涘缓 realm 绯荤粺鏈嶅姟..."
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
    echo "[9/10] 姝ｅ湪閰嶇疆 DNS 鑷姩鍒锋柊..."
    if [ "$MODE" != "realm" ] || [ "$ENABLE_DNS_REFRESH" != "yes" ]; then
        echo "DNS 鑷姩鍒锋柊鏈惎鐢ㄣ€�"
        return
    fi

    install_dns_deps
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        remove_systemd_dns_refresh
        install_dns_refresh_systemd
    else
        install_dns_refresh_openrc
    fi
    echo "DNS 鑷姩鍒锋柊宸叉垚鍔熷惎鐢ㄣ€�"
}

enable_ip_forward() {
    echo ""
    echo "姝ｅ湪寮€鍚� IPv4 鍐呮牳杞彂..."
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
    echo "[8/10] 姝ｅ湪鍒涘缓 nftables 杞彂鏈嶅姟..."
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
        echo "  鏆傛棤瑙勫垯銆�"
        return
    fi
    awk -F'|' '{printf "  %d. 鍗忚锛�%s | 鐩戝惉锛�0.0.0.0:%s | 鐩爣锛�%s:%s\n", NR, $1, $2, $3, $4}' "$RULE_FILE"
}

view_current_rules() {
    while true; do
        echo ""
        print_line
        echo " 褰撳墠鑴氭湰绠＄悊鐨勫叏閮ㄨ浆鍙戣鍒�"
        print_line
        echo ""

        echo "銆� realm 瑙勫垯 銆�"
        echo "--------------------------------------"
        print_rule_file_numbered "$REALM_RULES"
        echo ""

        echo "銆� nftables 瑙勫垯 銆�"
        echo "--------------------------------------"
        print_rule_file_numbered "$NFT_RULES"
        echo ""

        read_input "杈撳叆 0 杩斿洖涓昏彍鍗�: " VIEW_CHOICE

        if [ "$VIEW_CHOICE" = "0" ]; then
            return 0
        fi
    done
}

delete_all_rules() {
    echo ""
    confirm_input "纭鍒犻櫎鍏ㄩ儴瑙勫垯锛焄y/N/0杩斿洖锛屽洖杞﹂粯璁や笉鍒犻櫎]: " CONFIRM_DELETE_ALL

    if [ "$CONFIRM_DELETE_ALL" != "yes" ]; then
        echo "宸插彇娑堝垹闄ゃ€�"
        return
    fi

    stop_realm_service
    stop_nft_service
    cleanup_dns_refresh

    rm -f "$REALM_RULES" "$NFT_RULES" "$REALM_CONF"

    if command -v nft >/dev/null 2>&1; then
        nft delete table ip realm_forward >/dev/null 2>&1 || true
    fi

    cleanup_vfm_forward_rules
    echo "鉁� 鍏ㄩ儴杞彂瑙勫垯宸插垹闄ゃ€�"
}

delete_current_rules() {
    while true; do
        echo ""
        print_line
        echo " 鍒犻櫎杞彂瑙勫垯"
        print_line
        echo ""

        START_IDX=1
        REALM_COUNT=0
        NFT_COUNT=0

        if [ -f "$REALM_RULES" ] && [ -s "$REALM_RULES" ]; then
            REALM_COUNT=$(wc -l < "$REALM_RULES" | tr -d ' ')
        fi

        if [ -f "$NFT_RULES" ] && [ -s "$NFT_RULES" ]; then
            NFT_COUNT=$(wc -l < "$NFT_RULES" | tr -d ' ')
        fi

        TOTAL_RULES=$((REALM_COUNT + NFT_COUNT))

        echo "銆� realm 瑙勫垯 銆�"
        echo "--------------------------------------"
        if [ "$REALM_COUNT" -gt 0 ]; then
            awk -F'|' -v start="$START_IDX" '{printf "  [%d] 鍗忚锛�%s | 鐩戝惉锛�0.0.0.0:%s | 鐩爣锛�%s:%s\n", start+NR-1, $1, $2, $3, $4}' "$REALM_RULES"
            START_IDX=$((START_IDX + REALM_COUNT))
        else
            echo "  鏆傛棤瑙勫垯銆�"
        fi

        echo ""
        echo "銆� nftables 瑙勫垯 銆�"
        echo "--------------------------------------"
        if [ "$NFT_COUNT" -gt 0 ]; then
            awk -F'|' -v start="$START_IDX" '{printf "  [%d] 鍗忚锛�%s | 鐩戝惉锛�0.0.0.0:%s | 鐩爣锛�%s:%s\n", start+NR-1, $1, $2, $3, $4}' "$NFT_RULES"
        else
            echo "  鏆傛棤瑙勫垯銆�"
        fi

        echo ""
        echo "鎿嶄綔鑿滃崟锛�"
        echo "  [鏁板瓧缂栧彿] 鍒犻櫎瀵瑰簲鍗曟潯瑙勫垯"
        echo "  [a]        鍒犻櫎鍏ㄩ儴瑙勫垯"
        echo "  [0]        杩斿洖涓昏彍鍗�"
        echo ""

        read_input "璇疯緭鍏ラ€夐」: " DEL_CHOICE

        case "$DEL_CHOICE" in
            0) return 0 ;;
            a|A)
                delete_all_rules
                continue
                ;;
            ''|*[!0-9]*)
                echo "閿欒锛氭棤鏁堥€夐」鎴栫紪鍙枫€�"
                continue
                ;;
        esac

        if [ "$DEL_CHOICE" -lt 1 ] || [ "$DEL_CHOICE" -gt "$TOTAL_RULES" ]; then
            echo "閿欒锛氳緭鍏ョ紪鍙疯秴鍑鸿寖鍥淬€�"
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
        echo "鍗冲皢鍒犻櫎浠ヤ笅 [${TARGET_NAME}] 瑙勫垯锛�"
        echo "鍗忚锛�$RULE_PROTO | 鐩戝惉锛�0.0.0.0:$RULE_LISTEN | 鐩爣锛�$RULE_HOST:$RULE_PORT"
        echo ""

        confirm_input "纭鍒犻櫎锛焄y/N/0杩斿洖锛屽洖杞﹂粯璁や笉鍒犻櫎]: " CONFIRM_DELETE

        if [ "$CONFIRM_DELETE" = "back" ]; then continue; fi
        if [ "$CONFIRM_DELETE" != "yes" ]; then
            echo "宸插彇娑堝垹闄ゃ€�"
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

        echo "鉁� 宸叉垚鍔熷垹闄よ瑙勫垯銆�"
    done
}

uninstall_all() {
    echo ""
    print_line
    echo " 鍗歌浇鑴氭湰瀹夎鐨勫叏閮ㄥ唴瀹�"
    print_line
    echo ""
    echo "娉ㄦ剰锛氫粎鍗歌浇 realm/閰嶇疆/瀹氭椂浠诲姟/鍐呴儴琛紝涓嶄細鍗歌浇 curl銆乶ftables 绛夌郴缁熶緷璧栧寘銆�"
    echo ""
    confirm_input "纭鍗歌浇鍏ㄩ儴鍐呭锛焄y/N/0杩斿洖锛屽洖杞﹂粯璁や笉鍗歌浇]: " CONFIRM_UNINSTALL

    if [ "$CONFIRM_UNINSTALL" != "yes" ]; then
        echo "宸插彇娑堝嵏杞姐€�"
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

    cleanup_vfm_forward_rules
    rm -f "$SHORTCUT_BIN"

    echo ""
    echo "鉁� 鍗歌浇瀹屾垚锛佽剼鏈浉鍏虫湇鍔″拰閰嶇疆宸茶鍏ㄦ暟娓呴櫎銆�"
    echo ""
    exit 0
}

show_result() {
    echo ""
    echo "[10/10] 瀹夎缁撴灉姹囨€�"
    echo "--------------------------------------"
    echo "杞彂鏂瑰紡 锛�$MODE"
    echo "鐩戝惉鍦板潃 锛�0.0.0.0:${LISTEN_PORT}"
    echo "鐩爣鍦板潃 锛�${REMOTE_ADDR}"
    echo "鍗忚     锛�$PROTO"
    echo "--------------------------------------"
    echo ""

    if [ "$MODE" = "realm" ]; then
        echo "銆� realm 褰撳墠瑙勫垯 銆戯細"
        print_rule_file_numbered "$REALM_RULES"
        echo ""
    else
        echo "銆� nftables 褰撳墠瑙勫垯 銆戯細"
        print_rule_file_numbered "$NFT_RULES"
        echo ""
    fi

    echo "銆� 娉ㄦ剰浜嬮」 銆戯細"
    echo "1. 璇峰湪浜戞湇鍔″櫒瀹夊叏缁�/闃茬伀澧欎腑鏀捐鐩戝惉绔彛 [ ${LISTEN_PORT} ]"
    echo "2. nftables 妯″紡涓嬶紝绔彛澶勪簬鍐呮牳 NAT 杞彂灞傜骇锛屼娇鐢� netstat 鎴� ss 灏嗘棤娉曟煡鐪嬪埌 LISTEN 鐘舵€侊紙杩欐槸姝ｅ父鐜拌薄锛�"
    echo "3. 鏃ュ父绠＄悊鍙€氳繃鍦ㄧ粓绔洿鎺ヨ緭鍏ュ揩鎹峰懡浠わ細vfm 鎵撳紑鏈剼鏈�"
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
                run_forward_test
                break
            done
            ;;
        view)
            view_current_rules
            ;;
        delete)
            delete_current_rules
            ;;
        service)
            service_manage_menu
            ;;
        uninstall)
            uninstall_all
            ;;
    esac
done
