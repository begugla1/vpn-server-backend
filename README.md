# VPN Backend — 3X-UI Manager

Backend-сервис для централизованного управления несколькими серверами
с панелью [3X-UI](https://github.com/MHSanaei/3x-ui).
Предоставляет REST API для Telegram-бота: управление пользователями,
серверами, инбаундами и подписками.

## Возможности

- Управление несколькими серверами с 3X-UI
- CRUD пользователей (идентификация по Telegram ID)
- Создание и управление инбаундами (VLESS, VMess, Trojan, Shadowsocks)
- Создание подписок (subscription links) для пользователей
- Синхронизация инбаундов с существующих 3X-UI панелей
- Мониторинг статуса серверов в реальном времени
- Управление трафиком и сроком действия подписок

## Быстрый старт

### Требования

- Docker ≥ 20.10
- Docker Compose ≥ 2.0
- Один или несколько серверов с установленной 3X-UI панелью

### Установка

```bash
git clone <repository-url>
cd vpn_backend

# Создать файл конфигурации
cp .env.example .env

# Отредактировать конфигурацию
nano .env

# Запустить
docker compose up -d --build
```

### Проверка

```bash
curl http://localhost:8000/health
# {"status":"ok"}

# Swagger UI
open http://localhost:8000/docs
```

## Конфигурация

Все параметры задаются через переменные окружения или файл `.env`.

### Обязательные переменные

| Переменная     | Описание                                                                                                 | Пример                                                      |
| -------------- | -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `DATABASE_URL` | Строка подключения к PostgreSQL. Формат: `postgresql+asyncpg://<user>:<password>@<host>:<port>/<dbname>` | `postgresql+asyncpg://vpn_user:vpn_password@db:5432/vpn_db` |

### Опциональные переменные приложения

| Переменная | Описание                                                                             | Значение по умолчанию |
| ---------- | ------------------------------------------------------------------------------------ | --------------------- |
| `APP_HOST` | Хост, на котором слушает приложение                                                  | `0.0.0.0`             |
| `APP_PORT` | Порт приложения                                                                      | `8000`                |
| `DEBUG`    | Режим отладки. Включает вывод SQL-запросов в логи. **Не использовать в продакшене.** | `false`               |

### Опциональные переменные 3X-UI (значения по умолчанию)

Эти переменные используются как **значения по умолчанию** при создании серверов,
если конкретные значения не указаны в запросе.

| Переменная                  | Описание                              | Значение по умолчанию |
| --------------------------- | ------------------------------------- | --------------------- |
| `DEFAULT_XUI_USERNAME`      | Логин для 3X-UI панелей по умолчанию  | `admin`               |
| `DEFAULT_XUI_PASSWORD`      | Пароль для 3X-UI панелей по умолчанию | `admin`               |
| `DEFAULT_XUI_PORT`          | Порт 3X-UI панелей по умолчанию       | `2053`                |
| `DEFAULT_XUI_WEB_BASE_PATH` | Базовый путь панелей по умолчанию     | `/`                   |

### Переменные PostgreSQL (для docker-compose)

Эти переменные используются контейнером PostgreSQL при первом запуске
для создания базы данных и пользователя.

| Переменная          | Описание                        | Значение по умолчанию |
| ------------------- | ------------------------------- | --------------------- |
| `POSTGRES_DB`       | Имя базы данных                 | `vpn_db`              |
| `POSTGRES_USER`     | Пользователь базы данных        | `vpn_user`            |
| `POSTGRES_PASSWORD` | Пароль пользователя базы данных | `vpn_password`        |

> **Важно:** Значения `POSTGRES_USER`, `POSTGRES_PASSWORD` и `POSTGRES_DB`
> должны совпадать с соответствующими частями `DATABASE_URL`.

## Пример файла `.env`

```env
# ═══════════════════════════════════════════
#  DATABASE
# ═══════════════════════════════════════════
# При использовании docker-compose хост = "db" (имя сервиса)
# При локальном запуске хост = "localhost"
DATABASE_URL=postgresql+asyncpg://vpn_user:vpn_password@db:5432/vpn_db

# Параметры для контейнера PostgreSQL
POSTGRES_DB=vpn_db
POSTGRES_USER=vpn_user
POSTGRES_PASSWORD=vpn_password

# ═══════════════════════════════════════════
#  APPLICATION
# ═══════════════════════════════════════════
APP_HOST=0.0.0.0
APP_PORT=8000
DEBUG=false

# ═══════════════════════════════════════════
#  3X-UI DEFAULTS
# ═══════════════════════════════════════════
# Значения по умолчанию для новых серверов.
# Каждый сервер может иметь свои индивидуальные настройки,
# заданные при создании через API.
DEFAULT_XUI_USERNAME=admin
DEFAULT_XUI_PASSWORD=admin
DEFAULT_XUI_PORT=2053
DEFAULT_XUI_WEB_BASE_PATH=/
```

## Настройка продакшен-окружения

### Рекомендации по безопасности

1. **Смените пароль PostgreSQL** на случайный:

   ```bash
   # Генерация случайного пароля
   openssl rand -base64 32
   ```

2. **Не открывайте порт PostgreSQL** наружу.
   Удалите секцию `ports` у сервиса `db` в `docker-compose.yml`:

   ```yaml
   db:
     image: postgres:16-alpine
     # ports:            ← удалить или закомментировать
     #   - "5432:5432"
   ```

3. **Используйте HTTPS** перед приложением (nginx reverse proxy).

4. **Ограничьте доступ к API** по IP, если приложение доступно
   только для вашего Telegram-бота.

### Пример docker-compose для продакшена

```yaml
version: "3.8"

services:
  db:
    image: postgres:16-alpine
    container_name: vpn_backend_db
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    # Порт НЕ пробрасывается наружу
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  backend:
    build: .
    container_name: vpn_backend_app
    depends_on:
      db:
        condition: service_healthy
    env_file:
      - .env
    ports:
      - "127.0.0.1:8000:8000" # Слушаем только на localhost
    restart: unless-stopped

volumes:
  pgdata:
```

### Настройка nginx (опционально)

Если вы хотите HTTPS и доступ по доменному имени:

```nginx
server {
    listen 443 ssl http2;
    server_name api.yourdomain.com;

    ssl_certificate     /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Структура проекта

```
vpn_backend/
├── app/
│   ├── main.py              # Точка входа FastAPI
│   ├── config.py            # Конфигурация (env переменные)
│   ├── database.py          # Подключение к БД
│   ├── exceptions.py        # Пользовательские исключения
│   ├── models/              # SQLAlchemy модели (таблицы БД)
│   │   ├── user.py
│   │   ├── server.py
│   │   ├── inbound.py
│   │   └── subscription.py
│   ├── schemas/             # Pydantic схемы (валидация запросов/ответов)
│   │   ├── user.py
│   │   ├── server.py
│   │   ├── inbound.py
│   │   └── subscription.py
│   ├── services/            # Бизнес-логика
│   │   ├── xui_client.py    # HTTP-клиент для 3X-UI API
│   │   ├── user_service.py
│   │   ├── server_service.py
│   │   ├── inbound_service.py
│   │   └── subscription_service.py
│   └── routers/             # FastAPI роуты (эндпоинты)
│       ├── users.py
│       ├── servers.py
│       ├── inbounds.py
│       └── subscriptions.py
├── .env                     # Переменные окружения (не коммитить!)
├── .env.example             # Пример переменных окружения
├── requirements.txt         # Python-зависимости
├── Dockerfile               # Сборка Docker-образа
├── docker-compose.yml       # Оркестрация контейнеров
└── README.md
```

## API документация

После запуска доступна интерактивная документация:

- **Swagger UI:** `http://localhost:8000/docs`
- **ReDoc:** `http://localhost:8000/redoc`

## Типичный сценарий использования

```bash
# 1. Добавить сервер
curl -X POST http://localhost:8000/api/v1/servers/ \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Germany-1",
    "ip_address": "185.123.45.67",
    "panel_port": 2053,
    "panel_username": "admin",
    "panel_password": "mypassword"
  }'

# 2. Синхронизировать инбаунды (если на сервере уже есть)
curl -X POST http://localhost:8000/api/v1/inbounds/sync/1

# 3. Или создать новый инбаунд
curl -X POST http://localhost:8000/api/v1/inbounds/ \
  -H "Content-Type: application/json" \
  -d '{
    "server_id": 1,
    "remark": "VLESS-TCP",
    "port": 443
  }'

# 4. Создать пользователя
curl -X POST http://localhost:8000/api/v1/users/ \
  -H "Content-Type: application/json" \
  -d '{
    "telegram_id": 123456789,
    "username": "johndoe"
  }'

# 5. Создать подписку
curl -X POST http://localhost:8000/api/v1/subscriptions/ \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": 1,
    "server_id": 1,
    "inbound_id": 1,
    "total_gb": 10737418240
  }'
# → Ответ содержит subscription_url для пользователя

# 6. Получить подписки пользователя (из ТГ-бота)
curl http://localhost:8000/api/v1/subscriptions/?telegram_id=123456789
```

## Лицензия

MIT
