import asyncio
import logging
from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.auth.scope import assert_group_member
from app.config import settings
from app.db import get_session
from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import importer
from app.integrations.splitwise import writer as sw_writer
from app.integrations.storage import minio_client
from app.logic.avatars import avatar_object_keys, remove_avatar_objects
from app.models import BackendType, Expense, Group, GroupMember, GroupOverride, Receipt, User
from app.schemas.group import GroupCreate, GroupResponse, GroupUpdate
from app.schemas.group_member import GroupMemberCreate, GroupMemberResponse
from app.utils import ensure_utc

log = logging.getLogger(__name__)

router = APIRouter(prefix="/groups", tags=["groups"])


async def _push_token(session: AsyncSession, caller: str | None):
    """The Splitwise token to push a group op with (caller's, else the single token). 409 when none."""
    try:
        return await sw_writer.select_token_for_caller(session, caller)
    except sw_writer.NoSplitwiseToken:
        raise HTTPException(
            status_code=409, detail="No Splitwise token stored; authorize via /auth/splitwise/login first"
        )


async def _sync_splitwise_group(session: AsyncSession, token, sw_group_id: str) -> None:
    """Pull one Splitwise group's metadata + members back into the local DB after a write. Commits."""
    client = sw_client.make_client(token.access_token)
    groups = await asyncio.to_thread(sw_client.fetch_groups, client)
    scoped = [g for g in groups if g["splitwise_id"] == sw_group_id]
    await importer.sync_groups(session, client, settings.splitwise_user_map, groups=scoped)


@router.post("", response_model=GroupResponse, status_code=201)
async def create_group(
    body: GroupCreate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Group:
    if body.backend_type == BackendType.splitwise:
        token = await _push_token(session, caller)
        client = sw_client.make_client(token.access_token)
        try:
            created = await asyncio.to_thread(
                sw_client.create_group, client, body.name, body.group_type
            )
        except Exception as exc:  # SDK / upstream Splitwise error
            raise HTTPException(status_code=502, detail=f"Splitwise rejected the request: {exc}")
        # Let the sync upsert the group (by splitwise_group_id) + its members (incl. the creator).
        await _sync_splitwise_group(session, token, created["splitwise_id"])
        group = await session.scalar(
            select(Group).where(Group.splitwise_group_id == created["splitwise_id"])
        )
        await _attach_group_overrides(session, caller, [group])
        return group

    group = Group(name=body.name, backend_type=BackendType.self_hosted)
    session.add(group)
    await session.flush()
    if caller is not None:  # the creator joins, so per-caller scoping shows them their own group
        session.add(GroupMember(group_id=group.id, user_identifier=caller))
    await session.commit()
    await session.refresh(group)
    await _attach_group_overrides(session, caller, [group])
    return group


# Override columns persisted per (owner, group). `hidden` defaults to False; include flags default null.
_GROUP_OVERRIDE_FIELDS = ("hidden", "include_in_spending", "include_in_cash_flow")


async def _attach_group_overrides(
    session: AsyncSession, caller: str | None, groups: list[Group]
) -> None:
    """Populate each group's per-user override fields (`hidden`, `include_in_spending`,
    `include_in_cash_flow`) from the caller's `group_overrides` row (none in open mode → defaults). Sets
    transient attributes the response serializes via `from_attributes`."""
    by_id: dict = {}
    ids = [g.id for g in groups]
    if caller is not None and ids:
        rows = await session.scalars(
            select(GroupOverride).where(
                GroupOverride.owner_identifier == caller, GroupOverride.group_id.in_(ids)
            )
        )
        by_id = {o.group_id: o for o in rows}
    for g in groups:
        override = by_id.get(g.id)
        g.hidden = bool(override.hidden) if override is not None and override.hidden is not None else False
        g.include_in_spending = override.include_in_spending if override is not None else None
        g.include_in_cash_flow = override.include_in_cash_flow if override is not None else None


@router.get("", response_model=list[GroupResponse])
async def list_groups(
    backend_type: BackendType | None = None,
    include_hidden: bool = False,
    updated_since: datetime | None = None,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Group]:
    stmt = select(Group)
    if caller is not None:  # only groups the caller is a member of
        stmt = stmt.where(
            Group.id.in_(select(GroupMember.group_id).where(GroupMember.user_identifier == caller))
        )
    if backend_type is not None:
        stmt = stmt.where(Group.backend_type == backend_type)
    # Always exclude superseded (local-import source) + deleted (restorable Splitwise) groups.
    stmt = stmt.where(Group.superseded_at.is_(None), Group.deleted_at.is_(None))
    if caller is not None and not include_hidden:  # exclude groups the caller has hidden (open mode hides none)
        stmt = stmt.where(
            Group.id.notin_(
                select(GroupOverride.group_id).where(
                    GroupOverride.owner_identifier == caller, GroupOverride.hidden.is_(True)
                )
            )
        )
    if updated_since is not None:
        stmt = stmt.where(Group.updated_at >= ensure_utc(updated_since))
    rows = list(await session.scalars(stmt.order_by(Group.created_at)))
    await _attach_group_overrides(session, caller, rows)
    return rows


# NOTE: declared before `/{group_id}` so "deleted" isn't matched as a group id.
@router.get("/deleted", response_model=list[GroupResponse])
async def list_deleted_groups(
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Group]:
    """Splitwise groups the caller is a member of that were deleted through the app (restorable), newest first."""
    stmt = select(Group).where(Group.deleted_at.is_not(None))
    if caller is not None:
        stmt = stmt.where(
            Group.id.in_(select(GroupMember.group_id).where(GroupMember.user_identifier == caller))
        )
    rows = list(await session.scalars(stmt.order_by(Group.deleted_at.desc())))
    await _attach_group_overrides(session, caller, rows)
    return rows


@router.get("/{group_id}", response_model=GroupResponse)
async def get_group(
    group_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Group:
    group = await session.get(Group, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="Group not found")
    await assert_group_member(session, group_id, caller)
    await _attach_group_overrides(session, caller, [group])
    return group


@router.patch("/{group_id}", response_model=GroupResponse)
async def update_group(
    group_id: UUID,
    body: GroupUpdate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Group:
    group = await session.get(Group, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="Group not found")
    await assert_group_member(session, group_id, caller)
    if body.name is not None:  # name is shared/sourced - stays on the group row
        group.name = body.name
    if caller is not None:  # the rest are the caller's per-user overrides
        fields = body.model_dump(exclude_unset=True)
        fields.pop("name", None)
        if fields.get("hidden") is False:  # hidden False = the default (shown) → clear
            fields["hidden"] = None
        if fields:
            override = await session.scalar(
                select(GroupOverride).where(
                    GroupOverride.owner_identifier == caller, GroupOverride.group_id == group_id
                )
            )
            if override is None:
                override = GroupOverride(owner_identifier=caller, group_id=group_id)
                # Concurrent first-time override for the same (owner, group) trips uq_group_override_owner_group
                # - adopt the winner and apply this request's field updates onto it, not a 500.
                try:
                    async with session.begin_nested():
                        session.add(override)
                except IntegrityError:
                    override = await session.scalar(
                        select(GroupOverride).where(
                            GroupOverride.owner_identifier == caller, GroupOverride.group_id == group_id
                        )
                    )
            for field, value in fields.items():
                setattr(override, field, value)
            if all(getattr(override, field) is None for field in _GROUP_OVERRIDE_FIELDS):
                await session.delete(override)
    await session.commit()
    await session.refresh(group)
    await _attach_group_overrides(session, caller, [group])
    return group


async def _remove_group_receipts(session: AsyncSession, group_id: UUID) -> None:
    """Best-effort MinIO cleanup of a group's expense receipts (the DB rows cascade on expense/group delete)."""
    keys = await session.scalars(
        select(Receipt.object_key)
        .join(Expense, Receipt.expense_id == Expense.id)
        .where(Expense.group_id == group_id)
    )
    for key in keys:
        try:
            await asyncio.to_thread(minio_client.remove, key)
        except Exception:
            log.warning("receipt object cleanup failed (key=%s)", key, exc_info=True)  # don't block the delete


async def _hard_delete_group(session: AsyncSession, group: Group) -> None:
    await _remove_group_receipts(session, group.id)
    avatar_keys = avatar_object_keys(group)  # capture before the row (and its keys) is gone
    await session.delete(group)
    await session.commit()
    await remove_avatar_objects(avatar_keys)  # best-effort, after commit, so a delete doesn't orphan images


async def _soft_delete_splitwise_group(session: AsyncSession, group: Group) -> None:
    """Flag a Splitwise group deleted (restorable) and drop its expenses (gone on Splitwise; restore re-syncs
    them). Keeps the shared group row + members so any member can restore. Commits."""
    await _remove_group_receipts(session, group.id)
    await session.execute(delete(Expense).where(Expense.group_id == group.id))
    group.deleted_at = datetime.now(timezone.utc)
    await session.commit()


@router.delete("/{group_id}", status_code=204)
async def delete_group(
    group_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    group = await session.get(Group, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="Group not found")
    await assert_group_member(session, group_id, caller)
    if group.backend_type == BackendType.splitwise:
        if not group.splitwise_group_id:
            raise HTTPException(status_code=400, detail="Splitwise group is missing splitwise_group_id")
        token = await _push_token(session, caller)
        client = sw_client.make_client(token.access_token)
        try:
            await asyncio.to_thread(sw_client.delete_group, client, group.splitwise_group_id)
        except Exception as exc:  # SDK / upstream Splitwise error
            raise HTTPException(status_code=502, detail=f"Splitwise rejected the request: {exc}")
        # Restorable: keep the shared row (+ members) flagged so any member can undo. (Self-hosted is final.)
        await _soft_delete_splitwise_group(session, group)
    else:
        await _hard_delete_group(session, group)


@router.post("/{group_id}/restore", response_model=GroupResponse)
async def restore_group(
    group_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Group:
    """Restore a deleted Splitwise group (undelete on Splitwise + its expenses, clear the flag, re-sync). Any
    member of the group can call this."""
    group = await session.get(Group, group_id)
    if group is None or group.deleted_at is None:
        raise HTTPException(status_code=404, detail="No deleted group to restore")
    await assert_group_member(session, group_id, caller)
    if not group.splitwise_group_id:
        raise HTTPException(status_code=400, detail="Splitwise group is missing splitwise_group_id")
    token = await _push_token(session, caller)
    try:
        await asyncio.to_thread(sw_client.restore_group, token.access_token, group.splitwise_group_id)
    except Exception as exc:  # upstream Splitwise error
        raise HTTPException(status_code=502, detail=f"Splitwise rejected the request: {exc}")
    group.deleted_at = None
    await session.commit()
    await _sync_splitwise_group(session, token, group.splitwise_group_id)
    await importer.sync_expenses(
        session, sw_client.make_client(token.access_token), settings.splitwise_user_map,
        group_id=group.splitwise_group_id,
    )
    await session.refresh(group)
    await _attach_group_overrides(session, caller, [group])
    return group


@router.get("/{group_id}/members", response_model=list[GroupMemberResponse])
async def list_members(
    group_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[GroupMember]:
    await assert_group_member(session, group_id, caller)
    rows = await session.scalars(
        select(GroupMember)
        .where(GroupMember.group_id == group_id)
        .order_by(GroupMember.user_identifier)
    )
    return list(rows)


@router.post("/{group_id}/members", response_model=GroupMemberResponse, status_code=201)
async def add_member(
    group_id: UUID,
    body: GroupMemberCreate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> GroupMember:
    group = await session.get(Group, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="Group not found")
    await assert_group_member(session, group_id, caller)

    if group.backend_type == BackendType.splitwise:
        return await _add_splitwise_member(session, group, body, caller)

    # Self-hosted: local roster only.
    if not body.user_identifier:
        raise HTTPException(status_code=422, detail="user_identifier is required")
    existing = await session.scalar(
        select(GroupMember).where(
            GroupMember.group_id == group_id,
            GroupMember.user_identifier == body.user_identifier,
        )
    )
    if existing is not None:
        return existing
    member = GroupMember(group_id=group_id, user_identifier=body.user_identifier)
    # Insert inside a savepoint: a concurrent add of the same member trips uq_group_members_group_user; adopt
    # the winner instead of an unhandled IntegrityError -> 500 (idempotent add). Mirrors create_expense.
    try:
        async with session.begin_nested():
            session.add(member)
    except IntegrityError:
        return await session.scalar(
            select(GroupMember).where(
                GroupMember.group_id == group_id,
                GroupMember.user_identifier == body.user_identifier,
            )
        )
    await session.commit()
    await session.refresh(member)
    return member


async def _add_splitwise_member(
    session: AsyncSession, group: Group, body: GroupMemberCreate, caller: str | None
) -> GroupMember:
    """Add a member to a Splitwise group by roster id (resolve their splitwise_user_id) or by email
    (invite), propagate to Splitwise, then sync the membership back and return the new local row."""
    if not group.splitwise_group_id:
        raise HTTPException(status_code=400, detail="Splitwise group is missing splitwise_group_id")
    token = await _push_token(session, caller)
    client = sw_client.make_client(token.access_token)
    kwargs: dict = {}
    target_identifier = body.user_identifier
    if body.user_identifier:
        swid = await session.scalar(
            select(User.splitwise_user_id).where(User.identifier == body.user_identifier)
        )
        if not swid:
            raise HTTPException(status_code=422, detail="That person has no Splitwise account to add")
        kwargs = {"user_id": swid}
    elif body.email:
        kwargs = {"email": body.email, "first_name": body.first_name, "last_name": body.last_name}
    else:
        raise HTTPException(status_code=422, detail="user_identifier or email is required")
    try:
        added = await asyncio.to_thread(
            sw_client.add_user_to_group, client, group.splitwise_group_id, **kwargs
        )
    except Exception as exc:  # SDK / upstream Splitwise error
        raise HTTPException(status_code=502, detail=f"Splitwise rejected the request: {exc}")
    if target_identifier is None and added is not None:  # invited-by-email → resolve the returned user
        target_identifier = await importer._resolve_identifier(
            session, splitwise_user_id=added["splitwise_id"], first_name=added.get("first_name", ""),
            email=added.get("email"), user_map=settings.splitwise_user_map,
        )
    await _sync_splitwise_group(session, token, group.splitwise_group_id)
    member = await session.scalar(
        select(GroupMember).where(
            GroupMember.group_id == group.id, GroupMember.user_identifier == target_identifier
        )
    )
    if member is None:
        raise HTTPException(status_code=502, detail="Member added on Splitwise but did not sync back")
    return member


@router.delete("/{group_id}/members/{user_identifier}", status_code=204)
async def remove_member(
    group_id: UUID,
    user_identifier: str,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    group = await session.get(Group, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="Group not found")
    await assert_group_member(session, group_id, caller)
    member = await session.scalar(
        select(GroupMember).where(
            GroupMember.group_id == group_id,
            GroupMember.user_identifier == user_identifier,
        )
    )
    if member is None:
        raise HTTPException(status_code=404, detail="Member not found")

    if group.backend_type == BackendType.splitwise:
        if not group.splitwise_group_id:
            raise HTTPException(status_code=400, detail="Splitwise group is missing splitwise_group_id")
        swid = await session.scalar(
            select(User.splitwise_user_id).where(User.identifier == user_identifier)
        )
        if not swid:
            raise HTTPException(status_code=422, detail="That member has no Splitwise account")
        token = await _push_token(session, caller)
        try:
            await asyncio.to_thread(
                sw_client.remove_user_from_group, token.access_token, group.splitwise_group_id, swid
            )
        except Exception as exc:  # SDK / upstream Splitwise error
            raise HTTPException(status_code=502, detail=f"Splitwise rejected the request: {exc}")

    await session.delete(member)
    await session.commit()
