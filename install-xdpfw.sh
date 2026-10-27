#!/usr/bin/env bash
# =============================================================================
#  xdpfw — XDP-файрвол для VPS с remnanode в Docker (Ubuntu 24.04)
#
#  Политика:
#   * всё входящее закрыто (TCP/UDP), кроме ответов на исходящие соединения сервера
#   * SSH 22: только список IP (или всем — выбирается при установке и в меню)
#   * TCP 1433 (порт ноды Remnawave): только один IP (меняется в меню)
#   * TCP 443: открыт для всех, а дальше три независимых защиты:
#       1) антифлуд обычных IP: лимиты пакетов/соединений на IP -> блокировка на 443
#          (по умолчанию режим «Высокий»: 800 пакетов, 25 SYN в секунду)
#       2) лимит одновременно допущенных IP вне whitelist (по умолчанию 50 на каждый
#          IP-адрес интерфейса, например ens3; время освобождения слота — 1 с)
#       3) отдельный антифлуд для whitelist (свои лимиты, своё время блокировки, вкл/выкл)
#   * Whitelist (24 ч) = IP, которых Xray реально авторизовал (stats API, без логов):
#     опрос каждые 2 с, запись в whitelist обновляется раз в час
#   * UDP для whitelist (по умолчанию порт 443): когда ВЫКЛ — входящий UDP закрыт для всех;
#     когда ВКЛ — открыт только для IP из whitelist (порт и адрес VPS меняются в меню).
#   * Ограничение скорости в ОБЕ стороны (настоящий shaping: пакеты ставятся в очередь, а не отбрасываются):
#     исходящий трафик (VPS -> IP) — tc egress + fq; входящий (IP -> VPS) — tc ingress + IFB + fq.
#     Направления считаются раздельно и не суммируются. По умолчанию ограничение скорости ВЫКЛЮЧЕНО
#     (tc-программы тогда не загружаются и не нагружают систему); включается в xdpfw-menu, пункт 13.
#       [A] средняя скорость за скользящее окно (60 мин) > 50 Мбит/с (≈22.5 ГБ) В ЛЮБУЮ сторону
#           -> 25 Мбит/с в каждую сторону на 24 ч
#       [B] общий лимит скорости на каждый IP (по умолчанию 250 Мбит/с в каждую сторону, выключен)
#       [C] входящий трафик можно отключить (shape_upload=no) — тогда ограничивается только исходящий
#     все параметры и вкл/выкл — в xdpfw-menu; состояние переживает перезапуск и перезагрузку
#
#  Запуск:            sudo bash install-xdpfw.sh
#  Без вопросов:      sudo SSH_MODE=list bash install-xdpfw.sh   (UDP для whitelist по умолчанию выключен;
#                     включить сразу: UDP443=yes UDP_PORT=443 UDP_IP=any)
#  Без авто-отката:   sudo SAFE_MODE=0 bash install-xdpfw.sh
#  Меню после установки:  sudo xdpfw-menu
# =============================================================================
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Запустите от root: sudo bash $0"; exit 1; }

SAFE_MODE="${SAFE_MODE:-1}"
SRC=/opt/xdpfw
LIBDIR=/usr/local/lib/xdpfw
CONF_DIR=/etc/xdpfw
CONF=$CONF_DIR/xdpfw.conf

SSH_DEFAULT_IPS=(
  5.189.21.45 138.124.51.232 171.22.114.40 178.236.253.135 178.236.253.146
  31.77.114.251 31.77.114.252 194.124.210.87 185.236.24.140 46.48.37.11
)
MSSQL_DEFAULT_IP="45.148.127.244"

ask() {  # ask "вопрос" "значение по умолчанию"
  local a=""
  if [[ -z "${NONINTERACTIVE:-}" ]] && ( : </dev/tty ) 2>/dev/null; then
    printf '%s' "$1" >&2
    read -r a </dev/tty || a=""
  fi
  echo "${a:-$2}"
}

echo "[1/8] Установка зависимостей"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y build-essential clang llvm libbpf-dev libelf-dev zlib1g-dev iproute2 python3 socat
command -v docker >/dev/null 2>&1 || echo "    ВНИМАНИЕ: docker не найден — whitelist из Xray работать не будет."

echo "[2/8] Сетевой интерфейс и ваш SSH-IP"
IFACE="${IFACE:-$(ip -o route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"
if [[ -z "$IFACE" ]]; then
  echo "Не удалось определить интерфейс. Запустите так: sudo IFACE=ens3 bash $0"
  exit 1
fi
echo "    интерфейс: $IFACE"

SSH_IP="${SSH_CLIENT:-}"
SSH_IP="${SSH_IP%% *}"
if [[ -z "$SSH_IP" ]]; then
  SSH_IP="$(who -m 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' || true)"
fi
[[ "$SSH_IP" =~ ^[0-9a-fA-F:.]+$ ]] || SSH_IP=""

echo "[3/8] Настройки"
mkdir -p "$CONF_DIR" "$SRC" "$LIBDIR" /var/lib/xdpfw

# конфиг старого формата (без ssh_mode) не подходит: сохраняем копию и создаём новый
if [[ -f "$CONF" ]] && ! grep -q '^ssh_mode=' "$CONF"; then
  BAK="$CONF.legacy-$(date +%Y%m%d-%H%M%S)"
  cp -p "$CONF" "$BAK"
  rm -f "$CONF"
  echo "    найден конфиг старого формата — сохранён как $BAK, создаю новый"
fi

if [[ -f "$CONF" ]]; then
  echo "    найден $CONF — сохраняю существующие настройки (менять: xdpfw-menu)"
  # исправления параметров, оставшихся от прежних версий
  sed -i \
    -e 's/^bridge_port=18086$/bridge_port=18085/' \
    -e 's/^poll_interval=5$/poll_interval=2/' \
    -e 's/^xray_container=auto$/xray_container=remnanode/' \
    -e 's|^xray_bin=auto$|xray_bin=/usr/local/bin/xray|' \
    -e 's/^flood_packets=300$/flood_packets=800/' \
    -e 's/^flood_syn=10$/flood_syn=25/' \
    -e 's/^ip_limit_idle=30$/ip_limit_idle=1/' \
    -e '/^flood_skip_whitelisted=/d' \
    "$CONF"
  add_default() { grep -q "^$1=" "$CONF" || echo "$1=$2" >> "$CONF"; }
  add_default whitelist_refresh_minutes 60
  add_default flood_window 1
  add_default flood_packets 800
  add_default flood_syn 25
  add_default wl_flood no
  add_default wl_flood_window 1
  add_default wl_flood_packets 150000
  add_default wl_flood_syn 300
  add_default wl_ban_minutes 10
  add_default ip_limit yes
  add_default ip_limit_per_dst yes
  add_default ip_limit_max 50
  add_default ip_limit_idle 1
  add_default bridge_port 18085
  add_default poll_interval 2
  add_default shape_auto no
  add_default shape_window_min 60
  add_default shape_avg_mbps 50
  add_default shape_penalty_mbps 25
  add_default shape_penalty_hours 24
  add_default shape_ip_cap no
  add_default shape_ip_cap_mbps 250
  add_default shape_upload no
  add_default shape_port 443
  add_default udp_port 443
  add_default udp_ip any
  add_default shape_max_delay_ms 2000
  add_default shape_check_sec 10
else
  # UDP для whitelist по умолчанию ВЫКЛЮЧЕН (включается в xdpfw-menu, пункт 11, или переменными UDP443=yes UDP_PORT= UDP_IP=)
  UDP443="${UDP443:-no}"
  UDP_PORT="${UDP_PORT:-443}"
  UDP_IP="${UDP_IP:-any}"
  if [[ "$UDP443" == "yes" ]]; then
    EPH_LO=32768; EPH_HI=60999
    read -r EPH_LO EPH_HI < /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || true
    if ! [[ "$UDP_PORT" =~ ^[0-9]+$ ]] || (( UDP_PORT < 1 || UDP_PORT > 65535 )); then
      echo "    некорректный UDP-порт '$UDP_PORT' — использую 443"; UDP_PORT=443
    elif (( UDP_PORT >= EPH_LO && UDP_PORT <= EPH_HI )); then
      echo "    порт $UDP_PORT входит в диапазон эфемерных портов ($EPH_LO-$EPH_HI) — использую 443"; UDP_PORT=443
    fi
    case "${UDP_IP,,}" in all|"*") UDP_IP=any ;; esac
    if [[ "$UDP_IP" != "any" ]] && ! python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$UDP_IP" 2>/dev/null; then
      echo "    '$UDP_IP' — не IP-адрес, UDP будет открыт на любом адресе VPS"; UDP_IP=any
    fi
  fi
  SSH_MODE="${SSH_MODE:-}"
  if [[ -z "$SSH_MODE" ]]; then
    a="$(ask "    SSH (22): 1) только список IP  2) всем  [1]: " "1")"
    [[ "$a" == "2" ]] && SSH_MODE="all" || SSH_MODE="list"
  fi

  ADD_ME=""
  if [[ "$SSH_MODE" == "list" && -n "$SSH_IP" ]]; then
    in_list=0
    for ip in "${SSH_DEFAULT_IPS[@]}"; do [[ "$ip" == "$SSH_IP" ]] && in_list=1; done
    if [[ $in_list -eq 0 ]]; then
      echo "    ВНИМАНИЕ: IP вашей сессии ($SSH_IP) не входит в список SSH — после запуска вас отключит."
      a="$(ask "    Добавить $SSH_IP в список SSH? [Y/n]: " "y")"
      if [[ "$a" =~ ^[yY] ]]; then ADD_ME="$SSH_IP"; fi
    fi
  fi

  {
    echo "# ===== xdpfw: конфигурация (удобнее менять через xdpfw-menu) ====="
    echo "iface=$IFACE"
    echo
    echo "# SSH 22: list = только allow_ssh, all = всем"
    echo "ssh_mode=$SSH_MODE"
    for ip in "${SSH_DEFAULT_IPS[@]}"; do echo "allow_ssh=$ip"; done
    [[ -n "$ADD_ME" ]] && echo "allow_ssh=$ADD_ME"
    echo
    echo "# TCP 1433 (порт ноды Remnawave) — только с этого IP"
    echo "allow_1433=$MSSQL_DEFAULT_IP"
    echo
    echo "# UDP для IP из whitelist: yes = открыт только для whitelist, no = входящий UDP закрыт для всех"
    echo "udp443_whitelist=$UDP443"
    echo "# порт UDP (по умолчанию 443; не из диапазона эфемерных портов)"
    echo "udp_port=$UDP_PORT"
    echo "# адрес этого VPS, на котором открыт UDP-порт: IP или any (любой адрес сервера)"
    echo "udp_ip=$UDP_IP"
    echo
    echo "# Whitelist: на сколько часов добавляется IP и как часто (минуты) продлевается запись у тех, кто уже онлайн"
    echo "whitelist_hours=24"
    echo "whitelist_refresh_minutes=60"
    echo
    echo "# --- Антифлуд обычных IP (вне whitelist) на TCP 443, лимиты для каждого IP отдельно ---"
    echo "#   flood_packets — макс. пакетов за окно (0 = защита выключена),"
    echo "#   flood_syn — макс. новых соединений за окно, flood_window — длина окна, секунды"
    echo "#   По умолчанию режим «Высокий»: 800 пакетов, 25 SYN за 1 с"
    echo "flood_window=1"
    echo "flood_packets=800"
    echo "flood_syn=25"
    echo "# На сколько минут блокируется IP на 443 при флуде"
    echo "ban_minutes=60"
    echo
    echo "# --- Отдельный антифлуд для IP из whitelist (yes/no) со своими лимитами и своей блокировкой ---"
    echo "# Выключен: whitelist вообще не проверяется на флуд."
    echo "wl_flood=no"
    echo "wl_flood_window=1"
    echo "wl_flood_packets=150000"
    echo "wl_flood_syn=300"
    echo "wl_ban_minutes=10"
    echo
    echo "# --- Лимит IP на TCP 443: пакеты пропускаются не более чем от ip_limit_max разных IP ---"
    echo "# IP из whitelist не считаются и всегда в приоритете, остальные сверх лимита дропаются."
    echo "# ip_limit_per_dst=yes — лимит ip_limit_max считается отдельно для каждого IP-адреса в $IFACE."
    echo "# ip_limit_per_dst=no  — общий лимит ip_limit_max на весь интерфейс $IFACE."
    echo "# Слот IP освобождается, если от него нет пакетов ip_limit_idle секунд (по умолчанию 1 с)."
    echo "ip_limit=yes"
    echo "ip_limit_per_dst=yes"
    echo "ip_limit_max=50"
    echo "ip_limit_idle=1"
    echo
    echo "# --- Ограничение скорости в обе стороны (traffic shaping: очередь fq, а не drop) ---"
    echo "# Исходящий трафик: байты, которые VPS отправил этому IP с порта shape_port (download клиента)."
    echo "# Входящий трафик: байты, которые этот IP прислал на порт shape_port (upload клиента); ограничивается через IFB."
    echo "# Направления считаются раздельно и не суммируются."
    echo "# [A] Автоограничение: средняя скорость за окно shape_window_min минут выше shape_avg_mbps в ЛЮБУЮ сторону"
    echo "#     (50 Мбит/с в среднем за 60 мин = 22.5 ГБ) -> IP режется до shape_penalty_mbps В КАЖДУЮ СТОРОНУ на shape_penalty_hours часов."
    echo "shape_auto=no"
    echo "shape_window_min=60"
    echo "shape_avg_mbps=50"
    echo "shape_penalty_mbps=25"
    echo "shape_penalty_hours=24"
    echo "# [B] Лимит скорости для КАЖДОГО IP (yes/no) и его значение — действует на каждое направление отдельно"
    echo "shape_ip_cap=no"
    echo "shape_ip_cap_mbps=250"
    echo "# [C] Учитывать и ограничивать входящий трафик (IP -> VPS). no — только исходящий."
    echo "shape_upload=no"
    echo "# порт VPN на VPS, максимальная очередь на IP (дольше — отбрасывается, как переполнение буфера), период проверки"
    echo "shape_port=443"
    echo "shape_max_delay_ms=2000"
    echo "shape_check_sec=10"
    echo
    echo "# --- Опрос Xray ---"
    echo "xray_container=remnanode"
    echo "xray_bin=/usr/local/bin/xray"
    echo "# Копия xray CLI на хосте (берётся из контейнера), чтобы не вызывать docker exec"
    echo "xray_cli=/usr/local/lib/xdpfw/xray-cli"
    echo "bridge_port=18085"
    echo "poll_interval=2"
  } > "$CONF"
  echo "    создан $CONF (UDP для whitelist: $UDP443, порт $UDP_PORT, адрес $UDP_IP; SSH: $SSH_MODE)"
fi

echo "[4/8] Исходники"
cat > "$SRC/xdpfw.bpf.c" <<'BPF_EOF'
// SPDX-License-Identifier: GPL-2.0
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

/* IPv4 хранится как IPv4-mapped IPv6 (::ffff:a.b.c.d) */
struct addr_key { __u8 a[16]; };
struct slot_key {
    struct addr_key src;
    struct addr_key dst; /* при ip_limit_per_dst=1 — локальный IP VPS, иначе нули */
};
struct acl_key  { struct addr_key ip; __u16 port; __u16 pad; };
struct fl       { __u64 start_ns; __u32 pkts; __u32 syns; };
struct fwcfg {
    __u32 eph_lo, eph_hi;
    __u32 ssh_open, udp443_wl;
    __u32 flood_pkts, flood_syn;
    __u32 wl_flood, wl_flood_pkts;
    __u32 wl_flood_syn, ip_limit;
    __u32 ip_limit_max, udp_port;      /* udp_port: порт UDP для whitelist (по умолчанию 443) */
    __u32 udp_ip_set, ip_limit_per_dst;/* udp_ip_set=1: только на udp_ip; ip_limit_per_dst=1: лимит IP на каждый адрес интерфейса */
    __u8  udp_ip[16];                  /* IPv4 как ::ffff:a.b.c.d */
    __u64 flood_window_ns, ban_ns;
    __u64 wl_flood_window_ns, wl_ban_ns;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, struct addr_key);
    __type(value, __u64);              /* monotonic ns, до которого IP в whitelist */
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} whitelist SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, struct addr_key);
    __type(value, __u64);              /* monotonic ns, до которого IP заблокирован на 443 */
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} banlist SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 131072);
    __type(key, struct addr_key);
    __type(value, struct fl);          /* счётчики пакетов/SYN в текущем окне */
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} flood SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, struct slot_key);
    __type(value, __u64);              /* слоты лимита IP: когда IP последний раз присылал пакет */
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} slots SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 4096);
    __type(key, struct addr_key);
    __type(value, __u32);              /* сколько слотов занято на каждом IP интерфейса (пересчитывает демон) */
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} ip_cnt SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, struct acl_key);
    __type(value, __u8);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} acl_tcp SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct fwcfg);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} fw_cfg SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} fw_drops SEC(".maps");

static __always_inline int addr_eq(const __u8 *a, const __u8 *b)
{
    __u64 a0, a1, b0, b1;
    __builtin_memcpy(&a0, a, 8);
    __builtin_memcpy(&a1, a + 8, 8);
    __builtin_memcpy(&b0, b, 8);
    __builtin_memcpy(&b1, b + 8, 8);
    return a0 == b0 && a1 == b1;
}

static __always_inline int do_drop(void)
{
    __u32 k = 0;
    __u64 *c = bpf_map_lookup_elem(&fw_drops, &k);
    if (c)
        (*c)++;
    return XDP_DROP;
}

SEC("xdp")
int xdp_fw(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    struct ethhdr *eth = data;
    struct addr_key src = {};
    struct addr_key dst = {};          /* адрес назначения (этого VPS) */
    void *l4 = 0;
    __u8 proto = 0;
    __u32 zero = 0;

    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto == bpf_htons(ETH_P_IP)) {
        struct iphdr *ip = (void *)(eth + 1);
        if ((void *)(ip + 1) > data_end)
            return XDP_PASS;
        __u32 hl = ip->ihl * 4;
        if (hl < sizeof(*ip))
            return XDP_PASS;
        /* не первый фрагмент: L4-заголовка нет, пропускаем */
        if (ip->frag_off & bpf_htons(0x1FFF))
            return XDP_PASS;
        l4 = (void *)ip + hl;
        proto = ip->protocol;
        src.a[10] = 0xff;
        src.a[11] = 0xff;
        __builtin_memcpy(&src.a[12], &ip->saddr, 4);
        dst.a[10] = 0xff;
        dst.a[11] = 0xff;
        __builtin_memcpy(&dst.a[12], &ip->daddr, 4);
    } else if (eth->h_proto == bpf_htons(ETH_P_IPV6)) {
        struct ipv6hdr *ip6 = (void *)(eth + 1);
        if ((void *)(ip6 + 1) > data_end)
            return XDP_PASS;
        proto = ip6->nexthdr;
        /* extension headers: иначе их можно использовать для обхода фильтра */
        if (proto == 0 || proto == 43 || proto == 44 || proto == 60)
            return do_drop();
        l4 = ip6 + 1;
        __builtin_memcpy(src.a, &ip6->saddr, 16);
        __builtin_memcpy(dst.a, &ip6->daddr, 16);
    } else {
        return XDP_PASS;                /* ARP и прочее */
    }

    if (proto != IPPROTO_TCP && proto != IPPROTO_UDP)
        return XDP_PASS;                /* ICMP и т.п. */

    __u64 now = bpf_ktime_get_ns();
    struct fwcfg *cfg = bpf_map_lookup_elem(&fw_cfg, &zero);

    /* эфемерные порты = ответы на исходящие соединения сервера */
    __u32 lo = cfg ? cfg->eph_lo : 32768;
    __u32 hi = cfg ? cfg->eph_hi : 60999;

    if (proto == IPPROTO_TCP) {
        struct tcphdr *tcp = l4;
        if ((void *)(tcp + 1) > data_end)
            return do_drop();
        __u32 dport = bpf_ntohs(tcp->dest);
        int is_syn = tcp->syn && !tcp->ack;

        if (dport == 443) {
            /* бан касается только 443: админский SSH/1433 он не трогает */
            __u64 *ban = bpf_map_lookup_elem(&banlist, &src);
            if (ban && *ban > now)
                return do_drop();
            if (!cfg)
                return XDP_PASS;

            __u32 lim_pkts = 0, lim_syn = 0;
            __u64 win_ns = 0, ban_ns = 0;
            __u64 *wl = bpf_map_lookup_elem(&whitelist, &src);

            if (wl && *wl > now) {
                /* whitelist: приоритет, в лимите IP не участвует, свой антифлуд (если включён) */
                if (cfg->wl_flood) {
                    lim_pkts = cfg->wl_flood_pkts;
                    lim_syn = cfg->wl_flood_syn;
                    win_ns = cfg->wl_flood_window_ns;
                    ban_ns = cfg->wl_ban_ns;
                }
            } else {
                /* лимит числа допущенных IP вне whitelist (для каждого IP интерфейса или общий) */
                if (cfg->ip_limit && cfg->ip_limit_max) {
                    struct slot_key sk = { .src = src };
                    struct addr_key ck = {};
                    if (cfg->ip_limit_per_dst) {
                        sk.dst = dst;
                        ck = dst;
                    }
                    __u64 *seen = bpf_map_lookup_elem(&slots, &sk);
                    if (seen) {
                        /* обновляем метку не чаще 10 раз в секунду (шаг 100 мс для точного idle=1 с) */
                        if (now - *seen > 100000000ULL)
                            *seen = now;
                    } else {
                        __u32 *cnt = bpf_map_lookup_elem(&ip_cnt, &ck);
                        if (!cnt) {
                            __u32 init_cnt = 0;
                            bpf_map_update_elem(&ip_cnt, &ck, &init_cnt, BPF_NOEXIST);
                            cnt = bpf_map_lookup_elem(&ip_cnt, &ck);
                        }
                        if (!cnt || *cnt >= cfg->ip_limit_max)
                            return do_drop();
                        if (bpf_map_update_elem(&slots, &sk, &now, BPF_NOEXIST) == 0)
                            __sync_fetch_and_add(cnt, 1);
                    }
                }
                lim_pkts = cfg->flood_pkts;
                lim_syn = cfg->flood_syn;
                win_ns = cfg->flood_window_ns;
                ban_ns = cfg->ban_ns;
            }

            if (lim_pkts) {
                struct fl *f = bpf_map_lookup_elem(&flood, &src);
                if (!f) {
                    struct fl nf = { .start_ns = now };
                    bpf_map_update_elem(&flood, &src, &nf, BPF_NOEXIST);
                    f = bpf_map_lookup_elem(&flood, &src);
                }
                if (f) {
                    if (now - f->start_ns >= win_ns) {
                        f->start_ns = now;
                        f->pkts = 0;
                        f->syns = 0;
                    }
                    __sync_fetch_and_add(&f->pkts, 1);
                    if (is_syn)
                        __sync_fetch_and_add(&f->syns, 1);
                    __u32 p = f->pkts;
                    __u32 s = f->syns;
                    if (p > lim_pkts || (lim_syn && s > lim_syn)) {
                        __u64 exp = now + ban_ns;
                        bpf_map_update_elem(&banlist, &src, &exp, BPF_ANY);
                        return do_drop();
                    }
                }
            }
            return XDP_PASS;
        }

        if (dport == 22 && cfg && cfg->ssh_open)
            return XDP_PASS;

        struct acl_key k = {};
        k.ip = src;
        k.port = dport;
        if (bpf_map_lookup_elem(&acl_tcp, &k))
            return XDP_PASS;

        if (dport < lo || dport > hi)   /* порт сервиса, не разрешён -> drop */
            return do_drop();
        if (is_syn)                     /* новое входящее соединение на эфемерный порт */
            return do_drop();
        return XDP_PASS;                /* ответ на исходящее соединение */
    }

    /* UDP: когда udp443_wl выключен — входящий UDP закрыт для всех (кроме ответов DNS/NTP и DHCP) */
    struct udphdr *udp = l4;
    if ((void *)(udp + 1) > data_end)
        return do_drop();
    __u32 dport = bpf_ntohs(udp->dest);
    __u32 sport = bpf_ntohs(udp->source);

    if (cfg && cfg->udp443_wl && dport == cfg->udp_port &&
        (!cfg->udp_ip_set || addr_eq(dst.a, cfg->udp_ip))) {
        __u64 *ban = bpf_map_lookup_elem(&banlist, &src);
        if (ban && *ban > now)
            return do_drop();
        __u64 *exp = bpf_map_lookup_elem(&whitelist, &src);
        if (exp && *exp > now)
            return XDP_PASS;
        return do_drop();
    }
    if (dport == 443 || (cfg && dport == cfg->udp_port))
        return do_drop();               /* UDP-порт закрыт для всех, если правило выше не сработало */
    if ((sport == 67 && dport == 68) || (sport == 547 && dport == 546))
        return XDP_PASS;                /* DHCPv4 / DHCPv6 */
    if ((sport == 53 || sport == 123) && dport >= lo && dport <= hi)
        return XDP_PASS;                /* ответы DNS (53) и NTP (123) на исходящие запросы сервера */
    return do_drop();
}

char LICENSE[] SEC("license") = "GPL";
BPF_EOF

cat > "$SRC/xdpfw_tc.bpf.c" <<'TC_BPF_EOF'
// SPDX-License-Identifier: GPL-2.0
/*
 * xdpfw_tc — tc-программы на физическом интерфейсе: учёт и ограничение скорости в обе стороны.
 *
 *   tc_egress  (egress  физического интерфейса): VPS -> клиент ("исходящий", download клиента).
 *              Считаются пакеты с портом ОТПРАВИТЕЛЯ = порт VPN (по умолчанию 443), ключ — IP назначения.
 *   tc_ingress (ingress физического интерфейса): клиент -> VPS ("входящий", upload клиента).
 *              Считаются пакеты с портом ПОЛУЧАТЕЛЯ = порт VPN, ключ — IP отправителя.
 *
 * Направления учитываются НЕЗАВИСИМО: у каждого свои счётчики (bw_ip / bw_ip_in) и своя история.
 *
 * Ограничение скорости — настоящий shaping, а не policing: программа не отбрасывает пакеты "по скорости",
 * а выставляет им время отправки (EDT, skb->tstamp); пакеты ждут в очереди qdisc fq и уходят в
 * назначенное время. Для входящего трафика пакет перенаправляется в IFB-устройство с fq и после
 * задержки возвращается в сетевой стек. Отбрасывается лишь то, что не помещается в очередь
 * (задержка больше max_delay_ns) — как переполнение буфера в любом шейпере.
 * Пакеты, которым задержка не нужна (IP в пределах скорости), через IFB не идут.
 */
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define NB 60
#define IN_MARK 0x7d9f5a01u     /* метка "пакет уже прошёл через IFB": повторно не обрабатывать */

/* IPv4 хранится как IPv4-mapped IPv6 (::ffff:a.b.c.d) — так же, как в XDP-части */
struct addr_key { __u8 a[16]; };

struct bwip {
    struct bpf_spin_lock lock;
    __u32 pad;
    __u64 next_tx_ns;       /* когда можно пропускать следующий пакет этого IP (EDT) */
    __u64 total;            /* всего байт в этом направлении (растёт монотонно) */
};

struct hist {               /* пишет только демон: корзины скользящего окна */
    __u64 last_total;
    __u64 head;
    __u64 b[NB];
};

struct bwcfg {
    __u32 enabled;
    __u32 pen_cnt;          /* сколько IP сейчас оштрафовано (0 — карту штрафов не опрашиваем) */
    __u32 cap_on;           /* общий лимит скорости для каждого IP */
    __u32 port;             /* порт VPN: по нему определяем трафик, который считаем и ограничиваем */
    __u32 in_on;            /* ограничивать и входящий трафик (клиент -> VPS) */
    __u32 ifb_ifindex;      /* ifindex IFB-устройства (0 — входящий shaping недоступен) */
    __u64 pen_rate_bps;     /* скорость для нарушителей, бит/с (в каждую сторону) */
    __u64 cap_rate_bps;     /* общий лимит на IP, бит/с (в каждую сторону) */
    __u64 max_delay_ns;     /* максимальная очередь на IP */
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, struct addr_key);
    __type(value, struct bwip);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} bw_ip SEC(".maps");                   /* VPS -> IP */

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, struct addr_key);
    __type(value, struct bwip);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} bw_ip_in SEC(".maps");                /* IP -> VPS */

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 4096);
    __type(key, struct addr_key);
    __type(value, __u64);           /* monotonic ns, до которого IP ограничен (в обе стороны) */
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} bw_pen SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 16384);
    __uint(map_flags, BPF_F_NO_PREALLOC);
    __type(key, struct addr_key);
    __type(value, struct hist);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} bw_hist SEC(".maps");                 /* история VPS -> IP */

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 16384);
    __uint(map_flags, BPF_F_NO_PREALLOC);
    __type(key, struct addr_key);
    __type(value, struct hist);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} bw_hist_in SEC(".maps");              /* история IP -> VPS */

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct bwcfg);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} bw_cfg SEC(".maps");

/*
 * Разбор пакета. ingress=0: ключ — IP назначения, порт — порт отправителя.
 * ingress=1: ключ — IP отправителя, порт — порт получателя.
 * Возвращает 1, если это TCP/UDP-пакет, 0 — если он нас не касается.
 * *ctl = 1 для TCP SYN/FIN/RST (такие пакеты считаем, но не задерживаем).
 */
static __always_inline int parse_pkt(struct __sk_buff *skb, int ingress,
                                     struct addr_key *key, __u32 *port, int *ctl)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;
    void *l4;
    __u8 proto;

    *ctl = 0;
    if ((void *)(eth + 1) > data_end)
        return 0;

    if (eth->h_proto == bpf_htons(ETH_P_IP)) {
        struct iphdr *ip = (void *)(eth + 1);
        if ((void *)(ip + 1) > data_end)
            return 0;
        __u32 hl = ip->ihl * 4;
        if (hl < sizeof(*ip))
            return 0;
        if (ip->frag_off & bpf_htons(0x1FFF))
            return 0;                   /* не первый фрагмент: порта нет */
        l4 = (void *)ip + hl;
        proto = ip->protocol;
        key->a[10] = 0xff;
        key->a[11] = 0xff;
        __builtin_memcpy(&key->a[12], ingress ? &ip->saddr : &ip->daddr, 4);
    } else if (eth->h_proto == bpf_htons(ETH_P_IPV6)) {
        struct ipv6hdr *ip6 = (void *)(eth + 1);
        if ((void *)(ip6 + 1) > data_end)
            return 0;
        proto = ip6->nexthdr;
        l4 = ip6 + 1;
        __builtin_memcpy(key->a, ingress ? &ip6->saddr : &ip6->daddr, 16);
    } else {
        return 0;
    }

    if (proto == IPPROTO_TCP) {
        struct tcphdr *t = l4;
        if ((void *)(t + 1) > data_end)
            return 0;
        *port = bpf_ntohs(ingress ? t->dest : t->source);
        if (t->syn || t->fin || t->rst)
            *ctl = 1;
    } else if (proto == IPPROTO_UDP) {
        struct udphdr *u = l4;
        if ((void *)(u + 1) > data_end)
            return 0;
        *port = bpf_ntohs(ingress ? u->dest : u->source);
    } else {
        return 0;
    }
    return 1;
}

/*
 * Учёт пакета и расчёт времени его выпуска.
 * Возврат: -1 — очередь IP переполнена (пакет отбросить), 0 — задержка не нужна,
 * 1 — пакет надо выпустить в момент *t_out (> now).
 */
static __always_inline int bw_account(void *map, struct addr_key *key, struct bwcfg *cfg,
                                      __u64 now, __u32 len, __u64 ts, int shape, __u64 *t_out)
{
    struct bwip *st = bpf_map_lookup_elem(map, key);
    if (!st) {
        struct bwip fresh = {};
        bpf_map_update_elem(map, key, &fresh, BPF_NOEXIST);
        st = bpf_map_lookup_elem(map, key);
        if (!st)
            return 0;
    }

    /* какая скорость положена этому IP: штраф важнее общего лимита */
    __u64 rate = 0;
    if (cfg->pen_cnt) {
        __u64 *pen = bpf_map_lookup_elem(&bw_pen, key);
        if (pen && *pen > now)
            rate = cfg->pen_rate_bps;
    }
    if (!rate && cfg->cap_on)
        rate = cfg->cap_rate_bps;
    if (!shape)
        rate = 0;                       /* только считаем */

    int ret = 0;
    if (rate) {
        /* сколько "эфирного времени" занимает этот пакет на заданной скорости */
        __u64 cost = ((__u64)len * 8000000000ULL) / rate;
        __u64 t;
        int drop = 0;

        /* уже выставленное время отправки (TCP pacing) учитываем, но только разумное */
        if (ts <= now || ts - now > cfg->max_delay_ns)
            ts = 0;

        bpf_spin_lock(&st->lock);
        t = st->next_tx_ns;
        if (t < now)
            t = now;
        if (ts > t)
            t = ts;
        if (t - now > cfg->max_delay_ns)
            drop = 1;                   /* очередь этого IP переполнена */
        else
            st->next_tx_ns = t + cost;
        bpf_spin_unlock(&st->lock);

        if (drop)
            return -1;
        if (t > now) {
            *t_out = t;
            ret = 1;
        }
    }

    __sync_fetch_and_add(&st->total, (__u64)len);
    return ret;
}

SEC("tc")
int tc_egress(struct __sk_buff *skb)
{
    struct addr_key dst = {};
    __u32 port = 0;
    int ctl;
    __u32 zero = 0;

    if (!parse_pkt(skb, 0, &dst, &port, &ctl))
        return TC_ACT_OK;

    struct bwcfg *cfg = bpf_map_lookup_elem(&bw_cfg, &zero);
    if (!cfg || !cfg->enabled || port != cfg->port)
        return TC_ACT_OK;               /* не трафик VPN -> клиент */

    __u64 t = 0;
    int r = bw_account(&bw_ip, &dst, cfg, bpf_ktime_get_ns(), skb->len, skb->tstamp, 1, &t);
    if (r < 0)
        return TC_ACT_SHOT;
    if (r > 0)
        skb->tstamp = t;                /* fq отправит пакет не раньше этого времени */
    return TC_ACT_OK;
}

SEC("tc")
int tc_ingress(struct __sk_buff *skb)
{
    struct addr_key src = {};
    __u32 port = 0;
    int ctl;
    __u32 zero = 0;

    /* пакет вернулся из IFB после задержки: сбрасываем метку и пускаем дальше */
    if (skb->mark == IN_MARK) {
        skb->mark = 0;
        return TC_ACT_OK;
    }

    if (!parse_pkt(skb, 1, &src, &port, &ctl))
        return TC_ACT_OK;

    struct bwcfg *cfg = bpf_map_lookup_elem(&bw_cfg, &zero);
    if (!cfg || !cfg->enabled || port != cfg->port)
        return TC_ACT_OK;               /* не трафик клиент -> VPN */

    __u64 t = 0;
    /* tstamp на ingress — время приёма, а не время отправки: в расчёт не берём */
    int shape = cfg->in_on && cfg->ifb_ifindex;     /* иначе входящий трафик только считаем */
    int r = bw_account(&bw_ip_in, &src, cfg, bpf_ktime_get_ns(), skb->len, 0, shape, &t);
    if (r < 0)
        return TC_ACT_SHOT;
    if (r > 0 && !ctl) {
        /* SYN/FIN/RST не задерживаем: они малы, а задержка рукопожатия только вредит */
        if (bpf_skb_set_tstamp(skb, t, BPF_SKB_TSTAMP_DELIVERY_MONO))
            return TC_ACT_OK;
        skb->mark = IN_MARK;
        return bpf_redirect(cfg->ifb_ifindex, 0);
    }
    return TC_ACT_OK;
}

char LICENSE[] SEC("license") = "GPL";
TC_BPF_EOF

cat > "$SRC/xdpfw.c" <<'C_EOF'
// xdpfw — загрузчик XDP/tc-программ, демон и утилиты управления
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <linux/if_link.h>
#include <net/if.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define CFG_PATH      "/etc/xdpfw/xdpfw.conf"
#define OBJ_PATH      "/usr/local/lib/xdpfw/xdpfw.bpf.o"
#define TC_OBJ_PATH   "/usr/local/lib/xdpfw/xdpfw_tc.bpf.o"
#define PIN_DIR       "/sys/fs/bpf/xdpfw"
#define QDISC_HELPER  "/usr/local/sbin/xdpfw-qdisc"
#define STATE_DIR     "/var/lib/xdpfw"
#define STATE_FILE    "/var/lib/xdpfw/shape-state"
#define MAX_ALLOW     512
#define MAX_KNOWN     4096
#define NB            60                 /* число корзин скользящего окна */
#define SEC_NS        1000000000ULL

struct addr_key { uint8_t a[16]; };
struct slot_key {
    struct addr_key src;
    struct addr_key dst;
};
struct acl_key  { struct addr_key ip; uint16_t port; uint16_t pad; };
struct fwcfg {
    uint32_t eph_lo, eph_hi;
    uint32_t ssh_open, udp443_wl;
    uint32_t flood_pkts, flood_syn;
    uint32_t wl_flood, wl_flood_pkts;
    uint32_t wl_flood_syn, ip_limit;
    uint32_t ip_limit_max, udp_port;
    uint32_t udp_ip_set, ip_limit_per_dst;
    uint8_t  udp_ip[16];
    uint64_t flood_window_ns, ban_ns;
    uint64_t wl_flood_window_ns, wl_ban_ns;
};

/* --- структуры tc-программы (должны совпадать с xdpfw_tc.bpf.c) --- */
struct bwcfg {
    uint32_t enabled, pen_cnt, cap_on, port, in_on, ifb_ifindex;
    uint64_t pen_rate_bps, cap_rate_bps, max_delay_ns;
};
struct bwip  { uint32_t lock, pad; uint64_t next_tx_ns, total; };
struct hist  { uint64_t last_total, head, b[NB]; };

struct allow { struct addr_key ip; uint16_t port; };
struct config {
    char iface[IFNAMSIZ];
    int ssh_open, udp443_wl, wl_flood, ip_limit, ip_limit_per_dst;
    uint64_t udp_port;                  /* порт UDP для whitelist */
    int udp_ip_set;                     /* 1 — только на адресе udp_ip этого VPS */
    struct addr_key udp_ip;
    char udp_ip_txt[64];
    uint64_t wl_ttl, wl_refresh;
    uint64_t flood_window, flood_pkts, flood_syn, ban_sec;
    uint64_t wl_flood_window, wl_flood_pkts, wl_flood_syn, wl_ban_sec;
    uint64_t ip_limit_max, ip_limit_idle;
    /* ограничение скорости */
    int sh_auto, sh_cap, sh_up;
    uint64_t sh_window_min, sh_avg_mbps, sh_pen_mbps, sh_pen_hours;
    uint64_t sh_cap_mbps, sh_port, sh_delay_ms, sh_check;
    int n_allow;
    struct allow allow[MAX_ALLOW];
};

static volatile sig_atomic_t g_stop, g_reload;
static void on_sig(int s) { if (s == SIGHUP) g_reload = 1; else g_stop = 1; }

static uint64_t mono_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * SEC_NS + ts.tv_nsec;
}

static uint64_t real_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec;
}

static int parse_ip(const char *s, struct addr_key *k)
{
    struct in_addr a4;
    struct in6_addr a6;
    memset(k, 0, sizeof(*k));
    if (inet_pton(AF_INET, s, &a4) == 1) {
        k->a[10] = k->a[11] = 0xff;
        memcpy(&k->a[12], &a4, 4);
        return 0;
    }
    if (inet_pton(AF_INET6, s, &a6) == 1) {
        memcpy(k->a, &a6, 16);
        return 0;
    }
    return -1;
}

static const char *ip_str(const struct addr_key *k, char *buf, size_t n)
{
    static const uint8_t pre[12] = {0,0,0,0,0,0,0,0,0,0,0xff,0xff};
    if (!memcmp(k->a, pre, 12))
        inet_ntop(AF_INET, &k->a[12], buf, n);
    else
        inet_ntop(AF_INET6, k->a, buf, n);
    return buf;
}

/* loopback / 0.0.0.0 / multicast в whitelist не кладём */
static int is_special(const struct addr_key *k)
{
    static const uint8_t pre[12] = {0,0,0,0,0,0,0,0,0,0,0xff,0xff};
    static const uint8_t zero[16] = {0};
    if (!memcmp(k->a, pre, 12))
        return k->a[12] == 127 || k->a[12] == 0 || k->a[12] >= 224;
    if (!memcmp(k->a, zero, 15) && (k->a[15] == 0 || k->a[15] == 1))
        return 1;
    return k->a[0] == 0xff;
}

static char *trim(char *s)
{
    while (*s == ' ' || *s == '\t') s++;
    char *e = s + strlen(s);
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\n' || e[-1] == '\r'))
        *--e = 0;
    return s;
}

static int parse_bool(const char *v)
{
    return !strcasecmp(v, "yes") || !strcasecmp(v, "true") ||
           !strcmp(v, "1") || !strcasecmp(v, "on");
}

static void add_allow(struct config *c, const char *ip, uint16_t port)
{
    if (c->n_allow >= MAX_ALLOW)
        return;
    struct allow *a = &c->allow[c->n_allow];
    if (parse_ip(ip, &a->ip) == 0) { a->port = port; c->n_allow++; }
    else fprintf(stderr, "config: bad ip '%s'\n", ip);
}

static uint64_t clampu(uint64_t v, uint64_t lo, uint64_t hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

static int load_cfg(struct config *c)
{
    FILE *f = fopen(CFG_PATH, "r");
    char line[512];

    if (!f) { perror(CFG_PATH); return -1; }
    memset(c, 0, sizeof(*c));
    snprintf(c->iface, sizeof(c->iface), "ens3");
    c->udp_port = 443;
    c->wl_ttl = 24 * 3600;
    c->wl_refresh = 3600;
    c->flood_window = 1; c->flood_pkts = 800; c->flood_syn = 25; c->ban_sec = 3600;
    c->wl_flood = 0;
    c->wl_flood_window = 1; c->wl_flood_pkts = 150000; c->wl_flood_syn = 300; c->wl_ban_sec = 600;
    c->ip_limit = 1; c->ip_limit_per_dst = 1; c->ip_limit_max = 50; c->ip_limit_idle = 1;
    c->sh_auto = 0; c->sh_cap = 0; c->sh_up = 0;
    c->sh_window_min = 60; c->sh_avg_mbps = 50; c->sh_pen_mbps = 25; c->sh_pen_hours = 24;
    c->sh_cap_mbps = 250; c->sh_port = 443; c->sh_delay_ms = 2000; c->sh_check = 10;

    while (fgets(line, sizeof(line), f)) {
        char *p = trim(line);
        if (*p == '#' || *p == 0) continue;
        char *eq = strchr(p, '=');
        if (!eq) continue;
        *eq = 0;
        char *key = trim(p), *val = trim(eq + 1);

        if (!strcmp(key, "iface"))                      snprintf(c->iface, sizeof(c->iface), "%s", val);
        else if (!strcmp(key, "ssh_mode"))              c->ssh_open = !strcasecmp(val, "all");
        else if (!strcmp(key, "allow_ssh"))             add_allow(c, val, 22);
        else if (!strcmp(key, "allow_1433"))            add_allow(c, val, 1433);
        else if (!strcmp(key, "udp443_whitelist"))      c->udp443_wl = parse_bool(val);
        else if (!strcmp(key, "udp_port"))              c->udp_port = strtoull(val, NULL, 10);
        else if (!strcmp(key, "udp_ip"))                snprintf(c->udp_ip_txt, sizeof(c->udp_ip_txt), "%s", val);
        else if (!strcmp(key, "whitelist_hours"))       c->wl_ttl = strtoull(val, NULL, 10) * 3600;
        else if (!strcmp(key, "whitelist_refresh_minutes")) c->wl_refresh = strtoull(val, NULL, 10) * 60;
        else if (!strcmp(key, "flood_window"))          c->flood_window = strtoull(val, NULL, 10);
        else if (!strcmp(key, "flood_packets"))         c->flood_pkts = strtoull(val, NULL, 10);
        else if (!strcmp(key, "flood_syn"))             c->flood_syn = strtoull(val, NULL, 10);
        else if (!strcmp(key, "ban_minutes"))           c->ban_sec = strtoull(val, NULL, 10) * 60;
        else if (!strcmp(key, "wl_flood"))              c->wl_flood = parse_bool(val);
        else if (!strcmp(key, "wl_flood_window"))       c->wl_flood_window = strtoull(val, NULL, 10);
        else if (!strcmp(key, "wl_flood_packets"))      c->wl_flood_pkts = strtoull(val, NULL, 10);
        else if (!strcmp(key, "wl_flood_syn"))          c->wl_flood_syn = strtoull(val, NULL, 10);
        else if (!strcmp(key, "wl_ban_minutes"))        c->wl_ban_sec = strtoull(val, NULL, 10) * 60;
        else if (!strcmp(key, "ip_limit"))              c->ip_limit = parse_bool(val);
        else if (!strcmp(key, "ip_limit_per_dst"))      c->ip_limit_per_dst = parse_bool(val);
        else if (!strcmp(key, "ip_limit_max"))          c->ip_limit_max = strtoull(val, NULL, 10);
        else if (!strcmp(key, "ip_limit_idle"))         c->ip_limit_idle = strtoull(val, NULL, 10);
        else if (!strcmp(key, "shape_auto"))            c->sh_auto = parse_bool(val);
        else if (!strcmp(key, "shape_window_min"))      c->sh_window_min = strtoull(val, NULL, 10);
        else if (!strcmp(key, "shape_avg_mbps"))        c->sh_avg_mbps = strtoull(val, NULL, 10);
        else if (!strcmp(key, "shape_penalty_mbps"))    c->sh_pen_mbps = strtoull(val, NULL, 10);
        else if (!strcmp(key, "shape_penalty_hours"))   c->sh_pen_hours = strtoull(val, NULL, 10);
        else if (!strcmp(key, "shape_upload"))          c->sh_up = parse_bool(val);
        else if (!strcmp(key, "shape_ip_cap"))          c->sh_cap = parse_bool(val);
        else if (!strcmp(key, "shape_ip_cap_mbps"))     c->sh_cap_mbps = strtoull(val, NULL, 10);
        else if (!strcmp(key, "shape_port"))            c->sh_port = strtoull(val, NULL, 10);
        else if (!strcmp(key, "shape_max_delay_ms"))    c->sh_delay_ms = strtoull(val, NULL, 10);
        else if (!strcmp(key, "shape_check_sec"))       c->sh_check = strtoull(val, NULL, 10);
    }
    fclose(f);
    if (c->udp_port < 1 || c->udp_port > 65535) {
        fprintf(stderr, "config: udp_port вне диапазона 1-65535 — UDP для whitelist отключён\n");
        c->udp443_wl = 0;
        c->udp_port = 443;
    }
    if (c->udp_ip_txt[0] && strcasecmp(c->udp_ip_txt, "any") && strcmp(c->udp_ip_txt, "*") &&
        strcasecmp(c->udp_ip_txt, "all")) {
        if (parse_ip(c->udp_ip_txt, &c->udp_ip) == 0) {
            c->udp_ip_set = 1;
        } else {
            /* неверный адрес нельзя молча превращать в "любой": это открыло бы порт шире задуманного */
            fprintf(stderr, "config: udp_ip '%s' — не IP-адрес, UDP для whitelist отключён\n", c->udp_ip_txt);
            c->udp443_wl = 0;
        }
    }
    if (c->wl_ttl == 0) c->wl_ttl = 3600;
    if (c->ban_sec == 0) c->ban_sec = 60;
    if (c->wl_ban_sec == 0) c->wl_ban_sec = 60;
    if (c->flood_window == 0) c->flood_window = 1;
    if (c->wl_flood_window == 0) c->wl_flood_window = 1;
    if (c->ip_limit_idle == 0) c->ip_limit_idle = 1;
    if (c->ip_limit_max > 60000) c->ip_limit_max = 60000;
    c->sh_window_min = clampu(c->sh_window_min, 10, 1440);
    c->sh_avg_mbps = clampu(c->sh_avg_mbps, 1, 100000);
    c->sh_pen_mbps = clampu(c->sh_pen_mbps, 1, 100000);
    c->sh_pen_hours = clampu(c->sh_pen_hours, 1, 8760);
    c->sh_cap_mbps = clampu(c->sh_cap_mbps, 1, 100000);
    c->sh_port = clampu(c->sh_port, 1, 65535);
    c->sh_delay_ms = clampu(c->sh_delay_ms, 10, 60000);
    c->sh_check = clampu(c->sh_check, 5, 600);
    return 0;
}

static int in_cfg(const struct config *c, const struct acl_key *k)
{
    for (int i = 0; i < c->n_allow; i++)
        if (c->allow[i].port == k->port && !memcmp(&c->allow[i].ip, &k->ip, sizeof(k->ip)))
            return 1;
    return 0;
}

static void sync_acl(int fd, const struct config *c)
{
    struct acl_key cur, next;
    uint8_t one = 1;

    for (int i = 0; i < c->n_allow; i++) {
        struct acl_key k;
        memset(&k, 0, sizeof(k));
        k.ip = c->allow[i].ip;
        k.port = c->allow[i].port;
        bpf_map_update_elem(fd, &k, &one, BPF_ANY);
    }
    int r = bpf_map_get_next_key(fd, NULL, &next);
    while (r == 0) {
        cur = next;
        r = bpf_map_get_next_key(fd, &cur, &next);
        if (!in_cfg(c, &cur))
            bpf_map_delete_elem(fd, &cur);
    }
}

/* адрес принадлежит этому серверу (есть на каком-либо интерфейсе)? */
static int local_has_ip(const struct addr_key *k)
{
    struct ifaddrs *ifa, *p;
    int found = 0;
    if (getifaddrs(&ifa))
        return 1;                               /* проверить не смогли — не ругаемся */
    for (p = ifa; p && !found; p = p->ifa_next) {
        struct addr_key a;
        memset(&a, 0, sizeof(a));
        if (!p->ifa_addr)
            continue;
        if (p->ifa_addr->sa_family == AF_INET) {
            a.a[10] = a.a[11] = 0xff;
            memcpy(&a.a[12], &((struct sockaddr_in *)p->ifa_addr)->sin_addr, 4);
        } else if (p->ifa_addr->sa_family == AF_INET6) {
            memcpy(a.a, &((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr, 16);
        } else {
            continue;
        }
        found = !memcmp(&a, k, sizeof(a));
    }
    freeifaddrs(ifa);
    return found;
}

static void udp_desc(const struct config *c, char *buf, size_t n)
{
    char ip[INET6_ADDRSTRLEN];
    if (!c->udp443_wl) { snprintf(buf, n, "выкл (UDP закрыт для всех)"); return; }
    if (c->udp_ip_set)
        snprintf(buf, n, "вкл (только whitelist, UDP %llu на %s)", (unsigned long long)c->udp_port, ip_str(&c->udp_ip, ip, sizeof(ip)));
    else
        snprintf(buf, n, "вкл (только whitelist, UDP %llu на любом адресе)", (unsigned long long)c->udp_port);
}

static uint32_t clamp32(uint64_t v) { return v > 0xFFFFFFFFULL ? 0xFFFFFFFFU : (uint32_t)v; }

static void push_cfg_map(int fd, const struct config *c)
{
    struct fwcfg m;
    unsigned lo, hi;
    FILE *f;

    memset(&m, 0, sizeof(m));
    m.eph_lo = 32768;
    m.eph_hi = 60999;
    f = fopen("/proc/sys/net/ipv4/ip_local_port_range", "r");
    if (f) {
        if (fscanf(f, "%u %u", &lo, &hi) == 2) { m.eph_lo = lo; m.eph_hi = hi; }
        fclose(f);
    }
    m.ssh_open = c->ssh_open;
    m.udp443_wl = c->udp443_wl;
    m.udp_port = (uint32_t)c->udp_port;
    m.udp_ip_set = c->udp_ip_set;
    m.ip_limit_per_dst = c->ip_limit_per_dst;
    memcpy(m.udp_ip, c->udp_ip.a, 16);
    m.flood_pkts = clamp32(c->flood_pkts);
    m.flood_syn = clamp32(c->flood_syn);
    m.flood_window_ns = c->flood_window * SEC_NS;
    m.ban_ns = c->ban_sec * SEC_NS;
    m.wl_flood = c->wl_flood;
    m.wl_flood_pkts = clamp32(c->wl_flood_pkts);
    m.wl_flood_syn = clamp32(c->wl_flood_syn);
    m.wl_flood_window_ns = c->wl_flood_window * SEC_NS;
    m.wl_ban_ns = c->wl_ban_sec * SEC_NS;
    m.ip_limit = c->ip_limit;
    m.ip_limit_max = clamp32(c->ip_limit_max);

    uint32_t k = 0;
    bpf_map_update_elem(fd, &k, &m, BPF_ANY);
}

static void detach_xdp(int ifindex)
{
    bpf_xdp_detach(ifindex, XDP_FLAGS_SKB_MODE, NULL);
    bpf_xdp_detach(ifindex, XDP_FLAGS_DRV_MODE, NULL);
}

static int attach_xdp(int ifindex, int prog_fd)
{
    detach_xdp(ifindex);
    if (bpf_xdp_attach(ifindex, prog_fd, XDP_FLAGS_DRV_MODE, NULL) == 0) {
        puts("XDP attached: native (driver) mode");
        return 0;
    }
    if (bpf_xdp_attach(ifindex, prog_fd, XDP_FLAGS_SKB_MODE, NULL) == 0) {
        puts("XDP attached: generic (skb) mode");
        return 0;
    }
    return -1;
}

/* ---------- общие помощники по картам с ключом addr_key ---------- */
static int map_active(int fd, const struct addr_key *k, uint64_t now)
{
    uint64_t v;
    return bpf_map_lookup_elem(fd, k, &v) == 0 && v > now;
}

static int map_empty(int fd)
{
    struct addr_key k;
    return bpf_map_get_next_key(fd, NULL, &k) != 0;
}

static void map_clear(int fd)
{
    struct addr_key cur, next;
    int r = bpf_map_get_next_key(fd, NULL, &next);
    while (r == 0) {
        cur = next;
        r = bpf_map_get_next_key(fd, &cur, &next);
        bpf_map_delete_elem(fd, &cur);
    }
}

static void slots_clear(int fd_slots, int fd_cnt)
{
    struct slot_key cur, next;
    int r = bpf_map_get_next_key(fd_slots, NULL, &next);
    while (r == 0) {
        cur = next;
        r = bpf_map_get_next_key(fd_slots, &cur, &next);
        bpf_map_delete_elem(fd_slots, &cur);
    }
    map_clear(fd_cnt);
}

static void free_src_slots(int fd_slots, int fd_cnt, const struct addr_key *src)
{
    if (fd_slots < 0)
        return;
    struct slot_key cur, next;
    int r = bpf_map_get_next_key(fd_slots, NULL, &next);
    while (r == 0) {
        cur = next;
        r = bpf_map_get_next_key(fd_slots, &cur, &next);
        if (!memcmp(&cur.src, src, sizeof(*src))) {
            if (bpf_map_delete_elem(fd_slots, &cur) == 0 && fd_cnt >= 0) {
                uint32_t cnt = 0;
                if (bpf_map_lookup_elem(fd_cnt, &cur.dst, &cnt) == 0 && cnt > 0) {
                    cnt--;
                    if (cnt == 0)
                        bpf_map_delete_elem(fd_cnt, &cur.dst);
                    else
                        bpf_map_update_elem(fd_cnt, &cur.dst, &cnt, BPF_ANY);
                }
            }
        }
    }
}

static uint32_t count_active(int fd, uint64_t now)
{
    struct addr_key cur, next;
    uint64_t v;
    uint32_t n = 0;
    int r = bpf_map_get_next_key(fd, NULL, &next);
    while (r == 0) {
        cur = next;
        r = bpf_map_get_next_key(fd, &cur, &next);
        if (bpf_map_lookup_elem(fd, &cur, &v) == 0 && v > now)
            n++;
    }
    return n;
}

static void cleanup_expired(int fd, uint64_t now)
{
    struct addr_key cur, next;
    uint64_t v;
    int r = bpf_map_get_next_key(fd, NULL, &next);
    while (r == 0) {
        cur = next;
        r = bpf_map_get_next_key(fd, &cur, &next);
        if (bpf_map_lookup_elem(fd, &cur, &v) == 0 && v <= now)
            bpf_map_delete_elem(fd, &cur);
    }
}

struct dst_cnt {
    struct addr_key dst;
    uint32_t cnt;
};

/* освобождаем слоты IP, от которых нет пакетов ip_limit_idle секунд (или попавших в whitelist),
 * и пересчитываем счётчик занятых слотов для каждого IP интерфейса (или общий) */
static void prune_slots(int fd_slots, int fd_cnt, int fd_wl, const struct config *c, uint64_t now)
{
    struct slot_key cur, next;
    struct addr_key ccur, cnext;
    uint64_t v, idle = c->ip_limit_idle * SEC_NS;
    struct dst_cnt dc[512];
    int ndc = 0;

    int r = bpf_map_get_next_key(fd_slots, NULL, &next);
    while (r == 0) {
        cur = next;
        r = bpf_map_get_next_key(fd_slots, &cur, &next);
        if (bpf_map_lookup_elem(fd_slots, &cur, &v))
            continue;
        if ((now > v && now - v > idle) || (fd_wl >= 0 && map_active(fd_wl, &cur.src, now))) {
            bpf_map_delete_elem(fd_slots, &cur);
        } else {
            struct addr_key ck = {};
            if (c->ip_limit_per_dst)
                ck = cur.dst;
            int found = 0;
            for (int i = 0; i < ndc; i++) {
                if (!memcmp(&dc[i].dst, &ck, sizeof(ck))) {
                    dc[i].cnt++;
                    found = 1;
                    break;
                }
            }
            if (!found && ndc < 512) {
                dc[ndc].dst = ck;
                dc[ndc].cnt = 1;
                ndc++;
            }
        }
    }

    for (int i = 0; i < ndc; i++)
        bpf_map_update_elem(fd_cnt, &dc[i].dst, &dc[i].cnt, BPF_ANY);

    r = bpf_map_get_next_key(fd_cnt, NULL, &cnext);
    while (r == 0) {
        ccur = cnext;
        r = bpf_map_get_next_key(fd_cnt, &ccur, &cnext);
        int found = 0;
        for (int i = 0; i < ndc; i++) {
            if (!memcmp(&dc[i].dst, &ccur, sizeof(ccur))) {
                found = 1;
                break;
            }
        }
        if (!found)
            bpf_map_delete_elem(fd_cnt, &ccur);
    }
}

/* Множество уже замеченных блокировок за флуд (хеш-таблица): при массовой атаке в banlist тысячи записей,
 * линейный поиск на каждую из них съедал бы заметную часть процессора. */
#define KH 16384                             /* степень двойки, больше 2*MAX_KNOWN */
struct kslot { struct addr_key k; uint8_t used; };
static struct kslot g_kn[2][KH];
static int g_kcur, g_kcnt[2];

static uint32_t khash(const struct addr_key *k)
{
    uint32_t h = 2166136261u;
    for (int i = 0; i < 16; i++)
        h = (h ^ k->a[i]) * 16777619u;
    return h;
}

static int kset_has(int t, const struct addr_key *k)
{
    uint32_t i = khash(k) & (KH - 1);
    while (g_kn[t][i].used) {
        if (!memcmp(&g_kn[t][i].k, k, sizeof(*k)))
            return 1;
        i = (i + 1) & (KH - 1);
    }
    return 0;
}

static void kset_add(int t, const struct addr_key *k)
{
    uint32_t i = khash(k) & (KH - 1);
    while (g_kn[t][i].used)
        i = (i + 1) & (KH - 1);
    g_kn[t][i].k = *k;
    g_kn[t][i].used = 1;
    g_kcnt[t]++;
}

/* Раз в секунду пересчитываем слоты лимита IP (чтобы ip_limit_idle=1 с отрабатывал точно),
 * раз в 2 секунды пишем в лог новые блокировки за флуд, раз в минуту чистим whitelist. */
static void scan(int fd_wl, int fd_ban, int fd_slots, int fd_cnt, const struct config *c)
{
    static uint64_t last_wl, last_slots, last_ban;
    uint64_t now = mono_ns(), v;
    struct addr_key cur, next;
    char buf[INET6_ADDRSTRLEN];

    if (now - last_ban >= 2 * SEC_NS) {
        last_ban = now;
        int nt = 1 - g_kcur;
        if (g_kcnt[nt]) {
            memset(g_kn[nt], 0, sizeof(g_kn[nt]));
            g_kcnt[nt] = 0;
        }
        int r = bpf_map_get_next_key(fd_ban, NULL, &next);
        while (r == 0) {
            cur = next;
            r = bpf_map_get_next_key(fd_ban, &cur, &next);
            if (bpf_map_lookup_elem(fd_ban, &cur, &v))
                continue;
            if (v <= now) {
                bpf_map_delete_elem(fd_ban, &cur);
                continue;
            }
            if (!kset_has(g_kcur, &cur))
                printf("flood ban +%s на %llu с\n", ip_str(&cur, buf, sizeof(buf)),
                       (unsigned long long)((v - now) / SEC_NS));
            if (g_kcnt[nt] < MAX_KNOWN)
                kset_add(nt, &cur);
        }
        g_kcur = nt;
    }

    if (now - last_wl >= 60 * SEC_NS) {
        last_wl = now;
        cleanup_expired(fd_wl, now);
    }
    if (now - last_slots >= 1 * SEC_NS) {
        last_slots = now;
        prune_slots(fd_slots, fd_cnt, fd_wl, c, now);
    }
}

/* =====================================================================
 *  Ограничение скорости в обе стороны (traffic shaping)
 * ===================================================================== */
#define IFB_NAME "xdpfw-ifb"

struct shape_rt {
    int inited;             /* загрузка tc-объекта уже пробовалась */
    int ok;                 /* tc-объект загружен */
    int in_ok;              /* ingress-программа загружена */
    int attached;           /* egress-программа висит на интерфейсе */
    int in_attached;        /* ingress-программа висит на интерфейсе */
    int ifindex;
    int ifb_ifindex;        /* 0 — IFB недоступен: входящий трафик считается, но не ограничивается */
    char iface[IFNAMSIZ];
    int fd_ip, fd_ip_in, fd_pen, fd_hist, fd_hist_in, fd_cfg;
    int prog_fd, prog_in_fd;
    uint32_t pen_cnt;
    uint64_t window_min;    /* окно, с которым накоплена история */
    struct bpf_object *obj;
};

static uint64_t sh_window_sec(const struct config *c) { return c->sh_window_min * 60ULL; }
static uint64_t sh_bucket_sec(const struct config *c) { return sh_window_sec(c) / NB; }
static uint64_t sh_threshold(const struct config *c)
{
    return c->sh_avg_mbps * 125000ULL * sh_window_sec(c);
}

static void push_bw_cfg(const struct shape_rt *sh, const struct config *c)
{
    struct bwcfg m;
    uint32_t k = 0;
    memset(&m, 0, sizeof(m));
    m.enabled = 1;
    m.pen_cnt = sh->pen_cnt;
    m.cap_on = c->sh_cap;
    m.port = (uint32_t)c->sh_port;
    m.in_on = c->sh_up && sh->in_attached && sh->ifb_ifindex;
    m.ifb_ifindex = sh->ifb_ifindex > 0 ? (uint32_t)sh->ifb_ifindex : 0;
    m.pen_rate_bps = c->sh_pen_mbps * 1000000ULL;
    m.cap_rate_bps = c->sh_cap_mbps * 1000000ULL;
    m.max_delay_ns = c->sh_delay_ms * 1000000ULL;
    bpf_map_update_elem(sh->fd_cfg, &k, &m, BPF_ANY);
}

static int tc_attach(int ifindex, int prog_fd, enum bpf_tc_attach_point point)
{
    LIBBPF_OPTS(bpf_tc_hook, hook, .ifindex = ifindex, .attach_point = point);
    LIBBPF_OPTS(bpf_tc_opts, opts, .handle = 1, .priority = 1,
                .prog_fd = prog_fd, .flags = BPF_TC_F_REPLACE);
    int err = bpf_tc_hook_create(&hook);
    if (err && err != -EEXIST)
        return err;
    return bpf_tc_attach(&hook, &opts);
}

static void tc_detach(int ifindex, enum bpf_tc_attach_point point)
{
    LIBBPF_OPTS(bpf_tc_hook, hook, .ifindex = ifindex, .attach_point = point);
    LIBBPF_OPTS(bpf_tc_opts, opts, .handle = 1, .priority = 1);
    bpf_tc_detach(&hook, &opts);
}

static void run_qdisc_helper(const char *iface, int with_ifb)
{
    char cmd[200];
    for (const char *p = iface; *p; p++) {
        int ok = (*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
                 (*p >= '0' && *p <= '9') || *p == '-' || *p == '_' || *p == '.';
        if (!ok)
            return;
    }
    snprintf(cmd, sizeof(cmd), "%s %s%s", QDISC_HELPER, iface, with_ifb ? " ifb" : "");
    if (system(cmd) != 0)
        fprintf(stderr, "shape: %s завершился с ошибкой\n", QDISC_HELPER);
}

static struct bpf_object *open_tc_obj(int no_ingress)
{
    LIBBPF_OPTS(bpf_object_open_opts, opts, .pin_root_path = PIN_DIR);
    struct bpf_object *obj = bpf_object__open_file(TC_OBJ_PATH, &opts);
    if (obj && no_ingress) {
        struct bpf_program *pi = bpf_object__find_program_by_name(obj, "tc_ingress");
        if (pi)
            bpf_program__set_autoload(pi, false);
    }
    return obj;
}

static void shape_init(struct shape_rt *sh, int ifindex, const struct config *c)
{
    memset(sh, 0, sizeof(*sh));
    sh->fd_ip = sh->fd_ip_in = sh->fd_pen = sh->fd_hist = sh->fd_hist_in = sh->fd_cfg = -1;
    sh->prog_fd = sh->prog_in_fd = -1;
    sh->ifindex = ifindex;
    snprintf(sh->iface, sizeof(sh->iface), "%s", c->iface);

    struct bpf_object *obj = open_tc_obj(0);
    if (!obj) {
        fprintf(stderr, "shape: не удалось открыть %s — ограничение скорости недоступно\n", TC_OBJ_PATH);
        return;
    }
    int in_ok = 1;
    if (bpf_object__load(obj)) {
        bpf_object__close(obj);
        fprintf(stderr, "shape: tc-объект не загрузился целиком — пробую без входящей части\n");
        in_ok = 0;
        obj = open_tc_obj(1);
        if (!obj || bpf_object__load(obj)) {
            fprintf(stderr, "shape: tc-программа не загрузилась — ограничение скорости недоступно\n");
            if (obj)
                bpf_object__close(obj);
            return;
        }
        fprintf(stderr, "shape: ВХОДЯЩИЙ трафик ограничиваться не будет (нужно ядро Linux >= 5.18)\n");
    }
    struct bpf_map *m_ip = bpf_object__find_map_by_name(obj, "bw_ip");
    struct bpf_map *m_ip_in = bpf_object__find_map_by_name(obj, "bw_ip_in");
    struct bpf_map *m_pen = bpf_object__find_map_by_name(obj, "bw_pen");
    struct bpf_map *m_hist = bpf_object__find_map_by_name(obj, "bw_hist");
    struct bpf_map *m_hist_in = bpf_object__find_map_by_name(obj, "bw_hist_in");
    struct bpf_map *m_cfg = bpf_object__find_map_by_name(obj, "bw_cfg");
    struct bpf_program *prog = bpf_object__find_program_by_name(obj, "tc_egress");
    struct bpf_program *prog_in = bpf_object__find_program_by_name(obj, "tc_ingress");
    if (!m_ip || !m_ip_in || !m_pen || !m_hist || !m_hist_in || !m_cfg || !prog || !prog_in) {
        fprintf(stderr, "shape: в tc-объекте нет нужных карт/программ\n");
        bpf_object__close(obj);
        return;
    }
    sh->obj = obj;
    sh->fd_ip = bpf_map__fd(m_ip);
    sh->fd_ip_in = bpf_map__fd(m_ip_in);
    sh->fd_pen = bpf_map__fd(m_pen);
    sh->fd_hist = bpf_map__fd(m_hist);
    sh->fd_hist_in = bpf_map__fd(m_hist_in);
    sh->fd_cfg = bpf_map__fd(m_cfg);
    sh->prog_fd = bpf_program__fd(prog);
    if (in_ok)
        sh->prog_in_fd = bpf_program__fd(prog_in);
    sh->in_ok = in_ok && sh->prog_in_fd >= 0;
    sh->window_min = c->sh_window_min;
    sh->ok = 1;
}

static void state_load(const struct shape_rt *sh, const struct config *c);

static void shape_lazy(struct shape_rt *sh, int ifindex, const struct config *c)
{
    if (sh->inited || !(c->sh_auto || c->sh_cap))
        return;
    shape_init(sh, ifindex, c);
    sh->inited = 1;
    if (sh->ok && map_empty(sh->fd_pen) && map_empty(sh->fd_hist) && map_empty(sh->fd_hist_in))
        state_load(sh, c);
}

static void shape_apply(struct shape_rt *sh, const struct config *c)
{
    if (!sh->ok)
        return;
    int want = c->sh_auto || c->sh_cap;
    int want_in = want && c->sh_up && sh->in_ok;

    sh->pen_cnt = count_active(sh->fd_pen, mono_ns());

    if (want && !sh->attached) {
        run_qdisc_helper(sh->iface, want_in);
        int err = tc_attach(sh->ifindex, sh->prog_fd, BPF_TC_EGRESS);
        if (err) {
            fprintf(stderr, "shape: не удалось повесить tc на egress %s (код %d)\n", sh->iface, err);
        } else {
            sh->attached = 1;
            printf("shape: tc egress включён на %s (автоограничение=%s, лимит каждого IP=%s)\n",
                   sh->iface, c->sh_auto ? "да" : "нет", c->sh_cap ? "да" : "нет");
        }
    } else if (!want && sh->attached) {
        tc_detach(sh->ifindex, BPF_TC_EGRESS);
        sh->attached = 0;
        puts("shape: tc egress выключен");
    }

    if (want_in && !sh->in_attached) {
        sh->ifb_ifindex = (int)if_nametoindex(IFB_NAME);
        if (!sh->ifb_ifindex) {
            run_qdisc_helper(sh->iface, 1);
            sh->ifb_ifindex = (int)if_nametoindex(IFB_NAME);
            if (!sh->ifb_ifindex)
                fprintf(stderr, "shape: IFB (%s) недоступен (модуль ядра ifb?) — "
                        "входящий трафик будет только считаться, но не ограничиваться\n", IFB_NAME);
        }
        int err = tc_attach(sh->ifindex, sh->prog_in_fd, BPF_TC_INGRESS);
        if (err) {
            fprintf(stderr, "shape: не удалось повесить tc на ingress %s (код %d)\n", sh->iface, err);
        } else {
            sh->in_attached = 1;
            printf("shape: tc ingress включён на %s (входящий трафик ограничивается: %s)\n",
                   sh->iface, sh->ifb_ifindex ? "да" : "нет, только учёт");
        }
    } else if (!want_in && sh->in_attached) {
        tc_detach(sh->ifindex, BPF_TC_INGRESS);
        sh->in_attached = 0;
        puts("shape: tc ingress выключен");
    }
    push_bw_cfg(sh, c);
}

static void shape_reset(struct shape_rt *sh)
{
    if (!sh->ok)
        return;
    map_clear(sh->fd_hist);
    map_clear(sh->fd_hist_in);
    map_clear(sh->fd_ip);
    map_clear(sh->fd_ip_in);
}

static void reset_one_hist(int fd_ip, int fd_hist, const struct addr_key *k, uint64_t curb)
{
    struct bwip st;
    struct hist h;
    if (fd_ip < 0 || fd_hist < 0)
        return;
    memset(&h, 0, sizeof(h));
    h.head = curb;
    if (bpf_map_lookup_elem(fd_ip, k, &st) == 0)
        h.last_total = st.total;    /* чтобы накопленное раньше не посчиталось заново */
    bpf_map_update_elem(fd_hist, k, &h, BPF_ANY);
}

static void reset_hist_for(const struct shape_rt *sh, const struct addr_key *k, uint64_t curb)
{
    reset_one_hist(sh->fd_ip, sh->fd_hist, k, curb);
    reset_one_hist(sh->fd_ip_in, sh->fd_hist_in, k, curb);
}

static uint32_t scan_dir(struct shape_rt *sh, const struct config *c, int fd_ip, int fd_hist,
                         const char *dir, uint64_t now_m, uint64_t curb)
{
    uint64_t window = sh_window_sec(c), thr = sh_threshold(c);
    uint64_t pen_ns = c->sh_pen_hours * 3600ULL * SEC_NS;
    struct addr_key cur, next;
    char buf[INET6_ADDRSTRLEN];
    uint32_t added = 0;
    int r = bpf_map_get_next_key(fd_ip, NULL, &next);

    while (r == 0) {
        struct bwip st;
        struct hist h;
        uint64_t delta, sum = 0;
        int have_h;

        cur = next;
        r = bpf_map_get_next_key(fd_ip, &cur, &next);
        if (bpf_map_lookup_elem(fd_ip, &cur, &st))
            continue;
        have_h = bpf_map_lookup_elem(fd_hist, &cur, &h) == 0;
        if (!have_h) {
            memset(&h, 0, sizeof(h));
            h.head = curb;
        }
        if (curb > h.head) {                 /* сдвигаем окно: обнуляем корзины, в которые попали бы старые данные */
            uint64_t n = curb - h.head;
            if (n >= NB) {
                memset(h.b, 0, sizeof(h.b));
            } else {
                for (uint64_t i = 1; i <= n; i++)
                    h.b[(h.head + i) % NB] = 0;
            }
            h.head = curb;
        }
        delta = st.total >= h.last_total ? st.total - h.last_total : st.total;
        h.b[h.head % NB] += delta;
        h.last_total = st.total;
        for (int i = 0; i < NB; i++)
            sum += h.b[i];

        if (sum == 0 && delta == 0) {        /* за всё окно ни байта — забываем IP */
            bpf_map_delete_elem(fd_hist, &cur);
            bpf_map_delete_elem(fd_ip, &cur);
            continue;
        }
        bpf_map_update_elem(fd_hist, &cur, &h, BPF_ANY);

        if (c->sh_auto && sum > thr && !map_active(sh->fd_pen, &cur, now_m)) {
            uint64_t exp = now_m + pen_ns;
            bpf_map_update_elem(sh->fd_pen, &cur, &exp, BPF_ANY);
            added++;
            printf("shape +%s: %s — средняя скорость %.1f Мбит/с за %llu мин (порог %llu) -> "
                   "%llu Мбит/с в каждую сторону на %llu ч\n",
                   ip_str(&cur, buf, sizeof(buf)), dir,
                   (double)sum * 8.0 / (double)window / 1e6,
                   (unsigned long long)c->sh_window_min, (unsigned long long)c->sh_avg_mbps,
                   (unsigned long long)c->sh_pen_mbps, (unsigned long long)c->sh_pen_hours);
        }
    }
    return added;
}

static void shape_scan(struct shape_rt *sh, const struct config *c)
{
    uint64_t now_m = mono_ns(), now_r = real_sec();
    uint64_t curb = now_r / sh_bucket_sec(c);
    struct addr_key cur, next;
    char buf[INET6_ADDRSTRLEN];
    uint32_t npen = 0;
    int r;

    /* 1. штрафы: убрать истёкшие (и все, если автоограничение выключено), посчитать активные */
    r = bpf_map_get_next_key(sh->fd_pen, NULL, &next);
    while (r == 0) {
        uint64_t v;
        cur = next;
        r = bpf_map_get_next_key(sh->fd_pen, &cur, &next);
        if (bpf_map_lookup_elem(sh->fd_pen, &cur, &v))
            continue;
        if (!c->sh_auto || v <= now_m) {
            bpf_map_delete_elem(sh->fd_pen, &cur);
            printf("shape -%s (%s)\n", ip_str(&cur, buf, sizeof(buf)),
                   v <= now_m ? "срок ограничения истёк" : "автоограничение выключено");
        } else {
            npen++;
        }
    }

    /* 2. учёт трафика и скользящее окно: направления считаем раздельно, не складывая */
    npen += scan_dir(sh, c, sh->fd_ip, sh->fd_hist, "исходящий (VPS -> IP)", now_m, curb);
    if (sh->in_attached)
        npen += scan_dir(sh, c, sh->fd_ip_in, sh->fd_hist_in, "входящий (IP -> VPS)", now_m, curb);

    if (npen != sh->pen_cnt) {
        sh->pen_cnt = npen;
        push_bw_cfg(sh, c);
    }
}

/* ---------- состояние переживает перезапуск и перезагрузку ---------- */
static void save_hists(FILE *f, int fd_hist, char tag, uint64_t thr)
{
    struct addr_key cur, next;
    char buf[INET6_ADDRSTRLEN];
    int r = bpf_map_get_next_key(fd_hist, NULL, &next);
    while (r == 0) {
        struct hist h;
        uint64_t sum = 0;
        cur = next;
        r = bpf_map_get_next_key(fd_hist, &cur, &next);
        if (bpf_map_lookup_elem(fd_hist, &cur, &h))
            continue;
        for (int i = 0; i < NB; i++)
            sum += h.b[i];
        if (sum * 20 < thr)                  /* меньше 5% порога — не храним */
            continue;
        fprintf(f, "%c %s %llu", tag, ip_str(&cur, buf, sizeof(buf)), (unsigned long long)h.head);
        for (int i = 0; i < NB; i++)
            fprintf(f, " %llu", (unsigned long long)h.b[i]);
        fputc('\n', f);
    }
}

static void state_save(const struct shape_rt *sh, const struct config *c)
{
    char tmp[128];
    uint64_t now_m = mono_ns(), now_r = real_sec(), thr = sh_threshold(c);
    struct addr_key cur, next;
    char buf[INET6_ADDRSTRLEN];
    FILE *f;
    int r;

    if (!sh->ok)
        return;
    mkdir(STATE_DIR, 0700);
    snprintf(tmp, sizeof(tmp), "%s.tmp", STATE_FILE);
    f = fopen(tmp, "w");
    if (!f)
        return;
    fprintf(f, "# xdpfw shape state\nM %llu\n", (unsigned long long)sh_bucket_sec(c));

    r = bpf_map_get_next_key(sh->fd_pen, NULL, &next);
    while (r == 0) {
        uint64_t v;
        cur = next;
        r = bpf_map_get_next_key(sh->fd_pen, &cur, &next);
        if (bpf_map_lookup_elem(sh->fd_pen, &cur, &v) == 0 && v > now_m)
            fprintf(f, "P %s %llu\n", ip_str(&cur, buf, sizeof(buf)),
                    (unsigned long long)(now_r + (v - now_m) / SEC_NS));
    }
    save_hists(f, sh->fd_hist, 'H', thr);        /* исходящий */
    save_hists(f, sh->fd_hist_in, 'I', thr);     /* входящий */
    if (fclose(f) == 0)
        rename(tmp, STATE_FILE);
}

static void state_load(const struct shape_rt *sh, const struct config *c)
{
    FILE *f = fopen(STATE_FILE, "r");
    char line[4096];
    int same_bucket = 0;
    uint64_t now_m = mono_ns(), now_r = real_sec();
    unsigned np = 0, nh = 0, ni = 0;

    if (!f || !sh->ok) {
        if (f) fclose(f);
        return;
    }
    while (fgets(line, sizeof(line), f)) {
        struct addr_key k;
        if (line[0] == 'M') {
            unsigned long long b = 0;
            if (sscanf(line + 1, "%llu", &b) == 1)
                same_bucket = (b == sh_bucket_sec(c));
        } else if (line[0] == 'P') {
            char ip[64];
            unsigned long long exp_r;
            if (sscanf(line + 1, "%63s %llu", ip, &exp_r) == 2 && exp_r > now_r &&
                parse_ip(ip, &k) == 0) {
                uint64_t exp = now_m + (exp_r - now_r) * SEC_NS;
                bpf_map_update_elem(sh->fd_pen, &k, &exp, BPF_ANY);
                np++;
            }
        } else if ((line[0] == 'H' || line[0] == 'I') && same_bucket) {
            char *save = NULL, *tok;
            struct hist h;
            int i;
            memset(&h, 0, sizeof(h));
            tok = strtok_r(line + 1, " \n", &save);
            if (!tok || parse_ip(tok, &k) != 0)
                continue;
            tok = strtok_r(NULL, " \n", &save);
            if (!tok)
                continue;
            h.head = strtoull(tok, NULL, 10);
            for (i = 0; i < NB; i++) {
                tok = strtok_r(NULL, " \n", &save);
                if (!tok)
                    break;
                h.b[i] = strtoull(tok, NULL, 10);
            }
            if (i == NB) {
                if (line[0] == 'H') {
                    bpf_map_update_elem(sh->fd_hist, &k, &h, BPF_ANY);
                    nh++;
                } else {
                    bpf_map_update_elem(sh->fd_hist_in, &k, &h, BPF_ANY);
                    ni++;
                }
            }
        }
    }
    fclose(f);
    printf("shape: состояние восстановлено из %s (штрафов: %u, историй исходящих: %u, входящих: %u)\n",
           STATE_FILE, np, nh, ni);
}

static void warn_udp(const struct config *c)
{
    unsigned lo = 32768, hi = 60999;
    FILE *f;
    if (!c->udp443_wl)
        return;
    if (c->udp_ip_set && !local_has_ip(&c->udp_ip))
        fprintf(stderr, "WARNING: udp_ip=%s не найден ни на одном интерфейсе этого сервера — "
                "UDP для whitelist работать не будет, пока адрес не появится\n", c->udp_ip_txt);
    f = fopen("/proc/sys/net/ipv4/ip_local_port_range", "r");
    if (f) {
        if (fscanf(f, "%u %u", &lo, &hi) != 2) { lo = 32768; hi = 60999; }
        fclose(f);
    }
    if (c->udp_port >= lo && c->udp_port <= hi)
        fprintf(stderr, "WARNING: udp_port=%llu лежит в диапазоне эфемерных портов %u-%u: ответы на исходящие "
                "UDP-соединения сервера с этим портом будут проходить только для whitelist\n",
                (unsigned long long)c->udp_port, lo, hi);
}

static void print_cfg_line(const struct config *c, const char *prefix)
{
    char ud[160];
    udp_desc(c, ud, sizeof(ud));
    printf("%s ssh=%s, acl=%d, udp whitelist=%s, flood=%llu пак./%llu SYN за %llu с, "
           "whitelist-антифлуд=%s, лимит IP=%s(%llu, %s на %s, слот %llu с)\n",
           prefix, c->ssh_open ? "all" : "list", c->n_allow, ud,
           (unsigned long long)c->flood_pkts, (unsigned long long)c->flood_syn,
           (unsigned long long)c->flood_window, c->wl_flood ? "on" : "off",
           c->ip_limit ? "on" : "off", (unsigned long long)c->ip_limit_max,
           c->ip_limit_per_dst ? "на каждый IP" : "общий", c->iface,
           (unsigned long long)c->ip_limit_idle);
    printf("%s shaping: авто=%s (среднее за %llu мин > %llu Мбит/с в любую сторону -> %llu Мбит/с на %llu ч), "
           "лимит каждого IP=%s (%llu Мбит/с), входящий трафик=%s\n",
           prefix, c->sh_auto ? "on" : "off", (unsigned long long)c->sh_window_min,
           (unsigned long long)c->sh_avg_mbps, (unsigned long long)c->sh_pen_mbps,
           (unsigned long long)c->sh_pen_hours, c->sh_cap ? "on" : "off",
           (unsigned long long)c->sh_cap_mbps, c->sh_up ? "on" : "off");
}

static int cmd_run(void)
{
    struct config cfg;
    struct shape_rt sh;
    int has22 = 0;
    uint64_t last_shape = 0, last_save;
    if (load_cfg(&cfg)) return 1;

    int ifindex = if_nametoindex(cfg.iface);
    if (!ifindex) { fprintf(stderr, "interface '%s' not found\n", cfg.iface); return 1; }

    for (int i = 0; i < cfg.n_allow; i++)
        if (cfg.allow[i].port == 22) has22 = 1;
    if (!cfg.ssh_open && !has22)
        fprintf(stderr, "WARNING: SSH (22) закрыт для всех: список allow_ssh пуст, а ssh_mode != all\n");

    mkdir(PIN_DIR, 0700);
    LIBBPF_OPTS(bpf_object_open_opts, opts, .pin_root_path = PIN_DIR);
    struct bpf_object *obj = bpf_object__open_file(OBJ_PATH, &opts);
    if (!obj) { fprintf(stderr, "cannot open %s\n", OBJ_PATH); return 1; }
    if (bpf_object__load(obj)) { fprintf(stderr, "bpf load failed\n"); return 1; }

    struct bpf_map *m_wl = bpf_object__find_map_by_name(obj, "whitelist");
    struct bpf_map *m_ban = bpf_object__find_map_by_name(obj, "banlist");
    struct bpf_map *m_slots = bpf_object__find_map_by_name(obj, "slots");
    struct bpf_map *m_cnt = bpf_object__find_map_by_name(obj, "ip_cnt");
    struct bpf_map *m_acl = bpf_object__find_map_by_name(obj, "acl_tcp");
    struct bpf_map *m_cfg = bpf_object__find_map_by_name(obj, "fw_cfg");
    struct bpf_program *prog = bpf_object__find_program_by_name(obj, "xdp_fw");
    if (!m_wl || !m_ban || !m_slots || !m_cnt || !m_acl || !m_cfg || !prog) {
        fprintf(stderr, "maps/program not found in object\n");
        return 1;
    }
    int fd_wl = bpf_map__fd(m_wl), fd_ban = bpf_map__fd(m_ban);
    int fd_slots = bpf_map__fd(m_slots), fd_cnt = bpf_map__fd(m_cnt);
    int fd_acl = bpf_map__fd(m_acl), fd_cfg = bpf_map__fd(m_cfg);

    sync_acl(fd_acl, &cfg);
    push_cfg_map(fd_cfg, &cfg);

    if (attach_xdp(ifindex, bpf_program__fd(prog))) {
        fprintf(stderr, "XDP attach failed on %s\n", cfg.iface);
        return 1;
    }
    print_cfg_line(&cfg, "xdpfw started:");
    warn_udp(&cfg);

    /* ограничение скорости: его сбой не должен ронять файрвол */
    memset(&sh, 0, sizeof(sh));
    shape_lazy(&sh, ifindex, &cfg);
    shape_apply(&sh, &cfg);
    last_save = mono_ns();
    fflush(stdout);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sig;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    while (!g_stop) {
        uint64_t now;
        sleep(1);
        if (g_stop)
            break;
        if (g_reload) {
            struct config n;
            g_reload = 0;
            if (load_cfg(&n) == 0) {
                snprintf(n.iface, sizeof(n.iface), "%s", cfg.iface);
                if (sh.ok && n.sh_window_min != sh.window_min) {
                    shape_reset(&sh);                /* окно изменилось: накопленная история несопоставима */
                    sh.window_min = n.sh_window_min;
                    puts("shape: окно изменено, история сброшена");
                }
                if (n.ip_limit_per_dst != cfg.ip_limit_per_dst || !n.ip_limit)
                    slots_clear(fd_slots, fd_cnt);
                cfg = n;
                sync_acl(fd_acl, &cfg);
                push_cfg_map(fd_cfg, &cfg);
                shape_lazy(&sh, ifindex, &cfg);
                shape_apply(&sh, &cfg);
                print_cfg_line(&cfg, "config reloaded:");
                warn_udp(&cfg);
            }
        }
        scan(fd_wl, fd_ban, fd_slots, fd_cnt, &cfg);

        now = mono_ns();
        if (sh.ok && sh.attached && now - last_shape >= cfg.sh_check * SEC_NS) {
            shape_scan(&sh, &cfg);
            last_shape = now;
        }
        if (sh.ok && now - last_save >= 300 * SEC_NS) {
            state_save(&sh, &cfg);
            last_save = now;
        }
        fflush(stdout);
    }
    if (sh.ok)
        state_save(&sh, &cfg);
    return 0;
}

static int cmd_detach(void)
{
    struct config cfg;
    if (load_cfg(&cfg)) return 1;
    int ifindex = if_nametoindex(cfg.iface);
    if (!ifindex) return 1;
    detach_xdp(ifindex);
    tc_detach(ifindex, BPF_TC_EGRESS);
    tc_detach(ifindex, BPF_TC_INGRESS);
    if (if_nametoindex(IFB_NAME))
        if (system("ip link del " IFB_NAME " 2>/dev/null") != 0)
            fprintf(stderr, "не удалось удалить %s\n", IFB_NAME);
    printf("XDP и tc (egress, ingress) сняты с %s\n", cfg.iface);
    return 0;
}

static void dump_list(const char *title, int fd)
{
    struct addr_key cur, next;
    char buf[INET6_ADDRSTRLEN];
    uint64_t v, now = mono_ns();
    int n = 0;
    int r = bpf_map_get_next_key(fd, NULL, &next);

    printf("%s:\n", title);
    while (r == 0) {
        cur = next;
        r = bpf_map_get_next_key(fd, &cur, &next);
        if (bpf_map_lookup_elem(fd, &cur, &v) == 0 && v > now) {
            printf("  %-40s осталось %llu мин\n", ip_str(&cur, buf, sizeof(buf)),
                   (unsigned long long)((v - now) / SEC_NS / 60));
            n++;
        }
    }
    if (!n) puts("  (пусто)");
}

/* Вывод текущих активных IP в слотах (клиенты вне whitelist на TCP 443) */
static void dump_slots(int fd_slots, int fd_wl, const struct config *c)
{
    struct slot_key cur, next;
    char sbuf[INET6_ADDRSTRLEN], dbuf[INET6_ADDRSTRLEN];
    uint64_t v, now = mono_ns(), idle = c->ip_limit_idle * SEC_NS;
    int n = 0;

    printf("Активные IP в слотах на 443 (вне whitelist):\n");
    if (!c->ip_limit) {
        puts("  (лимит IP выключен)");
        return;
    }
    if (fd_slots < 0) {
        puts("  (пусто)");
        return;
    }
    int r = bpf_map_get_next_key(fd_slots, NULL, &next);
    while (r == 0) {
        cur = next;
        r = bpf_map_get_next_key(fd_slots, &cur, &next);
        if (bpf_map_lookup_elem(fd_slots, &cur, &v) != 0)
            continue;
        if (now > v && now - v > idle)
            continue;
        if (fd_wl >= 0 && map_active(fd_wl, &cur.src, now))
            continue;
        uint64_t elapsed = now > v ? now - v : 0;
        uint64_t rem_ms = idle > elapsed ? (idle - elapsed) / 1000000ULL : 0;
        if (c->ip_limit_per_dst) {
            printf("  %-40s -> %-18s (осталось %.1f с)\n",
                   ip_str(&cur.src, sbuf, sizeof(sbuf)),
                   ip_str(&cur.dst, dbuf, sizeof(dbuf)),
                   (double)rem_ms / 1000.0);
        } else {
            printf("  %-40s осталось %.1f с\n",
                   ip_str(&cur.src, sbuf, sizeof(sbuf)),
                   (double)rem_ms / 1000.0);
        }
        n++;
    }
    if (!n)
        puts("  (пусто)");
}

static void dump_top(int fd_hist, const char *title, const struct config *c)
{
    struct addr_key top_k[5], cur, next;
    uint64_t top_v[5];
    char buf[INET6_ADDRSTRLEN];
    int nt = 0;
    int r = bpf_map_get_next_key(fd_hist, NULL, &next);

    while (r == 0) {
        struct hist h;
        uint64_t sum = 0;
        int pos;
        cur = next;
        r = bpf_map_get_next_key(fd_hist, &cur, &next);
        if (bpf_map_lookup_elem(fd_hist, &cur, &h))
            continue;
        for (int i = 0; i < NB; i++)
            sum += h.b[i];
        if (sum == 0 || (nt == 5 && sum <= top_v[4]))
            continue;
        pos = nt < 5 ? nt++ : 4;
        top_k[pos] = cur;
        top_v[pos] = sum;
        while (pos > 0 && top_v[pos] > top_v[pos - 1]) {
            struct addr_key tk = top_k[pos];
            uint64_t tv = top_v[pos];
            top_k[pos] = top_k[pos - 1]; top_v[pos] = top_v[pos - 1];
            top_k[pos - 1] = tk;         top_v[pos - 1] = tv;
            pos--;
        }
    }
    printf("Топ по средней скорости %s за окно %llu мин (порог %llu Мбит/с):\n", title,
           (unsigned long long)c->sh_window_min, (unsigned long long)c->sh_avg_mbps);
    if (!nt)
        puts("  (нет данных)");
    for (int i = 0; i < nt; i++)
        printf("  %-40s %.2f Мбит/с (%.2f ГБ)\n", ip_str(&top_k[i], buf, sizeof(buf)),
               (double)top_v[i] * 8.0 / (double)sh_window_sec(c) / 1e6, (double)top_v[i] / 1e9);
}

static void dump_shape(const struct config *c)
{
    int fd_pen = bpf_obj_get(PIN_DIR "/bw_pen");
    int fd_hist = bpf_obj_get(PIN_DIR "/bw_hist");
    int fd_hist_in = bpf_obj_get(PIN_DIR "/bw_hist_in");

    if (fd_pen < 0 || fd_hist < 0) {
        puts("Ограничение скорости: не активно");
        return;
    }
    dump_list("Ограничены по скорости (shaping, в обе стороны)", fd_pen);
    dump_top(fd_hist, "исходящего трафика VPS -> IP", c);
    if (fd_hist_in >= 0)
        dump_top(fd_hist_in, "входящего трафика IP -> VPS", c);
}

static int cmd_status(void)
{
    struct config cfg;
    int fd_wl = bpf_obj_get(PIN_DIR "/whitelist");
    int fd_ban = bpf_obj_get(PIN_DIR "/banlist");
    int fd_dr = bpf_obj_get(PIN_DIR "/fw_drops");
    int fd_cnt = bpf_obj_get(PIN_DIR "/ip_cnt");
    int fd_slots = bpf_obj_get(PIN_DIR "/slots");
    if (fd_wl < 0 || fd_ban < 0 || fd_dr < 0) {
        fprintf(stderr, "xdpfw не запущен (нет pinned maps в %s)\n", PIN_DIR);
        return 1;
    }
    if (load_cfg(&cfg) == 0) {
        char ud[160];
        udp_desc(&cfg, ud, sizeof(ud));
        printf("SSH 22: %s | UDP для whitelist: %s | whitelist: %llu ч, продление раз в %llu мин\n",
               cfg.ssh_open ? "открыт всем" : "только список", ud,
               (unsigned long long)(cfg.wl_ttl / 3600), (unsigned long long)(cfg.wl_refresh / 60));
        printf("Антифлуд: %llu пак. и %llu SYN за %llu с, бан %llu мин\n",
               (unsigned long long)cfg.flood_pkts, (unsigned long long)cfg.flood_syn,
               (unsigned long long)cfg.flood_window, (unsigned long long)(cfg.ban_sec / 60));
        printf("Антифлуд whitelist: %s (%llu пак. и %llu SYN за %llu с, бан %llu мин)\n",
               cfg.wl_flood ? "вкл" : "выкл", (unsigned long long)cfg.wl_flood_pkts,
               (unsigned long long)cfg.wl_flood_syn, (unsigned long long)cfg.wl_flood_window,
               (unsigned long long)(cfg.wl_ban_sec / 60));
        if (fd_cnt >= 0) {
            if (cfg.ip_limit_per_dst) {
                struct addr_key cur, next;
                uint32_t used = 0, total = 0, n_dst = 0;
                int r = bpf_map_get_next_key(fd_cnt, NULL, &next);
                while (r == 0) {
                    cur = next;
                    r = bpf_map_get_next_key(fd_cnt, &cur, &next);
                    if (bpf_map_lookup_elem(fd_cnt, &cur, &used) == 0 && used > 0) {
                        total += used;
                        n_dst++;
                    }
                }
                printf("Лимит IP на 443: %s (на каждый IP в %s: до %llu, слот %llu с), занято слотов %u (активных IP %s: %u)\n",
                       cfg.ip_limit ? "вкл" : "выкл", cfg.iface,
                       (unsigned long long)cfg.ip_limit_max, (unsigned long long)cfg.ip_limit_idle,
                       total, cfg.iface, n_dst);
                if (n_dst > 0) {
                    char dbuf[INET6_ADDRSTRLEN];
                    r = bpf_map_get_next_key(fd_cnt, NULL, &next);
                    while (r == 0) {
                        cur = next;
                        r = bpf_map_get_next_key(fd_cnt, &cur, &next);
                        if (bpf_map_lookup_elem(fd_cnt, &cur, &used) == 0 && used > 0)
                            printf("  слоты на %-35s %u из %llu\n",
                                   ip_str(&cur, dbuf, sizeof(dbuf)), used,
                                   (unsigned long long)cfg.ip_limit_max);
                    }
                }
            } else {
                struct addr_key zk = {};
                uint32_t used = 0;
                bpf_map_lookup_elem(fd_cnt, &zk, &used);
                printf("Лимит IP на 443: %s (общий на %s, слот %llu с), занято слотов %u из %llu\n",
                       cfg.ip_limit ? "вкл" : "выкл", cfg.iface,
                       (unsigned long long)cfg.ip_limit_idle, used,
                       (unsigned long long)cfg.ip_limit_max);
            }
        }
        printf("Ограничение скорости (исходящий и входящий трафик, каждый отдельно): авто=%s "
               "(среднее за %llu мин > %llu Мбит/с ≈ %.1f ГБ в любую сторону -> %llu Мбит/с в каждую сторону на %llu ч), "
               "лимит каждого IP=%s (%llu Мбит/с в каждую сторону), входящий трафик=%s\n",
               cfg.sh_auto ? "вкл" : "выкл", (unsigned long long)cfg.sh_window_min,
               (unsigned long long)cfg.sh_avg_mbps, (double)sh_threshold(&cfg) / 1e9,
               (unsigned long long)cfg.sh_pen_mbps, (unsigned long long)cfg.sh_pen_hours,
               cfg.sh_cap ? "вкл" : "выкл", (unsigned long long)cfg.sh_cap_mbps,
               cfg.sh_up ? "вкл" : "выкл");
    }
    int ncpu = libbpf_num_possible_cpus();
    uint64_t *v = calloc(ncpu > 0 ? ncpu : 1, sizeof(uint64_t));
    uint64_t sum = 0;
    uint32_t z = 0;
    if (v && bpf_map_lookup_elem(fd_dr, &z, v) == 0)
        for (int i = 0; i < ncpu; i++) sum += v[i];
    printf("Отброшено пакетов: %llu\n", (unsigned long long)sum);
    dump_slots(fd_slots, fd_wl, &cfg);
    dump_list("Whitelist (авторизованы в Xray)", fd_wl);
    dump_list("Заблокированы на 443 (флуд)", fd_ban);
    dump_shape(&cfg);
    free(v);
    return 0;
}

static int cmd_unban(const char *ip)
{
    struct addr_key k;
    int fd = bpf_obj_get(PIN_DIR "/banlist");
    if (fd < 0) { fprintf(stderr, "xdpfw не запущен\n"); return 1; }

    if (ip && !strcmp(ip, "all")) {
        map_clear(fd);
        puts("все блокировки сняты");
        return 0;
    }
    if (!ip || parse_ip(ip, &k)) { fprintf(stderr, "usage: xdpfw unban <ip|all>\n"); return 1; }
    if (bpf_map_delete_elem(fd, &k) == 0) printf("unbanned %s\n", ip);
    else printf("%s не был заблокирован\n", ip);
    return 0;
}

/* Снять ограничение скорости вручную. Историю IP обнуляем, иначе оно сработало бы снова сразу. */
static int cmd_unshape(const char *ip)
{
    struct config cfg;
    struct shape_rt sh;
    struct addr_key k, cur, next;
    uint64_t curb;
    int r;

    memset(&sh, 0, sizeof(sh));
    if (load_cfg(&cfg)) return 1;
    sh.fd_pen = bpf_obj_get(PIN_DIR "/bw_pen");
    sh.fd_ip = bpf_obj_get(PIN_DIR "/bw_ip");
    sh.fd_hist = bpf_obj_get(PIN_DIR "/bw_hist");
    sh.fd_ip_in = bpf_obj_get(PIN_DIR "/bw_ip_in");
    sh.fd_hist_in = bpf_obj_get(PIN_DIR "/bw_hist_in");
    if (sh.fd_pen < 0 || sh.fd_ip < 0 || sh.fd_hist < 0) { fprintf(stderr, "xdpfw не запущен\n"); return 1; }
    curb = real_sec() / sh_bucket_sec(&cfg);

    if (ip && !strcmp(ip, "all")) {
        r = bpf_map_get_next_key(sh.fd_pen, NULL, &next);
        while (r == 0) {
            cur = next;
            r = bpf_map_get_next_key(sh.fd_pen, &cur, &next);
            reset_hist_for(&sh, &cur, curb);
            bpf_map_delete_elem(sh.fd_pen, &cur);
        }
        puts("все ограничения скорости сняты");
        return 0;
    }
    if (!ip || parse_ip(ip, &k)) { fprintf(stderr, "usage: xdpfw unshape <ip|all>\n"); return 1; }
    reset_hist_for(&sh, &k, curb);
    if (bpf_map_delete_elem(sh.fd_pen, &k) == 0) printf("ограничение скорости снято с %s\n", ip);
    else printf("%s не был ограничен\n", ip);
    return 0;
}

/*
 * Вызывается xdpfw-xray-poll: IP, авторизованные в Xray -> whitelist.
 * Новый IP добавляется сразу, а у уже добавленного запись продлевается не чаще
 * раза в whitelist_refresh_minutes (по умолчанию раз в час) — это экономит работу.
 * IP занимает слот в лимите IP, пока не попал в whitelist: после добавления слот освобождаем.
 * При добавлении нового IP в whitelist он также снимается с блокировки (banlist).
 */
static int cmd_wl_add(int argc, char **argv)
{
    struct config cfg;
    char buf[INET6_ADDRSTRLEN];
    if (load_cfg(&cfg)) return 1;
    int fd_wl = bpf_obj_get(PIN_DIR "/whitelist");
    int fd_slots = bpf_obj_get(PIN_DIR "/slots");
    int fd_cnt = bpf_obj_get(PIN_DIR "/ip_cnt");
    int fd_ban = bpf_obj_get(PIN_DIR "/banlist");
    if (fd_wl < 0) { fprintf(stderr, "xdpfw не запущен\n"); return 1; }

    uint64_t now = mono_ns();
    uint64_t ttl_ns = cfg.wl_ttl * SEC_NS;
    uint64_t refresh_ns = cfg.wl_refresh * SEC_NS;
    if (refresh_ns > ttl_ns / 2)
        refresh_ns = ttl_ns / 2;
    uint64_t exp = now + ttl_ns;

    for (int i = 2; i < argc; i++) {
        struct addr_key k;
        uint64_t cur;
        if (parse_ip(argv[i], &k) || is_special(&k))
            continue;
        int active = bpf_map_lookup_elem(fd_wl, &k, &cur) == 0 && cur > now;
        if (!active)
            free_src_slots(fd_slots, fd_cnt, &k);
        if (active && cur > now + ttl_ns - refresh_ns)
            continue;                       /* запись обновлялась недавно */
        bpf_map_update_elem(fd_wl, &k, &exp, BPF_ANY);
        if (!active) {
            printf("whitelist +%s на %llu ч\n", ip_str(&k, buf, sizeof(buf)),
                   (unsigned long long)(cfg.wl_ttl / 3600));
            /* IP авторизован в Xray -> снимаем с него блокировку (если была) */
            if (fd_ban >= 0 && bpf_map_delete_elem(fd_ban, &k) == 0)
                printf("unban %s (добавлен в whitelist)\n", ip_str(&k, buf, sizeof(buf)));
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *cmd = argc > 1 ? argv[1] : "run";
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (!strcmp(cmd, "run"))     return cmd_run();
    if (!strcmp(cmd, "detach"))  return cmd_detach();
    if (!strcmp(cmd, "status"))  return cmd_status();
    if (!strcmp(cmd, "unban"))   return cmd_unban(argc > 2 ? argv[2] : NULL);
    if (!strcmp(cmd, "unshape")) return cmd_unshape(argc > 2 ? argv[2] : NULL);
    if (!strcmp(cmd, "wl-add"))  return cmd_wl_add(argc, argv);
    fprintf(stderr, "usage: xdpfw run|detach|status|unban <ip|all>|unshape <ip|all>|wl-add <ip>...\n");
    return 1;
}
C_EOF

cat > /usr/local/sbin/xdpfw-xray-poll <<'POLL_EOF'
#!/usr/bin/env bash
# xdpfw-xray-poll — whitelist из авторизованных пользователей Xray.
#
# Логика monitor.sh: динамический abstract-сокет XTLS remnanode -> socat -> 127.0.0.1:PORT,
# затем `xray api statsonlineiplist -all` и разбор IP. Оптимизации по нагрузке:
#   * xray CLI копируется из контейнера на хост один раз (docker cp) — ни одного docker exec
#     за цикл; имя сокета читается прямо с файловой системы контейнера через /proc/<pid>/root;
#   * конфиг читается встроенными средствами bash раз в 30 с, пауза между опросами — builtin read;
#   * IP разбираются регулярками bash (без grep/sort), неизменный ответ не разбирается заново;
#   * в whitelist уходят только новые IP и те, чью запись пора продлить (раз в час).
set -u

CONF="${XDPFW_CONF:-/etc/xdpfw/xdpfw.conf}"
XDPFW="${XDPFW_BIN:-/usr/local/sbin/xdpfw}"
IP_RE='([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}'
ERR_RE='unknown command|failed to|rpc error|connection refused|deadline exceeded'

declare -A C=() ADDED=()
CONTAINER=remnanode; XRAY_BIN=/usr/local/bin/xray; CLI=/usr/local/lib/xdpfw/xray-cli
PORT=18085; INTERVAL=2; REFRESH=3600
BRIDGE_PID=""; BRIDGE_SOCK=""; LAST_ERR=""; LAST_RAW=""; CPID=""; SOCKET_NAME=""
CLI_TRY=0; NEXT_FULL=0; FORCE_SOCK=0; SOCK_CHECK_AT=0; SOCK_READ_AT=0; PRUNED=0

log() { echo "$*"; }
warn() { if [ "$1" != "$LAST_ERR" ]; then log "WARN: $1"; LAST_ERR="$1"; fi; }

load_conf()
{
    local k v m
    C=()
    if [ -r "$CONF" ]; then
        while IFS='=' read -r k v || [ -n "$k" ]; do
            [[ "$k" =~ ^[a-z0-9_]+$ ]] && C[$k]="${v%$'\r'}"
        done < "$CONF"
    fi
    CONTAINER="${C[xray_container]:-remnanode}"
    [ "$CONTAINER" = "auto" ] && CONTAINER=remnanode
    XRAY_BIN="${C[xray_bin]:-/usr/local/bin/xray}"
    [ "$XRAY_BIN" = "auto" ] && XRAY_BIN=/usr/local/bin/xray
    CLI="${C[xray_cli]:-/usr/local/lib/xdpfw/xray-cli}"
    PORT="${C[bridge_port]:-18085}"
    [[ "$PORT" =~ ^[0-9]+$ ]] || PORT=18085
    INTERVAL="${C[poll_interval]:-2}"
    [[ "$INTERVAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] || INTERVAL=2
    m="${C[whitelist_refresh_minutes]:-60}"
    [[ "$m" =~ ^[0-9]+$ ]] || m=60
    REFRESH=$(( m * 60 ))
}

# пауза без запуска внешнего sleep
FIFO="$(mktemp -u /tmp/xdpfw-poll.XXXXXX)"
if mkfifo "$FIFO" 2>/dev/null && exec {SFD}<>"$FIFO"; then
    rm -f "$FIFO"
    nap() { read -r -t "$INTERVAL" -u "$SFD" _ || true; }
else
    nap() { sleep "$INTERVAL"; }
fi

stop_bridge()
{
    if [ -n "$BRIDGE_PID" ]; then
        kill "$BRIDGE_PID" 2>/dev/null || true
        wait "$BRIDGE_PID" 2>/dev/null || true
    fi
    BRIDGE_PID=""
    BRIDGE_SOCK=""
}
trap 'stop_bridge; exit 0' INT TERM
trap 'stop_bridge' EXIT

# имя динамического XTLS-сокета: читаем файл контейнера прямо с хоста
read_socket()
{
    local f name=""
    SOCKET_NAME=""
    if [ -n "$CPID" ] && [ "$CPID" != "0" ]; then
        f="/proc/$CPID/root/run/s6/container_environment/XTLS_API_SOCKET_PATH"
        [ -r "$f" ] && IFS= read -r name < "$f"
    fi
    if [ -z "$name" ]; then
        # контейнер перезапускался или путь недоступен: обновляем PID и пробуем ещё раз
        CPID="$(docker inspect -f '{{.State.Pid}}' "$CONTAINER" 2>/dev/null)"
        if [ -n "$CPID" ] && [ "$CPID" != "0" ]; then
            f="/proc/$CPID/root/run/s6/container_environment/XTLS_API_SOCKET_PATH"
            [ -r "$f" ] && IFS= read -r name < "$f"
        fi
    fi
    if [ -z "$name" ]; then
        name="$(docker exec "$CONTAINER" sh -c 'cat /run/s6/container_environment/XTLS_API_SOCKET_PATH 2>/dev/null' 2>/dev/null | tr -d '\r\n')"
    fi
    SOCKET_NAME="${name%$'\r'}"
}

start_bridge()
{
    local uf="${XDPFW_UNIX_FILE:-/proc/${CPID:-self}/net/unix}"
    stop_bridge
    if ! grep -q "@${SOCKET_NAME}" "$uf" 2>/dev/null; then
        warn "XTLS-сокет @${SOCKET_NAME} не активен (Xray не запущен?)"
        return 1
    fi
    pkill -f "socat.*TCP-LISTEN:${PORT}" 2>/dev/null || true
    sleep 0.2
    socat "TCP-LISTEN:${PORT},bind=127.0.0.1,reuseaddr,fork" \
          "ABSTRACT-CONNECT:${SOCKET_NAME}" >/dev/null 2>&1 &
    BRIDGE_PID=$!
    BRIDGE_SOCK="$SOCKET_NAME"
    sleep 0.5
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
        BRIDGE_PID=""
        BRIDGE_SOCK=""
        warn "socat не запустился (порт ${PORT} занят?)"
        return 1
    fi
    log "мост: @${SOCKET_NAME} -> 127.0.0.1:${PORT}"
    return 0
}

# xray CLI на хосте (копия из контейнера); возвращает 0, если он доступен
ensure_cli()
{
    local now
    [ -x "$CLI" ] && return 0
    printf -v now '%(%s)T' -1
    (( now - CLI_TRY < 60 )) && return 1
    CLI_TRY=$now
    mkdir -p "$(dirname "$CLI")"
    if docker cp "${CONTAINER}:${XRAY_BIN}" "${CLI}.new" >/dev/null 2>&1; then
        chmod 755 "${CLI}.new"
        mv -f "${CLI}.new" "$CLI"
        log "xray CLI скопирован из контейнера: $CLI"
        return 0
    fi
    warn "не удалось скопировать xray из контейнера, работаю через docker exec"
    return 1
}

cycle()
{
    local RAW rc low now ip last s i need
    local -A SEEN=()
    local -a NEW=()

    # имя сокета меняется только при перезапуске Xray/контейнера: перечитываем раз в 30 с или после ошибки API
    printf -v now '%(%s)T' -1
    need=0
    if [ -z "$SOCKET_NAME" ] || [ "$FORCE_SOCK" = "1" ] || (( now >= SOCK_CHECK_AT )); then need=1; fi
    if [ "$need" = "1" ] && (( now - SOCK_READ_AT >= 10 )); then      # не чаще раза в 10 с
        read_socket
        FORCE_SOCK=0
        SOCK_READ_AT=$now
        SOCK_CHECK_AT=$(( now + 30 ))
    fi
    if [ -z "$SOCKET_NAME" ]; then
        stop_bridge
        warn "XTLS_API_SOCKET_PATH не найден (контейнер $CONTAINER запущен?)"
        return 1
    fi
    if [ "$SOCKET_NAME" != "$BRIDGE_SOCK" ] || [ -z "$BRIDGE_PID" ] || ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
        start_bridge || return 1
    fi

    # ВСЕ online-пользователи и их IP
    if ensure_cli; then
        RAW="$("$CLI" api statsonlineiplist -s "127.0.0.1:${PORT}" -t 3 -all 2>&1)"; rc=$?
    else
        RAW="$(docker exec "$CONTAINER" "$XRAY_BIN" api statsonlineiplist -s "127.0.0.1:${PORT}" -t 3 -all 2>&1)"; rc=$?
    fi
    low="${RAW,,}"
    if [ $rc -ne 0 ] || [[ "$low" =~ $ERR_RE ]]; then
        [[ "$low" =~ unknown\ command ]] && rm -f "$CLI"      # старая копия CLI: перекопируем
        LAST_RAW=""
        FORCE_SOCK=1                                          # возможно, Xray перезапустился: имя сокета сменилось
        warn "Xray API: ${RAW:0:300}"
        return 1
    fi
    LAST_ERR=""

    # ответ не изменился и продлевать пока рано — ничего не разбираем
    if [ "$RAW" = "$LAST_RAW" ] && (( now < NEXT_FULL )); then
        return 0
    fi
    LAST_RAW="$RAW"
    NEXT_FULL=$(( now + 30 ))

    # IPv4 / IPv6 из JSON: только новые и те, чью запись пора продлить
    s="$RAW"
    while [[ "$s" =~ $IP_RE ]]; do
        ip="${BASH_REMATCH[0]}"
        s="${s#*"$ip"}"
        [ -n "${SEEN[$ip]:-}" ] && continue
        SEEN[$ip]=1
        last="${ADDED[$ip]:-0}"
        if (( now - last >= REFRESH )); then
            ADDED[$ip]=$now
            NEW+=("$ip")
        fi
    done

    for (( i = 0; i < ${#NEW[@]}; i += 100 )); do
        if ! "$XDPFW" wl-add "${NEW[@]:i:100}"; then
            for ip in "${NEW[@]:i:100}"; do unset 'ADDED[$ip]'; done
        fi
    done

    # чистим память от IP, которые давно не появлялись
    if (( now - ${PRUNED:-0} > 3600 )); then
        PRUNED=$now
        for ip in "${!ADDED[@]}"; do
            (( now - ADDED[$ip] > 2 * REFRESH + 60 )) && unset 'ADDED[$ip]'
        done
    fi
    return 0
}

load_conf
n=0
while true; do
    cycle || true
    n=$(( n + 1 ))
    [ "${MAX_CYCLES:-0}" != "0" ] && [ "$n" -ge "${MAX_CYCLES:-0}" ] && break
    (( n % 15 == 0 )) && load_conf
    nap
done
POLL_EOF
chmod 755 /usr/local/sbin/xdpfw-xray-poll

cat > /usr/local/sbin/xdpfw-menu <<'MENU_EOF'
#!/usr/bin/env bash
# xdpfw-menu — меню управления XDP-файрволом
CONF="${XDPFW_CONF:-/etc/xdpfw/xdpfw.conf}"
XDPFW="${XDPFW_BIN:-/usr/local/sbin/xdpfw}"

if [[ -z "${XDPFW_TEST:-}" && $EUID -ne 0 ]]; then
    echo "Запустите от root: sudo xdpfw-menu"
    exit 1
fi
[[ -f "$CONF" ]] || { echo "Не найден $CONF"; exit 1; }

# ---------- работа с конфигом ----------
cfg_get()  { local v; v="$(grep -m1 "^$1=" "$CONF" | cut -d= -f2- | tr -d '\r')"; echo "${v:-${2:-}}"; }
cfg_list() { grep "^$1=" "$CONF" | cut -d= -f2- | tr -d '\r'; }
cfg_set()  {
    if grep -q "^$1=" "$CONF"; then sed -i "s|^$1=.*|$1=$2|" "$CONF"; else echo "$1=$2" >> "$CONF"; fi
}
cfg_add()  { grep -qx "$1=$2" "$CONF" || echo "$1=$2" >> "$CONF"; }
cfg_del()  { local v="${2//./\\.}"; sed -i "\|^$1=${v}\$|d" "$CONF"; }
cfg_del_all() { sed -i "/^$1=/d" "$CONF"; }

is_on()  { case "${1,,}" in yes|true|1|on) return 0;; *) return 1;; esac; }
onoff()  { if is_on "$1"; then echo "ВКЛ"; else echo "ВЫКЛ"; fi; }
valid_ip() { python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$1" 2>/dev/null; }
is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }
pause()  { read -r -p "Enter — продолжить..." _ || exit 0; }

apply() {
    if systemctl reload xdpfw 2>/dev/null; then
        echo "✔ Применено."
    else
        echo "⚠ Не удалось применить: сервис xdpfw не запущен. Запустите: systemctl restart xdpfw"
    fi
}

# read_num "вопрос" min max  -> NUM (код 1, если отмена/ошибка)
read_num() {
    local v
    read -r -p "$1" v || exit 0
    [[ -z "$v" ]] && return 1
    if is_num "$v" && (( v >= $2 && v <= $3 )); then NUM="$v"; return 0; fi
    echo "Некорректное значение (нужно число от $2 до $3)."
    return 1
}

# сколько ГБ (десятичных) соответствует средней скорости <Мбит/с> за окно <минут>: Мбит/с * 125000 Б/с * секунд
gb_of() { awk -v m="$1" -v w="$2" 'BEGIN{printf "%.1f", m*125000*w*60/1e9}'; }

my_ip() { local ip="${SSH_CLIENT:-}"; echo "${ip%% *}"; }

# предупреждение, если после изменения SSH-доступа вас отключит
check_lockout() {
    [[ "$(cfg_get ssh_mode list)" == "list" ]] || return 0
    local me; me="$(my_ip)"
    [[ -n "$me" ]] || return 0
    if ! cfg_list allow_ssh | grep -qx "$me"; then
        local a
        read -r -p "ВНИМАНИЕ: ваш IP ($me) не в списке SSH — вас отключит. Продолжить? [y/N] " a || return 1
        [[ "$a" =~ ^[yY]$ ]] || return 1
    fi
    return 0
}

# ---------- экран ----------
header() {
    clear 2>/dev/null || true
    local n ssh f wf il sa sc gb ifc ud
    ifc="$(cfg_get iface ens3)"
    n="$(cfg_list allow_ssh | grep -c .)"
    if [[ "$(cfg_get ssh_mode list)" == "all" ]]; then ssh="открыт ВСЕМ"; else ssh="только список ($n IP)"; fi
    if [[ "$(cfg_get flood_packets 800)" == "0" ]]; then
        f="ВЫКЛ"
    else
        f="$(cfg_get flood_packets 800) пак., $(cfg_get flood_syn 25) SYN / $(cfg_get flood_window 1) с; бан $(cfg_get ban_minutes 60) мин"
    fi
    if is_on "$(cfg_get wl_flood no)"; then
        wf="ВКЛ: $(cfg_get wl_flood_packets 150000) пак., $(cfg_get wl_flood_syn 300) SYN / $(cfg_get wl_flood_window 1) с; бан $(cfg_get wl_ban_minutes 10) мин"
    else
        wf="ВЫКЛ (whitelist не проверяется)"
    fi
    if is_on "$(cfg_get ip_limit yes)"; then
        if is_on "$(cfg_get ip_limit_per_dst yes)"; then
            il="ВКЛ: не более $(cfg_get ip_limit_max 50) IP вне whitelist на КАЖДЫЙ IP в $ifc (слот $(cfg_get ip_limit_idle 1) с)"
        else
            il="ВКЛ: не более $(cfg_get ip_limit_max 50) IP вне whitelist (общий на $ifc, слот $(cfg_get ip_limit_idle 1) с)"
        fi
    else
        il="ВЫКЛ"
    fi
    if is_on "$(cfg_get udp443_whitelist no)"; then
        ud="ВКЛ (открыт только для whitelist: $(udp_desc))"
    else
        ud="ВЫКЛ (UDP закрыт для всех)"
    fi
    gb="$(gb_of "$(cfg_get shape_avg_mbps 50)" "$(cfg_get shape_window_min 60)")"
    if is_on "$(cfg_get shape_auto no)"; then
        sa="ВКЛ: >$(cfg_get shape_avg_mbps 50) Мбит/с за $(cfg_get shape_window_min 60) мин (≈$gb ГБ) в любую сторону -> $(cfg_get shape_penalty_mbps 25) Мбит/с в каждую сторону на $(cfg_get shape_penalty_hours 24) ч"
    else
        sa="ВЫКЛ"
    fi
    if is_on "$(cfg_get shape_ip_cap no)"; then sc="ВКЛ: $(cfg_get shape_ip_cap_mbps 250) Мбит/с на каждый IP, в каждую сторону"; else sc="ВЫКЛ ($(cfg_get shape_ip_cap_mbps 250) Мбит/с)"; fi
    echo "===================== XDP-файрвол (xdpfw) ====================="
    echo " SSH 22 ........................... $ssh"
    echo " TCP 1433 (нода Remnawave) ........ $(cfg_get allow_1433 '— закрыт —')"
    echo " UDP для whitelist ................ $ud"
    echo " Whitelist ........................ $(cfg_get whitelist_hours 24) ч (продление раз в $(cfg_get whitelist_refresh_minutes 60) мин)"
    echo " Антифлуд (обычные IP) ............ $f"
    echo " Антифлуд (whitelist) ............. $wf"
    echo " Лимит IP на 443 .................. $il"
    echo " Лимит 443 для каждого IP в $ifc .. $(onoff "$(cfg_get ip_limit_per_dst yes)")"
    echo " Скорость: автоограничение ........ $sa"
    echo " Скорость: лимит на каждый IP ..... $sc"
    echo " Скорость: входящий трафик ........ $(onoff "$(cfg_get shape_upload no)") (IP -> VPS; выкл — ограничивается только исходящий)"
    echo " Сервисы: xdpfw=$(systemctl is-active xdpfw 2>/dev/null)  xdpfw-xray=$(systemctl is-active xdpfw-xray 2>/dev/null)"
    echo "==============================================================="
}

# ---------- действия ----------
act_status() { "$XDPFW" status; echo; pause; }

act_ssh_mode() {
    local cur; cur="$(cfg_get ssh_mode list)"
    echo "Сейчас SSH 22: $([[ $cur == all ]] && echo 'открыт ВСЕМ' || echo 'только список IP')"
    echo "  1) только список IP"
    echo "  2) всем"
    read -r -p "Выбор [Enter — отмена]: " c || exit 0
    case "$c" in
        1)
            if [[ -z "$(cfg_list allow_ssh)" ]]; then echo "Список пуст — сначала добавьте IP (пункт 3)."; pause; return; fi
            cfg_set ssh_mode list
            check_lockout || { cfg_set ssh_mode "$cur"; echo "Отменено."; pause; return; }
            apply ;;
        2) cfg_set ssh_mode all; apply ;;
        *) return ;;
    esac
    pause
}

act_ssh_add() {
    echo "IP, допущенные к SSH 22:"
    local i=0 ip
    while read -r ip; do [[ -n "$ip" ]] && { i=$((i+1)); printf '  %2d) %s\n' "$i" "$ip"; }; done < <(cfg_list allow_ssh)
    [[ $i -eq 0 ]] && echo "  (пусто)"
    echo
    read -r -p "Добавить IP (можно несколько через пробел, Enter — отмена): " list || exit 0
    [[ -z "$list" ]] && return
    local added=0
    for ip in $list; do
        if valid_ip "$ip"; then cfg_add allow_ssh "$ip"; echo "  + $ip"; added=1; else echo "  ✗ '$ip' — некорректный IP"; fi
    done
    [[ $added -eq 1 ]] && apply
    pause
}

act_ssh_del() {
    mapfile -t arr < <(cfg_list allow_ssh)
    if [[ ${#arr[@]} -eq 0 ]]; then echo "Список пуст."; pause; return; fi
    local i
    for i in "${!arr[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${arr[$i]}"; done
    read -r -p "Номер IP для удаления (Enter — отмена): " n || exit 0
    [[ -z "$n" ]] && return
    if ! is_num "$n" || (( n < 1 || n > ${#arr[@]} )); then echo "Нет такого номера."; pause; return; fi
    local ip="${arr[$((n-1))]}"
    cfg_del allow_ssh "$ip"
    if [[ "$(cfg_get ssh_mode list)" == "list" ]]; then
        if [[ -z "$(cfg_list allow_ssh)" ]]; then
            echo "Список опустеет — SSH будет закрыт для всех, включая вас!"
        fi
        if ! check_lockout || { [[ -z "$(cfg_list allow_ssh)" ]] && { read -r -p "Всё равно удалить? [y/N] " a; [[ "$a" =~ ^[yY]$ ]] || false; }; }; then
            cfg_add allow_ssh "$ip"; echo "Отменено, $ip возвращён."; pause; return
        fi
    fi
    echo "  - $ip"
    apply
    pause
}

# set_flood <префикс ключа: "" или "wl_"> окно пакеты syn
set_flood() {
    cfg_set "${1}flood_window" "$2"
    cfg_set "${1}flood_packets" "$3"
    cfg_set "${1}flood_syn" "$4"
    apply
}

manual_flood() {  # префикс
    local w p s
    read_num "Окно, секунд (1-3600): " 1 3600 && w="$NUM" || return 1
    read_num "Макс. пакетов с одного IP за окно (1-4000000000): " 1 4000000000 && p="$NUM" || return 1
    read_num "Макс. новых TCP-соединений (SYN) с одного IP за окно (0 — не ограничивать): " 0 4000000000 && s="$NUM" || return 1
    set_flood "$1" "$w" "$p" "$s"
}

act_flood() {
    echo "Антифлуд обычных IP (вне whitelist) на TCP 443 — лимиты на каждый IP:"
    echo "  Сейчас: $(cfg_get flood_packets 800) пакетов и $(cfg_get flood_syn 25) новых соединений за $(cfg_get flood_window 1) с"
    echo
    echo "  1) Низкая        — 5000 пакетов, 150 новых соединений в секунду"
    echo "  2) Средняя       — 2000 пакетов,  60 новых соединений в секунду"
    echo "  3) Высокая       —  800 пакетов,  25 новых соединений в секунду (по умолчанию)"
    echo "  4) Максимальная  —  300 пакетов,  10 новых соединений в секунду"
    echo "  5) Вручную"
    echo "  0) Отключить антифлуд обычных IP"
    read -r -p "Выбор [Enter — отмена]: " c || exit 0
    case "$c" in
        1) set_flood "" 1 5000 150 ;;
        2) set_flood "" 1 2000 60 ;;
        3) set_flood "" 1 800 25 ;;
        4) set_flood "" 1 300 10 ;;
        5) manual_flood "" ;;
        0) cfg_set flood_packets 0; apply ;;
        *) return ;;
    esac
    pause
}

act_ban() {
    echo "Сейчас блокировка обычных IP при флуде: $(cfg_get ban_minutes 60) мин."
    read_num "Новое время в минутах (1-10080, Enter — отмена): " 1 10080 || { pause; return; }
    cfg_set ban_minutes "$NUM"; apply
    pause
}

act_hours() {
    echo "Сейчас IP попадает в whitelist на $(cfg_get whitelist_hours 24) ч."
    read_num "Новое время в часах (1-8760, Enter — отмена): " 1 8760 || { pause; return; }
    cfg_set whitelist_hours "$NUM"; apply
    pause
}

act_wl_flood() {
    while true; do
        header
        echo "---- Антифлуд для IP из whitelist (отдельно от обычного) ----"
        echo "  Состояние: $(onoff "$(cfg_get wl_flood no)")"
        echo "  Лимиты:    $(cfg_get wl_flood_packets 150000) пакетов и $(cfg_get wl_flood_syn 300) новых соединений за $(cfg_get wl_flood_window 1) с"
        echo "  Блокировка: $(cfg_get wl_ban_minutes 10) мин"
        echo
        echo "  1) Включить / выключить"
        echo "  2) Жёсткость (лимиты)"
        echo "  3) Время блокировки (минуты)"
        echo "  0) Назад"
        read -r -p "Выбор: " c || exit 0
        case "$c" in
            1)
                if is_on "$(cfg_get wl_flood no)"; then cfg_set wl_flood no; else cfg_set wl_flood yes; fi
                apply; pause ;;
            2)
                echo
                echo "  1) Низкая        — 300000 пакетов, 600 новых соединений в секунду"
                echo "  2) Средняя       — 150000 пакетов, 300 новых соединений в секунду (по умолчанию)"
                echo "  3) Высокая       —  60000 пакетов, 120 новых соединений в секунду"
                echo "  4) Максимальная  —  20000 пакетов,  40 новых соединений в секунду"
                echo "  5) Вручную"
                echo "  (легитимный клиент на гигабитном канале может слать десятки тысяч пакетов/с)"
                read -r -p "Выбор [Enter — отмена]: " p || exit 0
                case "$p" in
                    1) set_flood wl_ 1 300000 600 ;;
                    2) set_flood wl_ 1 150000 300 ;;
                    3) set_flood wl_ 1 60000 120 ;;
                    4) set_flood wl_ 1 20000 40 ;;
                    5) manual_flood wl_ ;;
                    *) continue ;;
                esac
                pause ;;
            3)
                read_num "Время блокировки в минутах (1-10080, Enter — отмена): " 1 10080 && { cfg_set wl_ban_minutes "$NUM"; apply; }
                pause ;;
            0|"") return ;;
        esac
    done
}

act_ip_limit_per_dst_toggle() {
    local ifc; ifc="$(cfg_get iface ens3)"
    if is_on "$(cfg_get ip_limit_per_dst yes)"; then
        cfg_set ip_limit_per_dst no
        echo "Лимит подключенных IP на 443 для каждого IP в $ifc: ВЫКЛ (теперь общий лимит на весь $ifc)"
    else
        cfg_set ip_limit_per_dst yes
        echo "Лимит подключенных IP на 443 для каждого IP в $ifc: ВКЛ (до $(cfg_get ip_limit_max 50) IP вне whitelist на каждый адрес $ifc)"
    fi
    apply
    pause
}

act_ip_limit() {
    while true; do
        header
        local ifc; ifc="$(cfg_get iface ens3)"
        echo "---- Лимит IP на TCP 443 ----"
        echo "  Пакеты пропускаются не более чем от N разных IP. IP из whitelist не считаются"
        echo "  (у них приоритет), остальные сверх лимита дропаются."
        echo "  Состояние: $(onoff "$(cfg_get ip_limit yes)"),  N = $(cfg_get ip_limit_max 50),  слот освобождается через $(cfg_get ip_limit_idle 1) с без пакетов"
        echo "  Лимит на 443 для каждого IP-адреса в $ifc отдельно: $(onoff "$(cfg_get ip_limit_per_dst yes)")"
        echo
        echo "  1) Включить / выключить лимит IP на 443"
        echo "  2) Изменить N (макс. число IP)"
        echo "  3) Время освобождения слота (секунды, по умолчанию 1)"
        echo "  4) Переключатель: лимит для каждого IP-адреса в $ifc (вкл/выкл)"
        echo "  0) Назад"
        read -r -p "Выбор: " c || exit 0
        case "$c" in
            1)
                if is_on "$(cfg_get ip_limit yes)"; then cfg_set ip_limit no; else cfg_set ip_limit yes; fi
                apply; pause ;;
            2)
                read_num "Новое N (1-60000, Enter — отмена): " 1 60000 && { cfg_set ip_limit_max "$NUM"; apply; }
                pause ;;
            3)
                read_num "Секунд без пакетов до освобождения слота (1-3600, Enter — отмена): " 1 3600 && { cfg_set ip_limit_idle "$NUM"; apply; }
                pause ;;
            4)
                act_ip_limit_per_dst_toggle ;;
            0|"") return ;;
        esac
    done
}

act_1433() {
    echo "TCP 1433 сейчас доступен только с: $(cfg_get allow_1433 '— никому —')"
    read -r -p "Новый IP ('-' — закрыть порт, Enter — отмена): " ip || exit 0
    [[ -z "$ip" ]] && return
    if [[ "$ip" == "-" ]]; then
        cfg_del_all allow_1433; apply
    elif valid_ip "$ip"; then
        cfg_del_all allow_1433; echo "allow_1433=$ip" >> "$CONF"; apply
    else
        echo "Некорректный IP."
    fi
    pause
}

# адреса этого VPS на интерфейсе файрвола (глобальные IPv4/IPv6)
local_ips() {
    ip -o addr show dev "$(cfg_get iface ens3)" scope global 2>/dev/null |
        awk '{split($4, a, "/"); print a[1]}'
}

udp_desc() {
    local ip; ip="$(cfg_get udp_ip any)"
    [[ -z "$ip" || "${ip,,}" == "all" || "$ip" == "*" ]] && ip="any"
    if [[ "$ip" == "any" ]]; then echo "порт $(cfg_get udp_port 443), на любом адресе VPS"
    else echo "порт $(cfg_get udp_port 443), только на адресе $ip"; fi
}

act_udp() {
    local c a ip n i p lo hi list
    while true; do
        header
        echo "---- UDP для IP из whitelist ----"
        if is_on "$(cfg_get udp443_whitelist no)"; then
            echo "  Состояние: ВКЛ — открыт только для whitelist ($(udp_desc))"
        else
            echo "  Состояние: ВЫКЛ — входящий UDP ЗАКРЫТ для всех (при включении: $(udp_desc))"
        fi
        echo "  (Когда ВЫКЛ — любые входящие UDP-соединения блокируются для всех;"
        echo "   когда ВКЛ — UDP-пакеты на выбранный порт пропускаются только от IP из whitelist)"
        echo
        echo "  1) Вкл/выкл (выкл = закрыть UDP для всех)"
        echo "  2) Изменить порт (сейчас $(cfg_get udp_port 443))"
        echo "  3) Выбрать адрес VPS, на котором порт открыт при включении (или любой)"
        echo "  0) Назад"
        read -r -p "Выбор: " c || exit 0
        case "$c" in
            1)
                if is_on "$(cfg_get udp443_whitelist no)"; then cfg_set udp443_whitelist no; else cfg_set udp443_whitelist yes; fi
                apply; pause ;;
            2)
                read_num "UDP-порт (1-65535, Enter — отмена): " 1 65535 || { pause; continue; }
                p="$NUM"
                read -r lo hi < /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || { lo=32768; hi=60999; }
                if (( p >= lo && p <= hi )); then
                    echo "Порт $p входит в диапазон эфемерных портов ($lo-$hi): через него идут ответы на исходящие"
                    echo "соединения сервера. Выберите другой порт."
                else
                    cfg_set udp_port "$p"; apply
                fi
                pause ;;
            3)
                list="$(local_ips)"
                echo "Адреса этого VPS на $(cfg_get iface ens3):"
                n=0
                while read -r ip; do
                    [[ -z "$ip" ]] && continue
                    n=$((n+1)); echo "  $n) $ip"
                done <<< "$list"
                echo "  a) любой адрес VPS (без привязки)"
                read -r -p "Номер, сам IP или 'a' [Enter — отмена]: " a || exit 0
                [[ -z "$a" ]] && { pause; continue; }
                if [[ "${a,,}" == "a" || "${a,,}" == "any" ]]; then
                    cfg_set udp_ip any; apply
                else
                    if [[ "$a" =~ ^[0-9]+$ ]] && (( a >= 1 && a <= n )); then
                        a="$(sed -n "${a}p" <<< "$list")"
                    fi
                    if valid_ip "$a" && grep -qxF "$a" <<< "$list"; then
                        cfg_set udp_ip "$a"; apply
                    else
                        echo "Этот адрес не принадлежит VPS на $(cfg_get iface ens3) — выберите из списка."
                    fi
                fi
                pause ;;
            0|"") return ;;
        esac
    done
}

act_unban() {
    "$XDPFW" status 2>/dev/null | sed -n '/Заблокированы/,$p'
    read -r -p "IP для снятия блокировки ('all' — всех, Enter — отмена): " ip || exit 0
    [[ -z "$ip" ]] && return
    if [[ "$ip" == "all" ]] || valid_ip "$ip"; then "$XDPFW" unban "$ip"; else echo "Некорректный IP."; fi
    pause
}

act_restart() {
    systemctl restart xdpfw && systemctl restart xdpfw-xray && echo "✔ Сервисы перезапущены." || echo "⚠ Ошибка перезапуска."
    pause
}

act_confirm() {
    systemctl stop xdpfw-rollback.timer 2>/dev/null && echo "✔ Авто-откат отменён." || echo "Авто-отката нет."
    pause
}

act_shape() {
    local c g w
    while true; do
        header
        w="$(cfg_get shape_window_min 60)"
        echo "---- Ограничение скорости: исходящий (VPS -> IP) и входящий (IP -> VPS) трафик ----"
        echo "     каждое направление считается отдельно, лимиты действуют на каждое направление отдельно"
        echo "  [A] Автоограничение нарушителей: $(onoff "$(cfg_get shape_auto no)")"
        echo "      средняя скорость за $w мин > $(cfg_get shape_avg_mbps 50) Мбит/с (≈ $(gb_of "$(cfg_get shape_avg_mbps 50)" "$w") ГБ за окно) в ЛЮБУЮ сторону (исходящий и входящий не суммируются)"
        echo "      -> ограничение до $(cfg_get shape_penalty_mbps 25) Мбит/с В КАЖДУЮ СТОРОНУ на $(cfg_get shape_penalty_hours 24) ч, потом снимается само"
        echo "  [B] Лимит скорости для КАЖДОГО IP: $(onoff "$(cfg_get shape_ip_cap no)"), $(cfg_get shape_ip_cap_mbps 250) Мбит/с в каждую сторону"
        echo "  [C] Входящий трафик (IP -> VPS, через IFB): $(onoff "$(cfg_get shape_upload no)")"
        echo
        echo "  1) [A] Автоограничение: вкл/выкл"
        echo "  2) [A] Окно усреднения (минуты, 10-1440)"
        echo "  3) [A] Порог средней скорости (Мбит/с или ГБ за окно)"
        echo "  4) [A] Скорость ограничения нарушителя (Мбит/с, в каждую сторону)"
        echo "  5) [A] Длительность ограничения (часы)"
        echo "  6) [B] Лимит для каждого IP: вкл/выкл"
        echo "  7) [B] Скорость лимита для каждого IP (Мбит/с, в каждую сторону)"
        echo "  8) [C] Учитывать и ограничивать входящий трафик: вкл/выкл"
        echo "  0) Назад"
        read -r -p "Выбор: " c || exit 0
        case "$c" in
            1)
                if is_on "$(cfg_get shape_auto no)"; then cfg_set shape_auto no; else cfg_set shape_auto yes; fi
                apply; pause ;;
            2)
                echo "(при смене окна накопленная история скорости сбрасывается)"
                read_num "Окно в минутах (10-1440, Enter — отмена): " 10 1440 && { cfg_set shape_window_min "$NUM"; apply; }
                pause ;;
            3)
                echo "  1) в Мбит/с"
                echo "  2) в гигабайтах за окно ($w мин)"
                read -r -p "Выбор [Enter — отмена]: " g || exit 0
                case "$g" in
                    1) read_num "Порог, Мбит/с (1-100000): " 1 100000 && { cfg_set shape_avg_mbps "$NUM"; apply; echo "≈ $(gb_of "$NUM" "$w") ГБ за $w мин"; } ;;
                    2)
                        read -r -p "ГБ за $w мин (например 22.5): " g || exit 0
                        if [[ "$g" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                            NUM="$(awk -v g="$g" -v w="$w" 'BEGIN{v=int(g*1e9*8/(w*60)/1e6+0.5); if(v<1)v=1; print v}')"
                            cfg_set shape_avg_mbps "$NUM"; apply
                            echo "= $NUM Мбит/с в среднем (≈ $(gb_of "$NUM" "$w") ГБ за $w мин)"
                        else
                            echo "Некорректное число."
                        fi ;;
                esac
                pause ;;
            4)
                read_num "Скорость ограничения, Мбит/с в каждую сторону (1-100000, Enter — отмена): " 1 100000 && { cfg_set shape_penalty_mbps "$NUM"; apply; }
                pause ;;
            5)
                read_num "Длительность, часов (1-8760, Enter — отмена): " 1 8760 && { cfg_set shape_penalty_hours "$NUM"; apply; }
                pause ;;
            6)
                if is_on "$(cfg_get shape_ip_cap no)"; then cfg_set shape_ip_cap no; else cfg_set shape_ip_cap yes; fi
                apply; pause ;;
            7)
                read_num "Лимит на каждый IP, Мбит/с в каждую сторону (1-100000, по умолчанию 250, Enter — отмена): " 1 100000 && { cfg_set shape_ip_cap_mbps "$NUM"; apply; }
                pause ;;
            8)
                if is_on "$(cfg_get shape_upload no)"; then cfg_set shape_upload no; else cfg_set shape_upload yes; fi
                apply; pause ;;
            0|"") return ;;
        esac
    done
}

act_unshape() {
    "$XDPFW" status 2>/dev/null | sed -n '/Ограничены по скорости/,/^Топ/p' | sed '$d'
    read -r -p "IP для снятия ограничения скорости ('all' — всех, Enter — отмена): " ip || exit 0
    [[ -z "$ip" ]] && return
    if [[ "$ip" == "all" ]] || valid_ip "$ip"; then "$XDPFW" unshape "$ip"; else echo "Некорректный IP."; fi
    pause
}

# ---------- главный цикл ----------
while true; do
    header
    echo "  1) Статус: слоты, whitelist, блокировки, счётчики"
    echo "  2) SSH 22: режим (только список / всем)"
    echo "  3) SSH 22: показать и добавить IP"
    echo "  4) SSH 22: удалить IP"
    echo "  5) Антифлуд обычных IP: жёсткость (по умолчанию Высокая: 800 пак.)"
    echo "  6) Антифлуд обычных IP: время блокировки (минуты)"
    echo "  7) Whitelist: время (часы)"
    echo "  8) Антифлуд для whitelist: вкл/выкл, жёсткость, время блокировки"
    echo "  9) Лимит IP на 443 (не более N IP вне whitelist): вкл/выкл, N, слот"
    echo " 10) TCP 1433: заменить IP"
    echo " 11) UDP для whitelist: вкл/выкл (выкл = закрыть UDP всем), порт, адрес VPS"
    echo " 12) Снять блокировку с IP"
    echo " 13) Ограничение скорости (исходящий и входящий трафик): настройки"
    echo " 14) Снять ограничение скорости с IP"
    echo " 15) Перезапустить сервисы"
    echo " 17) Переключатель: лимит IP на 443 для каждого IP в $(cfg_get iface ens3) (сейчас $(onoff "$(cfg_get ip_limit_per_dst yes)"))"
    if systemctl is-active --quiet xdpfw-rollback.timer 2>/dev/null; then
        echo " 16) ПОДТВЕРДИТЬ установку (отменить авто-откат файрвола)"
    fi
    echo "  0) Выход"
    read -r -p "Выбор: " ch || exit 0
    case "$ch" in
        1) act_status ;;
        2) act_ssh_mode ;;
        3) act_ssh_add ;;
        4) act_ssh_del ;;
        5) act_flood ;;
        6) act_ban ;;
        7) act_hours ;;
        8) act_wl_flood ;;
        9) act_ip_limit ;;
        10) act_1433 ;;
        11) act_udp ;;
        12) act_unban ;;
        13) act_shape ;;
        14) act_unshape ;;
        15) act_restart ;;
        16) act_confirm ;;
        17) act_ip_limit_per_dst_toggle ;;
        0|q|Q) exit 0 ;;
        *) ;;
    esac
done
MENU_EOF
chmod 755 /usr/local/sbin/xdpfw-menu

cat > /usr/local/sbin/xdpfw-qdisc <<'QDISC_EOF'
#!/usr/bin/env bash
# xdpfw-qdisc <iface> [ifb] — ставит qdisc fq там, где его ещё нет.
#
# fq выдерживает пакеты до времени отправки, которое tc-программа xdpfw записала в пакет (EDT) —
# это и есть очередь/shaping. Скрипт идемпотентен: если fq уже стоит, только подстраивает его
# размеры очереди. На многоочередных сетевых картах (корень mq) меняются дочерние qdisc.
# Со вторым аргументом "ifb" дополнительно создаёт IFB-устройство xdpfw-ifb с fq: через него
# идёт задержка ВХОДЯЩИХ пакетов (клиент -> VPS), которые надо притормозить.
# Запускается один раз при включении ограничения скорости, не раз в секунду.
set -u

IF="${1:-}"
[ -n "$IF" ] || { echo "usage: xdpfw-qdisc <iface>"; exit 1; }
command -v tc >/dev/null 2>&1 || { echo "WARN: tc не найден (пакет iproute2)"; exit 1; }

# размеры очереди: на 25 Мбит/с 1500 пакетов на поток ≈ 0.5 с буфера, horizon больше max_delay (2 с)
PARAMS=(limit 50000 flow_limit 1500 horizon 4s)

set_fq() {   # set_fq root | set_fq parent :1
    if ! tc qdisc replace dev "$IF" "$@" fq "${PARAMS[@]}" 2>/dev/null; then
        tc qdisc replace dev "$IF" "$@" fq 2>/dev/null || echo "WARN: не удалось поставить fq ($*)"
    fi
}

change_fq() {
    tc qdisc change dev "$IF" "$@" fq "${PARAMS[@]}" 2>/dev/null || true
}

out="$(tc qdisc show dev "$IF" 2>/dev/null)"
root_line="$(printf '%s\n' "$out" | grep -m1 -E ' root( |$)')"
kind="$(printf '%s\n' "$root_line" | awk '{print $2}')"

case "$kind" in
    fq)
        change_fq root
        echo "fq уже стоит на $IF"
        ;;
    mq|mqprio)
        # дочерние очереди: "qdisc <тип> <handle>: parent :N ..."; clsact (parent ffff:) пропускаем
        printf '%s\n' "$out" | awk '
            / parent / {
                for (i = 1; i <= NF; i++) if ($i == "parent") p = $(i+1)
                if (p !~ /^ffff:/) print p, $2
            }' | while read -r parent k; do
                if [ "$k" = "fq" ]; then change_fq parent "$parent"; else set_fq parent "$parent"; fi
            done
        echo "fq настроен на очередях $IF (mq)"
        ;;
    *)
        set_fq root
        echo "fq поставлен на корень $IF (был: ${kind:-нет})"
        ;;
esac

# ---- IFB для входящего трафика ----
if [ "${2:-}" = "ifb" ]; then
    IFB=xdpfw-ifb
    if ! command -v ip >/dev/null 2>&1; then
        echo "WARN: ip не найден (пакет iproute2) — входящий трафик ограничиваться не будет"
        exit 0
    fi
    if ! ip link show "$IFB" >/dev/null 2>&1; then
        modprobe ifb numifbs=0 2>/dev/null || true
        ip link add "$IFB" type ifb 2>/dev/null || {
            echo "WARN: не удалось создать $IFB (нет модуля ifb? apt install linux-modules-extra-\$(uname -r)) — входящий трафик ограничиваться не будет"
            exit 0
        }
    fi
    ip link set "$IFB" up 2>/dev/null || true
    if ! tc qdisc replace dev "$IFB" root fq "${PARAMS[@]}" 2>/dev/null; then
        tc qdisc replace dev "$IFB" root fq 2>/dev/null || echo "WARN: не удалось поставить fq на $IFB"
    fi
    echo "IFB $IFB готов (fq)"
fi
QDISC_EOF
chmod 755 /usr/local/sbin/xdpfw-qdisc

echo "[5/8] Сборка"
clang -O2 -g -Wall -target bpf -I"/usr/include/$(uname -m)-linux-gnu" \
      -c "$SRC/xdpfw.bpf.c" -o "$LIBDIR/xdpfw.bpf.o"
clang -O2 -g -Wall -target bpf -I"/usr/include/$(uname -m)-linux-gnu" \
      -c "$SRC/xdpfw_tc.bpf.c" -o "$LIBDIR/xdpfw_tc.bpf.o"
gcc -O2 -Wall -o /usr/local/sbin/xdpfw "$SRC/xdpfw.c" -lbpf

echo "[6/8] Сервисы"
cat > /etc/sysctl.d/99-xdpfw.conf <<'SYSCTL_EOF'
# SYN-cookies — дополнительная защита от SYN-флуда на TCP 443
net.ipv4.tcp_syncookies = 1
SYSCTL_EOF
sysctl -q -p /etc/sysctl.d/99-xdpfw.conf || true

mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
systemctl stop xdpfw-xray 2>/dev/null || true
systemctl stop xdpfw 2>/dev/null || true
rm -rf /sys/fs/bpf/xdpfw

cat > /etc/systemd/system/xdpfw.service <<'UNIT_EOF'
[Unit]
Description=XDP firewall (xdpfw)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/xdpfw run
ExecReload=/bin/kill -HUP $MAINPID
ExecStopPost=/usr/local/sbin/xdpfw detach
Restart=on-failure
RestartSec=3
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > /etc/systemd/system/xdpfw-xray.service <<'UNIT_EOF'
[Unit]
Description=xdpfw: whitelist from Xray authenticated users (monitor.sh logic)
After=docker.service xdpfw.service
Wants=xdpfw.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/xdpfw-xray-poll
Restart=always
RestartSec=5
Nice=10
CPUWeight=20
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable xdpfw xdpfw-xray >/dev/null 2>&1
systemctl restart xdpfw
sleep 2
if ! systemctl is-active --quiet xdpfw; then
  echo "Сервис xdpfw не запустился. Лог:"
  journalctl -u xdpfw -n 40 --no-pager
  exit 1
fi
systemctl restart xdpfw-xray

echo "[7/8] Страховка от блокировки"
if [[ "$SAFE_MODE" == "1" ]]; then
  systemctl stop xdpfw-rollback.timer xdpfw-rollback.service 2>/dev/null || true
  systemctl reset-failed xdpfw-rollback.service 2>/dev/null || true
  systemd-run --quiet --unit=xdpfw-rollback --on-active=300 /bin/systemctl stop xdpfw
  echo "    Через 5 минут файрвол АВТОМАТИЧЕСКИ отключится (на случай, если вас отрезало)."
  echo "    Если SSH работает — подтвердите:  systemctl stop xdpfw-rollback.timer   (или пункт 16 в xdpfw-menu)"
fi

echo "[8/8] Проверка связи с Xray (несколько секунд)"
sleep 8
journalctl -u xdpfw-xray -n 8 --no-pager || true

cat <<DONE

Готово. XDP-файрвол запущен.

  Меню управления:     sudo xdpfw-menu
  Статус / whitelist:  xdpfw status
  Лог файрвола:        journalctl -u xdpfw -f        (блокировки за флуд)
  Лог whitelist:       journalctl -u xdpfw-xray -f   (кто авторизован в Xray)
  Снять блокировку:    xdpfw unban 1.2.3.4   (или: xdpfw unban all)
  Снять ограничение скорости:  xdpfw unshape 1.2.3.4   (или: xdpfw unshape all)
  Лимит IP на 443 для каждого IP в $IFACE: меню xdpfw-menu, пункт 9 или 17
  UDP для whitelist (порт, адрес VPS): меню xdpfw-menu, пункт 11
  Ограничение скорости в обе стороны: меню xdpfw-menu, пункт 13 (входящий трафик — через IFB; смотрите journalctl -u xdpfw)
  Конфиг:              $CONF
  Выключить:           systemctl disable --now xdpfw xdpfw-xray

DONE
