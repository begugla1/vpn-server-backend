# Setup Pipeline

Этот документ описывает полный production pipeline:

- настройка backend-хоста
- настройка новой VPN-ноды
- ручное создание VLESS inbound в 3X-UI
- добавление сервера в backend БД
- синхронизация inbound-ов в backend

## 1. Что подготовить заранее

Перед началом нужно знать:

- публичный IP backend-хоста
- backend URL
- `BACKEND_API_TOKEN`
- SSH-доступ к backend-хосту
- SSH-доступ к VPN-ноде
- значения 3X-UI:
  - `X3UI_PORT`
  - `X3UI_SUB_PORT`
  - `X3UI_WEB_BASE_PATH`
  - `X3UI_USERNAME`
  - `X3UI_PASSWORD`

Рекомендуемые значения проекта:

- `X3UI_PORT=65000`
- `X3UI_SUB_PORT=2096`
- `X3UI_WEB_BASE_PATH=/secretpanel`
- `use_https=true`
- `max_subscriptions=110-130`

## 2. Backend Host Pipeline

### 2.1 Подготовить `.env`

На backend-хосте должен существовать рабочий `.env`.

Минимально обязательные переменные:

```env
DATABASE_URL=postgresql+asyncpg://vpn_user:vpn_password@db:5432/vpn_db
BACKEND_API_TOKEN=change-me
POSTGRES_DB=vpn_db
POSTGRES_USER=vpn_user
POSTGRES_PASSWORD=vpn_password
APP_HOST=0.0.0.0
APP_PORT=8000
DEBUG=false
DEFAULT_XUI_USERNAME=admin
DEFAULT_XUI_PASSWORD=admin
DEFAULT_XUI_PORT=65000
DEFAULT_XUI_WEB_BASE_PATH=/
DEFAULT_SERVER_MAX_SUBSCRIPTIONS=150
```

### 2.2 Запустить backend deploy

Стандартный запуск:

```bash
sudo ./ops/backend-host/deploy_production.sh
```

Если нужно переопределить переменные при запуске:

```bash
sudo \
  APP_PORT=8000 \
  SSH_PORT=22 \
  DB_BACKUP_RETENTION_DAYS=14 \
  DB_BACKUP_HOUR=3 \
  DB_BACKUP_MINUTE=15 \
  ./ops/backend-host/deploy_production.sh
```

Что делает скрипт:

- ставит Docker и `docker compose`
- открывает `22/tcp` и `8000/tcp`
- настраивает `ufw`, `fail2ban`, `DOCKER-USER`
- запускает backend и PostgreSQL
- прогоняет `alembic upgrade head`
- настраивает ежедневный backup PostgreSQL

### 2.3 Проверка backend-хоста

```bash
backend-status
docker compose ps
docker compose logs -f backend
ufw status verbose
fail2ban-client status
sudo /usr/local/bin/backend-db-backup
```

### 2.4 Нужно ли менять firewall backend-хоста

Обычно нет.

С текущим `deploy_production.sh` backend уже принимает:

- `22/tcp`
- `8000/tcp`

Это значит:

- для отправки API-запросов на backend дополнительный firewall update не нужен
- для исходящих запросов backend -> VPN-нода ничего открывать не нужно, исходящий трафик разрешен

Дополнительный firewall update нужен только если вы потом сами ужесточите доступ к `8000/tcp` и переведете его на whitelist по IP.

## 3. VPN Node Pipeline

### 3.1 Выбрать переменные перед запуском

Минимально нужно задать:

- `BACKEND_IP`
- `X3UI_PORT`
- `X3UI_SUB_PORT`
- `X3UI_WEB_BASE_PATH`
- `X3UI_USERNAME`
- `X3UI_PASSWORD`

Рекомендуемый запуск:

```bash
sudo \
  BACKEND_IP=<PUBLIC_BACKEND_IP> \
  X3UI_PORT=65000 \
  X3UI_SUB_PORT=2096 \
  X3UI_WEB_BASE_PATH=/secretpanel \
  X3UI_USERNAME=admin \
  X3UI_PASSWORD='<strong-password>' \
  SSH_PORT=22 \
  ENABLE_BBR=true \
  ENABLE_FIREWALL=true \
  ENABLE_WARP_ROUTING=true \
  WARP_PROXY_PORT=40000 \
  bash ./ops/vpn-node/vpn-server.sh install
```

Что делает скрипт:

- ставит 3X-UI
- включает firewall
- открывает:
  - `22/tcp`
  - `443/tcp` для всех
  - `65000/tcp` только для `BACKEND_IP`
  - `2096/tcp` только для `BACKEND_IP`
- ставит `fail2ban`
- ставит `unattended-upgrades`
- настраивает WARP routing
- ставит backup job для `x-ui.db`

### 3.2 Проверка VPN-ноды

```bash
vpn-status
systemctl status x-ui
warp-cli --accept-tos status
systemctl status warp-svc
ufw status verbose
fail2ban-client status
```

Сохрани файл:

```bash
/root/.vpn-server-credentials
```

## 4. Ручное создание VLESS inbound в 3X-UI

### 4.1 Войти в панель

Если использовались дефолты:

```text
https://<VPN_SERVER_IP>:65000/secretpanel
```

Если вы меняли переменные при установке, подставьте свои:

- `X3UI_PORT`
- `X3UI_WEB_BASE_PATH`

### 4.2 Создать inbound вручную

Нужно вручную создать production VLESS inbound в панели 3X-UI.

Минимальные требования:

- protocol: `VLESS`
- inbound должен быть `enabled`
- рабочий клиентский порт должен совпадать с вашей production-моделью
- Reality/TLS/SNI/target site настраиваются вручную под ваш шаблон

Важно:

- backend сейчас не создает production inbound автоматически
- backend дальше только синхронизирует уже существующий inbound из панели
- если inbound disabled, auto-allocation на него не пойдет

## 5. Добавить VPN-сервер в backend БД

### 5.1 Подготовить переменные для запросов

```bash
export BACKEND_URL="http://<BACKEND_HOST>:8000"
export API_TOKEN="<BACKEND_API_TOKEN>"
export VPN_IP="<VPN_SERVER_PUBLIC_IP>"
```

Если backend стоит за reverse proxy, используйте свой `https://...`.

### 5.2 Создать server record

```bash
curl -X POST "${BACKEND_URL}/api/v1/servers/" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "node-1",
    "ip_address": "'"${VPN_IP}"'",
    "panel_port": 65000,
    "panel_username": "admin",
    "panel_password": "<strong-password>",
    "web_base_path": "/secretpanel",
    "use_https": true,
    "subscription_port": 2096,
    "subscription_base_path": "/sub/",
    "max_subscriptions": 120,
    "is_active": true
  }'
```

Должны совпадать:

- `panel_port` = `X3UI_PORT`
- `panel_username` = `X3UI_USERNAME`
- `panel_password` = `X3UI_PASSWORD`
- `web_base_path` = `X3UI_WEB_BASE_PATH`
- `subscription_port` = `X3UI_SUB_PORT`

### 5.3 Важный момент по `subscription_base_path`

Если вы используете стандартную схему проекта, оставляйте:

```json
"subscription_base_path": "/sub/"
```

Если subscription path в 3X-UI менялся вручную, backend server record должен совпадать с реальным subscription URL. Иначе backend будет собирать неправильные subscription links.

## 6. Проверить backend -> panel connectivity

После создания server record полезно сразу проверить доступность панели через backend:

```bash
curl -H "Authorization: Bearer ${API_TOKEN}" \
  "${BACKEND_URL}/api/v1/servers/<SERVER_ID>/status"
```

Если не работает, проверь:

- правильно ли указан `BACKEND_IP` на VPN-ноде
- совпадают ли `panel_port`, `web_base_path`, `panel_username`, `panel_password`
- действительно ли панель отвечает по `HTTPS`

## 7. Синхронизировать inbound-ы в backend

### 7.1 Запустить sync

```bash
curl -X POST \
  -H "Authorization: Bearer ${API_TOKEN}" \
  "${BACKEND_URL}/api/v1/inbounds/sync/<SERVER_ID>"
```

### 7.2 Проверить список inbound-ов

```bash
curl -H "Authorization: Bearer ${API_TOKEN}" \
  "${BACKEND_URL}/api/v1/inbounds/?server_id=<SERVER_ID>"
```

Ожидаемо:

- inbound появился в backend БД
- `enable=true`
- `protocol` и `port` совпадают с 3X-UI

## 8. Что еще важно после sync

Нужно проверить:

1. `server.is_active=true`
2. у сервера есть хотя бы один `enabled` inbound
3. `max_subscriptions` выставлен под реальную емкость ноды
4. backend реально видит inbound после sync

Без этого `create_subscription_with_any_available_server` не сможет выбрать ноду.

## 9. Короткий pipeline новой ноды

### 9.1 Backend host

```bash
sudo ./ops/backend-host/deploy_production.sh
```

Переменные при необходимости:

- `APP_PORT`
- `SSH_PORT`
- `DB_BACKUP_RETENTION_DAYS`
- `DB_BACKUP_HOUR`
- `DB_BACKUP_MINUTE`

### 9.2 VPN node

```bash
sudo \
  BACKEND_IP=<PUBLIC_BACKEND_IP> \
  X3UI_PORT=65000 \
  X3UI_SUB_PORT=2096 \
  X3UI_WEB_BASE_PATH=/secretpanel \
  X3UI_USERNAME=admin \
  X3UI_PASSWORD='<strong-password>' \
  SSH_PORT=22 \
  ENABLE_BBR=true \
  ENABLE_FIREWALL=true \
  ENABLE_WARP_ROUTING=true \
  WARP_PROXY_PORT=40000 \
  bash ./ops/vpn-node/vpn-server.sh install
```

### 9.3 Ручной inbound

- зайти в панель
- вручную создать production VLESS inbound
- убедиться, что inbound enabled

### 9.4 Добавить server record

```bash
curl -X POST "${BACKEND_URL}/api/v1/servers/" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "node-1",
    "ip_address": "'"${VPN_IP}"'",
    "panel_port": 65000,
    "panel_username": "admin",
    "panel_password": "<strong-password>",
    "web_base_path": "/secretpanel",
    "use_https": true,
    "subscription_port": 2096,
    "subscription_base_path": "/sub/",
    "max_subscriptions": 120,
    "is_active": true
  }'
```

### 9.5 Проверить статус сервера

```bash
curl -H "Authorization: Bearer ${API_TOKEN}" \
  "${BACKEND_URL}/api/v1/servers/<SERVER_ID>/status"
```

### 9.6 Синхронизировать inbound-ы

```bash
curl -X POST \
  -H "Authorization: Bearer ${API_TOKEN}" \
  "${BACKEND_URL}/api/v1/inbounds/sync/<SERVER_ID>"
```

### 9.7 Проверить inbound-ы

```bash
curl -H "Authorization: Bearer ${API_TOKEN}" \
  "${BACKEND_URL}/api/v1/inbounds/?server_id=<SERVER_ID>"
```

## 10. Частые ошибки

- На VPN-ноде указан неправильный `BACKEND_IP`
- В backend server record не совпадают `panel_port`, `web_base_path`, `panel_username`, `panel_password`
- Панель недоступна по `HTTPS`
- Inbound создан, но не включен
- После ручного создания inbound забыли выполнить `sync`
- В backend забыли передать `Authorization: Bearer <BACKEND_API_TOKEN>`

## 11. Что не требуется

Сейчас не требуется:

- вручную открывать дополнительные порты для WARP
- менять firewall backend-хоста для исходящего доступа на VPN-ноду
- вручную создавать inbound в backend через `POST /inbounds/`, если уже был сделан `sync`

Для production pipeline достаточно:

- поднять backend host
- поднять VPN-ноду
- вручную создать inbound в 3X-UI
- зарегистрировать сервер в backend
- выполнить sync inbound-ов
