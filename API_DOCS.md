# Документация VPN Backend — 3X-UI Manager

## Оглавление

1. [Структура базы данных](#1-структура-базы-данных)
2. [API Endpoints](#2-api-endpoints)
   - [Health](#health)
   - [Users](#users)
   - [Servers](#servers)
   - [Inbounds](#inbounds)
   - [Subscriptions](#subscriptions)

---

## 1. Структура базы данных

### ER-диаграмма связей

```
┌──────────┐       ┌──────────────┐       ┌──────────────┐
│  users   │       │   servers    │       │   inbounds   │
├──────────┤       ├──────────────┤       ├──────────────┤
│ id (PK)  │       │ id (PK)      │       │ id (PK)      │
│ tg_id    │       │ name         │◄──┐   │ server_id(FK)│──► servers.id
│ username │       │ ip_address   │   │   │ xui_inb_id   │
│ ...      │       │ panel_port   │   │   │ protocol     │
└────┬─────┘       │ ...          │   │   │ port         │
     │             └──────┬───────┘   │   │ ...          │
     │                    │           │   └──────┬───────┘
     │                    │           │          │
     │             ┌──────┴───────────┴──────────┴───┐
     │             │         subscriptions           │
     └────────────►│                                 │
                   │ id (PK)                         │
                   │ user_id (FK) ──► users.id       │
                   │ server_id (FK) ──► servers.id   │
                   │ inbound_id (FK) ──► inbounds.id │
                   │ client_uuid                     │
                   │ client_email                    │
                   │ sub_id                          │
                   │ subscription_url                │
                   │ ...                             │
                   └─────────────────────────────────┘
```

---

### Таблица `users`

Хранит информацию о пользователях, идентифицируемых через Telegram.

| Колонка       | Тип                 | Ограничения                        | Описание                                                     |
| ------------- | ------------------- | ---------------------------------- | ------------------------------------------------------------ |
| `id`          | `INTEGER`           | `PRIMARY KEY`, `AUTOINCREMENT`     | Внутренний ID пользователя                                   |
| `telegram_id` | `BIGINT`            | `UNIQUE`, `NOT NULL`, `INDEX`      | Telegram ID пользователя — основной идентификатор из ТГ-бота |
| `username`    | `VARCHAR(255)`      | `NULLABLE`                         | Telegram username (без @)                                    |
| `first_name`  | `VARCHAR(255)`      | `NULLABLE`                         | Имя пользователя в Telegram                                  |
| `last_name`   | `VARCHAR(255)`      | `NULLABLE`                         | Фамилия пользователя в Telegram                              |
| `created_at`  | `TIMESTAMP WITH TZ` | `DEFAULT now()`                    | Дата создания записи                                         |
| `updated_at`  | `TIMESTAMP WITH TZ` | `DEFAULT now()`, `ON UPDATE now()` | Дата последнего обновления                                   |

**Связи:**

- `ONE-TO-MANY` → `subscriptions` (у пользователя может быть много подписок)
- Каскадное удаление: при удалении пользователя удаляются все его подписки

**Индексы:**

- `telegram_id` — уникальный индекс для быстрого поиска по Telegram ID

---

### Таблица `servers`

Хранит информацию о серверах с установленной панелью 3X-UI.

| Колонка                  | Тип                 | Ограничения                        | Описание                                             |
| ------------------------ | ------------------- | ---------------------------------- | ---------------------------------------------------- |
| `id`                     | `INTEGER`           | `PRIMARY KEY`, `AUTOINCREMENT`     | Внутренний ID сервера                                |
| `name`                   | `VARCHAR(255)`      | `NOT NULL`                         | Человекочитаемое имя сервера (например, "Germany-1") |
| `ip_address`             | `VARCHAR(45)`       | `NOT NULL`, `UNIQUE`               | IP-адрес сервера (поддержка IPv4 и IPv6)             |
| `panel_port`             | `INTEGER`           | `NOT NULL`, `DEFAULT 2053`         | Порт панели 3X-UI                                    |
| `panel_username`         | `VARCHAR(255)`      | `NOT NULL`, `DEFAULT 'admin'`      | Логин для авторизации в 3X-UI                        |
| `panel_password`         | `VARCHAR(255)`      | `NOT NULL`, `DEFAULT 'admin'`      | Пароль для авторизации в 3X-UI                       |
| `web_base_path`          | `VARCHAR(255)`      | `NOT NULL`, `DEFAULT '/'`          | Базовый путь панели (например, `/secretpath/`)       |
| `use_https`              | `BOOLEAN`           | `NOT NULL`, `DEFAULT false`        | Использовать HTTPS для подключения к панели          |
| `subscription_port`      | `INTEGER`           | `NOT NULL`, `DEFAULT 2096`         | Порт для сервиса подписок на 3X-UI                   |
| `subscription_base_path` | `VARCHAR(255)`      | `NOT NULL`, `DEFAULT '/sub/'`      | Базовый путь подписок                                |
| `open_ports`             | `JSON`              | `NULLABLE`                         | Информация об открытых портах сервера                |
| `configuration`          | `JSON`              | `NULLABLE`                         | Произвольная конфигурация сервера                    |
| `is_active`              | `BOOLEAN`           | `NOT NULL`, `DEFAULT true`         | Флаг активности сервера                              |
| `created_at`             | `TIMESTAMP WITH TZ` | `DEFAULT now()`                    | Дата создания                                        |
| `updated_at`             | `TIMESTAMP WITH TZ` | `DEFAULT now()`, `ON UPDATE now()` | Дата обновления                                      |

**Связи:**

- `ONE-TO-MANY` → `inbounds` (на сервере может быть много инбаундов)
- `ONE-TO-MANY` → `subscriptions` (к серверу привязаны подписки)
- Каскадное удаление: при удалении сервера удаляются все инбаунды и подписки

**Вычисляемое свойство:**

- `panel_base_url` — полный URL для доступа к панели, формируется как `{protocol}://{ip_address}:{panel_port}{web_base_path}`

---

### Таблица `inbounds`

Хранит информацию об инбаундах (точках входа) на серверах 3X-UI. Каждый инбаунд — это отдельный прокси-протокол на определённом порту.

| Колонка           | Тип                 | Ограничения                                     | Описание                                                |
| ----------------- | ------------------- | ----------------------------------------------- | ------------------------------------------------------- |
| `id`              | `INTEGER`           | `PRIMARY KEY`, `AUTOINCREMENT`                  | Внутренний ID инбаунда                                  |
| `server_id`       | `INTEGER`           | `FOREIGN KEY → servers.id`, `NOT NULL`, `INDEX` | К какому серверу относится                              |
| `xui_inbound_id`  | `INTEGER`           | `NOT NULL`                                      | ID инбаунда на стороне 3X-UI панели                     |
| `remark`          | `VARCHAR(255)`      | `NOT NULL`, `DEFAULT ''`                        | Название/пометка инбаунда                               |
| `protocol`        | `VARCHAR(50)`       | `NOT NULL`                                      | Протокол: `vless`, `vmess`, `trojan`, `shadowsocks`     |
| `port`            | `INTEGER`           | `NOT NULL`                                      | Порт, на котором слушает инбаунд                        |
| `settings`        | `JSON`              | `NULLABLE`                                      | Настройки инбаунда (клиенты, шифрование и т.д.)         |
| `stream_settings` | `JSON`              | `NULLABLE`                                      | Транспортные настройки (network, security, TLS/Reality) |
| `sniffing`        | `JSON`              | `NULLABLE`                                      | Настройки сниффинга трафика                             |
| `enable`          | `BOOLEAN`           | `NOT NULL`, `DEFAULT true`                      | Активен ли инбаунд                                      |
| `up`              | `INTEGER`           | `NOT NULL`, `DEFAULT 0`                         | Исходящий трафик (байты)                                |
| `down`            | `INTEGER`           | `NOT NULL`, `DEFAULT 0`                         | Входящий трафик (байты)                                 |
| `total`           | `INTEGER`           | `NOT NULL`, `DEFAULT 0`                         | Лимит трафика (0 = безлимит)                            |
| `created_at`      | `TIMESTAMP WITH TZ` | `DEFAULT now()`                                 | Дата создания                                           |
| `updated_at`      | `TIMESTAMP WITH TZ` | `DEFAULT now()`, `ON UPDATE now()`              | Дата обновления                                         |

**Связи:**

- `MANY-TO-ONE` → `servers` (инбаунд принадлежит серверу)
- `ONE-TO-MANY` → `subscriptions` (к инбаунду привязаны подписки клиентов)
- При удалении сервера (`ON DELETE CASCADE`) — удаляются все инбаунды
- При удалении инбаунда — каскадно удаляются все подписки

**Пример `settings` (JSON) для VLESS:**

```json
{
  "clients": [
    {
      "id": "uuid-here",
      "email": "abc123",
      "flow": "",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": "",
      "subId": "random16chars",
      "reset": 0
    }
  ],
  "decryption": "none",
  "fallbacks": []
}
```

**Пример `stream_settings` (JSON):**

```json
{
  "network": "tcp",
  "security": "reality",
  "externalProxy": [],
  "realitySettings": {
    "dest": "yahoo.com:443",
    "serverNames": ["yahoo.com"],
    "privateKey": "...",
    "shortIds": ["abc123"],
    "settings": {
      "publicKey": "...",
      "fingerprint": "random"
    }
  }
}
```

---

### Таблица `subscriptions`

Центральная таблица, связывающая пользователя, сервер и инбаунд. Представляет собой конкретного клиента на конкретном инбаунде.

| Колонка            | Тип                 | Ограничения                                      | Описание                                                                       |
| ------------------ | ------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------ |
| `id`               | `INTEGER`           | `PRIMARY KEY`, `AUTOINCREMENT`                   | Внутренний ID подписки                                                         |
| `user_id`          | `INTEGER`           | `FOREIGN KEY → users.id`, `NOT NULL`, `INDEX`    | Какому пользователю принадлежит                                                |
| `server_id`        | `INTEGER`           | `FOREIGN KEY → servers.id`, `NOT NULL`, `INDEX`  | На каком сервере                                                               |
| `inbound_id`       | `INTEGER`           | `FOREIGN KEY → inbounds.id`, `NOT NULL`, `INDEX` | В каком инбаунде                                                               |
| `client_uuid`      | `VARCHAR(255)`      | `NOT NULL`                                       | UUID клиента на стороне 3X-UI (client.id для VLESS/VMESS, password для Trojan) |
| `client_email`     | `VARCHAR(255)`      | `NOT NULL`, `UNIQUE`                             | Email-идентификатор клиента в 3X-UI (уникален глобально)                       |
| `sub_id`           | `VARCHAR(255)`      | `NOT NULL`                                       | Идентификатор подписки для формирования URL                                    |
| `subscription_url` | `VARCHAR(1024)`     | `NOT NULL`                                       | Полный URL подписки, который получает пользователь                             |
| `client_config`    | `JSON`              | `NULLABLE`                                       | Полная конфигурация клиента, как она хранится в 3X-UI                          |
| `enable`           | `BOOLEAN`           | `NOT NULL`, `DEFAULT true`                       | Активна ли подписка                                                            |
| `total_gb`         | `BIGINT`            | `NOT NULL`, `DEFAULT 0`                          | Лимит трафика в байтах (0 = безлимит)                                          |
| `expiry_time`      | `BIGINT`            | `NOT NULL`, `DEFAULT 0`                          | Время истечения в Unix timestamp (мс). 0 = бессрочно                           |
| `created_at`       | `TIMESTAMP WITH TZ` | `DEFAULT now()`                                  | Дата создания                                                                  |
| `updated_at`       | `TIMESTAMP WITH TZ` | `DEFAULT now()`, `ON UPDATE now()`               | Дата обновления                                                                |

**Связи:**

- `MANY-TO-ONE` → `users` (подписка принадлежит пользователю)
- `MANY-TO-ONE` → `servers` (подписка привязана к серверу)
- `MANY-TO-ONE` → `inbounds` (подписка привязана к инбаунду)
- Все внешние ключи имеют `ON DELETE CASCADE`

**Формат `subscription_url`:**

```
http://{server_ip}:{subscription_port}/{subscription_base_path}/{sub_id}
```

Пример: `http://185.123.45.67:2096/sub/rqv5zw1ydutamcp0`

**Пример `client_config` (JSON):**

```json
{
  "id": "b86c0cdc-8a02-4da4-8693-72ba27005587",
  "flow": "",
  "email": "nt3wz904",
  "limitIp": 0,
  "totalGB": 10737418240,
  "expiryTime": 1735689600000,
  "enable": true,
  "tgId": "123456789",
  "subId": "rqv5zw1ydutamcp0",
  "comment": "",
  "reset": 0
}
```

---

## 2. API Endpoints

**Базовый URL:** `http://localhost:8000/api/v1`

Все ответы с ошибками имеют формат:

```json
{
  "detail": "Описание ошибки"
}
```

---

### Health

#### `GET /health`

Проверка работоспособности сервера.

**Авторизация:** не требуется

**Параметры:** отсутствуют

**Ответ `200 OK`:**

```json
{
  "status": "ok"
}
```

---

### Users

#### `POST /api/v1/users/`

Создание нового пользователя. Если пользователь с указанным `telegram_id` уже существует — возвращается существующая запись без ошибки (идемпотентно).

**Тело запроса:**

| Поле          | Тип       | Обязательно | Описание                 |
| ------------- | --------- | ----------- | ------------------------ |
| `telegram_id` | `integer` | ✅          | Telegram ID пользователя |
| `username`    | `string`  | ❌          | Telegram username        |
| `first_name`  | `string`  | ❌          | Имя                      |
| `last_name`   | `string`  | ❌          | Фамилия                  |

**Пример запроса:**

```json
{
  "telegram_id": 123456789,
  "username": "johndoe",
  "first_name": "John",
  "last_name": "Doe"
}
```

**Ответ `201 Created`:**

```json
{
  "id": 1,
  "telegram_id": 123456789,
  "username": "johndoe",
  "first_name": "John",
  "last_name": "Doe",
  "created_at": "2025-01-15T10:30:00Z",
  "updated_at": "2025-01-15T10:30:00Z"
}
```

---

#### `GET /api/v1/users/`

Получение списка всех пользователей. Сортировка по дате создания (новые первыми).

**Параметры:** отсутствуют

**Ответ `200 OK`:**

```json
[
  {
    "id": 1,
    "telegram_id": 123456789,
    "username": "johndoe",
    "first_name": "John",
    "last_name": "Doe",
    "created_at": "2025-01-15T10:30:00Z",
    "updated_at": "2025-01-15T10:30:00Z"
  }
]
```

---

#### `GET /api/v1/users/{user_id}`

Получение пользователя по внутреннему ID.

**Параметры пути:**

| Параметр  | Тип       | Описание                   |
| --------- | --------- | -------------------------- |
| `user_id` | `integer` | Внутренний ID пользователя |

**Ответ `200 OK`:** объект пользователя (аналогично созданию)

**Ответ `404 Not Found`:**

```json
{
  "detail": "User with id=999 not found"
}
```

---

#### `GET /api/v1/users/telegram/{telegram_id}`

Поиск пользователя по Telegram ID. Основной способ идентификации из ТГ-бота.

**Параметры пути:**

| Параметр      | Тип       | Описание    |
| ------------- | --------- | ----------- |
| `telegram_id` | `integer` | Telegram ID |

**Ответ `200 OK`:** объект пользователя

**Ответ `404 Not Found`:**

```json
{
  "detail": "User with id=telegram_id=123456789 not found"
}
```

---

#### `GET /api/v1/users/{user_id}/subscriptions`

Получение пользователя вместе со всеми его подписками. Позволяет ТГ-боту одним ��апросом получить всю информацию о пользователе.

**Параметры пути:**

| Параметр  | Тип       | Описание                   |
| --------- | --------- | -------------------------- |
| `user_id` | `integer` | Внутренний ID пользователя |

**Ответ `200 OK`:**

```json
{
  "id": 1,
  "telegram_id": 123456789,
  "username": "johndoe",
  "first_name": "John",
  "last_name": "Doe",
  "created_at": "2025-01-15T10:30:00Z",
  "updated_at": "2025-01-15T10:30:00Z",
  "subscriptions": [
    {
      "id": 1,
      "user_id": 1,
      "server_id": 1,
      "inbound_id": 1,
      "client_uuid": "b86c0cdc-8a02-4da4-8693-72ba27005587",
      "client_email": "nt3wz904",
      "sub_id": "rqv5zw1ydutamcp0",
      "subscription_url": "http://185.123.45.67:2096/sub/rqv5zw1ydutamcp0",
      "client_config": { "..." },
      "enable": true,
      "total_gb": 10737418240,
      "expiry_time": 1735689600000,
      "created_at": "2025-01-15T10:35:00Z",
      "updated_at": "2025-01-15T10:35:00Z"
    }
  ]
}
```

---

#### `PATCH /api/v1/users/{user_id}`

Частичное обновление данных пользователя. Передаются только изменяемые поля.

**Параметры пути:**

| Параметр  | Тип       | Описание                   |
| --------- | --------- | -------------------------- |
| `user_id` | `integer` | Внутренний ID пользователя |

**Тело запроса (все поля опциональны):**

| Поле         | Тип      | Описание       |
| ------------ | -------- | -------------- |
| `username`   | `string` | Новый username |
| `first_name` | `string` | Новое имя      |
| `last_name`  | `string` | Новая фамилия  |

**Пример запроса:**

```json
{
  "username": "new_username"
}
```

**Ответ `200 OK`:** обновлённый объект пользователя

---

#### `DELETE /api/v1/users/{user_id}`

Удаление пользователя. **Каскадно удаляет все подписки пользователя** из БД. Клиенты на стороне 3X-UI при этом **не удаляются** автоматически (только записи в нашей БД).

**Параметры пути:**

| Параметр  | Тип       | Описание                   |
| --------- | --------- | -------------------------- |
| `user_id` | `integer` | Внутренний ID пользователя |

**Ответ `204 No Content`:** пустое тело

---

### Servers

#### `POST /api/v1/servers/`

Регистрация нового сервера с 3X-UI панелью в системе. Сервер не проверяется на доступность при создании — это просто запись в БД с параметрами подключения.

**Тело запроса:**

| Поле                     | Тип       | Обязательно | По умолчанию | Описание                  |
| ------------------------ | --------- | ----------- | ------------ | ------------------------- |
| `name`                   | `string`  | ✅          | —            | Имя сервера               |
| `ip_address`             | `string`  | ✅          | —            | IP-адрес сервера          |
| `panel_port`             | `integer` | ❌          | `2053`       | Порт 3X-UI панели         |
| `panel_username`         | `string`  | ❌          | `"admin"`    | Логин 3X-UI               |
| `panel_password`         | `string`  | ❌          | `"admin"`    | Пароль 3X-UI              |
| `web_base_path`          | `string`  | ❌          | `"/"`        | Базовый путь панели       |
| `use_https`              | `boolean` | ❌          | `false`      | HTTPS для панели          |
| `subscription_port`      | `integer` | ❌          | `2096`       | Порт подписок             |
| `subscription_base_path` | `string`  | ❌          | `"/sub/"`    | Путь подписок             |
| `open_ports`             | `object`  | ❌          | `null`       | Открытые порты сервера    |
| `configuration`          | `object`  | ❌          | `null`       | Произвольная конфигурация |

**Пример запроса:**

```json
{
  "name": "Germany-Frankfurt-1",
  "ip_address": "185.123.45.67",
  "panel_port": 2053,
  "panel_username": "myadmin",
  "panel_password": "supersecret",
  "web_base_path": "/secretpanel/",
  "open_ports": {
    "tcp": [443, 8443, 2053, 2096],
    "udp": [443]
  }
}
```

**Ответ `201 Created`:**

```json
{
  "id": 1,
  "name": "Germany-Frankfurt-1",
  "ip_address": "185.123.45.67",
  "panel_port": 2053,
  "panel_username": "myadmin",
  "web_base_path": "/secretpanel/",
  "use_https": false,
  "subscription_port": 2096,
  "subscription_base_path": "/sub/",
  "open_ports": {
    "tcp": [443, 8443, 2053, 2096],
    "udp": [443]
  },
  "configuration": null,
  "is_active": true,
  "created_at": "2025-01-15T10:00:00Z",
  "updated_at": "2025-01-15T10:00:00Z"
}
```

> **Примечание:** `panel_password` не возвращается в ответе из соображений безопасности (поле отсутствует в `ServerResponse` схеме).

---

#### `GET /api/v1/servers/`

Получение списка всех серверов. Сортировка по дате создания (новые первыми).

**Ответ `200 OK`:** массив объектов серверов

---

#### `GET /api/v1/servers/{server_id}`

Получение сервера по ID.

**Параметры пути:**

| Параметр    | Тип       | Описание   |
| ----------- | --------- | ---------- |
| `server_id` | `integer` | ID сервера |

**Ответ `200 OK`:** объект сервера

**Ответ `404 Not Found`:** если сервер не найден

---

#### `GET /api/v1/servers/{server_id}/status`

Получение текущего статуса сервера **в реальном времени** из 3X-UI панели. Выполняется HTTP-запрос к панели (`/panel/api/server/status`).

**Параметры пути:**

| Параметр    | Тип       | Описание   |
| ----------- | --------- | ---------- |
| `server_id` | `integer` | ID сервера |

**Логика работы:**

1. Из БД достаётся сервер с параметрами подключения
2. Выполняется `login()` на 3X-UI панели
3. Запрашивается `/panel/api/server/status`
4. Если сервер недоступен — возвращается `is_reachable: false` без ошибки

**Ответ `200 OK` (сервер доступен):**

```json
{
  "server_id": 1,
  "server_name": "Germany-Frankfurt-1",
  "is_reachable": true,
  "cpu": 15.5,
  "mem_current": 1073741824,
  "mem_total": 4294967296,
  "disk_current": 5368709120,
  "disk_total": 42949672960,
  "xray_state": "running",
  "xray_version": "v25.9.11",
  "uptime": 864000
}
```

**Ответ `200 OK` (сервер недоступен):**

```json
{
  "server_id": 1,
  "server_name": "Germany-Frankfurt-1",
  "is_reachable": false,
  "cpu": null,
  "mem_current": null,
  "mem_total": null,
  "disk_current": null,
  "disk_total": null,
  "xray_state": null,
  "xray_version": null,
  "uptime": null
}
```

---

#### `PATCH /api/v1/servers/{server_id}`

Частичное обновление настроек сервера.

**Тело запроса (все поля опциональны):**

| Поле                     | Тип       | Описание          |
| ------------------------ | --------- | ----------------- |
| `name`                   | `string`  | Новое имя         |
| `ip_address`             | `string`  | Новый IP          |
| `panel_port`             | `integer` | Новый порт панели |
| `panel_username`         | `string`  | Новый логин       |
| `panel_password`         | `string`  | Новый пароль      |
| `web_base_path`          | `string`  | Новый путь        |
| `use_https`              | `boolean` | HTTPS             |
| `subscription_port`      | `integer` | Порт подписок     |
| `subscription_base_path` | `string`  | Путь подписок     |
| `open_ports`             | `object`  | Открытые порты    |
| `configuration`          | `object`  | Конфигурация      |
| `is_active`              | `boolean` | Активность        |

**Ответ `200 OK`:** обновлённый объект сервера

---

#### `DELETE /api/v1/servers/{server_id}`

Удаление сервера из системы. **Каскадно удаляет** все инбаунды и подписки, привязанные к этому серверу, из нашей БД. На стороне 3X-UI ничего не удаляется.

**Ответ `204 No Content`**

---

### Inbounds

#### `POST /api/v1/inbounds/`

Создание нового инбаунда на сервере. Выполняется **двойное действие**:

1. Создаётся инбаунд на 3X-UI панели через API (`/panel/api/inbounds/add`)
2. Созданный инбаунд сохраняется в нашу БД

Если `settings` не указан — автоматически создаётся дефолтная VLESS конфигурация с TCP транспортом.

**Тело запроса:**

| Поле              | Тип       | Обязательно | По умолчанию    | Описание                                            |
| ----------------- | --------- | ----------- | --------------- | --------------------------------------------------- |
| `server_id`       | `integer` | ✅          | —               | ID сервера, на котором создать инбаунд              |
| `remark`          | `string`  | ❌          | `""`            | Название инбаунда                                   |
| `port`            | `integer` | ✅          | —               | Порт для прослушивания                              |
| `protocol`        | `string`  | ❌          | `"vless"`       | Протокол: `vless`, `vmess`, `trojan`, `shadowsocks` |
| `settings`        | `object`  | ❌          | дефолтный VLESS | Настройки инбаунда (клиенты, шифрование)            |
| `stream_settings` | `object`  | ❌          | TCP/none        | Транспортные настройки                              |
| `sniffing`        | `object`  | ❌          | enabled/all     | Настройки сниффинга                                 |
| `enable`          | `boolean` | ❌          | `true`          | Активен ли инбаунд                                  |
| `total`           | `integer` | ❌          | `0`             | Лимит трафика для инбаунда                          |
| `expiry_time`     | `integer` | ❌          | `0`             | Время истечения                                     |

**Пример простого запроса (дефолтный VLESS):**

```json
{
  "server_id": 1,
  "remark": "VLESS-TCP-Germany",
  "port": 443
}
```

**Пример с кастомной конфигурацией:**

```json
{
  "server_id": 1,
  "remark": "VLESS-Reality",
  "port": 443,
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "custom-uuid-here",
        "email": "default_client",
        "flow": "xtls-rprx-vision",
        "limitIp": 0,
        "totalGB": 0,
        "expiryTime": 0,
        "enable": true,
        "tgId": "",
        "subId": "customsubid12345",
        "reset": 0
      }
    ],
    "decryption": "none",
    "fallbacks": []
  },
  "stream_settings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "dest": "yahoo.com:443",
      "serverNames": ["yahoo.com"],
      "privateKey": "...",
      "shortIds": ["abc123"]
    }
  }
}
```

**Ответ `201 Created`:**

```json
{
  "id": 1,
  "server_id": 1,
  "xui_inbound_id": 5,
  "remark": "VLESS-TCP-Germany",
  "protocol": "vless",
  "port": 443,
  "settings": { "clients": [...], "decryption": "none" },
  "stream_settings": { "network": "tcp", "security": "none", ... },
  "sniffing": { "enabled": true, ... },
  "enable": true,
  "up": 0,
  "down": 0,
  "total": 0,
  "created_at": "2025-01-15T10:20:00Z",
  "updated_at": "2025-01-15T10:20:00Z"
}
```

**Возможные ошибки:**

- `404` — сервер не найден
- `502` — не удалось подключиться к 3X-UI панели
- `502` — ошибка API 3X-UI (например, порт уже занят)

---

#### `GET /api/v1/inbounds/`

Получение списка инбаундов с опциональной фильтрацией по серверу.

**Query-параметры:**

| Параметр    | Тип       | Обязательно | Описание             |
| ----------- | --------- | ----------- | -------------------- |
| `server_id` | `integer` | ❌          | Фильтр по ID сервера |

**Примеры:**

```
GET /api/v1/inbounds/               — все инбаунды
GET /api/v1/inbounds/?server_id=1   — инбаунды сервера #1
```

**Ответ `200 OK`:** массив объектов инбаундов

---

#### `GET /api/v1/inbounds/{inbound_id}`

Получение инбаунда по внутреннему ID.

**Ответ `200 OK`:** объект инбаунда

**Ответ `404 Not Found`:** если инбаунд не найден

---

#### `PATCH /api/v1/inbounds/{inbound_id}`

Обновление инбаунда. Выполняется **двойное действие**:

1. Получается текущая конфигурация инбаунда с 3X-UI
2. Мержатся переданные поля
3. Обновлённая конфигурация отправляется обратно на 3X-UI (`/panel/api/inbounds/update/{id}`)
4. Обновляется запись в нашей БД

**Тело запроса (все поля опциональны):**

| Поле              | Тип       | Описание                     |
| ----------------- | --------- | ---------------------------- |
| `remark`          | `string`  | Новое название               |
| `port`            | `integer` | Новый порт                   |
| `enable`          | `boolean` | Включить/выключить           |
| `settings`        | `object`  | Новые настройки              |
| `stream_settings` | `object`  | Новые транспортные настройки |
| `sniffing`        | `object`  | Новые настройки сниффинга    |

**Пример — отключение инбаунда:**

```json
{
  "enable": false
}
```

**Пример — смена порта и названия:**

```json
{
  "remark": "VLESS-Reality-Updated",
  "port": 8443
}
```

**Ответ `200 OK`:** обновлённый объект инбаунда

---

#### `DELETE /api/v1/inbounds/{inbound_id}`

Удаление инбаунда. **Двойное действие:**

1. Удаляется инбаунд на 3X-UI панели (`/panel/api/inbounds/del/{id}`)
2. Удаляется запись из нашей БД (каскадно удаляются все подписки)

**Ответ `204 No Content`**

---

#### `POST /api/v1/inbounds/sync/{server_id}`

Синхронизация инбаундов с 3X-UI панели в нашу БД. Полезно при:

- Первоначальном подключении сервера с уже настроенными инбаундами
- Ручном изменении настроек через веб-интерфейс 3X-UI
- Периодической сверке данных

**Логика работы:**

1. Запрашивается список всех инбаундов с 3X-UI (`/panel/api/inbounds/list`)
2. Для каждого инбаунда:
   - Если запись с таким `xui_inbound_id` уже есть в нашей БД — **обновляется**
   - Если нет — **создаётся новая** запись

**Параметры пути:**

| Параметр    | Тип       | Описание                     |
| ----------- | --------- | ---------------------------- |
| `server_id` | `integer` | ID сервера для синхронизации |

**Ответ `200 OK`:** массив синхронизированных инбаундов

---

### Subscriptions

#### `POST /api/v1/subscriptions/`

Создание подписки — центральная операция системы. Выполняет:

1. Проверяет существование пользователя, сервера и инбаунда
2. Проверяет, что инбаунд принадлежит указанному серверу
3. Генерирует UUID клиента, email и sub_id
4. Добавляет клиента в инбаунд на 3X-UI панели (`/panel/api/inbounds/addClient`)
5. Формирует `subscription_url`
6. Сохраняет подписку в нашу БД

**Тело запроса:**

| Поле           | Тип       | Обязательно | По умолчанию  | Описание                                       |
| -------------- | --------- | ----------- | ------------- | ---------------------------------------------- |
| `user_id`      | `integer` | ✅          | —             | Внутренний ID пользователя                     |
| `server_id`    | `integer` | ✅          | —             | ID сервера                                     |
| `inbound_id`   | `integer` | ✅          | —             | Внутренний ID инбаунда                         |
| `client_email` | `string`  | ❌          | автогенерация | Email клиента в 3X-UI                          |
| `total_gb`     | `integer` | ❌          | `0`           | Лимит трафика в байтах. `0` = безлимит         |
| `expiry_time`  | `integer` | ❌          | `0`           | Unix timestamp (мс) истечения. `0` = бессрочно |
| `limit_ip`     | `integer` | ❌          | `0`           | Лимит одновременных IP. `0` = без лимита       |
| `enable`       | `boolean` | ❌          | `true`        | Активна ли подписка                            |
| `tg_id`        | `string`  | ❌          | `""`          | Telegram ID для отображения в 3X-UI боте       |
| `flow`         | `string`  | ❌          | `""`          | Flow для VLESS (например, `xtls-rprx-vision`)  |

**Пример — безлимитная бессрочная подписка:**

```json
{
  "user_id": 1,
  "server_id": 1,
  "inbound_id": 1
}
```

**Пример — подписка на 10 ГБ сроком на месяц:**

```json
{
  "user_id": 1,
  "server_id": 1,
  "inbound_id": 1,
  "total_gb": 10737418240,
  "expiry_time": 1738368000000,
  "limit_ip": 2,
  "tg_id": "123456789",
  "flow": "xtls-rprx-vision"
}
```

> **Примечание по `total_gb`:** значение указывается в **байтах**.
>
> - 1 ГБ = `1073741824`
> - 10 ГБ = `10737418240`
> - 100 ГБ = `107374182400`

> **Примечание по `expiry_time`:** значение указывается в **миллисекундах** (формат 3X-UI).
> Пример: `1738368000000` = 1 февраля 2025, 00:00 UTC

**Ответ `201 Created`:**

```json
{
  "id": 1,
  "user_id": 1,
  "server_id": 1,
  "inbound_id": 1,
  "client_uuid": "b86c0cdc-8a02-4da4-8693-72ba27005587",
  "client_email": "nt3wz904",
  "sub_id": "rqv5zw1ydutamcp0",
  "subscription_url": "http://185.123.45.67:2096/sub/rqv5zw1ydutamcp0",
  "client_config": {
    "id": "b86c0cdc-8a02-4da4-8693-72ba27005587",
    "flow": "",
    "email": "nt3wz904",
    "limitIp": 0,
    "totalGB": 0,
    "expiryTime": 0,
    "enable": true,
    "tgId": "",
    "subId": "rqv5zw1ydutamcp0",
    "comment": "",
    "reset": 0
  },
  "enable": true,
  "total_gb": 0,
  "expiry_time": 0,
  "created_at": "2025-01-15T10:35:00Z",
  "updated_at": "2025-01-15T10:35:00Z"
}
```

**Возможные ошибки:**

- `404` — пользователь / сервер / инбаунд не найден
- `400` — инбаунд не принадлежит указанному серверу
- `502` — ошибка подключения к 3X-UI
- `502` — ошибка API 3X-UI

---

#### `GET /api/v1/subscriptions/`

Получение списка подписок с фильтрацией. Поддерживается комбинация фильтров.

**Query-параметры:**

| Параметр      | Тип       | Обязательно | Описание                              |
| ------------- | --------- | ----------- | ------------------------------------- |
| `user_id`     | `integer` | ❌          | Фильтр по внутреннему ID пользователя |
| `server_id`   | `integer` | ❌          | Фильтр по ID сервера                  |
| `telegram_id` | `integer` | ❌          | Фильтр по Telegram ID (JOIN с users)  |

**Примеры:**

```
GET /api/v1/subscriptions/                          — все подписки
GET /api/v1/subscriptions/?user_id=1                — подписки пользователя #1
GET /api/v1/subscriptions/?server_id=2              — подписки на сервере #2
GET /api/v1/subscriptions/?telegram_id=123456789    — подписки по Telegram ID
GET /api/v1/subscriptions/?user_id=1&server_id=2    — комбинированный фильтр
```

**Ответ `200 OK`:** массив объектов подписок

---

#### `GET /api/v1/subscriptions/{subscription_id}`

Получение подписки по ID.

**Ответ `200 OK`:** объект подписки

**Ответ `404 Not Found`:** если подписка не найдена

---

#### `GET /api/v1/subscriptions/{subscription_id}/traffic`

Получение **актуального** трафика клиента с 3X-UI панели. Данные запрашиваются **в реальном времени** через API панели (`/panel/api/inbounds/getClientTraffics/{email}`).

**Параметры пути:**

| Параметр          | Тип       | Описание    |
| ----------------- | --------- | ----------- |
| `subscription_id` | `integer` | ID подписки |

**Ответ `200 OK`:**

```json
{
  "id": 1,
  "inboundId": 1,
  "enable": true,
  "email": "nt3wz904",
  "uuid": "b86c0cdc-8a02-4da4-8693-72ba27005587",
  "subId": "rqv5zw1ydutamcp0",
  "up": 52428800,
  "down": 1073741824,
  "allTime": 0,
  "expiryTime": 1738368000000,
  "total": 10737418240,
  "reset": 0,
  "lastOnline": 1737456000000
}
```

> **Примечание:** `up` и `down` — реальные счётчики трафика в байтах с момента последнего сброса.

---

#### `PATCH /api/v1/subscriptions/{subscription_id}`

Обновление подписки. **Двойное действие:**

1. Обновляется конфигурация клиента на 3X-UI (`/panel/api/inbounds/updateClient/{uuid}`)
2. Обновляется запись в нашей БД

**Тело запроса (все поля опциональны):**

| Поле          | Тип       | Описание                        |
| ------------- | --------- | ------------------------------- |
| `enable`      | `boolean` | Включить/выключить подписку     |
| `total_gb`    | `integer` | Новый лимит трафика (байты)     |
| `expiry_time` | `integer` | Новое время истечения (Unix ms) |
| `limit_ip`    | `integer` | Новый лимит IP                  |
| `tg_id`       | `string`  | Новый Telegram ID               |

**Пример — отключение подписки:**

```json
{
  "enable": false
}
```

**Пример — продление на месяц и добавление трафика:**

```json
{
  "total_gb": 21474836480,
  "expiry_time": 1740960000000
}
```

**Ответ `200 OK`:** обновлённый объект подписки

---

#### `DELETE /api/v1/subscriptions/{subscription_id}`

Удаление подписки. **Двойное действие:**

1. Удаляется клиент из инбаунда на 3X-UI (`/panel/api/inbounds/{id}/delClient/{uuid}`)
2. Удаляется запись из нашей БД

**Ответ `204 No Content`**

**Возможные ошибки:**

- `404` — подписка не найдена
- `502` — ошибка при удалении клиента на 3X-UI

---

## Сводная таблица всех эндпоинтов

| Метод    | Путь                                 | Описание                | Взаимодействие с 3X-UI |
| -------- | ------------------------------------ | ----------------------- | ---------------------- |
| `GET`    | `/health`                            | Health check            | ❌                     |
| `POST`   | `/api/v1/users/`                     | Создать пользователя    | ❌                     |
| `GET`    | `/api/v1/users/`                     | Список пользователей    | ❌                     |
| `GET`    | `/api/v1/users/{id}`                 | Получить пользователя   | ❌                     |
| `GET`    | `/api/v1/users/telegram/{tg_id}`     | Найти по Telegram ID    | ❌                     |
| `GET`    | `/api/v1/users/{id}/subscriptions`   | Пользователь + подписки | ❌                     |
| `PATCH`  | `/api/v1/users/{id}`                 | Обновить пользователя   | ❌                     |
| `DELETE` | `/api/v1/users/{id}`                 | Удалить пользователя    | ❌                     |
| `POST`   | `/api/v1/servers/`                   | Добавить сервер         | ❌                     |
| `GET`    | `/api/v1/servers/`                   | Список серверов         | ❌                     |
| `GET`    | `/api/v1/servers/{id}`               | Получить сервер         | ❌                     |
| `GET`    | `/api/v1/servers/{id}/status`        | Статус сервера          | ✅ GET status          |
| `PATCH`  | `/api/v1/servers/{id}`               | Обновить сервер         | ❌                     |
| `DELETE` | `/api/v1/servers/{id}`               | Удалить сервер          | ❌                     |
| `POST`   | `/api/v1/inbounds/`                  | Создать инбаунд         | ✅ POST add            |
| `GET`    | `/api/v1/inbounds/`                  | Список инбаундов        | ❌                     |
| `GET`    | `/api/v1/inbounds/{id}`              | Получить инбаунд        | ❌                     |
| `PATCH`  | `/api/v1/inbounds/{id}`              | Обновить инбаунд        | ✅ POST update         |
| `DELETE` | `/api/v1/inbounds/{id}`              | Удалить инбаунд         | ✅ POST del            |
| `POST`   | `/api/v1/inbounds/sync/{server_id}`  | Синхронизация с 3X-UI   | ✅ GET list            |
| `POST`   | `/api/v1/subscriptions/`             | Создать подписку        | ✅ POST addClient      |
| `GET`    | `/api/v1/subscriptions/`             | Список подписок         | ❌                     |
| `GET`    | `/api/v1/subscriptions/{id}`         | Получить подписку       | ❌                     |
| `GET`    | `/api/v1/subscriptions/{id}/traffic` | Трафик подписки         | ✅ GET clientTraffics  |
| `PATCH`  | `/api/v1/subscriptions/{id}`         | Обновить подписку       | ✅ POST updateClient   |
| `DELETE` | `/api/v1/subscriptions/{id}`         | Удалить подписку        | ✅ POST delClient      |
