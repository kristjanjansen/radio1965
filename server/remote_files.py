"""
Deleting files that live on eccm.ee, outside this server's own DB/filesystem.

Currently just the one case manager/index.html needs (project-description.md
#11): removing a "streamrecording" event's audio file when a manager deletes
its event. Mirrors server/icecast_on_disconnect.sh's rsync upload (same
host/port/remote directory, via server/config.py's RADIO65_ECCM_SSH_*
constants) but in the opposite direction, over a plain `ssh ... rm -f`.
"""

import logging
import subprocess
from urllib.parse import urlparse

from server import config

logger = logging.getLogger(__name__)


def delete_eccm_stream_file(url: str) -> None:
    """
    Best-effort delete of a streamrecording's file on eccm.ee, given its
    public https://eccm.ee/radio1965/streams/<file> URL (as stored in
    Event.url by finalize_recording()). Never raises - a failed remote
    delete shouldn't block the caller's own DB cleanup, same posture as
    icecast_on_disconnect.sh's own error handling (log and move on).

    Relies on the default SSH identity under the server process's own
    $HOME/.ssh (no -i flag) rather than a dedicated key file - see
    config.py's RADIO65_ECCM_SSH_* comment.
    """
    # 2026-11-07: recordings are v2in's now and nothing is copied to
    # eccm.ee any more, so there is nothing there to delete. A no-op, the
    # ssh delete commented out below, not deleted.
    logger.info("delete_eccm_stream_file: no-op since 2026-11-07, not deleting '%s'", url)
    return

    # filename = urlparse(url).path.rsplit("/", 1)[-1]
    # if not filename:
    #     logger.warning("delete_eccm_stream_file: could not derive a filename from url '%s'", url)
    #     return

    # remote_path = f"{config.RADIO65_ECCM_STREAMS_DIR}/{filename}"
    # try:
    #     result = subprocess.run(
    #         [
    #             "ssh",
    #             "-p", str(config.RADIO65_ECCM_SSH_PORT),
    #             f"{config.RADIO65_ECCM_SSH_USER}@{config.RADIO65_ECCM_SSH_HOST}",
    #             "rm", "-f", remote_path,
    #         ],
    #         capture_output=True,
    #         text=True,
    #         timeout=30,
    #     )
    # except Exception:
    #     logger.exception("delete_eccm_stream_file: ssh rm failed for '%s'", remote_path)
    #     return

    # if result.returncode == 0:
    #     logger.info("delete_eccm_stream_file: removed '%s'", remote_path)
    # else:
    #     logger.warning(
    #         "delete_eccm_stream_file: ssh rm for '%s' exited %d: %s",
    #         remote_path, result.returncode, result.stderr.strip(),
    #     )
