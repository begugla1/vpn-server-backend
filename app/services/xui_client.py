"""
Клиент для взаимодействия с 3X-UI API.
Каждый экземпляр привязан к конкретному серверу.
"""

import httpx
import json
import uuid
import string
import random
from typing import Optional, Dict, Any, List

from app.models.server import Server
from app.exceptions import XUIConnectionError, XUIApiError


class XUIClient:
    """HTTP-клиент для 3X-UI panel API."""

    def __init__(self, server: Server):
        self.server = server
        self._session_cookie: Optional[str] = None
        if not server.use_https:
            raise XUIConnectionError(
                server.ip_address, detail="Unsafe connection via HTTP forbidden"
            )
        protocol = "https"
        self.base_url = f"{protocol}://{server.ip_address}:{server.panel_port}"
        self.web_base_path = server.web_base_path.rstrip("/")
        self._client: Optional[httpx.AsyncClient] = None

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                base_url=self.base_url,
                timeout=30.0,
                verify=False,  # Часто self-signed certs
                follow_redirects=True,
            )
        return self._client

    async def close(self):
        if self._client and not self._client.is_closed:
            await self._client.aclose()

    async def login(self) -> bool:
        """Аутентификация на 3X-UI панели."""
        client = await self._get_client()
        try:
            response = await client.post(
                f"{self.web_base_path}/login",
                data={
                    "username": self.server.panel_username,
                    "password": self.server.panel_password,
                },
            )
            response.raise_for_status()
            data = response.json()
            if data.get("success"):
                return True
            raise XUIApiError(f"Login failed: {data.get('msg', 'Unknown error')}")
        except httpx.ConnectError as e:
            raise XUIConnectionError(self.server.ip_address, str(e)) from e
        except httpx.HTTPStatusError as e:
            raise XUIConnectionError(self.server.ip_address, str(e)) from e

    async def _ensure_logged_in(self):
        client = await self._get_client()
        if not client.cookies:
            await self.login()

    async def _request(
        self,
        method: str,
        path: str,
        data: Optional[Dict[str, Any]] = None,
        json_data: Optional[Any] = None,
        form_data: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Выполнить запрос к API с автоматическим re-login."""
        client = await self._get_client()
        full_path = f"{self.web_base_path}{path}"

        try:
            kwargs = {}
            if json_data is not None:
                kwargs["json"] = json_data
            elif form_data is not None:
                kwargs["data"] = form_data
            elif data is not None:
                kwargs["json"] = data

            response = await client.request(method, full_path, **kwargs)

            # Если 401 — пробуем перелогиниться
            if response.status_code == 401:
                await self.login()
                response = await client.request(method, full_path, **kwargs)

            response.raise_for_status()
            result = response.json()

            if not result.get("success", False):
                raise XUIApiError(result.get("msg", "Unknown API error"))

            return result

        except httpx.ConnectError as e:
            raise XUIConnectionError(self.server.ip_address, str(e)) from e
        except httpx.HTTPStatusError as e:
            raise XUIApiError(
                f"HTTP {e.response.status_code}: {e.response.text}"
            ) from e

    # ────────── Server API ──────────

    async def get_server_status(self) -> Dict[str, Any]:
        """Получить статус сервера."""
        await self._ensure_logged_in()
        result = await self._request("GET", "/panel/api/server/status")
        return result.get("obj", {}) or {}

    async def get_new_uuid(self) -> str:
        """Получить новый UUID от панели."""
        await self._ensure_logged_in()
        result = await self._request("GET", "/panel/api/server/getNewUUID")
        return result["obj"]["uuid"]

    async def get_new_x25519_cert(self) -> Dict[str, str]:
        """Получить новый X25519 сертификат."""
        await self._ensure_logged_in()
        result = await self._request("GET", "/panel/api/server/getNewX25519Cert")
        return result["obj"]

    # ────────── Inbounds API ──────────

    async def list_inbounds(self) -> List[Dict[str, Any]]:
        """Получить все инбаунды."""
        await self._ensure_logged_in()
        result = await self._request("GET", "/panel/api/inbounds/list")
        return result.get("obj", []) or []

    async def get_inbound(self, inbound_id: int) -> Dict[str, Any]:
        """Получить инбаунд по ID."""
        await self._ensure_logged_in()
        result = await self._request("GET", f"/panel/api/inbounds/get/{inbound_id}")
        return result.get("obj", {}) or {}

    async def add_inbound(self, inbound_config: Dict[str, Any]) -> Dict[str, Any]:
        """
        Создать новый инбаунд.
        inbound_config должен содержать: port, protocol, settings, streamSettings, sniffing и т.д.
        """
        await self._ensure_logged_in()
        result = await self._request(
            "POST", "/panel/api/inbounds/add", json_data=inbound_config
        )
        return result.get("obj", {})

    async def update_inbound(
        self, inbound_id: int, inbound_config: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Обновить инбаунд."""
        await self._ensure_logged_in()
        result = await self._request(
            "POST",
            f"/panel/api/inbounds/update/{inbound_id}",
            json_data=inbound_config,
        )
        return result.get("obj", {})

    async def delete_inbound(self, inbound_id: int) -> bool:
        """Удалить инбаунд."""
        await self._ensure_logged_in()
        await self._request("POST", f"/panel/api/inbounds/del/{inbound_id}")
        return True

    # ────────── Clients API ──────────

    async def add_client(
        self,
        inbound_id: int,
        client_config: Dict[str, Any],
    ) -> bool:
        """
        Добавить клиента в инбаунд.
        client_config: {"id": "uuid", "email": "...", "flow": "...", ...}
        """
        await self._ensure_logged_in()
        payload = {
            "id": inbound_id,
            "settings": json.dumps({"clients": [client_config]}),
        }
        await self._request("POST", "/panel/api/inbounds/addClient", json_data=payload)
        return True

    async def update_client(
        self,
        client_uuid: str,
        inbound_id: int,
        client_config: Dict[str, Any],
    ) -> bool:
        """Обновить клиента по UUID."""
        await self._ensure_logged_in()
        payload = {
            "id": inbound_id,
            "settings": json.dumps({"clients": [client_config]}),
        }
        await self._request(
            "POST",
            f"/panel/api/inbounds/updateClient/{client_uuid}",
            json_data=payload,
        )
        return True

    async def delete_client(self, inbound_id: int, client_uuid: str) -> bool:
        """Удалить клиента из инбаунда."""
        await self._ensure_logged_in()
        await self._request(
            "POST",
            f"/panel/api/inbounds/{inbound_id}/delClient/{client_uuid}",
        )
        return True

    async def get_client_traffics(self, email: str) -> Optional[Dict[str, Any]]:
        """Получить трафик клиента по email."""
        await self._ensure_logged_in()
        result = await self._request(
            "GET",
            f"/panel/api/inbounds/getClientTraffics/{email}",
        )
        return result.get("obj")

    async def get_online_clients(self) -> List[str]:
        """Получить список онлайн-клиентов."""
        await self._ensure_logged_in()
        result = await self._request("POST", "/panel/api/inbounds/onlines")
        return result.get("obj", []) or []

    # ────────── Helper methods ──────────

    @staticmethod
    def generate_email(length: int = 8) -> str:
        """Генерация случайного email-идентификатора для клиента."""
        chars = string.ascii_lowercase + string.digits
        return "".join(random.choices(chars, k=length))

    @staticmethod
    def generate_sub_id(length: int = 16) -> str:
        """Генерация sub_id для подписки."""
        chars = string.ascii_lowercase + string.digits
        return "".join(random.choices(chars, k=length))

    def build_subscription_url(self, sub_id: str) -> str:
        """Построить URL подписки для клиента."""
        protocol = "https" if self.server.use_https else "http"
        base_path = self.server.subscription_base_path.strip("/")
        return (
            f"{protocol}://{self.server.ip_address}:{self.server.subscription_port}"
            f"/{base_path}/{sub_id}"
        )

    def build_default_vless_inbound(
        self,
        port: int,
        remark: str = "",
        client_email: Optional[str] = None,
        security: str = "none",
    ) -> Dict[str, Any]:
        """Создать конфигурацию VLESS инбаунда по умолчанию."""
        client_id = str(uuid.uuid4())
        email = client_email or self.generate_email()
        sub_id = self.generate_sub_id()

        settings = {
            "clients": [
                {
                    "id": client_id,
                    "flow": "",
                    "email": email,
                    "limitIp": 0,
                    "totalGB": 0,
                    "expiryTime": 0,
                    "enable": True,
                    "tgId": "",
                    "subId": sub_id,
                    "comment": "",
                    "reset": 0,
                }
            ],
            "decryption": "none",
            "fallbacks": [],
        }

        stream_settings = {
            "network": "tcp",
            "security": security,
            "externalProxy": [],
            "tcpSettings": {
                "acceptProxyProtocol": False,
                "header": {"type": "none"},
            },
        }

        sniffing = {
            "enabled": True,
            "destOverride": ["http", "tls", "quic", "fakedns"],
            "metadataOnly": False,
            "routeOnly": False,
        }

        return {
            "up": 0,
            "down": 0,
            "total": 0,
            "remark": remark,
            "enable": True,
            "expiryTime": 0,
            "listen": "",
            "port": port,
            "protocol": "vless",
            "settings": json.dumps(settings),
            "streamSettings": json.dumps(stream_settings),
            "sniffing": json.dumps(sniffing),
        }

    def build_client_config(
        self,
        client_uuid: Optional[str] = None,
        email: Optional[str] = None,
        sub_id: Optional[str] = None,
        total_gb: int = 0,
        expiry_time: int = 0,
        limit_ip: int = 0,
        enable: bool = True,
        tg_id: str = "",
        flow: str = "",
    ) -> Dict[str, Any]:
        """Создать конфигурацию клиента для добавления в инбаунд."""
        return {
            "id": client_uuid or str(uuid.uuid4()),
            "flow": flow,
            "email": email or self.generate_email(),
            "limitIp": limit_ip,
            "totalGB": total_gb,
            "expiryTime": expiry_time,
            "enable": enable,
            "tgId": tg_id,
            "subId": sub_id or self.generate_sub_id(),
            "comment": "",
            "reset": 0,
        }
