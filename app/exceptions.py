from fastapi import HTTPException, status


class AppException(HTTPException):
    """Базовое исключение приложения."""

    def __init__(self, detail: str, status_code: int = status.HTTP_400_BAD_REQUEST):
        super().__init__(status_code=status_code, detail=detail)


class NotFoundException(AppException):
    """Ресурс не найден."""

    def __init__(self, resource: str, identifier):
        super().__init__(
            detail=f"{resource} with id={identifier} not found",
            status_code=status.HTTP_404_NOT_FOUND,
        )


class XUIConnectionError(AppException):
    """Ошибка подключения к 3X-UI панели."""

    def __init__(self, server_ip: str, detail: str = ""):
        super().__init__(
            detail=f"Failed to connect to 3X-UI panel at {server_ip}: {detail}",
            status_code=status.HTTP_502_BAD_GATEWAY,
        )


class XUIApiError(AppException):
    """Ошибка API 3X-UI."""

    def __init__(self, detail: str):
        super().__init__(
            detail=f"3X-UI API error: {detail}",
            status_code=status.HTTP_502_BAD_GATEWAY,
        )
