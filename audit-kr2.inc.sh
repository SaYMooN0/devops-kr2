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
