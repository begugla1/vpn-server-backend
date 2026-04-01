from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from typing import List, Optional

from app.database import get_session
from app.schemas.inbound import InboundCreate, InboundUpdate, InboundResponse
from app.services.inbound_service import InboundService

router = APIRouter(prefix="/inbounds", tags=["Inbounds"])


@router.post("/", response_model=InboundResponse, status_code=201)
async def create_inbound(
    data: InboundCreate,
    session: AsyncSession = Depends(get_session),
):
    """
    Создать новый инбаунд на сервере.
    Создаёт инбаунд в 3X-UI п��нели и сохраняет запись в нашей БД.
    """
    service = InboundService(session)
    return await service.create_inbound(data)


@router.get("/", response_model=List[InboundResponse])
async def list_inbounds(
    server_id: Optional[int] = Query(None, description="Фильтр по серверу"),
    session: AsyncSession = Depends(get_session),
):
    """Получить список инбаундов (опционально фильтрация по серверу)."""
    service = InboundService(session)
    return await service.list_inbounds(server_id=server_id)


@router.get("/{inbound_id}", response_model=InboundResponse)
async def get_inbound(
    inbound_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Получить инбаунд по ID."""
    service = InboundService(session)
    return await service.get_inbound(inbound_id)


@router.patch("/{inbound_id}", response_model=InboundResponse)
async def update_inbound(
    inbound_id: int,
    data: InboundUpdate,
    session: AsyncSession = Depends(get_session),
):
    """
    Обновить инбаунд.
    Обновляет конфигурацию и на 3X-UI панели, и в нашей БД.
    """
    service = InboundService(session)
    return await service.update_inbound(inbound_id, data)


@router.delete("/{inbound_id}", status_code=204)
async def delete_inbound(
    inbound_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Удалить инбаунд из 3X-UI и из нашей БД."""
    service = InboundService(session)
    await service.delete_inbound(inbound_id)


@router.post("/sync/{server_id}", response_model=List[InboundResponse])
async def sync_inbounds(
    server_id: int,
    session: AsyncSession = Depends(get_session),
):
    """
    Синхронизировать инбаунды с 3X-UI панели сервера в нашу БД.
    Полезно при первоначальной настройке или для обновления данных.
    """
    service = InboundService(session)
    return await service.sync_inbounds_from_xui(server_id)
