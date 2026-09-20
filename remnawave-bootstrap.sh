#!/usr/bin/env bash

# ============================================================
# Remnawave VPS Bootstrap Installer
# ============================================================
#
# 1. Disable fwupd
# 2. apt update + show upgradable packages
# 3. Disable IPv6
# 4. BBR / network sysctl
# 5. Install Zapret.dat
# 6. Install / configure two WARP profiles
# 7. Install Remnawave Node
# 8. Install Selfsteal
# 9. Configure UFW
# 10. Install / configure Fail2ban
# 11. Install everything
#
# IMPORTANT:
# RemnaNode and Selfsteal installers remain FULLY INTERACTIVE.
# This script does NOT automatically answer their questions.
#
# ============================================================

set -o pipefail

# ------------------------------------------------------------
# Basic settings
# ------------------------------------------------------------

LOG_FILE="/var/log/remnawave-bootstrap.log"

REMNANODE_INSTALLER_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh"
SELFSTEAL_INSTALLER_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh"

ZAPRET_URL="https://github.com/kutovoys/ru_gov_zapret/releases/latest/download/zapret.dat"

WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.3.0/wgcf_2.3.0_linux_amd64"

REMNANODE_DIR="/opt/remnanode"
REMNANODE_COMPOSE="${REMNANODE_DIR}/docker-compose.yml"

ZAPRET_DIR="${REMNANODE_DIR}/xray/share"
ZAPRET_FILE="${ZAPRET_DIR}/zapret.dat"

WARP1_CONF="/etc/wireguard/wgcf1.conf"
WARP2_CONF="/etc/wireguard/wgcf2.conf"

WARP_START="/usr/local/bin/warp_start.sh"
WARP_SERVICE="/etc/systemd/system/warp.service"

FAIL2BAN_JAIL="/etc/fail2ban/jail.local"

INSTALL_ZAPRET=false
INSTALL_WARP=false
INSTALL_SELFSTEAL=false

STATUS_1="NOT RUN"
STATUS_2="NOT RUN"
STATUS_3="NOT RUN"
STATUS_4="NOT RUN"
STATUS_5="NOT RUN"
STATUS_6="NOT RUN"
STATUS_7="NOT RUN"
STATUS_8="NOT RUN"
STATUS_9="NOT RUN"
STATUS_10="NOT RUN"

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")"

exec > >(tee -a "$LOG_FILE") 2>&1

# ------------------------------------------------------------
# Always start from /root
# Prevents getcwd errors when previous directory was deleted
# ------------------------------------------------------------

cd /root || exit 1

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Ошибка: скрипт необходимо запускать от root.${NC}"
    exit 1
fi

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

pause_menu() {
    echo
    read -r -p "Нажмите Enter для возврата в меню..." _
}

mark_status() {
    local num="$1"
    local status="$2"

    case "$num" in
        1) STATUS_1="$status" ;;
        2) STATUS_2="$status" ;;
        3) STATUS_3="$status" ;;
        4) STATUS_4="$status" ;;
        5) STATUS_5="$status" ;;
        6) STATUS_6="$status" ;;
        7) STATUS_7="$status" ;;
        8) STATUS_8="$status" ;;
        9) STATUS_9="$status" ;;
        10) STATUS_10="$status" ;;
    esac
}

status_color() {
    case "$1" in
        OK)
            echo -e "${GREEN}$1${NC}"
            ;;
        FAILED)
            echo -e "${RED}$1${NC}"
            ;;
        SKIPPED)
            echo -e "${YELLOW}$1${NC}"
            ;;
        *)
            echo -e "${GRAY}$1${NC}"
            ;;
    esac
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

download_file() {
    local url="$1"
    local output="$2"

    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 300 \
        "$url" -o "$output"; then
        return 1
    fi

    [[ -s "$output" ]]
}

# ------------------------------------------------------------
# 1. Disable fwupd
# ------------------------------------------------------------

disable_fwupd() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}1. Отключение fwupd${NC}"
    echo -e "${CYAN}============================================================${NC}"

    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}systemctl не найден.${NC}"
        mark_status 1 FAILED
        return 1
    fi

    echo "Останавливаем fwupd..."

    systemctl stop fwupd.service 2>/dev/null || true
    systemctl disable fwupd.service 2>/dev/null || true

    echo "Снимаем возможный старый mask..."
    systemctl unmask fwupd.service 2>/dev/null || true

    echo "Маскируем fwupd..."
    systemctl mask fwupd.service 2>/dev/null || true

    systemctl daemon-reload

    local enabled_state
    local active_state
    local unit_target

    enabled_state="$(systemctl is-enabled fwupd.service 2>/dev/null || true)"
    active_state="$(systemctl is-active fwupd.service 2>/dev/null || true)"
    unit_target="$(readlink -f /etc/systemd/system/fwupd.service 2>/dev/null || true)"

    echo
    echo "fwupd:"
    echo "  enabled: $enabled_state"
    echo "  active : $active_state"
    echo "  target : $unit_target"

    if [[ "$enabled_state" == "masked" ]] ||
       [[ "$unit_target" == "/dev/null" ]]; then

        echo -e "${GREEN}fwupd успешно отключён и замаскирован.${NC}"
        mark_status 1 OK
        return 0
    fi

    echo -e "${YELLOW}Обычный systemctl mask не подтвердился. Применяем fallback...${NC}"

    rm -f /etc/systemd/system/fwupd.service
    ln -s /dev/null /etc/systemd/system/fwupd.service

    systemctl daemon-reload

    enabled_state="$(systemctl is-enabled fwupd.service 2>/dev/null || true)"
    unit_target="$(readlink -f /etc/systemd/system/fwupd.service 2>/dev/null || true)"

    echo
    echo "После fallback:"
    echo "  enabled: $enabled_state"
    echo "  target : $unit_target"

    if [[ "$enabled_state" == "masked" ]] ||
       [[ "$unit_target" == "/dev/null" ]]; then

        echo -e "${GREEN}fwupd успешно замаскирован.${NC}"
        mark_status 1 OK
        return 0
    fi

    echo -e "${RED}Не удалось подтвердить mask fwupd.${NC}"
    mark_status 1 FAILED
    return 1
}

# ------------------------------------------------------------
# 2. apt update + upgradable
# ------------------------------------------------------------

update_apt() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}2. Обновление списка пакетов${NC}"
    echo -e "${CYAN}============================================================${NC}"

    if ! apt update; then
        echo -e "${RED}apt update завершился с ошибкой.${NC}"
        mark_status 2 FAILED
        return 1
    fi

    echo
    echo -e "${CYAN}Доступные обновления:${NC}"
    apt list --upgradable 2>/dev/null || true

    mark_status 2 OK
    return 0
}

# ------------------------------------------------------------
# 3. Disable IPv6
# ------------------------------------------------------------

disable_ipv6() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}3. Отключение IPv6${NC}"
    echo -e "${CYAN}============================================================${NC}"

    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    if ! sysctl --system; then
        echo -e "${RED}Не удалось применить sysctl.${NC}"
        mark_status 3 FAILED
        return 1
    fi

    echo
    echo "IPv6:"
    sysctl net.ipv6.conf.all.disable_ipv6
    sysctl net.ipv6.conf.default.disable_ipv6
    sysctl net.ipv6.conf.lo.disable_ipv6

    if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == "1" ]] &&
       [[ "$(sysctl -n net.ipv6.conf.default.disable_ipv6)" == "1" ]] &&
       [[ "$(sysctl -n net.ipv6.conf.lo.disable_ipv6)" == "1" ]]; then

        echo -e "${GREEN}IPv6 отключён.${NC}"
        mark_status 3 OK
        return 0
    fi

    echo -e "${RED}Не удалось подтвердить отключение IPv6.${NC}"
    mark_status 3 FAILED
    return 1
}

# ------------------------------------------------------------
# 4. BBR / network sysctl
# ------------------------------------------------------------

configure_bbr() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}4. BBR и сетевые параметры${NC}"
    echo -e "${CYAN}============================================================${NC}"

    cat > /etc/sysctl.d/99-remnawave-network.conf <<'EOF'
# =========================
# BBR
# =========================
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# =========================
# TCP buffers
# =========================
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864

net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 131072 67108864

# =========================
# Network backlog
# =========================
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192

# =========================
# SYN protection / backlog
# =========================
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1

# =========================
# TCP connection lifecycle
# =========================
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# =========================
# TCP keepalive
# =========================
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# =========================
# Receive buffer autotuning
# =========================
net.ipv4.tcp_moderate_rcvbuf = 1

# =========================
# UDP
# =========================
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# =========================
# File descriptors
# =========================
fs.file-max = 1048576
EOF

    if ! sysctl --system; then
        echo -e "${RED}Не удалось применить сетевые sysctl.${NC}"
        mark_status 4 FAILED
        return 1
    fi

    echo
    echo -e "${CYAN}TCP congestion control:${NC}"
    sysctl net.ipv4.tcp_congestion_control

    echo
    echo -e "${CYAN}Default qdisc:${NC}"
    sysctl net.core.default_qdisc

    echo
    echo -e "${CYAN}Доступные congestion algorithms:${NC}"
    sysctl net.ipv4.tcp_allowed_congestion_control

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] &&
       [[ "$(sysctl -n net.core.default_qdisc)" == "fq" ]]; then

        echo -e "${GREEN}BBR успешно включён.${NC}"
        mark_status 4 OK
        return 0
    fi

    echo -e "${RED}Не удалось подтвердить BBR.${NC}"
    mark_status 4 FAILED
    return 1
}

# ------------------------------------------------------------
# Add Zapret mount to RemnaNode compose
# ------------------------------------------------------------

add_zapret_mount() {
    if [[ ! -f "$REMNANODE_COMPOSE" ]]; then
        echo -e "${YELLOW}docker-compose.yml пока отсутствует:${NC}"
        echo "  $REMNANODE_COMPOSE"
        return 1
    fi

    if grep -Fq \
        "/opt/remnanode/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro" \
        "$REMNANODE_COMPOSE"; then

        echo -e "${GREEN}Zapret mount уже присутствует в compose.${NC}"
        return 0
    fi

    local backup_file
    backup_file="${REMNANODE_COMPOSE}.bak.$(date +%Y%m%d_%H%M%S)"

    cp -a "$REMNANODE_COMPOSE" "$backup_file"

    echo "Backup compose:"
    echo "  $backup_file"

    python3 - "$REMNANODE_COMPOSE" <<'PY'
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

mount = "      - /opt/remnanode/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro\n"

# Already present
if any(
    "/opt/remnanode/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro"
    in line
    for line in lines
):
    sys.exit(0)

# Find top-level remnanode service
service_start = None

for i, line in enumerate(lines):
    if line.rstrip("\n") == "  remnanode:":
        service_start = i
        break

if service_start is None:
    print("ERROR: service 'remnanode:' not found")
    sys.exit(2)

# Find next top-level service
service_end = len(lines)

for i in range(service_start + 1, len(lines)):
    if lines[i].startswith("  ") and not lines[i].startswith("    ") and lines[i].rstrip().endswith(":"):
        service_end = i
        break

# Find volumes block inside remnanode service
volumes_start = None
volumes_end = None

for i in range(service_start + 1, service_end):
    if lines[i].rstrip() == "    volumes:":
        volumes_start = i
        break

if volumes_start is not None:
    volumes_end = service_end

    for i in range(volumes_start + 1, service_end):
        line = lines[i]

        if line.startswith("    ") and not line.startswith("      "):
            volumes_end = i
            break

    lines.insert(volumes_end, mount)

else:
    # Find a reasonable place near the beginning of the service.
    insert_at = service_start + 1

    lines[insert_at:insert_at] = [
        "    volumes:\n",
        mount,
    ]

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Не удалось изменить docker-compose.yml.${NC}"
        cp -a "$backup_file" "$REMNANODE_COMPOSE"
        return 1
    fi

    echo -e "${GREEN}Zapret mount добавлен.${NC}"
    return 0
}

# ------------------------------------------------------------
# Restart RemnaNode after Zapret modification
# ------------------------------------------------------------

restart_remnanode() {
    if [[ ! -f "$REMNANODE_COMPOSE" ]]; then
        return 1
    fi

    echo
    echo -e "${CYAN}Проверяем docker-compose.yml...${NC}"

    if ! (
        cd "$REMNANODE_DIR" &&
        docker compose config >/dev/null
    ); then

        echo -e "${RED}docker-compose.yml не прошёл проверку.${NC}"
        return 1
    fi

    echo -e "${GREEN}Compose config OK.${NC}"

    echo
    echo "Перезапускаем RemnaNode..."

    (
        cd "$REMNANODE_DIR" &&
        docker compose down &&
        docker compose up -d
    )

    local rc=$?

    if [[ $rc -ne 0 ]]; then
        echo -e "${RED}Не удалось перезапустить RemnaNode.${NC}"
        return 1
    fi

    echo
    (
        cd "$REMNANODE_DIR" &&
        docker compose ps
    )

    return 0
}

# ------------------------------------------------------------
# 5. Install Zapret.dat
# ------------------------------------------------------------

install_zapret() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}5. Установка Zapret.dat${NC}"
    echo -e "${CYAN}============================================================${NC}"

    mkdir -p "$ZAPRET_DIR"

    local tmp_file
    tmp_file="$(mktemp)"

    echo "Скачиваем:"
    echo "$ZAPRET_URL"

    if ! download_file "$ZAPRET_URL" "$tmp_file"; then
        echo -e "${RED}Не удалось скачать zapret.dat.${NC}"
        rm -f "$tmp_file"
        mark_status 5 FAILED
        return 1
    fi

    if [[ ! -s "$tmp_file" ]]; then
        echo -e "${RED}Скачанный zapret.dat пустой.${NC}"
        rm -f "$tmp_file"
        mark_status 5 FAILED
        return 1
    fi

    install -m 0644 "$tmp_file" "$ZAPRET_FILE"
    rm -f "$tmp_file"

    echo
    echo -e "${GREEN}Zapret.dat установлен:${NC}"
    ls -lh "$ZAPRET_FILE"

    # If RemnaNode already exists, configure it now.
    if [[ -f "$REMNANODE_COMPOSE" ]]; then

        echo
        echo "RemnaNode уже установлен."
        echo "Добавляем volume mount..."

        if ! add_zapret_mount; then
            mark_status 5 FAILED
            return 1
        fi

        if ! restart_remnanode; then
            mark_status 5 FAILED
            return 1
        fi

    else
        echo
        echo -e "${YELLOW}RemnaNode пока не установлен.${NC}"
        echo "Zapret.dat сохранён."
        echo "После установки RemnaNode mount будет добавлен автоматически."
    fi

    mark_status 5 OK
    return 0
}

# ------------------------------------------------------------
# Configure WARP config
# ------------------------------------------------------------

configure_warp_conf() {
    local file="$1"
    local address="$2"

    if [[ ! -f "$file" ]]; then
        echo -e "${RED}WARP config не найден: $file${NC}"
        return 1
    fi

    local tmp
    tmp="$(mktemp)"

    awk -v desired_address="$address" '
    BEGIN {
        in_interface=0
        address_added=0
        endpoint_found=0
        mtu_found=0
        table_added=0
        keepalive_added=0
    }

    /^\[Interface\]/ {
        in_interface=1
        print
        next
    }

    /^\[Peer\]/ {
        in_interface=0
        print
        next
    }

    {
        # Remove every existing Address line.
        if ($0 ~ /^[[:space:]]*Address[[:space:]]*=/) {
            if (!address_added && in_interface) {
                print "Address = " desired_address
                address_added=1
            }
            next
        }

        # Remove all IPv6 Endpoint values.
        if ($0 ~ /^[[:space:]]*Endpoint[[:space:]]*=/) {
            if ($0 ~ /\[/ && $0 ~ /:[0-9]+[[:space:]]*$/) {
                next
            }

            print
            endpoint_found=1

            if (!keepalive_added) {
                print "PersistentKeepalive = 25"
                keepalive_added=1
            }

            next
        }

        # Remove existing Table.
        if ($0 ~ /^[[:space:]]*Table[[:space:]]*=/) {
            next
        }

        # Remove existing PersistentKeepalive.
        if ($0 ~ /^[[:space:]]*PersistentKeepalive[[:space:]]*=/) {
            next
        }

        # Keep only IPv4 in AllowedIPs.
        if ($0 ~ /^[[:space:]]*AllowedIPs[[:space:]]*=/) {
            split($0, parts, "=")
            value = parts[2]

            gsub(/^[[:space:]]+/, "", value)
            gsub(/[[:space:]]+$/, "", value)

            n = split(value, ips, ",")

            result = ""

            for (i = 1; i <= n; i++) {
                ip = ips[i]
                gsub(/^[[:space:]]+/, "", ip)
                gsub(/[[:space:]]+$/, "", ip)

                if (ip !~ /:/ && ip != "") {
                    if (result != "") {
                        result = result ", "
                    }

                    result = result ip
                }
            }

            if (result != "") {
                print "AllowedIPs = " result
            }

            next
        }

        # Insert Table = off immediately after MTU.
        if ($0 ~ /^[[:space:]]*MTU[[:space:]]*=/) {
            print
            print "Table = off"
            table_added=1
            mtu_found=1
            next
        }

        print
    }

    END {
        if (in_interface && !address_added) {
            # No Address line existed.
            # This is handled by the shell validation below.
        }
    }
    ' "$file" > "$tmp"

    # Add Address immediately after [Interface] if awk did not find it.
    if ! grep -qE "^Address[[:space:]]*=[[:space:]]*$address$" "$tmp"; then
        awk -v addr="$address" '
        BEGIN { done=0 }
        {
            print
            if ($0 == "[Interface]" && !done) {
                print "Address = " addr
                done=1
            }
        }
        ' "$tmp" > "${tmp}.2"

        mv "${tmp}.2" "$tmp"
    fi

    # Verify required fields.
    if ! grep -qE "^Address[[:space:]]*=[[:space:]]*$address$" "$tmp"; then
        echo -e "${RED}Не удалось установить Address = $address${NC}"
        rm -f "$tmp"
        return 1
    fi

    if ! grep -qE "^Table[[:space:]]*=[[:space:]]*off$" "$tmp"; then
        echo -e "${RED}Не удалось установить Table = off${NC}"
        rm -f "$tmp"
        return 1
    fi

    if ! grep -qE "^PersistentKeepalive[[:space:]]*=[[:space:]]*25$" "$tmp"; then
        echo -e "${RED}Не удалось установить PersistentKeepalive = 25${NC}"
        rm -f "$tmp"
        return 1
    fi

    # Ensure no IPv6 address remains.
    if grep -qE "^[[:space:]]*Address[[:space:]]*=.*:" "$tmp"; then
        echo -e "${RED}В WARP config остался IPv6 Address.${NC}"
        rm -f "$tmp"
        return 1
    fi

    # Ensure no IPv6 AllowedIPs remain.
    if grep -qE "^[[:space:]]*AllowedIPs[[:space:]]*=.*:" "$tmp"; then
        echo -e "${RED}В WARP config остался IPv6 AllowedIPs.${NC}"
        rm -f "$tmp"
        return 1
    fi

    # Ensure no IPv6 endpoint remains.
    if grep -qE "^[[:space:]]*Endpoint[[:space:]]*=.*\[" "$tmp"; then
        echo -e "${RED}В WARP config остался IPv6 Endpoint.${NC}"
        rm -f "$tmp"
        return 1
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$file"
    chmod 600 "$file"

    return 0
}

# ------------------------------------------------------------
# Generate one WARP profile
# ------------------------------------------------------------

generate_warp_profile() {
    local number="$1"
    local conf="$2"
    local address="$3"

    echo
    echo -e "${CYAN}Создание WARP профиля #${number}${NC}"

    local temp_dir
    temp_dir="$(mktemp -d)"

    (
        cd "$temp_dir" || exit 1

        if ! wgcf register; then
            exit 1
        fi

        if ! wgcf generate; then
            exit 1
        fi

        if [[ ! -f wgcf-profile.conf ]]; then
            echo "wgcf-profile.conf не найден."
            exit 1
        fi

        install -m 0600 wgcf-profile.conf "$conf"
    )

    local rc=$?

    rm -rf "$temp_dir"

    if [[ $rc -ne 0 ]]; then
        echo -e "${RED}Не удалось создать WARP профиль #${number}.${NC}"
        return 1
    fi

    if ! configure_warp_conf "$conf" "$address"; then
        return 1
    fi

    echo -e "${GREEN}WARP профиль #${number} готов:${NC}"
    echo "  $conf"
    echo "  Address = $address"

    return 0
}

# ------------------------------------------------------------
# 6. Install WARP
# ------------------------------------------------------------

install_warp() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}6. Установка двух WARP профилей${NC}"
    echo -e "${CYAN}============================================================${NC}"

    echo "Устанавливаем WireGuard и необходимые пакеты..."

    if ! apt install -y wireguard curl; then
        echo -e "${RED}Не удалось установить WireGuard.${NC}"
        mark_status 6 FAILED
        return 1
    fi

    local tmp_wgcf
    tmp_wgcf="$(mktemp)"

    echo
    echo "Скачиваем wgcf v2.3.0..."

    if ! download_file "$WGCF_URL" "$tmp_wgcf"; then
        echo -e "${RED}Не удалось скачать wgcf.${NC}"
        rm -f "$tmp_wgcf"
        mark_status 6 FAILED
        return 1
    fi

    chmod +x "$tmp_wgcf"
    install -m 0755 "$tmp_wgcf" /usr/local/bin/wgcf
    rm -f "$tmp_wgcf"

    echo
    echo "wgcf:"
    wgcf --version 2>/dev/null || true

    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    # Stop old interfaces if they exist.
    wg-quick down wgcf1 2>/dev/null || true
    wg-quick down wgcf2 2>/dev/null || true

    # Generate WARP #1
    if ! generate_warp_profile \
        "1" \
        "$WARP1_CONF" \
        "172.16.0.2/32"; then

        mark_status 6 FAILED
        return 1
    fi

    # Generate WARP #2
    if ! generate_warp_profile \
        "2" \
        "$WARP2_CONF" \
        "172.16.0.3/32"; then

        mark_status 6 FAILED
        return 1
    fi

    # --------------------------------------------------------
    # Startup script
    # --------------------------------------------------------

    cat > "$WARP_START" <<'EOF'
#!/bin/bash
set -e

wg-quick down wgcf1 2>/dev/null || true
wg-quick down wgcf2 2>/dev/null || true

wg-quick up wgcf1
wg-quick up wgcf2
EOF

    chmod 0755 "$WARP_START"

    # --------------------------------------------------------
    # systemd service
    # --------------------------------------------------------

    cat > "$WARP_SERVICE" <<'EOF'
[Unit]
Description=WARP Load Balancer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp_start.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp.service

    echo
    echo "Запускаем WARP..."

    if ! systemctl restart warp.service; then
        echo -e "${RED}Не удалось запустить WARP service.${NC}"
        systemctl status warp.service --no-pager || true
        mark_status 6 FAILED
        return 1
    fi

    echo
    echo -e "${CYAN}WireGuard status:${NC}"
    wg show

    echo
    echo -e "${GREEN}Два WARP профиля установлены.${NC}"

    mark_status 6 OK
    return 0
}

# ------------------------------------------------------------
# 7. Install RemnaNode
# ------------------------------------------------------------

install_remnanode() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}7. Установка Remnawave Node${NC}"
    echo -e "${CYAN}============================================================${NC}"

    echo
    echo -e "${YELLOW}ВАЖНО:${NC}"
    echo "Установщик RemnaNode будет запущен в полностью интерактивном режиме."
    echo "Bootstrap НЕ будет отвечать на его вопросы."
    echo
    echo "Если установщик спросит:"
    echo "  y/n"
    echo "  параметры"
    echo "  подтверждение переустановки"
    echo "  другие значения"
    echo
    echo "Ответы необходимо вводить вручную."
    echo
    read -r -p "Нажмите Enter для запуска установщика RemnaNode..." _

    local node_installer
    node_installer="$(mktemp /tmp/remnanode-installer.XXXXXX.sh)"

    echo
    echo "Скачиваем RemnaNode installer..."

    if ! download_file "$REMNANODE_INSTALLER_URL" "$node_installer"; then
        echo -e "${RED}Не удалось скачать remnanode.sh.${NC}"
        rm -f "$node_installer"
        mark_status 7 FAILED
        return 1
    fi

    chmod +x "$node_installer"

    # Remove CRLF just in case.
    sed -i 's/\r$//' "$node_installer"

    echo
    echo -e "${GREEN}Запускаем RemnaNode installer...${NC}"
    echo -e "${GRAY}Все вопросы установщика будут переданы пользователю.${NC}"
    echo

    # --------------------------------------------------------
    # IMPORTANT:
    # NO printf
    # NO yes
    # NO expect
    # NO automatic answers
    # --------------------------------------------------------

    bash "$node_installer" @ install

    local installer_rc=$?

    rm -f "$node_installer"

    echo

    if [[ $installer_rc -ne 0 ]]; then
        echo -e "${RED}Установщик RemnaNode завершился с кодом: $installer_rc${NC}"

        # If compose is valid despite non-zero installer exit,
        # consider installation usable.
        if [[ -f "$REMNANODE_COMPOSE" ]] &&
           (
               cd "$REMNANODE_DIR" &&
               docker compose config >/dev/null 2>&1
           ); then

            echo -e "${YELLOW}Но docker-compose.yml существует и корректен.${NC}"
            echo -e "${YELLOW}Продолжаем настройку.${NC}"

        else
            mark_status 7 FAILED
            return "$installer_rc"
        fi
    else
        echo -e "${GREEN}RemnaNode installer завершён успешно.${NC}"
    fi

    # --------------------------------------------------------
    # Configure Zapret after Node installation
    # --------------------------------------------------------

    if [[ "$INSTALL_ZAPRET" == true ]]; then

        if [[ -f "$ZAPRET_FILE" ]]; then

            echo
            echo -e "${CYAN}Настраиваем Zapret mount для RemnaNode...${NC}"

            if add_zapret_mount; then

                if ! restart_remnanode; then
                    echo -e "${RED}Не удалось перезапустить RemnaNode после добавления Zapret.${NC}"
                    mark_status 7 FAILED
                    return 1
                fi

            else
                echo -e "${RED}Не удалось добавить Zapret mount.${NC}"
                mark_status 7 FAILED
                return 1
            fi

        else
            echo -e "${YELLOW}Zapret.dat не найден — пропускаем mount.${NC}"
        fi
    fi

    mark_status 7 OK
    return 0
}

# ------------------------------------------------------------
# 8. Install Selfsteal
# ------------------------------------------------------------

install_selfsteal() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}8. Установка Selfsteal${NC}"
    echo -e "${CYAN}============================================================${NC}"

    echo
    echo -e "${YELLOW}ВАЖНО:${NC}"
    echo "Установщик Selfsteal будет запущен в полностью интерактивном режиме."
    echo "Bootstrap НЕ будет автоматически отвечать на его вопросы."
    echo
    read -r -p "Нажмите Enter для запуска установщика Selfsteal..." _

    local selfsteal_installer
    selfsteal_installer="$(mktemp /tmp/selfsteal-installer.XXXXXX.sh)"

    echo
    echo "Скачиваем Selfsteal installer..."

    if ! download_file "$SELFSTEAL_INSTALLER_URL" "$selfsteal_installer"; then
        echo -e "${RED}Не удалось скачать selfsteal.sh.${NC}"
        rm -f "$selfsteal_installer"
        mark_status 8 FAILED
        return 1
    fi

    chmod +x "$selfsteal_installer"

    # Remove CRLF just in case.
    sed -i 's/\r$//' "$selfsteal_installer"

    echo
    echo -e "${GREEN}Запускаем Selfsteal installer...${NC}"
    echo -e "${GRAY}Все вопросы установщика будут переданы пользователю.${NC}"
    echo

    # Fully interactive.
    bash "$selfsteal_installer" @ install

    local installer_rc=$?

    rm -f "$selfsteal_installer"

    echo

    if [[ $installer_rc -ne 0 ]]; then
        echo -e "${RED}Установщик Selfsteal завершился с кодом: $installer_rc${NC}"
        mark_status 8 FAILED
        return "$installer_rc"
    fi

    echo -e "${GREEN}Selfsteal установлен.${NC}"

    mark_status 8 OK
    return 0
}

# ------------------------------------------------------------
# 9. Configure UFW
# ------------------------------------------------------------

configure_ufw() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}9. Настройка UFW${NC}"
    echo -e "${CYAN}============================================================${NC}"

    echo "Устанавливаем UFW..."

    if ! apt install -y ufw; then
        echo -e "${RED}Не удалось установить UFW.${NC}"
        mark_status 9 FAILED
        return 1
    fi

    echo
    echo "Добавляем правила..."

    ufw allow OpenSSH
    ufw allow 443/tcp
    ufw allow 1433/tcp

    echo
    echo "Включаем UFW..."

    if ! ufw --force enable; then
        echo -e "${RED}Не удалось включить UFW.${NC}"
        mark_status 9 FAILED
        return 1
    fi

    echo
    ufw status verbose

    mark_status 9 OK
    return 0
}

# ------------------------------------------------------------
# 10. Fail2ban
# ------------------------------------------------------------

configure_fail2ban() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}10. Настройка Fail2ban${NC}"
    echo -e "${CYAN}============================================================${NC}"

    echo "Устанавливаем Fail2ban..."

    if ! apt install -y fail2ban; then
        echo -e "${RED}Не удалось установить Fail2ban.${NC}"
        mark_status 10 FAILED
        return 1
    fi

    cat > "$FAIL2BAN_JAIL" <<'EOF'
[DEFAULT]
bantime = 6h
findtime = 20m
maxretry = 2
backend = systemd
ignoreip = 127.0.0.1/8 ::1 5.189.21.45

[sshd]
enabled = true
port = ssh
EOF

    systemctl enable fail2ban

    if ! systemctl restart fail2ban; then
        echo -e "${RED}Не удалось запустить Fail2ban.${NC}"
        systemctl status fail2ban --no-pager || true
        mark_status 10 FAILED
        return 1
    fi

    echo
    echo -e "${CYAN}Fail2ban status:${NC}"
    systemctl status fail2ban --no-pager || true

    echo
    echo -e "${CYAN}Jail status:${NC}"
    fail2ban-client status || true

    mark_status 10 OK
    return 0
}

# ------------------------------------------------------------
# Final status report
# ------------------------------------------------------------

show_status() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}СТАТУС УСТАНОВКИ${NC}"
    echo -e "${CYAN}============================================================${NC}"

    printf "1.  Disable fwupd       : "
    status_color "$STATUS_1"

    printf "2.  apt update          : "
    status_color "$STATUS_2"

    printf "3.  Disable IPv6        : "
    status_color "$STATUS_3"

    printf "4.  BBR / sysctl        : "
    status_color "$STATUS_4"

    printf "5.  Zapret.dat          : "
    status_color "$STATUS_5"

    printf "6.  WARP x2             : "
    status_color "$STATUS_6"

    printf "7.  RemnaNode           : "
    status_color "$STATUS_7"

    printf "8.  Selfsteal           : "
    status_color "$STATUS_8"

    printf "9.  UFW                 : "
    status_color "$STATUS_9"

    printf "10. Fail2ban            : "
    status_color "$STATUS_10"

    echo
    echo "Log:"
    echo "  $LOG_FILE"

    echo -e "${CYAN}============================================================${NC}"
}

# ------------------------------------------------------------
# Ask Install All options
# ------------------------------------------------------------

ask_install_all_options() {
    echo
    echo -e "${CYAN}Дополнительные компоненты:${NC}"
    echo

    while true; do
        read -r -p "Установить Zapret.dat? [y/n]: " answer

        case "$answer" in
            y|Y|д|Д)
                INSTALL_ZAPRET=true
                break
                ;;
            n|N|н|Н)
                INSTALL_ZAPRET=false
                break
                ;;
            *)
                echo "Введите y или n."
                ;;
        esac
    done

    while true; do
        read -r -p "Установить два WARP профиля? [y/n]: " answer

        case "$answer" in
            y|Y|д|Д)
                INSTALL_WARP=true
                break
                ;;
            n|N|н|Н)
                INSTALL_WARP=false
                break
                ;;
            *)
                echo "Введите y или n."
                ;;
        esac
    done

    while true; do
        read -r -p "Установить Selfsteal? [y/n]: " answer

        case "$answer" in
            y|Y|д|Д)
                INSTALL_SELFSTEAL=true
                break
                ;;
            n|N|н|Н)
                INSTALL_SELFSTEAL=false
                break
                ;;
            *)
                echo "Введите y или n."
                ;;
        esac
    done

    echo
    echo "Выбрано:"
    echo "  Zapret   : $INSTALL_ZAPRET"
    echo "  WARP     : $INSTALL_WARP"
    echo "  Selfsteal: $INSTALL_SELFSTEAL"
}

# ------------------------------------------------------------
# Install everything
# ------------------------------------------------------------

install_everything() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}11. ПОЛНАЯ УСТАНОВКА${NC}"
    echo -e "${CYAN}============================================================${NC}"

    ask_install_all_options

    echo
    echo -e "${YELLOW}Начинаем установку.${NC}"
    echo

    # --------------------------------------------------------
    # 1
    # --------------------------------------------------------

    disable_fwupd || true

    # --------------------------------------------------------
    # 2
    # --------------------------------------------------------

    update_apt || true

    # --------------------------------------------------------
    # 3
    # --------------------------------------------------------

    disable_ipv6 || true

    # --------------------------------------------------------
    # 4
    # --------------------------------------------------------

    configure_bbr || true

    # --------------------------------------------------------
    # 5
    # --------------------------------------------------------

    if [[ "$INSTALL_ZAPRET" == true ]]; then
        install_zapret || true
    else
        STATUS_5="SKIPPED"
        echo
        echo -e "${YELLOW}Zapret.dat пропущен.${NC}"
    fi

    # --------------------------------------------------------
    # 6
    # --------------------------------------------------------

    if [[ "$INSTALL_WARP" == true ]]; then
        install_warp || true
    else
        STATUS_6="SKIPPED"
        echo
        echo -e "${YELLOW}WARP пропущен.${NC}"
    fi

    # --------------------------------------------------------
    # 7
    # --------------------------------------------------------

    # IMPORTANT:
    # RemnaNode installer is fully interactive.
    install_remnanode || true

    # --------------------------------------------------------
    # 8
    # --------------------------------------------------------

    if [[ "$INSTALL_SELFSTEAL" == true ]]; then
        install_selfsteal || true
    else
        STATUS_8="SKIPPED"
        echo
        echo -e "${YELLOW}Selfsteal пропущен.${NC}"
    fi

    # --------------------------------------------------------
    # 9
    # --------------------------------------------------------

    configure_ufw || true

    # --------------------------------------------------------
    # 10
    # --------------------------------------------------------

    configure_fail2ban || true

    # --------------------------------------------------------
    # Final
    # --------------------------------------------------------

    show_status

    echo
    echo -e "${GREEN}Полная установка завершена.${NC}"
}

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------

show_menu() {
    clear

    echo -e "${CYAN}============================================================${NC}"
    echo -e "${WHITE}        Remnawave VPS Bootstrap Installer${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo
    echo "  1) Disable fwupd"
    echo "  2) apt update + показать обновления"
    echo "  3) Disable IPv6"
    echo "  4) BBR / network sysctl"
    echo "  5) Install Zapret.dat"
    echo "  6) Install / configure two WARP profiles"
    echo "  7) Install Remnawave Node"
    echo "  8) Install Selfsteal"
    echo "  9) Configure UFW"
    echo " 10) Install / configure Fail2ban"
    echo
    echo " 11) Установить всё"
    echo
    echo "  0) Выход"
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo
}

# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------

while true; do

    show_menu

    read -r -p "Выберите пункт [0-11]: " choice

    case "$choice" in

        1)
            disable_fwupd
            pause_menu
            ;;

        2)
            update_apt
            pause_menu
            ;;

        3)
            disable_ipv6
            pause_menu
            ;;

        4)
            configure_bbr
            pause_menu
            ;;

        5)
            install_zapret
            pause_menu
            ;;

        6)
            install_warp
            pause_menu
            ;;

        7)
            install_remnanode
            pause_menu
            ;;

        8)
            install_selfsteal
            pause_menu
            ;;

        9)
            configure_ufw
            pause_menu
            ;;

        10)
            configure_fail2ban
            pause_menu
            ;;

        11)
            install_everything
            pause_menu
            ;;

        0)
            echo
            echo -e "${GREEN}Выход.${NC}"
            exit 0
            ;;

        *)
            echo
            echo -e "${RED}Неверный пункт меню.${NC}"
            sleep 1
            ;;

    esac

done
