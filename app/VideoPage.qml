import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import QtQuick.Window

// Pushed onto Main.qml's StackView (with the shared PlaybackController
// instance passed as an initial property) while the currently-playing
// media file has a video track, or with liveVideo true when a channel card's
// video button is tapped (ChannelCard.qml).
//
// liveVideo: PlaybackController's videoPlayer plays the channel's /api/now
// video here, picture and sound from the one HLS stream, while the channel's
// Icecast stream stops. Back stops the video and tunes the channel in again;
// the page closes by itself when the video ends. A mix shows one member's
// video, its members' names along the bottom switch to another. During a raid
// the picture is covered with the raid's line until the video comes back.
//
// Windowed mode: playback is controlled by the always-visible PlayerBar
// strip above the StackView, same as before - the top bar here is just
// back/title/fullscreen-toggle, always visible, styled as an overlay
// (transparent background) purely so both modes share one structure.
//
// Fullscreen mode: Main.qml hides PlayerBar while
// Window.visibility===FullScreen (it has no room and would defeat the
// point of fullscreen), so this page grows its own auto-hiding overlay
// controls (top: back/title/exit-fullscreen, bottom: play/pause/seek/time)
// - tap the video to reveal, fades out after a few seconds of inactivity.
// project-description.md TODOs: "Video fullscreen dows not fill the screen
// on mobile devices" / "the seek bar should be below the video... how in
// fullscreen" - both addressed by VideoOutput now always filling the whole
// Page (no header reserving space) and this overlay pair.
Page {
    id: root
    required property PlaybackController controller
    property bool liveVideo: false
    // the channel's video ended (not a raid, which keeps the page under its cover): closed a moment later, so the
    // sound tuning in again (its player passes through stopped) does not close it
    readonly property bool liveVideoGone: root.liveVideo && root.controller.videoUrl === ""
                                          && !root.controller.videoRaidCover
    Timer {
        interval: 1500
        running: root.liveVideoGone
        onTriggered: root.closeVideoPage()
    }

    readonly property bool fullscreenActive: root.Window.window && root.Window.window.visibility === Window.FullScreen
    property bool controlsVisible: true

    // Restored on exit instead of hardcoding Window.Windowed: on platforms
    // with no real windowed mode (iOS/iPadOS), the window's visibility
    // before entering fullscreen is whatever the OS gave it automatically
    // (not Windowed) - forcing Windowed there makes Qt apply Main.qml's
    // literal width/height as real on-screen geometry, shrinking the whole
    // app down instead of returning it to filling the iPad's screen.
    property int previousVisibility: Window.Windowed

    function toggleFullscreen() {
        if (!root.Window.window)
            return;
        if (root.fullscreenActive) {
            root.Window.window.visibility = root.previousVisibility;
        } else {
            root.previousVisibility = root.Window.window.visibility;
            root.Window.window.visibility = Window.FullScreen;
        }
        root.controlsVisible = true;
    }

    // User-initiated close (the "←" button and the edge-swipe gesture
    // below) - unlike Main.qml's own reactive pop when hasVideo goes false
    // on its own (e.g. switching to a different, video-less item, where
    // playback is already moving on to something else and must NOT be
    // stopped here), the user explicitly closing this page means they're
    // actually done with it: stop playback for real (not just stop
    // rendering it - root.controller.stop() per PlaybackController.qml's
    // own stop() still leaves it resumable, same as the player strip's own
    // Stop button), and restore the window out of fullscreen first so
    // PlayerBar (hidden only while Window.FullScreen, see Main.qml) reliably
    // reappears instead of staying hidden behind the now-popped page.
    function closeVideoPage() {
        if (root.fullscreenActive)
            root.toggleFullscreen();
        // a channel's video stops and its Icecast stream plays again
        if (root.liveVideo)
            root.controller.hideVideo(videoOutput);
        else
            root.controller.stop();
        root.StackView.view.pop();
    }

    // Same small independent duplicate as PlayerBar.qml's formatTime()/
    // BroadcastPage.qml's formatElapsed() - established convention in this
    // codebase for this exact helper rather than a shared utility import.
    function formatTime(ms) {
        function pad(n) { return (n < 10 ? "0" : "") + n; }
        const totalSeconds = Math.max(0, Math.floor(ms / 1000));
        const m = Math.floor(totalSeconds / 60);
        const s = totalSeconds % 60;
        return pad(m) + ":" + pad(s);
    }

    background: Rectangle { color: "black" }

    Timer {
        id: hideControlsTimer
        interval: 3000
        running: root.fullscreenActive && root.controlsVisible
        onTriggered: root.controlsVisible = false
    }

    VideoOutput {
        id: videoOutput
        anchors.fill: parent

        TapHandler {
            // Only meaningful in fullscreen - windowed mode's top bar is
            // always visible (see topBar.visible below), nothing to reveal.
            onTapped: if (root.fullscreenActive) root.controlsVisible = true
        }

        // iOS-style "swipe from the left edge to go back" - matches the
        // platform convention (UINavigationController's interactive pop
        // gesture) that this Page otherwise lacks, having only the explicit
        // "←" button above. Unlike WebViewPage.qml, there's no native
        // composited content here to work around - a plain DragHandler over
        // the whole VideoOutput works, since it only ever acts on drags that
        // started within the edge threshold below.
        DragHandler {
            id: edgeSwipeHandler
            target: null
            yAxis.enabled: false
            onActiveChanged: {
                if (!active && centroid.pressPosition.x < 24 && centroid.position.x - centroid.pressPosition.x > 80) {
                    root.closeVideoPage();
                }
            }
        }
    }

    Rectangle {
        id: topBar
        z: 2 // over the raid's cover below, so back still works
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: topBarRow.implicitHeight + 12
        color: root.fullscreenActive ? "#99000000" : "transparent"
        visible: !root.fullscreenActive || root.controlsVisible

        RowLayout {
            id: topBarRow
            anchors.fill: parent
            anchors.margins: 6

            ToolButton {
                text: "←"
                onClicked: root.closeVideoPage()
            }

            Label {
                text: root.liveVideo ? root.controller.videoTitle : root.controller.displayTitle
                color: root.fullscreenActive ? "white" : Material.foreground
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            ToolButton {
                icon.source: root.fullscreenActive ? "qrc:/images/fullscreen_exit.svg" : "qrc:/images/fullscreen.svg"
                onClicked: root.toggleFullscreen()
            }
        }
    }

    Rectangle {
        id: bottomBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: bottomBarRow.implicitHeight + 12
        color: "#99000000"
        // Windowed mode still has PlayerBar for this - only shown here
        // once PlayerBar is hidden for fullscreen (see Main.qml).
        // a live video has nothing to seek: the PlayerBar's stop, out of fullscreen, stops it
        visible: root.fullscreenActive && root.controlsVisible && !root.liveVideo

        RowLayout {
            id: bottomBarRow
            anchors.fill: parent
            anchors.margins: 8

            ToolButton {
                icon.source: root.controller.player.playbackState === MediaPlayer.PlayingState
                             ? "qrc:/images/pause.svg" : "qrc:/images/play.svg"
                onClicked: root.controller.togglePlayPause()
            }

            Label { color: "white"; text: root.formatTime(root.controller.player.position) }

            Slider {
                Layout.fillWidth: true
                from: 0
                to: root.controller.player.duration
                value: root.controller.player.position
                onMoved: root.controller.player.position = value
            }

            Label { color: "white"; text: root.formatTime(root.controller.player.duration) }
        }
    }

    // a mix's members who send video, along the bottom: one is watched at a time, picture and sound; a tap on
    // another name switches to it. Plain words, the watched one in the full text colour, the others dimmed.
    Rectangle {
        id: membersBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: membersFlow.implicitHeight + 12
        color: "#99000000"
        visible: root.liveVideo && root.controller.mixVideos.length > 1 && !root.controller.videoRaidCover
                 && (!root.fullscreenActive || root.controlsVisible)

        Flow {
            id: membersFlow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 16

            Repeater {
                model: root.liveVideo ? root.controller.mixVideos : []

                delegate: Label {
                    id: memberLabel
                    required property var modelData
                    text: modelData.title || modelData.artist || qsTr("Live")
                    font.pointSize: 13
                    color: "white"
                    opacity: modelData.channel === root.controller.videoChannel ? 1 : 0.5
                    topPadding: 8
                    bottomPadding: 8

                    TapHandler { onTapped: root.controller.watch(memberLabel.modelData.channel) }
                }
            }
        }
    }

    // during a raid the server refuses the video: its place covered with the raid's line, no retry until it ends
    Rectangle {
        anchors.fill: parent
        visible: root.liveVideo && root.controller.videoRaidCover
        color: "black"

        Label {
            anchors.fill: parent
            anchors.margins: 24
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.Wrap
            color: Material.foreground   // the app's text colour, as the raid line over the cards
            text: qsTr("Air-raid alert in Kyiv.\nThe video is off until it ends.")
        }
    }

    BusyIndicator {
        anchors.centerIn: parent
        running: root.liveVideo && !root.controller.videoRaidCover
                 && root.controller.videoPlayer.playbackState !== MediaPlayer.PlayingState
        visible: running
    }

    Component.onCompleted: {
        if (root.liveVideo)
            root.controller.showVideo(videoOutput);
        else
            root.controller.player.videoOutput = videoOutput;
    }
    // a page popped any other way lets the video go too (a no-op after closeVideoPage)
    Component.onDestruction: {
        if (root.liveVideo)
            root.controller.hideVideo(videoOutput);
        else
            root.controller.player.videoOutput = null;
    }
}
