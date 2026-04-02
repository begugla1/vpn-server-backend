from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from typing import List, Optional

from app.database import get_session
from app.schemas.subscription import (
    SubscriptionCreate,
    SubscriptionCreateWithAnyAvailableServer,
    SubscriptionCreateWithAnyAvailableServerResponse,
    SubscriptionUpdate,
    SubscriptionResponse,
)
from app.services.subscription_service import SubscriptionService

router = APIRouter(prefix="/subscriptions", tags=["Subscriptions"])


@router.post("/", response_model=SubscriptionResponse, status_code=201)
async def create_subscription(
    data: SubscriptionCreate,
    session: AsyncSession = Depends(get_session),
):
    """
    Создать п��дписку (subscription link):
    1. Добавляет клиента в инбаунд на 3X-UI панели
    2. Генерирует subscription URL
    3. Сохраняет всё в нашу БД
    """
    service = SubscriptionService(session)
    return await service.create_subscription(data)


@router.post(
    "/auto",
    response_model=SubscriptionCreateWithAnyAvailableServerResponse,
    status_code=201,
)
async def create_subscription_with_any_available_server(
    data: SubscriptionCreateWithAnyAvailableServer,
    session: AsyncSession = Depends(get_session),
):
    """
    Создать подписку на любом активном сервере с доступным inbound.

    Если свободных по лимиту серверов нет, используется soft-limit:
    выбирается наименее загруженный активный сервер и в ответе
    возвращается warning.
    """
    service = SubscriptionService(session)
    return await service.create_subscription_with_any_available_server(data)


@router.get("/", response_model=List[SubscriptionResponse])
async def list_subscriptions(
    user_id: Optional[int] = Query(None, description="Фильтр по пользователю"),
    server_id: Optional[int] = Query(None, description="Фильтр по серверу"),
    telegram_id: Optional[int] = Query(None, description="Фильтр по Telegram ID"),
    session: AsyncSession = Depends(get_session),
):
    """Получить список подписок с фильтрацией."""
    service = SubscriptionService(session)
    return await service.list_subscriptions(
        user_id=user_id,
        server_id=server_id,
        telegram_id=telegram_id,
    )


@router.get("/{subscription_id}", response_model=SubscriptionResponse)
async def get_subscription(
    subscription_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Получить подписку по ID."""
    service = SubscriptionService(session)
    return await service.get_subscription(subscription_id)


@router.get("/{subscription_id}/traffic")
async def get_subscription_traffic(
    subscription_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Получить трафик подписки из 3X-UI панели."""
    service = SubscriptionService(session)
    return await service.get_client_traffic(subscription_id)


@router.patch("/{subscription_id}", response_model=SubscriptionResponse)
async def update_subscription(
    subscription_id: int,
    data: SubscriptionUpdate,
    session: AsyncSession = Depends(get_session),
):
    """
    Обновить подписку:
    - enable/disable
    - лимиты трафика
    - срок действия
    Обновляет и на 3X-UI, и в нашей БД.
    """
    service = SubscriptionService(session)
    return await service.update_subscription(subscription_id, data)


@router.delete("/{subscription_id}", status_code=204)
async def delete_subscription(
    subscription_id: int,
    session: AsyncSession = Depends(get_session),
):
    """
    Удалить подписку:
    Удаляет клиента из 3X-UI и запись из нашей БД.
    """
    service = SubscriptionService(session)
    await service.delete_subscription(subscription_id)
