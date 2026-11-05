"""
Weekly cron job: dumps the Events DB (mysqldump | gzip) into
config.BACKUP_DIR, keeping only the config.BACKUP_KEEP_COUNT most recent
backups (project-description.md #11).

Run directly against the DB (same "no dependency on the API server being
up" posture as cron_publish.py).

Install via crontab (adjust paths for your deployment), every Monday at 03:00:
    0 3 * * 1 cd /home/pierre/src/radio1965 && . server/set_env.sh && /home/pierre/src/radio1965/server/.venv/bin/python -m server.cron_backup >> /var/log/radio65_backup_cron.log 2>&1
"""

import glob
import gzip
import logging
import os
import subprocess
from datetime import datetime

from sqlalchemy.engine import make_url

from server import config

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def _dump_database(dest_path: str) -> None:
    url = make_url(config.DATABASE_URL)
    cmd = ["mysqldump", "-h", url.host or "localhost", "-u", url.username]
    if url.port:
        cmd += ["-P", str(url.port)]
    cmd += [url.database]

    env = dict(os.environ)
    if url.password:
        # Avoids the password showing up in `ps` output - mysqldump reads
        # it from the environment instead of a -p<password> argument.
        env["MYSQL_PWD"] = url.password

    with gzip.open(dest_path, "wb") as gz_file:
        subprocess.run(cmd, stdout=gz_file, env=env, check=True)


def _prune_old_backups() -> None:
    backups = sorted(glob.glob(os.path.join(config.BACKUP_DIR, "radio65_*.sql.gz")))
    stale = backups[:-config.BACKUP_KEEP_COUNT] if config.BACKUP_KEEP_COUNT > 0 else backups
    for path in stale:
        try:
            os.remove(path)
            logger.info("Removed old backup '%s'", path)
        except OSError:
            logger.exception("Failed to remove old backup '%s'", path)


def main() -> None:
    os.makedirs(config.BACKUP_DIR, exist_ok=True)
    dest_path = os.path.join(config.BACKUP_DIR, f"radio65_{datetime.now():%Y%m%d}.sql.gz")
    try:
        _dump_database(dest_path)
        logger.info("Wrote backup '%s'", dest_path)
    except Exception:
        logger.exception("Database backup failed")
        return
    _prune_old_backups()


if __name__ == "__main__":
    main()
