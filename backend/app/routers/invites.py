"""Single-use enrollment invites. An enrolled member mints one (admin always; any member when the
`invites_open_to_members` server setting is on) and shares the join link carrying its code; a new person
redeems it at sign-in (see `app/auth/identity.resolve_user`). Create/list/revoke; redemption is at sign-in."""
import secrets
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import server_settings
from app.auth import require_auth
from app.auth.access import is_admin_caller
from app.db import get_session
from app.models import Invite
from app.schemas.invite import InviteCreate, InviteResponse

router = APIRouter(prefix="/invites", tags=["invites"])


async def require_can_invite(
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> str:
    """An admin, or any enrolled member when `invites_open_to_members` is on, may manage invites."""
    if caller is None:
        raise HTTPException(status_code=401, detail="Authentication required")
    if await is_admin_caller(session, caller):
        return caller
    if await server_settings.get(session, "invites_open_to_members"):
        return caller
    raise HTTPException(status_code=403, detail="Only admins can create invites on this server.")


def _status(invite: Invite) -> str:
    if invite.revoked_at is not None:
        return "revoked"
    if invite.redeemed_at is not None:
        return "redeemed"
    if invite.expires_at is not None and invite.expires_at <= datetime.now(timezone.utc):
        return "expired"
    return "active"


def _to_response(invite: Invite) -> InviteResponse:
    return InviteResponse(
        id=invite.id, code=invite.code, label=invite.label, status=_status(invite),
        expires_at=invite.expires_at, redeemed_at=invite.redeemed_at, redeemed_by=invite.redeemed_by,
        revoked_at=invite.revoked_at, created_at=invite.created_at,
    )


@router.post("", response_model=InviteResponse, status_code=201)
async def create_invite(
    body: InviteCreate,
    caller: str = Depends(require_can_invite),
    session: AsyncSession = Depends(get_session),
) -> InviteResponse:
    expires_at = None
    if body.ttl_days and body.ttl_days > 0:
        expires_at = datetime.now(timezone.utc) + timedelta(days=body.ttl_days)
    invite = Invite(
        code=secrets.token_urlsafe(16), created_by=caller, label=(body.label or None), expires_at=expires_at
    )
    session.add(invite)
    await session.commit()
    await session.refresh(invite)
    return _to_response(invite)


@router.get("", response_model=list[InviteResponse])
async def list_invites(
    caller: str = Depends(require_can_invite),
    session: AsyncSession = Depends(get_session),
) -> list[InviteResponse]:
    rows = await session.scalars(select(Invite).order_by(Invite.created_at.desc()))
    return [_to_response(i) for i in rows]


@router.delete("/{invite_id}", status_code=204)
async def revoke_invite(
    invite_id: UUID,
    caller: str = Depends(require_can_invite),
    session: AsyncSession = Depends(get_session),
) -> None:
    invite = await session.get(Invite, invite_id)
    if invite is None:
        raise HTTPException(status_code=404, detail="Invite not found")
    if invite.revoked_at is None and invite.redeemed_at is None:  # spent/already-revoked invites are inert
        invite.revoked_at = datetime.now(timezone.utc)
        await session.commit()
