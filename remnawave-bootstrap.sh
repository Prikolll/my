#!/bin/bash

# ============================================================
# Remnawave VPS Bootstrap Installer
# Ubuntu / Debian
# ============================================================

set -u

LOG_FILE="/var/log/remnawave-bootstrap.log"

REMNANODE_DIR="/opt/remnanode"
REMNANODE_COMPOSE="/opt/remnanode/docker-compose.yml"

NODE_INSTALLER_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh"
SELFSTEAL_INSTALLER_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh"
ZAPRET_URL="https://github.com/kutovoys/ru_gov_zapret/releases/latest/download/zapret.dat"
WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.3.0/wgcf_2.3.0_linux_amd64"

ZAPRET_FILE="/opt/remnanode/xray/share/zapret.dat"

WARP1_CONF="/etc/wireguard/wgcf1.conf"
WARP2_CONF="/etc/wireguard/wgcf2.conf"
WARP_START="/usr/local/bin/warp_start.sh"
WARP_SERVICE="/etc/systemd/system/warp.service"

INSTALL_ZAPRET=false

declare -A STATUS

# ============================================================
# LOGGING
# ============================================================

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

# ============================================================
# ROOT CHECK
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo
    echo "Ошибка: скрипт необходимо запускать от root."
    echo
    exit 1
fi

# ============================================================
# HELPERS
# ============================================================

pause_menu() {
    echo
    read -r -p "Нажмите Enter для продолжения..." _
}

ask_yes_no() {
    local prompt="$1"
    local answer

    while true; do
        read -r -p "$prompt [y/n]: " answer

        case "$answer" in
            y|Y|д|Д)
                return 0
                ;;
            n|N|н|Н)
                return 1
                ;;
            *)
                echo "Введите y или n."
                ;;
        esac
    done
}

status_ok() {
    STATUS["$1"]="OK"
}

status_failed() {
    STATUS["$1"]="FAILED"
}

status_skipped() {
    STATUS["$1"]="SKIPPED"
}

status_not_run() {
    STATUS["$1"]="NOT RUN"
}

print_status() {
    echo
    echo "============================================================"
    echo "                    СТАТУС УСТАНОВКИ"
    echo "============================================================"

    local items=(
        "1. fwupd"
        "2. apt update"
        "3. IPv6"
        "4. BBR / network"
        "5. Zapret.dat"
        "6. WARP"
        "7. Remnawave Node"
        "8. Selfsteal"
        "9. UFW"
        "10. Fail2ban"
    )

    local key

    for item in "${items[@]}"; do
        key="${item%%.*}"

        printf "%-25s : %s\n" \
            "$item" \
            "${STATUS[$key]:-NOT RUN}"
    done

    echo "============================================================"
    echo
}

run_cmd() {
    "$@"
    return $?
}

# ============================================================
# 1. FWUPD
# ============================================================

install_fwupd() {

    echo
    echo "============================================================"
    echo "1. ОТКЛЮЧЕНИЕ FWUPD"
    echo "============================================================"

    echo "Останавливаем fwupd..."
    systemctl stop fwupd.service 2>/dev/null || true

    echo "Отключаем автозапуск..."
    systemctl disable fwupd.service 2>/dev/null || true

    echo "Создаём persistent mask..."

    local mask_ok=false

    if systemctl mask fwupd.service; then
        mask_ok=true
    else
        echo "Обычный systemctl mask завершился с ошибкой."

        # Иногда в /etc/systemd/system уже существует некорректный
        # файл/ссылка fwupd.service.
        if [[ -e /etc/systemd/system/fwupd.service ||
              -L /etc/systemd/system/fwupd.service ]]; then

            echo "Обнаружен конфликтующий /etc/systemd/system/fwupd.service."

            rm -f /etc/systemd/system/fwupd.service

            ln -s /dev/null /etc/systemd/system/fwupd.service
            systemctl daemon-reload
        fi
    fi

    systemctl daemon-reload

    local mask_target
    mask_target="$(readlink -f /etc/systemd/system/fwupd.service 2>/dev/null || true)"

    if [[ "$mask_target" == "/dev/null" ]]; then
        mask_ok=true
    fi

    if systemctl is-enabled fwupd.service 2>/dev/null | grep -q '^masked$'; then
        mask_ok=true
    fi

    echo
    echo "Проверка:"
    systemctl is-enabled fwupd.service 2>/dev/null || true
    systemctl is-active fwupd.service 2>/dev/null || true
    echo "Mask target: ${mask_target:-не найден}"

    if [[ "$mask_ok" == true ]]; then
        echo
        echo "fwupd успешно отключён и замаскирован."
        status_ok "1"
        return 0
    fi

    echo
    echo "ОШИБКА: не удалось подтвердить mask fwupd."
    status_failed "1"
    return 1
}

# ============================================================
# 2. APT UPDATE
# ============================================================

update_system() {

    echo
    echo "============================================================"
    echo "2. ОБНОВЛЕНИЕ СПИСКА ПАКЕТОВ"
    echo "============================================================"

    if apt update; then

        echo
        echo "Доступные обновления:"
        apt list --upgradable || true

        status_ok "2"
        return 0
    fi

    echo
    echo "Ошибка apt update."
    status_failed "2"
    return 1
}

# ============================================================
# 3. DISABLE IPV6
# ============================================================

disable_ipv6() {

    echo
    echo "============================================================"
    echo "3. ОТКЛЮЧЕНИЕ IPV6"
    echo "============================================================"

    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    echo "Применяем sysctl..."
    sysctl --system

    local ipv6_all
    ipv6_all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)"

    if [[ "$ipv6_all" == "1" ]]; then
        echo
        echo "IPv6 отключён."
        status_ok "3"
        return 0
    fi

    echo
    echo "Не удалось подтвердить отключение IPv6."
    status_failed "3"
    return 1
}

# ============================================================
# 4. BBR / NETWORK SYSCTL
# ============================================================

configure_bbr() {

    echo
    echo "============================================================"
    echo "4. BBR / NETWORK"
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

    echo "Применяем настройки..."
    sysctl --system

    echo
    echo "Проверка BBR:"
    echo "Congestion control:"
    sysctl net.ipv4.tcp_congestion_control

    echo
    echo "Default qdisc:"
    sysctl net.core.default_qdisc

    local cc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"

    if [[ "$cc" == "bbr" ]]; then
        echo
        echo "BBR активен."
        status_ok "4"
        return 0
    fi

    echo
    echo "Внимание: BBR не активен."
    status_failed "4"
    return 1
}

# ============================================================
# ZAPRET - MODIFY DOCKER COMPOSE
# ============================================================

configure_remnanode_zapret() {

    if [[ ! -f "$REMNANODE_COMPOSE" ]]; then
        echo
        echo "Compose Node не найден:"
        echo "$REMNANODE_COMPOSE"
        return 1
    fi

    echo
    echo "Настраиваем Zapret.dat в Docker Compose..."

    if grep -Fq \
        "/opt/remnanode/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro" \
        "$REMNANODE_COMPOSE"; then

        echo "Mount Zapret.dat уже присутствует."
        return 0
    fi

    local backup

    backup="${REMNANODE_COMPOSE}.bak.$(date +%Y%m%d_%H%M%S)"

    cp -a "$REMNANODE_COMPOSE" "$backup"

    echo "Backup:"
    echo "$backup"

    python3 - "$REMNANODE_COMPOSE" <<'PY'
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

mount = "      - /opt/remnanode/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro\n"

# Найти service remnanode
service_start = None

for i, line in enumerate(lines):
    if line.rstrip("\n") == "  remnanode:":
        service_start = i
        break

if service_start is None:
    raise SystemExit("Не найден service 'remnanode:' в docker-compose.yml")

# Найти конец service remnanode
service_end = len(lines)

for i in range(service_start + 1, len(lines)):
    if lines[i].startswith("  ") and not lines[i].startswith("    "):
        service_end = i
        break

# Проверка внутри service
service_lines = lines[service_start:service_end]

# Если volumes существует
volumes_index = None

for i, line in enumerate(service_lines):
    if line.rstrip("\n") == "    volumes:":
        volumes_index = i
        break

if volumes_index is not None:
    insert_at = service_start + volumes_index + 1

    # Ищем конец volumes
    for j in range(volumes_index + 1, len(service_lines)):
        line = service_lines[j]

        if line.startswith("    ") and not line.startswith("      "):
            insert_at = service_start + j
            break

        if not line.startswith("      - "):
            insert_at = service_start + j
            break
    else:
        insert_at = service_end

    lines.insert(insert_at, mount)

else:
    # Создаём volumes перед следующим service
    insert_at = service_end

    block = [
        "    volumes:\n",
        mount
    ]

    lines[insert_at:insert_at] = block

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)

print("Compose изменён.")
PY

    echo
    echo "Проверяем Docker Compose..."

    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker пока не установлен."
        echo "Mount сохранён в Compose; проверка будет выполнена после установки Node."
        return 0
    fi

    if (
        cd "$REMNANODE_DIR" &&
        docker compose config >/dev/null
    ); then

        echo "Docker Compose configuration OK."
        return 0
    fi

    echo
    echo "ОШИБКА: docker compose config не прошёл."
    echo "Восстанавливаем backup..."

    cp -a "$backup" "$REMNANODE_COMPOSE"

    return 1
}

# ============================================================
# 5. ZAPRET
# ============================================================

install_zapret() {

    echo
    echo "============================================================"
    echo "5. ZAPRET.DAT"
    echo "============================================================"

    mkdir -p /opt/remnanode/xray/share

    echo "Скачиваем Zapret.dat..."

    if ! curl -fL --retry 3 \
        "$ZAPRET_URL" \
        -o "$ZAPRET_FILE"; then

        echo
        echo "Ошибка загрузки Zapret.dat."
        status_failed "5"
        return 1
    fi

    if [[ ! -s "$ZAPRET_FILE" ]]; then
        echo
        echo "Zapret.dat пустой."
        status_failed "5"
        return 1
    fi

    chmod 644 "$ZAPRET_FILE"

    echo
    echo "Zapret.dat установлен:"
    ls -lh "$ZAPRET_FILE"

    INSTALL_ZAPRET=true

    # Если Node уже установлен — сразу модифицируем Compose
    if [[ -f "$REMNANODE_COMPOSE" ]]; then

        echo
        echo "Remnawave Node уже установлен."
        echo "Добавляем mount Zapret.dat..."

        if configure_remnanode_zapret; then

            echo
            echo "Перезапускаем Remnawave Node..."

            (
                cd "$REMNANODE_DIR" &&
                docker compose down &&
                docker compose up -d
            )

            if [[ $? -eq 0 ]]; then
                echo
                echo "Node перезапущен."

                (
                    cd "$REMNANODE_DIR" &&
                    docker compose ps
                )

                status_ok "5"
                return 0
            fi
        fi

        echo
        echo "Не удалось настроить/перезапустить Node."
        status_failed "5"
        return 1
    fi

    echo
    echo "Node пока не установлен."
    echo "Zapret.dat сохранён."
    echo "После установки Node mount будет добавлен автоматически."

    status_ok "5"
    return 0
}

# ============================================================
# WARP CONFIG MODIFICATION
# ============================================================

configure_warp_conf() {

    local conf="$1"
    local address="$2"

    if [[ ! -f "$conf" ]]; then
        echo "Файл не найден: $conf"
        return 1
    fi

    python3 - "$conf" "$address" <<'PY'
import sys
import re

path = sys.argv[1]
address = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

# ------------------------------------------------------------
# Address
# ------------------------------------------------------------

new_lines = []
address_added = False

for line in lines:

    if line.strip().startswith("Address ="):
        continue

    if line.strip() == "[Interface]":
        new_lines.append(line)
        new_lines.append(f"Address = {address}\n")
        address_added = True
        continue

    new_lines.append(line)

lines = new_lines

# ------------------------------------------------------------
# AllowedIPs — удалить IPv6, оставить IPv4
# ------------------------------------------------------------

new_lines = []

for line in lines:

    if line.strip().startswith("AllowedIPs ="):

        value = line.split("=", 1)[1].strip()
        entries = [x.strip() for x in value.split(",")]

        ipv4_entries = []

        for entry in entries:
            if ":" not in entry:
                ipv4_entries.append(entry)

        line = "AllowedIPs = " + ", ".join(ipv4_entries) + "\n"

    new_lines.append(line)

lines = new_lines

# ------------------------------------------------------------
# Удалить IPv6 Endpoint
# ------------------------------------------------------------

new_lines = []

for line in lines:

    stripped = line.strip()

    if stripped.startswith("Endpoint = ["):
        continue

    new_lines.append(line)

lines = new_lines

# ------------------------------------------------------------
# Table = off
# ------------------------------------------------------------

new_lines = []

for line in lines:

    if line.strip().startswith("Table ="):
        continue

    new_lines.append(line)

lines = new_lines

mtu_index = None

for i, line in enumerate(lines):

    if line.strip().startswith("MTU ="):
        mtu_index = i
        break

if mtu_index is None:
    raise SystemExit("Не найден MTU в WireGuard config")

lines.insert(mtu_index + 1, "Table = off\n")

# ------------------------------------------------------------
# PersistentKeepalive = 25 после Endpoint
# ------------------------------------------------------------

new_lines = []
endpoint_found = False

for line in lines:

    if line.strip().startswith("PersistentKeepalive ="):
        continue

    new_lines.append(line)

    if line.strip().startswith("Endpoint = engage.cloudflareclient.com:2408"):
        new_lines.append("PersistentKeepalive = 25\n")
        endpoint_found = True

if not endpoint_found:
    raise SystemExit("Не найден Endpoint = engage.cloudflareclient.com:2408")

lines = new_lines

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)

print(f"Настроен {path}")
PY

    chmod 600 "$conf"

    echo
    echo "Проверяем:"
    grep -E \
        '^(Address|MTU|Table|AllowedIPs|Endpoint|PersistentKeepalive)' \
        "$conf" || true
}

# ============================================================
# 6. WARP
# ============================================================

install_warp() {

    echo
    echo "============================================================"
    echo "6. WARP"
    echo "============================================================"

    echo "Устанавливаем WireGuard..."

    if ! apt install -y wireguard; then
        echo
        echo "Ошибка установки WireGuard."
        status_failed "6"
        return 1
    fi

    echo
    echo "Скачиваем wgcf 2.3.0..."

    local tmpdir
    tmpdir="$(mktemp -d)"

    if ! curl -fL --retry 3 \
        "$WGCF_URL" \
        -o "$tmpdir/wgcf"; then

        rm -rf "$tmpdir"

        echo
        echo "Ошибка загрузки wgcf."
        status_failed "6"
        return 1
    fi

    chmod +x "$tmpdir/wgcf"
    install -m 755 "$tmpdir/wgcf" /usr/local/bin/wgcf

    rm -rf "$tmpdir"

    echo
    echo "wgcf:"
    /usr/local/bin/wgcf --version || true

    # ========================================================
    # WARP 1
    # ========================================================

    echo
    echo "Создаём WARP профиль #1..."

    local warp1_tmp
    warp1_tmp="$(mktemp -d)"

    cd "$warp1_tmp" || return 1

    rm -f wgcf-account.toml wgcf-profile.conf

    if ! wgcf register; then
        rm -rf "$warp1_tmp"
        echo "Ошибка регистрации WARP #1."
        status_failed "6"
        return 1
    fi

    if ! wgcf generate; then
        rm -rf "$warp1_tmp"
        echo "Ошибка генерации WARP #1."
        status_failed "6"
        return 1
    fi

    install -m 600 wgcf-profile.conf "$WARP1_CONF"

    rm -rf "$warp1_tmp"

    configure_warp_conf "$WARP1_CONF" "172.16.0.2/32" || {
        status_failed "6"
        return 1
    }

    # ========================================================
    # WARP 2
    # ========================================================

    echo
    echo "Создаём WARP профиль #2..."

    local warp2_tmp
    warp2_tmp="$(mktemp -d)"

    cd "$warp2_tmp" || return 1

    rm -f wgcf-account.toml wgcf-profile.conf

    if ! wgcf register; then
        rm -rf "$warp2_tmp"
        echo "Ошибка регистрации WARP #2."
        status_failed "6"
        return 1
    fi

    if ! wgcf generate; then
        rm -rf "$warp2_tmp"
        echo "Ошибка генерации WARP #2."
        status_failed "6"
        return 1
    fi

    install -m 600 wgcf-profile.conf "$WARP2_CONF"

    rm -rf "$warp2_tmp"

    configure_warp_conf "$WARP2_CONF" "172.16.0.3/32" || {
        status_failed "6"
        return 1
    }

    # ========================================================
    # START SCRIPT
    # ========================================================

    echo
    echo "Создаём WARP startup script..."

    cat > "$WARP_START" <<'EOF'
#!/bin/bash

set -e

wg-quick down wgcf1 2>/dev/null || true
wg-quick down wgcf2 2>/dev/null || true

wg-quick up wgcf1
wg-quick up wgcf2
EOF

    chmod 755 "$WARP_START"

    # ========================================================
    # SYSTEMD
    # ========================================================

    echo
    echo "Создаём systemd service..."

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
        echo
        echo "Ошибка запуска WARP."
        systemctl status warp.service --no-pager || true
        status_failed "6"
        return 1
    fi

    echo
    echo "wg show:"
    wg show

    echo
    echo "Проверяем интерфейсы..."

    if ip link show wgcf1 >/dev/null 2>&1 &&
       ip link show wgcf2 >/dev/null 2>&1; then

        echo
        echo "Оба WARP интерфейса работают."

        status_ok "6"
        return 0
    fi

    echo
    echo "Не удалось подтвердить запуск обоих WARP интерфейсов."
    status_failed "6"
    return 1
}

# ============================================================
# 7. REMNAWAVE NODE
# ============================================================

install_remnanode() {

    echo
    echo "============================================================"
    echo "7. REMNAWAVE NODE"
    echo "============================================================"

    local node_installer
    node_installer="$(mktemp /tmp/remnanode-installer.XXXXXX.sh)"

    echo "Скачиваем installer..."

    if ! curl -fL --retry 3 \
        "$NODE_INSTALLER_URL" \
        -o "$node_installer"; then

        rm -f "$node_installer"

        echo
        echo "Ошибка загрузки remnanode.sh."
        status_failed "7"
        return 1
    fi

    chmod +x "$node_installer"

    echo
    echo "Запускаем установщик Remnawave Node."
    echo
    echo "ВАЖНО:"
    echo "Если установщик завис или работает бесконечно,"
    echo "нажмите Ctrl+C."
    echo
    echo "Ctrl+C прервет только установщик Node,"
    echo "после чего этот bootstrap-скрипт продолжит работу."
    echo

    local installer_exit=0
    local node_interrupted=0

    # SIGINT ловится родительским скриптом.
    # Foreground installer также получает Ctrl+C.
    trap 'node_interrupted=1; echo; echo "Получен Ctrl+C — останавливаем установщик Node..."' INT

    bash "$node_installer" @ install
    installer_exit=$?

    trap - INT

    rm -f "$node_installer"

    echo
    echo "Код завершения установщика: $installer_exit"

    # ========================================================
    # Ctrl+C
    # ========================================================

    if [[ "$node_interrupted" -eq 1 || "$installer_exit" -eq 130 ]]; then

        echo
        echo "Установщик Remnawave Node был прерван пользователем."

        if [[ -f "$REMNANODE_COMPOSE" ]]; then

            echo
            echo "Docker Compose найден:"
            echo "$REMNANODE_COMPOSE"

            if ask_yes_no "Продолжить настройку Node"; then
                :
            else
                status_skipped "7"
                return 0
            fi

        else

            echo
            echo "Docker Compose Node не найден."

            status_failed "7"
            return 1
        fi

    elif [[ "$installer_exit" -ne 0 ]]; then

        echo
        echo "Установщик Node завершился с ошибкой."

        if [[ ! -f "$REMNANODE_COMPOSE" ]]; then
            status_failed "7"
            return 1
        fi

        echo
        echo "Однако Docker Compose найден."
        echo "Продолжаем настройку существующей установки."

    fi

    # ========================================================
    # Проверка Compose
    # ========================================================

    if [[ ! -f "$REMNANODE_COMPOSE" ]]; then

        echo
        echo "Docker Compose не найден:"
        echo "$REMNANODE_COMPOSE"

        status_failed "7"
        return 1
    fi

    echo
    echo "Проверяем Docker Compose..."

    if ! (
        cd "$REMNANODE_DIR" &&
        docker compose config >/dev/null
    ); then

        echo
        echo "Ошибка в Docker Compose."

        status_failed "7"
        return 1
    fi

    echo "Docker Compose configuration OK."

    # ========================================================
    # ZAPRET
    # ========================================================

    if [[ "$INSTALL_ZAPRET" == true ]]; then

        echo
        echo "Добавляем Zapret.dat в Node..."

        if ! configure_remnanode_zapret; then
            echo
            echo "Не удалось добавить Zapret.dat."
            status_failed "7"
            return 1
        fi

        echo
        echo "Перезапускаем Node..."

        if ! (
            cd "$REMNANODE_DIR" &&
            docker compose down &&
            docker compose up -d
        ); then

            echo
            echo "Ошибка перезапуска Node."
            status_failed "7"
            return 1
        fi
    fi

    echo
    echo "Статус Node:"

    (
        cd "$REMNANODE_DIR" &&
        docker compose ps
    ) || true

    status_ok "7"
    return 0
}

# ============================================================
# 8. SELFSTEAL
# ============================================================

install_selfsteal() {

    echo
    echo "============================================================"
    echo "8. SELFSTEAL"
    echo "============================================================"

    local selfsteal_installer

    selfsteal_installer="$(mktemp /tmp/selfsteal-installer.XXXXXX.sh)"

    echo "Скачиваем Selfsteal installer..."

    if ! curl -fL --retry 3 \
        "$SELFSTEAL_INSTALLER_URL" \
        -o "$selfsteal_installer"; then

        rm -f "$selfsteal_installer"

        echo
        echo "Ошибка загрузки selfsteal.sh."
        status_failed "8"
        return 1
    fi

    chmod +x "$selfsteal_installer"

    echo
    echo "Запускаем Selfsteal..."

    bash "$selfsteal_installer" @ install
    local result=$?

    rm -f "$selfsteal_installer"

    if [[ "$result" -eq 0 ]]; then
        echo
        echo "Selfsteal установлен."
        status_ok "8"
        return 0
    fi

    echo
    echo "Selfsteal завершился с ошибкой. Код: $result"
    status_failed "8"
    return 1
}

# ============================================================
# 9. UFW
# ============================================================

configure_ufw() {

    echo
    echo "============================================================"
    echo "9. UFW"
    echo "============================================================"

    echo "Устанавливаем UFW..."

    if ! apt install -y ufw; then
        echo
        echo "Ошибка установки UFW."
        status_failed "9"
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
        echo
        echo "Ошибка включения UFW."
        status_failed "9"
        return 1
    fi

    echo
    echo "Статус UFW:"
    ufw status verbose

    status_ok "9"
    return 0
}

# ============================================================
# 10. FAIL2BAN
# ============================================================

configure_fail2ban() {

    echo
    echo "============================================================"
    echo "10. FAIL2BAN"
    echo "============================================================"

    echo "Устанавливаем Fail2ban..."

    if ! apt install -y fail2ban; then
        echo
        echo "Ошибка установки Fail2ban."
        status_failed "10"
        return 1
    fi

    cat > /etc/fail2ban/jail.local <<'EOF'
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
    echo "Перезапускаем Fail2ban..."

    systemctl enable fail2ban
    systemctl restart fail2ban

    echo
    echo "Статус Fail2ban:"

    if systemctl is-active --quiet fail2ban; then

        systemctl status fail2ban --no-pager -l || true

        echo
        echo "Jail status:"
        fail2ban-client status || true

        status_ok "10"
        return 0
    fi

    echo
    echo "Fail2ban не запущен."
    status_failed "10"
    return 1
}

# ============================================================
# 11. INSTALL EVERYTHING
# ============================================================

install_all() {

    echo
    echo "============================================================"
    echo "11. УСТАНОВКА ВСЕГО"
    echo "============================================================"

    echo
    echo "Дополнительные компоненты:"
    echo

    local install_zapret_all=false
    local install_warp_all=false
    local install_selfsteal_all=false

    if ask_yes_no "Установить Zapret.dat?"; then
        install_zapret_all=true
    fi

    if ask_yes_no "Установить два WARP профиля?"; then
        install_warp_all=true
    fi

    if ask_yes_no "Установить Selfsteal?"; then
        install_selfsteal_all=true
    fi

    echo
    echo "Начинаем установку..."

    # --------------------------------------------------------
    # 1
    # --------------------------------------------------------

    install_fwupd || true

    # --------------------------------------------------------
    # 2
    # --------------------------------------------------------

    update_system || true

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

    if [[ "$install_zapret_all" == true ]]; then
        install_zapret || true
    else
        status_skipped "5"
    fi

    # --------------------------------------------------------
    # 6
    # --------------------------------------------------------

    if [[ "$install_warp_all" == true ]]; then
        install_warp || true
    else
        status_skipped "6"
    fi

    # --------------------------------------------------------
    # 7
    # --------------------------------------------------------

    install_remnanode || true

    # --------------------------------------------------------
    # 8
    # --------------------------------------------------------

    if [[ "$install_selfsteal_all" == true ]]; then
        install_selfsteal || true
    else
        status_skipped "8"
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
    # REPORT
    # --------------------------------------------------------

    print_status

    echo
    echo "Установка завершена."
    echo "Лог:"
    echo "$LOG_FILE"
    echo
}

# ============================================================
# INITIAL STATUS
# ============================================================

for i in {1..10}; do
    status_not_run "$i"
done

# ============================================================
# MENU
# ============================================================

while true; do

    clear 2>/dev/null || true

    echo
    echo "============================================================"
    echo "             REMNAWAVE VPS BOOTSTRAP"
    echo "============================================================"
    echo
    echo "  1. Отключить fwupd"
    echo "  2. apt update + показать обновления"
    echo "  3. Отключить IPv6"
    echo "  4. Настроить BBR / network sysctl"
    echo "  5. Установить Zapret.dat"
    echo "  6. Установить два WARP профиля"
    echo "  7. Установить Remnawave Node"
    echo "  8. Установить Selfsteal"
    echo "  9. Настроить UFW"
    echo " 10. Установить и настроить Fail2ban"
    echo
    echo " 11. Установить ВСЁ"
    echo
    echo "  0. Выход"
    echo
    echo "============================================================"
    echo

    read -r -p "Выберите пункт: " choice

    case "$choice" in

        1)
            install_fwupd
            pause_menu
            ;;

        2)
            update_system
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
            install_all
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