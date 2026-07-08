from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # APNs token-based auth (the one official key for money.cleave.app). Empty = /push returns 503.
    apns_key_id: str = ""
    apns_team_id: str = ""
    apns_bundle_id: str = ""
    apns_auth_key: str = ""        # base64-encoded .p8 (PEM)
    apns_env: str = "production"   # "production" | "sandbox"

    # Operations
    admin_token: str = ""          # gates /admin/* (approve/revoke) + admin UI; empty = admin disabled
    admin_user: str = "admin"      # Basic-auth username for the /admin web UI (password = admin_token)
    relay_auto_issue: bool = True  # register → key now; false = pending until approved
    db_path: str = "relay.db"      # sqlite file
    # When true, the relay refuses plaintext-body pushes and only forwards E2E-encrypted (opaque) payloads,
    # so it can be safely shared by multiple self-hosters without seeing their content. Off = back-compat.
    require_e2ee: bool = False

    # Rate limits
    register_max_per_hour: int = 5     # per IP
    push_max_per_minute: int = 600     # per key

    @property
    def apns_configured(self) -> bool:
        return all([self.apns_key_id, self.apns_team_id, self.apns_bundle_id, self.apns_auth_key])


settings = Settings()
