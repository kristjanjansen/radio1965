"""
SQLAlchemy engine/session and ORM models for the Events DB (MySQL/MariaDB).

Schema mirrors sql/schema.sql - see that file for the raw DDL used to
create the database, so keep the two in sync when making changes.
"""

from collections.abc import Generator

from sqlalchemy import (
    JSON,
    DateTime,
    Enum,
    ForeignKey,
    Integer,
    String,
    Text,
    create_engine,
    func,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, relationship, sessionmaker

from server import config

engine = create_engine(config.DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)


class Base(DeclarativeBase):
    pass


EVENT_TYPES = ("text", "audio", "video", "article", "webcontent", "livestream", "streamrecording")
EVENT_STATUSES = ("unpublished", "new", "shelved", "archived")
# "none" (no row) isn't a stored value - it's what GET /contributors/status
# (main.py) returns when a token isn't found at all. "deleted" is set by
# POST /contributors/delete - the row (id/name) stays so already-published
# events keep a valid author_id/author_name, but email/password_hash/
# access_token are scrubbed, so the account can never log in/be found again.
USER_ROLES = ("pending", "contributor", "manager", "banned", "deleted")


class Event(Base):
    __tablename__ = "events"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    type: Mapped[str] = mapped_column(Enum(*EVENT_TYPES, name="event_type"), nullable=False)
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    summary: Mapped[str | None] = mapped_column(Text, nullable=True)
    url: Mapped[str | None] = mapped_column(String(1024), nullable=True)
    publish_at: Mapped[object] = mapped_column(DateTime, nullable=False)
    shelf_at: Mapped[object | None] = mapped_column(DateTime, nullable=True)
    status: Mapped[str] = mapped_column(
        Enum(*EVENT_STATUSES, name="event_status"), nullable=False, default="unpublished"
    )
    payload: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    # Who posted this event - nullable. Populated by POST /events/publish
    # (server/main.py's publish_event()) from whichever access_token the
    # publisher sent - editor/index.html's logged-in session, or the app's
    # broadcast flow via icecast_on_connect.sh's ice-audio-info carrier.
    author_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[object] = mapped_column(DateTime, server_default=func.now())
    updated_at: Mapped[object] = mapped_column(DateTime, server_default=func.now(), onupdate=func.now())

    tags: Mapped[list["Tag"]] = relationship(
        back_populates="event", cascade="all, delete-orphan", lazy="joined"
    )
    # lazy="joined" so to_dict() can resolve author_name without a second
    # query per event.
    author: Mapped["User | None"] = relationship(lazy="joined")

    def to_dict(self) -> dict:
        """JSON-safe dict matching the Event schema in project-description.md."""
        return {
            "id": self.id,
            "type": self.type,
            "title": self.title,
            "summary": self.summary,
            "url": self.url,
            "publish_at": self.publish_at.isoformat(),
            "shelf_at": self.shelf_at.isoformat() if self.shelf_at else None,
            "status": self.status,
            "tags": [t.tag for t in self.tags],
            "payload": self.payload or {},
            "author_id": self.author_id,
            "author_name": self.author.name if self.author else None,
        }


class Tag(Base):
    __tablename__ = "tags"

    event_id: Mapped[str] = mapped_column(
        String(64), ForeignKey("events.id", ondelete="CASCADE"), primary_key=True
    )
    tag: Mapped[str] = mapped_column(String(64), primary_key=True, index=True)

    event: Mapped["Event"] = relationship(back_populates="tags")


class User(Base):
    """
    "Become a Contributor" accounts (project-description.md #10.2) - rows
    start life as role='pending' (created by POST /contributors/register),
    flipped to 'contributor' once the emailed confirmation link is visited
    (GET /contributors/confirm). 'manager'/'banned' are only ever set by a
    manual DB update for now - no self-service flow creates them.
    """

    __tablename__ = "users"

    # Plain auto-increment integer (not Event's "evt_<ts>"-style string id)
    # - easier to hand-edit/cross-reference directly in the DB (e.g. to
    # manually set someone to role='manager').
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    # Nullable - POST /contributors/delete scrubs these three (and sets
    # role='deleted') while keeping id/name, so already-published events
    # keep a valid author. Not dropping the row entirely for that same
    # reason (events.author_id's FK would otherwise have to go NULL too).
    email: Mapped[str | None] = mapped_column(String(255), nullable=True, unique=True, index=True)
    role: Mapped[str] = mapped_column(Enum(*USER_ROLES, name="user_role"), nullable=False, default="pending")
    password_hash: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # Opaque per-user secret (see main.py's register/confirm/status
    # endpoints) - doubles as both the one-time email confirmation link's
    # token and the app's ongoing "am I confirmed yet" status-check
    # credential, so nothing after initial registration ever needs to look
    # a user up by email again (which would let anyone probe whether an
    # arbitrary email address is registered).
    access_token: Mapped[str | None] = mapped_column(String(64), nullable=True, unique=True, index=True)
    # Set by POST /contributors/forgot-password, cleared by
    # POST /contributors/reset-password (main.py) - separate from
    # access_token so a leaked/scanned reset-email link can't also be used
    # as an ongoing status-check credential.
    reset_token: Mapped[str | None] = mapped_column(String(64), nullable=True, unique=True, index=True)
    reset_token_expires_at: Mapped[object | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[object] = mapped_column(DateTime, server_default=func.now())
    updated_at: Mapped[object] = mapped_column(DateTime, server_default=func.now(), onupdate=func.now())


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
