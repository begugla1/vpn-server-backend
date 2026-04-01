from pydantic import BaseModel
from typing import Optional, Dict, Any
from datetime import datetime


class InboundCreate(BaseModel):
    """Создание инбаунда на конкретном сервере через 3X-UI API."""

    server_id: int
    remark: str = ""
    port: int
    protocol: str = "vless"  # vless, vmess, trojan, shadowsocks
    settings: Optional[Dict[str, Any]] = None
    stream_settings: Optional[Dict[str, Any]] = None
    sniffing: Optional[Dict[str, Any]] = None
    enable: bool = True
    total: int = 0
    expiry_time: int = 0


class InboundUpdate(BaseModel):
    remark: Optional[str] = None
    port: Optional[int] = None
    enable: Optional[bool] = None
    settings: Optional[Dict[str, Any]] = None
    stream_settings: Optional[Dict[str, Any]] = None
    sniffing: Optional[Dict[str, Any]] = None


class InboundResponse(BaseModel):
    id: int
    server_id: int
    xui_inbound_id: int
    remark: str
    protocol: str
    port: int
    settings: Optional[Dict[str, Any]]
    stream_settings: Optional[Dict[str, Any]]
    sniffing: Optional[Dict[str, Any]]
    enable: bool
    up: int
    down: int
    total: int
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


class ClientTraffic(BaseModel):
    email: str
    up: int
    down: int
    total: int
    enable: bool
    expiry_time: int
