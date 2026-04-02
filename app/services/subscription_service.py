import logging
import uuid
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload
from starlette import status

from app.models.user import User
from app.models.server import Server
from app.models.inbound import Inbound
from app.models.subscription import Subscription
from app.schemas.subscription import (
    SubscriptionCreate,
    SubscriptionCreateBase,
    SubscriptionCreateWithAnyAvailableServer,
    SubscriptionCreateWithAnyAvailableServerResponse,
    SubscriptionUpdate,
)
from app.services.xui_client import XUIClient
from app.exceptions import NotFoundException, AppException

logger = logging.getLogger(__name__)


class SubscriptionService:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def _get_user(self, user_id: int) -> User:
        user = await self.session.get(User, user_id)
        if not user:
            raise NotFoundException("User", user_id)
        return user

    async def _get_server(self, server_id: int) -> Server:
        server = await self.session.get(Server, server_id)
        if not server:
            raise NotFoundException("Server", server_id)
        return server

    async def _get_inbound(self, inbound_id: int) -> Inbound:
        inbound = await self.session.get(Inbound, inbound_id)
        if not inbound:
            raise NotFoundException("Inbound", inbound_id)
        return inbound

    async def _get_existing_subscription_for_user(
        self, user_id: int
    ) -> Subscription | None:
        stmt = (
            select(Subscription)
            .where(Subscription.user_id == user_id)
            .order_by(Subscription.created_at.desc())
        )
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def _ensure_user_has_no_subscription(self, user_id: int) -> None:
        existing_subscription = await self._get_existing_subscription_for_user(user_id)
        if existing_subscription:
            raise AppException(
                detail=(
                    "User already has an active subscription "
                    f"(subscription_id={existing_subscription.id}, "
                    f"server_id={existing_subscription.server_id})"
                ),
                status_code=status.HTTP_409_CONFLICT,
            )

    @staticmethod
    def _ensure_server_and_inbound_are_available(server: Server, inbound: Inbound) -> None:
        if not server.is_active:
            raise AppException(
                detail=f"Server id={server.id} is inactive",
                status_code=status.HTTP_409_CONFLICT,
            )
        if not inbound.enable:
            raise AppException(
                detail=f"Inbound id={inbound.id} is disabled",
                status_code=status.HTTP_409_CONFLICT,
            )

    async def _create_subscription_on_server(
        self,
        user: User,
        server: Server,
        inbound: Inbound,
        data: SubscriptionCreateBase,
    ) -> Subscription:
        self._ensure_server_and_inbound_are_available(server, inbound)

        client = XUIClient(server)
        client_uuid = str(uuid.uuid4())
        client_email = data.client_email or client.generate_email()
        sub_id = client.generate_sub_id()
        client_created = False

        try:
            client_config = client.build_client_config(
                client_uuid=client_uuid,
                email=client_email,
                sub_id=sub_id,
                total_gb=data.total_gb,
                expiry_time=data.expiry_time,
                limit_ip=data.limit_ip,
                enable=data.enable,
                tg_id=data.tg_id or str(user.telegram_id or ""),
                flow=data.flow,
            )

            await client.add_client(inbound.xui_inbound_id, client_config)
            client_created = True

            subscription = Subscription(
                user_id=user.id,
                server_id=server.id,
                inbound_id=inbound.id,
                client_uuid=client_uuid,
                client_email=client_email,
                sub_id=sub_id,
                subscription_url=client.build_subscription_url(sub_id),
                client_config=client_config,
                enable=data.enable,
                total_gb=data.total_gb,
                expiry_time=data.expiry_time,
            )
            self.session.add(subscription)

            try:
                await self.session.commit()
            except IntegrityError as exc:
                await self.session.rollback()
                if client_created:
                    try:
                        await client.delete_client(inbound.xui_inbound_id, client_uuid)
                    except BaseException:  # pylint: disable=broad-except
                        logger.exception(
                            "Failed to roll back XUI client after DB integrity error"
                        )

                raise AppException(
                    detail="User already has a subscription",
                    status_code=status.HTTP_409_CONFLICT,
                ) from exc

            await self.session.refresh(subscription)
            return subscription
        finally:
            await client.close()

    async def _select_server_and_inbound_for_auto_assignment(
        self,
    ) -> tuple[Server, Inbound, str | None]:
        stmt = (
            select(Server)
            .options(
                selectinload(Server.inbounds),
                selectinload(Server.subscriptions),
            )
            .where(Server.is_active.is_(True))
            .order_by(Server.created_at.asc(), Server.id.asc())
        )
        result = await self.session.execute(stmt)
        servers = list(result.scalars().all())

        candidates: list[tuple[int, Server, Inbound]] = []
        overflow_candidates: list[tuple[int, Server, Inbound]] = []

        for server in servers:
            enabled_inbound = next(
                (inbound for inbound in sorted(server.inbounds, key=lambda item: item.id) if inbound.enable),
                None,
            )
            if not enabled_inbound:
                continue

            current_subscription_count = len(server.subscriptions)
            candidate = (current_subscription_count, server, enabled_inbound)

            if current_subscription_count < server.max_subscriptions:
                candidates.append(candidate)
            else:
                overflow_candidates.append(candidate)

        if candidates:
            _, server, inbound = min(
                candidates,
                key=lambda item: (item[0], item[1].created_at, item[1].id, item[2].id),
            )
            return server, inbound, None

        if overflow_candidates:
            current_subscription_count, server, inbound = min(
                overflow_candidates,
                key=lambda item: (item[0], item[1].created_at, item[1].id, item[2].id),
            )
            warning = (
                f"Server #{server.id} has reached capacity "
                f"({current_subscription_count}/{server.max_subscriptions}). "
                "Subscription was created using soft-limit mode."
            )
            logger.warning(warning)
            return server, inbound, warning

        raise AppException(
            detail="No active server with an enabled inbound is available",
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        )

    async def create_subscription(self, data: SubscriptionCreate) -> Subscription:
        """
        Создать подписку:
        1. Добавить клиента в инбаунд через 3X-UI API
        2. Сохранить подписку в нашу БД
        """
        user = await self._get_user(data.user_id)
        await self._ensure_user_has_no_subscription(user.id)
        server = await self._get_server(data.server_id)
        inbound = await self._get_inbound(data.inbound_id)

        # Проверяем, что инбаунд принадлежит этому серверу
        if inbound.server_id != server.id:
            raise AppException("Inbound does not belong to the specified server")

        return await self._create_subscription_on_server(user, server, inbound, data)

    async def create_subscription_with_any_available_server(
        self,
        data: SubscriptionCreateWithAnyAvailableServer,
    ) -> SubscriptionCreateWithAnyAvailableServerResponse:
        user = await self._get_user(data.user_id)
        await self._ensure_user_has_no_subscription(user.id)

        server, inbound, warning = (
            await self._select_server_and_inbound_for_auto_assignment()
        )
        subscription = await self._create_subscription_on_server(
            user=user,
            server=server,
            inbound=inbound,
            data=data,
        )
        return SubscriptionCreateWithAnyAvailableServerResponse(
            subscription=subscription,
            warning=warning,
        )

    async def get_subscription(self, subscription_id: int) -> Subscription:
        subscription = await self.session.get(Subscription, subscription_id)
        if not subscription:
            raise NotFoundException("Subscription", subscription_id)
        return subscription

    async def list_subscriptions(
        self,
        user_id: int | None = None,
        server_id: int | None = None,
        telegram_id: int | None = None,
    ) -> list[Subscription]:
        stmt = select(Subscription)

        if user_id:
            stmt = stmt.where(Subscription.user_id == user_id)
        if server_id:
            stmt = stmt.where(Subscription.server_id == server_id)
        if telegram_id:
            # Джойним с User чтобы фильтровать по telegram_id
            stmt = stmt.join(User).where(User.telegram_id == telegram_id)

        stmt = stmt.order_by(Subscription.created_at.desc())
        result = await self.session.execute(stmt)
        return list(result.scalars().all())

    async def update_subscription(
        self, subscription_id: int, data: SubscriptionUpdate
    ) -> Subscription:
        """Обновить подписку в 3X-UI и в нашей БД."""
        subscription = await self.get_subscription(subscription_id)
        server = await self._get_server(subscription.server_id)
        inbound = await self._get_inbound(subscription.inbound_id)
        client = XUIClient(server)

        try:
            update_data = data.model_dump(exclude_unset=True)

            # Обновляем конфигурацию клиента
            client_config = dict(subscription.client_config or {})

            if "enable" in update_data:
                client_config["enable"] = update_data["enable"]
            if "total_gb" in update_data:
                client_config["totalGB"] = update_data["total_gb"]
            if "expiry_time" in update_data:
                client_config["expiryTime"] = update_data["expiry_time"]
            if "limit_ip" in update_data:
                client_config["limitIp"] = update_data["limit_ip"]
            if "tg_id" in update_data:
                client_config["tgId"] = update_data["tg_id"]

            # Обновляем на 3X-UI
            await client.update_client(
                subscription.client_uuid,
                inbound.xui_inbound_id,
                client_config,
            )

            # Обновляем в нашей БД
            if "enable" in update_data:
                subscription.enable = update_data["enable"]
            if "total_gb" in update_data:
                subscription.total_gb = update_data["total_gb"]
            if "expiry_time" in update_data:
                subscription.expiry_time = update_data["expiry_time"]

            subscription.client_config = client_config

            await self.session.commit()
            await self.session.refresh(subscription)
            return subscription

        finally:
            await client.close()

    async def delete_subscription(self, subscription_id: int) -> bool:
        """Удалить подписку: удалить клиента из 3X-UI и запись из БД."""
        subscription = await self.get_subscription(subscription_id)
        server = await self._get_server(subscription.server_id)
        inbound = await self._get_inbound(subscription.inbound_id)
        client = XUIClient(server)

        try:
            # Удаляем клиента из 3X-UI
            await client.delete_client(
                inbound.xui_inbound_id,
                subscription.client_uuid,
            )

            # Удаляем из БД
            await self.session.delete(subscription)
            await self.session.commit()
            return True

        finally:
            await client.close()

    async def get_client_traffic(self, subscription_id: int) -> dict | None:
        """Получить трафик клиента из 3X-UI."""
        subscription = await self.get_subscription(subscription_id)
        server = await self._get_server(subscription.server_id)
        client = XUIClient(server)

        try:
            return await client.get_client_traffics(subscription.client_email)
        finally:
            await client.close()
