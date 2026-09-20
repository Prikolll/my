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
# Table formatting helpers
# ============================================================

pad_to_width() {
    local text="$1"
    local target_width="$2"
    local visible_width=${#text}
    local padding=$((target_width - visible_width))

    if [[ $padding -gt 0 ]]; then
        printf "%s%*s" "$text" "$padding" ""
    else
        printf "%s" "$text"
    fi
}

print_table_header() {
    local col1_width=4
    local col2_width=55
    local col3_width=8

    printf "%s │ %s │ %s\n" \
        "$(pad_to_width "#" $col1_width)" \
        "$(pad_to_width "Задача" $col2_width)" \
        "$(pad_to_width "Статус" $col3_width)"

    printf "%s┼%s┼%s\n" \
        "$(printf '%*s' $((col1_width + 1)) '' | tr ' ' '─')" \
        "$(printf '%*s' $((col2_width + 2)) '' | tr ' ' '─')" \
        "$(printf '%*s' $((col3_width + 1)) '' | tr ' ' '─')"
}

print_table_row() {
    local num="$1"
    local task="$2"
    local status="$3"

    local col1_width=4
    local col2_width=55
    local col3_width=8

    printf "%s │ %s │ " \
        "$(pad_to_width "$num" $col1_width)" \
        "$(pad_to_width "$task" $col2_width)"

    local status_plain
    case "$status" in
        OK) status_plain="OK" ;;
        FAILED) status_plain="FAILED" ;;
        SKIPPED) status_plain="SKIPPED" ;;
        RUNNING) status_plain="RUNNING" ;;
        *) status_plain="$status" ;;
    esac

    local colored_status
    colored_status=$(status_text "$status")

    local visible_width=${#status_plain}
    local padding=$((col3_width - visible_width))

    printf "%s%*s\n" "$colored_status" "$padding" ""
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

    # --------------------------------------------------------
    # Проверяем реальное состояние
    # --------------------------------------------------------

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

    # --------------------------------------------------------
    # Если systemd не показывает masked — создаём маску вручную
    # --------------------------------------------------------

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

    # --------------------------------------------------------
    # Финальная проверка
    # --------------------------------------------------------

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

    # ========================================================
    # Docker Compose
    # ========================================================

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

# ------------------------------------------------------------
# Already exists
# ------------------------------------------------------------

if any(mount in line for line in lines):
    print("Volume zapret.dat уже присутствует.")
    sys.exit(0)

# ------------------------------------------------------------
# Find remnanode service
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# Find end of service
# ------------------------------------------------------------

service_end = len(lines)

for i in range(service_index + 1, len(lines)):

    line = lines[i]

    if not line.strip():
        continue

    indent = len(line) - len(line.lstrip())

    if indent <= service_indent and line.strip().endswith(":"):
        service_end = i
        break

# ------------------------------------------------------------
# Find volumes
# ------------------------------------------------------------

volumes_index = None

for i in range(service_index + 1, service_end):

    line = lines[i]

    if not line.strip():
        continue

    indent = len(line) - len(line.lstrip())

    if indent == service_indent + 2 and line.strip() == "volumes:":
        volumes_index = i
        break

# ------------------------------------------------------------
# Add mount
# ------------------------------------------------------------

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

    # ========================================================
    # WARP 1
    # ========================================================

    msg_step "Создание WARP профиля 1"

    cd "$tmp1" || {

        msg_error "Не удалось перейти
