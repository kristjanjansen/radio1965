# Radio 1965: unified event/media platform (Qt client + Linux server)

## 1. General description
        
      
The software  forwards different content (articles, audio/video, live streams, different web content) to users. It  consists of three parts:  

Event server (written in python) -  records events (new content created/edited/deleted ) in database (or JSON file) and forwards them via push notifications to  users apps.   Some content can be created in separate JOOMLA system, a bridge is neede to retriece the content of articles.

Client app  (Android, iOS, based on Qt platform) -  receives notifications on new content and shows relevant content. Enables search in past events/content.

Editor page (html/javascript/php) -  frontend for server management: for entering new events/creating content, .  

The server runs on Ubuntu 18.04, streaming service is already set up.

## 2. Notes for client app

  - For web content (articles, embedded conent) on iOS/Android: use `QtWebView` (wraps native WKWebView / Android WebView).
  - WebAssembly: Don't embed a
    web engine at all — use an `<iframe>` via JS interop for "webcontent"     posts, or native browser capability directly.
    
- Use `QtMultimedia` (with a capable backend, e.g. `libmpv` or GStreamer) to   play HLS/DASH/RTMP directly. 

### 2.1 Client app UI and functinality

The overall logic is similar to a library (of books) - there is counter of new itmes (New Arrivals), shelves (Collection) and Archive where materials to be out of site can be still be accessible.
An entry is called an "item" instead of "event"  now.

On startup or a push notification arriving, the app pulls data via notification server API, updates its internal data and shows the content.
The main internal data is a model that refers to  events table in the database, where status is "new" or "shelved". If status is "archived", the items are shown only when searched for, "unpublished" are never shown.
On exit the app stores the models state in app settings.

// note for myaself: Kartoteek (Estonian) = Card Catalog; Kaart = Entry or Card.

Visually the main element is a Card with  a title, summary, type, maybe later also category, (later also thumbnail) on it. 
Use separate QML component Card.qml for it. Set necessary proeprties. 
For now use something like the listviews delegate for it:

Rectangle {
                        width: messageListView.width
                        height: messageColumn.implicitHeight + 20
                        radius: 5
                        color: Material.backgroundColor.lighter()
                        border.width: 1
                        border.color: // Card.color

                        ColumnLayout {
                            id: messageColumn
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 4

                            Label {
                                text: title
                                font.bold: true
                                font.pointSize: 13
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }

                            Label {
                                text: summary
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }

                            // other necessary fields

                            Mousearea { ... }
                        }

Use different border colors for different types.

When user clicks on the card, the contents are retrieved and shown in a content component (probably via WebView). Always show also the title on the component. Add Close, Next, Previous button.

Behaviour by types:
- text -  just show the plain text
- article -  pull content from joomla API (see joomla_importer.py) and show it as html.
- audio, video, streams -  to be implemented
- web content -  use iframe and show given content.

The app has three main pages/views:
- New Arrivals 
- Collection (Shelves)
-- for now organized by type (text, article, audio etc), later by categories
- Archive
-- Search form, do not implent now.

Use TabBar + SwipeView for it:
Something like:
```
ApplicationWindow {
    footer: TabBar {
        id: tabBar
        TabButton { text: "New Arrivals" }
        TabButton { text: "Collection" }
        TabButton { text: "Broadcast" }
    }

    SwipeView {
        anchors.fill: parent
        currentIndex: tabBar.currentIndex
        NewArrivalsPage {}
        CollectionPage {}
        BroadcastPage {}
    }
}
```
For Content use StackView, that covers the main content area (between header and above footer)


Later use a slim, persistent mini-player bar that survives across tab switches and stack pushes/pops (sitting between the SwipeView and the TabBar, or docked just above it

## 2.1 Organizing shevled events

In the collection page (or it can be called also archive, no separate archive page any more) the sheleved events are devided into Shelves (separate QML component) by event type:
Live Streams, Audio, Video, Web Content, Article, Message
Use different background colours and according border colours for them (dark side) 

Shelves have Boxes on them ( component Box)  that can be grouped by:
Author (not present yet but will be introduced), Creation time (by month), alphabetically by Title. Maybe lateralso by tags but skip that now.
Add row  with radio buttons for choice. Add a simple animation when sorting is changed.

Add a search strip that finds all events searched bu title (exact or partial match), author, word andywhere. Probably it is good to use Stackview to push the  Results page there.
The search rows are not always visible, just open it when user clicks on the search toolbuttton. 

## 3. Main architecture

```
Qt/QML client (iOS/Android (maybe WASM for demo)
        |
        v
   Events API  <---- Admin panel (native content entry: streams, live events)
        |
   Events DB   <---- Joomla importer (polls/receives webhook from Joomla,
        |             normalizes articles into the Events schema)
        v
 Notification service (FCM for Android/web push, APNs for iOS)
        
 Streaming server (Icecast/Liquidsoap for audio, RTMP->HLS via nginx-rtmp or MediaMTX for video) — Events DB just stores the resulting stream URL  and live/offline status.
```

Principles:
- The **Events API/DB is the single source of truth** the client talks to.
  It's a thin, purpose-built service — not a general CMS — so it can model
  streams, live status, and time windows cleanly.
- **Joomla stays as an editorial tool for article content only**, feeding   the Events DB through an importer, not queried live by the client. This   avoids coupling the app's uptime/performance to Joomla and avoids forcing   streaming/event concepts into Joomla's data model.
- **Streaming infrastructure is decoupled** from the CMS entirely; the  Events DB just references it.

## 4. Event JSON schema (draft, v2)


Type: 
text - simple text message (can be rich text), no media
audio| video -  link to url
audiostream | videostream -  live
article - html content from joomla or possible elsewhere
webcontent - iframe to anything

Skip thumbnail (url) for now, later perhaps automatic on  UI.
"comments_enabled": true  - for later
"status": "upcoming | live | past", -  probably not necessary

"payload" -  any data necessary to send

"shelf_at" - before that the message us shown in "CURRENT" or "NEW" in UI, later moves to "shelf"

```json
{
  "id": "evt_2026_07_16_001",
  "type": "text | audio | video | audiostream | videostream | article | webcontent",
  "title": "string",
  "summary": "string",
  "url": "https://...",
  "publish_at": "2026-07-20T18:00:00Z",
  "shelf_at": "2026-07-20T19:00:00Z",
  "status": "unpublished | new | shelved | archived", 
  "tags": ["string"],
  "payload": {},
 
}
```

`payload` is type-specific extra data (e.g. stream bitrate/codec info, embedded webapp config). Keep the top level stable; put anything volatile or type-specific in `payload` so the schema doesn't need to change per content type.

## 5. Notification system

- Use  Firebase and FastAPI on server side for push notifications. See fcm_notify_example.py. 
- Client: FCM on Android and web (WASM), APNs on iOS. Use Firebase API (via wrapper classes).
- Use cron system (every minute) to check if new events must be sent or some event changes status (new->shelved)


## 6. Joomla import

- Needs work to clarify: maybe Joomla import is poll-based (cron) or event-based (a small  Joomla plugin fires a webhook on article publish/update).

Process:
- user creates the article with joomla content creator in given category (47 at the moment); 
- remote server (that runs also notification server and database) checks via a crontab job if there are new articles 
-- Joomla API address:  https://eccm.ee/api/index.php/v1
-- get JOOMLA_API_KEY from enviroment
-- initial filters: content/articles?filter[state]=1&filter[category]=47 
- if there are new articles, adds them to notification database, using the publish_up for notification publish time (use 'now', if the time is in past) and publish_down ad "move to shelf" time in the database. If is unset, take 7 days from publish time,  



## 7. Editor

Web page that manages events in the database. Notification server uses cron to send new events.
Also accept "Now" as possible publish time (send directily to notification server and set published_at to current time).

Common fields to all types:
- Title 
- Summary (used in notification text):
- Type: "text | audio | video | audiostream | videostream | article | webcontent"
- Announce at:  time/date select,  support also "Now" 
- Put to shelf at (moved from "new" items to normal, "shelved" items) // optional, if empty, take a week from publishing time
- Tags (comma separated)

The 'status' is set to 'unpublished' by default, unless publish is "now"
Use smart seach for Tags (when user start to type, suggest existing tags. If it is s new tag, add it to the database, table tags)

Other parameters that do not have a db field are kept/sent in payload field.

Fields depending on type:
"text": 
- Text 
- no URL

All others:
- Content URL:

"audiostream | videostream":
- Live at  // time, send in payload
- Server address: // default https://live.uuu.ee/stream

TODO: proper support of audio streams, needs a separate streaming service.


## 8. Streaming (receivng)

Use U:'s streaming service for testing.

Video (based on nginx):

sending (OBS Studio, IRL Pro from mobile)
rtmp://live.uuu.ee/live/stream
the last part, "stream" can be various keys. 
rtmp://live.uuu.ee/live/<key>

Watching 
https://live.uuu.ee:4443/hls/<key>.m3u8
Web wrapper (audio muted at the moment): https://live.uuu.ee/live



Audio:

Sending: rtmp://live.uuu.ee/audio/stream 

Listening:
https://live.uuu.ee:4443/hls_audio/stream.m3u8

(use any key instead of "stream" )



nginx.conf streaming section:
```
server {
        listen 8080;
        location /hls {
            types {
                application/vnd.apple.mpegurl m3u8;
                video/mp2t ts;
            }
            root /var/www/html;
            add_header Cache-Control no-cache;
            add_header Access-Control-Allow-Origin *;
        }
    }

    # --- HTTPS server (nt 4443) ---
    server {
        listen 4443 ssl;
        server_name _;

        ssl_certificate     /etc/ssl/private/live.uuu.ee.pem;
        ssl_certificate_key /etc/ssl/private/private.key;

        location /hls {
            types {
                application/vnd.apple.mpegurl m3u8;
                video/mp2t ts;
            }
            root /var/www/html;
            add_header Cache-Control no-cache;
            add_header Access-Control-Allow-Origin *;
        }

        location / {
            root /var/www/html;
            index index.html player.html;
        }
    }
}


rtmp {
    server {
        listen 1935; # RTMP port
        chunk_size 4096;

        application live {
            live on;
            record on;
            record all;
            record_path /var/recordings/video;
            record_unique on;
            record_suffix -%Y%m%d-%H%M%S.flv;
            exec_publish /usr/local/bin/rtmp_on_publish.sh $app $name;
            exec_record_done /usr/local/bin/rtmp_on_record_done.sh $path $app $name;

            # HLS väljund
            hls on;
            hls_path /var/www/html/hls;
            hls_fragment 2s;
            hls_playlist_length 10s;
        }
    }
}
```

`exec_publish` fires when a source starts publishing: `server/rtmp_on_publish.sh`
publishes a `type="livestream"` event (same `POST /events/publish` the Icecast hooks
below use for audio) with a `"<name> is live on 'video'"` notification, and persists
the created event id to `/tmp/rtmp_event_<name>.id`.

`exec_record_done` fires once nginx-rtmp closes the recorded `.flv` (effectively at
disconnect, since `record_unique` gives one file per connection) - that's `server/
rtmp_on_record_done.sh`'s "stream ended" hook: it unpublishes the event immediately,
then in the background converts the `.flv` (remux to `.mp4` if it has a video track,
else extract to `.mp3`), moves it to `eccm.ee:/home/eccmee1/www/radio1965/streams/video/`,
and finalizes the event into a playable `type="streamrecording"` - mirroring
`icecast_on_disconnect.sh`'s audio flow (#8.2.1 below).


### 8.1 Audio streaming from Icecast

Icecast server running on remote sever (port 8001 for now)

Test send:
ffmpeg -re -f lavfi -i "sine=frequency=440:duration=60"   -c:a libmp3lame -b:a 128k   -content_type audio/mpeg   -f mp3 icecast://source:<Password>@live.uuu.ee:8001/radio1965

or as a looping file:
ffmpeg -re -stream_loop -1 -i raba.mp3 -c:a copy -content_type audio/mpeg   -f mp3 icecast://source:<Password>@185.169.69.8:8001/radio1965


Listen:
http://185.169.69.8:8001/radio1965

Channels (streams): 
- radio1965 -  continuos playlist/generated stream -- no recording, no notification
- live -  live audio broadcast (by managers) -  save, notification (by default)
- user1-user4 -  for broadcasting from the app (or elsewhere) for users


Hooks on starting/stopping streams (in icecast.xml)

<mount>
    <mount-name>/user1</mount-name>
    <on-connect>/usr/local/bin/stream-started.sh</on-connect>
    <on-disconnect>/usr/local/bin/stream-stopped.sh</on-disconnect>
</mount>

Predefine this way  4 channels (user1, user2 etc)

To get info about a stream in the script:
curl -s "http://localhost:8001/status-json.xsl"
Returns JSON with active sources, including things like:
listenurl
server_name / server_description (if the source client sent them)
bitrate
content-type (e.g. audio/mpeg)
listeners (current count)

### 8.2 Storing streams

Storage location: save locally, then move to given remote location.

Move the stream over ssh protocol (rsync or scp or similar) to: eccm.ee folder
/home/eccmee1/www/radio1965/streams
User, port and key are already configured on the server.

#### 8.2.1 Audio

When save_stream is 1, start saving audio stream as mp3. Filename: combined fro title (make the string url friendly, not longer than 20 characters) + date + .mp3 

When stream is ended (and save_stream==1), close audio file

### 8.2.2 Storing video streams (nginx)

Recorded locally to .flv by nginx-rtmp's `record_path /var/recordings/video` (#8
above). Conversion to .mp4 and the move to eccm.ee is handled by `server/
rtmp_on_record_done.sh` via the `exec_record_done` hook - see #8 above.



## 9. Broadcasting audio from app to Icecast

FFmpeg (libavformat/libavcodec)
This is the most common approach. FFmpeg's libavformat can open an rtmp:// URL as an output and handles the whole RTMP handshake/FLV muxing for you — you just feed it encoded audio (and video) packets. You'd:

Capture PCM via QAudioSource
Encode to AAC via libavcodec (or Android's native MediaCodec AAC encoder if you want to skip FFmpeg's audio encoder)
Mux + push via libavformat to Icecast.


## 10. Registration

1) 1) Temporary contributor  
- user can become a temporay contributor (role "temporaryContributor") by entering name and password
- no need to ask for email address
- check the password on the server, not locally. Store the password in a protected text file (via permissions) on  but do not encrypt it -  it should easy to edit the file and replace the password.
- the role is valid for 24 hours and then resets to normal
- temporaryContributor has broadcasting limit (like 5 minutes) - max broadcastLimit minutes per session, then automatic stop for broadcast, disable broadcasting button for the next broadcastLimit minutes.

2) Permanent contributor.

New table: users:

id | name | email | role (null|pending|contributor|manager|banned) | password

Add field 'author' in table 'events' (linked to users)

In app menu "Become a contributor" 

    
For production version:
    -> onClick:  show dialog with rights and rules, field for name and email + password + repeat password.  If OK pressed,
        -> mark the name and email into tabel 'users', role 'pending', send confirmation email. If confirmed, mark 'contributor'. 
        How to let the app know? Notification only to this device? Restart app? Or rather on "Refresh events"

Only people with role "contributor", "temporaryContributor" and "manager" can broadcast and make new event -  BroadcastPage (also in TabBar) disabled if not contributor|manager. Add Popup "You must be contributor or manager to broadacst"

TODO: Add login option to menu: "Become a contributor/Log in"
- in registration, check if already registered, direct to login then.
- add "Forgot password" to login page

3) 
TODO: rewrite editor page, that requires e-mail and password but can receive it also from URL 
? What about joomla?

4) Add action "Share a gem"  in menu (if contributor|manager)-> opens editor page with email and (encoded) password in the URL. 

In app: store name, email, password in app settings. On startup, check and set for role and set it in settings. Add button "Reset role" to main menu.

If user is marked 'banned' -  do not allow use of the app at all. (Show popup "You exiled. Contact the admistrators if it feels unjust.")

In table 'events' add column 'author_id' - user who enetered the event.  

## 11. Manager page

Create a web page for managing the database (manager/index.html), will be hosted on eccm.ee

Add pushing the page to eccm.ee to github actions.

Login:  users with type 'contributor' and 'manager' can log with their credentials.

'contributor' can edit only their events, 'manager' everything.

1) Table "Events"  - enum fields as Selction, others as text. What is good editing mean for date/time fields?

2) Users -  show ownly for managers.

3) Tags -  do not show for now.

Add a filter bar (similar to Beekeeprs tudio) to find/filter rows.

Like Beekeeper - when something in a line is changed, mark it with a color (light green or similar), when a line is to be deleted (light red or similar) and Have a "Apply" button somehwere to make the changes to database.

When a row with streamrecording is being deleted, ask if also audiofile (on eccm.ee) should be deleted.

Create a crontab job to make copies of the databse every Monday, keep last 4 backups.


## 99. Ideas.

Think of the app/project as **library** -  new items, catlogues, shelves, items lost, order/wish lists, meeting with authors, *vorlesungen* etc I
