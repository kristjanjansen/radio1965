#!/bin/bash
# Icecast <on-disconnect> hook (icecast.xml), run ON THE STREAMING SERVER
# by Icecast when a source stops broadcasting on a mountpoint
# (project-description.md #8.1/#9). Icecast passes the mountpoint as $1,
# as the literal <mount-name> string (e.g. "/user1", WITH the leading
# slash) - see server/icecast_on_connect.sh for how this was confirmed.
# Must normalize the same way here too, since the id-file path built below
# has to match the one icecast_on_connect.sh wrote.
#
# Unpublishes the event server/icecast_on_connect.sh created for this channel,
# via the new POST /events/{id}/unpublish (server/main.py) - immediate,
# rather than waiting on cron_publish.py's time-based shelf_at sweep.

# link it to /usr/local/bin

set -uo pipefail

CHANNEL="${1#/}"   # normalize away a leading slash, e.g. "/user1" -> "user1"
API_BASE="https://live.uuu.ee/radio1965/api"
IDFILE="/tmp/icecast_event_${CHANNEL}.id"
LOGFILE="/tmp/icecast_hooks.log"

# No logging previously existed here at all - curl's response was piped to
# /dev/null and a missing id file silently no-op'd, so a failed unpublish was
# indistinguishable from Icecast never invoking this hook in the first
# place. Log every step so a failure is diagnosable after the fact instead
# of only by reproducing it live with -x.
log() { echo "$(date -Is) [on-disconnect] $*" >> "$LOGFILE"; }

log "invoked: mount='$1' channel='$CHANNEL'"

# project-description.md #8.2.1: stop any recording icecast_on_connect.sh
# started for this channel, before touching the event - stopping the
# recording promptly matters more than the unpublish call's ordering.
RECORD_PIDFILE="/tmp/icecast_record_${CHANNEL}.pid"
RECORD_PATHFILE="/tmp/icecast_record_${CHANNEL}.path"
RECORD_PATH=""
RECORDING_STOPPED="false"
if [ -f "$RECORD_PIDFILE" ]; then
  RECORD_PID=$(cat "$RECORD_PIDFILE")
  RECORD_PATH=$(cat "$RECORD_PATHFILE" 2>/dev/null || echo "")
  if kill -0 "$RECORD_PID" 2>/dev/null; then
    kill -TERM "$RECORD_PID" 2>/dev/null
    # ffmpeg finalizes and exits on SIGTERM; a stream-copied mp3 has no
    # trailing index/atom to finalize, so even an unresponsive process
    # leaves a valid file up to its last complete frame - poll briefly
    # rather than blocking indefinitely on it.
    for attempt in 1 2 3 4 5; do
      kill -0 "$RECORD_PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$RECORD_PID" 2>/dev/null; then
      log "recording pid=$RECORD_PID ('$RECORD_PATH') still alive after SIGTERM - leaving it be"
    else
      SIZE=$(stat -c%s "$RECORD_PATH" 2>/dev/null || echo "?")
      log "stopped recording pid=$RECORD_PID -> '$RECORD_PATH' (${SIZE} bytes)"
      RECORDING_STOPPED="true"
    fi
  else
    log "recording pidfile '$RECORD_PIDFILE' found but pid=$RECORD_PID is not running (already stopped/crashed)"
    RECORDING_STOPPED="true"
  fi
  rm -f "$RECORD_PIDFILE" "$RECORD_PATHFILE"
else
  log "no recording pidfile - save_stream was off, or on-connect never ran for this channel"
fi

# project-description.md #8.2 (lines 393-397): once the recording is
# confirmed finished, move it to eccm.ee over ssh/rsync - backgrounded so a
# slow/stalled transfer can't block or risk timing out this hook (same
# reasoning as backgrounding ffmpeg itself in icecast_on_connect.sh), and
# doesn't delay the unpublish call below.
#
# Not relying on icecast2's own $HOME/.ssh (e.g. a "Host eccm.ee" alias in
# ~/.ssh/config with User/Port/IdentityFile resolved implicitly): `getent
# passwd icecast2` shows its home as /usr/share/icecast2, a root-owned
# package directory that gets reset on icecast2 upgrades/reinstalls - not a
# sane place to park a private key, and relying on it is what made
# `sudo -u icecast2 ssh eccm.ee` hang in the first place (no config, no
# known_hosts entry for icecast2 to use). Point ssh at a dedicated
# key/known_hosts under /etc/radio65-eccm-ssh (owned by icecast2, 600)
# via explicit flags instead, so this doesn't depend on icecast2 having a
# usable home directory at all.
ECCM_SSH_KEY="/etc/radio65-eccm-ssh/id_rsa_eccm_live"
ECCM_SSH_KNOWN_HOSTS="/etc/radio65-eccm-ssh/known_hosts"

# Read (but don't delete) the event id now, before the existing unpublish
# block below deletes IDFILE - the backgrounded rsync subshell further down
# needs it too (project-description.md #8.2.1's finalize-recording step),
# and by the time that subshell finishes IDFILE would otherwise be long gone.
EVENT_ID=""
if [ -f "$IDFILE" ]; then
  EVENT_ID=$(cat "$IDFILE")
fi

# 2026-11-07: recordings are v2in's now (the app broadcasts there, and v2in
# records and keeps the session), so the copy to eccm.ee and the finalize
# pointing at an eccm.ee URL are commented out below, not deleted. The
# recording stays on this server where ffmpeg wrote it, for old app builds
# that still broadcast here.
if [ "$RECORDING_STOPPED" = "true" ] && [ -n "$RECORD_PATH" ] && [ -f "$RECORD_PATH" ]; then
  log "recording kept on this server at '$RECORD_PATH' (no copy to eccm.ee since 2026-11-07)"
fi
# if [ "$RECORDING_STOPPED" = "true" ] && [ -n "$RECORD_PATH" ] && [ -f "$RECORD_PATH" ]; then
#   REMOTE_DEST="eccmee1@eccm.ee:/home/eccmee1/www/radio1965/streams/"
#   (
#     if rsync -az -e "ssh -p 38307 -i $ECCM_SSH_KEY -o UserKnownHostsFile=$ECCM_SSH_KNOWN_HOSTS -o StrictHostKeyChecking=accept-new" \
#         "$RECORD_PATH" "$REMOTE_DEST" >>"$LOGFILE" 2>&1; then
#       log "moved recording '$RECORD_PATH' -> $REMOTE_DEST"
#       rm -f "$RECORD_PATH"
#
#       # project-description.md #8.2.1: point the event at the real
#       # recording and move it from 'archived' (set by the unpublish call
#       # below, immediately on disconnect) to 'shelved' so it reappears in
#       # the app's Collection as a playable Audio card - see
#       # server/main.py's finalize_recording(). Only attempted once the
#       # upload actually succeeded (not on rsync failure); the event stays
#       # 'archived' if EVENT_ID is empty (on-connect never ran/no id was
#       # captured for this channel) since there's nothing to update.
#       if [ -n "$EVENT_ID" ]; then
#         REMOTE_URL="https://eccm.ee/radio1965/streams/$(basename "$RECORD_PATH")"
#         FINALIZE_BODY=$(jq -n --arg url "$REMOTE_URL" --arg type "streamrecording" '{url: $url, type: $type}')
#         FINALIZE_RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$API_BASE/events/${EVENT_ID}/finalize-recording" \
#           -H "Content-Type: application/json" -d "$FINALIZE_BODY")
#         FINALIZE_HTTP_CODE=$(echo "$FINALIZE_RESPONSE" | tail -n1)
#         FINALIZE_BODY_RESPONSE=$(echo "$FINALIZE_RESPONSE" | sed '$d')
#         log "finalize-recording response: http=$FINALIZE_HTTP_CODE body=$FINALIZE_BODY_RESPONSE (event_id='$EVENT_ID' url='$REMOTE_URL')"
#       fi
#     else
#       log "failed to move recording '$RECORD_PATH' to $REMOTE_DEST - left in place for retry"
#     fi
#   ) &
#   disown
# fi

if [ -n "$EVENT_ID" ]; then
  log "found id file, event_id='$EVENT_ID' - unpublishing"
  RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$API_BASE/events/${EVENT_ID}/unpublish")
  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | sed '$d')
  log "unpublish response: http=$HTTP_CODE body=$BODY"
  rm -f "$IDFILE"
else
  log "no id file at '$IDFILE' - nothing to unpublish (on-connect never ran for this channel, or already unpublished/cleaned up)"
fi