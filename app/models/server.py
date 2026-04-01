from typing import Any
from datetime import datetime

from sqlalchemy import String, Integer, DateTime, JSON, Boolean, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


class Server(Base):
    __tablename__ = "servers"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    ip_address: Mapped[str] = mapped_column(String(45), nullable=False, unique=True)

    # 3X-UI panel connection settings
    panel_port: Mapped[int] = mapped_column(Integer, nullable=False, default=2053)
    panel_username: Mapped[str] = mapped_column(
        String(255), nullable=False, default="admin"
    )
    panel_password: Mapped[str] = mapped_column(
        String(255), nullable=False, default="admin"
    )
    web_base_path: Mapped[str] = mapped_column(String(255), nullable=False, default="/")
    use_https: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    # Subscription port on XUI panel
    subscription_port: Mapped[int] = mapped_column(
        Integer, nullable=False, default=2096
    )
    subscription_base_path: Mapped[str] = mapped_column(
        String(255), nullable=False, default="/sub/"
    )

    # Server configuration
    open_ports: Mapped[dict[str, Any] | None] = mapped_column(
        JSON, nullable=True, default=dict
    )
    configuration: Mapped[dict[str, Any] | None] = mapped_column(
        JSON, nullable=True, default=dict
    )

    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()  # pylint: disable=E1102
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),  # pylint: disable=E1102
        onupdate=func.now(),  # pylint: disable=E1102
    )

    # Relationships
    inbounds: Mapped[list["Inbound"]] = relationship(  # noqa: F821
        "Inbound", back_populates="server", cascade="all, delete-orphan"
    )
    subscriptions: Mapped[list["Subscription"]] = relationship(  # noqa: F821
        "Subscription", back_populates="server", cascade="all, delete-orphan"
    )

    @property
    def panel_base_url(self) -> str:
        protocol = "https" if self.use_https else "http"
        return f"{protocol}://{self.ip_address}:{self.panel_port}{self.web_base_path}"

    def __repr__(self) -> str:
        return f"<Server(id={self.id}, name={self.name}, ip={self.ip_address})>"
