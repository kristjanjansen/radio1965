#!/bin/bash
# nginx-rtmp <exec_record_done> hook (ngx_rtmp_exec_module), run ON THE
# STREAMING SERVER once a recorded .flv file is closed - which for the
# "live" application's single-recording-per-connection setup (record_unique
# on) happens right as the source disconnects, making this the "stream
# ended" counterpart to rtmp_on_publish.sh. Configured as:
#   exec_record_done /usr/local/bin/rtmp_on_record_done.sh $path $app $name;
# so $1=path (full path to the finished .flv), $2=app, $3=name (stream key).
#
# Unpublishes the event rtmp_on_publish.sh created for this channel (same
# POST /events/{id}/unpublish server/icecast_on_disconnect.sh already uses
# for audio), then converts the .flv to .mp4 (project-description.md
# #8.2.2's draft conversion) and keeps it here (until 2026-11-07 it moved
# it to eccm.ee and finalized the event into a playable "streamrecording").

# link it to /usr/local/bin/rtmp_on_record_done.sh

set -uo pipefail

FILE="$1"
CHANNEL="$3"
API_BASE="https://live.uuu.ee/radio1965/api"
IDFILE="/tmp/rtmp_event_${CHANNEL}.id"
LOGFILE="/tmp/rtmp_hooks.log"

log() { echo "$(date -Is) [on-record-done] $*" >> "$LOGFILE"; }

log "invoked: path='$FILE' app='$2' channel='$CHANNEL'"

# Same dedicated-key reasoning as icecast_on_disconnect.sh - don't rely on
# nginx's own $HOME/.ssh, point ssh at a dedicated key/known_hosts instead.
ECCM_SSH_KEY="/etc/radio65-eccm-ssh/id_rsa_eccm_live"
ECCM_SSH_KNOWN_HOSTS="/etc/radio65-eccm-ssh/known_hosts"
ECCM_SSH_OPTS="-p 38307 -i $ECCM_SSH_KEY -o UserKnownHostsFile=$ECCM_SSH_KNOWN_HOSTS -o StrictHostKeyChecking=accept-new"
REMOTE_DIR="/home/eccmee1/www/radio1965/streams/video"
REMOTE_DEST="eccmee1@eccm.ee:${REMOTE_DIR}/"

# Read (but don't delete) the event id now, before the unpublish call below
# deletes IDFILE - the backgrounded conversion/upload subshell further down
# needs it too, and by the time it finishes IDFILE would otherwise be gone.
EVENT_ID=""
if [ -f "$IDFILE" ]; then
  EVENT_ID=$(cat "$IDFILE")
fi

if [ -n "$EVENT_ID" ]; then
  log "found id file, event_id='$EVENT_ID' - unpublishing"
  RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$API_BASE/events/${EVENT_ID}/unpublish")
  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | sed '$d')
  log "unpublish response: http=$HTTP_CODE body=$BODY"
  rm -f "$IDFILE"
else
  log "no id file at '$IDFILE' - nothing to unpublish (on-publish never ran for this channel, or already unpublished/cleaned up)"
fi

# Convert + move + finalize in the background so a slow conversion/transfer
# can't block or risk timing out this hook (same reasoning as backgrounding
# the rsync in icecast_on_disconnect.sh).
(
  if [ ! -f "$FILE" ]; then
    log "recording file '$FILE' not found - nothing to convert"
    exit 0
  fi

  BASENAME="${FILE%.*}"
  HAS_VIDEO=$(ffprobe -v error -select_streams v -show_entries stream=codec_type -of csv=p=0 "$FILE" 2>>"$LOGFILE")

  if [ -z "$HAS_VIDEO" ]; then
    OUT_PATH="${BASENAME}.mp3"
    ffmpeg -nostdin -loglevel error -y -i "$FILE" -vn -c:a libmp3lame -b:a 192k "$OUT_PATH" >>"$LOGFILE" 2>&1
  else
    OUT_PATH="${BASENAME}.mp4"
    ffmpeg -nostdin -loglevel error -y -i "$FILE" -c copy "$OUT_PATH" >>"$LOGFILE" 2>&1
  fi

  if [ ! -f "$OUT_PATH" ]; then
    log "conversion of '$FILE' failed - '$OUT_PATH' was not created, leaving '$FILE' in place"
    exit 1
  fi
  log "converted '$FILE' -> '$OUT_PATH'"
  rm -f "$FILE"

  # 2026-11-07: recordings are v2in's now, so the copy to eccm.ee and the
  # finalize pointing at an eccm.ee URL are commented out below, not
  # deleted. The converted file stays on this server, for old app builds
  # that still broadcast here.
  log "recording kept on this server at '$OUT_PATH' (no copy to eccm.ee since 2026-11-07)"

#  ssh $ECCM_SSH_OPTS eccmee1@eccm.ee "mkdir -p '$REMOTE_DIR'" >>"$LOGFILE" 2>&1
#
#  if rsync -az -e "ssh $ECCM_SSH_OPTS" "$OUT_PATH" "$REMOTE_DEST" >>"$LOGFILE" 2>&1; then
#    log "moved recording '$OUT_PATH' -> $REMOTE_DEST"
#    rm -f "$OUT_PATH"
#
#    if [ -n "$EVENT_ID" ]; then
#      REMOTE_URL="https://eccm.ee/radio1965/streams/video/$(basename "$OUT_PATH")"
#      FINALIZE_BODY=$(jq -n --arg url "$REMOTE_URL" --arg type "streamrecording" '{url: $url, type: $type}')
#      FINALIZE_RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$API_BASE/events/${EVENT_ID}/finalize-recording" \
#        -H "Content-Type: application/json" -d "$FINALIZE_BODY")
#      FINALIZE_HTTP_CODE=$(echo "$FINALIZE_RESPONSE" | tail -n1)
#      FINALIZE_BODY_RESPONSE=$(echo "$FINALIZE_RESPONSE" | sed '$d')
#      log "finalize-recording response: http=$FINALIZE_HTTP_CODE body=$FINALIZE_BODY_RESPONSE (event_id='$EVENT_ID' url='$REMOTE_URL')"
#    fi
#  else
#    log "failed to move recording '$OUT_PATH' to $REMOTE_DEST - left in place for retry"
#  fi
) &
disown
