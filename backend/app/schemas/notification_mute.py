from pydantic import BaseModel


class NotificationPrefs(BaseModel):
    """The caller's notification preference tokens (`"<channel>:<selector>"`). Used for both the GET
    response and the PUT body (replace-set semantics)."""
    tokens: list[str]
