```bash
#!/usr/bin/env bash

set -o pipefail

# ============================================================
# RemnaWave VPS Bootstrap
# ============================================================

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

# ============================================================
# Colors
# ============================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    GRAY='\033[0;90m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    WHITE=''
    GRAY=''
    RESET=''
fi

# ============================================================
# Colored output helpers
# ============================================================

msg_info() {
    echo -e "${CYAN}$*${RESET}"
}

msg_ok() {
    echo -e "${GREEN}$*${RESET}"
}

msg_warn() {
    echo -e "${YELLOW}$*${RESET}"
}

msg_error() {
    echo -e "${RED}$*${RESET}"
}

msg_title() {
    echo
    echo -e "${BLUE}============================================================${RESET}"
    echo -e "${WHITE}$*${RESET}"
    echo -e "${BLUE}============================================================${RESET}"
    echo
}

msg_step() {
    echo
    echo -e "${CYAN}------------------------------------------------------------${RESET}"
    echo -e "${WHITE}$*${RESET}"
    echo -e "${CYAN}------------------------------------------------------------${RESET}"
    echo
}

# ============================================================
# Root check
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    msg_error "Ошибка: скрипт необходимо запускать от root."
    exit 1
fi

# ============================================================
# Work directory
# ============================================================

cd /root || exit 1

# ============================================================
# Logging
# ============================================================

mkdir -p "$(dirname "$LOG_FILE")"

exec > >(tee -a "$LOG_FILE") 2>&1

msg_title "RemnaWave VPS Bootstrap"

echo "Лог: $LOG_FILE"
echo

# ============================================================
# Status
# ============================================================

declare -A STATUS

for i in {1..11}; do
    STATUS[$i]="NOT RUN"
done

# ============================================================
# Helpers
# ============================================================

pause_menu() {
    echo
    read -r -p "Нажмите Enter для возврата в меню..." _
}

ask_yes_no() {
    local question="$1"
    local answer

    while true; do

        echo -ne "${YELLOW}${question} [y/N]: ${RESET}"
        read -r answer

        case "${answer,,}" in
            y|yes)
                return 0
                ;;
            n|no|"")
                return 1
                ;;
            *)
                msg_warn "Введите y или n."
                ;;
        esac

    done
}

download_file() {
    local url="$1"
    local destination="$2"

    msg_info "Скачивание:"
    echo "$url"
    echo

    if command -v curl >/dev/null 2>&1; then

        curl -fL \
            --retry 3 \
            --connect-timeout 15 \
            "$url" \
            -o "$destination"

    elif command -v wget >/dev/null 2>&1; then

        wget \
            --tries=3 \
            --timeout=15 \
            -O "$destination" \
            "$url"

    else

        msg_error "Ошибка: не найден curl или wget."
        return 1
    fi
}

status_text() {
    local status="$1"

    case "$status" in
        OK)
            echo -e "${GREEN}OK${RESET}"
            ;;
        FAILED)
            echo -e "${RED}FAILED${RESET}"
            ;;
        SKIPPED)
            echo -e "${YELLOW}SKIPPED${RESET}"
            ;;
        RUNNING)
            echo -e "${CYAN}RUNNING${RESET}"
            ;;
        *)
            echo -e "${GRAY}${status}${RESET}"
            ;;
    esac
}

# ============================================================
# 1. Disable fwupd
# ============================================================

disable_fwupd() {

    msg_title "1. Отключение fwupd"

    STATUS[1]="RUNNING"

    msg_info "Остановка fwupd..."

    systemctl stop fwupd.service 2>/dev/null || true
    systemctl stop fwupd-refresh.service 2>/dev/null || true

    msg_info "Отключение автозапуска..."

    systemctl disable fwupd.service 2>/dev/null || true
    systemctl disable fwupd-refresh.service 2>/dev/null || true

    msg_info "Маскирование сервисов..."

    systemctl mask fwupd.service 2>/dev/null || true
    systemctl mask fwupd-refresh.service 2>/dev/null || true

    systemctl daemon-reload

    local fwupd_masked="no"
    local refresh_masked="no"
    local fwupd_active="no"
    local refresh_active="no"

    if systemctl is-enabled fwupd.service 2>/dev/null | grep -q "masked"; then
        fwupd_masked="yes"
    fi

    if systemctl is-enabled fwupd-refresh.service 2>/dev/null | grep -q "masked"; then
        refresh_masked="yes"
    fi

    if systemctl is-active --quiet fwupd.service 2>/dev/null; then
        fwupd_active="yes"
    fi

    if systemctl is-active --quiet fwupd-refresh.service 2>/dev/null; then
        refresh_active="yes"
    fi

    if [[ "$fwupd_masked" != "yes" ]]; then
        rm -f /etc/systemd/system/fwupd.service
        ln -sf /dev/null /etc/systemd/system/fwupd.service
        systemctl daemon-reload
    fi

    if [[ "$refresh_masked" != "yes" ]]; then
        rm -f /etc/systemd/system/fwupd-refresh.service
        ln -sf /dev/null /etc/systemd/system/fwupd-refresh.service
        systemctl daemon-reload
    fi

    fwupd_masked="no"
    refresh_masked="no"
    fwupd_active="no"
    refresh_active="no"

    if [[ -L /etc/systemd/system/fwupd.service ]] &&
       [[ "$(readlink -f /etc/systemd/system/fwupd.service)" == "/dev/null" ]]; then
        fwupd_masked="yes"
    fi

    if [[ -L /etc/systemd/system/fwupd-refresh.service ]] &&
       [[ "$(readlink -f /etc/systemd/system/fwupd-refresh.service)" == "/dev/null" ]]; then
        refresh_masked="yes"
    fi

    if systemctl is-active --quiet fwupd.service 2>/dev/null; then
        fwupd_active="yes"
    fi

    if systemctl is-active --quiet fwupd-refresh.service 2>/dev/null; then
        refresh_active="yes"
    fi

    echo
    echo "fwupd.service:"
    echo "  masked : $fwupd_masked"
    echo "  active : $fwupd_active"

    echo
    echo "fwupd-refresh.service:"
    echo "  masked : $refresh_masked"
    echo "  active : $refresh_active"

    if [[ "$fwupd_masked" == "yes" &&
          "$refresh_masked" == "yes" &&
          "$fwupd_active" == "no" &&
          "$refresh_active" == "no" ]]; then

        echo
        msg_ok "fwupd успешно отключён."
        STATUS[1]="OK"

    else

        echo
        msg_error "Не удалось полностью отключить fwupd."
        STATUS[1]="FAILED"

    fi
}

# ============================================================
# 2. apt update + show upgrades
# ============================================================

apt_update_show_upgrades() {

    msg_title "2. apt update + доступные обновления"

    STATUS[2]="RUNNING"

    msg_info "Выполняется apt-get update..."
    echo

    if apt-get update; then

        echo
        msg_info "Доступные обновления:"
        echo

        local upgrades

        upgrades=$(
            apt-get -s upgrade 2>/dev/null |
            awk '
                /^Inst / {
                    package=$2
                    version=$3
                    gsub(/\[/, "", version)
                    gsub(/\]/, "", version)
                    print package " " version
                }
            '
        )

        if [[ -n "$upgrades" ]]; then

            echo "$upgrades"

            echo
            msg_warn "Количество доступных обновлений: $(echo "$upgrades" | wc -l)"

        else

            msg_ok "Доступных обновлений нет."

        fi

        STATUS[2]="OK"

    else

        echo
        msg_error "Ошибка выполнения apt-get update."
        STATUS[2]="FAILED"

    fi
}

# ============================================================
# 3. Disable IPv6
# ============================================================

disable_ipv6() {

    msg_title "3. Отключение IPv6"

    STATUS[3]="RUNNING"

    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
# Disable IPv6

net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    msg_info "Применение sysctl..."

    if sysctl --system; then

        local all_value
        local default_value
        local lo_value

        all_value=$(sysctl -n net.ipv6.conf.all.disable_ipv6)
        default_value=$(sysctl -n net.ipv6.conf.default.disable_ipv6)
        lo_value=$(sysctl -n net.ipv6.conf.lo.disable_ipv6)

        echo
        echo "all     = $all_value"
        echo "default = $default_value"
        echo "lo      = $lo_value"

        if [[ "$all_value" == "1" &&
              "$default_value" == "1" &&
              "$lo_value" == "1" ]]; then

            echo
            msg_ok "IPv6 успешно отключён."
            STATUS[3]="OK"

        else

            echo
            msg_error "Не удалось подтвердить отключение IPv6."
            STATUS[3]="FAILED"

        fi

    else

        echo
        msg_error "Ошибка применения sysctl."
        STATUS[3]="FAILED"

    fi
}

# ============================================================
# 4. BBR / Network sysctl
# ============================================================

configure_bbr() {

    msg_title "4. BBR / Network sysctl"

    STATUS[4]="RUNNING"

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

    msg_info "Применение sysctl..."

    if sysctl --system; then

        local congestion
        local qdisc

        congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
        qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)

        echo
        echo "TCP congestion control: $congestion"
        echo "Default qdisc: $qdisc"

        if [[ "$congestion" == "bbr" &&
              "$qdisc" == "fq" ]]; then

            echo
            msg_ok "BBR успешно настроен."
            STATUS[4]="OK"

        else

            echo
            msg_error "BBR не удалось подтвердить."
            STATUS[4]="FAILED"

        fi

    else

        echo
        msg_error "Ошибка применения network sysctl."
        STATUS[4]="FAILED"

    fi
}

# ============================================================
# 5. Zapret.dat
# ============================================================

install_zapret() {

    msg_title "5. Установка Zapret.dat"

    STATUS[5]="RUNNING"

    mkdir -p "$ZAPRET_DIR"

    local temp_file
    temp_file=$(mktemp)

    msg_info "Скачивание zapret.dat..."

    if ! download_file "$ZAPRET_URL" "$temp_file"; then

        echo
        msg_error "Ошибка скачивания zapret.dat."

        rm -f "$temp_file"

        STATUS[5]="FAILED"
        return
    fi

    if [[ ! -s "$temp_file" ]]; then

        echo
        msg_error "Ошибка: скачанный zapret.dat пуст."

        rm -f "$temp_file"

        STATUS[5]="FAILED"
        return
    fi

    mv "$temp_file" "$ZAPRET_FILE"

    chmod 644 "$ZAPRET_FILE"

    echo
    msg_ok "Zapret.dat установлен:"
    echo "$ZAPRET_FILE"

    if [[ -f "$REMNANODE_COMPOSE" ]]; then

        echo
        msg_info "Найден Docker Compose:"
        echo "$REMNANODE_COMPOSE"

        cp "$REMNANODE_COMPOSE" \
            "${REMNANODE_COMPOSE}.bak.$(date +%Y%m%d-%H%M%S)"

        echo
        msg_info "Добавление volume в RemnaNode compose..."

        python3 - "$REMNANODE_COMPOSE" <<'PY'
import sys
from pathlib import Path

compose = Path(sys.argv[1])
lines = compose.read_text().splitlines()

mount = "/opt/remnanode/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro"

if any(mount in line for line in lines):
    print("Volume zapret.dat уже присутствует.")
    sys.exit(0)

service_index = None
service_indent = None

for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped == "remnanode:":
        service_index = i
        service_indent = len(line) - len(line.lstrip())
        break

if service_index is None:
    print("Не найден сервис remnanode в compose.")
    sys.exit(2)

service_end = len(lines)

for i in range(service_index + 1, len(lines)):
    line = lines[i]
    if not line.strip():
        continue
    indent = len(line) - len(line.lstrip())
    if indent <= service_indent and line.strip().endswith(":"):
        service_end = i
        break

volumes_index = None

for i in range(service_index + 1, service_end):
    line = lines[i]
    if not line.strip():
        continue
    indent = len(line) - len(line.lstrip())
    if indent == service_indent + 2 and line.strip() == "volumes:":
        volumes_index = i
        break

if volumes_index is not None:
    insert_index = volumes_index + 1
    lines.insert(
        insert_index,
        " " * (service_indent + 4) + f"- {mount}"
    )
else:
    insert_index = service_end
    lines.insert(
        insert_index,
        " " * (service_indent + 2) + "volumes:"
    )
    lines.insert(
        insert_index + 1,
        " " * (service_indent + 4) + f"- {mount}"
    )

compose.write_text("\n".join(lines) + "\n")
print("Volume zapret.dat добавлен в compose.")
PY

        local python_rc=$?

        if [[ $python_rc -eq 0 ]]; then

            echo
            msg_info "Проверка Docker Compose..."

            if command -v docker >/dev/null 2>&1; then

                if docker compose \
                    -f "$REMNANODE_COMPOSE" \
                    config >/dev/null 2>&1; then

                    msg_ok "Docker Compose config: OK"

                    echo
                    msg_info "Перезапуск RemnaNode..."

                    if docker compose \
                        -f "$REMNANODE_COMPOSE" \
                        down; then

                        if docker compose \
                            -f "$REMNANODE_COMPOSE" \
                            up -d; then

                            echo
                            msg_ok "RemnaNode успешно перезапущен."
                            STATUS[5]="OK"

                        else
                            echo
                            msg_error "Ошибка запуска Docker Compose."
                            STATUS[5]="FAILED"
                        fi

                    else
                        echo
                        msg_error "Не удалось остановить Docker Compose."
                        STATUS[5]="FAILED"
                    fi

                else
                    echo
                    msg_error "Ошибка в Docker Compose после изменения."

                    echo
                    msg_warn "Backup:"
                    ls -1t \
                        "${REMNANODE_COMPOSE}.bak."* \
                        2>/dev/null | head -1 || true

                    STATUS[5]="FAILED"
                fi

            else
                echo
                msg_warn "Docker не установлен."
                echo "Compose изменён, но контейнеры не перезапускались."
                STATUS[5]="OK"
            fi

        else
            echo
            msg_error "Не удалось добавить volume в compose."
            STATUS[5]="FAILED"
        fi

    else
        echo
        msg_warn "Docker Compose RemnaNode не найден:"
        echo "$REMNANODE_COMPOSE"
        echo
        echo "Zapret.dat установлен отдельно."
        STATUS[5]="OK"
    fi
}

# ============================================================
# 6. WARP
# ============================================================

install_warp() {

    local AUTO_TOS="${1:-no}"

    msg_title "6. Установка и настройка 2 WARP профилей"

    STATUS[6]="RUNNING"

    msg_info "Установка необходимых пакетов..."

    if ! apt-get install -y wireguard curl; then
        echo
        msg_error "Ошибка установки wireguard/curl."
        STATUS[6]="FAILED"
        return
    fi

    local wgcf="/usr/local/bin/wgcf"

    echo
    msg_info "Скачивание wgcf..."

    if ! download_file "$WGCF_URL" "$wgcf"; then
        echo
        msg_error "Ошибка скачивания wgcf."
        STATUS[6]="FAILED"
        return
    fi

    chmod +x "$wgcf"

    echo
    echo "wgcf:"
    "$wgcf" --version 2>/dev/null || true

    local tmp1
    local tmp2

    tmp1=$(mktemp -d)
    tmp2=$(mktemp -d)

    msg_step "Создание WARP профиля 1"

    cd "$tmp1" || {
        msg_error "Не удалось перейти в $tmp1."
        rm -rf "$tmp1" "$tmp2"
        STATUS[6]="FAILED"
        return
    }

    if [[ "$AUTO_TOS" == "yes" ]]; then
        msg_info "Автоматически принимаем WARP TOS..."
        if ! "$wgcf" register --accept-tos; then
            echo
            msg_error "Ошибка регистрации WARP 1."
            cd /root || true
            rm -rf "$tmp1" "$tmp2"
            STATUS[6]="FAILED"
            return
        fi
    else
        if ! "$wgcf" register; then
            echo
            msg_error "Ошибка регистрации WARP 1."
            cd /root || true
            rm -rf "$tmp1" "$tmp2"
            STATUS[6]="FAILED"
            return
        fi
    fi

    if ! "$wgcf" generate; then
        echo
        msg_error "Ошибка генерации WARP 1."
        cd /root || true
        rm -rf "$tmp1" "$tmp2"
        STATUS[6]="FAILED"
        return
    fi

    if [[ ! -f wgcf-profile.conf ]]; then
        echo
        msg_error "wgcf-profile.conf для WARP 1 не найден."
        cd /root || true
        rm -rf "$tmp1" "$tmp2"
        STATUS[6]="FAILED"
        return
    fi

    cp wgcf-profile.conf "$WARP1_CONF"

    msg_step "Создание WARP профиля 2"

    cd "$tmp2" || {
        msg_error "Не удалось перейти в $tmp2."
        cd /root || true
        rm -rf "$tmp1" "$tmp2"
        STATUS[6]="FAILED"
        return
    }

    if [[ "$AUTO_TOS" == "yes" ]]; then
        msg_info "Автоматически принимаем WARP TOS..."
        if ! "$wgcf" register --accept-tos; then
            echo
            msg_error "Ошибка регистрации WARP 2."
            cd /root || true
            rm -rf "$tmp1" "$tmp2"
            STATUS[6]="FAILED"
            return
        fi
    else
        if ! "$wgcf" register; then
            echo
            msg_error "Ошибка регистрации WARP 2."
            cd /root || true
            rm -rf "$tmp1" "$tmp2"
            STATUS[6]="FAILED"
            return
        fi
    fi

    if ! "$wgcf" generate; then
        echo
        msg_error "Ошибка генерации WARP 2."
        cd /root || true
        rm -rf "$tmp1" "$tmp2"
        STATUS[6]="FAILED"
        return
    fi

    if [[ ! -f wgcf-profile.conf ]]; then
        echo
        msg_error "wgcf-profile.conf для WARP 2 не найден."
        cd /root || true
        rm -rf "$tmp1" "$tmp2"
        STATUS[6]="FAILED"
        return
    fi

    cp wgcf-profile.conf "$WARP2_CONF"

    cd /root || true
    rm -rf "$tmp1" "$tmp2"

    msg_info "Настройка WARP 1..."

    if [[ ! -f "$WARP1_CONF" ]]; then
        msg_error "Конфигурация WARP 1 не найдена."
        STATUS[6]="FAILED"
        return
    fi

    sed -i -E '/^Address = .*:/d' "$WARP1_CONF"
    sed -i '/^Address = /d' "$WARP1_CONF"
    sed -i '/^\[Interface\]/a Address = 172.16.0.2/32' "$WARP1_CONF"

    sed -i '/^Table = /d' "$WARP1_CONF"

    if grep -q '^MTU = ' "$WARP1_CONF"; then
        sed -i '/^MTU = /a Table = off' "$WARP1_CONF"
    else
        sed -i '/^\[Interface\]/a Table = off' "$WARP1_CONF"
    fi

    sed -i '/^PersistentKeepalive = /d' "$WARP1_CONF"

    if grep -q '^Endpoint = ' "$WARP1_CONF"; then
        sed -i '/^Endpoint = /a PersistentKeepalive = 25' "$WARP1_CONF"
    else
        sed -i '/^\[Peer\]/a PersistentKeepalive = 25' "$WARP1_CONF"
    fi

    sed -i '/^AllowedIPs = /d' "$WARP1_CONF"
    sed -i '/^PublicKey = /a AllowedIPs = 0.0.0.0/0' "$WARP1_CONF"

    msg_info "Настройка WARP 2..."

    if [[ ! -f "$WARP2_CONF" ]]; then
        msg_error "Конфигурация WARP 2 не найдена."
        STATUS[6]="FAILED"
        return
    fi

    sed -i -E '/^Address = .*:/d' "$WARP2_CONF"
    sed -i '/^Address = /d' "$WARP2_CONF"
    sed -i '/^\[Interface\]/a Address = 172.16.0.3/32' "$WARP2_CONF"

    sed -i '/^Table = /d' "$WARP2_CONF"

    if grep -q '^MTU = ' "$WARP2_CONF"; then
        sed -i '/^MTU = /a Table = off' "$WARP2_CONF"
    else
        sed -i '/^\[Interface\]/a Table = off' "$WARP2_CONF"
    fi

    sed -i '/^PersistentKeepalive = /d' "$WARP2_CONF"

    if grep -q '^Endpoint = ' "$WARP2_CONF"; then
        sed -i '/^Endpoint = /a PersistentKeepalive = 25' "$WARP2_CONF"
    else
        sed -i '/^\[Peer\]/a PersistentKeepalive = 25' "$WARP2_CONF"
    fi

    sed -i '/^AllowedIPs = /d' "$WARP2_CONF"
    sed -i '/^PublicKey = /a AllowedIPs = 0.0.0.0/0' "$WARP2_CONF"

    chmod 600 "$WARP1_CONF" "$WARP2_CONF"

    msg_info "Создание WARP startup script..."

    cat > "$WARP_START" <<'EOF'
#!/bin/bash

set -e

wg-quick down wgcf1 2>/dev/null || true
wg-quick down wgcf2 2>/dev/null || true

wg-quick up wgcf1
wg-quick up wgcf2
EOF

    chmod +x "$WARP_START"

    msg_info "Создание systemd сервиса..."

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
    msg_info "Запуск WARP..."

    if systemctl restart warp.service; then

        echo
        echo "Проверка интерфейсов:"
        echo

        wg show wgcf1 || true
        echo
        wg show wgcf2 || true
        echo
        ip addr show wgcf1 || true
        echo
        ip addr show wgcf2 || true

        if ip link show wgcf1 >/dev/null 2>&1 &&
           ip link show wgcf2 >/dev/null 2>&1; then

            echo
            msg_ok "Оба WARP интерфейса успешно запущены."
            STATUS[6]="OK"

        else

            echo
            msg_error "Один или оба WARP интерфейса не запустились."
            STATUS[6]="FAILED"

        fi

    else

        echo
        msg_error "Ошибка запуска warp.service."
        systemctl status warp.service --no-pager || true
        STATUS[6]="FAILED"

    fi
}

# ============================================================
# 7. UFW
# ============================================================

configure_ufw() {

    msg_title "7. Настройка UFW"

    STATUS[7]="RUNNING"

    msg_info "Установка UFW..."

    if ! apt-get install -y ufw; then
        echo
        msg_error "Ошибка установки UFW."
        STATUS[7]="FAILED"
        return
    fi

    echo
    msg_info "Добавление правил..."

    ufw allow OpenSSH
    ufw allow 443/tcp
    ufw allow 1433/tcp

    echo
    msg_info "Включение UFW..."

    if ufw --force enable; then

        echo
        msg_info "Текущий статус UFW:"
        echo

        ufw status verbose

        echo
        msg_ok "UFW успешно настроен."
        STATUS[7]="OK"

    else

        echo
        msg_error "Ошибка включения UFW."
        STATUS[7]="FAILED"

    fi
}

# ============================================================
# 8. Fail2ban
# ============================================================

install_fail2ban() {

    msg_title "8. Установка и настройка Fail2ban"

    STATUS[8]="RUNNING"

    msg_info "Установка Fail2ban..."

    if ! apt-get install -y fail2ban; then
        echo
        msg_error "Ошибка установки Fail2ban."
        STATUS[8]="FAILED"
        return
    fi

    echo
    msg_info "Создание $FAIL2BAN_JAIL..."

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

    echo
    msg_info "Перезапуск Fail2ban..."

    systemctl enable fail2ban

    if systemctl restart fail2ban; then

        sleep 2

        echo
        msg_info "Статус Fail2ban:"
        echo

        systemctl status fail2ban --no-pager || true

        echo
        msg_info "Jail:"
        echo

        fail2ban-client status || true

        echo
        msg_info "SSHD jail:"
        echo

        fail2ban-client status sshd 2>/dev/null || true

        if systemctl is-active --quiet fail2ban; then
            echo
            msg_ok "Fail2ban успешно настроен."
            STATUS[8]="OK"
        else
            echo
            msg_error "Fail2ban не запущен."
            STATUS[8]="FAILED"
        fi

    else

        echo
        msg_error "Ошибка запуска Fail2ban."
        systemctl status fail2ban --no-pager || true
        STATUS[8]="FAILED"

    fi
}

# ============================================================
# 9. RemnaNode
# ============================================================

install_remnanode() {

    msg_title "9. Установка RemnaNode"

    STATUS[9]="RUNNING"

    local node_installer

    node_installer=$(mktemp)

    msg_info "Скачивание установщика RemnaNode..."
    echo

    if ! download_file \
        "$REMNANODE_INSTALLER_URL" \
        "$node_installer"; then

        echo
        msg_error "Ошибка скачивания установщика RemnaNode."
        rm -f "$node_installer"
        STATUS[9]="FAILED"
        return
    fi

    sed -i 's/\r$//' "$node_installer"
    chmod +x "$node_installer"

    echo
    msg_info "Запуск RemnaNode installer..."
    echo

    bash "$node_installer" @ install \
        </dev/tty \
        >/dev/tty \
        2>/dev/tty

    local installer_rc=$?

    rm -f "$node_installer"

    echo
    echo "RemnaNode installer завершён с кодом: $installer_rc"

    if [[ $installer_rc -eq 0 ]]; then
        msg_ok "RemnaNode установлен."
        STATUS[9]="OK"
    else
        msg_error "RemnaNode installer завершился с ошибкой."
        STATUS[9]="FAILED"
    fi
}

# ============================================================
# 10. Selfsteal
# ============================================================

install_selfsteal() {

    msg_title "10. Установка Selfsteal"

    STATUS[10]="RUNNING"

    local selfsteal_installer

    selfsteal_installer=$(mktemp)

    msg_info "Скачивание установщика Selfsteal..."
    echo

    if ! download_file \
        "$SELFSTEAL_INSTALLER_URL" \
        "$selfsteal_installer"; then

        echo
        msg_error "Ошибка скачивания установщика Selfsteal."
        rm -f "$selfsteal_installer"
        STATUS[10]="FAILED"
        return
    fi

    sed -i 's/\r$//' "$selfsteal_installer"
    chmod +x "$selfsteal_installer"

    echo
    msg_info "Запуск Selfsteal installer..."
    echo

    bash "$selfsteal_installer" \
        </dev/tty \
        >/dev/tty \
        2>/dev/tty

    local installer_rc=$?

    rm -f "$selfsteal_installer"

    echo
    echo "Selfsteal installer завершён с кодом: $installer_rc"

    if [[ $installer_rc -eq 0 ]]; then
        msg_ok "Selfsteal установлен."
        STATUS[10]="OK"
    else
        msg_error "Selfsteal installer завершился с ошибкой."
        STATUS[10]="FAILED"
    fi
}

# ============================================================
# Report 1-8
# ============================================================

show_report_1_to_8() {

    msg_title "Отчёт по пунктам 1-8"

    printf "%-4s │ %-52s │ %s\n" "#" "Задача" "Статус"
    printf "─────┼──────────────────────────────────────────────────────┼────────\n"

    printf "%-4s │ %-52s │ " "1" "Отключить fwupd"
    status_text "${STATUS[1]}"

    printf "%-4s │ %-52s │ " "2" "apt update + доступные обновления"
    status_text "${STATUS[2]}"

    printf "%-4s │ %-52s │ " "3" "Отключить IPv6"
    status_text "${STATUS[3]}"

    printf "%-4s │ %-52s │ " "4" "BBR / Network sysctl"
    status_text "${STATUS[4]}"

    printf "%-4s │ %-52s │ " "5" "Zapret.dat"
    status_text "${STATUS[5]}"

    printf "%-4s │ %-52s │ " "6" "2 WARP профиля"
    status_text "${STATUS[6]}"

    printf "%-4s │ %-52s │ " "7" "UFW"
    status_text "${STATUS[7]}"

    printf "%-4s │ %-52s │ " "8" "Fail2ban"
    status_text "${STATUS[8]}"

    echo
}

# ============================================================
# Final report
# ============================================================

show_final_report() {

    msg_title "Итоговый отчёт"

    printf "%-4s │ %-52s │ %s\n" "#" "Задача" "Статус"
    printf "─────┼──────────────────────────────────────────────────────┼────────\n"

    printf "%-4s │ %-52s │ " "1" "Отключить fwupd"
    status_text "${STATUS[1]}"

    printf "%-4s │ %-52s │ " "2" "apt update"
    status_text "${STATUS[2]}"

    printf "%-4s │ %-52s │ " "3" "Отключить IPv6"
    status_text "${STATUS[3]}"

    printf "%-4s │ %-52s │ " "4" "BBR / Network sysctl"
    status_text "${STATUS[4]}"

    printf "%-4s │ %-52s │ " "5" "Zapret.dat"
    status_text "${STATUS[5]}"

    printf "%-4s │ %-52s │ " "6" "2 WARP профиля"
    status_text "${STATUS[6]}"

    printf "%-4s │ %-52s │ " "7" "UFW"
    status_text "${STATUS[7]}"

    printf "%-4s │ %-52s │ " "8" "Fail2ban"
    status_text "${STATUS[8]}"

    printf "%-4s │ %-52s │ " "9" "RemnaNode"
    status_text "${STATUS[9]}"

    printf "%-4s │ %-52s │ " "10" "Selfsteal"
    status_text "${STATUS[10]}"

    printf "%-4s │ %-52s │ " "11" "Установка 1-9"
    status_text "${STATUS[11]}"

    echo
    echo "Лог:"
    echo "$LOG_FILE"
    echo
}

# ============================================================
# 11. Install 1-9
# ============================================================

install_1_to_9() {

    msg_title "11. Установка 1-9"

    STATUS[11]="RUNNING"

    local run_zapret="no"

    if ask_yes_no "Установить Zapret.dat?"; then
        run_zapret="yes"
    fi

    echo

    local run_warp="no"

    if ask_yes_no "Установить и настроить 2 WARP профиля?"; then
        run_warp="yes"
    fi

    echo

    local run_ufw="no"

    if ask_yes_no "Настроить UFW?"; then
        run_ufw="yes"
    fi

    echo

    disable_fwupd

    msg_step "Переход к пункту 2"
    apt_update_show_upgrades

    msg_step "Переход к пункту 3"
    disable_ipv6

    msg_step "Переход к пункту 4"
    configure_bbr

    msg_step "Переход к пункту 5"

    if [[ "$run_zapret" == "yes" ]]; then
        install_zapret
    else
        msg_warn "Zapret.dat пропущен."
        STATUS[5]="SKIPPED"
    fi

    msg_step "Переход к пункту 6"

    if [[ "$run_warp" == "yes" ]]; then
        install_warp yes
    else
        msg_warn "WARP пропущен."
        STATUS[6]="SKIPPED"
    fi

    msg_step "Переход к пункту 7"

    if [[ "$run_ufw" == "yes" ]]; then
        configure_ufw
    else
        msg_warn "UFW пропущен."
        STATUS[7]="SKIPPED"
    fi

    msg_step "Переход к пункту 8"
    install_fail2ban

    show_report_1_to_8

    echo
    msg_info "Переход к установке RemnaNode..."
    echo

    install_remnanode

    STATUS[11]="OK"

    show_final_report

    echo
    msg_ok "Установка 1-9 завершена."
    echo

    exit 0
}

# ============================================================
# Main menu
# ============================================================

while true; do

    clear 2>/dev/null || true

    echo
    echo -e "${BLUE}============================================================${RESET}"
    echo -e "${WHITE}             RemnaWave VPS Bootstrap${RESET}"
    echo -e "${BLUE}============================================================${RESET}"
    echo
    echo -e "${CYAN}1.${RESET}  Отключить fwupd"
    echo -e "${CYAN}2.${RESET}  apt update + показать доступные обновления"
    echo -e "${CYAN}3.${RESET}  Отключить IPv6"
    echo -e "${CYAN}4.${RESET}  Настроить BBR / Network sysctl"
    echo -e "${CYAN}5.${RESET}  Установить Zapret.dat"
    echo -e "${CYAN}6.${RESET}  Установить и настроить 2 WARP профиля"
    echo -e "${CYAN}7.${RESET}  Настроить UFW"
    echo -e "${CYAN}8.${RESET}  Установить и настроить Fail2ban"
    echo -e "${CYAN}9.${RESET}  Установить RemnaNode"
    echo -e "${CYAN}10.${RESET} Установить Selfsteal"
    echo
    echo -e "${YELLOW}11.${RESET} Установить 1-9"
    echo
    echo -e "${GRAY}0.${RESET}  Выход"
    echo
    echo -e "${BLUE}============================================================${RESET}"
    echo

    echo -ne "${WHITE}Выберите пункт: ${RESET}"
    read -r choice

    case "$choice" in
        1)
            disable_fwupd
            pause_menu
            ;;
        2)
            apt_update_show_upgrades
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
            install_warp no
            pause_menu
            ;;
        7)
            configure_ufw
            pause_menu
            ;;
        8)
            install_fail2ban
            pause_menu
            ;;
        9)
            install_remnanode
            pause_menu
            ;;
        10)
            install_selfsteal
            pause_menu
            ;;
        11)
            install_1_to_9
            ;;
        0)
            echo
            msg_info "Выход."
            echo
            exit 0
            ;;
        *)
            echo
            msg_error "Неверный пункт."
            sleep 1
            ;;
    esac

done
```
