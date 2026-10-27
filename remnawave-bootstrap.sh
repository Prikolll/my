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

WARP_CONF_DIR="/etc/wireguard"
WARP_START="/usr/local/bin/warp_start.sh"
WARP_SERVICE="/etc/systemd/system/warp.service"
WARP_COUNT=2

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

for i in {1..10}; do
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
    local default="${2:-n}"
    local answer
    local prompt_hint

    if [[ "${default,,}" == "y" ]]; then
        prompt_hint="[Y/n]"
    else
        prompt_hint="[y/N]"
    fi

    while true; do

        echo -ne "${YELLOW}${question} ${prompt_hint}: ${RESET}"
        read -r answer

        if [[ -z "$answer" ]]; then
            answer="$default"
        fi

        case "${answer,,}" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                msg_warn "Введите y или n."
                ;;
        esac

    done
}

ask_warp_count() {
    local min_count=1
    for ((j = 1; j <= 250; j++)); do
        if [[ -f "${WARP_CONF_DIR}/wgcf${j}.conf" ]]; then
            min_count=$((j + 1))
        else
            break
        fi
    done

    local default_count=2
    if [[ $min_count -gt 2 ]]; then
        default_count=$min_count
    elif [[ $min_count -eq 2 ]]; then
        default_count=3
    fi

    local count
    while true; do
        if [[ $min_count -gt 1 ]]; then
            echo -ne "${YELLOW}Уже создано профилей: $((min_count - 1)). Укажите общее количество профилей (от ${min_count} до 250) [по умолчанию: ${default_count}]: ${RESET}"
        else
            echo -ne "${YELLOW}Сколько профилей WARP создать? (1-250) [по умолчанию: 2]: ${RESET}"
        fi
        read -r count
        count="${count:-$default_count}"

        if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -ge $min_count && "$count" -le 250 ]]; then
            WARP_COUNT="$count"
            return 0
        else
            msg_warn "Пожалуйста, введите целое число от ${min_count} до 250."
        fi
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
# DPKG lock helpers
# ============================================================

wait_for_dpkg_lock() {

    local max_wait="${1:-600}"
    local waited=0

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do

        if [[ $waited -ge $max_wait ]]; then

            msg_error "Превышено максимальное время ожидания блокировки dpkg (${max_wait}с)."
            return 1

        fi

        if [[ $waited -eq 0 ]]; then

            msg_warn "Обнаружена блокировка dpkg. Ожидание завершения другого процесса..."

            local holder_pid
            holder_pid=$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null | awk '{print $1}')

            if [[ -n "$holder_pid" ]]; then

                local holder_cmd
                holder_cmd=$(ps -p "$holder_pid" -o comm= 2>/dev/null || echo "unknown")

                msg_info "Блокирующий процесс: PID $holder_pid ($holder_cmd)"

            fi

        fi

        sleep 5
        waited=$((waited + 5))

        if [[ $((waited % 30)) -eq 0 ]]; then

            msg_info "Ожидание: ${waited}с / ${max_wait}с..."

        fi

    done

    if [[ $waited -gt 0 ]]; then

        msg_ok "Блокировка dpkg освобождена (ожидали ${waited}с)."

    fi

    return 0
}

apt_install_with_retry() {

    if ! wait_for_dpkg_lock 600; then
        return 1
    fi

    local max_attempts=3
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do

        if apt-get install -y "$@"; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then

            msg_warn "Попытка $attempt/$max_attempts не удалась. Ожидание блокировки dpkg..."

            if ! wait_for_dpkg_lock 300; then
                return 1
            fi

            attempt=$((attempt + 1))

        else

            msg_error "Не удалось установить пакеты после $max_attempts попыток."
            return 1

        fi

    done

    return 1
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

    if ! wait_for_dpkg_lock 600; then
        STATUS[2]="FAILED"
        return 1
    fi

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

ensure_zapret_volume() {

    if [[ ! -f "$REMNANODE_COMPOSE" ]]; then

        msg_warn "Docker Compose RemnaNode не найден:"
        echo "$REMNANODE_COMPOSE"
        return 1

    fi

    echo
    msg_info "Найден Docker Compose:"
    echo "$REMNANODE_COMPOSE"

    cp "$REMNANODE_COMPOSE" \
        "${REMNANODE_COMPOSE}.bak.$(date +%Y%m%d-%H%M%S)"

    echo
    msg_info "Добавление volume zapret.dat в RemnaNode compose..."

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

    if [[ $python_rc -ne 0 ]]; then

        msg_error "Не удалось добавить volume в compose."
        return 1

    fi

    echo
    msg_info "Проверка Docker Compose..."

    if ! command -v docker >/dev/null 2>&1; then

        msg_warn "Docker не установлен. Volume добавлен в compose, но контейнеры не перезапускались."
        return 0

    fi

    if ! docker compose -f "$REMNANODE_COMPOSE" config >/dev/null 2>&1; then

        msg_error "Ошибка в Docker Compose после изменения."
        echo
        msg_warn "Backup:"
        ls -1t "${REMNANODE_COMPOSE}.bak."* 2>/dev/null | head -1 || true
        return 1

    fi

    msg_ok "Docker Compose config: OK"

    echo
    msg_info "Перезапуск RemnaNode..."

    if docker compose -f "$REMNANODE_COMPOSE" down &&
       docker compose -f "$REMNANODE_COMPOSE" up -d; then

        msg_ok "RemnaNode успешно перезапущен."
        return 0

    else

        msg_error "Ошибка перезапуска RemnaNode."
        return 1

    fi
}

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

    if ensure_zapret_volume; then

        msg_ok "Volume zapret.dat добавлен в compose."

    else

        msg_warn "Volume zapret.dat не добавлен в compose (Docker/RemnaNode ещё не установлен)."
        msg_info "Файл zapret.dat установлен, volume будет добавлен после установки RemnaNode."

    fi

    STATUS[5]="OK"
}

# ============================================================
# 6. WARP
# ============================================================

install_warp() {

    local COUNT_ARG="${1:-}"

    if [[ -n "$COUNT_ARG" ]]; then
        WARP_COUNT="$COUNT_ARG"
    else
        ask_warp_count
    fi

    # Determine existing max index to support resuming/appending
    local max_existing=0
    for ((j = 1; j <= 250; j++)); do
        if [[ -f "${WARP_CONF_DIR}/wgcf${j}.conf" ]]; then
            max_existing=$j
        else
            break
        fi
    done

    if [[ $WARP_COUNT -lt $max_existing ]]; then
        WARP_COUNT=$max_existing
    fi

    local start_index=$((max_existing + 1))

    msg_title "6. Установка и настройка WARP профилей (Всего: ${WARP_COUNT}, создаем с ${start_index})"

    STATUS[6]="RUNNING"

    msg_info "Установка необходимых пакетов..."

    if ! apt_install_with_retry wireguard curl; then

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

    mkdir -p "$WARP_CONF_DIR"

    for ((i = start_index; i <= WARP_COUNT; i++)); do

        local tmp_dir
        tmp_dir=$(mktemp -d)
        local conf_file="${WARP_CONF_DIR}/wgcf${i}.conf"
        local ip_octet=$((i + 1))
        local local_ip="172.16.0.${ip_octet}/32"

        msg_step "Создание WARP профиля ${i} из ${WARP_COUNT} (IP: ${local_ip})"

        cd "$tmp_dir" || {
            msg_error "Не удалось перейти в $tmp_dir."
            rm -rf "$tmp_dir"
            STATUS[6]="FAILED"
            return
        }

        msg_info "Регистрация профиля WARP ${i} (с защитой от 429 Too Many Requests)..."

        local reg_success="false"
        local reg_attempt=1
        local max_reg_attempts=5

        while [[ $reg_attempt -le $max_reg_attempts ]]; do
            if "$wgcf" register --accept-tos; then
                reg_success="true"
                break
            else
                msg_warn "Лимит запросов Cloudflare (429). Ожидание 10 секунд перед попыткой $reg_attempt/$max_reg_attempts..."
                sleep 10
                reg_attempt=$((reg_attempt + 1))
            fi
        done

        if [[ "$reg_success" != "true" ]]; then
            echo
            msg_error "Ошибка регистрации WARP ${i} после $max_reg_attempts попыток."
            cd /root || true
            rm -rf "$tmp_dir"
            STATUS[6]="FAILED"
            return
        fi

        if ! "$wgcf" generate; then
            echo
            msg_error "Ошибка генерации WARP ${i}."
            cd /root || true
            rm -rf "$tmp_dir"
            STATUS[6]="FAILED"
            return
        fi

        if [[ ! -f wgcf-profile.conf ]]; then
            echo
            msg_error "wgcf-profile.conf для WARP ${i} не найден."
            cd /root || true
            rm -rf "$tmp_dir"
            STATUS[6]="FAILED"
            return
        fi

        cp wgcf-profile.conf "$conf_file"

        cd /root || true
        rm -rf "$tmp_dir"

        msg_info "Настройка WARP ${i} (${conf_file} -> ${local_ip})..."

        if [[ ! -f "$conf_file" ]]; then
            msg_error "Конфигурация WARP ${i} не найдена."
            STATUS[6]="FAILED"
            return
        fi

        sed -i -E '/^Address = .*:/d' "$conf_file"
        sed -i '/^Address = /d' "$conf_file"
        sed -i '/^DNS = /d' "$conf_file"
        sed -i "/^\[Interface\]/a Address = ${local_ip}" "$conf_file"

        sed -i '/^Table = /d' "$conf_file"

        if grep -q '^MTU = ' "$conf_file"; then
            sed -i '/^MTU = /a Table = off' "$conf_file"
        else
            sed -i '/^\[Interface\]/a Table = off' "$conf_file"
        fi

        sed -i '/^PersistentKeepalive = /d' "$conf_file"

        if grep -q '^Endpoint = ' "$conf_file"; then
            sed -i '/^Endpoint = /a PersistentKeepalive = 25' "$conf_file"
        else
            sed -i '/^\[Peer\]/a PersistentKeepalive = 25' "$conf_file"
        fi

        sed -i '/^AllowedIPs = /d' "$conf_file"
        sed -i '/^PublicKey = /a AllowedIPs = 0.0.0.0/0' "$conf_file"

        chmod 600 "$conf_file"

        if [[ $i -lt $WARP_COUNT ]]; then
            # Pause increases by 1 second after every 5 profiles (Base: 3s)
            local current_pause=$(( 3 + (i - 1) / 5 ))
            msg_info "Пауза ${current_pause} сек. перед созданием следующего профиля..."
            sleep "$current_pause"
        fi

    done

    msg_info "Создание WARP startup script ($WARP_START)..."

    {
        echo "#!/bin/bash"
        echo ""
        echo "set -e"
        echo ""
        for ((i = 1; i <= WARP_COUNT; i++)); do
            echo "wg-quick down wgcf${i} 2>/dev/null || true"
        done
        echo ""
        for ((i = 1; i <= WARP_COUNT; i++)); do
            echo "wg-quick up wgcf${i}"
        done
    } > "$WARP_START"

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

        local all_up="yes"

        for ((i = 1; i <= WARP_COUNT; i++)); do
            wg show "wgcf${i}" || true
            echo
            ip addr show "wgcf${i}" || true
            echo

            if ! ip link show "wgcf${i}" >/dev/null 2>&1; then
                all_up="no"
            fi
        done

        if [[ "$all_up" == "yes" ]]; then

            echo
            msg_ok "Все WARP интерфейсы (${WARP_COUNT} шт.) успешно запущены."
            STATUS[6]="OK"

        else

            echo
            msg_error "Один или несколько WARP интерфейсов не запустились."
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

    if ! apt_install_with_retry ufw; then

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

    if ! apt_install_with_retry fail2ban; then

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

    local AUTO_CONFIRM="${1:-no}"

    msg_title "9. Установка RemnaNode"

    STATUS[9]="RUNNING"

    if ! wait_for_dpkg_lock 600; then
        STATUS[9]="FAILED"
        return 1
    fi

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

    # Fix CRLF
    sed -i 's/\r$//' "$node_installer"

    chmod +x "$node_installer"

    echo
    msg_info "Запуск RemnaNode installer..."
    echo

    local should_auto_confirm="no"

    if [[ "$AUTO_CONFIRM" == "yes" ]] && [[ -d "$REMNANODE_DIR" ]]; then
        should_auto_confirm="yes"
        msg_info "Автоматическое подтверждение первого вопроса включено."
    else
        msg_info "Автоматическое подтверждение отключено."
    fi

    echo

    python3 - "$node_installer" "$should_auto_confirm" <<'PYEOF'
import pty
import os
import sys
import select
import time
import termios
import tty
import signal
import re

installer = sys.argv[1]
auto_confirm = sys.argv[2] == "yes"

pid, fd = pty.fork()

if pid == 0:
    os.execvp("bash", ["bash", installer, "@", "install"])

tty_fd = os.open("/dev/tty", os.O_RDWR)

if auto_confirm:
    time.sleep(1)
    os.write(fd, b"y\n")

old_tty = termios.tcgetattr(tty_fd)

buffer = b""
started_detected = False
start_time = None

ansi_re = re.compile(rb'\x1b\[[0-9;?]*[ -/]*[@-~]')

CHECK_MARK_UTF8 = b'\xe2\x9c\x94'
started_re = re.compile(
    CHECK_MARK_UTF8 + rb'\s*Container\s+remnanode\s+Started',
    re.IGNORECASE
)

try:
    tty.setraw(tty_fd)

    while True:
        r, _, _ = select.select([tty_fd, fd], [], [], 0.1)

        if tty_fd in r:
            try:
                data = os.read(tty_fd, 1024)
            except:
                break
            if not data:
                break
            os.write(fd, data)

        if fd in r:
            try:
                data = os.read(fd, 1024)
            except:
                break
            if not data:
                break
            os.write(tty_fd, data)

            buffer += data
            if len(buffer) > 4096:
                buffer = buffer[-2048:]

            if not started_detected:
                clean = ansi_re.sub(b'', buffer)
                if started_re.search(clean):
                    started_detected = True
                    start_time = time.time()

        if started_detected and start_time is not None:
            if time.time() - start_time >= 2.0:
                break

finally:
    try:
        termios.tcsetattr(tty_fd, termios.TCSADRAIN, old_tty)
    except:
        pass
    try:
        os.close(tty_fd)
    except:
        pass

if started_detected:
    try:
        os.kill(pid, signal.SIGTERM)
    except:
        pass
    time.sleep(0.3)
    try:
        os.kill(pid, signal.SIGKILL)
    except:
        pass
    try:
        os.waitpid(pid, 0)
    except:
        pass
    sys.exit(0)

try:
    _, status = os.waitpid(pid, 0)
    sys.exit(os.WEXITSTATUS(status))
except:
    sys.exit(1)
PYEOF

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

    if ! wait_for_dpkg_lock 600; then
        STATUS[10]="FAILED"
        return 1
    fi

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

    # Fix CRLF
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
# Final report
# ============================================================

show_final_report() {

    msg_title "Итоговый отчёт"

    print_table_header

    print_table_row "1" "Отключить fwupd" "${STATUS[1]}"
    print_table_row "2" "apt update" "${STATUS[2]}"
    print_table_row "3" "Отключить IPv6" "${STATUS[3]}"
    print_table_row "4" "BBR / Network sysctl" "${STATUS[4]}"
    print_table_row "5" "Zapret.dat" "${STATUS[5]}"
    print_table_row "6" "WARP профили (${WARP_COUNT} шт.)" "${STATUS[6]}"
    print_table_row "7" "UFW" "${STATUS[7]}"
    print_table_row "8" "Fail2ban" "${STATUS[8]}"
    print_table_row "9" "RemnaNode" "${STATUS[9]}"
    print_table_row "10" "Selfsteal" "${STATUS[10]}"

    echo
    echo "Лог:"
    echo "$LOG_FILE"
    echo
}

# ============================================================
# Auto-install wizard
# ============================================================

run_auto_install() {

    msg_title "Мастер автоматической установки"

    msg_info "Ответьте на вопросы, чтобы выбрать, какие компоненты установить автоматически."
    echo

    local run_fwupd="no"
    local run_apt="no"
    local run_ipv6="no"
    local run_bbr="no"
    local run_zapret="no"
    local run_warp="no"
    local run_ufw="no"
    local run_fail2ban="no"
    local run_remnanode="no"
    local run_selfsteal="no"

    if ask_yes_no "1. Отключить fwupd?" "y"; then run_fwupd="yes"; fi
    if ask_yes_no "2. Выполнить apt update и показать обновления?" "y"; then run_apt="yes"; fi
    if ask_yes_no "3. Отключить IPv6?" "y"; then run_ipv6="yes"; fi
    if ask_yes_no "4. Настроить BBR / Network sysctl?" "y"; then run_bbr="yes"; fi
    if ask_yes_no "5. Установить Zapret.dat?" "y"; then run_zapret="yes"; fi
    if ask_yes_no "6. Установить и настроить WARP профили?" "y"; then
        run_warp="yes"
        ask_warp_count
    fi
    if ask_yes_no "7. Настроить UFW?" "y"; then run_ufw="yes"; fi
    if ask_yes_no "8. Установить и настроить Fail2ban?" "y"; then run_fail2ban="yes"; fi
    if ask_yes_no "9. Установить RemnaNode?" "y"; then run_remnanode="yes"; fi
    if ask_yes_no "10. Установить Selfsteal?" "n"; then run_selfsteal="yes"; fi

    echo
    msg_step "Запуск автоматической установки выбранных компонентов"

    # 1
    if [[ "$run_fwupd" == "yes" ]]; then
        disable_fwupd
    else
        STATUS[1]="SKIPPED"
        msg_warn "Пункт 1 (fwupd) пропущен."
    fi

    # 2
    if [[ "$run_apt" == "yes" ]]; then
        apt_update_show_upgrades
    else
        STATUS[2]="SKIPPED"
        msg_warn "Пункт 2 (apt update) пропущен."
    fi

    # 3
    if [[ "$run_ipv6" == "yes" ]]; then
        disable_ipv6
    else
        STATUS[3]="SKIPPED"
        msg_warn "Пункт 3 (IPv6) пропущен."
    fi

    # 4
    if [[ "$run_bbr" == "yes" ]]; then
        configure_bbr
    else
        STATUS[4]="SKIPPED"
        msg_warn "Пункт 4 (BBR) пропущен."
    fi

    # 5
    if [[ "$run_zapret" == "yes" ]]; then
        install_zapret
    else
        STATUS[5]="SKIPPED"
        msg_warn "Пункт 5 (Zapret) пропущен."
    fi

    # 6
    if [[ "$run_warp" == "yes" ]]; then
        install_warp "$WARP_COUNT"
    else
        STATUS[6]="SKIPPED"
        msg_warn "Пункт 6 (WARP) пропущен."
    fi

    # 7
    if [[ "$run_ufw" == "yes" ]]; then
        configure_ufw
    else
        STATUS[7]="SKIPPED"
        msg_warn "Пункт 7 (UFW) пропущен."
    fi

    # 8
    if [[ "$run_fail2ban" == "yes" ]]; then
        install_fail2ban
    else
        STATUS[8]="SKIPPED"
        msg_warn "Пункт 8 (Fail2ban) пропущен."
    fi

    # 9
    if [[ "$run_remnanode" == "yes" ]]; then
        install_remnanode yes

        if [[ "$run_zapret" == "yes" ]] && [[ "${STATUS[9]}" == "OK" ]]; then
            msg_step "Добавление volume zapret.dat в compose..."
            if ensure_zapret_volume; then
                msg_ok "Volume zapret.dat добавлен в RemnaNode compose."
            else
                msg_error "Не удалось добавить volume zapret.dat."
            fi
        fi
    else
        STATUS[9]="SKIPPED"
        msg_warn "Пункт 9 (RemnaNode) пропущен."
    fi

    # 10
    if [[ "$run_selfsteal" == "yes" ]]; then
        install_selfsteal
    else
        STATUS[10]="SKIPPED"
        msg_warn "Пункт 10 (Selfsteal) пропущен."
    fi

    show_final_report

    echo
    msg_ok "Автоматическая установка завершена."
    echo
    pause_menu
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
    echo -e "${CYAN}6.${RESET}  Установить и настроить WARP профили"
    echo -e "${CYAN}7.${RESET}  Настроить UFW"
    echo -e "${CYAN}8.${RESET}  Установить и настроить Fail2ban"
    echo -e "${CYAN}9.${RESET}  Установить RemnaNode"
    echo -e "${CYAN}10.${RESET} Установить Selfsteal"
    echo
    echo -e "${YELLOW}11.${RESET} Автоматическая установка (мастер)"
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
            install_warp
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
            run_auto_install
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
