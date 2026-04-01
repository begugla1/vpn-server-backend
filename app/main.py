from contextlib import asynccontextmanager
from fastapi import FastAPI

from app.database import init_db
from app.routers import users, servers, inbounds, subscriptions


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Startup: создаём таблицы
    await init_db()
    yield
    # Shutdown: cleanup если нужно


app = FastAPI(
    title="VPN Backend — 3X-UI Manager",
    description=(
        "Backend для управления серверами с 3X-UI панелями. "
        "Поддержка нескольких серверов, создание инбаундов, "
        "управление подписками пользователей."
    ),
    version="0.1.0",
    lifespan=lifespan,
)

# Подключаем роуты
app.include_router(users.router, prefix="/api/v1")
app.include_router(servers.router, prefix="/api/v1")
app.include_router(inbounds.router, prefix="/api/v1")
app.include_router(subscriptions.router, prefix="/api/v1")


@app.get("/health", tags=["Health"])
async def health_check():
    return {"status": "ok"}
