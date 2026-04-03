# Setup Pipeline

Этот документ описывает актуальный production pipeline:

- поднять backend-хост
- поднять новую VPN-ноду
- вручную довести панель 3X-UI до нужной конфигурации
- зарегистрировать сервер в backend
- синхронизировать inbound-ы

## 1. Что подготовить заранее

Перед началом нужны:

- публичный IP backend-хоста
- `BACKEND_API_TOKEN`
- SSH-доступ к backend-хосту
- SSH-доступ к VPN-ноде
- публичный IP VPN-ноды

Важно:

- `vpn-server.sh` больше не выставляет panel port, `webBasePath`, username, password и subscription path автоматически
- после установки реальные параметры панели берите из `/root/.vpn-server-credentials`

## 2. Backend Host Pipeline

### 2.1 Подготовить `.env`

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
DEFAULT_SERVER_MAX_SUBSCRIPTIONS=120
```

Эти `DEFAULT_XUI_*` значения используются только как backend defaults при создании нового server record. Они не заставляют `vpn-server.sh` менять саму панель.

### 2.2 Запустить deploy

Рекомендуемый запуск:

```bash
make backend-deploy
```

Если нужен кастомный SSH-порт:

```bash
make backend-deploy SSH_PORT=2222 APP_PORT=8000
```

### 2.3 Проверка backend-хоста

```bash
backend-status
docker compose ps
docker compose logs -f backend
ufw status verbose
fail2ban-client status
```

## 3. VPN Node Pipeline

### 3.1 Установить ноду

Минимальный запуск:

```bash
make vpn-install BACKEND_IP=<PUBLIC_BACKEND_IP> ADMIN_IP=<YOUR_ADMIN_IP>
```

Если нужен прямой запуск в текущей SSH-сессии:

```bash
make vpn-install-direct BACKEND_IP=<PUBLIC_BACKEND_IP> ADMIN_IP=<YOUR_ADMIN_IP>
```

Полезные override-переменные:

- `SSH_PORT`
- `X3UI_SUB_PORT`
- `ENABLE_BBR`
- `ENABLE_FIREWALL`
- `WARP_PROXY_PORT`
- `PANEL_CERT_DAYS`

Дополнительные переменные для firewall и сохранения credentials:

- `X3UI_PORT`
- `X3UI_WEB_BASE_PATH`
- `X3UI_SUB_PATH`
- `X3UI_USERNAME`
- `X3UI_PASSWORD`

### 3.2 Что делает install

Скрипт:

- ставит 3X-UI
- сохраняет install log в `/root/.vpn-server-3x-ui-install.log`
- создает self-signed сертификат `/root/cert/x-ui.crt` и `/root/cert/x-ui.key`
- привязывает этот сертификат к панели
- ставит официальный `warp-cli`
- регистрирует WARP и включает local proxy на `127.0.0.1:40000`
- настраивает firewall, `fail2ban`, backup `x-ui.db`

### 3.3 Что проверить сразу после install

```bash
cat /root/.vpn-server-credentials
vpn-status
systemctl status x-ui
systemctl status warp-svc
warp-cli --accept-tos status
ufw status verbose
```

Файл `/root/.vpn-server-credentials` содержит:

- фактический panel URL
- текущий username
- password, если его удалось вытащить из install log
- subscription port hint
- локальный WARP proxy
- пути к сертификату

## 4. Ручная настройка панели 3X-UI

### 4.1 Войти в панель

Откройте URL из `/root/.vpn-server-credentials`.

Если вы потом меняете panel port, `webBasePath`, username или password:

- обновите firewall при необходимости
- используйте эти новые реальные значения при создании server record в backend

### 4.2 Настроить panel settings вручную

Скрипт этого больше не делает. В панели вручную задайте все нужное под свою модель:

- panel port
- `webBasePath`
- username/password
- subscription port и subscription path

### 4.3 Донастроить WARP в 3X-UI

Скрипт готовит только локальный proxy на стороне ОС. В самой панели нужно вручную:

- создать outbound, который использует локальный proxy `127.0.0.1:40000`
- создать routing rules для нужных inbound-ов и доменов

### 4.4 Создать inbound вручную

Нужно вручную создать production inbound в 3X-UI.

Минимально:

- protocol: `VLESS`
- inbound должен быть `enabled`
- порт и stream settings должны соответствовать вашей production-схеме

## 5. Добавить VPN-сервер в backend

### 5.1 Подготовить переменные

```bash
export BACKEND_URL="http://<BACKEND_HOST>:8000"
export API_TOKEN="<BACKEND_API_TOKEN>"
export VPN_IP="<VPN_SERVER_PUBLIC_IP>"
```

Если backend стоит за reverse proxy, используйте свой `https://...`.

### 5.2 Создать server record

Подставьте реальные значения панели после ручной настройки:

```bash
curl -X POST "${BACKEND_URL}/api/v1/servers/" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "node-1",
    "ip_address": "'"${VPN_IP}"'",
    "panel_port": 65000,
    "panel_username": "admin",
    "panel_password": "admin",
    "web_base_path": "/",
    "use_https": true,
    "subscription_port": 2096,
    "subscription_base_path": "/sub/",
    "max_subscriptions": 120,
    "is_active": true
  }'
```

Должны совпадать:

- `panel_port`
- `panel_username`
- `panel_password`
- `web_base_path`
- `subscription_port`
- `subscription_base_path`

Если вы уже поменяли панель на нестандартные значения, не оставляйте тут дефолты.

### 5.3 Проверить доступность панели через backend

```bash
curl -H "Authorization: Bearer ${API_TOKEN}" \
  "${BACKEND_URL}/api/v1/servers/<SERVER_ID>/status"
```

Если не работает, проверьте:

- правильный ли `BACKEND_IP` указан при установке ноды
- совпадают ли `panel_port`, `web_base_path`, `panel_username`, `panel_password`
- действительно ли панель отвечает по `HTTPS`

## 6. Синхронизировать inbound-ы

### 6.1 Запустить sync

```bash
curl -X POST \
  -H "Authorization: Bearer ${API_TOKEN}" \
  "${BACKEND_URL}/api/v1/inbounds/sync/<SERVER_ID>"
```

### 6.2 Проверить список inbound-ов

```bash
curl -H "Authorization: Bearer ${API_TOKEN}" \
  "${BACKEND_URL}/api/v1/inbounds/?server_id=<SERVER_ID>"
```

Ожидаемо:

- inbound появился в backend БД
- `enable=true`
- `protocol` и `port` совпадают с 3X-UI

## 7. Что еще важно после sync

Нужно проверить:

1. `server.is_active=true`
2. у сервера есть хотя бы один enabled inbound
3. `max_subscriptions` выставлен под реальную емкость ноды
4. backend реально видит inbound после sync

Без этого `create_subscription_with_any_available_server` не сможет выбрать ноду.

## 8. Частые ошибки

- На VPN-ноде указан неправильный `BACKEND_IP`
- В backend server record не совпадают `panel_port`, `web_base_path`, `panel_username`, `panel_password`
- Панель недоступна по `HTTPS`
- Inbound создан, но не включен
- После ручного создания inbound забыли выполнить `sync`
- Вручную поменяли panel port, но не обновили firewall
- Ожидается, что WARP routing заработает сам по себе, хотя в 3X-UI не был создан outbound/rule

## 9. Что не требуется

Сейчас не требуется:

- вручную устанавливать `warp-cli`
- вручную выпускать self-signed сертификат для 3X-UI
- вручную открывать отдельный внешний порт для WARP proxy
- менять firewall backend-хоста для исходящего доступа к VPN-ноде
