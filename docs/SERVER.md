# Server Deployment Guide

Этот файл описывает серверные скрипты проекта:

- `ops/backend-host/deploy_production.sh` — подготовка backend-сервера
- `ops/vpn-node/vpn-server.sh` — подготовка VPN-ноды с 3X-UI
- `ops/run-safe.sh` — detached-запуск `ops`-команд, который переживает разрыв SSH

Скрипты ориентированы на Debian/Ubuntu-хосты и рассчитаны на повторный безопасный запуск.

Если не хотите помнить длинные команды, используйте корневой `Makefile`:

```bash
make help
```

## 0. Как запускать так, чтобы пережить разрыв SSH

Эти `ops`-скрипты обновляют пакеты, перезапускают сервисы и меняют firewall, поэтому во время выполнения SSH-сессия может оборваться.

Рекомендуемый запуск:

```bash
make backend-deploy
make vpn-install BACKEND_IP=203.0.113.10 ADMIN_IP=198.51.100.25
```

`ops/run-safe.sh`:

- запускает команду через `systemd-run`, а если его нет, использует `nohup`
- пишет лог в `/var/log/<name>.log`
- сохраняет metadata в `/var/tmp/ops-run-safe/<name>.env`

После переподключения:

```bash
make safe-info JOB=vpn-install
make safe-logs JOB=vpn-install
make safe-status JOB=vpn-install
```

Если нужен интерактивный запуск и на сервере есть `tmux`:

```bash
tmux new -As ops
make vpn-install-direct BACKEND_IP=203.0.113.10 ADMIN_IP=198.51.100.25
```

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
- применяет безопасные `sysctl` и лимиты открытых файлов
- создает helper-команду `backend-status`
- запускает `docker compose`
- применяет миграции Alembic

### Порты backend-хоста

По умолчанию после `deploy_production.sh` снаружи доступны:

- `22/tcp` — SSH
- `8000/tcp` — backend API

### Как запускать

В корне проекта должен существовать корректный `.env`.

```bash
make backend-deploy
```

Если SSH работает не на `22`:

```bash
make backend-deploy SSH_PORT=2222 APP_PORT=8000
```

Если нужен запуск в текущей SSH-сессии:

```bash
make backend-deploy-direct
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
make vpn-install BACKEND_IP=203.0.113.10 ADMIN_IP=198.51.100.25
make vpn-update BACKEND_IP=203.0.113.10 ADMIN_IP=198.51.100.25
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
- `ufw`
- `fail2ban`
- `logrotate`
- `unattended-upgrades`
- helper `vpn-status`
- резервное копирование `x-ui.db`
- cron-задачу для регулярных backup-ов

WARP из автоматической логики удален. Если он нужен, настраивайте его вручную через 3X-UI панель.

### Порты VPN-ноды

Текущая схема firewall такая:

- `22/tcp` — SSH
- `443/tcp` — открыт для всех
- `65000/tcp` — панель 3X-UI, доступ с `BACKEND_IP` и `ADMIN_IP`
- `2096/tcp` — subscription endpoint 3X-UI, доступ только с `BACKEND_IP`

Важно:

- `443/udp` закрыт
- `80/tcp` закрыт
- при включенном firewall переменная `BACKEND_IP` обязательна
- переменная `ADMIN_IP` необязательна, но если задана, получает доступ к панели на `65000/tcp`

### SSL / HTTPS для панели

Скрипт исходит из вашей текущей эксплуатационной модели:

- панель 3X-UI доступна по `HTTPS`
- на VPS уже есть предустановленный self-signed SSL-сертификат
- backend подключается к панели по `HTTPS`, но без строгой проверки сертификата

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
ADMIN_IP
SSH_PORT
ENABLE_BBR
ENABLE_FIREWALL
SQLITE_BUSY_TIMEOUT_MS
SQLITE_RETRY_ATTEMPTS
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
ADMIN_IP=""          # опционален, дает доступ к панели на 65000/tcp
SSH_PORT=22
ENABLE_BBR=true
ENABLE_FIREWALL=true
SQLITE_BUSY_TIMEOUT_MS=15000
SQLITE_RETRY_ATTEMPTS=5
```

### Пример установки новой VPN-ноды

```bash
make vpn-install BACKEND_IP=203.0.113.10 ADMIN_IP=198.51.100.25
```

Если нужен запуск без detached-режима:

```bash
make vpn-install-direct BACKEND_IP=203.0.113.10 ADMIN_IP=198.51.100.25
```

### Пример безопасного update

```bash
make vpn-update BACKEND_IP=203.0.113.10 ADMIN_IP=198.51.100.25
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

### Что сохранить после fresh install

На новой установке создается файл:

```bash
/root/.vpn-server-credentials
```

Там лежат итоговые доступы к панели и служебная информация по конфигурации.

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
journalctl -u x-ui -f
systemctl status x-ui
ufw status verbose
fail2ban-client status
```

## 5. Связанные документы

- `README.md` — обзор backend и быстрый старт
- `docs/PIPELINE.md` — endpoint-ы, бизнес-правила и схема БД
