from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    DATABASE_URL: str

    APP_HOST: str = "0.0.0.0"
    APP_PORT: int = 8000
    DEBUG: bool = False

    DEFAULT_XUI_USERNAME: str = "admin"
    DEFAULT_XUI_PASSWORD: str = "admin"
    DEFAULT_XUI_PORT: int = 2053
    DEFAULT_XUI_WEB_BASE_PATH: str = "/"

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )


settings = Settings()
