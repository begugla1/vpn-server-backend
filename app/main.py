from contextlib import asynccontextmanager
from fastapi import Depends, FastAPI
from fastapi.openapi.docs import get_redoc_html, get_swagger_ui_html
from fastapi.openapi.utils import get_openapi
from fastapi.responses import JSONResponse

from app.dependencies import require_api_token
from app.routers import users, servers, inbounds, subscriptions


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Здесь больше не создаём таблицы автоматически.
    # Схема БД управляется через Alembic миграции.
    yield


app = FastAPI(
    title="VPN Backend — 3X-UI Manager",
    description=(
        "Backend для управления серверами с 3X-UI панелями. "
        "Поддержка нескольких серверов, создание инбаундов, "
        "управление подписками пользователей."
    ),
    version="0.1.0",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

protected_api_dependencies = [Depends(require_api_token)]

app.include_router(
    users.router,
    prefix="/api/v1",
    dependencies=protected_api_dependencies,
)
app.include_router(
    servers.router,
    prefix="/api/v1",
    dependencies=protected_api_dependencies,
)
app.include_router(
    inbounds.router,
    prefix="/api/v1",
    dependencies=protected_api_dependencies,
)
app.include_router(
    subscriptions.router,
    prefix="/api/v1",
    dependencies=protected_api_dependencies,
)


@app.get("/health", tags=["Health"], dependencies=protected_api_dependencies)
async def health_check():
    return {"status": "ok"}


@app.get("/openapi.json", include_in_schema=False, dependencies=protected_api_dependencies)
async def openapi_schema():
    return JSONResponse(
        get_openapi(
            title=app.title,
            version=app.version,
            description=app.description,
            routes=app.routes,
        )
    )


@app.get("/docs", include_in_schema=False, dependencies=protected_api_dependencies)
async def swagger_ui():
    return get_swagger_ui_html(
        openapi_url="/openapi.json",
        title=f"{app.title} - Swagger UI",
    )


@app.get("/redoc", include_in_schema=False, dependencies=protected_api_dependencies)
async def redoc_ui():
    return get_redoc_html(
        openapi_url="/openapi.json",
        title=f"{app.title} - ReDoc",
    )
