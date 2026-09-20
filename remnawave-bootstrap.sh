#!/bin/bash

set -u

cd /root || exit 1

LOG_FILE="/var/log/remnawave-bootstrap.log"

REMNANODE_DIR="/opt/remnanode"
REMNANODE_COMPOSE="/opt/remnanode/docker-compose.yml"
XRAY_SHARE="/opt/remnanode/xray/share"
ZAPRET_FILE="${XRAY_SHARE}/zapret.dat"

NODE_INSTALLER_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh"
SELFSTEAL_INSTALLER_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh"
ZAPRET_URL="https://github.com/kutovoys/ru_gov_zapret/releases/latest/download/zapret.dat"
WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.3.0/wgcf_2.3.0_linux_amd64"

INSTALL_ZAPRET=false
INSTALL_WARP=false
INSTALL_SELFSTEAL=false

declare -A STATUS

mkdir -p "$(dirname "$LOG_FILE")"

exec > >(tee -a "$LOG_FILE") 2>&1


# ============================================================
# COLORS
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'


# ============================================================
# HELPERS
# ============================================================

status_ok() {
    STATUS["$1"]="OK"
}

status_failed() {
    STATUS["$1"]="FAILED"
}

status_skipped() {
    STATUS["$1"]="SKIPPED"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}


require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        print_error "Скрипт необходимо запускать от root."
        exit 1
    fi
}


# ============================================================
# 1. DISABLE FWUPD
# ============================================================

install_fwupd() {

    echo
    echo "============================================================"
    echo "1. Отключение fwupd"
    echo "============================================================"

    local service="fwupd.service"

    systemctl stop "$service" 2>/dev/null || true
    systemctl disable "$service" 2>/dev/null || true
    systemctl unmask "$service" 2>/dev/null || true

    if systemctl mask "$service" >/dev/null 2>&1; then
        print_info "systemctl mask выполнен."
    else
        print_warn "systemctl mask завершился ошибкой. Используем fallback."
    fi

    systemctl daemon-reload

    local target=""

    if [[ -e "/etc/systemd/system/$service" || -L "/etc/systemd/system/$service" ]]; then
        target="$(readlink -f "/etc/systemd/system/$service" 2>/dev/null || true)"
    fi

    if [[ "$target" != "/dev/null" ]]; then

        print_warn "Маска fwupd не установлена. Создаём её вручную."

        rm -f "/etc/systemd/system/$service"
        ln -s /dev/null "/etc/systemd/system/$service"

        systemctl daemon-reload
    fi

    local enabled
    local active

    enabled="$(systemctl is-enabled "$service" 2>/dev/null || true)"
    active="$(systemctl is-active "$service" 2>/dev/null || true)"
    target="$(readlink -f "/etc/systemd/system/$service" 2>/dev/null || true)"

    echo
    echo "fwupd enabled: $enabled"
    echo "fwupd active:  $active"
    echo "fwupd target:  $target"
    echo

    if [[ "$enabled" == "masked" || "$target" == "/dev/null" ]]; then
        print_ok "fwupd успешно отключён и замаскирован."
        status_ok "1"
        return 0
    fi

    print_error "Не удалось подтвердить mask fwupd."
    status_failed "1"
    return 1
}


# ============================================================
# 2. APT UPDATE
# ============================================================

install_updates() {

    echo
    echo "============================================================"
    echo "2. apt update + список обновлений"
    echo "============================================================"

    if apt update; then
        print_ok "apt update выполнен."
    else
        print_error "apt update завершился ошибкой."
        status_failed "2"
        return 1
    fi

    echo
    echo "Доступные обновления:"
    echo "------------------------------------------------------------"

    apt list --upgradable 2>/dev/null || true

    status_ok "2"
    return 0
}


# ============================================================
# 3. DISABLE IPV6
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

    if sysctl --system; then
        print_ok "IPv6 отключён через sysctl."
        status_ok "3"
        return 0
    fi

    print_error "Не удалось применить sysctl."
    status_failed "3"
    return 1
}


# ============================================================
# 4. BBR / NETWORK
# ============================================================

configure_bbr() {

    echo
    echo "============================================================"
    echo "4. BBR / сетевые параметры"
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
        print_error "Не удалось применить сетевые параметры."
        status_failed "4"
        return 1
    fi

    echo
    echo "Текущий congestion control:"
    sysctl net.ipv4.tcp_congestion_control

    echo
    echo "Текущий qdisc:"
    sysctl net.core.default_qdisc

    echo

    local cc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"

    if [[ "$cc" == "bbr" ]]; then
        print_ok "BBR активен."
        status_ok "4"
        return 0
    fi

    print_warn "BBR не активен."
    status_failed "4"
    return 1
}


# ============================================================
# ZAPRET -> DOCKER COMPOSE
# ============================================================

configure_remnanode_zapret() {

    echo
    echo "Настройка Zapret.dat в Remnawave Node..."

    if [[ ! -f "$REMNANODE_COMPOSE" ]]; then
        print_error "Не найден:"
        echo "$REMNANODE_COMPOSE"
        return 1
    fi

    if [[ ! -s "$ZAPRET_FILE" ]]; then
        print_error "Zapret.dat отсутствует или пустой:"
        echo "$ZAPRET_FILE"
        return 1
    fi

    local mount_line
    mount_line="      - /opt/remnanode/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro"

    if grep -Fq "$mount_line" "$REMNANODE_COMPOSE"; then
        print_info "Mount Zapret уже присутствует."
        return 0
    fi

    local backup
    backup="${REMNANODE_COMPOSE}.bak.$(date +%Y%m%d_%H%M%S)"

    cp -a "$REMNANODE_COMPOSE" "$backup"

    print_info "Создан backup:"
    echo "$backup"

    if ! python3 - "$REMNANODE_COMPOSE" <<'PY'
import sys
from pathlib import Path

compose = Path(sys.argv[1])

text = compose.read_text()

mount = "      - /opt/remnanode/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro"

if mount in text:
    sys.exit(0)

lines = text.splitlines()

service_start = None

for i, line in enumerate(lines):
    if line == "  remnanode:":
        service_start = i
        break

if service_start is None:
    print("Service remnanode не найден.")
    sys.exit(1)

service_end = len(lines)

for i in range(service_start + 1, len(lines)):
    if lines[i].startswith("  ") and not lines[i].startswith("    "):
        service_end = i
        break

volumes_line = None

for i in range(service_start + 1, service_end):
    if lines[i].strip() == "volumes:" and lines[i].startswith("    "):
        volumes_line = i
        break

if volumes_line is not None:
    lines.insert(volumes_line + 1, mount)
else:
    lines[service_end:service_end] = [
        "    volumes:",
        mount,
    ]

compose.write_text("\n".join(lines) + "\n")
PY
    then

        print_error "Не удалось изменить docker-compose.yml."
        cp -a "$backup" "$REMNANODE_COMPOSE"
        return 1
    fi

    echo
    echo "Проверяем Docker Compose..."

    if ! (cd "$REMNANODE_DIR" && docker compose config >/dev/null); then

        print_error "Docker Compose после изменения невалиден."
        print_warn "Восстанавливаем backup."

        cp -a "$backup" "$REMNANODE_COMPOSE"

        return 1
    fi

    print_ok "Zapret mount успешно добавлен."

    echo
    echo "Строка mount:"
    grep -F "zapret.dat:/usr/local/bin/zapret.dat" \
        "$REMNANODE_COMPOSE" || true

    return 0
}


# ============================================================
# RESTART NODE
# ============================================================

restart_remnanode() {

    if [[ ! -f "$REMNANODE_COMPOSE" ]]; then
        print_error "Remnawave Node не установлен."
        return 1
    fi

    cd "$REMNANODE_DIR" || return 1

    echo
    echo "Перезапускаем Remnawave Node..."

    docker compose down || true

    if ! docker compose up -d; then
        print_error "Не удалось запустить Remnawave Node."
        return 1
    fi

    echo
    docker compose ps

    return 0
}


# ============================================================
# 5. ZAPRET
# ============================================================

install_zapret() {

    echo
    echo "============================================================"
    echo "5. Установка Zapret.dat"
    echo "============================================================"

    mkdir -p "$XRAY_SHARE"

    apt install -y curl ca-certificates

    local tmp_file
    tmp_file="$(mktemp)"

    echo
    echo "Скачиваем Zapret.dat..."

    if ! curl -fL --retry 3 \
        --connect-timeout 15 \
        "$ZAPRET_URL" \
        -o "$tmp_file"; then

        rm -f "$tmp_file"

        print_error "Не удалось скачать Zapret.dat."
        status_failed "5"
        return 1
    fi

    if [[ ! -s "$tmp_file" ]]; then

        rm -f "$tmp_file"

        print_error "Скачанный Zapret.dat пустой."
        status_failed "5"
        return 1
    fi

    install -m 644 "$tmp_file" "$ZAPRET_FILE"

    rm -f "$tmp_file"

    print_ok "Zapret.dat установлен:"
    echo "$ZAPRET_FILE"

    INSTALL_ZAPRET=true

    # Если Node уже есть — сразу подключаем Zapret.
    if [[ -f "$REMNANODE_COMPOSE" ]]; then

        echo
        print_info "Найден существующий docker-compose.yml."

        if ! configure_remnanode_zapret; then

            print_error "Не удалось добавить Zapret в Compose."
            status_failed "5"
            return 1
        fi

        if ! restart_remnanode; then

            print_error "Не удалось перезапустить Node."
            status_failed "5"
            return 1
        fi

        print_ok "Zapret подключён к существующему Node."

    else

        echo
        print_info "Node ещё не установлен."
        print_info "Zapret будет подключён после установки Node."
    fi

    status_ok "5"
    return 0
}


# ============================================================
# WARP CONFIG
# ============================================================

configure_warp_conf() {

    local file="$1"
    local address="$2"

    if [[ ! -f "$file" ]]; then
        print_error "Не найден WARP конфиг:"
        echo "$file"
        return 1
    fi

    python3 - "$file" "$address" <<'PY'
import sys
from pathlib import Path

file = Path(sys.argv[1])
address = sys.argv[2]

lines = file.read_text().splitlines()

# Remove Address
lines = [
    line for line in lines
    if not line.strip().startswith("Address =")
]

# Insert IPv4 Address after [Interface]
interface_index = None

for i, line in enumerate(lines):
    if line.strip() == "[Interface]":
        interface_index = i
        break

if interface_index is None:
    print("Не найден [Interface]")
    sys.exit(1)

lines.insert(
    interface_index + 1,
    f"Address = {address}"
)

# IPv4-only AllowedIPs
new = []

for line in lines:

    if line.strip().startswith("AllowedIPs ="):

        value = line.split("=", 1)[1].strip()

        parts = [
            x.strip()
            for x in value.split(",")
        ]

        ipv4 = [
            x for x in parts
            if x and ":" not in x
        ]

        line = "AllowedIPs = " + ", ".join(ipv4)

    new.append(line)

lines = new

# Remove IPv6 Endpoint
new = []

for line in lines:

    if line.strip().startswith("Endpoint ="):

        endpoint = line.split("=", 1)[1].strip()

        if endpoint.startswith("["):
            continue

    new.append(line)

lines = new

# Remove existing Table
lines = [
    line for line in lines
    if not line.strip().startswith("Table =")
]

# Table = off after MTU
mtu_index = None

for i, line in enumerate(lines):

    if line.strip().startswith("MTU ="):
        mtu_index = i
        break

if mtu_index is None:
    print("Не найден MTU.")
    sys.exit(1)

lines.insert(
    mtu_index + 1,
    "Table = off"
)

# Remove existing PersistentKeepalive
lines = [
    line for line in lines
    if not line.strip().startswith("PersistentKeepalive =")
]

# Add PersistentKeepalive after endpoint
endpoint_index = None

for i, line in enumerate(lines):

    if line.strip() == "Endpoint = engage.cloudflareclient.com:2408":
        endpoint_index = i
        break

if endpoint_index is None:
    print("Не найден Endpoint = engage.cloudflareclient.com:2408")
    sys.exit(1)

lines.insert(
    endpoint_index + 1,
    "PersistentKeepalive = 25"
)

file.write_text(
    "\n".join(lines) + "\n"
)
PY

    chmod 600 "$file"

    return 0
}


# ============================================================
# 6. WARP
# ============================================================

install_warp() {

    echo
    echo "============================================================"
    echo "6. Установка двух WARP профилей"
    echo "============================================================"

    apt install -y wireguard curl ca-certificates

    local tmpdir
    tmpdir="$(mktemp -d)"

    cd "$tmpdir" || return 1

    echo
    echo "Скачиваем wgcf v2.3.0..."

    if ! curl -fL --retry 3 \
        "$WGCF_URL" \
        -o wgcf; then

        rm -rf "$tmpdir"

        print_error "Не удалось скачать wgcf."
        status_failed "6"
        return 1
    fi

    chmod +x wgcf
    install -m 755 wgcf /usr/local/bin/wgcf

    rm -rf "$tmpdir"


    # ========================================================
    # WARP 1
    # ========================================================

    echo
    echo "Создаём WARP профиль #1..."

    local warp1
    warp1="$(mktemp -d)"

    cd "$warp1" || return 1

    rm -f wgcf-account.toml wgcf-profile.conf

    if ! /usr/local/bin/wgcf register; then

        rm -rf "$warp1"

        print_error "wgcf register WARP #1 завершился ошибкой."
        status_failed "6"
        return 1
    fi

    if ! /usr/local/bin/wgcf generate; then

        rm -rf "$warp1"

        print_error "wgcf generate WARP #1 завершился ошибкой."
        status_failed "6"
        return 1
    fi

    if [[ ! -f wgcf-profile.conf ]]; then

        rm -rf "$warp1"

        print_error "WARP #1 конфиг не создан."
        status_failed "6"
        return 1
    fi

    mv wgcf-profile.conf /etc/wireguard/wgcf1.conf

    rm -rf "$warp1"


    # ========================================================
    # WARP 2
    # ========================================================

    echo
    echo "Создаём WARP профиль #2..."

    local warp2
    warp2="$(mktemp -d)"

    cd "$warp2" || return 1

    rm -f wgcf-account.toml wgcf-profile.conf

    if ! /usr/local/bin/wgcf register; then

        rm -rf "$warp2"

        print_error "wgcf register WARP #2 завершился ошибкой."
        status_failed "6"
        return 1
    fi

    if ! /usr/local/bin/wgcf generate; then

        rm -rf "$warp2"

        print_error "wgcf generate WARP #2 завершился ошибкой."
        status_failed "6"
        return 1
    fi

    if [[ ! -f wgcf-profile.conf ]]; then

        rm -rf "$warp2"

        print_error "WARP #2 конфиг не создан."
        status_failed "6"
        return 1
    fi

    mv wgcf-profile.conf /etc/wireguard/wgcf2.conf

    rm -rf "$warp2"

    cd /root || true


    # ========================================================
    # Configure
    # ========================================================

    echo
    echo "Настраиваем WARP #1..."

    if ! configure_warp_conf \
        /etc/wireguard/wgcf1.conf \
        "172.16.0.2/32"; then

        status_failed "6"
        return 1
    fi

    echo
    echo "Настраиваем WARP #2..."

    if ! configure_warp_conf \
        /etc/wireguard/wgcf2.conf \
        "172.16.0.3/32"; then

        status_failed "6"
        return 1
    fi


    # ========================================================
    # Startup script
    # ========================================================

    cat > /usr/local/bin/warp_start.sh <<'EOF'
#!/bin/bash

set -e

wg-quick down wgcf1 2>/dev/null || true
wg-quick down wgcf2 2>/dev/null || true

wg-quick up wgcf1
wg-quick up wgcf2
EOF

    chmod +x /usr/local/bin/warp_start.sh


    # ========================================================
    # systemd
    # ========================================================

    cat > /etc/systemd/system/warp.service <<'EOF'
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

        print_error "Не удалось запустить WARP."

        systemctl status warp.service --no-pager || true

        status_failed "6"
        return 1
    fi

    echo
    echo "WARP status:"
    wg show

    print_ok "Два WARP профиля настроены."

    status_ok "6"
    return 0
}


# ============================================================
# 7. REMNAWAVE NODE
# ============================================================

install_remnanode() {

    echo
    echo "============================================================"
    echo "7. Установка Remnawave Node"
    echo "============================================================"

    apt install -y curl ca-certificates

    local node_installer
    node_installer="$(mktemp /tmp/remnanode.XXXXXX.sh)"

    echo
    echo "Скачиваем установщик Remnawave Node..."

    if ! curl -fL --retry 3 \
        "$NODE_INSTALLER_URL" \
        -o "$node_installer"; then

        rm -f "$node_installer"

        print_error "Не удалось скачать установщик Node."

        status_failed "7"
        return 1
    fi

    chmod +x "$node_installer"

    # Убираем CRLF, если они присутствуют
    sed -i 's/\r$//' "$node_installer"

    echo
    echo "Запускаем установщик Remnawave Node."
    echo
    echo "Если Node уже установлен, будет автоматически"
    echo "подтверждена переустановка через ответ: y"
    echo
    echo "Если установка зависнет — нажмите Ctrl+C."
    echo
    echo "Ctrl+C остановит только установщик Node."
    echo "Bootstrap продолжит работу и вернётся в меню."
    echo

    local installer_pid
    local node_interrupted=0

    trap 'node_interrupted=1' INT

    # --------------------------------------------------------
    # ВАЖНО:
    #
    # Установщик сам спрашивает:
    #
    # Do you want to override the previous installation? (y/n)
    #
    # Поэтому передаём ему "y".
    #
    # /opt/remnanode НЕ удаляем.
    # --------------------------------------------------------

    setsid bash -c 'printf "y\n" | bash "$1" @ install' _ "$node_installer" &
    installer_pid=$!

    while kill -0 "$installer_pid" 2>/dev/null; do

        if [[ "$node_interrupted" -eq 1 ]]; then

            echo
            print_warn "Получен Ctrl+C."
            print_warn "Останавливаем только установщик Node..."

            kill -TERM -- "-$installer_pid" 2>/dev/null || true

            sleep 2

            if kill -0 "$installer_pid" 2>/dev/null; then

                print_warn "Установщик не остановился."
                print_warn "Отправляем SIGKILL..."

                kill -KILL -- "-$installer_pid" 2>/dev/null || true
            fi

            break
        fi

        sleep 0.5
    done

    wait "$installer_pid" 2>/dev/null
    local installer_rc=$?

    trap - INT

    rm -f "$node_installer"

    echo
    echo "Код завершения установщика: $installer_rc"
    echo


    # ========================================================
    # Ctrl+C
    # ========================================================

    if [[ "$node_interrupted" -eq 1 || "$installer_rc" -eq 130 ]]; then

        print_warn "Установка Node прервана пользователем."
        print_warn "Bootstrap продолжает работу."

        status_skipped "7"
        return 0
    fi


    # ========================================================
    # SUCCESS
    # ========================================================

    if [[ "$installer_rc" -eq 0 ]]; then

        print_ok "Установщик Remnawave Node завершился успешно."

        # ----------------------------------------------------
        # Zapret
        # ----------------------------------------------------

        if [[ "$INSTALL_ZAPRET" == "true" ]]; then

            echo
            print_info "Подключаем Zapret.dat к Remnawave Node..."

            if ! configure_remnanode_zapret; then

                print_error "Не удалось подключить Zapret."

                status_failed "7"
                return 1
            fi

            if ! restart_remnanode; then

                print_error "Не удалось перезапустить Remnawave Node."

                status_failed "7"
                return 1
            fi
        fi

        status_ok "7"
        return 0
    fi


    # ========================================================
    # Installer returned error, but Node may exist
    # ========================================================

    if [[ -f "$REMNANODE_COMPOSE" ]]; then

        print_warn "Установщик вернул код $installer_rc,"
        print_warn "но docker-compose.yml существует."

        if (cd "$REMNANODE_DIR" && docker compose config >/dev/null 2>&1); then

            print_ok "Docker Compose Node валиден."

            if [[ "$INSTALL_ZAPRET" == "true" ]]; then

                echo
                print_info "Подключаем Zapret.dat..."

                if ! configure_remnanode_zapret; then

                    print_error "Не удалось подключить Zapret."

                    status_failed "7"
                    return 1
                fi

                if ! restart_remnanode; then

                    print_error "Не удалось перезапустить Node."

                    status_failed "7"
                    return 1
                fi
            fi

            status_ok "7"
            return 0
        fi
    fi


    # ========================================================
    # ERROR
    # ========================================================

    print_error "Установщик Node завершился с ошибкой."
    print_error "Код: $installer_rc"

    status_failed "7"
    return 1
}


# ============================================================
# 8. SELFSTEAL
# ============================================================

install_selfsteal() {

    echo
    echo "============================================================"
    echo "8. Установка Selfsteal"
    echo "============================================================"

    apt install -y curl ca-certificates

    local selfsteal_installer
    selfsteal_installer="$(mktemp /tmp/selfsteal.XXXXXX.sh)"

    echo
    echo "Скачиваем установщик Selfsteal..."

    if ! curl -fL --retry 3 \
        "$SELFSTEAL_INSTALLER_URL" \
        -o "$selfsteal_installer"; then

        rm -f "$selfsteal_installer"

        print_error "Не удалось скачать Selfsteal installer."

        status_failed "8"
        return 1
    fi

    chmod +x "$selfsteal_installer"

    sed -i 's/\r$//' "$selfsteal_installer"

    echo
    echo "Запускаем установщик Selfsteal..."

    bash "$selfsteal_installer" @ install
    local rc=$?

    rm -f "$selfsteal_installer"

    echo
    echo "Код завершения Selfsteal: $rc"

    if [[ "$rc" -eq 0 ]]; then

        print_ok "Selfsteal установлен."

        status_ok "8"
        return 0
    fi

    print_error "Selfsteal завершился с ошибкой."

    status_failed "8"
    return 1
}


# ============================================================
# 9. UFW
# ============================================================

configure_ufw() {

    echo
    echo "============================================================"
    echo "9. Настройка UFW"
    echo "============================================================"

    apt install -y ufw

    echo
    echo "Разрешаем SSH..."

    ufw allow OpenSSH

    echo "Разрешаем TCP 443..."

    ufw allow 443/tcp

    echo "Разрешаем TCP 1433..."

    ufw allow 1433/tcp

    echo
    echo "Включаем UFW..."

    if ! ufw --force enable; then

        print_error "Не удалось включить UFW."

        status_failed "9"
        return 1
    fi

    echo
    ufw status verbose

    print_ok "UFW настроен."

    status_ok "9"
    return 0
}


# ============================================================
# 10. FAIL2BAN
# ============================================================

configure_fail2ban() {

    echo
    echo "============================================================"
    echo "10. Настройка Fail2ban"
    echo "============================================================"

    apt install -y fail2ban

    mkdir -p /etc/fail2ban

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

    systemctl enable fail2ban

    if ! systemctl restart fail2ban; then

        print_error "Не удалось запустить Fail2ban."

        systemctl status fail2ban --no-pager || true

        status_failed "10"
        return 1
    fi

    echo
    systemctl status fail2ban --no-pager

    echo
    echo "Jails:"

    fail2ban-client status || true

    print_ok "Fail2ban настроен."

    status_ok "10"
    return 0
}


# ============================================================
# STATUS
# ============================================================

print_status() {

    echo
    echo "============================================================"
    echo "СТАТУС"
    echo "============================================================"

    local names=(
        "1:Disable fwupd"
        "2:apt update"
        "3:Disable IPv6"
        "4:BBR / network"
        "5:Zapret.dat"
        "6:WARP"
        "7:Remnawave Node"
        "8:Selfsteal"
        "9:UFW"
        "10:Fail2ban"
    )

    local item
    local num
    local name
    local state

    for item in "${names[@]}"; do

        num="${item%%:*}"
        name="${item#*:}"

        state="${STATUS[$num]:-NOT RUN}"

        case "$state" in

            OK)
                echo -e "${GREEN}[OK]${NC}      $num. $name"
                ;;

            FAILED)
                echo -e "${RED}[FAILED]${NC}  $num. $name"
                ;;

            SKIPPED)
                echo -e "${YELLOW}[SKIPPED]${NC} $num. $name"
                ;;

            *)
                echo -e "${BLUE}[NOT RUN]${NC} $num. $name"
                ;;

        esac
    done

    echo
}


# ============================================================
# 11. INSTALL EVERYTHING
# ============================================================

install_all() {

    echo
    echo "============================================================"
    echo "11. Установка всего"
    echo "============================================================"

    echo
    read -r -p "Установить Zapret.dat? [y/n]: " answer

    case "$answer" in

        y|Y|д|Д)
            INSTALL_ZAPRET=true
            ;;

        *)
            INSTALL_ZAPRET=false
            status_skipped "5"
            ;;
    esac


    echo
    read -r -p "Установить два WARP профиля? [y/n]: " answer

    case "$answer" in

        y|Y|д|Д)
            INSTALL_WARP=true
            ;;

        *)
            INSTALL_WARP=false
            status_skipped "6"
            ;;
    esac


    echo
    read -r -p "Установить Selfsteal? [y/n]: " answer

    case "$answer" in

        y|Y|д|Д)
            INSTALL_SELFSTEAL=true
            ;;

        *)
            INSTALL_SELFSTEAL=false
            status_skipped "8"
            ;;
    esac


    echo
    echo "Начинаем установку..."
    echo


    install_fwupd || true

    install_updates || true

    disable_ipv6 || true

    configure_bbr || true


    if [[ "$INSTALL_ZAPRET" == "true" ]]; then
        install_zapret || true
    fi


    if [[ "$INSTALL_WARP" == "true" ]]; then
        install_warp || true
    fi


    # ========================================================
    # NODE
    #
    # Всегда запускаем installer.
    # Если он видит старый Node — автоматически отвечаем y.
    # ========================================================

    install_remnanode || true


    if [[ "$INSTALL_SELFSTEAL" == "true" ]]; then
        install_selfsteal || true
    fi


    configure_ufw || true

    configure_fail2ban || true


    print_status
}


# ============================================================
# MENU
# ============================================================

show_menu() {

    clear

    echo "============================================================"
    echo "       REMNAWAVE VPS BOOTSTRAP"
    echo "============================================================"
    echo
    echo "  1. Отключить fwupd"
    echo "  2. apt update + список обновлений"
    echo "  3. Отключить IPv6"
    echo "  4. BBR / сетевые параметры"
    echo "  5. Установить Zapret.dat"
    echo "  6. Установить два WARP профиля"
    echo "  7. Установить Remnawave Node"
    echo "  8. Установить Selfsteal"
    echo "  9. Настроить UFW"
    echo " 10. Настроить Fail2ban"
    echo " 11. Установить всё"
    echo
    echo "  0. Выход"
    echo
    echo "============================================================"
}


# ============================================================
# MAIN
# ============================================================

require_root

while true; do

    show_menu

    read -r -p "Выберите пункт: " choice

    case "$choice" in

        1)
            install_fwupd
            read -r -p "Нажмите Enter для возврата в меню..." _
            ;;

        2)
            install_updates
            read -r -p "Нажмите Enter для возврата в меню..." _
            ;;

        3)
            disable_ipv6
            read -r -p "Нажмите Enter для возврата в меню..." _
            ;;

        4)
            configure_bbr
            read -r -p "Нажмите Enter для возврата в меню..." _
            ;;

        5)
            install_zapret
            read -r -p "Нажмите Enter для возврата в меню..." _
            ;;

        6)
            install_warp
            read -r -p "Нажмите Enter для возврата в меню..." _
            ;;

        7)
            install_remnanode
            read -r -p "Нажмите Enter для возврата в меню..." _
            ;;

        8)
            install_selfsteal
            read -r -p "Нажмите Enter для возврата в меню..." _
            ;;

        9)
            configure_ufw
            read -r -p "Нажмите Enter для возврата в меню..." _
            ;;

        10)
            configure_fail2ban
            read -r -p "Нажмите Enter для возврата в меню..." _
            ;;

        11)
            install_all
            read -r -p "Нажмите Enter для возврата в меню..." _
            ;;

        0)
            echo
            echo "Выход."
            exit 0
            ;;

        *)
            print_error "Неверный пункт меню."
            sleep 1
            ;;

    esac

done
