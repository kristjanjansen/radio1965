"""
Minimal FastAPI server exposing FCM push notification endpoints.

Run from the repo root with:
    source server/set_env.sh
    SEND_TEST_NOTIFICATION=1 uvicorn server.main:app --reload
"""

import logging
import logging.handlers
import os
import re
import secrets
import time
from datetime import datetime, timedelta
from urllib.parse import urljoin

import bcrypt
import requests
from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from server import config, db, emailer, joomla_importer, notifications, remote_files

# Minimal responsive wrapper for Joomla's article "text" field (a bare HTML
# fragment with no viewport meta/CSS of its own) - see GET /articles/{id}.
ARTICLE_HTML_TEMPLATE = """<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{{font-family:sans-serif;padding:8px}}img,video,iframe{{max-width:100%;height:auto}}</style>
</head><body>{body}</body></html>"""

# Matches src="..."/href="..." (single or double quotes) whose value isn't
# already absolute (http(s)://, data:, or a #fragment).
_RELATIVE_URL_ATTR = re.compile(r"""(src|href)=(["'])(?!https?://|data:|#)([^"']+)\2""", re.IGNORECASE)


def _absolutize_urls(html: str, base: str) -> str:
    """
    Rewrite relative src/href attributes (e.g. Joomla's "images/foo.jpg") to
    absolute URLs against `base`. WebView.loadHtml(html, baseUrl)'s own
    relative-URL resolution is what this replaces - it's unreliable on the
    Android WebView backend, which has shown percent-encoded content instead
    of rendering it when a baseUrl is passed (desktop is unaffected, so this
    is worked around at the content level instead of relying on the
    platform's loadHtml() implementation).
    """
    return _RELATIVE_URL_ATTR.sub(lambda m: f'{m.group(1)}={m.group(2)}{urljoin(base, m.group(3))}{m.group(2)}', html)

# Events default to being moved to the shelf one day after publish_at if the
# editor doesn't set an explicit shelf_at (see project-description.md #7).
DEFAULT_SHELF_DELAY = timedelta(days=1)


def _parse_datetime(value: str) -> datetime:
    """
    Parse a datetime string from the editor's <input type="datetime-local">
    (e.g. '2026-08-01T14:24') as naive local time - matching the server's
    own local clock, so it can be compared directly with datetime.now().
    """
    return datetime.fromisoformat(value)

# File logging, rotated at 5MB x5 backups. Attached directly to
# "uvicorn"/"uvicorn.access" (not just root/our own "server.main" logger)
# since uvicorn configures both of those with propagate=False by default -
# a plain logging.basicConfig() on the root logger alone never sees
# uvicorn's own request-access lines (the "INFO: ... POST
# /contributors/login HTTP/1.1 200 OK" lines), only ours. "uvicorn.error"
# is deliberately NOT included separately here - per uvicorn's own
# logging.config.LOGGING_CONFIG it has no handlers of its own and
# propagate defaults to True, so its records already flow into "uvicorn"
# on their own; adding this handler there *too* would double-write every
# uvicorn.error message. Added on top of whatever handler(s) each logger
# already has, not instead of - console output (wherever that currently
# goes) is unaffected.
os.makedirs(os.path.dirname(config.LOG_FILE), exist_ok=True)
_file_handler = logging.handlers.RotatingFileHandler(
    config.LOG_FILE, maxBytes=5_000_000, backupCount=5
)
_file_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
for _logger_name in ("", "uvicorn", "uvicorn.access"):
    _logger = logging.getLogger(_logger_name)
    _logger.addHandler(_file_handler)
    _logger.setLevel(logging.INFO)

logger = logging.getLogger(__name__)

app = FastAPI(title="Radio 1965 Notification Service")

# Dev-only: allows the test client (client/index.html), served from a
# different origin/port, to call this API. Restrict this before production.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def testNotification() -> None:
    """Send a test push notification to the TEST_TOPIC. Logs the result."""
    try:
        message_id = notifications.send_to_topic(
            topic=config.TEST_TOPIC,
            title="Test notification",
            body="Radio 1965 test notification",
            event_id="test",
        )
        logger.info("Test notification sent to topic '%s': %s", config.TEST_TOPIC, message_id)
    except Exception:
        logger.exception("Failed to send test notification to topic '%s'", config.TEST_TOPIC)


@app.on_event("startup")
def on_startup() -> None:
    notifications.init_firebase()
    db.Base.metadata.create_all(bind=db.engine)
    if config.SEND_TEST_NOTIFICATION:
        testNotification()
    else:
        logger.info("Test notification skipped (set SEND_TEST_NOTIFICATION=1 to enable)")


class TopicNotificationRequest(BaseModel):
    topic: str
    title: str
    body: str
    event_id: str


class MulticastNotificationRequest(BaseModel):
    tokens: list[str]
    title: str
    body: str
    event_id: str


class SubscribeRequest(BaseModel):
    token: str
    topic: str


# Used by verify_temporary_contributor_password() - app/Main.qml's
# "Temporary contributor" dialog (project-description.md #10.1).
class TemporaryContributorVerifyIn(BaseModel):
    password: str


# Used by register_contributor() - app/Main.qml's "Become a Contributor"
# dialog (project-description.md #10.2).
class ContributorRegisterIn(BaseModel):
    name: str
    email: str
    password: str


# Used by login_contributor()/request_password_reset()/reset_password() -
# contributor/index.html's login/forgot-password/reset-password views.
class ContributorLoginIn(BaseModel):
    email: str
    password: str


class ContributorForgotPasswordIn(BaseModel):
    email: str


class ContributorResetPasswordIn(BaseModel):
    token: str
    new_password: str


class ContributorDeleteIn(BaseModel):
    access_token: str


# Used by send_feedback() - app/Main.qml's "Send Feedback" dialog. Everything
# but text is optional context for the email.
class FeedbackIn(BaseModel):
    text: str
    email: str = ""  # optional, used as Reply-To
    name: str = ""
    role: str = ""
    app_version: str = ""
    platform: str = ""


# Used by finalize_recording() - server/icecast_on_disconnect.sh's POST once
# a "Save stream" recording (project-description.md #8.2.1) has finished
# uploading to eccm.ee.
class FinalizeRecordingIn(BaseModel):
    url: str
    type: str = "streamrecording"


# Mirrors the Event JSON schema (v2) + editor spec (project-description.md
# #4, #7). `status` is not client-settable - the server derives it from
# publish_now/publish_at (see publish_event()). Fields not in the v2 draft
# (e.g. source/source_ref for the future Joomla importer, or per-type extras
# like stream server address) should be nested inside payload instead of
# added here.
class EventIn(BaseModel):
    id: str | None = None
    type: str = "article"
    title: str
    summary: str
    url: str = ""
    publish_at: str | None = None
    publish_now: bool = False
    shelf_at: str | None = None
    tags: list[str] = Field(default_factory=list)
    payload: dict = Field(default_factory=dict)
    comments_enabled: bool = False
    # Opt out of the push while still publishing/listing the event - used by
    # server/icecast_on_connect.sh, forwarding BroadcastPage.qml's "Send
    # notification" checkbox (see IcecastBroadcaster::startBroadcast()).
    send_notification: bool = True
    # Identifies the publisher so publish_event() can set Event.author_id -
    # editor/index.html's logged-in session, or the app's broadcast flow
    # via icecast_on_connect.sh's ice-audio-info carrier. An unknown/absent
    # token just leaves author_id null, same as before this field existed.
    access_token: str | None = None


# manager/index.html - partial edit of an existing event. All fields
# optional except access_token: only whichever ones are actually present
# get applied (see update_event()). Deliberately excludes id/payload/
# author_id/tags/created_at/updated_at - those stay server-managed, not
# exposed as editable grid columns.
class EventPatchIn(BaseModel):
    access_token: str
    type: str | None = None
    title: str | None = None
    summary: str | None = None
    url: str | None = None
    status: str | None = None
    publish_at: str | None = None
    shelf_at: str | None = None
    comments_enabled: bool | None = None


# manager/index.html - partial edit of an existing user. Role is the only
# field a manager can change from that grid for now.
class UserPatchIn(BaseModel):
    access_token: str
    role: str | None = None


def _require_user(access_token: str, session: Session, roles: tuple[str, ...] = ("contributor", "manager")) -> db.User:
    """
    manager/index.html's auth gate - same opaque-access_token-lookup
    convention as GET /contributors/status, just also checking role.
    Raises 403 for both "no such token" and "wrong role" (not 401/404) -
    no need to distinguish them for this internal admin tool.
    """
    user = session.query(db.User).filter(db.User.access_token == access_token).one_or_none()
    if not user or user.role not in roles:
        raise HTTPException(status_code=403, detail="Not authorized")
    return user


@app.post("/notify/topic")
def notify_topic(req: TopicNotificationRequest):
    message_id = notifications.send_to_topic(req.topic, req.title, req.body, req.event_id)
    return {"message_id": message_id}


@app.post("/notify/multicast")
def notify_multicast(req: MulticastNotificationRequest):
    return notifications.send_to_many(req.tokens, req.title, req.body, req.event_id)


@app.post("/notify/test")
def notify_test():
    testNotification()
    return {"status": "sent"}


@app.post("/devices/subscribe")
def subscribe_device(req: SubscribeRequest):
    response = notifications.subscribe_to_topic([req.token], req.topic)
    return {"success_count": response.success_count, "failure_count": response.failure_count}


@app.post("/temporary-contributor/verify")
def verify_temporary_contributor_password(req: TemporaryContributorVerifyIn):
    """
    project-description.md #10.1: "Temporary contributor" - checked here
    (not locally in the app) against config.TEMPORARY_CONTRIBUTOR_PASSWORD_PATH,
    a plain-text file an admin can edit directly. Read fresh on every call
    (no caching) so an edit takes effect immediately, without restarting
    this server.
    """
    try:
        with open(config.TEMPORARY_CONTRIBUTOR_PASSWORD_PATH) as f:
            expected_password = f.read().strip()
    except OSError:
        logger.exception(
            "Could not read temporary contributor password file at '%s'",
            config.TEMPORARY_CONTRIBUTOR_PASSWORD_PATH,
        )
        raise HTTPException(status_code=500, detail="Server misconfigured") from None

    if not expected_password or req.password != expected_password:
        raise HTTPException(status_code=403, detail="Incorrect password")

    return {"ok": True}


FEEDBACK_MAX_LENGTH = 5000
FEEDBACK_RATE_LIMIT = 5  # messages per client IP...
FEEDBACK_RATE_WINDOW_SECONDS = 600  # ...per this many seconds
# In-memory only (resets on restart) - just enough to stop a stuck client
# or casual abuse from flooding the inbox.
_feedback_times_by_ip: dict[str, list[float]] = {}


@app.post("/feedback")
def send_feedback(req: FeedbackIn, request: Request):
    """
    The app's "Send Feedback" dialog - emails tester feedback to
    config.FEEDBACK_EMAIL, with the sender's email (if given) as Reply-To.
    """
    text = req.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="Feedback text is empty")
    if len(text) > FEEDBACK_MAX_LENGTH:
        raise HTTPException(status_code=413, detail="Feedback text is too long")

    client_ip = request.client.host if request.client else "unknown"
    now = time.time()
    recent = [t for t in _feedback_times_by_ip.get(client_ip, []) if now - t < FEEDBACK_RATE_WINDOW_SECONDS]
    if len(recent) >= FEEDBACK_RATE_LIMIT:
        raise HTTPException(status_code=429, detail="Too many feedback messages")
    recent.append(now)
    _feedback_times_by_ip[client_ip] = recent

    # Only a plausible single address goes into the Reply-To header.
    email = req.email.strip()
    reply_to = email if re.fullmatch(r"[^@\s]+@[^@\s]+", email) else None

    body = (
        f"{text}\n\n"
        f"---\n"
        f"Name: {req.name or '-'}\n"
        f"Email: {email or '-'}\n"
        f"Role: {req.role or '-'}\n"
        f"App version: {req.app_version or '-'}\n"
        f"Platform: {req.platform or '-'}\n"
    )
    logger.info("feedback received from %s (%s, %s)", email or client_ip, req.app_version, req.platform)
    try:
        emailer.send_email(
            config.FEEDBACK_EMAIL,
            f"VÄIN feedback ({req.app_version or '?'}, {req.platform or '?'})",
            body,
            reply_to=reply_to,
        )
    except Exception:
        logger.exception("Sending feedback email failed")
        raise HTTPException(status_code=502, detail="Could not send feedback") from None

    return {"ok": True}


@app.post("/contributors/register")
def register_contributor(req: ContributorRegisterIn, session: Session = Depends(db.get_db)):
    """
    project-description.md #10.2: "Become a Contributor" (the permanent
    role, distinct from #10.1's temporaryContributor) - creates a
    db.User row with role='pending' and emails a confirmation link
    (GET /contributors/confirm). The returned access_token is both that
    link's ?token= value and the app's own ongoing credential for
    GET /contributors/status - nothing after this call is ever looked up
    by email again, so there's no way to probe whether an arbitrary email
    address is registered.
    """
    password_hash = bcrypt.hashpw(req.password.encode(), bcrypt.gensalt()).decode()

    existing = session.query(db.User).filter(db.User.email == req.email).one_or_none()
    if existing and existing.role in ("contributor", "manager"):
        raise HTTPException(status_code=409, detail="Email already registered")
    if existing and existing.role == "banned":
        raise HTTPException(status_code=403, detail="This email cannot register")

    if existing:
        # role == "pending" - re-registering (e.g. lost the confirmation
        # email) just refreshes name/password and resends, reusing the
        # same access_token rather than minting a new one.
        existing.name = req.name
        existing.password_hash = password_hash
        user = existing
    else:
        user = db.User(
            # id is auto-increment - not set here, unlike Event's "evt_<ts>"
            # style ids (see db.py's User.id comment).
            name=req.name,
            email=req.email,
            role="pending",
            password_hash=password_hash,
            access_token=secrets.token_urlsafe(32),
        )
        session.add(user)

    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        raise HTTPException(status_code=409, detail="Email already registered") from None
    session.refresh(user)

    confirm_url = f"{config.PUBLIC_BASE_URL}/contributors/confirm?token={user.access_token}"
    emailer.send_email(
        user.email,
        "Confirm your VÄIN contributor account",
        f"Hi {user.name},\n\n"
        f"Click the link below to confirm your contributor account for VÄIN (Radio Tallinn 1965):\n\n"
        f"{confirm_url}\n\n"
        f"If you didn't request this, you can ignore this email.",
    )

    return {"access_token": user.access_token, "role": user.role}


@app.get("/contributors/confirm", response_class=HTMLResponse)
def confirm_contributor(token: str, session: Session = Depends(db.get_db)):
    """Visited from the email link register_contributor() sends."""
    user = session.query(db.User).filter(db.User.access_token == token).one_or_none()
    if not user:
        return ARTICLE_HTML_TEMPLATE.format(body="<p>Invalid or expired confirmation link.</p>")

    if user.role == "pending":
        user.role = "contributor"
        session.commit()
        return ARTICLE_HTML_TEMPLATE.format(body="<p>Your contributor account is confirmed. You can close this page and return to the app.</p>")

    return ARTICLE_HTML_TEMPLATE.format(body="<p>This account is already confirmed.</p>")


@app.get("/contributors/status")
def get_contributor_status(token: str, session: Session = Depends(db.get_db)):
    """
    Polled by app/Main.qml's checkContributorStatus() (on startup and on
    the refresh button) to notice a 'pending' -> 'contributor' transition
    - project-description.md #10.2's own "how does the app know?" question,
    answered via "on Refresh events".
    """
    user = session.query(db.User).filter(db.User.access_token == token).one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="Unknown token")
    return {"role": user.role}


@app.post("/contributors/login")
def login_contributor(req: ContributorLoginIn, session: Session = Depends(db.get_db)):
    """
    contributor/index.html's login view (project-description.md #10's
    "Become a contributor/Log in" TODO). One generic 401 message for both
    "no such email" and "wrong password" - same enumeration-avoidance
    posture as register_contributor(). role='pending' is allowed to log in
    too, so a not-yet-confirmed user can recover their access_token on a
    new device.
    """
    user = session.query(db.User).filter(db.User.email == req.email).one_or_none()
    if not user or not bcrypt.checkpw(req.password.encode(), user.password_hash.encode()):
        logger.info("login failed for '%s': %s", req.email, "unknown email" if not user else "wrong password")
        raise HTTPException(status_code=401, detail="Invalid email or password")
    if user.role == "banned":
        logger.info("login rejected for '%s': banned", req.email)
        raise HTTPException(status_code=403, detail="This account cannot log in")

    logger.info("login ok for '%s' (id=%s, role=%s)", req.email, user.id, user.role)
    # "id" added for manager/index.html (project-description.md #11), which
    # needs to know the logged-in user's own id to tell which Events rows a
    # contributor is allowed to edit (author_id === id) - additive, ignored
    # by existing callers (contributor/index.html, editor/index.html).
    return {"access_token": user.access_token, "role": user.role, "id": user.id}


@app.post("/contributors/forgot-password")
def request_password_reset(req: ContributorForgotPasswordIn, session: Session = Depends(db.get_db)):
    """
    contributor/index.html's "Forgot password?" view. Always returns 200
    with the same generic message regardless of whether the email is
    registered, to avoid leaking that - same reasoning as
    register_contributor()'s access_token scheme.
    """
    user = session.query(db.User).filter(db.User.email == req.email).one_or_none()
    if user:
        user.reset_token = secrets.token_urlsafe(32)
        user.reset_token_expires_at = datetime.utcnow() + timedelta(hours=1)
        session.commit()

        reset_url = f"{config.CONTRIBUTOR_WEB_URL}?view=reset&token={user.reset_token}"
        emailer.send_email(
            user.email,
            "Reset your VÄIN contributor password",
            f"Hi {user.name},\n\n"
            f"Click the link below to choose a new password for VÄIN (Radio Tallinn 1965):\n\n"
            f"{reset_url}\n\n"
            f"This link expires in 1 hour. If you didn't request this, you can ignore this email.",
        )

    return {"detail": "If that email is registered, a reset link has been sent."}


@app.post("/contributors/reset-password")
def reset_password(req: ContributorResetPasswordIn, session: Session = Depends(db.get_db)):
    """Visited from the email link request_password_reset() sends."""
    user = session.query(db.User).filter(db.User.reset_token == req.token).one_or_none()
    if not user or not user.reset_token_expires_at or user.reset_token_expires_at < datetime.utcnow():
        raise HTTPException(status_code=400, detail="Invalid or expired reset link")

    user.password_hash = bcrypt.hashpw(req.new_password.encode(), bcrypt.gensalt()).decode()
    user.reset_token = None
    user.reset_token_expires_at = None
    session.commit()

    return {}


@app.post("/contributors/delete")
def delete_contributor(req: ContributorDeleteIn, session: Session = Depends(db.get_db)):
    """
    app/Main.qml's "Leave contributor role" -> "Delete my data" prompt.
    Scrubs email/password_hash/access_token (and reset_token, for good
    measure) and sets role='deleted' - id/name stay, since
    Event.author/author_id (db.py) still needs to resolve a name for
    anything this user already published. Not deleting the row outright:
    that would need events.author_id's FK to go NULL too, same situation
    sql/schema.sql's migration notes already describe for other changes.
    """
    user = session.query(db.User).filter(db.User.access_token == req.access_token).one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="Unknown token")

    user.email = None
    user.password_hash = None
    user.access_token = None
    user.reset_token = None
    user.reset_token_expires_at = None
    user.role = "deleted"
    session.commit()

    return {}


@app.post("/events/publish")
def publish_event(event: EventIn, session: Session = Depends(db.get_db)):
    """
    Build a full Event JSON object (schema in project-description.md),
    persist it (+ its tags) to the Events DB.

    If publish_now is set (or no publish_at was given), the event is
    published immediately: status is set to 'new' and the FCM
    notification is sent right away. Otherwise the event is stored as
    'unpublished' and server/cron_publish.py (run every minute) sends the
    notification and flips it to 'new' once publish_at has passed, and
    later to 'shelved' once shelf_at has passed - see project-description.md
    #5 and #7.
    """
    event_id = event.id or f"evt_{int(time.time() * 1000)}"

    now = datetime.now()
    if event.publish_now or not event.publish_at:
        publish_at = now
        status = "new"
    else:
        publish_at = _parse_datetime(event.publish_at)
        status = "unpublished"

    shelf_at = _parse_datetime(event.shelf_at) if event.shelf_at else publish_at + DEFAULT_SHELF_DELAY

    payload = dict(event.payload)
    if status == "unpublished":
        # send_notification itself has no DB column - it's only read right
        # below for an immediate publish. For a scheduled ("unpublished")
        # event, cron_publish.py's publish_due_events() is what actually
        # fires the notification, possibly hours/days later, so the flag
        # has to survive somewhere until then - stashed in payload (same
        # place icecast_on_connect.sh already stashes save_stream) under an
        # underscored key so it reads as internal bookkeeping, not
        # app-facing content. Stripped back out in publish_due_events()
        # once it's actually consumed.
        payload["_send_notification"] = event.send_notification

    author = (
        session.query(db.User).filter(db.User.access_token == event.access_token).one_or_none()
        if event.access_token else None
    )

    row = db.Event(
        id=event_id,
        type=event.type,
        title=event.title,
        summary=event.summary,
        url=event.url,
        publish_at=publish_at,
        shelf_at=shelf_at,
        status=status,
        comments_enabled=event.comments_enabled,
        payload=payload,
        tags=[db.Tag(tag=tag) for tag in event.tags],
        author_id=author.id if author else None,
    )
    session.add(row)
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        raise HTTPException(status_code=409, detail=f"Event '{event_id}' already exists")
    session.refresh(row)

    event_dict = row.to_dict()
    message_id = None
    if status == "new" and event.send_notification:
        message_id = notifications.send_event_notification(event_dict, config.TEST_TOPIC)

    return {"event": event_dict, "message_id": message_id, "sent_immediately": status == "new"}


@app.post("/events/{event_id}/unpublish")
def unpublish_event(event_id: str, session: Session = Depends(db.get_db)):
    """
    Immediately moves an event to 'archived' - used by
    server/icecast_on_disconnect.sh (project-description.md #8.1/#9) so a
    livestream event disappears from both "New Arrivals" and "Collection"
    (list_events() only shows status new/shelved by default) the moment the
    broadcaster actually disconnects, rather than lingering as a "shelved"
    (archived-but-visible) entry - an ended broadcast isn't a collectible
    item like a finished audio/video, it's just over.

    Not 'unpublished': this event's publish_at is already in the past (it
    was published with publish_now=true), and cron_publish.py's
    publish_due_events() sweeps every 'unpublished' row whose publish_at has
    passed - setting status back to 'unpublished' here caused the very next
    cron tick to treat the just-ended broadcast as newly due, resending the
    "is on air" notification and flipping it back to 'new'. 'archived' is
    just as hidden from list_events() but isn't touched by that sweep.
    """
    row = session.get(db.Event, event_id)
    if row is None:
        raise HTTPException(status_code=404, detail=f"Event '{event_id}' not found")
    row.status = "archived"
    session.commit()
    return {"event": row.to_dict()}


@app.post("/events/{event_id}/finalize-recording")
def finalize_recording(event_id: str, body: FinalizeRecordingIn, session: Session = Depends(db.get_db)):
    """
    Called by server/icecast_on_disconnect.sh once a "Save stream" recording
    (project-description.md #8.2.1) has finished uploading to eccm.ee.
    Points the event at the real recording file and moves it from
    'archived' (set immediately on disconnect by unpublish_event(), before
    the upload finishes) to 'shelved' - the app treats status='shelved'
    events as collectible, and changing `type` away from "livestream"
    reuses EventDelegate.qml's existing type-based tap dispatch
    (audio/video -> PlaybackController.playMedia with isLive=false) so a
    finished recording plays back like any other audio/video item, with no
    app-side changes needed. A plain type="livestream" row would otherwise
    always be treated as isLive regardless of whether it has a real url.

    Not swept by cron_publish.py's shelf_due_events() (which only touches
    rows already at status='new') or publish_due_events() (only
    'unpublished' rows), so setting status='shelved' directly here is safe.
    """
    row = session.get(db.Event, event_id)
    if row is None:
        raise HTTPException(status_code=404, detail=f"Event '{event_id}' not found")
    if body.type not in db.EVENT_TYPES:
        raise HTTPException(status_code=400, detail=f"Invalid type '{body.type}'")
    row.url = body.url
    row.type = body.type
    row.status = "shelved"
    session.commit()
    return {"event": row.to_dict()}


@app.get("/events")
def list_events(status: list[str] | None = Query(None), limit: int = Query(200), session: Session = Depends(db.get_db)):
    """
    Feed for the client app (project-description.md #2.1): "New Arrivals"
    (status=new) and "Collection" (status=shelved) by default, since
    unpublished events aren't due yet and archived ones are dropped from
    both. Pass ?status=... (repeatable) to override. ?limit=... lets
    manager/index.html (project-description.md #11) ask for more than the
    200-row default - no auth here, same public-read posture as before.
    """
    query = session.query(db.Event)
    query = query.filter(db.Event.status.in_(status or ["new", "shelved"]))
    rows = query.order_by(db.Event.publish_at.desc()).limit(limit).all()
    return {"events": [r.to_dict() for r in rows]}


@app.patch("/events/{event_id}")
def update_event(event_id: str, body: EventPatchIn, session: Session = Depends(db.get_db)):
    """
    manager/index.html's per-row "Apply" for an edited Event
    (project-description.md #11). Only the fields actually present in the
    request body get touched - everything else on the row is untouched.
    """
    row = session.get(db.Event, event_id)
    if row is None:
        raise HTTPException(status_code=404, detail=f"Event '{event_id}' not found")
    user = _require_user(body.access_token, session)
    if user.role != "manager" and row.author_id != user.id:
        raise HTTPException(status_code=403, detail="Not authorized to edit this event")

    if body.type is not None:
        if body.type not in db.EVENT_TYPES:
            raise HTTPException(status_code=400, detail=f"Invalid type '{body.type}'")
        row.type = body.type
    if body.title is not None:
        row.title = body.title
    if body.summary is not None:
        row.summary = body.summary
    if body.url is not None:
        row.url = body.url
    if body.status is not None:
        if body.status not in db.EVENT_STATUSES:
            raise HTTPException(status_code=400, detail=f"Invalid status '{body.status}'")
        row.status = body.status
    if body.publish_at is not None:
        row.publish_at = _parse_datetime(body.publish_at)
    if body.shelf_at is not None:
        row.shelf_at = _parse_datetime(body.shelf_at)
    if body.comments_enabled is not None:
        row.comments_enabled = body.comments_enabled

    session.commit()
    session.refresh(row)
    return {"event": row.to_dict()}


@app.delete("/events/{event_id}")
def delete_event(event_id: str, access_token: str, delete_audio_file: bool = False, session: Session = Depends(db.get_db)):
    """
    manager/index.html's per-row "Apply" for a row marked for deletion
    (project-description.md #11). `delete_audio_file` only matters for
    type="streamrecording" rows - the DB row itself is always removed
    (cascades to its Tag rows via the existing FK) regardless of whether
    the remote file deletion below succeeds, since a failed best-effort
    remote delete shouldn't block the DB cleanup the manager actually asked
    for.
    """
    row = session.get(db.Event, event_id)
    if row is None:
        raise HTTPException(status_code=404, detail=f"Event '{event_id}' not found")
    user = _require_user(access_token, session)
    if user.role != "manager" and row.author_id != user.id:
        raise HTTPException(status_code=403, detail="Not authorized to delete this event")

    if delete_audio_file and row.type == "streamrecording" and row.url:
        remote_files.delete_eccm_stream_file(row.url)

    session.delete(row)
    session.commit()
    return {"ok": True}


@app.get("/users")
def list_users(access_token: str, session: Session = Depends(db.get_db)):
    """manager/index.html's Users tab (project-description.md #11) - manager role only."""
    _require_user(access_token, session, roles=("manager",))
    rows = session.query(db.User).order_by(db.User.id).all()
    return {"users": [
        {"id": u.id, "name": u.name, "email": u.email, "role": u.role, "created_at": u.created_at.isoformat()}
        for u in rows
    ]}


@app.patch("/users/{user_id}")
def update_user(user_id: int, body: UserPatchIn, session: Session = Depends(db.get_db)):
    """manager/index.html's per-row "Apply" for an edited User - manager role only."""
    _require_user(body.access_token, session, roles=("manager",))
    row = session.get(db.User, user_id)
    if row is None:
        raise HTTPException(status_code=404, detail=f"User '{user_id}' not found")

    if body.role is not None:
        if body.role not in db.USER_ROLES:
            raise HTTPException(status_code=400, detail=f"Invalid role '{body.role}'")
        row.role = body.role

    session.commit()
    session.refresh(row)
    return {"id": row.id, "name": row.name, "email": row.email, "role": row.role, "created_at": row.created_at.isoformat()}


@app.get("/articles/{article_id}")
def get_article(article_id: int):
    """
    Proxy for a single Joomla article's HTML content (project-description.md
    #2). The app never holds JOOMLA_API_TOKEN - it calls this instead of
    Joomla directly, same auth/base URL as server/joomla_importer.py.
    Content is fetched live on every call, never stored server-side.
    """
    try:
        resp = requests.get(
            f"{joomla_importer.JOOMLA_BASE_URL}/content/articles/{article_id}",
            headers=joomla_importer.HEADERS,
            timeout=30,
        )
    except requests.RequestException:
        raise HTTPException(status_code=502, detail="Failed to reach Joomla")

    if resp.status_code == 404:
        raise HTTPException(status_code=404, detail=f"Article {article_id} not found")
    try:
        resp.raise_for_status()
    except requests.RequestException:
        raise HTTPException(status_code=502, detail="Failed to fetch article from Joomla")

    data = resp.json().get("data")
    if isinstance(data, list):
        data = data[0] if data else None
    if not data:
        raise HTTPException(status_code=404, detail=f"Article {article_id} not found")

    attrs = data["attributes"]
    # Same fallback chain as joomla_importer.joomla_article_to_event().
    body_html = attrs.get("text") or attrs.get("introtext") or attrs.get("fulltext") or ""
    # Site root, not attrs["link"]: Joomla's relative asset paths (e.g.
    # "images/foo.jpg") resolve against the site root, not the article's own
    # permalink path.
    base_url = joomla_importer.JOOMLA_SITE_URL
    body_html = _absolutize_urls(body_html, base_url)

    return {
        "article_id": article_id,
        "title": attrs.get("title", ""),
        "html": ARTICLE_HTML_TEMPLATE.format(body=body_html),
        "base_url": base_url,
    }


@app.get("/tags")
def list_tags(q: str = "", limit: int = 20, session: Session = Depends(db.get_db)):
    """
    Distinct tags for the editor's tag autocomplete (project-description.md
    #7: "suggest existing tags" as the user types).
    """
    query = session.query(db.Tag.tag).distinct()
    if q:
        query = query.filter(db.Tag.tag.ilike(f"{q}%"))
    rows = query.order_by(db.Tag.tag).limit(limit).all()
    return {"tags": [r[0] for r in rows]}
