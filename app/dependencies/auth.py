import secrets

from fastapi import Header, HTTPException, Security, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import settings

bearer_scheme = HTTPBearer(auto_error=False)


async def require_api_token(
    authorization: HTTPAuthorizationCredentials | None = Security(bearer_scheme),
    x_api_token: str | None = Header(default=None, alias="X-API-Token"),
) -> None:
    provided_token = authorization.credentials if authorization else x_api_token

    if provided_token and secrets.compare_digest(
        provided_token, settings.BACKEND_API_TOKEN
    ):
        return

    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or missing API token",
        headers={"WWW-Authenticate": "Bearer"},
    )
