from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path
import json
import logging

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
import uvicorn

from .config import Settings
from .db import Database
from .exporter import ExportManager
from .provider import ChatGPTClient, AuthenticationRequired, ProviderError, ProviderHTTPError
from .security import SecretStore, constant_time_equal, load_admin_token, require_access_token

LOG = logging.getLogger("chatgpt_export")

settings = Settings.load()
settings.ensure_dirs()
db = Database(settings.state_dir / "state.sqlite3")
secret_store = SecretStore(settings.key_file, settings.state_dir / "session.enc")
admin_token = load_admin_token(settings.admin_token_file)
manager = ExportManager(settings, db)


def _auth(value: str | None) -> None:
    if not value or not constant_time_equal(value, admin_token):
        raise HTTPException(status_code=401, detail="invalid admin token")


def _load_session() -> dict | None:
    return secret_store.load_session()


async def _validate_chatgpt_session(token: str) -> int:
    client = ChatGPTClient(token, settings)
    try:
        raw = await client.accounts()
        accounts = raw.get("accounts") if isinstance(raw, dict) else None
        values = accounts.values() if isinstance(accounts, dict) else accounts if isinstance(accounts, list) else []
        active = 0
        for item in values:
            if not isinstance(item, dict) or item.get("is_deactivated") is True:
                continue
            account = item.get("account") if isinstance(item.get("account"), dict) else item
            if isinstance(account, dict) and isinstance(account.get("account_id"), str) and account["account_id"]:
                active += 1
        if active == 0:
            raise HTTPException(status_code=422, detail="ChatGPT returned no active account/workspace scopes")
        return active
    except AuthenticationRequired as exc:
        raise HTTPException(status_code=401, detail="ChatGPT rejected this session; copy a fresh /api/auth/session JSON") from exc
    except ProviderHTTPError as exc:
        raise HTTPException(status_code=502, detail=f"ChatGPT rejected the server-side session check (HTTP {exc.status})") from exc
    except ProviderError as exc:
        raise HTTPException(status_code=502, detail=f"ChatGPT session preflight failed ({exc.code})") from exc
    finally:
        await client.aclose()


@asynccontextmanager
async def lifespan(app: FastAPI):
    latest = db.latest_job()
    if latest and latest.get("status") in {"QUEUED", "RUNNING"}:
        db.update_job(latest["id"], status="INTERRUPTED", error_code="SERVICE_RESTART", error_message="Service restarted before the export reached a terminal state; a resumable replacement run will be started when possible.")
        try:
            session = _load_session()
            if session:
                token = require_access_token(session)
                await manager.start(token)
                LOG.warning("Resumed an interrupted export as a new durable run")
        except Exception as exc:
            LOG.error("Could not auto-resume interrupted export: %s", type(exc).__name__)
    yield


app = FastAPI(title="ChatGPT Export", version="0.1.0", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
static_dir = Path(__file__).parent / "static"
app.mount("/static", StaticFiles(directory=static_dir), name="static")


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    return response


@app.get("/", response_class=HTMLResponse)
async def index():
    return FileResponse(static_dir / "index.html", media_type="text/html")


@app.get("/healthz")
async def healthz():
    return {"ok": True, "service": "chatgpt-export", "active_export": manager.active()}


@app.get("/api/status")
async def status(x_admin_token: str | None = Header(default=None)):
    _auth(x_admin_token)
    latest = db.latest_job()
    try:
        connected = _load_session() is not None
        session_error = None
    except RuntimeError:
        connected = False
        session_error = "stored session is unreadable; import a fresh session"
    return {"connected": connected, "session_error": session_error, "active": manager.active(), "latest": latest}


@app.post("/api/session")
async def set_session(request: Request, x_admin_token: str | None = Header(default=None)):
    _auth(x_admin_token)
    raw = await request.body()
    if len(raw) > 2_000_000:
        raise HTTPException(status_code=413, detail="session payload too large")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=400, detail="invalid JSON") from exc
    if isinstance(payload, dict) and isinstance(payload.get("session"), str):
        try:
            payload = json.loads(payload["session"])
        except json.JSONDecodeError as exc:
            raise HTTPException(status_code=400, detail="session field is not valid JSON") from exc
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="session must be a JSON object")
    try:
        token = require_access_token(payload)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    workspace_count = await _validate_chatgpt_session(token)
    secret_store.save_session(payload)
    job_id = await manager.start(token)
    return {"ok": True, "job_id": job_id, "workspaces": workspace_count, "message": "Session verified; full export started."}


@app.post("/api/export")
async def start_export(x_admin_token: str | None = Header(default=None)):
    _auth(x_admin_token)
    try:
        session = _load_session()
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail="stored session is unreadable; import a fresh session") from exc
    if not session:
        raise HTTPException(status_code=409, detail="no ChatGPT session has been imported")
    try:
        token = require_access_token(session)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail="stored session is invalid; import a fresh session") from exc
    job_id = await manager.start(token)
    return {"ok": True, "job_id": job_id}


@app.delete("/api/session")
async def clear_session(x_admin_token: str | None = Header(default=None)):
    _auth(x_admin_token)
    if manager.active():
        raise HTTPException(status_code=409, detail="cannot clear the session while an export is active")
    secret_store.clear_session()
    return {"ok": True}


@app.exception_handler(Exception)
async def unhandled_error(request: Request, exc: Exception):
    LOG.exception("Unhandled server error: %s", type(exc).__name__)
    return JSONResponse(status_code=500, content={"detail": "internal server error"})


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    uvicorn.run(app, host=settings.bind_host, port=settings.bind_port, log_level="info", access_log=False)


if __name__ == "__main__":
    main()
