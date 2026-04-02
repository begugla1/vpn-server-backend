from pydantic import BaseModel, Field
from typing import Optional, Dict, Any
from datetime import datetime

from app.config import settings


class ServerCreate(BaseModel):
    name: str
    ip_address: str
    panel_port: int = settings.DEFAULT_XUI_PORT
    panel_username: str = settings.DEFAULT_XUI_USERNAME
    panel_password: str = settings.DEFAULT_XUI_PASSWORD
    web_base_path: str = settings.DEFAULT_XUI_WEB_BASE_PATH
    use_https: bool = True
    subscription_port: int = 2096
    subscription_base_path: str = "/sub/"
    open_ports: Optional[Dict[str, Any]] = None
    configuration: Optional[Dict[str, Any]] = None
    max_subscriptions: int = Field(
        default=settings.DEFAULT_SERVER_MAX_SUBSCRIPTIONS,
        ge=1,
    )


class ServerUpdate(BaseModel):
    name: Optional[str] = None
    ip_address: Optional[str] = None
    panel_port: Optional[int] = None
    panel_username: Optional[str] = None
    panel_password: Optional[str] = None
    web_base_path: Optional[str] = None
    use_https: Optional[bool] = None
    subscription_port: Optional[int] = None
    subscription_base_path: Optional[str] = None
    open_ports: Optional[Dict[str, Any]] = None
    configuration: Optional[Dict[str, Any]] = None
    max_subscriptions: Optional[int] = Field(default=None, ge=1)
    is_active: Optional[bool] = None


class ServerResponse(BaseModel):
    id: int
    name: str
    ip_address: str
    panel_port: int
    panel_username: str
    web_base_path: str
    use_https: bool
    subscription_port: int
    subscription_base_path: str
    open_ports: Optional[Dict[str, Any]]
    configuration: Optional[Dict[str, Any]]
    max_subscriptions: int
    is_active: bool
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


class ServerStatus(BaseModel):
    """Статус сервера, полученный из 3X-UI API."""

    server_id: int
    server_name: str
    is_reachable: bool
    cpu: Optional[float] = None
    mem_current: Optional[int] = None
    mem_total: Optional[int] = None
    disk_current: Optional[int] = None
    disk_total: Optional[int] = None
    xray_state: Optional[str] = None
    xray_version: Optional[str] = None
    uptime: Optional[int] = None
