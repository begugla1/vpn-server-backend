from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload
from typing import Optional, List

from app.models.user import User
from app.schemas.user import UserCreate, UserUpdate
from app.exceptions import NotFoundException


class UserService:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def create_user(self, data: UserCreate) -> User:
        # Проверяем, нет ли уже пользователя с таким telegram_id
        existing = await self.get_by_telegram_id(data.telegram_id)
        if existing:
            return existing

        user = User(
            telegram_id=data.telegram_id,
            username=data.username,
            first_name=data.first_name,
            last_name=data.last_name,
        )
        self.session.add(user)
        await self.session.commit()
        await self.session.refresh(user)
        return user

    async def get_user(self, user_id: int) -> User:
        user = await self.session.get(User, user_id)
        if not user:
            raise NotFoundException("User", user_id)
        return user

    async def get_by_telegram_id(self, telegram_id: int) -> Optional[User]:
        stmt = select(User).where(User.telegram_id == telegram_id)
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def get_user_with_subscriptions(self, user_id: int) -> User:
        stmt = (
            select(User)
            .options(selectinload(User.subscriptions))
            .where(User.id == user_id)
        )
        result = await self.session.execute(stmt)
        user = result.scalar_one_or_none()
        if not user:
            raise NotFoundException("User", user_id)
        return user

    async def list_users(self) -> List[User]:
        stmt = select(User).order_by(User.created_at.desc())
        result = await self.session.execute(stmt)
        return list(result.scalars().all())

    async def update_user(self, user_id: int, data: UserUpdate) -> User:
        user = await self.get_user(user_id)
        update_data = data.model_dump(exclude_unset=True)
        for key, value in update_data.items():
            setattr(user, key, value)
        await self.session.commit()
        await self.session.refresh(user)
        return user

    async def delete_user(self, user_id: int) -> bool:
        user = await self.get_user(user_id)
        await self.session.delete(user)
        await self.session.commit()
        return True
