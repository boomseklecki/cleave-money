from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import server_settings
from app.auth import require_auth
from app.auth.scope import assert_owner, audience
from app.config import settings
from app.db import get_session
from app.models import User
from app.models.goal import Goal
from app.schemas.goal import GoalCreate, GoalResponse, GoalUpdate
from app.services import notify as notify_svc

router = APIRouter(tags=["goals"])


@router.post("/goals", response_model=GoalResponse, status_code=201)
async def create_goal(
    body: GoalCreate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Goal:
    goal = Goal(
        kind=body.kind,
        name=body.name,
        category=body.category,
        account_id=body.account_id,
        target_amount=body.target_amount,
        save_target_type=body.save_target_type,
        starting_balance=body.starting_balance,
        starting_date=body.starting_date,
        period=body.period,
        currency=body.currency or str(await server_settings.get(session, "default_currency")),
        shared=body.shared,
        owner_identifier=caller,
    )
    session.add(goal)
    await session.commit()
    await session.refresh(goal)
    if goal.shared:
        actor = await notify_svc.display_name(session, caller)
        await notify_svc.notify(session, await audience(session, caller), "goal_shared",
                                f"{actor} shared a budget: {goal.name}", actor=caller,
                                entity_type="goal", entity_id=str(goal.id))
    goal.shared_by = goal.shared_by_identifier = None
    return goal


@router.get("/goals", response_model=list[GoalResponse])
async def list_goals(
    include_archived: bool = False,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Goal]:
    stmt = select(Goal)
    if caller is not None:
        stmt = stmt.where(Goal.owner_identifier == caller)
    if not include_archived:
        stmt = stmt.where(Goal.archived_at.is_(None))
    rows = list(await session.scalars(stmt.order_by(Goal.created_at.desc())))
    for g in rows:  # own goals
        g.shared_by = g.shared_by_identifier = None

    # Plus goals a partner has marked shared (read-only, active only), tagged with the owner's name.
    aud = await audience(session, caller)
    if aud:
        shared = list(await session.scalars(
            select(Goal).where(
                Goal.owner_identifier.in_(aud), Goal.shared.is_(True), Goal.archived_at.is_(None)
            ).order_by(Goal.created_at.desc())
        ))
        owners = {u.identifier: u for u in await session.scalars(
            select(User).where(User.identifier.in_({g.owner_identifier for g in shared})))}
        for g in shared:
            owner = owners.get(g.owner_identifier)
            g.shared_by = owner.display_name if owner else g.owner_identifier
            g.shared_by_identifier = g.owner_identifier
        rows += shared
    return rows


async def _get_owned_or_404(session: AsyncSession, goal_id: UUID, caller: str | None) -> Goal:
    goal = await session.get(Goal, goal_id)
    if goal is None:
        raise HTTPException(status_code=404, detail="Goal not found")
    assert_owner(goal.owner_identifier, caller)
    return goal


@router.patch("/goals/{goal_id}", response_model=GoalResponse)
async def update_goal(
    goal_id: UUID,
    body: GoalUpdate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Goal:
    goal = await _get_owned_or_404(session, goal_id, caller)
    was_shared = goal.shared
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(goal, field, value)
    await session.commit()
    await session.refresh(goal)
    if goal.shared and not was_shared:
        actor = await notify_svc.display_name(session, caller)
        await notify_svc.notify(session, await audience(session, caller), "goal_shared",
                                f"{actor} shared a budget: {goal.name}", actor=caller,
                                entity_type="goal", entity_id=str(goal.id))
    goal.shared_by = goal.shared_by_identifier = None
    return goal


@router.delete("/goals/{goal_id}", status_code=204)
async def delete_goal(
    goal_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    goal = await _get_owned_or_404(session, goal_id, caller)
    goal.archived_at = datetime.now(timezone.utc)
    await session.commit()
