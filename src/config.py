from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://archer_user:password@localhost/archer"

    archer_telegram_bot_token: str = ""
    archer_telegram_chat_id: str = ""

    velocity_dir: Path = Path.home() / "Developer/velo9-dev/velocity"
    repos_yaml: Path = Path("config/repos.yaml")

    archer_host: str = "0.0.0.0"
    archer_port: int = 8100
    archer_secret_key: str = "changeme"


settings = Settings()
