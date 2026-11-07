import QtCore
import QtQuick
import QtMultimedia
import "DummyEvents.js" as DummyEvents

// Global playback state, replacing the per-page MediaPlayer that used to
// live inside PlayerPage.qml. Instantiated exactly once in Main.qml (id:
// playbackController) and passed down explicitly to PlayerBar, VideoPage,
// and EventListView - same "pass it down" convention this codebase already
// uses for navigationStack/serverBaseUrl - rather than as a `pragma
// Singleton`: bare `PlaybackController.xxx` global access did not resolve
// at runtime in this Qt/CMake setup (qmldir did not pick up the singleton
// registration from QML_FILES), so an explicitly-instantiated-and-threaded
// object is used instead. Not page-scoped, so playback survives tab
// switches and StackView pushes.
QtObject {
    id: root

    // Fallback for isLive when no per-event url is set - a tapped
    // livestream card with a real url (e.g. an Icecast channel, see
    // app/icecastbroadcaster.cpp) plays that instead, per start().
    readonly property string liveStreamUrl: "https://live.uuu.ee:4443/hls/stream.m3u8"

    // radio1965's public listen URL - moved off the Icecast box (behind
    // live.uuu.ee:8001, where status-json.xsl can see it) to this relay, so
    // its own occupancy can't come from status-json.xsl either - checked
    // separately below, same as liveStreamUrl/videoStreamLive.
    readonly property string radio1965StreamUrl: "https://v2in.stream/stream/radio1965"

    // The channels are v2in's (https://v2in.stream), as its GET /api/now lists them (today radio1965, kcmd and
    // live), so a channel added there needs no app release; none until the first answer, which chooses its first
    // channel when none of its channels is chosen. The same answer
    // says what each one plays now (title, by, a date; who is live; silent during an air-raid alert in Kyiv), read
    // every 10 s while the app is open, since the Home tab's cards (ChannelList.qml) show it, never while the app is
    // in the background. A tapped livestream card still plays its own url (playMedia), wherever it is.
    readonly property string v2inBaseUrl: "https://v2in.stream"
    property var v2inNow: null
    // true after a failed GET /api/now, false after the next good one (ChannelList.qml's error line)
    property bool v2inError: false
    // A channel of several streamers (its live a list in GET /api/now's channels, e.g. community) is listed as v2in's
    // front page shows it, by name and never by its slots (community-1, ...): mixed and playing (it has a stream), the
    // channel itself, playing its mix; unmixed with someone live, one entry per show, "<name>: <show>", each playing its
    // own slot; otherwise the channel itself, which does not play and says "Nobody live now" or the raid's line.
    readonly property var channelOptions: root.v2inNow
        ? root.v2inNow.channels.reduce((all, c) => all.concat(root._isSeveral(c) && !c.stream && c.live.length
              ? c.live.map(l => l.channel) : [c.id]), [])
        : []
    function isV2inChannel(channel) {
        return root.channelOptions.indexOf(channel) !== -1;
    }
    function _isSeveral(c) {
        return Array.isArray(c.live);
    }
    // { pool, live } for a channel of several by its id (live null) or one of its live slots, in `now` (an /api/now
    // answer); null for any other
    function _poolEntry(channel, now) {
        for (const p of ((now && now.channels) || []).filter(c => root._isSeveral(c))) {
            if (p.id === channel)
                return { pool: p, live: null };
            const l = p.live.find(x => x.channel === channel);
            if (l)
                return { pool: p, live: l };
        }
        return null;
    }
    // A channel of one as /api/now gives it; a channel of several, or one of its shows, in the same shape (status
    // "offline" for one that has nothing to play, so it is not offered to play; live the list of who is in a mix)
    function v2inChannel(channel) {
        if (!root.v2inNow)
            return null;
        const e = root._poolEntry(channel, root.v2inNow);
        if (!e)
            return root.v2inNow.channels.find(x => x.id === channel) || null;
        if (e.live)
            return { id: channel, name: e.pool.name, pool: true, status: e.pool.status === "silent" ? "silent" : "live",
                     title: e.live.title, by: e.live.artist, live: e.live };
        if (e.pool.stream)
            return { id: channel, name: e.pool.name, pool: true, status: e.pool.status, title: e.pool.title, by: e.pool.by,
                     date: e.pool.date, live: e.pool.live };
        return { id: channel, name: e.pool.name, pool: true, status: e.pool.status === "silent" ? "silent" : "offline",
                 title: "", by: "", live: null, silence: e.pool.status === "silent" ? e.pool.title : "" };
    }
    // What PlayerBar's channel picker shows: a channel of one's id, as before; a channel of several by its name, with
    // its show (or who is in its mix), or with "Nobody live now" or the raid's line
    function channelLabel(channel) {
        const c = root.v2inChannel(channel);
        if (!c || !c.pool)
            return channel;
        const line = c.live ? [c.by, c.title].filter(Boolean).join(" - ") : (c.silence || qsTr("Nobody live now"));
        return line ? c.name + ": " + line : c.name;
    }
    function refreshV2inNow() {
        // the RADIO65_LAYOUT_PREVIEW build has no backend: DummyEvents.js's answer, so the cards show
        if (layoutPreview) {
            root._takeV2inNow(DummyEvents.now);
            return;
        }
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            if (xhr.status !== 200) {
                root.v2inError = true;
                return;
            }
            let now;
            try { now = JSON.parse(xhr.responseText); } catch (e) { root.v2inError = true; return; }
            root.v2inError = false;
            root._takeV2inNow(now);
        };
        xhr.open("GET", root.v2inBaseUrl + "/api/now");
        xhr.send();
    }
    function _takeV2inNow(now) {
        const before = root._poolEntry(root.selectedChannel, root.v2inNow);
        root.v2inNow = now;
        if (root.channelOptions.indexOf(root.selectedChannel) === -1) {
            const pool = before ? root.v2inNow.channels.find(p => p.id === before.pool.id && root._isSeveral(p)) : null;
            if (pool)
                root._poolChanged(pool);
            else
                root.selectedChannel = root.channelOptions[0] || "";
        }
        root.refreshLiveInfo();
    }
    // The chosen entry of a channel of several is gone: its show ended, someone went live on an idle one, or its mix
    // began or ended. Its mix is chosen while it plays, else its first live show, else the channel itself; one that was
    // playing goes on with that, or stops when nothing is left.
    function _poolChanged(pool) {
        const playing = root.playingLive;
        const next = !pool.stream && pool.live.length ? pool.live[0].channel : pool.id;
        root.selectedChannel = next;
        if (!playing)
            return;
        if (next === pool.id && !pool.stream)
            root.stop();
        else
            root.start();
    }
    // A live channel is playing, tuning in or being tuned in again (_retryTimer), not stopped
    readonly property bool playingLive: root.isLive && !root.mediaUrl
        && (player.playbackState !== MediaPlayer.StoppedState || root.liveStreamOffline || root.loading)
    // The card of `channel` (a channel or one of its slots) shows stop while this is true, a busy ring while tuning
    function isPlayingChannel(channel) {
        return root.playingLive && root.selectedChannel === channel;
    }
    function isTuning(channel) {
        return root.isPlayingChannel(channel) && root.loading;
    }
    // A channel's slots open or folded under its card, kept across launches as v2in.stream keeps them in its
    // browser; folded by default
    property Settings channelSettings: Settings {
        category: "Channels"
        property string foldOpenJson: "{}"
    }
    property var foldOpen: ({})
    function setFoldOpen(channel, open) {
        const next = Object.assign({}, root.foldOpen);
        if (open)
            next[channel] = true;
        else
            delete next[channel];
        root.foldOpen = next;
        root.channelSettings.foldOpenJson = JSON.stringify(next);
    }

    property Timer _v2inTimer: Timer {
        interval: 10000
        repeat: true
        triggeredOnStart: true
        running: Qt.application.state === Qt.ApplicationActive
        onTriggered: root.refreshV2inNow()
    }

    // Which channels currently have a source connected - reuses
    // icecastBroadcaster's existing status-json.xsl fetch/parse
    // (app/icecastbroadcaster.cpp, already built for BroadcastPage.qml's
    // occupied-channel disabling) rather than duplicating that network
    // call here. icecastBroadcaster is only a context property on builds
    // with RADIO65_ENABLE_BROADCAST, hence the typeof guard - same
    // defensive pattern BroadcastPage.qml already uses.
    readonly property bool occupancyAvailable: typeof icecastBroadcaster !== "undefined"
    property var occupiedChannels: []
    // "video" (the main HLS stream) isn't an Icecast mountpoint, so its
    // occupancy can't come from status-json.xsl - checked separately below
    // via a plain GET against liveStreamUrl itself.
    property bool videoStreamLive: false
    // Same reasoning as videoStreamLive, now that radio1965 is no longer an
    // Icecast mountpoint reachable via status-json.xsl either.
    property bool radio1965StreamLive: false

    function _checkStreamLive(url, callback) {
        // Resolve as soon as headers arrive, not on DONE - a live
        // stream's body never ends on its own (confirmed via `curl -v
        // --max-time 5`: headers land instantly, body just keeps
        // streaming until the connection is forcibly cut), so waiting
        // for DONE here would hang forever instead of ever reporting
        // "live". abort() once the status is known so this doesn't sit
        // there quietly downloading live audio/video in the background -
        // deferred to the next event-loop tick via a one-shot Timer
        // rather than called inline, since calling xhr.abort()
        // synchronously from inside this same onreadystatechange handler
        // crashes (QIODevice::readAll() re-entering while Qt's network
        // reply machinery is still processing the very signal that
        // triggered this callback).
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState === XMLHttpRequest.HEADERS_RECEIVED) {
                callback(xhr.status >= 200 && xhr.status < 300);
                const abortTimer = Qt.createQmlObject(
                    "import QtQuick; Timer { interval: 0; running: true }", root);
                abortTimer.triggered.connect(function () {
                    xhr.abort();
                    abortTimer.destroy();
                });
            }
        };
        xhr.open("GET", url);
        xhr.send();
    }

    function refreshChannelAvailability() {
        if (root.occupancyAvailable)
            icecastBroadcaster.refreshOccupiedChannels();

        root._checkStreamLive(root.liveStreamUrl, function (live) { root.videoStreamLive = live; });
        root._checkStreamLive(root.radio1965StreamUrl, function (live) { root.radio1965StreamLive = live; });
    }

    function isChannelStreaming(channel) {
        const c = root.v2inChannel(channel);
        if (c)
            return c.status !== "offline";
        if (channel === "video")
            return root.videoStreamLive;
        if (channel === "radio1965")
            return root.radio1965StreamLive;
        return root.occupiedChannels.indexOf(channel) !== -1;
    }

    property Connections _occupancyConnections: Connections {
        target: root.occupancyAvailable ? icecastBroadcaster : null
        function onOccupiedChannelsChanged(list) { root.occupiedChannels = list; }
    }

    Component.onCompleted: {
        root.refreshChannelAvailability();
        root._loadRecentMedia();
        try { root.foldOpen = JSON.parse(root.channelSettings.foldOpenJson); } catch (e) { root.foldOpen = {}; }
    }

    property string mediaUrl: ""
    property string mediaTitle: ""
    property string mediaSummary: ""
    // Defaults true (not false) so the channel picker in PlayerBar.qml is
    // visible immediately on launch - the "Live" tab that used to be the
    // discovery/entry point for tuning in is gone, so the persistent strip
    // has to take over that role. Nothing actually plays until the user
    // presses Play or picks a channel, though - see start()/selectChannel().
    property bool isLive: true
    property string selectedChannel: ""   // v2in's first channel once /api/now answers

    // Local playback history, kept though PlayerBar's recent-media picker
    // that listed it is gone (project-description.md #8.2.1's "Save
    // stream" recordings included - anything played via playMedia() with
    // isLive=false), persisted via QtCore.Settings same as
    // BroadcastPage.qml's broadcastSettings. Settings can't natively store
    // an array of objects, hence the JSON-string round-trip.
    // Wrapped in a `property Settings ...:` assignment, not a bare child
    // declaration - QtObject (this file's root type) has no default
    // property to receive bare children, unlike Item (same reason
    // _occupancyConnections/player/_retryTimer below are all declared this
    // way rather than as plain child objects).
    property Settings recentMediaSettings: Settings {
        id: recentMediaSettings
        category: "RecentMedia"
        property string itemsJson: "[]"
    }
    property var recentMedia: []
    readonly property int maxRecentMedia: 15

    // Persists PlayerBar.qml's volume slider across launches, same Settings
    // pattern as recentMediaSettings above.
    property Settings playbackSettings: Settings {
        id: playbackSettings
        category: "Playback"
        property real volume: 1.0
    }

    function setVolume(volume) {
        player.audioOutput.volume = volume;
        playbackSettings.volume = volume;
    }

    function _loadRecentMedia() {
        try {
            root.recentMedia = JSON.parse(recentMediaSettings.itemsJson);
        } catch (e) {
            root.recentMedia = [];
        }
    }

    function _recordRecentMedia(url, title, summary) {
        if (!url)
            return;
        // Dedupe by url and move to front, rather than allowing the same
        // item to appear twice or staying stuck at its old position when
        // replayed.
        const filtered = root.recentMedia.filter(item => item.url !== url);
        filtered.unshift({ url: url, title: title, summary: summary });
        root.recentMedia = filtered.slice(0, root.maxRecentMedia);
        recentMediaSettings.itemsJson = JSON.stringify(root.recentMedia);
    }

    property bool loading: false
    property string errorMessage: ""
    // Specifically "the live HLS/Icecast source 404s" (MediaPlayer.ResourceError
    // while isLive), as opposed to some other playback error - drives the
    // auto-retry Timer below without spamming retries for unrelated errors.
    property bool liveStreamOffline: false
    property bool expanded: false

    property var liveInfo: null
    readonly property string displayTitle: liveInfo ? liveInfo.title
                                                      : (root.mediaTitle || (root.isLive ? qsTr("Live Stream") : ""))
    readonly property string displaySummary: liveInfo ? liveInfo.summary : root.mediaSummary

    function refreshLiveInfo() {
        if (!root.isLive) {
            // Otherwise a stale liveInfo from a previous live session would
            // keep overriding displayTitle/displaySummary for whatever
            // plays next (e.g. switching to a video event) - see start(),
            // which now calls this unconditionally instead of only when
            // isLive.
            root.liveInfo = null;
            return;
        }
        // Same url start() actually plays (mediaUrl wins if set - e.g. a
        // tapped livestream card - otherwise the selected channel) - not
        // just root.selectedChannel, so this stays correct for both entry
        // points into live playback.
        // a v2in channel says itself what it plays (GET /api/now): the show or the file, by whom, a date apart; the
        // raid's line while it is silent
        const v2in = root.mediaUrl ? null : root.v2inChannel(root.selectedChannel);
        if (v2in && v2in.pool && !v2in.live) {
            root.liveInfo = { title: v2in.name, summary: v2in.silence || qsTr("Nobody live now") };
            return;
        }
        // a mix plays who is live in it, named as its card names them
        if (v2in && v2in.pool && Array.isArray(v2in.live) && v2in.live.length && !v2in.title && !v2in.by) {
            root.liveInfo = { title: v2in.live.map(l => l.title || l.artist).filter(Boolean).join(", ") || qsTr("Live"),
                              summary: qsTr("Live on v2in") };
            return;
        }
        if (v2in && v2in.status !== "offline" && (v2in.title || v2in.by)) {
            root.liveInfo = { title: [v2in.by, v2in.title].filter(Boolean).join(" - "),
                              summary: v2in.status === "silent" ? qsTr("Silent until the alert ends")
                                     : v2in.status === "live" ? qsTr("Live on v2in") : (v2in.date || "") };
            return;
        }
        const liveUrl = root.mediaUrl || root.channelUrl(root.selectedChannel);
        const info = notificationManager.findLiveStream(liveUrl);
        root.liveInfo = (info && info.title) ? info : null;
    }

    property Connections _notificationConnections: Connections {
        target: notificationManager
        function onDataChanged() { root.refreshLiveInfo(); }
        function onRowsInserted() { root.refreshLiveInfo(); }
        function onRowsRemoved() { root.refreshLiveInfo(); }
    }

    function channelUrl(channel) {
        return root.v2inBaseUrl + "/stream/" + channel;
    }

    // Called by a channel card's play (ChannelCard.qml) - starts playback
    // immediately, switching from whatever played before (one stream at a
    // time).
    function selectChannel(channel) {
        root.selectedChannel = channel;
        root.isLive = true;
        root.mediaUrl = "";
        root.mediaTitle = "";
        root.mediaSummary = "";
        root.start();
    }

    // Called by EventListView.qml instead of pushing PlayerPage.qml.
    function playMedia(url, title, summary, isLive) {
        root.isLive = isLive;
        root.mediaUrl = url;
        root.mediaTitle = title;
        root.mediaSummary = summary;
        // Keep selectedChannel in sync with whatever's actually playing -
        // e.g. tapping a "livestream" Card/notification for "user1" while
        // selectedChannel was still "radio1965" from a previous session.
        // A plain property write, not a call to selectChannel()/start(), so
        // it can't re-enter start() (the call below already covers that).
        if (isLive) {
            const matched = root.channelOptions.find(channel => root.channelUrl(channel) === url);
            if (matched)
                root.selectedChannel = matched;
        }
        // Only fixed (non-live) items go into history - EventDelegate.qml
        // only passes isLive=true for type="livestream" cards (an
        // in-progress broadcast), so this naturally covers
        // audio/video/streamrecording without any type-checking here.
        if (!isLive)
            root._recordRecentMedia(url, title, summary);
        root.start();
    }

    function start() {
        // a channel of several with nothing to play (nobody live, no mix): its line says so
        const idle = root.isLive && !root.mediaUrl ? root.v2inChannel(root.selectedChannel) : null;
        if (idle && idle.pool && !idle.live) {
            player.stop();
            root.loading = false;
            root.liveStreamOffline = false;
            root.refreshLiveInfo();
            return;
        }
        root.loading = true;
        root.errorMessage = "";
        root.liveStreamOffline = false;

        // Reassigning `source` to the same URL it already holds is a no-op
        // in QML (the write is skipped when the new value equals the
        // cached one) - clearing it first forces MediaPlayer to genuinely
        // reload instead of silently doing nothing.
        player.source = "";
        root.refreshLiveInfo();
        if (root.isLive) {
            player.source = root.mediaUrl || root.channelUrl(root.selectedChannel);
        } else {
            player.source = root.mediaUrl;
        }
        player.play();
    }

    function togglePlayPause() {
        // player.source is QUrl-typed, not a plain string - comparing it
        // to "" with === (or even ==) never matches even when the URL is
        // genuinely empty (e.g. on fresh launch, before anything has ever
        // been loaded), because QML exposes it as a "url" value-type
        // object rather than a JS string. .toString() forces a real
        // comparison. Without this fix, pressing Play on first launch fell
        // through to player.play() with nothing loaded - a silent no-op.
        if (player.source.toString() === "" && !root.loading) {
            root.start();
        } else if (player.playbackState === MediaPlayer.PlayingState) {
            player.pause();
        } else {
            player.play();
        }
    }

    // Just stops playback - does NOT touch mediaUrl/isLive/title (PlayerBar
    // hides once stopped) - use backToChannels() for an explicit return to
    // radio mode.
    function stop() {
        player.stop();
        root.errorMessage = "";
        root.liveStreamOffline = false;
    }

    // Explicit "done listening to this file, back to radio" action - stops
    // playback and resets isLive/mediaUrl/liveInfo. Not currently wired to
    // any PlayerBar.qml control - left available for whatever
    // future control needs a full reset back to live/idle.
    function backToChannels() {
        player.stop();
        player.source = "";
        root.mediaUrl = "";
        root.mediaTitle = "";
        root.mediaSummary = "";
        root.liveInfo = null;
        root.isLive = true;
        root.errorMessage = "";
        root.liveStreamOffline = false;
    }

    property MediaPlayer player: MediaPlayer {
        id: player
        audioOutput: AudioOutput { volume: root.playbackSettings.volume }

        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.BufferedMedia)
                root.loading = false;
            // a live stream that ends by itself (the server restarted, the connection closed) is tuned in again by
            // _retryTimer, as one that was not there; a stop by the user never reaches EndOfMedia
            if (mediaStatus === MediaPlayer.EndOfMedia && root.isLive) {
                root.liveStreamOffline = true;
                root.errorMessage = qsTr("Reconnecting");
            }
        }

        // Keeps the display from timing out while something is actively
        // playing - the single biggest cause of accidental backgrounding
        // for a radio app. No-op on desktop (screenkeeper_noop.cpp).
        onPlaybackStateChanged: screenKeeper.setEnabled(playbackState === MediaPlayer.PlayingState)

        onErrorOccurred: (error, errorString) => {
            root.loading = false;
            // a live stream lost on the way (NetworkError) is tried again like one not found (ResourceError)
            if (root.isLive && (error === MediaPlayer.ResourceError || error === MediaPlayer.NetworkError)) {
                root.liveStreamOffline = true;
                root.errorMessage = qsTr("No live stream");
            } else {
                root.liveStreamOffline = false;
                root.errorMessage = errorString || qsTr("Playback failed");
            }
        }
    }

    // Drives auto-retry: a live source can go from offline to on-air while
    // the user is elsewhere in the app, and MediaPlayer never retries a
    // failed source on its own. Global now (no SwipeView-visibility gating
    // needed like the old embedded Live tab had) since this is always
    // relevant regardless of which page is currently showing.
    property Timer _retryTimer: Timer {
        interval: 8000
        repeat: true
        running: root.isLive && root.liveStreamOffline
        onTriggered: root.start()
    }
}
