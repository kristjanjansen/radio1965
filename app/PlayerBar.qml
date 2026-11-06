import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia

// Persistent, always-visible mini-player strip - lives above the StackView
// in Main.qml (not inside a tab/page) so it survives tab switches and
// pushed pages (WebViewPage, VideoPage). All actual playback state lives in
// the PlaybackController instance passed in from Main.qml; this is purely
// the view.
Item {
    id: root
    required property PlaybackController controller
    implicitHeight: contentColumn.implicitHeight + 12

    // True while either combobox dropdown is open - Main.qml uses this to
    // hide native WebView content, which would otherwise draw over the popup.
    readonly property bool popupOpen: channelCombo.popup.visible || recentMediaCombo.popup.visible

    // Material's ToolButton pads ~12px each side of its 24px icon; tighter
    // here so play/stop/expand sit close together in the player strip.
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
        anchors.leftMargin: 12
        anchors.top: parent.top
        anchors.margins: 6
        spacing: 6

        // Flow rather than one RowLayout: on narrow screens the volume +
        // transport group wraps onto its own line under the channel picker
        // instead of squeezing/overflowing. Each group is a RowLayout sized
        // explicitly (a Flow doesn't stretch children): side by side when
        // both fit, otherwise each takes the full width.
        Flow {
            id: controlsRow
            Layout.fillWidth: true
            spacing: 2

            // Free space when both groups fit on one line - shared equally
            // so the slider grows along with the picker.
            readonly property real extra: Math.max(0, width - spacing - selectorGroup.implicitWidth - volumeGroup.implicitWidth)

            readonly property bool wrapped: selectorGroup.implicitWidth + volumeGroup.implicitWidth + spacing > width

        RowLayout {
            id: selectorGroup
            width: controlsRow.wrapped ? controlsRow.width
                                       : implicitWidth + controlsRow.extra / 2
            spacing: 2

            BusyIndicator {
                implicitWidth: 20
                implicitHeight: 20
                running: root.controller.loading
                visible: running
            }

            Image {
                source: root.controller.browsingRecentMedia ? "qrc:/images/audio_file.svg" :
                            "qrc:/images/radio.svg"
                sourceSize.width: 22
                sourceSize.height: 22


                // Pure view toggle between the live-channel and recent-media
                // comboboxes below - never touches actual playback, so
                // tapping this is safe regardless of what's currently
                // playing (see PlaybackController.toggleSelectorMode()).
                TapHandler {
                    onTapped: root.controller.toggleSelectorMode()
                }
            }

            ComboBox {
                id: channelCombo
                Layout.minimumWidth: 110
                Layout.preferredWidth: 130
                Layout.fillWidth: true
                Layout.maximumWidth: 250

                visible: !root.controller.browsingRecentMedia
                model: root.controller.channelOptions
                currentIndex: root.controller.channelOptions.indexOf(root.controller.selectedChannel)
                onActivated: root.controller.selectChannel(root.controller.channelOptions[currentIndex])
                // a pool by its name and show, never its channel (PlaybackController.channelLabel)
                displayText: root.controller.channelLabel(currentText)
                delegate: ItemDelegate {
                    width: channelCombo.width
                    text: root.controller.channelLabel(modelData)
                    enabled: root.controller.isChannelStreaming(modelData)
                }
                background: Rectangle {
                    implicitWidth: 110
                    implicitHeight: 32
                    radius: 4
                    color: "transparent"
                    border.width: 0
                    border.color: "transparent"
                }

                Connections {
                    target: channelCombo.popup
                    function onOpened() { root.controller.refreshChannelAvailability(); }
                }
            }

            // Recent-media picker - local playback history (project-
            // description.md #8.2.1's "Save stream" recordings included),
            // see PlaybackController._recordRecentMedia(). Doubles as the
            // "currently selected" indicator the same way channelCombo does
            // for live channels: currentIndex tracks controller.mediaUrl.
            // A leading "Recent media" placeholder (index 0, not a real
            // history entry) is shown whenever nothing currently loaded
            // matches an entry, rather than defaulting to the most-recent
            // real item - that looked selected/loaded even though nothing
            // had actually been chosen yet, so pressing Play just resumed
            // whatever was playing before (e.g. the radio channel) instead
            // of the item the combobox appeared to show.
            ComboBox {
                id: recentMediaCombo
                Layout.minimumWidth: 110
                Layout.preferredWidth: 130
                Layout.fillWidth: true
                Layout.maximumWidth: 250
                visible: root.controller.browsingRecentMedia
                model: [{ title: qsTr("Recent media"), url: "" }].concat(root.controller.recentMedia)
                textRole: "title"
                valueRole: "url"
                currentIndex: {
                    for (let i = 0; i < root.controller.recentMedia.length; i++) {
                        if (root.controller.recentMedia[i].url === root.controller.mediaUrl)
                            return i + 1; // +1: index 0 is the placeholder
                    }
                    return 0;
                }
                onActivated: {
                    if (currentIndex === 0)
                        return; // placeholder - not a real item, no-op
                    const item = root.controller.recentMedia[currentIndex - 1];
                    if (item)
                        root.controller.playMedia(item.url, item.title, item.summary, false);
                }
                background: Rectangle {
                    implicitWidth: 110
                    implicitHeight: 32
                    radius: 4
                    color: "transparent"
                    border.width: 0
                    border.color: "transparent"
                }
            }

        }

        RowLayout {
            id: volumeGroup
            width: controlsRow.wrapped ? controlsRow.width : implicitWidth + controlsRow.extra / 2
            spacing: 0

            Image {
                source: "qrc:/images/sound.svg"
                // sourceSize.width: 18
                // sourceSize.height: 18
            }

            Slider {
                Layout.preferredWidth: 80
                Layout.minimumWidth: 40
                Layout.maximumWidth: 400
                Layout.fillWidth:  true
                from: 0
                to: 1
                value: root.controller.player.audioOutput.volume
                onMoved: root.controller.setVolume(value)
            }

            ToolButton {
                icon.source: root.controller.player.playbackState === MediaPlayer.PlayingState
                             ? "qrc:/images/pause.svg" : "qrc:/images/play.svg"
                onClicked: root.controller.togglePlayPause()
            }

            ToolButton {
                icon.source: "qrc:/images/stop.svg"
                onClicked: root.controller.stop()
            }

            ToolButton {
                icon.source: root.controller.expanded ? "qrc:/images/arrow_drop_up.svg" :
                                                        "qrc:/images/arrow_drop_down.svg"
                //text: root.controller.expanded ? "▴" : "▾"
                onClicked: root.controller.expanded = !root.controller.expanded
            }
        }
        }

        // Narrow "now playing" strip - single-pass marquee, since the
        // static title Label that used to live in controlsRow is gone
        // (superseded by this: the one place title/summary show now,
        // whether live or fixed media). Hidden while expanded, since the
        // RowLayout below already shows the summary in full there.
        Item {
            id: nowPlayingRow
            Layout.fillWidth: true
            height: nowPlayingLabel.implicitHeight
            clip: true
            visible: !root.controller.expanded && nowPlayingRow.scrollText !== ""

            readonly property string scrollText: {
                const t = root.controller.displayTitle;
                const s = root.controller.displaySummary;
                return t && s ? (t + "   -   " + s) : (t || s || "");
            }

            Label {
                id: nowPlayingLabel
                text: nowPlayingRow.scrollText
                font.pointSize: 8

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

        // Stacked rows (seek bar, then description, then Reload) rather
        // than side by side - the description wraps over the full width.
        ColumnLayout {

            Layout.fillWidth: true
            spacing: 4
            visible: root.controller.expanded

            RowLayout {
                Layout.fillWidth: true
                Layout.rightMargin: 16
                spacing: 8
                visible: !root.controller.isLive

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
