import uuid
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.user import User
from app.models.server import Server
from app.models.inbound import Inbound
from app.models.subscription import Subscription
from app.schemas.subscription import SubscriptionCreate, SubscriptionUpdate
from app.services.xui_client import XUIClient
from app.exceptions import NotFoundException, AppException


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

    async def create_subscription(self, data: SubscriptionCreate) -> Subscription:
        """
        Создать подписку:
        1. Добавить клиента в инбаунд через 3X-UI API
        2. Сохранить подписку в нашу БД
        """
        user = await self._get_user(data.user_id)
        server = await self._get_server(data.server_id)
        inbound = await self._get_inbound(data.inbound_id)

        # Проверяем, что инбаунд принадлежит этому серверу
        if inbound.server_id != server.id:
            raise AppException("Inbound does not belong to the specified server")

        client = XUIClient(server)

        try:
            # Генерируем данные клиента
            client_uuid = str(uuid.uuid4())
            client_email = data.client_email or client.generate_email()
            sub_id = client.generate_sub_id()

            # Формируем конфигурацию клиента
            client_config = client.build_client_config(
                client_uuid=client_uuid,
                email=client_email,
                sub_id=sub_id,
                total_gb=data.total_gb,
                expiry_time=data.expiry_time,
                limit_ip=data.limit_ip,
                enable=data.enable,
                tg_id=data.tg_id or "",
                flow=data.flow,
            )

            # Добавляем клиента в инбаунд на 3X-UI
            await client.add_client(inbound.xui_inbound_id, client_config)

            # Формируем URL подписки
            subscription_url = client.build_subscription_url(sub_id)

            # Сохраняем в БД
            subscription = Subscription(
                user_id=user.id,
                server_id=server.id,
                inbound_id=inbound.id,
                client_uuid=client_uuid,
                client_email=client_email,
                sub_id=sub_id,
                subscription_url=subscription_url,
                client_config=client_config,
                enable=data.enable,
                total_gb=data.total_gb,
                expiry_time=data.expiry_time,
            )
            self.session.add(subscription)
            await self.session.commit()
            await self.session.refresh(subscription)
            return subscription

        finally:
            await client.close()

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
