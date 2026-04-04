# ✅ 1. Самое важное — не допускать зависших процессов

Перед любыми рестартами:

```bash
systemctl stop x-ui
pkill -9 -f /usr/local/x-ui/x-ui
pkill -9 -f xray
```

👉 Если одновременно работают 2 процесса x-ui → SQLite сразу ловит `database is locked`.

Проверь:

```bash
pgrep -a x-ui
pgrep -a xray
```

---

## ✅ 2. Убрать lock-файлы (если проблема уже была)

```bash
rm -f /usr/local/x-ui/x-ui.db-wal /usr/local/x-ui/x-ui.db-shm
```

⚠️ Только при остановленном сервисе.

---

## ✅ 3. Включить WAL-режим (очень важно)

Это снижает блокировки SQLite:

```bash
sqlite3 /usr/local/x-ui/x-ui.db "PRAGMA journal_mode=WAL;"
```

Проверка:

```bash
sqlite3 /usr/local/x-ui/x-ui.db "PRAGMA journal_mode;"
```

Должно быть:

```text
wal
```

---

## ✅ 4. Проверить диск (частая причина)

```bash
df -h
df -i
```

Если:

* диск почти полный
* или inode закончились

→ SQLite начинает "залипать".

---

## ✅ 5. Отключить лишние логи Xray (очень влияет)

В конфиге xray (`config.json`) поставь:

```json
"log": {
  "access": "none",
  "error": ""
}
```

👉 Это реально снижает вероятность `database is locked` (официальная рекомендация для 3x-ui).

---

## ✅ 6. Исправить systemd, чтобы не было гонок

Открой:

```bash
nano /etc/systemd/system/x-ui.service
```

И сделай так:

```ini
[Unit]
Description=X-UI Service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/x-ui/x-ui
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Потом:

```bash
systemctl daemon-reload
```

👉 Это уменьшает "шторм рестартов", который и вызывает lock.

---

## ✅ 7. (Если повторится) — почистить конфликтный индекс

```bash
sqlite3 /usr/local/x-ui/x-ui.db "DROP INDEX IF EXISTS idx_enable_traffic_reset;"
```

---

## 🔥 Самый частый корень проблемы

Из практики:

1. Обновили x-ui
2. Миграция БД частично прошла
3. Сервис начал перезапускаться
4. Появился lock
5. Дальше цикл ошибок

---

## ⚡ Мини-чеклист (сохрани себе)

Если снова увидишь `database is locked`:

```bash
systemctl stop x-ui
pkill -9 -f x-ui
pkill -9 -f xray
rm -f /usr/local/x-ui/x-ui.db-wal /usr/local/x-ui/x-ui.db-shm
sqlite3 /usr/local/x-ui/x-ui.db "DROP INDEX IF EXISTS idx_enable_traffic_reset;"
systemctl start x-ui
```
