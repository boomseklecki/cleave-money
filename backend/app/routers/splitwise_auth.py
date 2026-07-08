import asyncio

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import RedirectResponse
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth, tokens
from app.auth.identity import resolve_user
from app.db import get_session
from app import server_settings
from app.integrations.splitwise import importer
from app.integrations.splitwise.client import get_current_user, make_client
from app.integrations.splitwise.oauth import build_authorize_url, exchange_code
from app.integrations.splitwise.pkce import (
    code_challenge_s256,
    generate_code_verifier,
    generate_state,
)
from app.models import SplitwiseOAuthState, SplitwiseToken
from app.ratelimit import rate_limit
from app.schemas.auth import SplitwiseAuthStart

router = APIRouter(prefix="/auth/splitwise", tags=["splitwise-auth"])


def _new_state(session: AsyncSession, *, user_identifier: str, invite: str | None) -> str:
    """Create an OAuth state row and return its Splitwise authorize URL. `user_identifier` is the local id the
    resulting Splitwise token binds to ("" = derive from the resolved Splitwise identity at callback)."""
    verifier = generate_code_verifier()
    state = generate_state()
    session.add(SplitwiseOAuthState(
        state=state, code_verifier=verifier, user_identifier=user_identifier, invite=invite))
    return build_authorize_url(state, code_challenge_s256(verifier))


@router.post("/start", response_model=SplitwiseAuthStart,
             dependencies=[Depends(rate_limit(15, 3600))])
async def start(
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> SplitwiseAuthStart:
    """Begin connecting Splitwise to the *signed-in* user. The OAuth state is bound to the verified caller
    server-side (no client-supplied identifier), so the resulting token can only attach to the caller."""
    authorize_url = _new_state(session, user_identifier=caller or "", invite=None)
    await session.commit()
    return SplitwiseAuthStart(authorize_url=authorize_url)


@router.get("/login", dependencies=[Depends(rate_limit(15, 3600))])
async def login(invite: str | None = None, session: AsyncSession = Depends(get_session)):
    """Anonymous *sign in with Splitwise* (first-time). The token binds to the user resolved from the Splitwise
    identity at callback; `invite` enrolls a new user on a claimed server. No caller-supplied identifier."""
    authorize_url = _new_state(session, user_identifier="", invite=invite)
    await session.commit()
    return RedirectResponse(authorize_url)


@router.get("/callback")
async def callback(code: str, state: str, session: AsyncSession = Depends(get_session)):
    pending = await session.get(SplitwiseOAuthState, state)
    if pending is None:
        raise HTTPException(status_code=400, detail="Unknown or expired OAuth state")

    bound_caller = pending.user_identifier  # "" for the anonymous login flow → bind to the resolved identity
    invite = pending.invite
    token_data = await asyncio.to_thread(exchange_code, code, pending.code_verifier)
    access_token = token_data.get("access_token")
    if not access_token:
        raise HTTPException(status_code=502, detail="Splitwise returned no access token")

    # Resolve the Splitwise identity into a User and mint our own session JWT.
    client = make_client(access_token)
    sw_user = await asyncio.to_thread(get_current_user, client)
    full_name = f"{sw_user['first_name']} {sw_user['last_name']}".strip()
    user = await resolve_user(
        session,
        provider="splitwise",
        sub=sw_user["splitwise_id"],
        email=sw_user.get("email"),
        name=full_name or None,
        avatar=sw_user.get("picture"),
        invite_code=invite,
    )

    # Bind the Splitwise token to the verified caller (connect flow) or the resolved user (login flow) - 
    # never to a client-supplied value.
    bind = bound_caller or user.identifier
    values = {
        "user_identifier": bind,
        "access_token": access_token,
        "token_type": token_data.get("token_type", "bearer"),
        "scope": token_data.get("scope"),
    }
    await session.execute(
        pg_insert(SplitwiseToken)
        .values(**values)
        .on_conflict_do_update(
            index_elements=[SplitwiseToken.user_identifier],
            set_={k: values[k] for k in ("access_token", "token_type", "scope")},
        )
    )
    await session.delete(pending)
    await session.commit()

    # Seed the activity feed so a freshly connected account isn't empty (up to the retention window, for
    # auditing). Best-effort: never let it break the OAuth redirect. push=False - the backfill must not flood.
    try:
        retention = int(await server_settings.get(session, "notifications_retention_count"))
        await importer.sync_notifications(
            session, client, bind, retention=retention, access_token=access_token, push=False)
    except Exception:
        await session.rollback()

    # Hand the JWT back to the iOS app via the custom scheme it catches in ASWebAuthenticationSession.
    return RedirectResponse(f"cleave://auth?token={tokens.issue(user)}")
