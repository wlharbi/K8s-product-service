from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "product-service"
    environment: str = "development"
    log_level: str = "INFO"
    database_url: str = "sqlite:///./product.db"
    api_prefix: str = "/api/v1"
    # Convenient for dev/demo; use migrations (e.g. Alembic) in production.
    auto_create_tables: bool = True


@lru_cache
def get_settings() -> Settings:
    return Settings()
