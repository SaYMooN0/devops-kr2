# Контрольная работа 2

Горкунов С.В., ЭФБО-01-24. Номер по списку 7, вариант 3.

Приложение из шаблона https://gitverse.ru/dgimatdinov/kr2-template хранит счётчик посещений в Redis. Логика app.py и зависимости не меняются. В app.py добавлен только комментарий с фамилией для проверки кэша сборки.

Адрес сайта: https://stats.devops.local. Внутри контейнера Gunicorn слушает 0.0.0.0:8003, на VM опубликован только 127.0.0.1:8003. Redis доступен по имени redis в сети backend, его порт не опубликован. Данные сохраняются в томе redis_data с AOF. Оба сервиса используют restart: unless-stopped.

## Развёртывание

На Windows нужна запись в hosts: `192.168.56.101 stats.devops.local`.

Доставка из корня репозитория через Bash:

```bash
rsync -avz --delete --exclude=.env --exclude=.git --dry-run ./ devops:kr2/
rsync -avz --delete --exclude=.env --exclude=.git ./ devops:kr2/
```

На сервере от пользователя devops:

```bash
bash ~/kr2/03-server-secret.sh
cd ~/kr2
unset REDIS_PASSWORD
docker compose up -d --build --wait
```

03-server-secret.sh создаёт случайный пароль только на сервере. Файл .env имеет права 600 и не меняется при повторной доставке. Пароль из истории исходного шаблона считается раскрытым и не используется.

Первый запуск настройки Nginx:

```bash
sudo bash ~/kr2/04-publish.sh
sudo install -o devops -g devops -m 755 ~/kr2/scripts/audit.sh ~/devops-course-2026/scripts/audit.sh
```

04-publish.sh создаёт отдельный сертификат с SAN stats.devops.local и конфигурацию /etc/nginx/sites-available/kr2. Если эти файлы уже есть, скрипт прекращает работу. Изменение devops-site и правил UFW не требуется.

## Проверка

```bash
cd ~/kr2
docker compose ps
docker compose exec -T app id
docker compose exec -T app getent hosts redis
docker compose port app 8003
docker compose port redis 6379
curl -fsS http://127.0.0.1:8003/health
sudo bash ~/devops-course-2026/scripts/audit.sh
```

Открытый сертификат можно получить с компьютера командой `scp devops:/etc/ssl/certs/kr2.crt ~/kr2.crt`. Закрытый ключ остаётся на сервере.

```bash
curl --cacert ~/kr2.crt https://stats.devops.local/
curl --cacert ~/kr2.crt https://stats.devops.local/whoami
curl --cacert ~/devops.crt https://devops.local/app/
```

Обычный `docker compose down` сохраняет том. Команду `down -v` для КР2 не использовать.

Если Nginx возвращает 502, проверить docker compose ps, /var/log/nginx/kr2.error.log и curl http://127.0.0.1:8003/health. Если /health работает, а / возвращает 500, проверить Redis, REDIS_HOST и согласованность пароля. Не выводить полный docker inspect или docker compose config, поскольку в них виден пароль.

Pull Request kr2/variant-3 → main остаётся открытым до защиты.
