#!/usr/bin/env bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run via sudo bash on VM' >&2; exit 1; }
[[ -f /home/devops/kr2/nginx-kr2.conf ]] || { echo 'Copy nginx-kr2.conf to ~/kr2 before publishing' >&2; exit 1; }
if [[ -e /etc/nginx/sites-available/kr2 || -e /etc/ssl/private/kr2.key || -e /etc/ssl/certs/kr2.crt ]]; then
    echo 'KR2 configuration or certificate already exists; review manually. Nothing overwritten.' >&2
    exit 1
fi
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/private/kr2.key -out /etc/ssl/certs/kr2.crt \
    -subj '/CN=stats.devops.local' -addext 'subjectAltName=DNS:stats.devops.local'
chown root:root /etc/ssl/private/kr2.key /etc/ssl/certs/kr2.crt
chmod 600 /etc/ssl/private/kr2.key
chmod 644 /etc/ssl/certs/kr2.crt
install -o root -g root -m 644 /home/devops/kr2/nginx-kr2.conf /etc/nginx/sites-available/kr2
ln -s /etc/nginx/sites-available/kr2 /etc/nginx/sites-enabled/kr2
if nginx -t; then
    systemctl reload nginx
else
    # Undo only the activation symlink created by this script; existing resources stay active.
    unlink /etc/nginx/sites-enabled/kr2
    exit 1
fi
openssl x509 -in /etc/ssl/certs/kr2.crt -noout -subject -dates -ext subjectAltName
stat -c '%a %U:%G %n' /etc/ssl/private/kr2.key
