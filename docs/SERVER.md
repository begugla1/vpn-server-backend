# Server Deployment Guide

Этот файл описывает серверные скрипты проекта:

- `ops/backend-host/deploy_production.sh` — подготовка backend-хоста
- `ops/vpn-node/vpn-server.sh` — минимальная подготовка VPN-ноды с 3X-UI
- `ops/run-safe.sh` — detached-запуск ops-команд, который переживает разрыв SSH

Скрипты рассчитаны на Debian/Ubuntu и допускают повторный безопасный запуск.

## 1. Безопасный запуск через `run-safe`

`ops`-скрипты обновляют пакеты, перезапускают сервисы и меняют firewall, поэтому SSH-сессия может оборваться.

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

Если нужен запуск прямо в текущей SSH-сессии:

```bash
make vpn-install-direct BACKEND_IP=203.0.113.10 ADMIN_IP=198.51.100.25
```

## 2. Backend Host

### Что делает `deploy_production.sh`

- обновляет систему
- ставит Docker Engine и `docker compose`
- включает `ufw`
- ограничивает Docker-порты через `DOCKER-USER`
- настраивает `fail2ban`
- включает `unattended-upgrades`
- ограничивает размер journald-логов
- применяет безопасные `sysctl` и лимиты
- запускает `docker compose`
- прогоняет `alembic upgrade head`
- создает helper-команду `backend-status`

### Открытые порты backend-хоста

По умолчанию снаружи доступны:

- `22/tcp` — SSH
- `8000/tcp` — backend API

### Запуск

```bash
make backend-deploy
```

Если SSH работает не на `22`:

```bash
make backend-deploy SSH_PORT=2222 APP_PORT=8000
```

### Что проверить

```bash
backend-status
docker compose ps
docker compose logs -f backend
ufw status verbose
fail2ban-client status
```

## 3. VPN Node

### Что делает `vpn-server.sh`

`vpn-server.sh` больше не накатывает project-specific настройки панели. Его задача теперь:

- поставить 3X-UI на новой ноде
- сохранить фактические данные доступа после официального install flow
- после завершения install flow больше не трогать `x-ui`
- настроить только базовый `ufw` и `fail2ban`

Что скрипт не делает:

- не меняет panel port, `webBasePath`, username, password
- не трогает subscription path в панели
- не выпускает и не привязывает TLS-сертификат
- не ставит и не запускает WARP

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
- прерывается, если находит существующую установку 3X-UI

`update`:

- не переустанавливает 3X-UI
- не меняет существующие ручные настройки панели
- не трогает существующий сертификат панели

`backup`:

- сохраняет только `x-ui.db`

### Порты VPN-ноды

При включенном firewall скрипт открывает:

- `22/tcp` — SSH
- `80/tcp` — ACME / HTTP validation
- `443/tcp` — публичный VPN traffic
- текущий panel port 3X-UI — открыт для всех

По умолчанию:

- panel port default: `65000`
- subscription port hint: `2096`

Важно:

- panel port для firewall и credentials берется из `X3UI_PORT`
- `X3UI_PORT`, `X3UI_WEB_BASE_PATH`, `X3UI_USERNAME`, `X3UI_PASSWORD`, `X3UI_SUB_PATH` используются только для firewall и сохранения credentials, а не для автоконфигурации панели
- script intentionally leaves TLS certificate and subscription port opening to you
- если потом вручную меняете panel port или subscription port, убедитесь, что firewall и backend server record обновлены под реальные значения

### SSL / HTTPS для панели

Скрипт сам сертификаты больше не выпускает и не прописывает.

Порт `80/tcp` открывается специально для последующего получения TLS-сертификата через `Let's Encrypt` или другой ACME flow.

Backend по-прежнему работает с self-signed и другими нестандартными сертификатами, потому что `XUIClient` использует `verify=False`.

### WARP

WARP намеренно вынесен из `vpn-server.sh` и ставится вручную после bootstrap ноды.

Причина простая: внешний инсталлятор может зависнуть или изменить свой интерактивный flow, а bootstrap ноды не должен зависеть от этого шага.

Актуальный ручной pipeline и дальнейшая настройка outbound/routing rules описаны в `docs/CONFIG_PIPELINE.md`.

### Переменные окружения для `vpn-server.sh`

Основные:

- `BACKEND_IP`
- `ADMIN_IP`
- `SSH_PORT`
- `X3UI_SUB_PORT`
- `ENABLE_BBR`
- `ENABLE_FIREWALL`

Дополнительные переменные для firewall и сохранения credentials:

- `X3UI_PORT`
- `X3UI_WEB_BASE_PATH`
- `X3UI_SUB_PATH`
- `X3UI_USERNAME`
- `X3UI_PASSWORD`

### Что сохранить после fresh install

После установки создаются:

- `/root/.vpn-server-credentials` — URL панели из install flow, логин и port/path hints
- `/root/.vpn-server-3x-ui-install.log` — сырой лог официального install flow 3X-UI

### Проверка VPN-ноды

```bash
systemctl status x-ui
ufw status verbose
fail2ban-client status
```

## 4. Operational Notes

- При добавлении ноды через API указывайте `use_https=true`.
- При создании server record в backend используйте реальные значения из панели или из `/root/.vpn-server-credentials`, а не старые project defaults.
- `vpn-update` не должен трогать сертификат панели, если вы настроили его вручную.
- После изменения схемы БД не забывайте `alembic upgrade head`.

## 5. Troubleshooting

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
journalctl -u x-ui -f
systemctl status x-ui
```

## 6. Связанные документы

- `README.md` — обзор и быстрый старт
- `docs/CONFIG_PIPELINE.md` — production pipeline новой ноды
- `docs/API_PIPELINE.md` — API, бизнес-правила и схема БД
