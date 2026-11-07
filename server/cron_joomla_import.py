"""
Periodic cron job: polls Joomla for new/updated articles and upserts them
into the Events DB (project-description.md #6). Run separately from
cron_publish.py since this one calls an external API - every minute would
be excessive, so a few minutes' delay is fine (notifications are still
sent promptly by cron_publish.py once the row lands with publish_at due).

Install via crontab (adjust paths for your deployment):
    */5 * * * * cd /home/pierre/src/radio1965 && . server/set_env.sh && /home/pierre/src/radio1965/server/.venv/bin/python -m server.cron_joomla_import >> /var/log/radio65_joomla_cron.log 2>&1
"""

import logging

from server import db, joomla_importer

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def main() -> None:
    # 2026-11-07: off. eccm.ee's Joomla goes away when eccm.ee moves to its new site, and ECCM posts no news to
    # the app any more; the crontab line can stay, it now returns at once. Remove this return to switch it back on.
    return
    session = db.SessionLocal()
    try:
        last_sync = joomla_importer.load_last_sync()
        new_last_sync = joomla_importer.run_import(session, last_sync)
        joomla_importer.save_last_sync(new_last_sync)
    except Exception:
        session.rollback()
        logger.exception("Joomla import run failed")
    finally:
        session.close()


if __name__ == "__main__":
    main()
