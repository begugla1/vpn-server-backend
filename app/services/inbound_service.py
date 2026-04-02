import json
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.server import Server
from app.models.inbound import Inbound
from app.schemas.inbound import InboundCreate, InboundUpdate
from app.services.xui_client import XUIClient
from app.exceptions import NotFoundException, AppException


class InboundService:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def _get_server(self, server_id: int) -> Server:
        server = await self.session.get(Server, server_id)
        if not server:
            raise NotFoundException("Server", server_id)
        return server

    async def create_inbound(self, data: InboundCreate) -> Inbound:
        """
        Создать инбаунд:
        1. Отправить запрос в 3X-UI API
        2. Сохранить данные в нашу БД
        """
        server = await self._get_server(data.server_id)
        client = XUIClient(server)

        try:
            # Формируем конфигурацию для 3X-UI
            if data.settings:
                settings_str = json.dumps(data.settings)
            else:
                if data.protocol != "vless":
                    raise AppException(
                        "Default inbound generation is supported only for protocol=vless. "
                        "Provide explicit settings for other protocols."
                    )
                # Создаём дефолтный VLESS inbound
                default_config = client.build_default_vless_inbound(
                    port=data.port,
                    remark=data.remark,
                )
                settings_str = default_config["settings"]

            stream_settings = data.stream_settings or {
                "network": "tcp",
                "security": "none",
                "externalProxy": [],
                "tcpSettings": {
                    "acceptProxyProtocol": False,
                    "header": {"type": "none"},
                },
            }

            sniffing = data.sniffing or {
                "enabled": True,
                "destOverride": ["http", "tls", "quic", "fakedns"],
                "metadataOnly": False,
                "routeOnly": False,
            }

            xui_payload = {
                "up": 0,
                "down": 0,
                "total": data.total,
                "remark": data.remark,
                "enable": data.enable,
                "expiryTime": data.expiry_time,
                "listen": "",
                "port": data.port,
                "protocol": data.protocol,
                "settings": settings_str,
                "streamSettings": json.dumps(stream_settings),
                "sniffing": json.dumps(sniffing),
            }

            # Создаём на 3X-UI
            xui_result = await client.add_inbound(xui_payload)
            xui_inbound_id = xui_result.get("id", 0)

            # Парсим settings обратно из строки
            parsed_settings = data.settings
            if not parsed_settings and isinstance(settings_str, str):
                try:
                    parsed_settings = json.loads(settings_str)
                except json.JSONDecodeError:
                    parsed_settings = {}

            # Сохраняем в нашу БД
            inbound = Inbound(
                server_id=data.server_id,
                xui_inbound_id=xui_inbound_id,
                remark=data.remark,
                protocol=data.protocol,
                port=data.port,
                settings=parsed_settings,
                stream_settings=stream_settings,
                sniffing=sniffing,
                enable=data.enable,
                total=data.total,
                expiry_time=data.expiry_time,
            )
            self.session.add(inbound)
            await self.session.commit()
            await self.session.refresh(inbound)
            return inbound

        finally:
            await client.close()

    async def get_inbound(self, inbound_id: int) -> Inbound:
        inbound = await self.session.get(Inbound, inbound_id)
        if not inbound:
            raise NotFoundException("Inbound", inbound_id)
        return inbound

    async def list_inbounds(self, server_id: int | None = None) -> list[Inbound]:
        stmt = select(Inbound)
        if server_id:
            stmt = stmt.where(Inbound.server_id == server_id)
        stmt = stmt.order_by(Inbound.created_at.desc())
        result = await self.session.execute(stmt)
        return list(result.scalars().all())

    async def update_inbound(self, inbound_id: int, data: InboundUpdate) -> Inbound:
        """Обновить инбаунд в 3X-UI и в нашей БД."""
        inbound = await self.get_inbound(inbound_id)
        server = await self._get_server(inbound.server_id)
        client = XUIClient(server)

        try:
            update_data = data.model_dump(exclude_unset=True)

            # Обновляем на 3X-UI
            xui_inbound = await client.get_inbound(inbound.xui_inbound_id)

            # Мержим данные
            if "remark" in update_data:
                xui_inbound["remark"] = update_data["remark"]
            if "port" in update_data:
                xui_inbound["port"] = update_data["port"]
            if "enable" in update_data:
                xui_inbound["enable"] = update_data["enable"]
            if "settings" in update_data and update_data["settings"]:
                xui_inbound["settings"] = json.dumps(update_data["settings"])
            if "stream_settings" in update_data and update_data["stream_settings"]:
                xui_inbound["streamSettings"] = json.dumps(
                    update_data["stream_settings"]
                )
            if "sniffing" in update_data and update_data["sniffing"]:
                xui_inbound["sniffing"] = json.dumps(update_data["sniffing"])
            if "total" in update_data:
                xui_inbound["total"] = update_data["total"]
            if "expiry_time" in update_data:
                xui_inbound["expiryTime"] = update_data["expiry_time"]

            await client.update_inbound(inbound.xui_inbound_id, xui_inbound)

            # Обновляем в нашей БД
            for key, value in update_data.items():
                setattr(inbound, key, value)

            await self.session.commit()
            await self.session.refresh(inbound)
            return inbound

        finally:
            await client.close()

    async def delete_inbound(self, inbound_id: int) -> bool:
        """Удалить инбаунд из 3X-UI и из нашей БД."""
        inbound = await self.get_inbound(inbound_id)
        server = await self._get_server(inbound.server_id)
        client = XUIClient(server)

        try:
            await client.delete_inbound(inbound.xui_inbound_id)
            await self.session.delete(inbound)
            await self.session.commit()
            return True
        finally:
            await client.close()

    async def sync_inbounds_from_xui(self, server_id: int) -> list[Inbound]:
        """
        Синхронизировать инбаунды с 3X-UI панели в нашу БД.
        Полезно при первоначальной настройке.
        """
        server = await self._get_server(server_id)
        client = XUIClient(server)

        try:
            xui_inbounds = await client.list_inbounds()
            synced = []

            for xui_ib in xui_inbounds:
                # Проверяем, есть ли уже в нашей БД
                stmt = select(Inbound).where(
                    Inbound.server_id == server_id,
                    Inbound.xui_inbound_id == xui_ib["id"],
                )
                result = await self.session.execute(stmt)
                existing = result.scalar_one_or_none()

                # Парсим settings
                settings = xui_ib.get("settings", "{}")
                if isinstance(settings, str):
                    try:
                        settings = json.loads(settings)
                    except json.JSONDecodeError:
                        settings = {}

                stream_settings = xui_ib.get("streamSettings", "{}")
                if isinstance(stream_settings, str):
                    try:
                        stream_settings = json.loads(stream_settings)
                    except json.JSONDecodeError:
                        stream_settings = {}

                sniffing = xui_ib.get("sniffing", "{}")
                if isinstance(sniffing, str):
                    try:
                        sniffing = json.loads(sniffing)
                    except json.JSONDecodeError:
                        sniffing = {}

                if existing:
                    existing.remark = xui_ib.get("remark", "")
                    existing.protocol = xui_ib.get("protocol", "")
                    existing.port = xui_ib.get("port", 0)
                    existing.settings = settings
                    existing.stream_settings = stream_settings
                    existing.sniffing = sniffing
                    existing.enable = xui_ib.get("enable", True)
                    existing.up = xui_ib.get("up", 0)
                    existing.down = xui_ib.get("down", 0)
                    existing.total = xui_ib.get("total", 0)
                    existing.expiry_time = xui_ib.get("expiryTime", 0)
                    synced.append(existing)
                else:
                    inbound = Inbound(
                        server_id=server_id,
                        xui_inbound_id=xui_ib["id"],
                        remark=xui_ib.get("remark", ""),
                        protocol=xui_ib.get("protocol", ""),
                        port=xui_ib.get("port", 0),
                        settings=settings,
                        stream_settings=stream_settings,
                        sniffing=sniffing,
                        enable=xui_ib.get("enable", True),
                        up=xui_ib.get("up", 0),
                        down=xui_ib.get("down", 0),
                        total=xui_ib.get("total", 0),
                        expiry_time=xui_ib.get("expiryTime", 0),
                    )
                    self.session.add(inbound)
                    synced.append(inbound)

            await self.session.commit()
            return synced

        finally:
            await client.close()
