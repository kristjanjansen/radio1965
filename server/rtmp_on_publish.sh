#!/bin/bash
# nginx-rtmp <exec_publish> hook (ngx_rtmp_exec_module), run ON THE STREAMING
# SERVER itself when a source starts publishing to the "live" application
# (project-description.md #8.2.2). Configured as:
#   exec_publish /usr/local/bin/rtmp_on_publish.sh $app $name;
# so $1=app (e.g. "live"), $2=name (the stream key, e.g. "stream" in
# rtmp://live.uuu.ee/live/stream).
#
# Publishes a type="livestream" event via the existing notification server
# API (same POST /events/publish server/icecast_on_connect.sh already uses
# for audio), and persists the created event id to a temp file keyed by
# channel so rtmp_on_record_done.sh (a separate later invocation, once the
# stream disconnects) can unpublish/finalize it.

# link it to /usr/local/bin/rtmp_on_publish.sh

set -uo pipefail

CHANNEL="$2"
API_BASE="https://live.uuu.ee/radio1965/api"   # matches Main.qml appSettings.serverUrl default
LOGFILE="/tmp/rtmp_hooks.log"

log() { echo "$(date -Is) [on-publish] $*" >> "$LOGFILE"; }

log "invoked: app='$1' channel='$CHANNEL'"

BODY=$(jq -n \
  --arg ch "$CHANNEL" \
  --arg title "Video stream is on air" \
  '{
    type: "livestream",
    title: $title,
    summary: "",
    url: ("https://live.uuu.ee:4443/hls/" + $ch + ".m3u8"),
    publish_now: true,
    send_notification: true,
    tags: [],
    payload: {}
  }')

RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$API_BASE/events/publish" \
  -H "Content-Type: application/json" \
  -d "$BODY")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY_RESPONSE=$(echo "$RESPONSE" | sed '$d')
log "publish response: http=$HTTP_CODE body=$BODY_RESPONSE"

EVENT_ID=$(echo "$BODY_RESPONSE" | jq -r '.event.id // empty')
if [ -n "$EVENT_ID" ]; then
  echo "$EVENT_ID" > "/tmp/rtmp_event_${CHANNEL}.id"
  log "wrote id file /tmp/rtmp_event_${CHANNEL}.id (event_id='$EVENT_ID')"
else
  log "no event id in publish response - id file NOT written, on-record-done will have nothing to unpublish"
fi
