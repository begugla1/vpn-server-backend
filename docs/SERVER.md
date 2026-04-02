# Server Deployment Guide

Этот файл описывает серверные скрипты проекта:

- `ops/backend-host/deploy_production.sh` — подготовка backend-сервера
- `ops/vpn-node/vpn-server.sh` — подготовка VPN-ноды с 3X-UI
- `ops/vpn-node/setup_warp.sh` — настройка Cloudflare WARP proxy и routing rules для Xray
- `ops/run-safe.sh` — безопасный detached-запуск `ops`-команд, который переживает разрыв SSH

Скрипты ориентированы на Debian/Ubuntu-хосты и рассчитаны на повторный безопасный запуск.

Если не хотите помнить длинные команды, используйте корневой `Makefile`:

```bash
make help
```

## 0. Как запускать так, чтобы пережить разрыв SSH

Эти `ops`-скрипты обновляют пакеты, перезапускают сервисы и меняют firewall, поэтому во время выполнения SSH-сессия может оборваться. Для таких запусков в репозиторий добавлен helper:

```bash
make vpn-install BACKEND_IP=203.0.113.10
```

```bash
make backend-deploy
```

Что делает `ops/run-safe.sh`:

- запускает команду через `systemd-run`, а если его нет, использует `nohup`
- пишет лог в `/var/log/<name>.log`
- сохраняет metadata в `/var/tmp/ops-run-safe/<name>.env`
- печатает команды для повторного подключения и проверки статуса

Если SSH у сервера работает не на `22`, обязательно передавайте `SSH_PORT=...` в `deploy_production.sh` и `vpn-server.sh`, иначе можно закрыть себе доступ после применения firewall.

После переподключения обычно полезно проверить:

```bash
make safe-info JOB=vpn-install
make safe-logs JOB=vpn-install
```

Если нужен точный `systemd` unit последнего запуска, он лежит в metadata-файле в поле `UNIT=...`.

```bash
make safe-status JOB=vpn-install
```

Если вам нужен именно интерактивный запуск и на сервере есть `tmux`, используйте его. При наличии `xterm-kitty` terminfo он обычно работает корректно:

```bash
tmux new -As ops
make vpn-install-direct BACKEND_IP=203.0.113.10
```

Для этих скриптов предпочтительнее `ops/run-safe.sh`, потому что они не требуют интерактивного ввода и лучше сочетаются с переподключением через SSH.

## 1. Backend-сервер

### Назначение

`ops/backend-host/deploy_production.sh` подготавливает хост для запуска backend через Docker Compose и делает базовый hardening системы.

### Что делает скрипт

- обновляет систему и пакеты
- ставит Docker Engine и `docker compose`
- включает `ufw`
- ограничивает опубликованные Docker-порты через `DOCKER-USER`
- настраивает `fail2ban`
- включает `unattended-upgrades`
- ограничивает размер journald-логов
- включает log rotation для Docker
- применяет безопасные `sysctl` и лимиты открытых файлов
- создает helper-команду `backend-status`
- запускает `docker compose`
- применяет миграции Alembic

### Порты backend-хоста

По умолчанию после `deploy_production.sh` снаружи доступны:

- `22/tcp` — SSH
- `8000/tcp` — backend API

Если вы хотите держать backend только за reverse proxy, поменяйте проброс в `docker-compose.yml` на `127.0.0.1:8000:8000`, а наружу открывайте уже `80/443` на уровне proxy.

### Как запускать

В корне проекта должен существовать корректный `.env`.

```bash
make backend-deploy-direct
```

Для безопасного запуска с переживанием SSH-разрыва:

```bash
make backend-deploy
```

Если SSH работает не на `22`, можно переопределить порт:

```bash
make backend-deploy-direct SSH_PORT=2222 APP_PORT=8000
```

Detached-вариант с кастомным SSH-портом:

```bash
make backend-deploy SSH_PORT=2222 APP_PORT=8000
```

### Что проверить после запуска

```bash
backend-status
docker compose ps
docker compose logs -f backend
ufw status verbose
fail2ban-client status
```

## 2. VPN-нода

### Назначение

`ops/vpn-node/vpn-server.sh` подготавливает сервер с 3X-UI/Xray и поддерживает безопасный update без разрушения существующей базы `x-ui.db`.

### Поддерживаемые команды

```bash
make vpn-install BACKEND_IP=203.0.113.10
make vpn-update BACKEND_IP=203.0.113.10
make vpn-backup
make vpn-version
```

### Safety model

`install`:

- только для нового сервера
- прерывается, если видит существующую установку 3X-UI

`update`:

- делает резервную копию БД перед изменениями
- не переустанавливает 3X-UI
- не трогает существующую базу и уже настроенные данные панели

`backup`:

- сохраняет только `x-ui.db`

### Что настраивает `vpn-server.sh`

- обновление системы и базовых пакетов
- установка 3X-UI на новом сервере
- системные лимиты и network tuning
- `TCP BBR`
- Cloudflare WARP как локальный SOCKS5 proxy для ChatGPT / OpenAI / Claude
- `ufw`
- `fail2ban`
- `logrotate`
- `unattended-upgrades`
- helper `vpn-status`
- резервное копирование `x-ui.db`
- cron-задачу для регулярных backup-ов

### Порты VPN-ноды

Текущая схема firewall такая:

- `22/tcp` — SSH
- `443/tcp` — открыт для всех
- `65000/tcp` — панель 3X-UI, доступ только с `BACKEND_IP`
- `2096/tcp` — subscription endpoint 3X-UI, доступ только с `BACKEND_IP`

Важно:

- `443/udp` закрыт
- `80/tcp` закрыт
- при включенном firewall переменная `BACKEND_IP` обязательна
- для WARP не открываются дополнительные порты, потому что это только исходящее соединение и локальный proxy на `127.0.0.1`

### SSL / HTTPS для панели

Скрипт исходит из вашей текущей эксплуатационной модели:

- панель 3X-UI доступна по `HTTPS`
- на VPS уже есть предустановленный self-signed SSL-сертификат
- backend подключается к панели по `HTTPS`, но без строгой проверки сертификата

Если конкретный провайдер когда-нибудь перестанет выдавать self-signed SSL по умолчанию, этот момент придется донастроить отдельно на стороне VPN-ноды.

### Cloudflare WARP routing

`ops/vpn-node/vpn-server.sh` теперь автоматически вызывает `ops/vpn-node/setup_warp.sh` в обоих режимах:

- `install`
- `update`

Что делает `ops/vpn-node/setup_warp.sh`:

- ставит официальный пакет `cloudflare-warp`
- переводит WARP в proxy mode
- поднимает локальный SOCKS5 proxy на `127.0.0.1:40000` по умолчанию
- делает backup `x-ui.db` перед изменением шаблона
- внедряет в `xrayTemplateConfig` outbound `warp`
- добавляет routing rule для `OpenAI`, `ChatGPT`, `Claude`, `Anthropic`
- перезапускает `x-ui`

На сервер также ставится helper-команда:

```bash
setup-warp
```

Ее можно запускать отдельно для повторной идемпотентной настройки.

Если хотите запускать ее с переживанием SSH-разрыва:

```bash
make warp-setup
```

### Как проверить, что WARP реально работает

1. Проверить состояние службы WARP:

```bash
warp-cli --accept-tos status
systemctl status warp-svc
```

Ожидаемо:

- статус `Connected`
- сервис `warp-svc` в состоянии `active`

2. Проверить, что локальный SOCKS5 proxy слушает нужный порт:

```bash
ss -ltnp | grep 40000
```

Если вы переопределяли `WARP_PROXY_PORT`, подставьте свой порт.

3. Проверить, что outbound и routing rule попали в шаблон Xray:

```bash
sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='xrayTemplateConfig';" \
  | jq '.outbounds[] | select(.tag == "warp")'
```

```bash
sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='xrayTemplateConfig';" \
  | jq '.routing.rules[] | select(.outboundTag == "warp")'
```

4. Проверить сам прокси прямым запросом:

```bash
curl --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

В ответе обычно можно увидеть строку вида `warp=on`.

5. Если что-то не взлетело, посмотреть логи:

```bash
journalctl -u warp-svc -n 100 --no-pager
journalctl -u x-ui -n 100 --no-pager
```

### Переменные окружения для `vpn-server.sh`

Поддерживаются переопределения:

```bash
X3UI_PORT
X3UI_SUB_PORT
X3UI_WEB_BASE_PATH
X3UI_SUB_PATH
X3UI_USERNAME
X3UI_PASSWORD
BACKEND_IP
SSH_PORT
ENABLE_BBR
ENABLE_FIREWALL
ENABLE_WARP_ROUTING
WARP_PROXY_PORT
```

Текущие дефолты:

```bash
X3UI_PORT=65000
X3UI_SUB_PORT=2096
X3UI_WEB_BASE_PATH=/secretpanel
X3UI_SUB_PATH=""
X3UI_USERNAME=admin
X3UI_PASSWORD=""     # сгенерируется на fresh install, если не задан
BACKEND_IP=""        # обязателен при ENABLE_FIREWALL=true
SSH_PORT=22
ENABLE_BBR=true
ENABLE_FIREWALL=true
ENABLE_WARP_ROUTING=true
WARP_PROXY_PORT=40000
```

### Пример установки новой VPN-ноды

```bash
make vpn-install-direct BACKEND_IP=203.0.113.10
```

Detached-вариант:

```bash
make vpn-install BACKEND_IP=203.0.113.10
```

С кастомными параметрами:

```bash
sudo BACKEND_IP=203.0.113.10 \
  X3UI_WEB_BASE_PATH=/secretpanel \
  X3UI_USERNAME=admin \
  X3UI_PASSWORD='strong-password-here' \
  bash ./ops/vpn-node/vpn-server.sh install
```

### Пример безопасного update

```bash
make vpn-update-direct BACKEND_IP=203.0.113.10
```

Detached-вариант:

```bash
make vpn-update BACKEND_IP=203.0.113.10
```

Если нужно временно отключить автонастройку WARP:

```bash
make vpn-update BACKEND_IP=203.0.113.10 ENABLE_WARP_ROUTING=false
```

### Резервные копии

Ручной backup:

```bash
make vpn-backup
```

Путь хранения:

```bash
/root/x-ui-backups
```

Скрипт сохраняет только последние 30 backup-файлов и ставит cron-задачу для регулярного резервного копирования.

### Что сохранить после fresh install

На новой установке создается файл:

```bash
/root/.vpn-server-credentials
```

Там лежат итоговые доступы к панели и служебная информация по конфигурации. После сохранения данных файл лучше убрать в безопасное место.

## 3. Операционные рекомендации

- Перед массовыми изменениями на VPN-ноде запускайте `backup`.
- На backend-хосте не открывайте PostgreSQL наружу.
- При добавлении ноды через API указывайте `use_https=true`.
- Если нода поднималась через `vpn-server.sh`, в backend-записи сервера обычно должны совпадать:
  - `panel_port=65000`
  - `subscription_port=2096`
  - `web_base_path=/secretpanel`
- После изменения схемы БД не забывайте `alembic upgrade head`.

## 4. Troubleshooting

Backend-хост:

```bash
backend-status
docker compose ps
docker compose logs -f backend
ufw status verbose
fail2ban-client status
```

VPN-нода:

```bash
vpn-status
setup-warp
warp-cli --accept-tos status
systemctl status warp-svc
journalctl -u warp-svc -n 100 --no-pager
journalctl -u x-ui -f
systemctl status x-ui
ufw status verbose
fail2ban-client status
```

## 5. Связанные документы

- `README.md` — обзор backend и быстрый старт
- `docs/PIPELINE.md` — endpoint-ы, бизнес-правила и схема БД
