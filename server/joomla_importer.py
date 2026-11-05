"""
Joomla -> Events DB importer (project-description.md #6).

Polls Joomla's Web Services API for published articles in
JOOMLA_CATEGORY_ID and upserts them into the events table as
type="article", id=f"joomla_{article_id}":
  - new articles are inserted with status="unpublished" so the normal
    server/cron_publish.py sweep sends the FCM notification and flips
    them to "new" (and later "shelved") exactly like editor-created events.
  - articles already imported are only updated (title/summary/url) if
    edited in Joomla afterwards; status/publish_at/shelf_at are left
    alone and no notification is re-sent.

Run on its own schedule via server/cron_joomla_import.py (see that file
for the crontab line) - separate from cron_publish.py since it hits an
external API rather than just the local DB.

don't forget 'source server/set_env.sh'
"""

import logging
import os
import re
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import urlparse

import requests

from server import db

logger = logging.getLogger(__name__)

JOOMLA_BASE_URL = "https://eccm.ee/api/index.php/v1"
JOOMLA_API_TOKEN = os.getenv("JOOMLA_API_TOKEN")
JOOMLA_CATEGORY_ID = 47  # set to restrict import to one category, or None for all

# Site root (not the API base), derived rather than hardcoded a second time.
# Used as the baseUrl for relative asset paths (e.g. "images/foo.jpg") found
# in article HTML - see server/main.py's GET /articles/{id}.
_parsed_base = urlparse(JOOMLA_BASE_URL)
JOOMLA_SITE_URL = f"{_parsed_base.scheme}://{_parsed_base.netloc}/"

HEADERS = {
    "Authorization": f"Bearer {JOOMLA_API_TOKEN}",
    "Accept": "application/vnd.api+json",
}

# Events default to being moved to the shelf a week after publish_at if
# Joomla's publish_down is unset - matches DEFAULT_SHELF_DELAY in main.py.
DEFAULT_SHELF_DELAY = timedelta(days=7)

# Small local state file tracking the last successful import run, so we
# only ask Joomla for articles modified since then. Not a secret, just
# runtime state - gitignored like the other local config in this dir.
LAST_SYNC_FILE = Path(__file__).parent / "config" / "joomla_last_sync.txt"


def strip_html(html: str, max_len: int = 400) -> str:
    """Very small HTML-tag stripper for building a plain-text summary."""
    text = re.sub(r"<[^>]+>", "", html or "")
    text = re.sub(r"\s+", " ", text).strip()
    return text[:max_len]


def parse_joomla_datetime(value: str | None) -> datetime | None:
    """
    Parse a Joomla datetime string ('YYYY-MM-DD HH:MM:SS') as naive local
    time, matching the rest of the app (see cron_publish.py / main.py,
    which compare against datetime.now()). Joomla represents "unset" dates
    as the zero-date string.
    """
    if not value:
        return None
    value = value.strip()
    if not value or value.startswith("0000-00-00"):
        return None
    return datetime.fromisoformat(value)


def load_last_sync() -> datetime | None:
    if not LAST_SYNC_FILE.exists():
        return None
    text = LAST_SYNC_FILE.read_text().strip()
    return datetime.fromisoformat(text) if text else None


def save_last_sync(when: datetime) -> None:
    LAST_SYNC_FILE.parent.mkdir(parents=True, exist_ok=True)
    LAST_SYNC_FILE.write_text(when.isoformat())


def fetch_articles(modified_since: datetime | None = None) -> list[dict]:
    """Fetch published articles from Joomla, optionally filtered by modified date."""
    params = {
        "filter[state]": "1",           # published only
        "list[fullordering]": "a.modified DESC",
        "list[limit]": "100",
    }
    if JOOMLA_CATEGORY_ID:
        params["filter[category]"] = JOOMLA_CATEGORY_ID

    resp = requests.get(f"{JOOMLA_BASE_URL}/content/articles", headers=HEADERS, params=params, timeout=30)
    resp.raise_for_status()
    body = resp.json()

    articles = []
    for item in body.get("data", []):
        attrs = item["attributes"]

        # Don't trust the server-side filter alone - Joomla's API has had
        # bugs where combined filter[] params silently drop one another.
        cat_id = item.get("relationships", {}).get("category", {}).get("data", {}).get("id")
        if JOOMLA_CATEGORY_ID and str(cat_id) != str(JOOMLA_CATEGORY_ID):
            continue
        if attrs.get("state") != 1:
            continue

        modified = parse_joomla_datetime(attrs.get("modified"))
        if modified_since and modified and modified <= modified_since:
            continue

        articles.append(item)

    return articles


def resolve_tag_name(raw_tag, cache: dict) -> str:
    """
    Joomla's articles endpoint lists each tag either as an already-resolved
    name (string) or as a bare numeric tag id, depending on the API/plugin
    version - resolve the latter via GET /tags/{id}, once per id per run.
    """
    if isinstance(raw_tag, dict):
        return raw_tag.get("title") or raw_tag.get("name") or str(raw_tag.get("id"))

    text = str(raw_tag)
    if not text.isdigit():
        return text

    if text in cache:
        return cache[text]

    resp = requests.get(f"{JOOMLA_BASE_URL}/tags/{text}", headers=HEADERS, timeout=30)
    resp.raise_for_status()
    name = resp.json()["data"]["attributes"]["title"]
    cache[text] = name
    return name


def joomla_article_to_event(item: dict, tag_cache: dict) -> dict:
    """Map a Joomla article's JSON:API record to Events DB fields (server/db.py)."""
    attrs = item["attributes"]
    article_id = item["id"]

    now = datetime.now()
    publish_at = parse_joomla_datetime(attrs.get("publish_up")) or now
    if publish_at < now:
        publish_at = now

    shelf_at = parse_joomla_datetime(attrs.get("publish_down"))
    if shelf_at is None:
        shelf_at = publish_at + DEFAULT_SHELF_DELAY

    # The list endpoint returns the full article body under "text" (not
    # "introtext"/"fulltext" as older Joomla versions used) - fall back to
    # those in case a different endpoint/version is ever used instead.
    body_html = attrs.get("text") or attrs.get("introtext") or attrs.get("fulltext") or ""

    tags = [resolve_tag_name(t, tag_cache) for t in attrs.get("tags") or []]

    return {
        "id": f"joomla_{article_id}",
        "type": "article",
        "title": attrs["title"],
        "summary": strip_html(body_html, 200),
        "url": attrs.get("link") or f"https://eccm.ee/index.php?option=com_content&id={article_id}",
        "publish_at": publish_at,
        "shelf_at": shelf_at,
        "payload": {"article_id": int(article_id)},
        "tags": tags,
    }


def run_import(session, last_sync: datetime | None) -> datetime:
    """
    Fetch new/updated Joomla articles and upsert them into the events
    table. Returns the new last_sync value to persist.

    New articles are inserted with status="unpublished" - cron_publish.py
    (run every minute) takes care of sending the notification and moving
    them through new -> shelved. Articles already imported are only
    updated in place (title/summary/url/tags/payload); their
    status/publish_at/shelf_at are left untouched and no notification is
    re-sent.
    """
    articles = fetch_articles(modified_since=last_sync)
    tag_cache: dict = {}

    for item in articles:
        event = joomla_article_to_event(item, tag_cache)
        tags = [db.Tag(tag=t) for t in event.pop("tags")]
        existing = session.get(db.Event, event["id"])

        if existing is None:
            row = db.Event(status="unpublished", tags=tags, **event)
            session.add(row)
            logger.info("Imported new Joomla article as event '%s'", event["id"])
        else:
            existing.title = event["title"]
            existing.summary = event["summary"]
            existing.url = event["url"]
            existing.payload = event["payload"]
            existing.tags = tags
            logger.info("Updated existing Joomla-imported event '%s' (no re-notify)", event["id"])

    session.commit()
    return datetime.now()
