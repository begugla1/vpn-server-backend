from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from typing import List

from app.database import get_session
from app.schemas.server import ServerCreate, ServerUpdate, ServerResponse, ServerStatus
from app.services.server_service import ServerService

router = APIRouter(prefix="/servers", tags=["Servers"])


@router.post("/", response_model=ServerResponse, status_code=201)
async def create_server(
    data: ServerCreate,
    session: AsyncSession = Depends(get_session),
):
    """Добавить новый сервер с 3X-UI панелью."""
    service = ServerService(session)
    return await service.create_server(data)


@router.get("/", response_model=List[ServerResponse])
async def list_servers(
    session: AsyncSession = Depends(get_session),
):
    """Получить список всех серверов."""
    service = ServerService(session)
    return await service.list_servers()


@router.get("/{server_id}", response_model=ServerResponse)
async def get_server(
    server_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Получить сервер по ID."""
    service = ServerService(session)
    return await service.get_server(server_id)


@router.get("/{server_id}/status", response_model=ServerStatus)
async def get_server_status(
    server_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Получить статус сервера из 3X-UI панели (CPU, RAM, Xray state и т.д.)."""
    service = ServerService(session)
    return await service.get_server_status(server_id)


@router.patch("/{server_id}", response_model=ServerResponse)
async def update_server(
    server_id: int,
    data: ServerUpdate,
    session: AsyncSession = Depends(get_session),
):
    """Обновить настройки сервера."""
    service = ServerService(session)
    return await service.update_server(server_id, data)


@router.delete("/{server_id}", status_code=204)
async def delete_server(
    server_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Удалить сервер и все связанные данные."""
    service = ServerService(session)
    await service.delete_server(server_id)
