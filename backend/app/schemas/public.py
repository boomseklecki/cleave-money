from pydantic import BaseModel


class ServerInfo(BaseModel):
    app: str
    version: str
    name: str  # friendly label for the confirm screen (server-settings public_hostname, else app_name)
    requires_auth: bool  # whether the gate shows (auth providers configured, or auth_required/api_tokens)
    auth_providers: list[str]  # configured sign-in options, e.g. ["apple", "google", "splitwise"]
    demo: bool = False  # a demo backend: the app shows guest "Start the demo" + a sample-data banner
    push_configured: bool = False  # a push relay is configured; the app shows the push toggle (prod, non-demo)
    # Which "connect a bank" methods to offer. Statement import + manual are always available. The app offers
    # Plaid only when BOTH plaid_configured (creds set) and plaid_enabled (admin toggle) are true.
    plaid_configured: bool = False   # Plaid API creds are set
    plaid_enabled: bool = True        # admin hasn't turned Plaid off (existing links keep syncing regardless)
    simplefin_enabled: bool = False  # SimpleFIN is enabled -> offer "Connect via SimpleFIN"
