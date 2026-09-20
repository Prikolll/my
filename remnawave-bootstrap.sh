```bash
#!/usr/bin/env bash

set -o pipefail

LOG_FILE="/var/log/remnawave-bootstrap.log"

REMNANODE_INSTALLER_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh"
SELFSTEAL_INSTALLER_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh"
ZAPRET_URL="https://github.com/kutovoys/ru_gov_zapret/releases/latest/download/zapret.dat"
WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.3.0/wgcf_2.3.0_linux_amd64"

REMNANODE_DIR="/opt/remnanode"
DOCKER_COMPOSE_FILE="/opt/remnanode/docker-compose.yml"
ZAPRET_FILE="/opt/remnanode/xray/share/zapret.dat"

WGCF1_CONF="/etc/wireguard/wgcf1.conf"
WGCF2_CONF="/etc/wireguard/wgcf2.conf"

WARP_START="/usr/local/bin/warp_start.sh"
WARP_SERVICE="/etc/systemd/system/warp.service"

FAIL2BAN_JAIL="/etc/fail2ban/jail.local"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

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
# STATUS
# ============================================================

declare -a STATUS

for i in {1..11}; do
    STATUS[$i]="NOT RUN"
done

# Был ли в пункте 11 подтверждён Zapret
ZAPRET_SELECTED_IN_11=false


# ============================================================
# HELPERS
# ============================================================

msg_title() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN} $1${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo
}

msg_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

msg_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

msg_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

status_text() {
    case "$1" in
        OK)
            echo -e "${GREEN}OK${NC}"
            ;;
        FAILED)
            echo -e "${RED}FAILED${NC}"
            ;;
        RUNNING)
            echo -e "${YELLOW}RUNNING${NC}"
            ;;
        SKIPPED)
            echo -e "${YELLOW}SKIPPED${NC}"
            ;;
        *)
            echo -e "${YELLOW}NOT RUN${NC}"
            ;;
    esac
}

pause_menu() {
    echo
    read -rp "Нажмите Enter для продолжения..."
}

download_file() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 15 "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --show-progress "$url" -O "$output"
    else
        msg_error "Не найден curl или wget."
        return 1
    fi
}


# ============================================================
# ROOT CHECK
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    msg_error "Скрипт необходимо запускать от root."
    exit 1
fi


# ============================================================
# 1. DISABLE FWUPD
# ============================================================

disable_fwupd() {

    msg_title "1. Отключение fwupd"

    STATUS[1]="RUNNING"

    if systemctl disable --now fwupd.service >/dev/null 2>&1; then
        msg_ok "fwupd отключён."
        STATUS[1]="OK"
        return
    fi

    if ! systemctl list-unit-files | grep -q '^fwupd'; then
        msg_ok "fwupd не установлен."
        STATUS[1]="OK"
        return
    fi

    systemctl stop fwupd.service >/dev/null 2>&1 || true
    systemctl disable fwupd.service >/dev/null 2>&1 || true

    if systemctl is-active --quiet fwupd.service; then
        msg_error "Не удалось отключить fwupd."
        STATUS[1]="FAILED"
    else
        msg_ok "fwupd отключён."
        STATUS[1]="OK"
    fi
}


# ============================================================
# 2. APT UPDATE + UPGRADES
# ============================================================

apt_update_show_upgrades() {

    msg_title "2. apt update + доступные обновления"

    STATUS[2]="RUNNING"

    if apt-get update; then
        echo
        msg_info "Доступные обновления:"
        echo

        apt list --upgradable 2>/dev/null || true

        STATUS[2]="OK"
        msg_ok "apt update выполнен."
    else
        msg_error "Ошибка apt update."
        STATUS[2]="FAILED"
    fi
}


# ============================================================
# 3. DISABLE IPV6
# ============================================================

disable_ipv6() {

    msg_title "3. Отключение IPv6"

    STATUS[3]="RUNNING"

    cat >/etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    if sysctl --system >/dev/null 2>&1; then
        msg_ok "IPv6 отключён."
        STATUS[3]="OK"
    else
        msg_error "Не удалось применить sysctl."
        STATUS[3]="FAILED"
    fi
}


# ============================================================
# 4. BBR
# ============================================================

configure_bbr() {

    msg_title "4. Настройка BBR"

    STATUS[4]="RUNNING"

    cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    if sysctl --system >/dev/null 2>&1; then

        if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
            msg_ok "BBR включён."
            STATUS[4]="OK"
        else
            msg_error "BBR не активирован."
            STATUS[4]="FAILED"
        fi

    else
        msg_error "Не удалось применить BBR."
        STATUS[4]="FAILED"
    fi
}


# ============================================================
# 5. ZAPRET
# ============================================================

install_zapret() {

    msg_title "5. Установка zapret.dat"

    STATUS[5]="RUNNING"

    mkdir -p "$(dirname "$ZAPRET_FILE")"

    local tmp_file
    tmp_file=$(mktemp)

    msg_info "Скачивание zapret.dat..."

    if download_file "$ZAPRET_URL" "$tmp_file"; then

        if [[ ! -s "$tmp_file" ]]; then
            msg_error "Скачанный zapret.dat пустой."
            rm -f "$tmp_file"
            STATUS[5]="FAILED"
            return
        fi

        install -m 0644 "$tmp_file" "$ZAPRET_FILE"
        rm -f "$tmp_file"

        msg_ok "zapret.dat установлен:"
        echo "      $ZAPRET_FILE"

        STATUS[5]="OK"

    else

        msg_error "Не удалось скачать zapret.dat."
        rm -f "$tmp_file"

        STATUS[5]="FAILED"
    fi
}


# ============================================================
# 6. WARP
# ============================================================

install_warp() {

    msg_title "6. Установка WARP"

    STATUS[6]="RUNNING"

    apt-get update >/dev/null 2>&1

    apt-get install -y \
        wireguard \
        wireguard-tools \
        >/dev/null 2>&1

    if ! command -v wg >/dev/null 2>&1; then
        msg_error "WireGuard не установлен."
        STATUS[6]="FAILED"
        return
    fi

    local wgcf_bin
    wgcf_bin=$(mktemp)

    msg_info "Скачивание wgcf..."

    if ! download_file "$WGCF_URL" "$wgcf_bin"; then
        msg_error "Не удалось скачать wgcf."
        rm -f "$wgcf_bin"
        STATUS[6]="FAILED"
        return
    fi

    chmod +x "$wgcf_bin"

    install -m 0755 "$wgcf_bin" /usr/local/bin/wgcf
    rm -f "$wgcf_bin"

    msg_info "wgcf установлен."

    if [[ ! -f "$WGCF1_CONF" ]]; then

        mkdir -p /etc/wireguard

        cd /etc/wireguard || {
            STATUS[6]="FAILED"
            return
        }

        if wgcf register --accept-tos >/dev/null 2>&1; then

            if wgcf generate >/dev/null 2>&1; then

                if [[ -f wgcf-profile.conf ]]; then

                    cp wgcf-profile.conf "$WGCF1_CONF"

                    sed -i \
                        's/^PrivateKey = .*/PrivateKey = &/' \
                        "$WGCF1_CONF" 2>/dev/null || true

                    msg_ok "wgcf1.conf создан."

                else
                    msg_error "wgcf-profile.conf не создан."
                    STATUS[6]="FAILED"
                    return
                fi

            else
                msg_error "Ошибка генерации WireGuard-конфига."
                STATUS[6]="FAILED"
                return
            fi

        else
            msg_error "Ошибка регистрации wgcf."
            STATUS[6]="FAILED"
            return
        fi

    else
        msg_info "wgcf1.conf уже существует."
    fi


    # --------------------------------------------------------
    # Создание второго WARP-конфига
    # --------------------------------------------------------

    if [[ -f "$WGCF1_CONF" && ! -f "$WGCF2_CONF" ]]; then

        cp "$WGCF1_CONF" "$WGCF2_CONF"

        msg_info "Создан wgcf2.conf."

    fi


    # --------------------------------------------------------
    # WARP start script
    # --------------------------------------------------------

    cat >"$WARP_START" <<'EOF'
#!/usr/bin/env bash

set -e

/usr/bin/wg-quick down wgcf1 2>/dev/null || true
/usr/bin/wg-quick down wgcf2 2>/dev/null || true

/usr/bin/wg-quick up wgcf1
/usr/bin/wg-quick up wgcf2
EOF

    chmod +x "$WARP_START"


    # --------------------------------------------------------
    # systemd service
    # --------------------------------------------------------

    cat >"$WARP_SERVICE" <<'EOF'
[Unit]
Description=WARP WireGuard
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp_start.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    if systemctl enable --now warp.service >/dev/null 2>&1; then
        msg_ok "WARP установлен и запущен."
        STATUS[6]="OK"
    else
        msg_error "Не удалось запустить WARP."
        STATUS[6]="FAILED"
    fi
}


# ============================================================
# 7. UFW
# ============================================================

configure_ufw() {

    msg_title "7. Настройка UFW"

    STATUS[7]="RUNNING"

    if ! command -v ufw >/dev/null 2>&1; then
        apt-get install -y ufw >/dev/null 2>&1
    fi

    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ufw allow 443/udp >/dev/null 2>&1

    if ufw --force enable >/dev/null 2>&1; then
        msg_ok "UFW настроен."
        STATUS[7]="OK"
    else
        msg_error "Не удалось включить UFW."
        STATUS[7]="FAILED"
    fi
}


# ============================================================
# 8. FAIL2BAN
# ============================================================

install_fail2ban() {

    msg_title "8. Установка Fail2Ban"

    STATUS[8]="RUNNING"

    if ! apt-get install -y fail2ban >/dev/null 2>&1; then
        msg_error "Не удалось установить Fail2Ban."
        STATUS[8]="FAILED"
        return
    fi

    cat >"$FAIL2BAN_JAIL" <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1

    if systemctl is-active --quiet fail2ban; then
        msg_ok "Fail2Ban установлен и запущен."
        STATUS[8]="OK"
    else
        msg_error "Fail2Ban не запущен."
        STATUS[8]="FAILED"
    fi
}


# ============================================================
# 9. REMNANODE
# ============================================================

install_remnanode() {

    msg_title "9. Установка RemnaNode"

    STATUS[9]="RUNNING"

    local node_installer
    local installer_log
    local installer_pid

    node_installer=$(mktemp)
    installer_log=$(mktemp)

    msg_info "Скачивание установщика RemnaNode..."
    echo

    if ! download_file \
        "$REMNANODE_INSTALLER_URL" \
        "$node_installer"; then

        echo
        msg_error "Ошибка скачивания установщика RemnaNode."

        rm -f "$node_installer"
        rm -f "$installer_log"

        STATUS[9]="FAILED"
        return
    fi

    # Убираем CRLF
    sed -i 's/\r$//' "$node_installer"

    chmod +x "$node_installer"

    echo
    msg_info "Запуск RemnaNode installer..."
    echo

    # --------------------------------------------------------
    # Важно:
    #
    # Установщик остаётся интерактивным через /dev/tty.
    # stdout/stderr одновременно выводятся на экран и
    # записываются в installer_log.
    #
    # В отличие от обычного pipeline:
    #
    # bash ... | tee
    #
    # здесь $! — именно PID установщика bash.
    # --------------------------------------------------------

    bash "$node_installer" @ install \
        </dev/tty \
        > >(tee "$installer_log") \
        2> >(tee -a "$installer_log" >&2) &

    installer_pid=$!

    # --------------------------------------------------------
    # Ждём:
    #
    # Container remnanode Started
    #
    # После появления строки ждём 2 секунды.
    # --------------------------------------------------------

    while kill -0 "$installer_pid" 2>/dev/null; do

        if grep -a -q "Container remnanode Started" "$installer_log" 2>/dev/null; then

            echo
            msg_ok "Container remnanode Started"

            msg_info "Установка завершена. Ожидание 2 секунды..."

            sleep 2

            echo
            msg_ok "RemnaNode успешно установлен."

            STATUS[9]="OK"

            # ------------------------------------------------
            # Останавливаем дальнейшее выполнение installer.
            # ------------------------------------------------

            kill "$installer_pid" 2>/dev/null || true

            sleep 0.5

            if kill -0 "$installer_pid" 2>/dev/null; then
                kill -9 "$installer_pid" 2>/dev/null || true
            fi

            wait "$installer_pid" 2>/dev/null || true

            break
        fi

        sleep 0.2

    done


    # --------------------------------------------------------
    # Если installer завершился самостоятельно
    # --------------------------------------------------------

    if [[ "${STATUS[9]}" == "RUNNING" ]]; then

        if grep -a -q "Container remnanode Started" "$installer_log" 2>/dev/null; then

            echo
            msg_ok "Container remnanode Started"
            msg_ok "RemnaNode успешно установлен."

            STATUS[9]="OK"

        else

            echo
            msg_error "RemnaNode installer завершился без подтверждения запуска контейнера."

            STATUS[9]="FAILED"

        fi

    fi


    rm -f "$node_installer"
    rm -f "$installer_log"
}


# ============================================================
# 9.1 ADD ZAPRET MOUNT
# ============================================================

add_zapret_mount_to_compose() {

    msg_title "Добавление zapret.dat в Docker Compose"

    if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
        msg_error "Не найден docker-compose.yml:"
        echo "      $DOCKER_COMPOSE_FILE"
        return 1
    fi

    if [[ ! -f "$ZAPRET_FILE" ]]; then
        msg_error "Не найден zapret.dat:"
        echo "      $ZAPRET_FILE"
        return 1
    fi

    local zapret_mount
    zapret_mount="      - /opt/remnanode/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro"

    # --------------------------------------------------------
    # Не добавляем повторно, если mount уже существует.
    # --------------------------------------------------------

    if grep -Fq "/opt/remnanode/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro" \
        "$DOCKER_COMPOSE_FILE"; then

        msg_ok "Mount zapret.dat уже присутствует в docker-compose.yml."

    else

        # ----------------------------------------------------
        # Ищем volumes: и добавляем mount после него.
        # ----------------------------------------------------

        if grep -qE '^[[:space:]]*volumes:[[:space:]]*$' "$DOCKER_COMPOSE_FILE"; then

            local tmp_compose
            tmp_compose=$(mktemp)

            awk -v mount="$zapret_mount" '
                BEGIN {
                    added=0
                }

                {
                    print

                    if (!added && $0 ~ /^[[:space:]]*volumes:[[:space:]]*$/) {
                        print mount
                        added=1
                    }
                }

                END {
                    if (!added) {
                        exit 1
                    }
                }
            ' "$DOCKER_COMPOSE_FILE" >"$tmp_compose"

            if [[ $? -eq 0 ]]; then

                cp "$tmp_compose" "$DOCKER_COMPOSE_FILE"
                rm -f "$tmp_compose"

                msg_ok "Mount zapret.dat добавлен в docker-compose.yml."

            else

                rm -f "$tmp_compose"

                msg_error "Не удалось добавить mount zapret.dat."
                return 1
            fi

        else

            msg_error "В docker-compose.yml не найден раздел volumes."
            return 1
        fi
    fi


    # --------------------------------------------------------
    # Применяем изменение compose.
    # --------------------------------------------------------

    msg_info "Применение изменений Docker Compose..."

    cd "$REMNANODE_DIR" || return 1

    if docker compose up -d; then

        msg_ok "Docker Compose обновлён."
        return 0

    else

        msg_error "Не удалось применить Docker Compose."
        return 1
    fi
}


# ============================================================
# 10. SELFSTEAL
# ============================================================

install_selfsteal() {

    msg_title "10. Установка Selfsteal"

    STATUS[10]="RUNNING"

    local selfsteal_installer
    selfsteal_installer=$(mktemp)

    msg_info "Скачивание установщика Selfsteal..."

    if ! download_file \
        "$SELFSTEAL_INSTALLER_URL" \
        "$selfsteal_installer"; then

        msg_error "Ошибка скачивания Selfsteal."

        rm -f "$selfsteal_installer"

        STATUS[10]="FAILED"
        return
    fi

    sed -i 's/\r$//' "$selfsteal_installer"
    chmod +x "$selfsteal_installer"

    echo
    msg_info "Запуск Selfsteal installer..."
    echo

    if bash "$selfsteal_installer" @ install \
        </dev/tty \
        >/dev/tty \
        2>/dev/tty; then

        msg_ok "Selfsteal установлен."
        STATUS[10]="OK"

    else

        msg_error "Ошибка установки Selfsteal."
        STATUS[10]="FAILED"
    fi

    rm -f "$selfsteal_installer"
}


# ============================================================
# REPORT 1-8
# ============================================================

show_report_1_to_8() {

    msg_title "Результат выполнения 1–8"

    printf "%-4s │ %-52s │ %s\n" "#" "Задача" "Статус"
    printf '%s\n' "─────┼──────────────────────────────────────────────────────┼────────"

    printf "%-4s │ %-52s │ " "1" "Отключить fwupd"
    status_text "${STATUS[1]}"

    printf "%-4s │ %-52s │ " "2" "apt update + доступные обновления"
    status_text "${STATUS[2]}"

    printf "%-4s │ %-52s │ " "3" "Отключить IPv6"
    status_text "${STATUS[3]}"

    printf "%-4s │ %-52s │ " "4" "Настроить BBR"
    status_text "${STATUS[4]}"

    printf "%-4s │ %-52s │ " "5" "Установить Zapret"
    status_text "${STATUS[5]}"

    printf "%-4s │ %-52s │ " "6" "Установить WARP"
    status_text "${STATUS[6]}"

    printf "%-4s │ %-52s │ " "7" "Настроить UFW"
    status_text "${STATUS[7]}"

    printf "%-4s │ %-52s │ " "8" "Установить Fail2Ban"
    status_text "${STATUS[8]}"

    echo
}


# ============================================================
# FINAL REPORT
# ============================================================

show_final_report() {

    msg_title "Финальный отчёт"

    printf "%-4s │ %-52s │ %s\n" "#" "Задача" "Статус"
    printf '%s\n' "─────┼──────────────────────────────────────────────────────┼────────"

    printf "%-4s │ %-52s │ " "1" "Отключить fwupd"
    status_text "${STATUS[1]}"

    printf "%-4s │ %-52s │ " "2" "apt update + доступные обновления"
    status_text "${STATUS[2]}"

    printf "%-4s │ %-52s │ " "3" "Отключить IPv6"
    status_text "${STATUS[3]}"

    printf "%-4s │ %-52s │ " "4" "Настроить BBR"
    status_text "${STATUS[4]}"

    printf "%-4s │ %-52s │ " "5" "Установить Zapret"
    status_text "${STATUS[5]}"

    printf "%-4s │ %-52s │ " "6" "Установить WARP"
    status_text "${STATUS[6]}"

    printf "%-4s │ %-52s │ " "7" "Настроить UFW"
    status_text "${STATUS[7]}"

    printf "%-4s │ %-52s │ " "8" "Установить Fail2Ban"
    status_text "${STATUS[8]}"

    printf "%-4s │ %-52s │ " "9" "Установить RemnaNode"
    status_text "${STATUS[9]}"

    printf "%-4s │ %-52s │ " "10" "Установить Selfsteal"
    status_text "${STATUS[10]}"

    echo
}


# ============================================================
# 11. INSTALL 1-9
# ============================================================

install_1_to_9() {

    msg_title "11. Автоматическая установка"

    ZAPRET_SELECTED_IN_11=false

    echo "Будут выполнены:"
    echo
    echo "  1. Отключение fwupd"
    echo "  2. apt update + доступные обновления"
    echo "  3. Отключение IPv6"
    echo "  4. Настройка BBR"
    echo "  5. Zapret"
    echo "  6. WARP"
    echo "  7. UFW"
    echo "  8. Fail2Ban"
    echo "  9. RemnaNode"
    echo

    read -rp "Продолжить установку 1–9? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[YyДд]$ ]]; then
        msg_warn "Установка отменена."
        return
    fi


    # --------------------------------------------------------
    # 1
    # --------------------------------------------------------

    disable_fwupd


    # --------------------------------------------------------
    # 2
    # --------------------------------------------------------

    apt_update_show_upgrades


    # --------------------------------------------------------
    # 3
    # --------------------------------------------------------

    disable_ipv6


    # --------------------------------------------------------
    # 4
    # --------------------------------------------------------

    configure_bbr


    # --------------------------------------------------------
    # 5 — ZAPRET
    # --------------------------------------------------------

    echo
    read -rp "Установить Zapret? [y/N]: " install_zapret_confirm

    if [[ "$install_zapret_confirm" =~ ^[YyДд]$ ]]; then

        ZAPRET_SELECTED_IN_11=true

        install_zapret

    else

        STATUS[5]="SKIPPED"

        msg_info "Zapret пропущен."
    fi


    # --------------------------------------------------------
    # 6 — WARP
    # --------------------------------------------------------

    echo
    read -rp "Установить WARP? [y/N]: " install_warp_confirm

    if [[ "$install_warp_confirm" =~ ^[YyДд]$ ]]; then

        install_warp

    else

        STATUS[6]="SKIPPED"

        msg_info "WARP пропущен."
    fi


    # --------------------------------------------------------
    # 7 — UFW
    # --------------------------------------------------------

    echo
    read -rp "Настроить UFW? [y/N]: " install_ufw_confirm

    if [[ "$install_ufw_confirm" =~ ^[YyДд]$ ]]; then

        configure_ufw

    else

        STATUS[7]="SKIPPED"

        msg_info "UFW пропущен."
    fi


    # --------------------------------------------------------
    # 8
    # --------------------------------------------------------

    install_fail2ban


    # --------------------------------------------------------
    # REPORT 1-8
    # --------------------------------------------------------

    show_report_1_to_8

    echo

    read -rp "Продолжить установку RemnaNode? [y/N]: " install_node_confirm

    if [[ ! "$install_node_confirm" =~ ^[YyДд]$ ]]; then

        STATUS[9]="SKIPPED"

        msg_warn "Установка RemnaNode отменена."
        show_final_report

        return
    fi


    # --------------------------------------------------------
    # 9 — REMNANODE
    # --------------------------------------------------------

    install_remnanode


    # --------------------------------------------------------
    # ZAPRET MOUNT
    #
    # Выполняется ТОЛЬКО если:
    #
    # 1. пользователь в пункте 11 подтвердил Zapret;
    # 2. RemnaNode установлен успешно.
    # --------------------------------------------------------

    if [[ "$ZAPRET_SELECTED_IN_11" == true &&
          "${STATUS[9]}" == "OK" ]]; then

        if add_zapret_mount_to_compose; then
            msg_ok "Zapret подключён к контейнеру RemnaNode."
        else
            msg_error "Не удалось подключить zapret.dat к RemnaNode."
        fi

    fi


    # --------------------------------------------------------
    # FINAL REPORT
    # --------------------------------------------------------

    show_final_report

    echo
    msg_ok "Автоматическая установка завершена."
}


# ============================================================
# MAIN MENU
# ============================================================

while true; do

    clear

    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}              RemnaNode Bootstrap Installer${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo

    echo "  1) Отключить fwupd"
    echo "  2) apt update + показать обновления"
    echo "  3) Отключить IPv6"
    echo "  4) Настроить BBR"
    echo "  5) Установить Zapret"
    echo "  6) Установить WARP"
    echo "  7) Настроить UFW"
    echo "  8) Установить Fail2Ban"
    echo "  9) Установить RemnaNode"
    echo " 10) Установить Selfsteal"
    echo " 11) Выполнить установку 1–9"
    echo
    echo "  0) Выход"
    echo

    read -rp "Выберите пункт: " choice

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
            install_1_to_9
            ;;

        0)
            echo
            msg_info "Выход."
            exit 0
            ;;

        *)
            msg_error "Неверный пункт меню."
            sleep 1
            ;;

    esac

done
```
