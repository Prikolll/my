#!/usr/bin/env bash

set -o pipefail

# ============================================================
# Remnawave Bootstrap Installer
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
    echo "Запустите скрипт от root."
    exit 1
fi

# ============================================================
# Fix deleted working directory / getcwd problems
# ============================================================

cd /root || exit 1

# ============================================================
# Logging
# ============================================================

mkdir -p "$(dirname "$LOG_FILE")"

exec > >(tee -a "$LOG_FILE") 2>&1

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
    local prompt="$1"
    local answer

    while true; do
        read -r -p "$prompt [y/n]: " answer

        case "$answer" in
            y|Y|yes|YES|Yes)
                return 0
                ;;
            n|N|no|NO|No)
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
        curl -fL --retry 3 --connect-timeout 15 "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$destination" "$url"
    else
        echo "Ошибка: curl/wget не найден."
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

    systemctl stop fwupd.service 2>/dev/null || true
    systemctl disable fwupd.service 2>/dev/null || true
    systemctl unmask fwupd.service 2>/dev/null || true
    systemctl mask fwupd.service 2>/dev/null || true
    systemctl daemon-reload

    local enabled
    local active
    local target

    enabled="$(systemctl is-enabled fwupd.service 2>/dev/null || true)"
    active="$(systemctl is-active fwupd.service 2>/dev/null || true)"
    target="$(readlink -f /etc/systemd/system/fwupd.service 2>/dev/null || true)"

    echo "is-enabled: $enabled"
    echo "is-active : $active"
    echo "service   : $target"

    if [[ "$enabled" == "masked" && "$active" != "active" ]]; then
        STATUS[1]="OK"
        echo "fwupd успешно отключён и замаскирован."
        return 0
    fi

    echo "Стандартное mask не подтвердилось. Применяем fallback."

    rm -f /etc/systemd/system/fwupd.service
    ln -s /dev/null /etc/systemd/system/fwupd.service

    systemctl daemon-reload

    enabled="$(systemctl is-enabled fwupd.service 2>/dev/null || true)"
    active="$(systemctl is-active fwupd.service 2>/dev/null || true)"
    target="$(readlink -f /etc/systemd/system/fwupd.service 2>/dev/null || true)"

    echo "is-enabled: $enabled"
    echo "is-active : $active"
    echo "service   : $target"

    if [[ "$enabled" == "masked" && "$active" != "active" ]]; then
        STATUS[1]="OK"
        echo "fwupd успешно отключён."
        return 0
    fi

    STATUS[1]="FAILED"
    echo "Не удалось полностью отключить fwupd."
    return 1
}

# ============================================================
# 2. APT update + upgrades
# ============================================================

update_apt() {
    echo
    echo "============================================================"
    echo "2. Обновление APT"
    echo "============================================================"

    if ! apt update; then
        STATUS[2]="FAILED"
        return 1
    fi

    echo
    echo "Доступные обновления:"
    echo "------------------------------------------------------------"

    apt list --upgradable 2>/dev/null || true

    STATUS[2]="OK"

    echo
    echo "APT успешно обновлён."
}

# ============================================================
# 3. Disable IPv6
# ============================================================

disable_ipv6() {
    echo
    echo "============================================================"
    echo "3. Отключение IPv6"
    echo "============================================================"

    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    if ! sysctl --system; then
        STATUS[3]="FAILED"
        return 1
    fi

    echo
    echo "Проверка:"

    local all
    local default
    local lo

    all="$(sysctl -n net.ipv6.conf.all.disable_ipv6)"
    default="$(sysctl -n net.ipv6.conf.default.disable_ipv6)"
    lo="$(sysctl -n net.ipv6.conf.lo.disable_ipv6)"

    echo "all     = $all"
    echo "default = $default"
    echo "lo      = $lo"

    if [[ "$all" == "1" && "$default" == "1" && "$lo" == "1" ]]; then
        STATUS[3]="OK"
        echo "IPv6 успешно отключён."
        return 0
    fi

    STATUS[3]="FAILED"
    echo "Ошибка: IPv6 не удалось полностью отключить."
    return 1
}

# ============================================================
# 4. BBR / network sysctl
# ============================================================

configure_bbr() {
    echo
    echo "============================================================"
    echo "4. BBR / Network sysctl"
    echo "============================================================"

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
        STATUS[4]="FAILED"
        return 1
    fi

    echo
    echo "Проверка BBR:"
    sysctl net.ipv4.tcp_congestion_control

    echo
    echo "Проверка qdisc:"
    sysctl net.core.default_qdisc

    local bbr
    local qdisc

    bbr="$(sysctl -n net.ipv4.tcp_congestion_control)"
    qdisc="$(sysctl -n net.core.default_qdisc)"

    if [[ "$bbr" == "bbr" && "$qdisc" == "fq" ]]; then
        STATUS[4]="OK"
        echo "BBR + fq успешно настроены."
        return 0
    fi

    STATUS[4]="FAILED"
    echo "Ошибка проверки BBR/fq."
    return 1
}

# ============================================================
# 5. Zapret.dat
# ============================================================

add_zapret_mount() {
    local compose="$1"

    python3 - "$compose" <<'PY'
import sys
from pathlib import Path

compose = Path(sys.argv[1])
text = compose.read_text()

mount = "/opt/remnanode/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro"

if mount in text:
    print("Zapret mount уже существует.")
    sys.exit(0)

lines = text.splitlines()

service_index = None

for i, line in enumerate(lines):
    if line.strip() == "remnanode:" and not line.startswith(" "):
        service_index = i
        break

if service_index is None:
    for i, line in enumerate(lines):
        if line.startswith("  remnanode:"):
            service_index = i
            break

if service_index is None:
    print("Не найден service remnanode.")
    sys.exit(1)

service_indent = len(lines[service_index]) - len(lines[service_index].lstrip())

volumes_index = None

for i in range(service_index + 1, len(lines)):
    stripped = lines[i].strip()

    if stripped and len(lines[i]) - len(lines[i].lstrip()) <= service_indent:
        break

    if stripped == "volumes:":
        volumes_index = i
        break

if volumes_index is not None:
    insert_at = volumes_index + 1
    volume_indent = (
        len(lines[volumes_index])
        - len(lines[volumes_index].lstrip())
        + 2
    )

    lines.insert(
        insert_at,
        " " * volume_indent + "- " + mount
    )

else:
    insert_at = service_index + 1

    while insert_at < len(lines):
        stripped = lines[insert_at].strip()

        if stripped and (
            len(lines[insert_at])
            - len(lines[insert_at].lstrip())
            <= service_indent
        ):
            break

        insert_at += 1

    lines.insert(
        insert_at,
        " " * (service_indent + 2) + "volumes:"
    )

    lines.insert(
        insert_at + 1,
        " " * (service_indent + 4) + "- " + mount
    )

compose.write_text("\n".join(lines) + "\n")

print("Zapret mount добавлен.")
PY
}

install_zapret() {
    echo
    echo "============================================================"
    echo "5. Установка Zapret.dat"
    echo "============================================================"

    mkdir -p "$ZAPRET_DIR"

    if ! download_file "$ZAPRET_URL" "$ZAPRET_FILE"; then
        STATUS[5]="FAILED"
        return 1
    fi

    chmod 644 "$ZAPRET_FILE"

    echo
    echo "Zapret.dat установлен:"
    ls -lh "$ZAPRET_FILE"

    # Zapret сам может создать /opt/remnanode.
    # Поэтому проверяем именно docker-compose.yml.
    if [[ ! -f "$REMNANODE_COMPOSE" ]]; then
        echo
        echo "RemnaNode пока не установлен."
        echo "Файл Zapret.dat скачан, но Docker mount будет добавлен"
        echo "при наличии $REMNANODE_COMPOSE."

        STATUS[5]="OK"
        return 0
    fi

    local backup
    backup="${REMNANODE_COMPOSE}.backup.$(date +%Y%m%d-%H%M%S)"

    cp -a "$REMNANODE_COMPOSE" "$backup"

    echo
    echo "Резервная копия compose:"
    echo "$backup"

    if ! add_zapret_mount "$REMNANODE_COMPOSE"; then
        echo "Ошибка добавления mount."
        cp -a "$backup" "$REMNANODE_COMPOSE"
        STATUS[5]="FAILED"
        return 1
    fi

    echo
    echo "Проверка Docker Compose..."

    if ! docker compose -f "$REMNANODE_COMPOSE" config >/dev/null; then
        echo "Ошибка docker compose config."
        cp -a "$backup" "$REMNANODE_COMPOSE"
        STATUS[5]="FAILED"
        return 1
    fi

    echo "Compose корректен."

    echo
    echo "Перезапуск RemnaNode..."

    docker compose -f "$REMNANODE_COMPOSE" down
    docker compose -f "$REMNANODE_COMPOSE" up -d

    STATUS[5]="OK"

    echo
    echo "Zapret.dat успешно установлен и подключён."
}

# ============================================================
# 6. WARP x2
# ============================================================

prepare_wgcf_config() {
    local file="$1"
    local address="$2"

    sed -i '/^Address =/c\Address = '"$address" "$file"

    sed -i '/^Table =/d' "$file"

    sed -i '/^MTU =/a Table = off' "$file"

    sed -i '/^PersistentKeepalive =/d' "$file"

    sed -i \
        '/^Endpoint = engage.cloudflareclient.com:2408/a PersistentKeepalive = 25' \
        "$file"

    sed -i '/^Address =/s/,[^ ]*//g' "$file"

    sed -i '/^AllowedIPs =/c\AllowedIPs = 0.0.0.0/0' "$file"

    sed -i '/Endpoint = .*]:2408/d' "$file"
}

install_warp() {
    echo
    echo "============================================================"
    echo "6. Установка двух WARP профилей"
    echo "============================================================"

    export DEBIAN_FRONTEND=noninteractive

    if ! apt install -y wireguard curl; then
        STATUS[6]="FAILED"
        return 1
    fi

    local wgcf_bin="/usr/local/bin/wgcf"

    echo
    echo "Скачивание wgcf..."

    if ! download_file "$WGCF_URL" "$wgcf_bin"; then
        STATUS[6]="FAILED"
        return 1
    fi

    chmod +x "$wgcf_bin"

    local tmp1
    local tmp2

    tmp1="$(mktemp -d /tmp/wgcf1.XXXXXX)"
    tmp2="$(mktemp -d /tmp/wgcf2.XXXXXX)"

    echo
    echo "Регистрация WARP профиля 1..."

    if ! (
        cd "$tmp1" || exit 1
        wgcf register --accept-tos
        wgcf generate
    ); then
        rm -rf "$tmp1" "$tmp2"
        STATUS[6]="FAILED"
        return 1
    fi

    echo
    echo "Регистрация WARP профиля 2..."

    if ! (
        cd "$tmp2" || exit 1
        wgcf register --accept-tos
        wgcf generate
    ); then
        rm -rf "$tmp1" "$tmp2"
        STATUS[6]="FAILED"
        return 1
    fi

    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    cp "$tmp1/wgcf-profile.conf" "$WARP1_CONF"
    cp "$tmp2/wgcf-profile.conf" "$WARP2_CONF"

    prepare_wgcf_config "$WARP1_CONF" "172.16.0.2/32"
    prepare_wgcf_config "$WARP2_CONF" "172.16.0.3/32"

    chmod 600 "$WARP1_CONF" "$WARP2_CONF"

    rm -rf "$tmp1" "$tmp2"

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

    chmod +x "$WARP_START"

    # --------------------------------------------------------
    # systemd
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
    echo "Запуск WARP..."

    if ! systemctl restart warp.service; then
        STATUS[6]="FAILED"
        return 1
    fi

    sleep 2

    echo
    echo "WARP interfaces:"
    wg show

    if ip link show wgcf1 >/dev/null 2>&1 &&
       ip link show wgcf2 >/dev/null 2>&1; then

        STATUS[6]="OK"

        echo
        echo "Оба WARP профиля успешно запущены."

        return 0
    fi

    STATUS[6]="FAILED"

    echo "Ошибка: WARP интерфейсы не поднялись."

    return 1
}

# ============================================================
# 7. RemnaNode
# ============================================================

install_remnanode() {
    echo
    echo "============================================================"
    echo "7. Установка RemnaNode"
    echo "============================================================"

    echo
    echo "ВАЖНО:"
    echo "Установщик RemnaNode будет запущен ПОЛНОСТЬЮ"
    echo "ИНТЕРАКТИВНО."
    echo
    echo "Bootstrap НЕ будет отвечать на его вопросы."
    echo "Все y/n, секретные ключи и остальные ответы"
    echo "вводите самостоятельно."
    echo

    if [[ ! -e /dev/tty ]]; then
        echo "Ошибка: /dev/tty недоступен."
        STATUS[7]="FAILED"
        return 1
    fi

    read -r -p \
        "Нажмите Enter для запуска установщика RemnaNode..." \
        _

    local node_installer

    node_installer="$(mktemp /tmp/remnanode-installer.XXXXXX.sh)"

    if ! download_file \
        "$REMNANODE_INSTALLER_URL" \
        "$node_installer"; then

        rm -f "$node_installer"

        STATUS[7]="FAILED"

        return 1
    fi

    chmod +x "$node_installer"

    # Убираем CRLF, если файл имеет Windows окончания строк.
    sed -i 's/\r$//' "$node_installer"

    echo
    echo "============================================================"
    echo "Запуск интерактивного установщика RemnaNode"
    echo "============================================================"
    echo

    # ========================================================
    # КРИТИЧЕСКИ ВАЖНО:
    #
    # Установщик получает настоящий терминал.
    #
    # Никаких:
    #   printf "y"
    #   yes
    #   echo y
    #
    # Все ответы вводит пользователь вручную.
    # ========================================================

    bash "$node_installer" @ install \
        </dev/tty \
        >/dev/tty \
        2>/dev/tty

    local installer_rc=$?

    rm -f "$node_installer"

    echo

    if [[ "$installer_rc" -eq 0 ]]; then
        STATUS[7]="OK"

        echo "RemnaNode установщик завершился успешно."

        return 0
    fi

    STATUS[7]="FAILED"

    echo "RemnaNode установщик завершился с кодом: $installer_rc"

    return "$installer_rc"
}

# ============================================================
# 8. Selfsteal
# ============================================================

install_selfsteal() {
    echo
    echo "============================================================"
    echo "8. Установка Selfsteal"
    echo "============================================================"

    echo
    echo "ВАЖНО:"
    echo "Установщик Selfsteal будет запущен ПОЛНОСТЬЮ"
    echo "ИНТЕРАКТИВНО."
    echo
    echo "Bootstrap НЕ будет отвечать на его вопросы."
    echo "Все ответы вводите самостоятельно."
    echo

    if [[ ! -e /dev/tty ]]; then
        echo "Ошибка: /dev/tty недоступен."
        STATUS[8]="FAILED"
        return 1
    fi

    read -r -p \
        "Нажмите Enter для запуска установщика Selfsteal..." \
        _

    local selfsteal_installer

    selfsteal_installer="$(mktemp /tmp/selfsteal-installer.XXXXXX.sh)"

    if ! download_file \
        "$SELFSTEAL_INSTALLER_URL" \
        "$selfsteal_installer"; then

        rm -f "$selfsteal_installer"

        STATUS[8]="FAILED"

        return 1
    fi

    chmod +x "$selfsteal_installer"

    # Убираем CRLF.
    sed -i 's/\r$//' "$selfsteal_installer"

    echo
    echo "============================================================"
    echo "Запуск интерактивного установщика Selfsteal"
    echo "============================================================"
    echo

    # Полностью интерактивный запуск через настоящий терминал.
    bash "$selfsteal_installer" @ install \
        </dev/tty \
        >/dev/tty \
        2>/dev/tty

    local installer_rc=$?

    rm -f "$selfsteal_installer"

    echo

    if [[ "$installer_rc" -eq 0 ]]; then
        STATUS[8]="OK"

        echo "Selfsteal установщик завершился успешно."

        return 0
    fi

    STATUS[8]="FAILED"

    echo "Selfsteal установщик завершился с кодом: $installer_rc"

    return "$installer_rc"
}

# ============================================================
# 9. UFW
# ============================================================

configure_ufw() {
    echo
    echo "============================================================"
    echo "9. Настройка UFW"
    echo "============================================================"

    export DEBIAN_FRONTEND=noninteractive

    if ! apt install -y ufw; then
        STATUS[9]="FAILED"
        return 1
    fi

    echo
    echo "Применение правил:"

    ufw allow OpenSSH
    ufw allow 443/tcp
    ufw allow 1433/tcp

    if ! ufw --force enable; then
        STATUS[9]="FAILED"
        return 1
    fi

    echo
    ufw status verbose

    STATUS[9]="OK"

    echo
    echo "UFW успешно настроен."
}

# ============================================================
# 10. Fail2ban
# ============================================================

configure_fail2ban() {
    echo
    echo "============================================================"
    echo "10. Настройка Fail2ban"
    echo "============================================================"

    export DEBIAN_FRONTEND=noninteractive

    if ! apt install -y fail2ban; then
        STATUS[10]="FAILED"
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
        STATUS[10]="FAILED"
        return 1
    fi

    sleep 2

    echo
    echo "Статус Fail2ban:"
    systemctl --no-pager --full status fail2ban || true

    echo
    echo "Jail:"
    fail2ban-client status sshd 2>/dev/null || true

    if systemctl is-active --quiet fail2ban; then
        STATUS[10]="OK"

        echo
        echo "Fail2ban успешно настроен."

        return 0
    fi

    STATUS[10]="FAILED"

    echo "Fail2ban не запущен."

    return 1
}

# ============================================================
# Status report
# ============================================================

show_status() {
    echo
    echo "============================================================"
    echo "СТАТУС УСТАНОВКИ"
    echo "============================================================"

    local name

    for i in {1..10}; do

        case "$i" in
            1)
                name="Отключение fwupd"
                ;;
            2)
                name="APT update"
                ;;
            3)
                name="Отключение IPv6"
                ;;
            4)
                name="BBR / Network sysctl"
                ;;
            5)
                name="Zapret.dat"
                ;;
            6)
                name="WARP x2"
                ;;
            7)
                name="RemnaNode"
                ;;
            8)
                name="Selfsteal"
                ;;
            9)
                name="UFW"
                ;;
            10)
                name="Fail2ban"
                ;;
        esac

        printf \
            "%2s. %-28s : %s\n" \
            "$i" \
            "$name" \
            "${STATUS[$i]}"
    done

    echo "============================================================"
}

# ============================================================
# 11. Install everything
# ============================================================

install_everything() {
    echo
    echo "============================================================"
    echo "11. Установка всего"
    echo "============================================================"

    echo
    echo "Будут выполнены пункты 1–10."
    echo

    local install_zapret_choice="n"
    local install_warp_choice="n"
    local install_selfsteal_choice="n"

    if ask_yes_no "Установить Zapret.dat?"; then
        install_zapret_choice="y"
    fi

    if ask_yes_no "Установить два WARP профиля?"; then
        install_warp_choice="y"
    fi

    if ask_yes_no "Установить Selfsteal?"; then
        install_selfsteal_choice="y"
    fi

    echo
    echo "============================================================"
    echo "Начинаем установку"
    echo "============================================================"

    echo
    echo ">>> 1. fwupd"
    disable_fwupd || true

    echo
    echo ">>> 2. APT"
    update_apt || true

    echo
    echo ">>> 3. IPv6"
    disable_ipv6 || true

    echo
    echo ">>> 4. BBR"
    configure_bbr || true

    if [[ "$install_zapret_choice" == "y" ]]; then

        echo
        echo ">>> 5. Zapret.dat"

        install_zapret || true

    else

        STATUS[5]="SKIPPED"

        echo
        echo ">>> 5. Zapret.dat — пропущено"

    fi

    if [[ "$install_warp_choice" == "y" ]]; then

        echo
        echo ">>> 6. WARP"

        install_warp || true

    else

        STATUS[6]="SKIPPED"

        echo
        echo ">>> 6. WARP — пропущено"

    fi

    echo
    echo ">>> 7. RemnaNode"

    install_remnanode || true

    if [[ "$install_selfsteal_choice" == "y" ]]; then

        echo
        echo ">>> 8. Selfsteal"

        install_selfsteal || true

    else

        STATUS[8]="SKIPPED"

        echo
        echo ">>> 8. Selfsteal — пропущено"

    fi

    echo
    echo ">>> 9. UFW"

    configure_ufw || true

    echo
    echo ">>> 10. Fail2ban"

    configure_fail2ban || true

    show_status

    echo
    echo "Установка всего завершена."
}

# ============================================================
# Menu
# ============================================================

show_menu() {
    clear

    echo "============================================================"
    echo "        REMNAWAVE VPS BOOTSTRAP INSTALLER"
    echo "============================================================"
    echo
    echo " 1. Отключить fwupd"
    echo " 2. apt update + показать доступные обновления"
    echo " 3. Отключить IPv6"
    echo " 4. Настроить BBR / Network sysctl"
    echo " 5. Установить Zapret.dat"
    echo " 6. Установить и настроить 2 WARP профиля"
    echo " 7. Установить RemnaNode"
    echo " 8. Установить Selfsteal"
    echo " 9. Настроить UFW"
    echo "10. Установить и настроить Fail2ban"
    echo "11. Установить ВСЁ"
    echo
    echo " 0. Выход"
    echo
    echo "============================================================"
    echo "Лог: $LOG_FILE"
    echo "============================================================"
    echo
}

# ============================================================
# Main loop
# ============================================================

while true; do

    show_menu

    read -r -p "Выберите пункт: " choice

    case "$choice" in

        1)
            disable_fwupd || true
            pause_menu
            ;;

        2)
            update_apt || true
            pause_menu
            ;;

        3)
            disable_ipv6 || true
            pause_menu
            ;;

        4)
            configure_bbr || true
            pause_menu
            ;;

        5)
            install_zapret || true
            pause_menu
            ;;

        6)
            install_warp || true
            pause_menu
            ;;

        7)
            install_remnanode || true
            pause_menu
            ;;

        8)
            install_selfsteal || true
            pause_menu
            ;;

        9)
            configure_ufw || true
            pause_menu
            ;;

        10)
            configure_fail2ban || true
            pause_menu
            ;;

        11)
            install_everything
            pause_menu
            ;;

        0)
            echo
            echo "Выход."
            exit 0
            ;;

        *)
            echo
            echo "Неверный пункт."
            sleep 1
            ;;

    esac

done
