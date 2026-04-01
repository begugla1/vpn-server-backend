from sqlalchemy import String, Integer, DateTime, JSON, Boolean, ForeignKey, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from typing import Any
from datetime import datetime

from app.database import Base


class Inbound(Base):
    __tablename__ = "inbounds"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    server_id: Mapped[int] = mapped_column(
        ForeignKey("servers.id", ondelete="CASCADE"), nullable=False, index=True
    )

    # ID инбаунда на стороне 3X-UI панели
    xui_inbound_id: Mapped[int] = mapped_column(Integer, nullable=False)

    remark: Mapped[str] = mapped_column(String(255), nullable=False, default="")
    protocol: Mapped[str] = mapped_column(
        String(50), nullable=False
    )  # vless, vmess, trojan, shadowsocks
    port: Mapped[int] = mapped_column(Integer, nullable=False)

    # Полная конфигурация инбаунда (settings, streamSettings, sniffing и т.д.)
    settings: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    stream_settings: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    sniffing: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)

    enable: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    # Traffic
    up: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    down: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    total: Mapped[int] = mapped_column(Integer, nullable=False, default=0)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()  # pylint: disable=E1102
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),  # pylint: disable=E1102
        onupdate=func.now(),  # pylint: disable=E1102
    )

    # Relationships
    server: Mapped["Server"] = relationship(  # noqa: F821
        "Server", back_populates="inbounds"
    )
    subscriptions: Mapped[list["Subscription"]] = relationship(  # noqa: F821
        "Subscription", back_populates="inbound", cascade="all, delete-orphan"
    )

    def __repr__(self) -> str:
        return (
            f"<Inbound(id={self.id}, xui_id={self.xui_inbound_id}, "
            f"protocol={self.protocol}, port={self.port})>"
        )
