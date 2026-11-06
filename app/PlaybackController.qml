import QtCore
import QtQuick
import QtMultimedia

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
    // live), so a channel added there needs no app release; radio1965 alone until the first answer. The same answer
    // says what each one plays now (title, by, a date; who is live; silent during an air-raid alert in Kyiv), read
    // every 10 s while one plays and every minute otherwise, never while the app is in the background. A tapped
    // livestream card still plays its own url (playMedia), wherever it is.
    readonly property string v2inBaseUrl: "https://v2in.stream"
    property var v2inNow: null
    readonly property var channelOptions: root.v2inNow ? root.v2inNow.channels.map(c => c.id) : ["radio1965"]
    function isV2inChannel(channel) {
        return root.channelOptions.indexOf(channel) !== -1;
    }
    function v2inChannel(channel) {
        return root.v2inNow ? (root.v2inNow.channels.find(c => c.id === channel) || null) : null;
    }
    function refreshV2inNow() {
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200)
                return;
            try { root.v2inNow = JSON.parse(xhr.responseText); } catch (e) { return; }
            root.refreshLiveInfo();
        };
        xhr.open("GET", root.v2inBaseUrl + "/api/now");
        xhr.send();
    }
    property Timer _v2inTimer: Timer {
        interval: root.isLive && root.isV2inChannel(root.selectedChannel) ? 10000 : 60000
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
    property string selectedChannel: "radio1965"

    // Purely which combobox PlayerBar.qml shows (live channels vs recent
    // media) - independent of isLive/mediaUrl so toggling this in the UI
    // never touches actual playback, only which picker is visible.
    property bool browsingRecentMedia: false

    function toggleSelectorMode() {
        root.browsingRecentMedia = !root.browsingRecentMedia;
    }

    // Local playback history (project-description.md #8.2.1's "Save
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

    // Called by PlayerBar's channel ComboBox onActivated (a real user pick,
    // not merely opening the popup) - starts playback immediately so the
    // user doesn't need a separate Play press after picking a channel.
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
        // Keep PlayerBar's channel ComboBox (bound to selectedChannel) in
        // sync with whatever's actually playing - e.g. tapping a
        // "livestream" Card/notification for "user1" while selectedChannel
        // was still "radio1965" from a previous session left the ComboBox
        // showing the wrong channel even though the right one was playing.
        // Only PlayerBar's own onActivated calls selectChannel() directly
        // (a real user pick), so updating selectedChannel here - a plain
        // property write, not a call to selectChannel()/start() - can't
        // cause a double-trigger: it neither re-enters start() itself (the
        // call below already covers that) nor fires onActivated, which only
        // reacts to actual popup interaction, not a currentIndex binding
        // update.
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

    // Just stops playback - does NOT touch mediaUrl/isLive/title, so the
    // strip keeps showing what was loaded (e.g. an audio file's title, with
    // Play available to resume it) instead of jumping back to the channel
    // picker on its own. Previously this reset straight to radio mode,
    // which looked wrong when Stop was pressed on a fixed-media item (the
    // combobox would appear even though the file was still the loaded
    // item) - use backToChannels() for an explicit return to radio mode.
    function stop() {
        player.stop();
        root.errorMessage = "";
        root.liveStreamOffline = false;
    }

    // Explicit "done listening to this file, back to radio" action - stops
    // playback and resets isLive/mediaUrl/liveInfo. Not currently wired to
    // any PlayerBar.qml control (the old media-icon tap that used to call
    // this now calls toggleSelectorMode() instead, which is a pure view
    // toggle that never touches playback) - left available for whatever
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
        }

        // Keeps the display from timing out while something is actively
        // playing - the single biggest cause of accidental backgrounding
        // for a radio app. No-op on desktop (screenkeeper_noop.cpp).
        onPlaybackStateChanged: screenKeeper.setEnabled(playbackState === MediaPlayer.PlayingState)

        onErrorOccurred: (error, errorString) => {
            root.loading = false;
            if (root.isLive && error === MediaPlayer.ResourceError) {
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
