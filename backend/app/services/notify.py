"""The app-source notification PRODUCER: writes `Notification(source=app)` rows on shared events and fires a
push. Best-effort - a notification failure must never break the triggering mutation."""
import logging
from uuid import UUID

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import server_settings
from app.models import GroupMember, Notification, NotificationMute, User
from app.models.enums import NotificationSource
from app.services import push

log = logging.getLogger(__name__)


async def push_muted_owners(session: AsyncSession, owners: set[str], type: str, source: str) -> set[str]:
    """Of `owners`, those who've muted PUSH for this notification's type or its source (`push:` tokens).
    `feed:` tokens are client-side display prefs and are intentionally ignored here."""
    if not owners:
        return set()
    tokens = {f"push:{type}", f"push:source:{source}"}
    return set(await session.scalars(
        select(NotificationMute.owner_identifier).where(
            NotificationMute.owner_identifier.in_(owners), NotificationMute.token.in_(tokens))))


async def group_recipients(session: AsyncSession, group_id: UUID) -> set[str]:
    """All members of a group (by identifier)."""
    return set(await session.scalars(
        select(GroupMember.user_identifier).where(GroupMember.group_id == group_id)))


async def display_name(session: AsyncSession, identifier: str | None) -> str:
    if not identifier:
        return "Someone"
    user = await session.scalar(select(User).where(User.identifier == identifier))
    return user.display_name if (user and user.display_name) else identifier


async def notify(session: AsyncSession, recipients: set[str], type: str, content: str,
                 actor: str | None = None, entity_type: str | None = None,
                 entity_id: str | None = None) -> None:
    """Insert an `app` notification per recipient (minus the actor), prune to retention, push. Never raises.
    `entity_type`/`entity_id` are the deep-link target (the Inbox row + a tapped push route to it)."""
    targets = {r for r in recipients if r and r != actor}
    if not targets:
        return
    try:
        retention = int(await server_settings.get(session, "notifications_retention_count"))
        # Everyone gets the feed row (the audit log stays complete); only push goes to non-push-muted owners.
        muted = await push_muted_owners(session, targets, type, NotificationSource.app.value)
        for owner in targets:
            session.add(Notification(owner_identifier=owner, source=NotificationSource.app,
                                     type=type, content=content,
                                     entity_type=entity_type, entity_id=entity_id))
        await session.flush()
        for owner in targets:
            keep = (select(Notification.id).where(Notification.owner_identifier == owner)
                    .order_by(Notification.created_at.desc()).limit(retention))
            await session.execute(delete(Notification).where(
                Notification.owner_identifier == owner, Notification.id.not_in(keep)))
        await session.commit()
    except Exception:
        log.exception("notify failed")
        await session.rollback()  # clear the failed tx so the caller's session stays usable (its write already committed)
        return
    target = {"type": entity_type, "id": entity_id} if (entity_type and entity_id) else None
    push.enqueue(targets - muted, "Cleave", content, target=target)
