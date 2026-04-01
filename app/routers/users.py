from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from typing import List

from app.database import get_session
from app.schemas.user import UserCreate, UserUpdate, UserResponse, UserWithSubscriptions
from app.services.user_service import UserService

router = APIRouter(prefix="/users", tags=["Users"])


@router.post("/", response_model=UserResponse, status_code=201)
async def create_user(
    data: UserCreate,
    session: AsyncSession = Depends(get_session),
):
    """Создать пользователя (или вернуть существующего по telegram_id)."""
    service = UserService(session)
    return await service.create_user(data)


@router.get("/", response_model=List[UserResponse])
async def list_users(
    session: AsyncSession = Depends(get_session),
):
    """Получить список всех пользователей."""
    service = UserService(session)
    return await service.list_users()


@router.get("/{user_id}", response_model=UserResponse)
async def get_user(
    user_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Получить пользователя по ID."""
    service = UserService(session)
    return await service.get_user(user_id)


@router.get("/telegram/{telegram_id}", response_model=UserResponse)
async def get_user_by_telegram_id(
    telegram_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Получить пользователя по Telegram ID."""
    service = UserService(session)
    user = await service.get_by_telegram_id(telegram_id)
    if not user:
        from app.exceptions import NotFoundException

        raise NotFoundException("User", f"telegram_id={telegram_id}")
    return user


@router.get("/{user_id}/subscriptions", response_model=UserWithSubscriptions)
async def get_user_with_subscriptions(
    user_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Получить пользователя со всеми подписками."""
    service = UserService(session)
    return await service.get_user_with_subscriptions(user_id)


@router.patch("/{user_id}", response_model=UserResponse)
async def update_user(
    user_id: int,
    data: UserUpdate,
    session: AsyncSession = Depends(get_session),
):
    """Обновить данные пользователя."""
    service = UserService(session)
    return await service.update_user(user_id, data)


@router.delete("/{user_id}", status_code=204)
async def delete_user(
    user_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Удалить пользователя и все его подписки."""
    service = UserService(session)
    await service.delete_user(user_id)
