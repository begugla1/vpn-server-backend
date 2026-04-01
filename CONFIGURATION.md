# Минимальный production pipeline (без nginx, открытый доступ)

## 1. Подключиться к серверу

```bash
ssh root@YOUR_SERVER_IP
```

---

## 2. Обновить систему

```bash
apt-get update && apt-get upgrade -y
```

---

## 3. Установить Docker

```bash
curl -fsSL https://get.docker.com | sh
docker --version
docker compose version
```

---

## 4. Склонировать проект

```bash
cd /root
git clone YOUR_REPO_URL vpn-backend
cd vpn-backend
```

---

## 5. Создать `.env`

```bash
cp .env.example .env
nano .env
```

Содержимое:

```env
DATABASE_URL=postgresql+asyncpg://vpn_user:vpn_password@db:5432/vpn_db

POSTGRES_DB=vpn_db
POSTGRES_USER=vpn_user
POSTGRES_PASSWORD=vpn_password

APP_HOST=0.0.0.0
APP_PORT=8000
DEBUG=false

DEFAULT_XUI_USERNAME=admin
DEFAULT_XUI_PASSWORD=admin
DEFAULT_XUI_PORT=2053
DEFAULT_XUI_WEB_BASE_PATH=/
```

---

## 6. Убедиться что `docker-compose.yml` открывает порт наружу

```bash
nano docker-compose.yml
```

## 7. Запустить

```bash
docker compose up -d --build
```

---

## 8. Проверить

```bash
# Контейнеры работают?
docker compose ps

# Логи backend
docker compose logs -f backend

# Health check с сервера
curl http://localhost:8000/health

# Health check снаружи (со своего компьютера)
curl http://YOUR_SERVER_IP:8000/health

# Swagger UI — открыть в браузере
# http://YOUR_SERVER_IP:8000/docs
```

---

## Всё

Шесть команд по сути:

```bash
apt-get update && apt-get upgrade -y
curl -fsSL https://get.docker.com | sh
git clone YOUR_REPO_URL vpn-backend
cd vpn-backend
cp .env.example .env
docker compose up -d --build
```

---

## Полезные команды на потом

```bash
# Посмотреть логи
docker compose logs -f backend

# Перезапустить
docker compose restart

# Остановить
docker compose down

# Пересобрать после изменений
git pull
docker compose up -d --build

# Зайти внутрь контейнера backend
docker compose exec backend sh

# Зайти в PostgreSQL
docker compose exec db psql -U vpn_user -d vpn_db
```
