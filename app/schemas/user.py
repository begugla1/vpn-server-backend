from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime


class UserCreate(BaseModel):
    telegram_id: int
    username: Optional[str] = None
    first_name: Optional[str] = None
    last_name: Optional[str] = None


class UserUpdate(BaseModel):
    username: Optional[str] = None
    first_name: Optional[str] = None
    last_name: Optional[str] = None


class UserResponse(BaseModel):
    id: int
    telegram_id: int
    username: Optional[str]
    first_name: Optional[str]
    last_name: Optional[str]
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


class UserWithSubscriptions(UserResponse):
    subscriptions: List["SubscriptionResponse"] = []

    class Config:
        from_attributes = True


# Forward reference — будет resolve после импорта SubscriptionResponse
from app.schemas.subscription import SubscriptionResponse  # noqa: E402

UserWithSubscriptions.model_rebuild()
