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
# Root check
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    echo "Ошибка: скрипт необходимо запускать от root."
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

echo
echo "============================================================"
echo " RemnaWave VPS Bootstrap"
echo "============================================================"
echo
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
        read -r -p "$question [y/N]: " answer

        case "${answer,,}" in
            y|yes)
                return 0
                ;;
            n|no|"")
                return 1
                ;;
            *)
                echo "Введите y или n."
                ;;
        esac
    done
}

download_file() {
    local url="$1"
    local destination="$2"

    echo
    echo "Скачивание:"
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
        echo "Ошибка: не найден curl или wget."
        return 1
    fi
}

# ============================================================
# 1. Disable fwupd
# ============================================================

disable_fwupd() {

    echo
    echo "============================================================"
    echo "1. Отключение fwupd"
    echo "============================================================"
    echo

    STATUS[1]="RUNNING"

    echo "Остановка fwupd..."

    systemctl stop fwupd.service 2>/dev/null || true
    systemctl disable fwupd.service 2>/dev/null || true
    systemctl mask fwupd.service 2>/dev/null || true

    systemctl stop fwupd-refresh.service 2>/dev/null || true
    systemctl disable fwupd-refresh.service 2>/dev/null || true
    systemctl mask fwupd-refresh.service 2>/dev/null || true

    systemctl daemon-reload

    echo
    echo "Проверка состояния:"
    echo

    systemctl is-enabled fwupd.service 2>/dev/null || true
    systemctl is-active fwupd.service 2>/dev/null || true

    if systemctl is-enabled fwupd.service 2>/dev/null | grep -qE 'masked|disabled'; then
        echo
        echo "fwupd успешно отключён."
        STATUS[1]="OK"
    else
        echo
        echo "Проверка стандартного состояния не подтвердила отключение."

        # Дополнительная защита
        if [[ ! -L /etc/systemd/system/fwupd.service ]]; then
            ln -sf /dev/null /etc/systemd/system/fwupd.service
        fi

        systemctl daemon-reload

        if systemctl is-enabled fwupd.service 2>/dev/null | grep -q masked; then
            echo "fwupd замаскирован."
            STATUS[1]="OK"
        else
            echo "Не удалось полностью отключить fwupd."
            STATUS[1]="FAILED"
        fi
    fi
}

# ============================================================
# 2. apt update + show upgrades
# ============================================================

apt_update_show_upgrades() {

    echo
    echo "============================================================"
    echo "2. apt update + доступные обновления"
    echo "============================================================"
    echo

    STATUS[2]="RUNNING"

    echo "Выполняется apt update..."
    echo

    if apt update; then

        echo
        echo "============================================================"
        echo "Доступные обновления"
        echo "============================================================"
        echo

        apt list --upgradable 2>/dev/null || true

        STATUS[2]="OK"

    else

        echo
        echo "Ошибка выполнения apt update."
        STATUS[2]="FAILED"
    fi
}

# ============================================================
# 3. Disable IPv6
# ============================================================

disable_ipv6() {

    echo
    echo "============================================================"
    echo "3. Отключение IPv6"
    echo "============================================================"
    echo

    STATUS[3]="RUNNING"

    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
# Disable IPv6

net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    echo "Применение sysctl..."

    if sysctl --system; then

        echo
        echo "Проверка:"
        echo

        ALL_VALUE=$(sysctl -n net.ipv6.conf.all.disable_ipv6)
        DEFAULT_VALUE=$(sysctl -n net.ipv6.conf.default.disable_ipv6)
        LO_VALUE=$(sysctl -n net.ipv6.conf.lo.disable_ipv6)

        echo "all     = $ALL_VALUE"
        echo "default = $DEFAULT_VALUE"
        echo "lo      = $LO_VALUE"

        if [[ "$ALL_VALUE" == "1" &&
              "$DEFAULT_VALUE" == "1" &&
              "$LO_VALUE" == "1" ]]; then

            echo
            echo "IPv6 успешно отключён."
            STATUS[3]="OK"

        else

            echo
            echo "Не удалось подтвердить отключение IPv6."
            STATUS[3]="FAILED"
        fi

    else

        echo
        echo "Ошибка применения sysctl."
        STATUS[3]="FAILED"
    fi
}

# ============================================================
# 4. BBR / Network sysctl
# ============================================================

configure_bbr() {

    echo
    echo "============================================================"
    echo "4. BBR / Network sysctl"
    echo "============================================================"
    echo

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

    echo "Применение sysctl..."

    if sysctl --system; then

        local congestion
        local qdisc

        congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
        qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)

        echo
        echo "TCP congestion control: $congestion"
        echo "Default qdisc: $qdisc"
        echo

        if [[ "$congestion" == "bbr" && "$qdisc" == "fq" ]]; then
            echo "BBR успешно настроен."
            STATUS[4]="OK"
        else
            echo "BBR не удалось подтвердить."
            STATUS[4]="FAILED"
        fi

    else

        echo
        echo "Ошибка применения network sysctl."
        STATUS[4]="FAILED"
    fi
}

# ============================================================
# 5. Zapret.dat
# ============================================================

install_zapret() {

    echo
    echo "============================================================"
    echo "5. Установка Zapret.dat"
    echo "============================================================"
    echo

    STATUS[5]="RUNNING"

    mkdir -p "$ZAPRET_DIR"

    local temp_file
    temp_file=$(mktemp)

    echo "Скачивание zapret.dat..."

    if ! download_file "$ZAPRET_URL" "$temp_file"; then
        echo
        echo "Ошибка скачивания zapret.dat."
        rm -f "$temp_file"
        STATUS[5]="FAILED"
        return
    fi

    if [[ ! -s "$temp_file" ]]; then
        echo
        echo "Ошибка: скачанный zapret.dat пуст."
        rm -f "$temp_file"
        STATUS[5]="FAILED"
        return
    fi

    mv "$temp_file" "$ZAPRET_FILE"

    chmod 644 "$ZAPRET_FILE"

    echo
    echo "Zapret.dat установлен:"
    echo "$ZAPRET_FILE"
    echo

    # --------------------------------------------------------
    # Проверяем Docker Compose
    # --------------------------------------------------------

    if [[ -f "$REMNANODE_COMPOSE" ]]; then

        echo "Найден Docker Compose:"
        echo "$REMNANODE_COMPOSE"
        echo

        cp "$REMNANODE_COMPOSE" \
            "${REMNANODE_COMPOSE}.bak.$(date +%Y%m%d-%H%M%S)"

        echo "Добавление volume в RemnaNode compose..."

        python3 - "$REMNANODE_COMPOSE" <<'PY'
import sys
from pathlib import Path

compose = Path(sys.argv[1])

lines = compose.read_text().splitlines()

mount = "/opt/remnanode/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro"

# ------------------------------------------------------------
# Already exists?
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
# Find next service on same level
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
# Find volumes inside remnanode
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
# Existing volumes section
# ------------------------------------------------------------

if volumes_index is not None:

    insert_index = volumes_index + 1

    lines.insert(
        insert_index,
        " " * (service_indent + 4) + f"- {mount}"
    )

else:

    # --------------------------------------------------------
    # Create volumes section before next service
    # --------------------------------------------------------

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
            echo "Проверка Docker Compose..."

            if command -v docker >/dev/null 2>&1; then

                if docker compose -f "$REMNANODE_COMPOSE" config >/dev/null 2>&1; then

                    echo "Docker Compose config: OK"

                    echo
                    echo "Перезапуск RemnaNode..."

                    if docker compose \
                        -f "$REMNANODE_COMPOSE" \
                        down; then

                        if docker compose \
                            -f "$REMNANODE_COMPOSE" \
                            up -d; then

                            echo
                            echo "RemnaNode успешно перезапущен."
                            STATUS[5]="OK"

                        else
                            echo
                            echo "Ошибка запуска Docker Compose."
                            STATUS[5]="FAILED"
                        fi

                    else

                        echo
                        echo "Не удалось остановить Docker Compose."
                        STATUS[5]="FAILED"
                    fi

                else

                    echo
                    echo "Ошибка в Docker Compose после изменения."
                    echo "Восстанавливать автоматически не будем."
                    echo
                    echo "Backup:"
                    ls -1t "${REMNANODE_COMPOSE}.bak."* 2>/dev/null | head -1 || true

                    STATUS[5]="FAILED"
                fi

            else

                echo
                echo "Docker не установлен."
                echo "Compose изменён, но контейнеры не перезапускались."

                STATUS[5]="OK"
            fi

        else

            echo
            echo "Не удалось добавить volume в compose."
            STATUS[5]="FAILED"
        fi

    else

        echo
        echo "Docker Compose RemnaNode не найден:"
        echo "$REMNANODE_COMPOSE"
        echo
        echo "Zapret.dat установлен отдельно."
        echo "После установки RemnaNode volume можно будет добавить повторным запуском пункта 5."

        STATUS[5]="OK"
    fi
}

# ============================================================
# 6. WARP
# ============================================================

install_warp() {

    local AUTO_TOS="${1:-no}"

    echo
    echo "============================================================"
    echo "6. Установка и настройка 2 WARP профилей"
    echo "============================================================"
    echo

    STATUS[6]="RUNNING"

    echo "Установка необходимых пакетов..."

    if ! apt install -y wireguard curl; then
        echo
        echo "Ошибка установки wireguard/curl."
        STATUS[6]="FAILED"
        return
    fi

    # --------------------------------------------------------
    # Download wgcf
    # --------------------------------------------------------

    local wgcf="/usr/local/bin/wgcf"

    echo
    echo "Скачивание wgcf..."

    if ! download_file "$WGCF_URL" "$wgcf"; then
        echo
        echo "Ошибка скачивания wgcf."
        STATUS[6]="FAILED"
        return
    fi

    chmod +x "$wgcf"

    echo
    echo "wgcf установлен:"
    "$wgcf" --version 2>/dev/null || true

    # --------------------------------------------------------
    # Temporary directories
    # --------------------------------------------------------

    local tmp1
    local tmp2

    tmp1=$(mktemp -d)
    tmp2=$(mktemp -d)

    trap 'rm -rf "$tmp1" "$tmp2"' RETURN

    # ========================================================
    # WARP 1
    # ========================================================

    echo
    echo "============================================================"
    echo "Создание WARP профиля 1"
    echo "============================================================"
    echo

    cd "$tmp1" || {
        echo "Не удалось перейти в $tmp1"
        STATUS[6]="FAILED"
        return
    }

    if [[ "$AUTO_TOS" == "yes" ]]; then

        echo "Автоматически принимаем WARP TOS..."

        if ! "$wgcf" register --accept-tos; then
            echo
            echo "Ошибка регистрации WARP 1."
            cd /root || true
            STATUS[6]="FAILED"
            return
        fi

    else

        echo "Регистрация WARP 1."
        echo "Если wgcf запросит подтверждение, ответьте вручную."
        echo

        if ! "$wgcf" register; then
            echo
            echo "Ошибка регистрации WARP 1."
            cd /root || true
            STATUS[6]="FAILED"
            return
        fi
    fi

    if ! "$wgcf" generate; then
        echo
        echo "Ошибка генерации WARP 1."
        cd /root || true
        STATUS[6]="FAILED"
        return
    fi

    if [[ ! -f wgcf-profile.conf ]]; then
        echo
        echo "wgcf-profile.conf для WARP 1 не найден."
        cd /root || true
        STATUS[6]="FAILED"
        return
    fi

    cp wgcf-profile.conf "$WARP1_CONF"

    # ========================================================
    # WARP 2
    # ========================================================

    echo
    echo "============================================================"
    echo "Создание WARP профиля 2"
    echo "============================================================"
    echo

    cd "$tmp2" || {
        echo "Не удалось перейти в $tmp2"
        cd /root || true
        STATUS[6]="FAILED"
        return
    }

    if [[ "$AUTO_TOS" == "yes" ]]; then

        echo "Автоматически принимаем WARP TOS..."

        if ! "$wgcf" register --accept-tos; then
            echo
            echo "Ошибка регистрации WARP 2."
            cd /root || true
            STATUS[6]="FAILED"
            return
        fi

    else

        echo "Регистрация WARP 2."
        echo "Если wgcf запросит подтверждение, ответьте вручную."
        echo

        if ! "$wgcf" register; then
            echo
            echo "Ошибка регистрации WARP 2."
            cd /root || true
            STATUS[6]="FAILED"
            return
        fi
    fi

    if ! "$wgcf" generate; then
        echo
        echo "Ошибка генерации WARP 2."
        cd /root || true
        STATUS[6]="FAILED"
        return
    fi

    if [[ ! -f wgcf-profile.conf ]]; then
        echo
        echo "wgcf-profile.conf для WARP 2 не найден."
        cd /root || true
        STATUS[6]="FAILED"
        return
    fi

    cp wgcf-profile.conf "$WARP2_CONF"

    cd /root || true

    # ========================================================
    # Configure WARP 1
    # ========================================================

    echo
    echo "Настройка WARP 1..."

    if [[ ! -f "$WARP1_CONF" ]]; then
        echo "Конфигурация WARP 1 не найдена."
        STATUS[6]="FAILED"
        return
    fi

    sed -i \
        -e '/^Address = /c\Address = 172.16.0.2/32' \
        -e '/^Address = /!b' \
        "$WARP1_CONF"

    sed -i '/^Address = /{n;}' "$WARP1_CONF" 2>/dev/null || true

    # Remove IPv6 Address if wgcf generated it
    sed -i -E '/^Address = .*:/d' "$WARP1_CONF"

    # Remove existing Table
    sed -i '/^Table = /d' "$WARP1_CONF"

    # Remove existing PersistentKeepalive
    sed -i '/^PersistentKeepalive = /d' "$WARP1_CONF"

    # Add Table after MTU if possible
    if grep -q '^MTU = ' "$WARP1_CONF"; then
        sed -i '/^MTU = /a Table = off' "$WARP1_CONF"
    else
        sed -i '/^\[Interface\]/a Table = off' "$WARP1_CONF"
    fi

    # Add PersistentKeepalive after endpoint
    if grep -q '^Endpoint = ' "$WARP1_CONF"; then
        sed -i '/^Endpoint = /a PersistentKeepalive = 25' "$WARP1_CONF"
    else
        sed -i '/^\[Peer\]/a PersistentKeepalive = 25' "$WARP1_CONF"
    fi

    # Force AllowedIPs
    sed -i '/^AllowedIPs = /d' "$WARP1_CONF"
    sed -i '/^PublicKey = /a AllowedIPs = 0.0.0.0/0' "$WARP1_CONF"

    # ========================================================
    # Configure WARP 2
    # ========================================================

    echo
    echo "Настройка WARP 2..."

    if [[ ! -f "$WARP2_CONF" ]]; then
        echo "Конфигурация WARP 2 не найдена."
        STATUS[6]="FAILED"
        return
    fi

    sed -i -E '/^Address = .*:/d' "$WARP2_CONF"

    sed -i '/^Address = /d' "$WARP2_CONF"
    sed -i '/^\[Interface\]/a Address = 172.16.0.3/32' "$WARP2_CONF"

    sed -i '/^Table = /d' "$WARP2_CONF"
    sed -i '/^PersistentKeepalive = /d' "$WARP2_CONF"

    if grep -q '^MTU = ' "$WARP2_CONF"; then
        sed -i '/^MTU = /a Table = off' "$WARP2_CONF"
    else
        sed -i '/^\[Interface\]/a Table = off' "$WARP2_CONF"
    fi

    if grep -q '^Endpoint = ' "$WARP2_CONF"; then
        sed -i '/^Endpoint = /a PersistentKeepalive = 25' "$WARP2_CONF"
    else
        sed -i '/^\[Peer\]/a PersistentKeepalive = 25' "$WARP2_CONF"
    fi

    sed -i '/^AllowedIPs = /d' "$WARP2_CONF"
    sed -i '/^PublicKey = /a AllowedIPs = 0.0.0.0/0' "$WARP2_CONF"

    chmod 600 "$WARP1_CONF" "$WARP2_CONF"

    # ========================================================
    # WARP startup script
    # ========================================================

    echo
    echo "Создание WARP startup script..."

    cat > "$WARP_START" <<'EOF'
#!/bin/bash

set -e

wg-quick down wgcf1 2>/dev/null || true
wg-quick down wgcf2 2>/dev/null || true

wg-quick up wgcf1
wg-quick up wgcf2
EOF

    chmod +x "$WARP_START"

    # ========================================================
    # systemd service
    # ========================================================

    echo
    echo "Создание systemd сервиса..."

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
    echo "Запуск WARP..."

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
            echo "Оба WARP интерфейса успешно запущены."
            STATUS[6]="OK"

        else

            echo
            echo "Один или оба WARP интерфейса не запустились."
            STATUS[6]="FAILED"
        fi

    else

        echo
        echo "Ошибка запуска warp.service."
        echo
        systemctl status warp.service --no-pager || true

        STATUS[6]="FAILED"
    fi
}

# ============================================================
# 7. UFW
# ============================================================

configure_ufw() {

    echo
    echo "============================================================"
    echo "7. Настройка UFW"
    echo "============================================================"
    echo

    STATUS[7]="RUNNING"

    echo "Установка UFW..."

    if ! apt install -y ufw; then
        echo
        echo "Ошибка установки UFW."
        STATUS[7]="FAILED"
        return
    fi

    echo
    echo "Добавление правил..."

    ufw allow OpenSSH
    ufw allow 443/tcp
    ufw allow 1433/tcp

    echo
    echo "Включение UFW..."

    if ufw --force enable; then

        echo
        echo "Текущий статус UFW:"
        echo

        ufw status verbose

        STATUS[7]="OK"

    else

        echo
        echo "Ошибка включения UFW."
        STATUS[7]="FAILED"
    fi
}

# ============================================================
# 8. Fail2ban
# ============================================================

install_fail2ban() {

    echo
    echo "============================================================"
    echo "8. Установка и настройка Fail2ban"
    echo "============================================================"
    echo

    STATUS[8]="RUNNING"

    echo "Установка Fail2ban..."

    if ! apt install -y fail2ban; then
        echo
        echo "Ошибка установки Fail2ban."
        STATUS[8]="FAILED"
        return
    fi

    echo
    echo "Создание $FAIL2BAN_JAIL..."

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
    echo "Перезапуск Fail2ban..."

    systemctl enable fail2ban

    if systemctl restart fail2ban; then

        sleep 2

        echo
        echo "Статус Fail2ban:"
        echo

        systemctl status fail2ban --no-pager || true

        echo
        echo "Jail:"
        echo

        fail2ban-client status || true

        echo
        echo "SSHD jail:"
        echo

        fail2ban-client status sshd 2>/dev/null || true

        if systemctl is-active --quiet fail2ban; then
            echo
            echo "Fail2ban успешно настроен."
            STATUS[8]="OK"
        else
            echo
            echo "Fail2ban не запущен."
            STATUS[8]="FAILED"
        fi

    else

        echo
        echo "Ошибка запуска Fail2ban."
        systemctl status fail2ban --no-pager || true

        STATUS[8]="FAILED"
    fi
}

# ============================================================
# 9. RemnaNode
# ============================================================

install_remnanode() {

    echo
    echo "============================================================"
    echo "9. Установка RemnaNode"
    echo "============================================================"
    echo

    STATUS[9]="RUNNING"

    local node_installer

    node_installer=$(mktemp)

    echo "Скачивание установщика RemnaNode..."
    echo

    if ! download_file "$REMNANODE_INSTALLER_URL" "$node_installer"; then
        echo
        echo "Ошибка скачивания установщика RemnaNode."
        rm -f "$node_installer"
        STATUS[9]="FAILED"
        return
    fi

    # --------------------------------------------------------
    # Fix CRLF
    # --------------------------------------------------------

    sed -i 's/\r$//' "$node_installer"

    chmod +x "$node_installer"

    echo
    echo "============================================================"
    echo "Сейчас будет запущен интерактивный установщик RemnaNode."
    echo
    echo "Bootstrap НЕ будет автоматически отвечать"
    echo "на его вопросы."
    echo "Все ответы вводятся вами."
    echo "============================================================"
    echo

    read -r -p "Нажмите Enter для запуска установщика RemnaNode..." _

    echo
    echo "Запуск RemnaNode installer..."
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
        STATUS[9]="OK"
    else
        STATUS[9]="FAILED"
    fi
}

# ============================================================
# 10. Selfsteal
# ============================================================

install_selfsteal() {

    echo
    echo "============================================================"
    echo "10. Установка Selfsteal"
    echo "============================================================"
    echo

    STATUS[10]="RUNNING"

    local selfsteal_installer

    selfsteal_installer=$(mktemp)

    echo "Скачивание установщика Selfsteal..."
    echo

    if ! download_file "$SELFSTEAL_INSTALLER_URL" "$selfsteal_installer"; then
        echo
        echo "Ошибка скачивания установщика Selfsteal."
        rm -f "$selfsteal_installer"
        STATUS[10]="FAILED"
        return
    fi

    # --------------------------------------------------------
    # Fix CRLF
    # --------------------------------------------------------

    sed -i 's/\r$//' "$selfsteal_installer"

    chmod +x "$selfsteal_installer"

    echo
    echo "============================================================"
    echo "Сейчас будет запущен интерактивный установщик Selfsteal."
    echo
    echo "Bootstrap НЕ будет автоматически отвечать"
    echo "на его вопросы."
    echo "Все ответы вводятся вами."
    echo "============================================================"
    echo

    read -r -p "Нажмите Enter для запуска установщика Selfsteal..." _

    echo
    echo "Запуск Selfsteal installer..."
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
        STATUS[10]="OK"
    else
        STATUS[10]="FAILED"
    fi
}

# ============================================================
# 11. Install 1-9
# ============================================================

install_1_to_9() {

    echo
    echo "============================================================"
    echo "11. Установка 1-9"
    echo "============================================================"
    echo

    STATUS[11]="RUNNING"

    echo "Будут последовательно выполнены пункты:"
    echo
    echo "  1. Отключить fwupd"
    echo "  2. apt update + показать доступные обновления"
    echo "  3. Отключить IPv6"
    echo "  4. Настроить BBR / Network sysctl"
    echo "  5. Установить Zapret.dat"
    echo "  6. Установить и настроить 2 WARP профиля"
    echo "  7. Настроить UFW"
    echo "  8. Установить и настроить Fail2ban"
    echo "  9. Установить RemnaNode"
    echo
    echo "Selfsteal (пункт 10) автоматически запущен НЕ будет."
    echo

    # ========================================================
    # Ask about Zapret
    # ========================================================

    local run_zapret="no"

    if ask_yes_no "Установить Zapret.dat?"; then
        run_zapret="yes"
    fi

    echo

    # ========================================================
    # Ask about WARP
    # ========================================================

    local run_warp="no"

    if ask_yes_no "Установить и настроить 2 WARP профиля?"; then
        run_warp="yes"
    fi

    echo

    # ========================================================
    # Ask about UFW
    # ========================================================

    local run_ufw="no"

    if ask_yes_no "Настроить UFW?"; then
        run_ufw="yes"
    fi

    echo
    echo "============================================================"
    echo "Начинаем установку 1-9"
    echo "============================================================"
    echo

    # ========================================================
    # 1
    # ========================================================

    disable_fwupd

    echo
    echo "------------------------------------------------------------"
    echo

    # ========================================================
    # 2
    # ========================================================

    apt_update_show_upgrades

    echo
    echo "------------------------------------------------------------"
    echo

    # ========================================================
    # 3
    # ========================================================

    disable_ipv6

    echo
    echo "------------------------------------------------------------"
    echo

    # ========================================================
    # 4
    # ========================================================

    configure_bbr

    echo
    echo "------------------------------------------------------------"
    echo

    # ========================================================
    # 5
    # ========================================================

    if [[ "$run_zapret" == "yes" ]]; then

        install_zapret

    else

        echo
        echo "5. Zapret.dat пропущен."
        STATUS[5]="SKIPPED"
    fi

    echo
    echo "------------------------------------------------------------"
    echo

    # ========================================================
    # 6
    # ========================================================

    if [[ "$run_warp" == "yes" ]]; then

        # Через пункт 11 TOS принимается автоматически.
        install_warp yes

    else

        echo
        echo "6. WARP пропущен."
        STATUS[6]="SKIPPED"
    fi

    echo
    echo "------------------------------------------------------------"
    echo

    # ========================================================
    # 7
    # ========================================================

    if [[ "$run_ufw" == "yes" ]]; then

        configure_ufw

    else

        echo
        echo "7. UFW пропущен."
        STATUS[7]="SKIPPED"
    fi

    echo
    echo "------------------------------------------------------------"
    echo

    # ========================================================
    # 8
    # ========================================================

    install_fail2ban

    echo
    echo "------------------------------------------------------------"
    echo

    # ========================================================
    # 9
    # ========================================================

    install_remnanode

    echo
    echo "------------------------------------------------------------"
    echo

    STATUS[11]="OK"

    echo
    echo "============================================================"
    echo "Пункт 11 завершён."
    echo "============================================================"
}

# ============================================================
# Status report
# ============================================================

show_status() {

    echo
    echo "============================================================"
    echo "Статус выполнения"
    echo "============================================================"
    echo

    printf "%-4s %-45s %s\n" "#" "Задача" "Статус"
    echo "----------------------------------------------------------------"

    printf "%-4s %-45s %s\n" \
        "1" \
        "Отключить fwupd" \
        "${STATUS[1]}"

    printf "%-4s %-45s %s\n" \
        "2" \
        "apt update + доступные обновления" \
        "${STATUS[2]}"

    printf "%-4s %-45s %s\n" \
        "3" \
        "Отключить IPv6" \
        "${STATUS[3]}"

    printf "%-4s %-45s %s\n" \
        "4" \
        "BBR / Network sysctl" \
        "${STATUS[4]}"

    printf "%-4s %-45s %s\n" \
        "5" \
        "Zapret.dat" \
        "${STATUS[5]}"

    printf "%-4s %-45s %s\n" \
        "6" \
        "2 WARP профиля" \
        "${STATUS[6]}"

    printf "%-4s %-45s %s\n" \
        "7" \
        "UFW" \
        "${STATUS[7]}"

    printf "%-4s %-45s %s\n" \
        "8" \
        "Fail2ban" \
        "${STATUS[8]}"

    printf "%-4s %-45s %s\n" \
        "9" \
        "RemnaNode" \
        "${STATUS[9]}"

    printf "%-4s %-45s %s\n" \
        "10" \
        "Selfsteal" \
        "${STATUS[10]}"

    printf "%-4s %-45s %s\n" \
        "11" \
        "Установка 1-9" \
        "${STATUS[11]}"

    echo
}

# ============================================================
# Menu
# ============================================================

while true; do

    clear 2>/dev/null || true

    echo
    echo "============================================================"
    echo "             RemnaWave VPS Bootstrap"
    echo "============================================================"
    echo
    echo "1.  Отключить fwupd"
    echo "2.  apt update + показать доступные обновления"
    echo "3.  Отключить IPv6"
    echo "4.  Настроить BBR / Network sysctl"
    echo "5.  Установить Zapret.dat"
    echo "6.  Установить и настроить 2 WARP профиля"
    echo "7.  Настроить UFW"
    echo "8.  Установить и настроить Fail2ban"
    echo "9.  Установить RemnaNode"
    echo "10. Установить Selfsteal"
    echo
    echo "11. Установить 1-9"
    echo
    echo "0.  Выход"
    echo
    echo "============================================================"
    echo

    read -r -p "Выберите пункт: " choice

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
            pause_menu
            ;;

        0)
            echo
            echo "Выход."
            echo
            exit 0
            ;;

        *)
            echo
            echo "Неверный пункт."
            sleep 1
            ;;
    esac

done
