#!/usr/bin/env bash
#
# naive-install.sh — мастер установки NaiveProxy (Caddy + forwardproxy) на VPS.
#
# Запуск: НА САМОЙ машине от root, с любого устройства, где есть ssh:
#   bash <(curl -fsSL https://raw.githubusercontent.com/etomoya20-prog/migration/main/naive-install.sh)
#
# Скрипт спросит домен, порт, логин и пароль (Enter — ответ в скобках),
# по желанию сам переведёт A-запись в Cloudflare, покажет сводку и попросит
# подтверждение. В конце печатает ссылку для клиентов и кладёт профиль
# sing-box (SFI на iPhone) в /root/naive-sfi.json.
#
# Что ставит:
#   1. Caddy с forwardproxy (сборка klzgrad, стек Chrome) в /usr/local/bin/caddy
#   2. заглушку-сайт в /var/www/html — её видит любой посторонний
#   3. /etc/caddy/Caddyfile (600) и службу caddy-naive
#   4. открывает порт в ufw, если ufw включён
#   5. ждёт сертификат и проверяет туннель с этой же машины
#
# Повторный запуск безопасен: если конфиг не изменился, служба не
# перезапускается. Логин и пароль по умолчанию — из прежнего Caddyfile.
#
# Параметры флагами или через env (что не задано — спросит):
#   DOMAIN       / --domain      домен, A-запись которого смотрит (или будет) сюда
#   NAIVE_PORT   / --port        TCP-порт naive (умолчание 8443)
#   NAIVE_USER   / --user        логин (умолчание — прежний или новый случайный)
#   NAIVE_PASS   / --pass        пароль (так же)
#   CF_API_TOKEN / --cf-token    токен Cloudflare с Zone.DNS Edit; без него
#                                A-запись правится руками
#   --creds-file ФАЙЛ            строки NAIVE_USER=… и NAIVE_PASS=… (файл удаляется)
#   --yes                        без вопросов, на значениях по умолчанию
#   --no-secrets                 не печатать пароль и ссылку (для запуска из скриптов)
#
# Грабли, ради которых скрипт и написан:
#   * адрес сайта обязан включать общий «:ПОРТ», иначе CONNECT с Host чужого
#     сайта не попадает ни в один сайт и Caddy отвечает пустым 200;
#   * без HOME=/root Caddy не может сохранить сертификат;
#   * если 443 занят (ShadowTLS и т.п.), сертификат берётся только по HTTP-01
#     на :80, а tls-alpn надо выключить.

set -euo pipefail

readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_RED='\033[31m'
readonly C_GRN='\033[32m'
readonly C_YEL='\033[33m'
readonly C_BLU='\033[34m'

step() { echo -e "\n${C_BOLD}${C_BLU}==> $*${C_RESET}"; }
ok()   { echo -e "  ${C_GRN}✓${C_RESET} $*"; }
warn() { echo -e "  ${C_YEL}⚠${C_RESET} $*"; }
die()  { echo -e "\n${C_RED}${C_BOLD}✗ FAIL: $*${C_RESET}\n" >&2; exit 1; }

CADDY_URL="https://github.com/klzgrad/forwardproxy/releases/download/v2.11.7-naive2/caddy-forwardproxy-naive.tar.xz"
CADDY_VERSION="v2.11.7"

DOMAIN="${DOMAIN:-}"
NAIVE_PORT="${NAIVE_PORT:-}"
NAIVE_USER="${NAIVE_USER:-}"
NAIVE_PASS="${NAIVE_PASS:-}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
YES=""
NO_SECRETS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)     DOMAIN="$2"; shift 2 ;;
        --port)       NAIVE_PORT="$2"; shift 2 ;;
        --user)       NAIVE_USER="$2"; shift 2 ;;
        --pass)       NAIVE_PASS="$2"; shift 2 ;;
        --cf-token)   CF_API_TOKEN="$2"; shift 2 ;;
        --creds-file)
            # shellcheck disable=SC1090
            source "$2"; rm -f "$2"; shift 2 ;;
        --yes)        YES=1; shift ;;
        --no-secrets) NO_SECRETS=1; shift ;;
        -h|--help)    grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0 ;;
        *) die "неизвестный флаг: $1" ;;
    esac
done

[[ $EUID -ne 0 ]] && die "запускать от root"
[[ "$(uname -m)" == "x86_64" ]] || die "сборка Caddy только под x86_64, а тут $(uname -m)"

prompt() {
    # $1 — вопрос, $2 — ответ по умолчанию
    local msg="$1" default="${2:-}" value=""
    if [[ -n "$YES" ]]; then
        [[ -n "$default" ]] || die "в режиме --yes не задано: $msg"
        printf '%s' "$default"; return
    fi
    while [[ -z "$value" ]]; do
        if [[ -n "$default" ]]; then printf "  %s [%s]: " "$msg" "$default" >&2
        else printf "  %s: " "$msg" >&2; fi
        read -re value
        [[ -z "$value" && -n "$default" ]] && value="$default"
    done
    printf '%s' "$value"
}

confirm() {
    # $1 — вопрос, $2 — y|n по умолчанию
    local msg="$1" def="${2:-y}" a=""
    if [[ -n "$YES" ]]; then [[ "$def" == y ]]; return; fi
    printf "  %s [%s]: " "$msg" "$([[ $def == y ]] && echo Д/н || echo д/Н)" >&2
    read -re a
    a="${a:-$def}"
    [[ "${a,,}" =~ ^(y|д|yes|да) ]]
}

rand() {   # $1 — длина; буквы и цифры всех трёх видов, первая — буква
    # Не через «tr </dev/urandom | head»: под pipefail tr ловит SIGPIPE и
    # set -e роняет скрипт.
    python3 - "$1" <<'EOF'
import secrets, string, sys
n, abc = int(sys.argv[1]), string.ascii_letters + string.digits
while True:
    s = "".join(secrets.choice(abc) for _ in range(n))
    if s[0].isalpha() and any(c.isdigit() for c in s) and any(c.islower() for c in s) \
            and any(c.isupper() for c in s):
        print(s, end="")
        break
EOF
}

port_owner() {   # кто слушает TCP-порт: имя процесса или пусто
    ss -ltnpH "( sport = :$1 )" 2>/dev/null | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2
}

echo -e "${C_BOLD}=== NaiveProxy ===${C_RESET}"

# ---------- осмотр ----------
step "Осмотр машины"
. /etc/os-release 2>/dev/null && ok "$PRETTY_NAME, $(uname -m)"
MY_IP=$(curl -4 -fsS --max-time 15 https://api.ipify.org || true)
[[ -n "$MY_IP" ]] || die "не узнал свой внешний адрес (нет выхода в интернет?)"
ok "внешний адрес $MY_IP"
OWN80=$(port_owner 80); OWN443=$(port_owner 443)
echo "  порт 80: ${OWN80:-свободен}; порт 443: ${OWN443:-свободен}"
[[ -z "$OWN80" || "$OWN80" == caddy ]] || die "порт 80 занят «$OWN80»: он нужен Caddy для сертификата (HTTP-01)"

OLD_USER="" OLD_PASS="" OLD_DOMAIN="" OLD_PORT=""
if [[ -f /etc/caddy/Caddyfile ]]; then
    read -r _ OLD_USER OLD_PASS < <(grep -m1 -E '^\s*basic_auth ' /etc/caddy/Caddyfile || true) || true
    OLD_SITE=$(grep -m1 -E '^:[0-9]+, ' /etc/caddy/Caddyfile || true)
    OLD_PORT=$(sed -E 's/^:([0-9]+),.*/\1/' <<<"$OLD_SITE")
    OLD_DOMAIN=$(sed -E 's/^:[0-9]+, ([^: ]+):.*/\1/' <<<"$OLD_SITE")
    [[ -n "$OLD_USER" ]] && ok "naive уже стоит: ${OLD_DOMAIN}:${OLD_PORT}, служба $(systemctl is-active caddy-naive 2>/dev/null || true)"
fi

# ---------- параметры ----------
step "Параметры"
DOMAIN=$(prompt "домен" "${DOMAIN:-${OLD_DOMAIN:-naive.bezvsego.xyz}}")
DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"
while :; do
    NAIVE_PORT=$(prompt "порт naive (TCP)" "${NAIVE_PORT:-${OLD_PORT:-8443}}")
    own=$(port_owner "$NAIVE_PORT")
    [[ -z "$own" || "$own" == caddy ]] && break
    warn "порт $NAIVE_PORT занят «$own» — нужен другой"
    [[ -n "$YES" ]] && die "порт $NAIVE_PORT занят"
    NAIVE_PORT=""
done
if [[ -z "$NAIVE_USER" || -z "$NAIVE_PASS" ]]; then
    if [[ -n "$OLD_USER" ]] && confirm "оставить прежние логин и пароль?" y; then
        NAIVE_USER="$OLD_USER"; NAIVE_PASS="$OLD_PASS"
    else
        NAIVE_USER=$(rand 11); NAIVE_PASS=$(rand 24)
        ok "сгенерированы новые логин и пароль"
    fi
fi
[[ "$NAIVE_USER$NAIVE_PASS" =~ ^[A-Za-z0-9]+$ ]] || die "логин и пароль — только буквы и цифры"

# ---------- DNS ----------
dns_ip() { getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'; }
CUR_DNS=$(dns_ip "$DOMAIN")
if [[ "$CUR_DNS" != "$MY_IP" && -z "$CF_API_TOKEN" && -z "$YES" ]]; then
    echo "  $DOMAIN сейчас → ${CUR_DNS:-нет записи}, а нужен $MY_IP (иначе не будет сертификата)."
    printf "  токен Cloudflare, чтобы перевести запись (Enter — переведу руками; ввод скрыт): " >&2
    read -rs CF_API_TOKEN; echo >&2
fi

ALPN=1
[[ -n "$OWN443" && "$OWN443" != caddy ]] && ALPN=""

step "Сводка"
echo "  $DOMAIN:$NAIVE_PORT на $MY_IP, Caddy $CADDY_VERSION + forwardproxy, заглушка-сайт"
echo "  сертификат: $([[ -n $ALPN ]] && echo 'tls-alpn или HTTP-01' || echo "только HTTP-01 на :80 (443 занят «$OWN443»)")"
if [[ "$CUR_DNS" == "$MY_IP" ]]; then echo "  DNS: уже $MY_IP"
elif [[ -n "$CF_API_TOKEN" ]]; then echo "  DNS: ${CUR_DNS:-нет} → $MY_IP через Cloudflare"
else echo "  DNS: ${CUR_DNS:-нет} → $MY_IP переводишь сам, скрипт подождёт"; fi
confirm "поехали?" "$([[ -n $YES ]] && echo y || echo n)" || { echo "  ничего не менял"; exit 0; }

# ---------- DNS ----------
if [[ "$CUR_DNS" != "$MY_IP" ]]; then
    step "DNS"
    if [[ -n "$CF_API_TOKEN" ]]; then
        cfapi() { curl -fsS -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "$@"; }
        ZONE_ID="" name="$DOMAIN"
        first_id='import json,sys; r=json.load(sys.stdin).get("result") or []; print(r[0]["id"] if r else "")'
        while [[ "$name" == *.* && -z "$ZONE_ID" ]]; do
            ZONE_ID=$(cfapi "https://api.cloudflare.com/client/v4/zones?name=$name" 2>/dev/null |
                      python3 -c "$first_id" 2>/dev/null || true)
            name="${name#*.}"
        done
        [[ -n "$ZONE_ID" ]] || die "токен Cloudflare не видит зону для $DOMAIN (нужен Zone.DNS Edit)"
        REC=$(cfapi "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" |
              python3 -c "$first_id") || die "не прочитал A-запись $DOMAIN"
        BODY="{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$MY_IP\",\"ttl\":60,\"proxied\":false}"
        if [[ -n "$REC" ]]; then
            cfapi -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$REC" \
                -d "$BODY" >/dev/null || die "Cloudflare не дал поменять запись"
        else
            cfapi -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
                -d "$BODY" >/dev/null || die "Cloudflare не дал создать запись"
        fi
        ok "$DOMAIN → $MY_IP (без прокси Cloudflare, TTL 60)"
    else
        echo "  переведи A-запись $DOMAIN → $MY_IP (без оранжевого облака), жду…"
    fi
    seen=""
    for _ in $(seq 1 60); do
        seen=$(curl -fsS --max-time 10 -H 'accept: application/dns-json' \
              "https://1.1.1.1/dns-query?name=$DOMAIN&type=A" 2>/dev/null |
              python3 -c 'import json,sys; print(" ".join(a["data"] for a in json.load(sys.stdin).get("Answer",[])))' 2>/dev/null || true)
        [[ " $seen " == *" $MY_IP "* ]] && break
        sleep 10
    done
    [[ " $seen " == *" $MY_IP "* ]] || die "за 10 минут $DOMAIN так и не стал $MY_IP (сейчас: ${seen:-нет})"
    ok "в DNS уже $MY_IP"
fi

# ---------- установка ----------
step "Установка"
CHANGED=""
if [[ "$(/usr/local/bin/caddy version 2>/dev/null | cut -d' ' -f1)" != "$CADDY_VERSION" ]]; then
    command -v xz >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -q xz-utils >/dev/null
    tmp=$(mktemp -d)
    curl -fsSL --max-time 300 -o "$tmp/c.tar.xz" "$CADDY_URL" || die "не скачался Caddy с GitHub"
    tar -xJf "$tmp/c.tar.xz" -C "$tmp"
    install -m 755 "$(find "$tmp" -type f -name caddy | head -1)" /usr/local/bin/caddy
    rm -rf "$tmp"
    CHANGED=1
fi
ok "Caddy $(/usr/local/bin/caddy version | cut -d' ' -f1)"

mkdir -p /var/www/html /etc/caddy
cat > /var/www/html/index.html <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Northwind Notes</title></head>
<body style="font-family:sans-serif;max-width:640px;margin:60px auto"><h1>Northwind Notes</h1>
<p>Field notes on hiking, photography and slow travel in Scandinavia. New posts coming soon.</p></body></html>
EOF

ISSUER=""
[[ -z "$ALPN" ]] && ISSUER=$'\n    issuer acme {\n      disable_tlsalpn_challenge\n    }'
NEW_CF=$(cat <<EOF
{
  order forward_proxy before file_server
}
:$NAIVE_PORT, $DOMAIN:$NAIVE_PORT {
  tls {
    protocols tls1.3$ISSUER
  }
  forward_proxy {
    basic_auth $NAIVE_USER $NAIVE_PASS
    hide_ip
    hide_via
    probe_resistance
  }
  file_server {
    root /var/www/html
  }
}
EOF
)
if [[ "$(cat /etc/caddy/Caddyfile 2>/dev/null)" != "$NEW_CF" ]]; then
    (umask 077; printf '%s\n' "$NEW_CF" > /etc/caddy/Caddyfile.new)
    /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile.new --adapter caddyfile >/dev/null 2>&1 ||
        die "Caddyfile не прошёл проверку"
    mv /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile
    CHANGED=1
    ok "Caddyfile записан (600)"
else
    ok "Caddyfile без изменений"
fi

UNIT='[Unit]
After=network-online.target
[Service]
Environment=HOME=/root
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
Restart=always
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target'
if [[ "$(cat /etc/systemd/system/caddy-naive.service 2>/dev/null)" != "$UNIT" ]]; then
    printf '%s\n' "$UNIT" > /etc/systemd/system/caddy-naive.service
    systemctl daemon-reload
    CHANGED=1
fi
if ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$NAIVE_PORT/tcp" >/dev/null; ufw allow 80/tcp >/dev/null
    ok "ufw: открыты $NAIVE_PORT/tcp и 80/tcp"
fi
if [[ -n "$CHANGED" || "$(systemctl is-active caddy-naive 2>/dev/null)" != active ]]; then
    systemctl enable caddy-naive >/dev/null 2>&1 || true
    systemctl restart caddy-naive
    ok "служба caddy-naive (пере)запущена"
else
    ok "служба caddy-naive уже работает с этим конфигом — не трогаю"
fi
sleep 3
systemctl is-active --quiet caddy-naive ||
    die "caddy-naive не работает:\n$(journalctl -u caddy-naive -n 15 --no-pager -o cat)"

# ---------- проверка ----------
step "Проверка"
echo "  жду сертификат (до 5 минут)…"
got=""
for _ in $(seq 1 30); do
    if curl -fsS --max-time 10 --resolve "$DOMAIN:$NAIVE_PORT:127.0.0.1" \
            "https://$DOMAIN:$NAIVE_PORT/" 2>/dev/null | grep -q Northwind; then
        got=1; break
    fi
    sleep 10
done
[[ -n "$got" ]] || die "нет сертификата. Хвост лога:\n$(journalctl -u caddy-naive -n 30 --no-pager -o cat | grep -iE 'error|challenge|obtain' | tail -5)"
ok "сертификат настоящий, посторонним — заглушка-сайт"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$DOMAIN:$NAIVE_PORT:127.0.0.1" \
       -p -x "https://$DOMAIN:$NAIVE_PORT" https://example.com/ || true)
[[ "$code" == 2* ]] && die "CONNECT без пароля прошёл — сервер открыт всем"
ok "CONNECT без пароля не пускает"

eg=$(curl -s --max-time 20 --resolve "$DOMAIN:$NAIVE_PORT:127.0.0.1" \
     -x "https://$NAIVE_USER:$NAIVE_PASS@$DOMAIN:$NAIVE_PORT" https://api.ipify.org || true)
[[ "$eg" == "$MY_IP" ]] || die "туннель с паролем не заработал (ответ «$eg»)"
ok "туннель с паролем работает, выход $eg"

# ---------- клиенты ----------
umask 077
cat > /root/naive-sfi.json <<EOF
{
  "log": {"level": "warn"},
  "dns": {
    "servers": [
      {"type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "naive"},
      {"type": "local", "tag": "local"}
    ],
    "rules": [{"domain": ["$DOMAIN"], "server": "local"}],
    "final": "remote",
    "strategy": "ipv4_only"
  },
  "inbounds": [{"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"],
                "auto_route": true, "strict_route": true}],
  "outbounds": [
    {"type": "naive", "tag": "naive", "server": "$DOMAIN", "server_port": $NAIVE_PORT,
     "username": "$NAIVE_USER", "password": "$NAIVE_PASS",
     "tls": {"enabled": true, "server_name": "$DOMAIN"}},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {
    "rules": [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"},
              {"ip_is_private": true, "outbound": "direct"}],
    "final": "naive", "auto_detect_interface": true, "default_domain_resolver": "local"
  }
}
EOF

step "Готово"
echo "  профиль sing-box (SFI на iPhone): /root/naive-sfi.json"
if [[ -z "$NO_SECRETS" ]]; then
    echo "  ссылка (NekoBox, Throne, v2rayN):"
    echo "    naive+https://$NAIVE_USER:$NAIVE_PASS@$DOMAIN:$NAIVE_PORT#naive-$DOMAIN"
    echo "  официальный клиент naive, config.json:"
    echo "    {\"listen\":\"socks://127.0.0.1:1080\",\"proxy\":\"https://$NAIVE_USER:$NAIVE_PASS@$DOMAIN:$NAIVE_PORT\"}"
fi
