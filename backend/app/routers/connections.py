from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.db import get_session
from app.logic.avatars import resolved_avatar_url
from app.models import Connection, User
from app.models.enums import ConnectionStatus
from app.schemas.connection import ConnectionCreate, ConnectionResponse
from app.services import notify as notify_svc

router = APIRouter(prefix="/connections", tags=["connections"])


async def _resolve(session: AsyncSession, body: ConnectionCreate) -> User:
    """Find the invited user by identifier or email (they must already be enrolled)."""
    user: User | None = None
    if body.identifier:
        user = await session.scalar(select(User).where(User.identifier == body.identifier))
    elif body.email:
        user = await session.scalar(
            select(User).where(User.email == body.email).order_by(User.created_at).limit(1)
        )
    else:
        raise HTTPException(status_code=422, detail="identifier or email is required")
    if user is None:
        raise HTTPException(status_code=404, detail="No user with that email/identifier")
    return user


def _response(c: Connection, caller: str, by_id: dict[str, User]) -> ConnectionResponse:
    other = c.addressee_identifier if c.requester_identifier == caller else c.requester_identifier
    u = by_id.get(other)
    return ConnectionResponse(
        id=c.id,
        other_identifier=other,
        other_display_name=(u.display_name if u else other),
        other_avatar_url=(resolved_avatar_url(u, "users") if u else None),
        direction="outgoing" if c.requester_identifier == caller else "incoming",
        status=c.status.value,
    )


@router.get("", response_model=list[ConnectionResponse])
async def list_connections(
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[ConnectionResponse]:
    """The caller's partner connections (incoming/outgoing pending + accepted), each with the other party."""
    if caller is None:
        return []
    rows = list(await session.scalars(
        select(Connection).where(
            or_(Connection.requester_identifier == caller, Connection.addressee_identifier == caller)
        ).order_by(Connection.created_at.desc())
    ))
    others = {(c.addressee_identifier if c.requester_identifier == caller else c.requester_identifier)
              for c in rows}
    by_id = {u.identifier: u for u in await session.scalars(
        select(User).where(User.identifier.in_(others)))} if others else {}
    return [_response(c, caller, by_id) for c in rows]


@router.post("", response_model=ConnectionResponse, status_code=201)
async def create_connection(
    body: ConnectionCreate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> ConnectionResponse:
    """Invite a partner to connect (pending until they accept)."""
    if caller is None:
        raise HTTPException(status_code=401, detail="Sign in to connect a partner")
    other = await _resolve(session, body)
    if other.identifier == caller:
        raise HTTPException(status_code=422, detail="You can't connect with yourself")
    existing = await session.scalar(
        select(Connection).where(
            or_(
                (Connection.requester_identifier == caller)
                & (Connection.addressee_identifier == other.identifier),
                (Connection.requester_identifier == other.identifier)
                & (Connection.addressee_identifier == caller),
            )
        )
    )
    if existing is not None:
        raise HTTPException(status_code=409, detail="A connection with this person already exists")
    conn = Connection(requester_identifier=caller, addressee_identifier=other.identifier,
                      status=ConnectionStatus.pending)
    session.add(conn)
    await session.commit()
    await session.refresh(conn)
    actor = await notify_svc.display_name(session, caller)
    await notify_svc.notify(session, {other.identifier}, "connection_request",
                            f"{actor} wants to connect", actor=caller)
    return _response(conn, caller, {other.identifier: other})


@router.post("/{connection_id}/accept", response_model=ConnectionResponse)
async def accept_connection(
    connection_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> ConnectionResponse:
    """Accept a pending invite (only the invited party). Idempotent on an already-accepted one."""
    conn = await session.get(Connection, connection_id)
    if conn is None:
        raise HTTPException(status_code=404, detail="Connection not found")
    if caller is not None and conn.addressee_identifier != caller:
        raise HTTPException(status_code=403, detail="Only the invited person can accept")
    conn.status = ConnectionStatus.accepted
    await session.commit()
    actor = await notify_svc.display_name(session, caller or conn.addressee_identifier)
    await notify_svc.notify(session, {conn.requester_identifier}, "connection_accepted",
                            f"{actor} accepted your connection request", actor=caller,
                            entity_type="friend", entity_id=(caller or conn.addressee_identifier))
    by_id = {u.identifier: u for u in await session.scalars(
        select(User).where(User.identifier.in_(
            [conn.requester_identifier, conn.addressee_identifier])))}
    return _response(conn, caller or conn.addressee_identifier, by_id)


@router.delete("/{connection_id}", status_code=204)
async def delete_connection(
    connection_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    """Decline a pending invite or disconnect an accepted partner (either party)."""
    conn = await session.get(Connection, connection_id)
    if conn is None:
        raise HTTPException(status_code=404, detail="Connection not found")
    if caller is not None and caller not in (conn.requester_identifier, conn.addressee_identifier):
        raise HTTPException(status_code=403, detail="Not your connection")
    await session.delete(conn)
    await session.commit()
