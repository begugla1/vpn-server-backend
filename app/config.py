from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # Database
    DATABASE_URL: str = (
        "postgresql+asyncpg://vpn_user:vpn_password@localhost:5432/vpn_db"
    )

    # App
    APP_HOST: str = "0.0.0.0"
    APP_PORT: int = 8000
    DEBUG: bool = False

    # Default XUI credentials (можно переопределять per-server)
    DEFAULT_XUI_USERNAME: str = "admin"
    DEFAULT_XUI_PASSWORD: str = "admin"
    DEFAULT_XUI_PORT: int = 2053
    DEFAULT_XUI_WEB_BASE_PATH: str = "/"

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


settings = Settings()
