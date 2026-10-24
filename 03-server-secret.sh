#!/usr/bin/env bash
set -euo pipefail
[[ "$(id -un)" == devops ]] || { echo 'Run as devops on the VM' >&2; exit 1; }
cd "$HOME/kr2"
if [[ -e .env ]]; then
    [[ "$(stat -c '%a %U' .env)" == '600 devops' ]] || { echo 'Existing .env has wrong owner/mode' >&2; exit 1; }
    grep -qE '^REDIS_PASSWORD=[0-9a-f]{32,}$' .env || { echo 'Existing secret requires manual review' >&2; exit 1; }
    echo 'Existing server secret retained'
else
    umask 077
    printf 'REDIS_PASSWORD=%s\n' "$(openssl rand -hex 16)" > .env
    chmod 600 .env
    echo 'New random password generated on VM; not printed'
fi
unset REDIS_PASSWORD
stat -c '%a %U:%G %n' .env
docker compose config -q
echo 'Compose syntax accepted; expanded configuration was not printed'
