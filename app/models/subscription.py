from typing import Any
from datetime import datetime

from sqlalchemy import (
    ForeignKey,
    String,
    JSON,
    Boolean,
    BigInteger,
    DateTime,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


class Subscription(Base):
    __tablename__ = "subscriptions"
    __table_args__ = (
        UniqueConstraint("user_id", name="uq_subscriptions_user_id"),
    )

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    server_id: Mapped[int] = mapped_column(
        ForeignKey("servers.id", ondelete="CASCADE"), nullable=False, index=True
    )
    inbound_id: Mapped[int] = mapped_column(
        ForeignKey("inbounds.id", ondelete="CASCADE"), nullable=False, index=True
    )

    # Client UUID on the XUI panel (client.id for VLESS/VMESS, password for Trojan)
    client_uuid: Mapped[str] = mapped_column(String(255), nullable=False)
    client_email: Mapped[str] = mapped_column(String(255), nullable=False, unique=True)

    # Sub ID для подписки (генерируется 3X-UI)
    sub_id: Mapped[str] = mapped_column(String(255), nullable=False)

    # Полный URL подписки
    subscription_url: Mapped[str] = mapped_column(String(1024), nullable=False)

    # Конфигурация клиента на стороне XUI
    client_config: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)

    enable: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    # Traffic limits
    total_gb: Mapped[int] = mapped_column(
        BigInteger, nullable=False, default=0
    )  # 0 = unlimited
    expiry_time: Mapped[int] = mapped_column(
        BigInteger, nullable=False, default=0
    )  # 0 = never

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()  # pylint: disable=E1102
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),  # pylint: disable=E1102
        onupdate=func.now(),  # pylint: disable=E1102
    )

    # Relationships
    user: Mapped["User"] = relationship(  # noqa: F821
        "User", back_populates="subscriptions"
    )
    server: Mapped["Server"] = relationship(  # noqa: F821
        "Server", back_populates="subscriptions"
    )
    inbound: Mapped["Inbound"] = relationship(  # noqa: F821
        "Inbound", back_populates="subscriptions"
    )

    def __repr__(self) -> str:
        return (
            f"<Subscription(id={self.id}, user_id={self.user_id}, "
            f"server_id={self.server_id}, email={self.client_email})>"
        )
