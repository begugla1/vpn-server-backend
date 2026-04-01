from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from typing import List

from app.models.server import Server
from app.schemas.server import ServerCreate, ServerUpdate, ServerStatus
from app.services.xui_client import XUIClient
from app.exceptions import NotFoundException


class ServerService:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def create_server(self, data: ServerCreate) -> Server:
        server = Server(**data.model_dump())
        self.session.add(server)
        await self.session.commit()
        await self.session.refresh(server)
        return server

    async def get_server(self, server_id: int) -> Server:
        server = await self.session.get(Server, server_id)
        if not server:
            raise NotFoundException("Server", server_id)
        return server

    async def list_servers(self) -> List[Server]:
        stmt = select(Server).order_by(Server.created_at.desc())
        result = await self.session.execute(stmt)
        return list(result.scalars().all())

    async def update_server(self, server_id: int, data: ServerUpdate) -> Server:
        server = await self.get_server(server_id)
        update_data = data.model_dump(exclude_unset=True)
        for key, value in update_data.items():
            setattr(server, key, value)
        await self.session.commit()
        await self.session.refresh(server)
        return server

    async def delete_server(self, server_id: int) -> bool:
        server = await self.get_server(server_id)
        await self.session.delete(server)
        await self.session.commit()
        return True

    async def get_server_status(self, server_id: int) -> ServerStatus:
        """Получить статус сервера из 3X-UI панели."""
        server = await self.get_server(server_id)
        client = XUIClient(server)

        try:
            status_data = await client.get_server_status()
            return ServerStatus(
                server_id=server.id,
                server_name=server.name,
                is_reachable=True,
                cpu=status_data.get("cpu"),
                mem_current=status_data.get("mem", {}).get("current"),
                mem_total=status_data.get("mem", {}).get("total"),
                disk_current=status_data.get("disk", {}).get("current"),
                disk_total=status_data.get("disk", {}).get("total"),
                xray_state=status_data.get("xray", {}).get("state"),
                xray_version=status_data.get("xray", {}).get("version"),
                uptime=status_data.get("uptime"),
            )
        except BaseException:  # pylint: disable=broad-except
            return ServerStatus(
                server_id=server.id,
                server_name=server.name,
                is_reachable=False,
            )
        finally:
            await client.close()
