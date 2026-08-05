#!/usr/bin/env bash
#
# xui-migrate.sh — миграция 3x-UI + xui-bot со старого VPS на новый.
#
# Запуск: НА НОВОМ (чистом) VPS от root, без аргументов.
# Скрипт по очереди спросит все нужные параметры, проверит CF токен,
# сам настроит SSH-ключ на старый VPS (если нужно), покажет сводку
# и попросит подтверждение перед стартом.
#
# Что делает:
#   1. Тянет данные со старого VPS по scp
#   2. Разворачивает всё локально (x-ui, xui-bot, cert, acme.sh)
#   3. Пересоздаёт Python venv для бота (может быть другая версия Python)
#   4. Устанавливает CF Warp (wgcf + wireproxy на 127.0.0.1:40000)
#   5. Обновляет A-записи в Cloudflare через API
#   6. Запускает службы, финальные проверки
#
# Все параметры можно передать и через env/флаги (для автоматизации):
#   OLD_VPS_HOST / --old       IP или hostname старого VPS
#   OLD_VPS_USER / --user      ssh user (default: root)
#   OLD_VPS_PORT / --port      ssh port (default: 22)
#   DOMAIN       / --domain    домен, например bezfigni.xyz
#   CF_API_TOKEN / --cf-token  Cloudflare API token с Zone.DNS Edit
#   SKIP_WARP    / --skip-warp пропустить установку CF Warp
#
# Что не задано — скрипт спросит интерактивно.
#
# Примеры:
#   bash xui-migrate.sh                                    # полностью интерактивно
#   bash xui-migrate.sh --old 2.27.30.95 --domain X.xyz    # спросит только CF token
#   OLD_VPS_HOST=1.2.3.4 DOMAIN=X.xyz CF_API_TOKEN=t bash xui-migrate.sh

set -euo pipefail

# ---------- визуал ----------
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

# ---------- параметры ----------
OLD_VPS_HOST="${OLD_VPS_HOST:-}"
OLD_VPS_USER="${OLD_VPS_USER:-root}"
OLD_VPS_PORT="${OLD_VPS_PORT:-22}"
DOMAIN="${DOMAIN:-}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
SKIP_WARP="${SKIP_WARP:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --old)       OLD_VPS_HOST="$2"; shift 2 ;;
        --user)      OLD_VPS_USER="$2"; shift 2 ;;
        --port)      OLD_VPS_PORT="$2"; shift 2 ;;
        --domain)    DOMAIN="$2"; shift 2 ;;
        --cf-token)  CF_API_TOKEN="$2"; shift 2 ;;
        --skip-warp) SKIP_WARP=1; shift ;;
        -h|--help)
            grep -E '^# ' "$0" | sed 's/^# //'
            exit 0
            ;;
        *) die "unknown flag: $1" ;;
    esac
done

[[ $EUID -ne 0 ]] && die "запускать от root"

# ---------- интерактивный опрос ----------
# всё что не задано флагом/env — спрашиваем у пользователя
# TTY нужен для интерактива; при запуске из пайпа падаем на fail
prompt() {
    # $1 = prompt text, $2 = default value (можно пустой), $3 = "silent" для скрытого ввода
    local msg="$1" default="${2:-}" silent="${3:-}"
    local value=""
    while [[ -z "$value" ]]; do
        if [[ -n "$default" ]]; then
            printf "  %s [%s]: " "$msg" "$default" >&2
        else
            printf "  %s: " "$msg" >&2
        fi
        if [[ "$silent" == "silent" ]]; then
            read -rs value
            echo >&2
        else
            read -re value
        fi
        [[ -z "$value" && -n "$default" ]] && value="$default"
    done
    printf '%s' "$value"
}

echo -e "${C_BOLD}=== xui migration ===${C_RESET}"
echo "Скрипт мигрирует 3x-UI + xui-bot со старого VPS сюда."
echo "Он остановит службы на старом VPS ~30 секунд для сбора архива."
echo

# старый VPS
if [[ -z "$OLD_VPS_HOST" ]]; then
    echo -e "${C_BOLD}Старый VPS:${C_RESET}"
    OLD_VPS_HOST=$(prompt "IP или hostname")
    OLD_VPS_USER=$(prompt "ssh user" "root")
    OLD_VPS_PORT=$(prompt "ssh port" "22")
    echo
fi

# домен
if [[ -z "$DOMAIN" ]]; then
    echo -e "${C_BOLD}Домен:${C_RESET}"
    DOMAIN=$(prompt "домен (без https://)")
    # снять протокол если пользователь всё-таки его вписал
    DOMAIN="${DOMAIN#https://}"
    DOMAIN="${DOMAIN#http://}"
    DOMAIN="${DOMAIN%/}"
    echo
fi

# CF token
if [[ -z "$CF_API_TOKEN" ]]; then
    echo -e "${C_BOLD}Cloudflare API token:${C_RESET}"
    echo "  (для авто-обновления DNS; Enter пропустит — обновишь вручную)"
    printf "  токен (ввод скрыт): " >&2
    read -rs CF_API_TOKEN
    echo >&2
    echo
fi

# валидация CF токена (если задан)
if [[ -n "$CF_API_TOKEN" ]]; then
    echo -en "  проверяю CF токен... "
    CF_CHECK=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null || echo '{}')
    CF_STATUS=$(echo "$CF_CHECK" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('result', {}).get('status', 'invalid'))
except Exception:
    print('invalid')
" 2>/dev/null || echo "invalid")

    if [[ "$CF_STATUS" != "active" ]]; then
        echo -e "${C_RED}не работает${C_RESET}"
        CF_ERR=$(echo "$CF_CHECK" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print((d.get('errors') or [{'message':'нет ответа от CF API'}])[0].get('message'))
except Exception:
    print('нет ответа от CF API')
" 2>/dev/null)
        die "CF token невалиден: $CF_ERR"
    fi

    # проверка что токен видит зону
    ZONE_CHECK=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" 2>/dev/null)
    ZONE_ID_PRECHECK=$(echo "$ZONE_CHECK" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    r = d.get('result') or []
    print(r[0].get('id') if r else '')
except Exception:
    pass
" 2>/dev/null)

    if [[ -z "$ZONE_ID_PRECHECK" ]]; then
        echo -e "${C_RED}зона недоступна${C_RESET}"
        die "токен активен, но не видит зону $DOMAIN. Проверь права токена (Zone.DNS Edit для $DOMAIN)"
    fi
    echo -e "${C_GRN}ok, доступ к $DOMAIN есть${C_RESET}"
    echo
fi

# CF Warp: устанавливать?
if [[ -z "$SKIP_WARP" ]]; then
    printf "  Устанавливать Cloudflare Warp (для RU-трафика)? [Y/n]: " >&2
    read -re WARP_ANS
    [[ "$WARP_ANS" =~ ^[Nn] ]] && SKIP_WARP=1
    echo
fi

# сводка + подтверждение
readonly BACKUP_PATH="/tmp/xui-migration.tar.gz"
readonly NEW_IP=$(curl -s4 --max-time 5 https://api.ipify.org || die "не смог узнать свой IP")

echo -e "${C_BOLD}Итого:${C_RESET}"
echo "  old VPS:  $OLD_VPS_USER@$OLD_VPS_HOST:$OLD_VPS_PORT"
echo "  new VPS:  $NEW_IP (this)"
echo "  domain:   $DOMAIN"
echo "  CF DNS:   $([[ -n "$CF_API_TOKEN" ]] && echo 'auto (обновится)' || echo 'manual (обновишь сам)')"
echo "  CF Warp:  $([[ -n "$SKIP_WARP" ]] && echo 'skip' || echo 'install')"
echo
printf "  Продолжить? [y/N]: " >&2
read -re CONFIRM
[[ "$CONFIRM" =~ ^[Yy] ]] || die "отменено пользователем"
echo

# ---------- 0. проверки окружения ----------
step "0. проверка окружения"

[[ -f /etc/os-release ]] || die "не Linux с /etc/os-release"
. /etc/os-release
[[ "$ID" == "ubuntu" || "$ID" == "debian" ]] \
    || warn "дистрибутив $ID не тестировался (ожидалось ubuntu/debian) — продолжаем"

# ssh reachability
if ! timeout 3 bash -c "exec 3<>/dev/tcp/$OLD_VPS_HOST/$OLD_VPS_PORT" 2>/dev/null; then
    die "не могу дотянуться до $OLD_VPS_HOST:$OLD_VPS_PORT — проверь адрес и firewall"
fi
ok "ssh порт $OLD_VPS_PORT на старом VPS открыт"

# ssh key auth?
SSH_OPTS=(-p "$OLD_VPS_PORT" -o StrictHostKeyChecking=accept-new
          -o ConnectTimeout=10 -o BatchMode=yes)
if ssh "${SSH_OPTS[@]}" "$OLD_VPS_USER@$OLD_VPS_HOST" true 2>/dev/null; then
    ok "ssh key auth работает"
else
    warn "ssh key auth не работает — настраиваю"

    # 1. локальный ключ есть?
    if [[ ! -f /root/.ssh/id_ed25519 && ! -f /root/.ssh/id_rsa ]]; then
        ok "генерирую /root/.ssh/id_ed25519"
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 -q
    fi

    # 2. установить sshpass если нет ssh-copy-id + запросить пароль
    command -v ssh-copy-id >/dev/null 2>&1 || apt-get install -y -qq openssh-client
    apt-get install -y -qq sshpass 2>/dev/null || true

    echo
    echo -e "  ${C_YEL}Введи пароль пользователя ${OLD_VPS_USER}@${OLD_VPS_HOST}${C_RESET}"
    echo -e "  ${C_YEL}(один раз для копирования ключа, дальше без пароля):${C_RESET}"
    printf "  пароль: " >&2
    read -rs OLD_VPS_PASS
    echo >&2

    # 3. копируем ключ через sshpass (обходит "password: " интерактив)
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$OLD_VPS_PASS" ssh-copy-id \
            -o StrictHostKeyChecking=accept-new \
            -p "$OLD_VPS_PORT" \
            "$OLD_VPS_USER@$OLD_VPS_HOST" >/dev/null 2>&1 \
            || die "ssh-copy-id упал — проверь пароль и попробуй заново"
    else
        # fallback без sshpass — интерактивно
        ssh-copy-id -o StrictHostKeyChecking=accept-new \
            -p "$OLD_VPS_PORT" \
            "$OLD_VPS_USER@$OLD_VPS_HOST" \
            || die "ssh-copy-id упал"
    fi

    # 4. проверка что теперь пускает
    if ssh "${SSH_OPTS[@]}" "$OLD_VPS_USER@$OLD_VPS_HOST" true 2>/dev/null; then
        ok "ssh key auth настроен"
    else
        die "ключ скопирован, но всё равно не пускает — проверь sshd_config на старом VPS"
    fi
    unset OLD_VPS_PASS
fi

# ---------- 1. пакеты ----------
step "1. установка зависимостей"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget tar sqlite3 python3 python3-venv python3-pip jq
ok "пакеты установлены"

# ---------- 2. сборка бэкапа на старом VPS ----------
step "2. сборка архива на старом VPS"

ssh "${SSH_OPTS[@]}" "$OLD_VPS_USER@$OLD_VPS_HOST" bash -s <<'REMOTE_EOF'
set -e
systemctl stop x-ui xui-bot 2>/dev/null || true

# перед tar — убедиться что БД сброшена на диск (WAL → main)
if [[ -f /etc/x-ui/x-ui.db ]]; then
    sqlite3 /etc/x-ui/x-ui.db "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
fi

tar czf /tmp/xui-migration.tar.gz \
    /usr/local/x-ui/ \
    /etc/x-ui/ \
    /etc/systemd/system/x-ui.service \
    /opt/xui-bot/ \
    /etc/systemd/system/xui-bot.service \
    /root/.acme.sh/ 2>/dev/null

# x-ui поднимаем обратно как fallback proxy на 3-5 дней
# xui-bot НЕ поднимаем — новый бот будет отвечать один
systemctl start x-ui 2>/dev/null || true
systemctl disable xui-bot 2>/dev/null || true

ls -la /tmp/xui-migration.tar.gz
REMOTE_EOF
ok "архив собран на старом VPS"

# ---------- 3. качаем архив ----------
step "3. копирование архива"

# scp использует -P для порта (не -p как ssh)
scp -P "$OLD_VPS_PORT" -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 -o BatchMode=yes \
    "$OLD_VPS_USER@$OLD_VPS_HOST:/tmp/xui-migration.tar.gz" \
    "$BACKUP_PATH"

[[ -f "$BACKUP_PATH" ]] || die "архив не скачался"
ok "архив $(du -h "$BACKUP_PATH" | cut -f1) получен"

# ---------- 4. распаковка ----------
step "4. распаковка на новом VPS"

# на случай повторного запуска — сохраняем старое
for path in /usr/local/x-ui /etc/x-ui /opt/xui-bot; do
    if [[ -e "$path" ]]; then
        mv "$path" "${path}.bak.$(date +%s)"
        warn "существующий $path переименован в ${path}.bak.*"
    fi
done

tar xzf "$BACKUP_PATH" -C /
ok "распаковано"

# ---------- 5. пересоздать venv для бота ----------
step "5. пересоздание Python venv для xui-bot"

if [[ -d /opt/xui-bot/venv ]]; then
    mv /opt/xui-bot/venv /opt/xui-bot/venv.old
fi

cd /opt/xui-bot
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate

if [[ -f requirements.txt ]]; then
    pip install -q --upgrade pip
    pip install -q -r requirements.txt
else
    # fallback — известные зависимости
    pip install -q httpx python-telegram-bot python-dotenv "qrcode[pil]"
fi

deactivate
rm -rf /opt/xui-bot/venv.old
ok "venv собран под $(python3 --version)"

# ---------- 6. проверка share_addr в БД ----------
step "6. проверка share_addr в БД"

CURRENT_SHARE=$(sqlite3 /etc/x-ui/x-ui.db \
    "SELECT share_addr FROM inbounds WHERE id=1;" 2>/dev/null || echo "")

if [[ "$CURRENT_SHARE" == "$DOMAIN" ]]; then
    ok "share_addr = $DOMAIN (нормально, миграция DNS покроет)"
elif [[ -z "$CURRENT_SHARE" ]]; then
    warn "share_addr пустой — VLESS URL будет использовать listen IP"
else
    warn "share_addr = '$CURRENT_SHARE' — заменяю на '$DOMAIN'"
    sqlite3 /etc/x-ui/x-ui.db "UPDATE inbounds SET share_addr = '$DOMAIN' WHERE id = 1;"
    ok "share_addr обновлён на $DOMAIN"
fi

# ---------- 7. systemd + запуск ----------
step "7. запуск x-ui и xui-bot"

systemctl daemon-reload
systemctl enable x-ui xui-bot >/dev/null
systemctl restart x-ui
sleep 4
systemctl restart xui-bot
sleep 2

if ! systemctl is-active --quiet x-ui; then
    journalctl -u x-ui -n 30 --no-pager | tail -15
    die "x-ui не запустился"
fi
ok "x-ui запущен"

if ! systemctl is-active --quiet xui-bot; then
    journalctl -u xui-bot -n 30 --no-pager | tail -15
    die "xui-bot не запустился"
fi
ok "xui-bot запущен"

# ---------- 8. порты ----------
step "8. проверка портов"

for port in 443 31170 2096; do
    if ss -lnt "sport = :$port" | grep -q ":$port"; then
        ok "порт $port слушается"
    else
        warn "порт $port НЕ слушается — что-то не так"
    fi
done

# ---------- 9. Cloudflare DNS ----------
step "9. обновление DNS"

if [[ -z "$CF_API_TOKEN" ]]; then
    warn "CF_API_TOKEN не задан — обнови вручную:"
    echo "     Cloudflare → зона $DOMAIN → DNS Records"
    echo "     A $DOMAIN     → $NEW_IP  (Proxy: DNS only)"
    echo "     A www.$DOMAIN → $NEW_IP  (Proxy: DNS only)"
else
    ZONE_ID=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        | jq -r '.result[0].id // empty')

    [[ -z "$ZONE_ID" ]] && die "не смог найти zone id для $DOMAIN в Cloudflare"
    ok "zone id: $ZONE_ID"

    for name in "$DOMAIN" "www.$DOMAIN"; do
        REC=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$name" \
            | jq -r '.result[0]')
        REC_ID=$(echo "$REC" | jq -r '.id // empty')
        REC_IP=$(echo "$REC" | jq -r '.content // empty')

        if [[ -z "$REC_ID" ]]; then
            warn "A-запись $name не найдена — создаю"
            curl -s -X POST -H "Authorization: Bearer $CF_API_TOKEN" \
                -H "Content-Type: application/json" \
                "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
                -d "{\"type\":\"A\",\"name\":\"$name\",\"content\":\"$NEW_IP\",\"ttl\":60,\"proxied\":false}" \
                | jq -r '.success' | grep -q true \
                && ok "$name создана → $NEW_IP" \
                || warn "$name не создалась"
        elif [[ "$REC_IP" == "$NEW_IP" ]]; then
            ok "$name уже указывает на $NEW_IP"
        else
            curl -s -X PATCH -H "Authorization: Bearer $CF_API_TOKEN" \
                -H "Content-Type: application/json" \
                "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$REC_ID" \
                -d "{\"content\":\"$NEW_IP\",\"proxied\":false}" \
                | jq -r '.success' | grep -q true \
                && ok "$name обновлена: $REC_IP → $NEW_IP" \
                || warn "$name не обновилась"
        fi
    done
fi

# ---------- 10. Cloudflare Warp (SOCKS5 для RU-трафика) ----------
if [[ -n "$SKIP_WARP" ]]; then
    step "10. Cloudflare Warp — пропускаем (SKIP_WARP=1)"
else
    step "10. установка Cloudflare Warp (wgcf + wireproxy)"

    # проверяем есть ли уже wireproxy — если да, пропускаем
    if systemctl is-active --quiet wireproxy 2>/dev/null && \
       ss -lnt "sport = :40000" 2>/dev/null | grep -q :40000; then
        ok "wireproxy уже установлен и работает на :40000"
    else
        # --- wgcf ---
        WGCF_URL=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest \
            | grep -oE '"browser_download_url": *"[^"]+wgcf_[0-9.]+_linux_amd64"' \
            | head -1 | grep -oE 'https://[^"]+' || true)
        [[ -z "$WGCF_URL" ]] && die "не смог найти URL wgcf на GitHub"

        curl -fsSL -o /usr/local/bin/wgcf "$WGCF_URL"
        chmod +x /usr/local/bin/wgcf
        ok "wgcf установлен"

        # регистрация в CF Warp
        mkdir -p /etc/wireproxy
        cd /etc/wireproxy
        rm -f wgcf-account.toml wgcf-profile.conf
        wgcf register --accept-tos >/dev/null 2>&1
        wgcf generate >/dev/null 2>&1
        [[ -f wgcf-profile.conf ]] || die "wgcf не сгенерировал профиль"
        ok "аккаунт CF Warp создан"

        # --- wireproxy ---
        curl -fsSL -o /tmp/wireproxy.tar.gz \
            'https://github.com/whyvl/wireproxy/releases/latest/download/wireproxy_linux_amd64.tar.gz'
        tar xzf /tmp/wireproxy.tar.gz -C /usr/local/bin/
        chmod +x /usr/local/bin/wireproxy
        ok "wireproxy $(/usr/local/bin/wireproxy -v 2>&1 | head -1)"

        # собираем конфиг из wgcf-profile.conf
        # Address в wgcf идёт одной строкой через запятую — надо разделить
        PRIV_KEY=$(grep '^PrivateKey' wgcf-profile.conf | awk -F' = ' '{print $2}')
        ADDR_V4=$(grep '^Address' wgcf-profile.conf | awk -F' = ' '{print $2}' \
                  | tr ',' '\n' | grep -v ':' | head -1 | tr -d ' ')
        ADDR_V6=$(grep '^Address' wgcf-profile.conf | awk -F' = ' '{print $2}' \
                  | tr ',' '\n' | grep ':' | head -1 | tr -d ' ')
        PUB_KEY=$(grep '^PublicKey' wgcf-profile.conf | awk -F' = ' '{print $2}')

        cat > /etc/wireproxy/wireproxy.conf <<EOF
[Interface]
PrivateKey = ${PRIV_KEY}
Address = ${ADDR_V4}
Address = ${ADDR_V6}
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = ${PUB_KEY}
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
Endpoint = engage.cloudflareclient.com:2408
PersistentKeepalive = 25

[Socks5]
BindAddress = 127.0.0.1:40000
EOF
        ok "wireproxy.conf собран"

        # systemd unit
        cat > /etc/systemd/system/wireproxy.service <<'EOF'
[Unit]
Description=Cloudflare Warp SOCKS5 proxy (wireproxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wireproxy -c /etc/wireproxy/wireproxy.conf
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now wireproxy >/dev/null
        sleep 4

        systemctl is-active --quiet wireproxy || \
            { journalctl -u wireproxy -n 20 --no-pager; die "wireproxy не запустился"; }
        ok "wireproxy запущен"
    fi

    # проверка что SOCKS5 работает (тест curl через warp)
    WARP_IP=$(curl -s4 --socks5 127.0.0.1:40000 --max-time 8 https://api.ipify.org || echo "")
    if [[ -n "$WARP_IP" && "$WARP_IP" != "$NEW_IP" ]]; then
        ok "warp SOCKS5 работает — трафик выходит с $WARP_IP (CF)"
    else
        warn "warp SOCKS5 не отвечает — проверь: systemctl status wireproxy"
    fi

    # рестарт x-ui чтобы xray переоткрыл соединение к warp
    systemctl restart x-ui
    sleep 3
fi

# ---------- 11. финальный тест ----------
step "11. финальная проверка"

# ждём пропагации DNS до 60 секунд (внутри VPS резолвер может кэшировать)
for i in {1..12}; do
    RESOLVED=$(dig +short "$DOMAIN" @1.1.1.1 2>/dev/null | head -1)
    if [[ "$RESOLVED" == "$NEW_IP" ]]; then
        ok "DNS: $DOMAIN → $NEW_IP"
        break
    fi
    sleep 5
    [[ $i -eq 12 ]] && warn "DNS ещё не пропагирован ($RESOLVED); подожди 5-10 минут"
done

# берём subId первого клиента и проверяем что URL содержит домен
SUB_ID=$(sqlite3 /etc/x-ui/x-ui.db \
    "SELECT settings FROM inbounds WHERE id=1;" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    clients = d.get('clients', [])
    if clients:
        print(clients[0].get('subId', ''))
except Exception:
    pass
" 2>/dev/null)

if [[ -n "$SUB_ID" ]]; then
    SUB_PATH=$(sqlite3 /etc/x-ui/x-ui.db \
        "SELECT value FROM settings WHERE key='subPath';" 2>/dev/null | sed 's|/$||')
    SUB_PORT=$(sqlite3 /etc/x-ui/x-ui.db \
        "SELECT value FROM settings WHERE key='subPort';" 2>/dev/null)
    # subDomain из БД (может отличаться от --domain если серт ещё не обновлён)
    SUB_DOMAIN=$(sqlite3 /etc/x-ui/x-ui.db \
        "SELECT value FROM settings WHERE key='subDomain';" 2>/dev/null)
    [[ -z "$SUB_DOMAIN" ]] && SUB_DOMAIN="$DOMAIN"

    VLESS_URL=$(curl -sk --max-time 5 \
        "https://127.0.0.1:${SUB_PORT}${SUB_PATH}/${SUB_ID}" \
        -H "Host: $SUB_DOMAIN" | base64 -d 2>/dev/null | head -1)

    if [[ "$VLESS_URL" == *"@${DOMAIN}:"* ]]; then
        ok "VLESS URL корректный: @${DOMAIN}:..."
    elif [[ "$VLESS_URL" == vless://* ]]; then
        warn "VLESS URL сгенерирован, но не с доменом: ${VLESS_URL:0:80}..."
    else
        warn "не смог сгенерировать VLESS URL"
    fi
fi

# ---------- готово ----------
echo
echo -e "${C_GRN}${C_BOLD}=== миграция готова ===${C_RESET}"
echo "  панель:  https://${DOMAIN}:31170$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null | sed 's|/$||')/"
echo "  new IP:  $NEW_IP"
echo
echo "Дальше:"
echo "  • старый VPS оставь работать 3-5 дней как fallback"
echo "  • попроси клиентов свайпнуть подписку для обновления"
echo "  • acme.sh: sertификат уже переехал, renew до истечения"
echo "  • ротируй TG token (@BotFather → /revoke) → обнови .env"
echo
