import base64
import binascii
import logging
import secrets
from contextlib import asynccontextmanager

import httpx
from fastapi import Depends, FastAPI, Form, Header, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

from app import apns, db, ratelimit
from app.config import settings

log = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init()
    yield


app = FastAPI(title="Cleave Push Relay", lifespan=lifespan)


def require_key(authorization: str | None = Header(default=None)) -> None:
    key = authorization.removeprefix("Bearer ").strip() if authorization else ""
    if not key or not db.valid_key(key):
        raise HTTPException(status_code=401, detail="Invalid API key")
    ratelimit.check(f"push:{db.hash_key(key)}", settings.push_max_per_minute, 60)


_CHALLENGE = {"WWW-Authenticate": 'Basic realm="Cleave Relay Admin"'}


def require_admin(authorization: str | None = Header(default=None)) -> None:
    """Accepts `Bearer <admin_token>` (curl) or Basic auth (browser); password == admin_token."""
    if not settings.admin_token:
        raise HTTPException(status_code=403, detail="Admin only")
    header = authorization or ""
    if header.startswith("Basic "):
        try:
            user, _, password = base64.b64decode(header[6:]).decode().partition(":")
        except (binascii.Error, UnicodeDecodeError):
            user = password = ""
        if secrets.compare_digest(user, settings.admin_user) and \
                secrets.compare_digest(password, settings.admin_token):
            return
    else:
        token = header.removeprefix("Bearer ").strip()
        if token and secrets.compare_digest(token, settings.admin_token):
            return
    raise HTTPException(status_code=401, detail="Admin only", headers=_CHALLENGE)


class EncMessage(BaseModel):
    token: str
    epk: str
    box: str


class PushRequest(BaseModel):
    # Plaintext form (back-compat): relay sees the content.
    tokens: list[str] = []
    title: str = "Cleave"
    body: str = ""
    # E2E form: per-device ciphertext + a generic fallback alert. Relay stays blind.
    messages: list[EncMessage] = []
    fallback_title: str = "Cleave"
    fallback_body: str = "New activity"


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "apns_configured": settings.apns_configured}


@app.post("/push")
async def push(body: PushRequest, _: None = Depends(require_key)) -> dict:
    """Forwards alerts to APNs (encrypted `messages` and/or plaintext `tokens`); returns dead tokens to
    prune. With `RELAY_REQUIRE_E2EE`, plaintext pushes are refused so the relay only ever sees ciphertext."""
    if not settings.apns_configured:
        raise HTTPException(status_code=503, detail="Relay APNs is not configured")
    if settings.require_e2ee and body.tokens:
        raise HTTPException(status_code=400, detail="This relay accepts only E2E-encrypted pushes")
    dead: list[str] = []
    async with httpx.AsyncClient(http2=True, timeout=10) as client:
        for m in body.messages:
            if await apns.send_encrypted(client, m.token, body.fallback_title, body.fallback_body,
                                         m.epk, m.box):
                dead.append(m.token)
        for token in body.tokens:
            if await apns.send(client, token, body.title, body.body):
                dead.append(token)
    return {"dead": dead}


_FORM = """<!doctype html><meta charset=utf-8><title>Cleave Push Relay</title>
<body style="font-family:system-ui;max-width:34rem;margin:3rem auto;padding:0 1rem;line-height:1.5">
<h1>Cleave push relay</h1>
<p>Register your self-hosted Cleave instance to send push through the official app.
The key is shown once - copy it.</p>
<form method=post action=/register>
<p><input name=email type=email required placeholder="you@example.com" style="width:100%;padding:.5rem"></p>
<p><input name=instance placeholder="instance name (optional)" style="width:100%;padding:.5rem"></p>
<p><button type=submit style="padding:.5rem 1rem">Get an API key</button></p>
</form></body>"""


def _page(inner: str) -> HTMLResponse:
    return HTMLResponse("<!doctype html><meta charset=utf-8><body style='font-family:system-ui;"
                        f"max-width:34rem;margin:3rem auto;padding:0 1rem;line-height:1.5'>{inner}</body>")


_ADMIN = """<!doctype html><meta charset=utf-8><title>Cleave Relay Admin</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<style>
 body{font-family:system-ui;max-width:60rem;margin:2rem auto;padding:0 1rem;line-height:1.5;color-scheme:light dark}
 table{border-collapse:collapse;width:100%;margin:1rem 0}
 th,td{text-align:left;padding:.4rem .6rem;border-bottom:1px solid #8883;font-size:.9rem}
 th{font-weight:600}
 .badge{font-size:.75rem;padding:.1rem .5rem;border-radius:1rem;white-space:nowrap}
 .active{background:#1a7f371a;color:#1a7f37}
 .pending{background:#9a6c001a;color:#9a6700}
 .revoked{background:#cf222e1a;color:#cf222e}
 button{padding:.25rem .6rem;margin-right:.3rem;font-size:.8rem;cursor:pointer}
 form{margin:1.5rem 0;padding:1rem;border:1px solid #8884;border-radius:.5rem}
 input{padding:.45rem;margin-right:.5rem}
 pre{padding:1rem;background:#8881;overflow:auto;user-select:all}
 .muted{color:#8889;font-size:.85rem}
</style>
<body>
<h1>Cleave relay &mdash; API keys</h1>
<p class=muted>Keys self-hosted backends use to send push. The plaintext key is only ever shown once, at issue time.</p>
<form id=issue onsubmit="return issue(event)">
 <strong>Issue a new key</strong> &mdash; active immediately.<br><br>
 <input name=email type=email required placeholder="you@example.com">
 <input name=instance placeholder="instance name (optional)">
 <button type=submit>Issue key</button>
</form>
<div id=issued></div>
<table><thead><tr><th>Instance / email<th>Status<th>Created<th>Last used<th>Pushes<th>Actions</tr></thead>
<tbody id=rows></tbody></table>
<script>
async function api(path, method){
  const r = await fetch(path, {method: method||"GET", headers:{"Content-Type":"application/json"}});
  if(r.status===401){ location.reload(); throw new Error("auth"); }
  if(!r.ok) throw new Error((await r.json().catch(()=>({}))).detail || r.status);
  return r.json();
}
function esc(s){ return (s==null?"":String(s)).replace(/[&<>"]/g, c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }
function when(s){ return s ? new Date(s).toLocaleString() : "\\u2014"; }
function status(k){ return !k.approved ? "pending" : (k.active ? "active" : "revoked"); }
async function act(id, verb){
  try{
    if(verb==="delete"){ if(!confirm("Delete key #"+id+"? This cannot be undone.")) return; await api("/admin/keys/"+id,"DELETE"); }
    else await api("/admin/keys/"+id+"/"+verb,"POST");
    load();
  }catch(e){ if(e.message!=="auth") alert("Failed: "+e.message); }
}
function actions(k){
  const s=status(k), b=[];
  if(s==="pending") b.push(`<button onclick="act(${k.id},'approve')">Approve</button>`);
  if(s==="active")  b.push(`<button onclick="act(${k.id},'revoke')">Revoke</button>`);
  if(s==="revoked") b.push(`<button onclick="act(${k.id},'approve')">Reactivate</button>`);
  b.push(`<button onclick="act(${k.id},'delete')">Delete</button>`);
  return b.join("");
}
async function load(){
  try{
    const {keys} = await api("/admin/keys");
    document.getElementById("rows").innerHTML = keys.length ? keys.map(k=>{
      const s=status(k);
      return `<tr><td><strong>${esc(k.instance||"\\u2014")}</strong><br><span class=muted>${esc(k.email)}</span></td>`+
        `<td><span class="badge ${s}">${s}</span></td><td>${when(k.created_at)}</td>`+
        `<td>${when(k.last_used_at)}</td><td>${k.push_count}</td><td>${actions(k)}</td></tr>`;
    }).join("") : `<tr><td colspan=6 class=muted>No keys yet.</td></tr>`;
  }catch(e){ if(e.message!=="auth") document.getElementById("rows").innerHTML=`<tr><td colspan=6>Error: ${esc(e.message)}</td></tr>`; }
}
async function issue(ev){
  ev.preventDefault();
  const f=ev.target, email=f.email.value, instance=f.instance.value;
  try{
    const r = await fetch("/admin/keys",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({email,instance})});
    if(r.status===401){ location.reload(); return false; }
    if(!r.ok){ alert("Failed: "+((await r.json().catch(()=>({}))).detail||r.status)); return false; }
    const {key} = await r.json();
    document.getElementById("issued").innerHTML =
      `<p><strong>New key for ${esc(email)} &mdash; copy it now, shown once:</strong></p><pre>${esc(key)}</pre>`+
      `<p class=muted>Set on the backend as <code>PUSH_RELAY_API_KEY</code> (with <code>PUSH_RELAY_URL</code>).</p>`;
    f.reset(); load();
  }catch(e){ alert("Failed: "+e.message); }
  return false;
}
load();
</script></body>"""


@app.get("/", response_class=HTMLResponse)
def form() -> str:
    return _FORM


@app.post("/register")
async def register(request: Request, email: str = Form(...), instance: str = Form("")) -> HTMLResponse:
    ratelimit.check(f"register:{ratelimit.client_ip(request)}", settings.register_max_per_hour, 3600)
    key = db.create_key(email, instance or None)
    if settings.relay_auto_issue:
        return _page(
            "<p><strong>Your API key (copy it now - shown once):</strong></p>"
            f"<pre style='padding:1rem;background:#f4f4f4;overflow:auto'>{key}</pre>"
            "<p>Set it on your Cleave backend as <code>PUSH_RELAY_API_KEY</code> "
            "(with <code>PUSH_RELAY_URL</code>).</p>")
    return _page("<p>Request received - your key will activate once it's approved.</p>")


class IssueKey(BaseModel):
    email: str
    instance: str = ""


@app.get("/admin", response_class=HTMLResponse)
def admin_page(_: None = Depends(require_admin)) -> str:
    return _ADMIN


@app.get("/admin/keys")
def list_keys(_: None = Depends(require_admin)) -> dict:
    return {"keys": db.list_keys()}


@app.post("/admin/keys")
def issue_key(body: IssueKey, _: None = Depends(require_admin)) -> dict:
    key = db.create_key(body.email, body.instance or None, approved=True)
    return {"key": key}


@app.post("/admin/keys/{key_id}/approve")
def approve(key_id: int, _: None = Depends(require_admin)) -> dict:
    if not db.set_flags(key_id, approved=1, active=1):
        raise HTTPException(status_code=404, detail="Key not found")
    return {"ok": True}


@app.post("/admin/keys/{key_id}/revoke")
def revoke(key_id: int, _: None = Depends(require_admin)) -> dict:
    if not db.set_flags(key_id, active=0):
        raise HTTPException(status_code=404, detail="Key not found")
    return {"ok": True}


@app.delete("/admin/keys/{key_id}")
def delete(key_id: int, _: None = Depends(require_admin)) -> dict:
    if not db.delete_key(key_id):
        raise HTTPException(status_code=404, detail="Key not found")
    return {"ok": True}
