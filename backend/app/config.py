from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Core
    app_name: str = "Cleave"
    default_currency: str = "USD"
    # NOTE: runtime policy (public_hostname, invite policy, scheduler/refresh intervals) moved to the
    # admin-editable `server_settings` table (see app/server_settings.py); they are no longer .env vars.
    # Maps bearer token -> local identifier, e.g. {"tok-alice": "alice", "tok-bob": "bob"}.
    # Empty = auth disabled (open mode); populated = bearer token required on app endpoints.
    api_tokens: dict[str, str] = {}

    # Real auth: providers (Apple/Google/Splitwise) verified server-side, then the backend issues
    # its own stateless JWT. `auth_required` default false keeps dev/tests/open mode working.
    auth_jwt_secret: str = ""  # HS256 signing secret; generate a long random value (openssl rand -hex 32)
    auth_required: bool = False  # when true, guarded endpoints reject requests without a valid token
    # Enrollment is now DB-backed (the `users.enrolled` flag, granted by redeeming an invite or claiming a
    # fresh server) - see app/auth/identity.py. The former AUTH_ALLOWED_USERS / CLOSED_REGISTRATION env vars
    # are gone.
    google_client_id: str = ""  # Google iOS OAuth client id - the id-token audience
    apple_audience: str = ""  # the iOS app bundle id (e.g. money.yourcompany.cleave) - the identity-token audience
    # Apple Developer Team ID - used to serve the App Site Association (GET /.well-known/apple-app-site-association)
    # for Universal Links. AASA returns 404 until this is set. appID = "<team_id>.<apple_audience>".
    apple_team_id: str = ""

    # Postgres
    database_url: str = "postgresql+asyncpg://cleave:cleave@db:5432/cleave"

    # MinIO (server-side only; iOS app never sees these)
    minio_endpoint: str = "minio:9000"
    minio_access_key: str = "cleave"
    minio_secret_key: str = "cleave-secret"
    minio_bucket: str = "receipts"
    minio_secure: bool = False

    # Backups (admin-only): full DB dump + receipt objects, stored as one tar.gz per backup in this MinIO
    # bucket (parallel to the receipts bucket; set per stack, e.g. backups-prod). The scheduler cadence +
    # retention (backup_interval_hours / backups_retention_days / backups_retention_min_keep) are now
    # admin-editable server settings (see app/server_settings.py), not env vars. Manual backups are never
    # auto-deleted.
    backups_bucket: str = "backups"

    # Periodic data sync cadence (sync_interval_hours) is also an admin-editable server setting now.

    # Subscription brand logos: the upstream a logo is fetched from (cached in MinIO, served by /logos).
    # `{domain}` is substituted. Default is a free, token-less favicon service; logo.dev gives nicer logos
    # with an API token, e.g. "https://img.logo.dev/{domain}?token=YOUR_TOKEN".
    logo_upstream_template: str = "https://www.google.com/s2/favicons?domain={domain}&sz=128"

    # Plaid (server-side only)
    plaid_client_id: str = ""
    plaid_secret: str = ""
    plaid_env: str = "development"
    plaid_products: str = "transactions"
    plaid_country_codes: str = "US"
    plaid_language: str = "en"
    # OAuth redirect URI for Plaid Link (required by most production banks). Must be registered in the
    # Plaid dashboard AND handled by the iOS app. Leave blank for sandbox / non-OAuth - only passed
    # to link-token creation when set (an unregistered value breaks ALL link tokens).
    plaid_redirect_uri: str = ""
    # Initial transaction history requested at link time (Plaid `days_requested`, max 730 = ~24 months).
    # Burned in per item at link; 0 omits the request entirely (some OAuth banks reject the extra data scope).
    plaid_transactions_days_requested: int = 730

    # Splitwise (server-side only) - consumer key/secret act as the OAuth2 client id/secret
    splitwise_consumer_key: str = ""
    splitwise_consumer_secret: str = ""
    splitwise_redirect_uri: str = "http://localhost:8000/auth/splitwise/callback"
    # Maps Splitwise user id (string) -> local identifier, e.g. {"123": "alice", "456": "bob"}
    splitwise_user_map: dict[str, str] = {}

    # Field-encryption keys for access tokens at rest (Fernet). JSON list; the FIRST encrypts, ANY can
    # decrypt (rotation). Empty = stored plaintext (dev). Generate one with:
    #   python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
    encryption_keys: list[str] = []
    # Local identifiers granted admin (see all people; reserved for gating settings/features). Set to your
    # /me identifier (Settings -> Account shows it). Empty = no admins.
    admin_users: list[str] = []
    # HTTP hardening. Empty ⇒ disabled (no behavior change). Set on prod to the public + LAN hostnames, e.g.
    #   ALLOWED_HOSTS=["your-host.example.com","dev.your-host.example.com","your-lan-host","localhost"]
    # (behind the Cloudflare tunnel the app still sees the real Host, so this must enumerate every one).
    allowed_hosts: list[str] = []
    # Browser origins allowed cross-origin (the native app doesn't need this). Empty ⇒ CORS not mounted.
    cors_allowed_origins: list[str] = []
    # Demo backend: enables the guest login (POST /auth/demo, name only - no OAuth) that mints an ephemeral
    # user and auto-seeds isolated sample data. Surfaced on /server-info so the app shows the demo UX. Keep
    # FALSE on dev/prod (the endpoint 404s when off).
    demo_mode: bool = False

    # Push: the backend never touches APNs directly - keeping the open-source server free of Apple creds.
    # It POSTs to a standalone push relay (e.g. push.your-host.example.com) with an instance key issued by the
    # relay's self-serve registration. Empty = push disabled.
    push_relay_url: str = ""       # e.g. https://push.your-host.example.com
    push_relay_api_key: str = ""

    @property
    def push_configured(self) -> bool:
        return bool(self.push_relay_url and self.push_relay_api_key)

    @property
    def plaid_configured(self) -> bool:
        # Plaid needs server-side API creds; the app hides "Connect a bank (Plaid)" when they're absent.
        return bool(self.plaid_client_id and self.plaid_secret)

    @property
    def libpq_dsn(self) -> str:
        """A plain libpq connection URI (for pg_dump/pg_restore), derived from the SQLAlchemy async URL by
        dropping the `+asyncpg` driver tag. Credentials stay embedded so no PGPASSWORD wiring is needed."""
        return self.database_url.replace("+asyncpg", "", 1)

    @model_validator(mode="after")
    def _require_strong_jwt_secret(self) -> "Settings":
        # When auth is enforced, an empty/short HS256 secret makes session tokens forgeable (PyJWT will
        # happily sign/verify with ""). Fail fast at startup rather than silently accept it.
        if self.auth_required and len(self.auth_jwt_secret) < 32:
            raise ValueError(
                "AUTH_JWT_SECRET must be set to >=32 chars when AUTH_REQUIRED=true "
                "(generate one with `openssl rand -hex 32`)."
            )
        return self


settings = Settings()
