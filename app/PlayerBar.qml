import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia

// Now-playing bar, one row of constant height, always there so nothing under it jumps: what plays (a channel from
// a Home card, a recording from Collection), or a muted "Nothing playing" with stop greyed. Lives above the StackView in Main.qml (not inside a tab/page) so it survives
// tab switches and pushed pages (WebViewPage, VideoPage). Picking a channel is the cards' (ChannelCard.qml), so the
// bar keeps what belongs to what plays: stop (pause for a recording), what plays, volume, and a recording's seek bar
// under its chevron. All actual playback state lives in the PlaybackController instance passed in from Main.qml;
// this is purely the view.
Item {
    id: root
    required property PlaybackController controller
    // Main.qml's app.gap: the space between the bar's icons, and from the window's edges to the first and last
    required property int gap
    // a CompactToolButton's padding around its 24 px icon, (34 - 24) / 2, so the icons, not the buttons, are a gap
    // apart
    readonly property int iconInset: 5
    implicitHeight: contentColumn.implicitHeight + root.gap

    // Something plays, is tuning in, is being tuned in again, is paused, failed (its error shows), or stopped for
    // VideoPage's video of the channel (videoHoldsChannel); stop is
    // greyed and the text says "Nothing playing" otherwise
    readonly property bool active: root.controller.player.playbackState !== MediaPlayer.StoppedState
                                   || root.controller.loading || root.controller.liveStreamOffline
                                   || root.controller.errorMessage !== "" || root.controller.videoHoldsChannel
    readonly property bool recording: !root.controller.isLive && root.active
    // the name and what plays: larger than the old ticker's 8 pt since it scrolls anyway, a little under the
    // cards' 16 pt names
    readonly property real textSize: 14

    // Material's ToolButton pads ~12px each side of its 24px icon; tighter
    // here so the bar's buttons sit close together.
    component CompactToolButton: ToolButton {
        padding: 0
        leftPadding: 0
        rightPadding: 0
        implicitWidth: 34
        implicitHeight: 36
    }

    function formatTime(ms) {
        // Same duration-formatting approach as BroadcastPage.qml's
        // formatElapsed() - not Qt.formatTime(new Date(ms)), which renders
        // in local time and is wrong by the timezone offset at ms=0.
        function pad(n) { return (n < 10 ? "0" : "") + n; }
        const totalSeconds = Math.max(0, Math.floor(ms / 1000));
        const m = Math.floor(totalSeconds / 60);
        const s = totalSeconds % 60;
        return pad(m) + ":" + pad(s);
    }

    ColumnLayout {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.gap - root.iconInset
        anchors.rightMargin: root.gap - root.iconInset
        anchors.top: parent.top
        anchors.topMargin: root.gap / 2
        spacing: root.gap / 2

        RowLayout {
            Layout.fillWidth: true
            spacing: root.gap - 2 * root.iconInset

            // a recording pauses and plays on; a channel only stops, as a radio does
            CompactToolButton {
                visible: root.recording
                icon.source: root.controller.player.playbackState === MediaPlayer.PlayingState
                             ? "qrc:/images/pause.svg" : "qrc:/images/play.svg"
                onClicked: root.controller.togglePlayPause()
            }

            CompactToolButton {
                icon.source: "qrc:/images/stop.svg"
                enabled: root.active
                onClicked: root.controller.stop()

                BusyIndicator {
                    anchors.centerIn: parent
                    implicitWidth: 34
                    implicitHeight: 34
                    running: root.controller.loading
                    visible: running
                }
            }

            // the channel's name, for a channel (a recording's title is in the line beside it); "Nothing playing"
            // when stopped
            Label {
                Layout.leftMargin: root.iconInset
                Layout.alignment: Qt.AlignVCenter
                visible: text !== ""
                text: {
                    if (!root.active)
                        return qsTr("Nothing playing");
                    if (root.recording || root.controller.mediaUrl)
                        return "";
                    const c = root.controller.v2inChannel(root.controller.selectedChannel);
                    return c ? c.name : root.controller.selectedChannel;
                }
                font.pointSize: root.textSize
                font.bold: root.active
                opacity: root.active ? 1 : 0.5
            }

            // What plays - single-pass marquee, the one place title/summary
            // show in the row, whether live or fixed media. Empty while
            // expanded, since the rows below already show them in full there.
            Item {
                id: nowPlayingRow
                Layout.fillWidth: true
                Layout.leftMargin: root.gap / 2
                Layout.rightMargin: root.gap / 2
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredHeight: nowPlayingLabel.implicitHeight
                clip: true

                readonly property string scrollText: {
                    if (!root.active || (root.controller.expanded && root.recording))
                        return "";
                    const t = root.controller.displayTitle;
                    const s = root.controller.displaySummary;
                    return t && s ? (t + "   -   " + s) : (t || s || "");
                }

                Label {
                    id: nowPlayingLabel
                    text: nowPlayingRow.scrollText
                    font.pointSize: root.textSize

                    readonly property bool needsScroll: implicitWidth > nowPlayingRow.width

                    // Plain SequentialAnimation with an explicit target/property
                    // (started/stopped imperatively below), not "SequentialAnimation
                    // on x": the latter permanently destroys any declarative
                    // binding on x the first time it actually runs (QML: writing
                    // to a property, including via an animation, removes its
                    // binding - it does not come back once the animation stops).
                    // That meant a later short/empty title got stuck wherever
                    // the animation last left x (often off-screen), looking
                    // like the row "didn't clear" even though `text` itself had
                    // updated correctly.
                    SequentialAnimation {
                        id: scrollAnim
                        loops: Animation.Infinite
                        NumberAnimation {
                            target: nowPlayingLabel
                            property: "x"
                            from: nowPlayingRow.width
                            to: -nowPlayingLabel.implicitWidth
                            duration: Math.max(12000, nowPlayingLabel.implicitWidth * 30)
                        }
                        PauseAnimation { duration: 800 }
                    }

                    function _restartScroll() {
                        if (nowPlayingRow.visible && needsScroll) {
                            nowPlayingLabel.x = nowPlayingRow.width;
                            scrollAnim.restart();
                        } else {
                            scrollAnim.stop();
                            nowPlayingLabel.x = 0;
                        }
                    }

                    onTextChanged: nowPlayingLabel._restartScroll()
                    onNeedsScrollChanged: nowPlayingLabel._restartScroll()
                    Component.onCompleted: nowPlayingLabel._restartScroll()

                    Connections {
                        target: nowPlayingRow
                        function onVisibleChanged() { nowPlayingLabel._restartScroll(); }
                    }
                }
            }

            Image {
                source: "qrc:/images/sound.svg"
            }

            Slider {
                Layout.preferredWidth: 80
                Layout.minimumWidth: 40
                from: 0
                to: 1
                value: root.controller.player.audioOutput.volume
                onMoved: root.controller.setVolume(value)
            }

            // a recording's seek bar, title and summary
            CompactToolButton {
                visible: root.recording
                icon.source: root.controller.expanded ? "qrc:/images/arrow_drop_up.svg" :
                                                        "qrc:/images/arrow_drop_down.svg"
                onClicked: root.controller.expanded = !root.controller.expanded
            }
        }

        // Stacked rows (seek bar, then description, then Reload) rather
        // than side by side - the description wraps over the full width.
        ColumnLayout {

            Layout.fillWidth: true
            spacing: 4
            visible: root.controller.expanded && root.recording

            RowLayout {
                Layout.fillWidth: true
                Layout.rightMargin: 16
                spacing: 8

                Label { text: root.formatTime(root.controller.player.position) }

                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: root.controller.player.duration
                    value: root.controller.player.position
                    onMoved: root.controller.player.position = value
                }

                Label { text: root.formatTime(root.controller.player.duration) }
            }

            // Title and summary share one row in landscape, stacked in portrait.
            GridLayout {
                id: descriptionGrid
                readonly property bool landscape: root.Window.width > root.Window.height
                Layout.fillWidth: true
                Layout.leftMargin: 12
                columns: landscape ? 2 : 1
                columnSpacing: 12
                rowSpacing: 2

                Label {
                    Layout.fillWidth: false
                    Layout.maximumWidth: descriptionGrid.landscape ? descriptionGrid.width * 0.4 : Number.POSITIVE_INFINITY
                    Layout.alignment: Qt.AlignTop
                    wrapMode: Text.Wrap
                    font.bold: true
                    visible: root.controller.displayTitle.length > 0
                    text: root.controller.displayTitle
                }

                Label {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    wrapMode: Text.Wrap
                    visible: root.controller.displaySummary.length > 0
                    text: root.controller.displaySummary
                }
            }

            Button {
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("Reload")
                visible: root.controller.errorMessage !== ""
                onClicked: root.controller.start()
            }
        }
    }

    // Errors need to be visible even when the strip is collapsed (the
    // expanded section's Reload button alone isn't enough - a plain
    // Rectangle here would get painted over by the StackView sibling below
    // PlayerBar in Main.qml, since ordinary z only reorders siblings under
    // the same parent). A Popup renders through the window's overlay layer
    // instead, so it stays on top regardless of expand/collapse state.
    Popup {
        x: (root.width - width) / 2
        y: contentColumn.height + 4
        visible: root.controller.errorMessage !== ""
        modal: false
        focus: false
        closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape
        background: Rectangle {
            color: "crimson"
            radius: 4
        }
        contentItem: Label {
            padding: 6
            color: "white"
            text: root.controller.errorMessage
        }
    }
}
