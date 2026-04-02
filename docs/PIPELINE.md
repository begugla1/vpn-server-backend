# VPN Backend Pipeline Docs

## 1. Overview

This document describes the current backend pipeline end-to-end:

- how requests are authenticated
- which endpoints exist and what each one actually does
- which service methods and side effects are involved
- how the local PostgreSQL schema is organized
- what business rules are enforced in code right now

Project type:

- FastAPI backend
- async SQLAlchemy ORM
- PostgreSQL via `asyncpg`
- external panel integration via 3X-UI HTTP API

Core purpose:

- store users
- register VPN servers
- store and sync inbounds from 3X-UI
- create and manage one active subscription per user

---

## 2. Security Model

### 2.1 API token

All backend routes are protected by a shared backend token.

Accepted headers:

- `Authorization: Bearer <BACKEND_API_TOKEN>`
- `X-API-Token: <BACKEND_API_TOKEN>`

Token source:

- `.env`
- setting name: `BACKEND_API_TOKEN`

Protected routes:

- all `/api/v1/*`
- `/health`
- `/openapi.json`
- `/docs`
- `/redoc`

Authentication dependency:

- `app/dependencies/auth.py`
- function: `require_api_token`

If token is missing or invalid:

- HTTP `401 Unauthorized`
- response body:

```json
{
  "detail": "Invalid or missing API token"
}
```

### 2.2 3X-UI connectivity

The backend talks to 3X-UI only through `XUIClient`.

Current rules:

- server record must use `use_https=true`
- backend intentionally rejects plain HTTP
- TLS certificate verification is disabled with `verify=False`
- this is intentional for self-signed panel certificates

3X-UI client file:

- `app/services/xui_client.py`

---

## 3. Runtime Pipeline

### 3.1 Request pipeline

For a typical protected request the flow is:

1. FastAPI route receives the HTTP request.
2. `require_api_token` validates `Authorization` or `X-API-Token`.
3. `get_session()` creates an async SQLAlchemy session.
4. Router delegates to a service class.
5. Service reads or mutates local DB state.
6. If needed, service calls `XUIClient` and changes state in 3X-UI.
7. DB transaction is committed.
8. ORM object is returned and serialized by Pydantic response schema.

### 3.2 Main layers

Routers:

- translate HTTP into service calls
- define status codes and response models

Services:

- contain business rules
- validate relationships
- decide when to call 3X-UI
- commit DB changes

Models:

- SQLAlchemy table definitions

Schemas:

- request and response contracts for FastAPI

Exceptions:

- unify HTTP errors for not found, 3X-UI failures, and business validation

---

## 4. System Endpoints

Base business prefix:

- `/api/v1`

System endpoints live at root level and are also token-protected.

### 4.1 `GET /health`

Purpose:

- simple liveness check

Auth:

- required

Behavior:

- returns static JSON
- does not touch DB
- does not call 3X-UI

Response:

```json
{
  "status": "ok"
}
```

### 4.2 `GET /openapi.json`

Purpose:

- returns OpenAPI schema

Auth:

- required

Behavior:

- schema is generated dynamically from `app.routes`

### 4.3 `GET /docs`

Purpose:

- Swagger UI page

Auth:

- required

Note:

- because the page itself is protected, browser usage requires a header-injection extension or another tool that can attach the token

### 4.4 `GET /redoc`

Purpose:

- ReDoc page

Auth:

- required

---

## 5. Users API

Router:

- `app/routers/users.py`

Service:

- `app/services/user_service.py`

### 5.1 `POST /api/v1/users/`

Request model:

- `UserCreate`

Fields:

- `telegram_id: int`
- `username: str | null`
- `first_name: str | null`
- `last_name: str | null`

Response model:

- `UserResponse`

Actual logic:

1. Search user by `telegram_id`.
2. If found, return existing record.
3. If not found, create a new `users` row.
4. Commit and refresh ORM object.

Important behavior:

- operation is idempotent by `telegram_id`
- route always returns status `201`, even when existing user is returned

### 5.2 `GET /api/v1/users/`

Response model:

- `list[UserResponse]`

Actual logic:

- returns all users ordered by `created_at DESC`

### 5.3 `GET /api/v1/users/{user_id}`

Response model:

- `UserResponse`

Actual logic:

- `session.get(User, user_id)`
- if missing: `404`

### 5.4 `GET /api/v1/users/telegram/{telegram_id}`

Response model:

- `UserResponse`

Actual logic:

- finds one user by `telegram_id`
- if missing: `404`

### 5.5 `GET /api/v1/users/{user_id}/subscriptions`

Response model:

- `UserWithSubscriptions`

Actual logic:

- loads user with `selectinload(User.subscriptions)`
- if missing: `404`

Note:

- this returns local DB subscriptions only
- no fresh 3X-UI sync happens here

### 5.6 `PATCH /api/v1/users/{user_id}`

Request model:

- `UserUpdate`

Fields:

- `username`
- `first_name`
- `last_name`

Actual logic:

- partial update
- commits only provided fields

### 5.7 `DELETE /api/v1/users/{user_id}`

Actual logic:

- deletes user row
- related subscriptions are deleted by ORM cascade and FK cascade

Response:

- HTTP `204 No Content`

---

## 6. Servers API

Router:

- `app/routers/servers.py`

Service:

- `app/services/server_service.py`

### 6.1 `POST /api/v1/servers/`

Request model:

- `ServerCreate`

Fields:

- `name`
- `ip_address`
- `panel_port`
- `panel_username`
- `panel_password`
- `web_base_path`
- `use_https`
- `subscription_port`
- `subscription_base_path`
- `open_ports`
- `configuration`
- `max_subscriptions`

Actual logic:

1. Create local `servers` row.
2. Commit and refresh.

Notes:

- this endpoint does not validate connectivity to the panel
- `panel_password` is stored in DB but not exposed in response
- default `use_https=true`

### 6.2 `GET /api/v1/servers/`

Response model:

- `list[ServerResponse]`

Actual logic:

- returns all servers ordered by `created_at DESC`

### 6.3 `GET /api/v1/servers/{server_id}`

Response model:

- `ServerResponse`

Actual logic:

- fetch by PK
- if missing: `404`

### 6.4 `GET /api/v1/servers/{server_id}/status`

Response model:

- `ServerStatus`

Actual logic:

1. Load server from DB.
2. Create `XUIClient(server)`.
3. Call 3X-UI endpoint `/panel/api/server/status`.
4. Map result into `ServerStatus`.

Success payload includes:

- `cpu`
- `mem_current`
- `mem_total`
- `disk_current`
- `disk_total`
- `xray_state`
- `xray_version`
- `uptime`

Failure behavior:

- most runtime failures return `is_reachable=false`
- if server record itself is invalid before entering the `try` block, an exception can still propagate

### 6.5 `PATCH /api/v1/servers/{server_id}`

Request model:

- `ServerUpdate`

Actual logic:

- partial update of any provided server fields
- commits and refreshes

### 6.6 `DELETE /api/v1/servers/{server_id}`

Actual logic:

- deletes server row
- related inbounds and subscriptions are deleted by cascade

Response:

- HTTP `204 No Content`

---

## 7. Inbounds API

Router:

- `app/routers/inbounds.py`

Service:

- `app/services/inbound_service.py`

### 7.1 `POST /api/v1/inbounds/`

Request model:

- `InboundCreate`

Fields:

- `server_id`
- `remark`
- `port`
- `protocol`
- `settings`
- `stream_settings`
- `sniffing`
- `enable`
- `total`
- `expiry_time`

Actual logic:

1. Load server from DB.
2. Create `XUIClient(server)`.
3. Build XUI inbound payload.
4. Call `POST /panel/api/inbounds/add`.
5. Save local `inbounds` row.
6. Commit and refresh.

Default generation behavior:

- if `settings` are provided, they are used as-is
- if `settings` are missing, backend generates a default inbound only for `protocol=vless`
- if `settings` are missing and `protocol != "vless"`, request is rejected with `400`

Generated defaults:

- empty `clients: []`
- default TCP stream settings
- default sniffing settings

Local mirror behavior:

- request field `expiry_time` is sent to 3X-UI
- local `inbounds` row stores `expiry_time`
- local DB mirrors `up`, `down`, `total`, and `expiry_time`

### 7.2 `GET /api/v1/inbounds/`

Query params:

- `server_id` optional

Response model:

- `list[InboundResponse]`

Actual logic:

- if `server_id` is provided, filters by server
- sorts by `created_at DESC`

### 7.3 `GET /api/v1/inbounds/{inbound_id}`

Response model:

- `InboundResponse`

Actual logic:

- fetch by PK
- if missing: `404`

### 7.4 `PATCH /api/v1/inbounds/{inbound_id}`

Request model:

- `InboundUpdate`

Fields:

- `remark`
- `port`
- `enable`
- `settings`
- `stream_settings`
- `sniffing`
- `total`
- `expiry_time`

Actual logic:

1. Load local inbound.
2. Load owning server.
3. Read current inbound from 3X-UI.
4. Merge only provided fields into remote object.
5. Push updated object to 3X-UI.
6. Apply same fields to local DB row.
7. Commit and refresh.

### 7.5 `DELETE /api/v1/inbounds/{inbound_id}`

Actual logic:

1. Delete inbound from 3X-UI.
2. Delete local DB row.
3. Commit.

Response:

- HTTP `204 No Content`

### 7.6 `POST /api/v1/inbounds/sync/{server_id}`

Response model:

- `list[InboundResponse]`

Actual logic:

1. Read all inbounds from 3X-UI.
2. For each panel inbound:
   - if local row exists by `(server_id, xui_inbound_id)`, update it
   - otherwise insert a new local row
3. Commit.

Sync behavior:

- `settings`, `streamSettings`, and `sniffing` are parsed from JSON strings when needed
- `up`, `down`, `total`, and `expiryTime` are mirrored from panel
- removed panel inbounds are not deleted from local DB by this method

---

## 8. Subscriptions API

Router:

- `app/routers/subscriptions.py`

Service:

- `app/services/subscription_service.py`

### 8.1 Current subscription business rules

These rules are enforced now:

- one user can have only one subscription in the entire system
- this is enforced twice:
  - in service logic before creation
  - by DB unique constraint `uq_subscriptions_user_id`
- subscription must belong to:
  - existing user
  - existing server
  - existing inbound
- manual creation requires that inbound belongs to the same server
- server must be active
- inbound must be enabled

### 8.2 `POST /api/v1/subscriptions/`

Request model:

- `SubscriptionCreate`

Fields:

- `user_id`
- `server_id`
- `inbound_id`
- `client_email`
- `total_gb`
- `expiry_time`
- `limit_ip`
- `enable`
- `tg_id`
- `flow`

Actual logic:

1. Load user, server, and inbound.
2. Reject if user already has a subscription.
3. Reject if inbound does not belong to server.
4. Reject if server is inactive or inbound is disabled.
5. Generate:
   - `client_uuid`
   - `client_email` if absent
   - `sub_id`
6. Build client config for 3X-UI.
7. Add client to remote inbound via 3X-UI.
8. Build `subscription_url`.
9. Save local `subscriptions` row.
10. Commit and refresh.

Rollback behavior:

- if DB commit fails after remote client creation, backend tries to delete the newly created client from 3X-UI

### 8.3 `POST /api/v1/subscriptions/auto`

Request model:

- `SubscriptionCreateWithAnyAvailableServer`

Fields:

- `user_id`
- `client_email`
- `total_gb`
- `expiry_time`
- `limit_ip`
- `enable`
- `tg_id`
- `flow`

Response model:

- `SubscriptionCreateWithAnyAvailableServerResponse`

Response fields:

- `subscription`
- `warning`

Actual logic:

1. Load user.
2. Reject if user already has a subscription.
3. Query all active servers with eager-loaded inbounds and subscriptions.
4. For each server:
   - pick the first enabled inbound ordered by inbound id
   - count current subscriptions on that server
5. Choose target server:
   - first priority: server with free capacity `count < max_subscriptions`
   - fallback: least loaded active server even if full
6. Create subscription on selected server.
7. Return created subscription.
8. If soft-limit path was used, also return `warning`.

Soft-limit rule:

- if every active server is already full, backend still creates the subscription on the least loaded active server with an enabled inbound
- returned warning text indicates overflow

Failure cases:

- `409` if user already has a subscription
- `503` if there is no active server with at least one enabled inbound

### 8.4 `GET /api/v1/subscriptions/`

Query params:

- `user_id` optional
- `server_id` optional
- `telegram_id` optional

Response model:

- `list[SubscriptionResponse]`

Actual logic:

- base query: all subscriptions
- optional filters:
  - by `user_id`
  - by `server_id`
  - by joined `users.telegram_id`
- sorted by `created_at DESC`

### 8.5 `GET /api/v1/subscriptions/{subscription_id}`

Response model:

- `SubscriptionResponse`

Actual logic:

- fetch by PK
- if missing: `404`

### 8.6 `GET /api/v1/subscriptions/{subscription_id}/traffic`

Purpose:

- fetch current client traffic from 3X-UI

Actual logic:

1. Load local subscription.
2. Load owning server.
3. Call 3X-UI by `client_email`.

Returned data:

- raw object from 3X-UI API
- not wrapped in a dedicated response schema

### 8.7 `PATCH /api/v1/subscriptions/{subscription_id}`

Request model:

- `SubscriptionUpdate`

Fields:

- `enable`
- `total_gb`
- `expiry_time`
- `limit_ip`
- `tg_id`

Actual logic:

1. Load local subscription, server, and inbound.
2. Start from saved `client_config`.
3. Merge provided fields into client config.
4. Push updated client to 3X-UI.
5. Mirror selected fields into local subscription row.
6. Commit and refresh.

Note:

- local DB persists `enable`, `total_gb`, and `expiry_time`
- `limit_ip` and `tg_id` are only kept inside `client_config`, not in separate DB columns

### 8.8 `DELETE /api/v1/subscriptions/{subscription_id}`

Actual logic:

1. Load local subscription, server, and inbound.
2. Delete remote client from 3X-UI.
3. Delete local subscription row.
4. Commit.

Response:

- HTTP `204 No Content`

---

## 9. Database Schema

## 9.1 Relationships

Logical relations:

- one `user` -> many `subscriptions`
- one `server` -> many `inbounds`
- one `server` -> many `subscriptions`
- one `inbound` -> many `subscriptions`

Delete cascades:

- deleting a user deletes related subscriptions
- deleting a server deletes related inbounds and subscriptions
- deleting an inbound deletes related subscriptions

### 9.2 Table `users`

Purpose:

- Telegram-based identity registry

Columns:

| Column | Type | Null | Default | Constraints / Notes |
| --- | --- | --- | --- | --- |
| `id` | `INTEGER` | no | auto | primary key |
| `telegram_id` | `BIGINT` | no | - | unique, indexed |
| `username` | `VARCHAR(255)` | yes | `NULL` | Telegram username |
| `first_name` | `VARCHAR(255)` | yes | `NULL` | first name |
| `last_name` | `VARCHAR(255)` | yes | `NULL` | last name |
| `created_at` | `TIMESTAMP WITH TIME ZONE` | no | `now()` | row creation time |
| `updated_at` | `TIMESTAMP WITH TIME ZONE` | no | `now()` | auto-updated timestamp |

### 9.3 Table `servers`

Purpose:

- stores 3X-UI connection parameters and local server metadata

Columns:

| Column | Type | Null | Default | Constraints / Notes |
| --- | --- | --- | --- | --- |
| `id` | `INTEGER` | no | auto | primary key |
| `name` | `VARCHAR(255)` | no | - | human-readable server name |
| `ip_address` | `VARCHAR(45)` | no | - | unique, IPv4/IPv6 compatible |
| `panel_port` | `INTEGER` | no | `65000` | 3X-UI panel port |
| `panel_username` | `VARCHAR(255)` | no | `admin` | stored in DB |
| `panel_password` | `VARCHAR(255)` | no | `admin` | stored in DB, never returned by API |
| `web_base_path` | `VARCHAR(255)` | no | `/` | panel path prefix |
| `use_https` | `BOOLEAN` | no | `true` | backend rejects plain HTTP |
| `subscription_port` | `INTEGER` | no | `2096` | subscription endpoint port |
| `subscription_base_path` | `VARCHAR(255)` | no | `/sub/` | subscription path prefix |
| `open_ports` | `JSON` | yes | `{}` / `NULL` | custom metadata |
| `configuration` | `JSON` | yes | `{}` / `NULL` | custom metadata |
| `max_subscriptions` | `INTEGER` | no | env default | server capacity limit |
| `is_active` | `BOOLEAN` | no | `true` | used by auto-allocation |
| `created_at` | `TIMESTAMP WITH TIME ZONE` | no | `now()` | row creation time |
| `updated_at` | `TIMESTAMP WITH TIME ZONE` | no | `now()` | auto-updated timestamp |

Important notes:

- unique server identity in local DB is `ip_address`
- auto-allocation logic reads `max_subscriptions`

### 9.4 Table `inbounds`

Purpose:

- local mirror of inbounds configured in 3X-UI

Columns:

| Column | Type | Null | Default | Constraints / Notes |
| --- | --- | --- | --- | --- |
| `id` | `INTEGER` | no | auto | primary key |
| `server_id` | `INTEGER` | no | - | FK -> `servers.id`, indexed |
| `xui_inbound_id` | `INTEGER` | no | - | inbound id in 3X-UI |
| `remark` | `VARCHAR(255)` | no | `""` | label |
| `protocol` | `VARCHAR(50)` | no | - | `vless`, `vmess`, `trojan`, `shadowsocks` |
| `port` | `INTEGER` | no | - | listening port |
| `settings` | `JSON` | yes | `NULL` | main inbound settings |
| `stream_settings` | `JSON` | yes | `NULL` | stream settings |
| `sniffing` | `JSON` | yes | `NULL` | sniffing settings |
| `enable` | `BOOLEAN` | no | `true` | local enabled flag |
| `up` | `BIGINT` | no | `0` | uploaded bytes |
| `down` | `BIGINT` | no | `0` | downloaded bytes |
| `total` | `BIGINT` | no | `0` | traffic limit in bytes |
| `expiry_time` | `BIGINT` | no | `0` | Unix timestamp in ms |
| `created_at` | `TIMESTAMP WITH TIME ZONE` | no | `now()` | row creation time |
| `updated_at` | `TIMESTAMP WITH TIME ZONE` | no | `now()` | auto-updated timestamp |

Important notes:

- unique `(server_id, xui_inbound_id)` is enforced by DB constraint `uq_inbounds_server_id_xui_inbound_id`
- local row mirrors panel traffic fields and `expiry_time`

### 9.5 Table `subscriptions`

Purpose:

- binds a user to one concrete client entry inside one concrete inbound on one server

Columns:

| Column | Type | Null | Default | Constraints / Notes |
| --- | --- | --- | --- | --- |
| `id` | `INTEGER` | no | auto | primary key |
| `user_id` | `INTEGER` | no | - | FK -> `users.id`, indexed |
| `server_id` | `INTEGER` | no | - | FK -> `servers.id`, indexed |
| `inbound_id` | `INTEGER` | no | - | FK -> `inbounds.id`, indexed |
| `client_uuid` | `VARCHAR(255)` | no | - | remote client UUID / password |
| `client_email` | `VARCHAR(255)` | no | - | unique globally |
| `sub_id` | `VARCHAR(255)` | no | - | subscription identifier |
| `subscription_url` | `VARCHAR(1024)` | no | - | final client URL |
| `client_config` | `JSON` | yes | `NULL` | stored XUI client config |
| `enable` | `BOOLEAN` | no | `true` | local subscription state |
| `total_gb` | `BIGINT` | no | `0` | traffic limit in bytes |
| `expiry_time` | `BIGINT` | no | `0` | Unix timestamp in ms |
| `created_at` | `TIMESTAMP WITH TIME ZONE` | no | `now()` | row creation time |
| `updated_at` | `TIMESTAMP WITH TIME ZONE` | no | `now()` | auto-updated timestamp |

Constraints:

- FK `user_id -> users.id`
- FK `server_id -> servers.id`
- FK `inbound_id -> inbounds.id`
- unique `client_email`
- unique `user_id` via `uq_subscriptions_user_id`

Important notes:

- the current system allows only one subscription per user globally
- `client_email` must also stay globally unique
- `limit_ip` and `tg_id` live inside `client_config`, not as standalone columns

---

## 10. Migration State

Current Alembic revisions in repository:

1. `ddb25d56b42b` - initial schema
2. `5272b505389d` - converts inbound traffic counters to `BigInteger`
3. `1c93f4c57f4f` - adds `servers.max_subscriptions` and unique subscription-per-user rule
4. `7c8d1f7f2c1a` - adds `inbounds.expiry_time` and unique `(server_id, xui_inbound_id)` rule

Deployment note:

- before running new backend code, database should be migrated with `alembic upgrade head`

---

## 11. Error Model

Common exception classes:

- `AppException` -> generic business error, default `400`
- `NotFoundException` -> `404`
- `XUIConnectionError` -> `502`
- `XUIApiError` -> `502`

Standard error format:

```json
{
  "detail": "..."
}
```

Typical status codes:

- `200` success
- `201` created
- `204` deleted/no content
- `400` invalid business input
- `401` token missing or invalid
- `404` resource not found
- `409` business conflict, such as duplicate subscription
- `502` failure talking to 3X-UI
- `503` no available active server for auto-allocation

---

## 12. Current Caveats

These are important implementation details to keep in mind:

- `POST /api/v1/users/` returns `201` even when existing user is returned instead of a new one.
- `GET /api/v1/subscriptions/{subscription_id}/traffic` returns raw 3X-UI payload, not a stable local schema.
- inbound sync updates and inserts rows, but does not remove local inbounds that were deleted on panel side.
- browser access to `/docs` requires attaching the token header to the page request and to the OpenAPI request.

---

## 13. Recommended Reading Order for Developers

If you are onboarding into this backend, the fastest way to understand it is:

1. `app/main.py`
2. `app/dependencies/auth.py`
3. all files in `app/routers/`
4. all files in `app/services/`
5. all files in `app/models/`
6. Alembic migrations

This order mirrors the actual runtime path of a request.
