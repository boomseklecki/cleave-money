"""DB-backed access control. A user may authenticate iff their `User.enrolled` flag is set (replaces the
former `.env` email allowlist); enrollment is granted at sign-in by redeeming an invite or by claiming a
fresh server. `is_admin` unions the DB `is_admin` flag with the legacy `ADMIN_USERS` config (operator-pinned
admins keep working)."""
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.models import User


def _config_admins() -> set[str]:
    return {a.strip().lower() for a in settings.admin_users if a and a.strip()}


def is_enrolled(user: User | None) -> bool:
    """Whether this user may hold a session. Enrolled = on the DB allowlist."""
    return user is not None and bool(user.enrolled)


def is_admin(caller: str | None, user: User | None = None) -> bool:
    """Admin via the DB `is_admin` flag (first-user claim / promoted) OR the `ADMIN_USERS` config."""
    if user is not None and user.is_admin:
        return True
    if caller is None:
        return False
    return caller.strip().lower() in _config_admins()


async def is_admin_caller(session: AsyncSession, caller: str | None) -> bool:
    """Load the caller's user and resolve admin status (DB flag ∪ config)."""
    if caller is None:
        return False
    user = await session.scalar(select(User).where(User.identifier == caller))
    return is_admin(caller, user)
