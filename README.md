# VPN Backend — 3X-UI Manager

Backend для управления VPN-нодами с 3X-UI: пользователи, серверы, inbounds, подписки и интеграция с Xray/3X-UI.

## Что уже реализовано

- backend API закрыт токеном `BACKEND_API_TOKEN`
- защищены ` /api/v1/*`, `/health`, `/docs`, `/redoc`, `/openapi.json`
- у пользователя может быть только одна подписка
- есть автоназначение подписки на любой доступный сервер с soft-limit
- default 3X-UI panel port: `65000`
- у серверов есть `max_subscriptions`
- default VLESS inbound создается без лишнего клиента
- inbound хранит `expiry_time`, а `(server_id, xui_inbound_id)` защищены unique constraint
- есть server scripts для backend-хоста, VPN-ноды и WARP routing

## Структура

```text
app/                     FastAPI backend
alembic/                 DB migrations
ops/run-safe.sh          detached wrapper for ops scripts
ops/backend-host/        deploy_production.sh
ops/vpn-node/            vpn-server.sh, setup_warp.sh
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

3X-UI defaults:

- `DEFAULT_XUI_USERNAME=admin`
- `DEFAULT_XUI_PASSWORD=admin`
- `DEFAULT_XUI_PORT=65000`
- `DEFAULT_XUI_WEB_BASE_PATH=/`
- `DEFAULT_SERVER_MAX_SUBSCRIPTIONS=150`

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

# 3X-UI DEFAULTS
DEFAULT_XUI_USERNAME=admin
DEFAULT_XUI_PASSWORD=admin
DEFAULT_XUI_PORT=65000
DEFAULT_XUI_WEB_BASE_PATH=/
DEFAULT_SERVER_MAX_SUBSCRIPTIONS=150
```

## Типовые команды

Локальный запуск:

```bash
docker compose up -d --build
docker compose logs -f backend
docker compose run --rm backend alembic upgrade head
```

Серверные `ops`-скрипты лучше запускать через `ops/run-safe.sh`, потому что во время установки может оборваться SSH. Лог пишется в `/var/log/<name>.log`, metadata сохраняется в `/var/tmp/ops-run-safe/<name>.env`.

Backend host deploy:

```bash
sudo ./ops/run-safe.sh --name backend-deploy -- \
  bash ./ops/backend-host/deploy_production.sh
```

VPN node install:

```bash
sudo ./ops/run-safe.sh --name vpn-install -- \
  BACKEND_IP=203.0.113.10 bash ./ops/vpn-node/vpn-server.sh install
```

VPN node update:

```bash
sudo ./ops/run-safe.sh --name vpn-update -- \
  BACKEND_IP=203.0.113.10 bash ./ops/vpn-node/vpn-server.sh update
```

WARP routing helper:

```bash
sudo ./ops/run-safe.sh --name setup-warp -- \
  bash ./ops/vpn-node/setup_warp.sh
```

Проверка после переподключения:

```bash
cat /var/tmp/ops-run-safe/vpn-install.env
tail -f /var/log/vpn-install.log
```

## Документация

- [docs/SERVER.md](docs/SERVER.md)
- [docs/PIPELINE.md](docs/PIPELINE.md)
