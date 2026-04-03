from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    DATABASE_URL: str
    BACKEND_API_TOKEN: str

    APP_HOST: str = "0.0.0.0"
    APP_PORT: int = 8000
    DEBUG: bool = False

    DEFAULT_XUI_USERNAME: str = "admin"
    DEFAULT_XUI_PASSWORD: str = "admin"
    DEFAULT_XUI_PORT: int = 65000
    DEFAULT_XUI_WEB_BASE_PATH: str = "/"
    DEFAULT_SERVER_MAX_SUBSCRIPTIONS: int = 120

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )


settings = Settings()
