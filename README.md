# VPN Backend — 3X-UI Manager

Backend для управления VPN-нодами с 3X-UI: пользователи, серверы, inbounds, подписки и интеграция с Xray/3X-UI.

## Что уже реализовано

- backend API закрыт токеном `BACKEND_API_TOKEN`
- защищены ` /api/v1/*`, `/health`, `/docs`, `/redoc`, `/openapi.json`
- у пользователя может быть только одна подписка
- есть автоназначение подписки на любой доступный сервер с soft-limit
- default 3X-UI panel port for new backend records: `65000`
- у серверов есть `max_subscriptions`
- default VLESS inbound создается без лишнего клиента
- inbound хранит `expiry_time`, а `(server_id, xui_inbound_id)` защищены unique constraint
- есть server scripts для backend-хоста и VPN-ноды
- `vpn-server.sh` ставит официальный `warp-cli`, включает локальный proxy mode на `127.0.0.1:40000` и подготавливает self-signed HTTPS для панели

## Структура

```text
app/                     FastAPI backend
alembic/                 DB migrations
Makefile                 short project commands
ops/run-safe.sh          detached wrapper for ops scripts
ops/backend-host/        deploy_production.sh
ops/vpn-node/            vpn-server.sh
docs/                    deployment и pipeline документация
docker-compose.yml
Dockerfile
README.md
```

## Быстрый старт

```bash
cp .env.example .env
docker compose up -d --build
docker compose run --rm backend alembic upgrade head
```

Проверка health:

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" http://localhost:8000/health
```

OpenAPI schema:

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" http://localhost:8000/openapi.json
```

Важно: `/docs` и `/redoc` тоже закрыты токеном. Для браузера нужен header injection extension или любой инструмент, который умеет добавлять `Authorization: Bearer ...` к запросам страницы и schema.

## Основные переменные `.env`

Обязательные:

- `DATABASE_URL`
- `BACKEND_API_TOKEN`

Базовые:

- `APP_HOST=0.0.0.0`
- `APP_PORT=8000`
- `DEBUG=false`

3X-UI defaults для новых server records в backend:

- `vpn-server.sh` больше не применяет эти значения к панели автоматически
- используйте реальные параметры панели при создании/обновлении записи сервера

- `DEFAULT_XUI_USERNAME=admin`
- `DEFAULT_XUI_PASSWORD=admin`
- `DEFAULT_XUI_PORT=65000`
- `DEFAULT_XUI_WEB_BASE_PATH=/`
- `DEFAULT_SERVER_MAX_SUBSCRIPTIONS=120`

PostgreSQL для `docker compose`:

- `POSTGRES_DB`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`

## Пример `.env`

```env
# DATABASE
DATABASE_URL=postgresql+asyncpg://vpn_user:vpn_password@db:5432/vpn_db

# API SECURITY
BACKEND_API_TOKEN=change-me-to-a-long-random-token

# POSTGRES
POSTGRES_DB=vpn_db
POSTGRES_USER=vpn_user
POSTGRES_PASSWORD=vpn_password

# APPLICATION
APP_HOST=0.0.0.0
APP_PORT=8000
DEBUG=false

# 3X-UI DEFAULTS FOR NEW SERVER RECORDS IN BACKEND
DEFAULT_XUI_USERNAME=admin
DEFAULT_XUI_PASSWORD=admin
DEFAULT_XUI_PORT=65000
DEFAULT_XUI_WEB_BASE_PATH=/
DEFAULT_SERVER_MAX_SUBSCRIPTIONS=120
```

## Типовые команды

Все длинные команды вынесены в корневой `Makefile`:

```bash
make help
```

Локальный запуск:

```bash
make up
make logs
make migrate
```

Серверные `ops`-скрипты лучше запускать через `ops/run-safe.sh`, потому что во время установки может оборваться SSH. Лог пишется в `/var/log/<name>.log`, metadata сохраняется в `/var/tmp/ops-run-safe/<name>.env`.

Если SSH у сервера работает не на `22`, обязательно передавайте `SSH_PORT=...` в `deploy_production.sh` и `vpn-server.sh`, иначе можно закрыть себе доступ после применения firewall.

Backend host deploy:

```bash
make backend-deploy
```

VPN node install:

```bash
make vpn-install BACKEND_IP=203.0.113.10
```

После install откройте `/root/.vpn-server-credentials`: там будет фактический URL панели, текущий логин и путь к self-signed сертификату. Настройки панели (`port`, `webBasePath`, subscription path и routing rules) теперь меняются вручную в 3X-UI.

VPN node install с доступом к панели для админа:

```bash
make vpn-install BACKEND_IP=203.0.113.10 ADMIN_IP=198.51.100.25
```

VPN node update:

```bash
make vpn-update BACKEND_IP=203.0.113.10
```

Backend host deploy с кастомным SSH-портом:

```bash
make backend-deploy SSH_PORT=2222 APP_PORT=8000
```

Ручной backup VPN-ноды:

```bash
make vpn-backup
```

Проверка после переподключения:

```bash
make safe-info JOB=vpn-install
make safe-logs JOB=vpn-install
```

Для `systemd`-запуска можно дополнительно проверить unit из поля `UNIT=...`:

```bash
make safe-status JOB=vpn-install
```

## Что делает `vpn-server.sh`

- ставит 3X-UI без project-specific правок панели
- создает self-signed сертификат `x-ui.crt` / `x-ui.key` в `/root/cert/` и привязывает его к панели
- ставит официальный `warp-cli`, регистрирует клиент и включает local proxy на `127.0.0.1:40000`
- сохраняет итоговую служебную информацию в `/root/.vpn-server-credentials`

Что остается ручным:

- смена panel port / web base path / логина / пароля
- настройка subscription port/path в самой панели
- создание outbound и routing rules в 3X-UI под WARP

## Документация

- [docs/SERVER.md](docs/SERVER.md)
- [docs/CONFIG_PIPELINE.md](docs/CONFIG_PIPELINE.md)
- [docs/API_PIPELINE.md](docs/API_PIPELINE.md)
