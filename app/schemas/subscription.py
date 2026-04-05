from pydantic import BaseModel
from typing import Optional, Dict, Any
from datetime import datetime


class SubscriptionCreateBase(BaseModel):
    # Параметры клиента на XUI
    client_email: Optional[str] = None  # если не указан — генерируется
    total_gb: int = 0  # 0 = unlimited, в байтах
    expiry_time: int = 0  # 0 = never, unix timestamp в ms
    limit_ip: int = 0
    enable: bool = True
    tg_id: Optional[str] = ""
    flow: str = "xtls-rprx-vision"  # для VLESS: xtls-rprx-vision


class SubscriptionCreate(SubscriptionCreateBase):
    """Создание подписки: привязка клиента к inbound на сервере."""

    user_id: int  # Наш внутренний user ID
    server_id: int
    inbound_id: int  # Наш внутренний inbound ID


class SubscriptionCreateWithAnyAvailableServer(SubscriptionCreateBase):
    """Создание подписки на любой доступной ноде."""

    user_id: int


class SubscriptionUpdate(BaseModel):
    enable: Optional[bool] = None
    total_gb: Optional[int] = None
    expiry_time: Optional[int] = None
    limit_ip: Optional[int] = None
    tg_id: Optional[str] = None


class SubscriptionResponse(BaseModel):
    id: int
    user_id: int
    server_id: int
    inbound_id: int
    client_uuid: str
    client_email: str
    sub_id: str
    subscription_url: str
    client_config: Optional[Dict[str, Any]]
    enable: bool
    total_gb: int
    expiry_time: int
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


class SubscriptionDetail(SubscriptionResponse):
    """Подписка с деталями о пользователе и сервере."""

    user_telegram_id: Optional[int] = None
    server_name: Optional[str] = None
    server_ip: Optional[str] = None
    inbound_protocol: Optional[str] = None
    inbound_port: Optional[int] = None


class SubscriptionCreateWithAnyAvailableServerResponse(BaseModel):
    subscription: SubscriptionResponse
    warning: Optional[str] = None
