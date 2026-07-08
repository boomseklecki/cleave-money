import asyncio
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.auth.access import is_admin, is_admin_caller
from app.auth.scope import audience, caller_co_members
from app.db import get_session
from app.integrations.plaid import client as plaid_client
from app.logic.avatars import avatar_object_keys, remove_avatar_objects
from app.models import (
    Account,
    CategoryMap,
    Connection,
    Friend,
    Goal,
    GroupMember,
    PlaidItem,
    SpendCategory,
    SplitwiseToken,
    Transaction,
    User,
)
from app.models.enums import UserSource
from app.schemas.user import MeResponse, UserCreate, UserResponse, UserUpdate
from app.utils import ensure_utc, slugify

router = APIRouter(tags=["users"])


async def _purge_personal_data(session: AsyncSession, identifier: str) -> None:
    """Remove a user's PERSONAL data on account deletion: Plaid links (token revoked at Plaid +
    cascading their accounts), Splitwise token, owned accounts/transactions/goals, and group
    memberships. Shared group expenses/splits are co-owned records (other members' balances depend on
    them) and are left intact, the way Splitwise retains a departed member's history."""
    items = (await session.scalars(
        select(PlaidItem).where(PlaidItem.user_identifier == identifier))).all()
    for item in items:
        try:  # best-effort: end Plaid's access so unlinking actually revokes the token
            await asyncio.to_thread(plaid_client.make_client().item_remove, item.access_token)
        except Exception:
            pass
        await session.delete(item)  # cascades its accounts; their transactions are owner-deleted below
    await session.execute(delete(Transaction).where(Transaction.owner_identifier == identifier))
    await session.execute(delete(Goal).where(Goal.owner_identifier == identifier))
    await session.execute(delete(Account).where(Account.owner_identifier == identifier))
    await session.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier == identifier))
    await session.execute(delete(GroupMember).where(GroupMember.user_identifier == identifier))
    # Category taxonomy/maps (keyed by owner) and connections (pairwise) have no FK cascade off the user.
    await session.execute(delete(SpendCategory).where(SpendCategory.owner_identifier == identifier))
    await session.execute(delete(CategoryMap).where(CategoryMap.owner_identifier == identifier))
    await session.execute(delete(Connection).where(or_(
        Connection.requester_identifier == identifier, Connection.addressee_identifier == identifier)))


@router.get("/me", response_model=MeResponse)
async def me(
    identifier: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> MeResponse:
    user = None
    if identifier is not None:
        user = await session.scalar(select(User).where(User.identifier == identifier))
    return MeResponse(identifier=identifier, authenticated=identifier is not None,
                      is_admin=is_admin(identifier, user), user=user)


def _public(user: User, caller: str | None, admin: bool, co_members: set[str]) -> UserResponse:
    """Directory entry with contact details (email/Splitwise id) only for people the caller may see: in
    open mode or as an admin, all; otherwise the caller's own row + people they share a group with."""
    full = admin or caller is None or user.identifier == caller or user.identifier in co_members
    response = UserResponse.model_validate(user)
    if full:
        return response
    return response.model_copy(update={"email": None, "splitwise_user_id": None})


@router.get("/users", response_model=list[UserResponse])
async def list_users(
    source: UserSource | None = None,
    updated_since: datetime | None = None,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[UserResponse]:
    stmt = select(User)
    if source is not None:
        stmt = stmt.where(User.source == source)
    if updated_since is not None:
        stmt = stmt.where(User.updated_at >= ensure_utc(updated_since))
    admin = await is_admin_caller(session, caller)
    co_members: set[str] = set()
    if caller is not None:
        # Scope the browsable directory to people the caller can act on: local logins (source=app - you can
        # start a local group with them) + their Splitwise friends + shared-group co-members + accepted
        # partners. Deduped by the User row; drops *other* people's imported Splitwise-only contacts. This
        # also composes with `?source=app` (the admin local-users view → only local logins). Open mode
        # (caller is None) is unscoped, as before.
        co_members = await caller_co_members(session, caller)
        partners = await audience(session, caller)
        friend_ids = set(await session.scalars(select(Friend.identifier).where(
            Friend.owner_identifier == caller, Friend.identifier.is_not(None))))
        related = co_members | partners | friend_ids
        stmt = stmt.where(or_(User.source == UserSource.app, User.identifier.in_(related)))
    rows = list(await session.scalars(stmt.order_by(User.display_name)))
    return [_public(u, caller, admin, co_members) for u in rows]


@router.post("/users", response_model=UserResponse, status_code=201)
async def create_user(
    body: UserCreate, session: AsyncSession = Depends(get_session)
) -> User:
    identifier = body.identifier or slugify(body.display_name)
    if await session.scalar(select(User).where(User.identifier == identifier)):
        raise HTTPException(status_code=409, detail=f"identifier '{identifier}' already exists")
    user = User(
        identifier=identifier,
        display_name=body.display_name,
        source=body.source,
        splitwise_user_id=body.splitwise_user_id,
        email=body.email,
    )
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return user


@router.get("/users/{user_id}", response_model=UserResponse)
async def get_user(
    user_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> UserResponse:
    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    admin = await is_admin_caller(session, caller)
    co_members: set[str] = set()
    if caller is not None and not admin:
        co_members = await caller_co_members(session, caller)
    return _public(user, caller, admin, co_members)


@router.patch("/users/{user_id}", response_model=UserResponse)
async def update_user(
    user_id: UUID, body: UserUpdate, session: AsyncSession = Depends(get_session)
) -> User:
    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    if body.display_name is not None:
        user.display_name = body.display_name
    if body.email is not None:
        user.email = body.email
    await session.commit()
    await session.refresh(user)
    return user


@router.delete("/users/{user_id}", status_code=204)
async def delete_user(
    user_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    """Delete a user and their personal data - the caller's own account (App Store account-deletion
    requirement), or any account when the caller is an admin. Shared/co-owned group history is retained
    (see `_purge_personal_data`)."""
    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    if caller is not None and user.identifier != caller and not await is_admin_caller(session, caller):
        raise HTTPException(status_code=403, detail="You can only delete your own account.")
    avatar_keys = avatar_object_keys(user)  # capture before the row (and its keys) is gone
    await _purge_personal_data(session, user.identifier)
    await session.delete(user)
    await session.commit()
    await remove_avatar_objects(avatar_keys)  # best-effort, after commit, so a delete doesn't orphan images


@router.post("/users/{user_id}/revoke", status_code=204)
async def revoke_user(
    user_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    """Admin-only: revoke a user's access by de-enrolling them. Their session 403s on the very next request
    (`require_auth` re-checks `enrolled`); their identity + shared history are untouched, and a fresh invite
    re-enrolls them. Reversible - not a data purge (use DELETE for that)."""
    if caller is not None and not await is_admin_caller(session, caller):
        raise HTTPException(status_code=403, detail="Admins only.")
    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    if caller is not None and user.identifier == caller:
        raise HTTPException(status_code=400, detail="You can't revoke your own access.")
    user.enrolled = False
    await session.commit()
