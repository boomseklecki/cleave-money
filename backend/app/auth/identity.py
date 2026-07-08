"""Find-or-create/link a User from a verified provider identity, gated by DB enrollment.

Called after a provider (apple/google/splitwise) token is verified. Idempotent: the same provider sub always
resolves to the same User; a matching email links a second provider onto an existing User. Enrollment: an
already-enrolled user signs in freely; otherwise they must redeem a single-use invite - except on a fresh,
unclaimed server (no enrolled users yet), where the first person to sign in is enrolled and made admin.
"""
from fastapi import HTTPException, status
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Invite, User
from app.models.enums import UserSource
from app.utils import slugify

# Provider -> the User column holding that provider's subject id.
_PROVIDER_COLUMN = {
    "apple": "apple_sub",
    "google": "google_sub",
    "splitwise": "splitwise_user_id",
}

_INVITE_REQUIRED = HTTPException(
    status_code=status.HTTP_403_FORBIDDEN, detail="An invite is required to join this server."
)


def _backfill(user: User, *, email: str | None, avatar: str | None) -> None:
    if user.email is None and email:
        user.email = email
    if user.avatar_url is None and avatar:
        user.avatar_url = avatar


async def _unique_identifier(session: AsyncSession, source_name: str) -> str:
    base = slugify(source_name)
    candidate, n = base, 1
    while await session.scalar(select(User.id).where(User.identifier == candidate)) is not None:
        n += 1
        candidate = f"{base}{n}"
    return candidate


async def _no_enrolled_users(session: AsyncSession) -> bool:
    """True on a fresh/unclaimed server - the first person to sign in then claims it (enrolled + admin)."""
    return (await session.scalar(select(func.count()).select_from(User).where(User.enrolled.is_(True)))) == 0


async def _redeem(session: AsyncSession, code: str | None, identifier: str) -> str | None:
    """Atomically spend a valid single-use invite for `identifier`. Returns the invite's creator (to notify
    them of the acceptance) on success, or None if no valid invite applies."""
    if not code:
        return None
    result = await session.execute(
        update(Invite)
        .where(
            Invite.code == code,
            Invite.redeemed_at.is_(None),
            Invite.revoked_at.is_(None),
            (Invite.expires_at.is_(None)) | (Invite.expires_at > func.now()),
        )
        .values(redeemed_at=func.now(), redeemed_by=identifier)
        .returning(Invite.created_by)
    )
    row = result.first()
    return row[0] if row is not None else None


async def _notify_inviter(session: AsyncSession, creator: str | None, user: User) -> None:
    """Best-effort: tell whoever created the redeemed invite that it was accepted (a one-time notification,
    not a lingering list entry). Never breaks sign-in - a notify failure is swallowed + rolled back."""
    if not creator or creator == user.identifier:
        return
    try:
        from app.services import notify as notify_svc  # lazy: keep auth ↔ notify decoupled
        await notify_svc.notify(
            session, {creator}, type="invite_redeemed",
            content=f"{user.display_name} accepted your invite and joined.",
            entity_type="user", entity_id=str(user.id))
    except Exception:
        await session.rollback()


async def resolve_user(
    session: AsyncSession,
    *,
    provider: str,
    sub: str,
    email: str | None,
    name: str | None,
    avatar: str | None,
    invite_code: str | None = None,
) -> User:
    column = _PROVIDER_COLUMN[provider]

    # Find an existing user by provider sub, else link by matching email.
    user = await session.scalar(select(User).where(getattr(User, column) == sub))
    if user is None and email:
        user = await session.scalar(select(User).where(User.email == email))
        if user is not None:
            setattr(user, column, sub)

    if user is not None:
        creator: str | None = None
        if not user.enrolled:  # existing row not yet permitted → claim or redeem
            if await _no_enrolled_users(session):
                user.enrolled = True
                user.is_admin = True
            elif (creator := await _redeem(session, invite_code, user.identifier)):
                user.enrolled = True
            else:
                raise _INVITE_REQUIRED
        _backfill(user, email=email, avatar=avatar)
        await session.commit()
        await session.refresh(user)
        await _notify_inviter(session, creator, user)
        return user

    # New user - claim the server, or require an invite.
    identifier = await _unique_identifier(session, name or email or "user")
    enrolled = is_admin = False
    creator = None
    if await _no_enrolled_users(session):
        enrolled = is_admin = True
    elif (creator := await _redeem(session, invite_code, identifier)):
        enrolled = True
    else:
        raise _INVITE_REQUIRED
    user = User(
        identifier=identifier,
        display_name=name or email or identifier,
        source=UserSource.app,
        email=email,
        avatar_url=avatar,
        enrolled=enrolled,
        is_admin=is_admin,
    )
    setattr(user, column, sub)
    session.add(user)
    await session.commit()
    await session.refresh(user)
    await _notify_inviter(session, creator, user)
    return user
