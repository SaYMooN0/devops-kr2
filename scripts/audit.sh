#!/usr/bin/env bash
# VM configuration audit: PR5 checks, followed by PR6 when its config exists.
# Usage: scripts/audit.sh [--base|--web]
# Negative certificate test: CERT_MIN_DAYS=400 scripts/audit.sh --web
set -uo pipefail
export LC_ALL=C

PASS=0
FAIL=0
WEB_MODE=auto
SITE_DIR="${SITE_DIR:-/var/www/devops-site}"
TLS_CERT="${TLS_CERT:-/etc/ssl/certs/devops.crt}"
TLS_KEY="${TLS_KEY:-/etc/ssl/private/devops.key}"
NGINX_CONFIG="${NGINX_CONFIG:-/etc/nginx/sites-available/devops-site}"
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"

case "$#:$*" in
    0:) ;;
    1:--base) WEB_MODE=no ;;
    1:--web) WEB_MODE=yes ;;
    *) printf 'Использование: %s [--base|--web]\n' "$0" >&2; exit 1 ;;
esac
if [[ ! "$CERT_MIN_DAYS" =~ ^[0-9]{1,6}$ ]]; then
    echo 'Ошибка: CERT_MIN_DAYS должен быть целым числом от 0 до 999999.' >&2
    exit 1
fi
CERT_MIN_SECONDS=$((10#$CERT_MIN_DAYS * 86400))

priv() {
    if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi
}

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf '  [OK]   %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s (ожидалось: '%s', получено: '%s')\n" "$desc" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

printf 'Аудит конфигурации: %s, %s\n' "$(hostname -f)" "$(date '+%Y-%m-%d %H:%M')"
echo '[1] Служба SSH'
SSH_CONFIG="$(priv sshd -T)" || SSH_CONFIG=''
check 'Вход от имени root запрещён' no "$(awk '/^permitrootlogin / {print $2}' <<< "$SSH_CONFIG")"
check 'Парольная аутентификация отключена' no "$(awk '/^passwordauthentication / {print $2}' <<< "$SSH_CONFIG")"
# If multiple Port directives exist, every listener must avoid port 22.
PORTS="$(awk '/^port / {print $2}' <<< "$SSH_CONFIG")"
PORT_OK=no
if [[ -n "$PORTS" ]] && awk 'BEGIN {ok=1} !/^[0-9]+$/ || $1<1 || $1>65535 || $1==22 {ok=0} END {exit !ok}' <<< "$PORTS"; then
    PORT_OK=yes
fi
check 'Все порты SSH отличаются от 22' yes "$PORT_OK"
check 'MaxAuthTries равен 3' 3 "$(awk '/^maxauthtries / {print $2}' <<< "$SSH_CONFIG")"

echo '[2] Межсетевой экран'
UFW_CONFIG="$(priv ufw status verbose)" || UFW_CONFIG=''
check 'Межсетевой экран активен' active "$(awk '/^Status:/ {print $2}' <<< "$UFW_CONFIG")"
check 'Входящий трафик по умолчанию запрещён' deny "$(sed -n 's/^Default: \([^ ]*\) (incoming).*/\1/p' <<< "$UFW_CONFIG")"

echo '[3] Учётные записи'
awk -F: '$3>=1000 && $3<65534 {printf "    %s (uid=%s)\n",$1,$3}' /etc/passwd

if [[ "$WEB_MODE" == yes || ( "$WEB_MODE" == auto && -e "$NGINX_CONFIG" ) ]]; then
    echo '[4] Веб-сервер'
    NGINX_ACTIVE="$(systemctl is-active nginx 2>/dev/null)" || NGINX_ACTIVE="${NGINX_ACTIVE:-unknown}"
    check 'Служба nginx активна' active "$NGINX_ACTIVE"
    NGINX_SYNTAX=1
    if priv nginx -t; then NGINX_SYNTAX=0; fi
    check 'Конфигурация nginx синтаксически корректна' 0 "$NGINX_SYNTAX"
    CERT_VALID=1
    if openssl x509 -in "$TLS_CERT" -noout -checkend "$CERT_MIN_SECONDS"; then CERT_VALID=0; fi
    check "Сертификат действует ещё не менее ${CERT_MIN_DAYS} дней" 0 "$CERT_VALID"
    PERMISSIONS_OK=no
    WORLD_WRITABLE=''
    KEY_MODE="$(priv stat -c '%a' -- "$TLS_KEY")" || KEY_MODE=unavailable
    if [[ -d "$SITE_DIR" ]] && WORLD_WRITABLE="$(priv find "$SITE_DIR" -perm -o+w -print)"; then
        if [[ -z "$WORLD_WRITABLE" && "$KEY_MODE" == 600 ]]; then PERMISSIONS_OK=yes; fi
    fi
    check 'Нет записи для всех в каталоге ресурса И права ключа равны 600' yes "$PERMISSIONS_OK"
    if [[ "$PERMISSIONS_OK" != yes ]]; then
        printf '    Права ключа: %s\n' "$KEY_MODE"
        if [[ -n "$WORLD_WRITABLE" ]]; then printf '    Доступны для записи всем:\n%s\n' "$WORLD_WRITABLE"; fi
    fi
fi


if [[ "$WEB_MODE" != no && -f /home/devops/app/docker-compose.yml ]]; then
    echo '[5] Контейнеризация'
    APP_DIR=/home/devops/app
    DOCKER_ACTIVE="$(systemctl is-active docker 2>/dev/null)" || DOCKER_ACTIVE=unknown
    check 'Служба docker активна' active "$DOCKER_ACTIVE"
    APP_DB_ID="$(priv docker compose --project-directory "$APP_DIR" ps -q db 2>/dev/null)" || APP_DB_ID=''
    APP_DB_HEALTH=unavailable
    if [[ -n "$APP_DB_ID" ]]; then
        APP_DB_HEALTH="$(priv docker inspect -f '{{.State.Health.Status}}' "$APP_DB_ID" 2>/dev/null)" || APP_DB_HEALTH=unavailable
    fi
    check 'Контейнер PostgreSQL находится в состоянии healthy' healthy "$APP_DB_HEALTH"
    APP_BIND="$(priv docker compose --project-directory "$APP_DIR" port app 5000 2>/dev/null)" || APP_BIND=unavailable
    APP_DB_BIND="$(priv docker compose --project-directory "$APP_DIR" port db 5432 2>/dev/null)" || APP_DB_BIND=''
    APP_SOCKETS="$(ss -H -ltn 2>/dev/null)" || APP_SOCKETS='unavailable'
    APP_PORTS_OK=no
    if [[ "$APP_BIND" == '127.0.0.1:5000' && ( -z "$APP_DB_BIND" || "$APP_DB_BIND" == ':0' ) && "$APP_SOCKETS" != unavailable ]] &&
       awk '$4 ~ /:(5000|5432)$/ && $4 !~ /^127[.]0[.]0[.]1:/ {bad=1} END {exit bad}' <<< "$APP_SOCKETS"; then
        APP_PORTS_OK=yes
    fi
    check 'Порт 5000 только на 127.0.0.1 и порт 5432 не опубликован' yes "$APP_PORTS_OK"
    APP_ENV_MODE="$(priv stat -c '%a' "$APP_DIR/.env" 2>/dev/null)" || APP_ENV_MODE=unavailable
    check 'Права файла приложения .env равны 600' 600 "$APP_ENV_MODE"
fi

# Insert before final PASS/FAIL summary in the existing scripts/audit.sh.
# Uses existing check() and priv(); no secrets printed.
if [[ -f /home/devops/kr2/docker-compose.yml ]]; then
    echo '[6] Контрольная работа № 2'
    KR_DIR=/home/devops/kr2
    kr_compose() { priv env -u REDIS_PASSWORD docker compose --project-directory "$KR_DIR" "$@"; }
    KR_REDIS_ID="$(kr_compose ps -q redis 2>/dev/null)" || KR_REDIS_ID=''
    KR_HEALTH=unavailable
    if [[ -n "$KR_REDIS_ID" ]]; then KR_HEALTH="$(priv docker inspect -f '{{.State.Health.Status}}' "$KR_REDIS_ID" 2>/dev/null)" || KR_HEALTH=unavailable; fi
    check 'Redis КР2 находится в состоянии healthy' healthy "$KR_HEALTH"
    KR_BIND="$(kr_compose port app 8003 2>/dev/null)" || KR_BIND=unavailable
    check 'Порт КР2 опубликован только на 127.0.0.1' '127.0.0.1:8003' "$KR_BIND"
    KR_ENV_MODE="$(priv stat -c '%a' "$KR_DIR/.env" 2>/dev/null)" || KR_ENV_MODE=unavailable
    check 'Права .env КР2 равны 600' 600 "$KR_ENV_MODE"
    KR_CERT_RC=1
    if openssl x509 -in /etc/ssl/certs/kr2.crt -noout -checkend 2592000; then KR_CERT_RC=0; fi
    check 'Сертификат КР2 действителен ещё 30 дней' 0 "$KR_CERT_RC"
    KR_ENABLED=no
    if [[ -L /etc/nginx/sites-enabled/kr2 && -e /etc/nginx/sites-enabled/kr2 ]]; then KR_ENABLED=yes; fi
    check 'Ресурс КР2 активирован' yes "$KR_ENABLED"
fi

printf 'Пройдено: %s, не пройдено: %s\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then exit 0; else exit 1; fi
