import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One v2in channel as v2in.stream's Channels tab draws it (web/index.html, render()): play or stop, the name,
// On air / Silent / Offline, and one line of what plays with its date apart. A channel of several (community)
// plays its mix from the play when it is mixed; unmixed, its slots fold under a chevron, one row each.
Rectangle {
    id: root

    // one entry of GET /api/now's channels, as v2in gives it
    required property var channel
    required property PlaybackController controller
    // Main.qml's app.gap: the card's padding
    required property int gap

    readonly property bool several: Array.isArray(channel.live)
    readonly property var liveShows: several ? channel.live : []
    readonly property bool mixed: several && !!channel.mix && !!channel.stream
    readonly property var slots: several && !channel.mix && Array.isArray(channel.slots) ? channel.slots : null
    readonly property bool many: slots !== null
    readonly property bool off: channel.status === "offline"
    // what the card's own play plays: the channel, its mix, or its one live show; nothing for a channel of several
    // with nobody live or several live without a mix
    readonly property string streamChannel: !several ? channel.id
                                          : mixed ? channel.id
                                          : !many && liveShows.length === 1 ? liveShows[0].channel : ""
    readonly property bool playing: streamChannel !== "" && controller.isPlayingChannel(streamChannel)
    // one of its slots plays: the slots stay open, so the playing row stays in sight
    readonly property bool held: many && slots.some(s => controller.isPlayingChannel(s.channel))
    readonly property bool open: many && (held || !!controller.foldOpen[channel.id])

    readonly property string monoFamily: Qt.platform.os === "ios" || Qt.platform.os === "osx"
                                         || Qt.platform.os === "macos" ? "Menlo" : "monospace"

    // The line under the name, by v2in.stream's rules (render() and slotLine() in web/index.html)
    function line() {
        const x = root.channel;
        const lv = root.liveShows;
        if (root.many) {
            const on = root.slots.filter(s => s.live);
            const free = root.slots.length - on.length;
            const counts = [on.length && qsTr("%1 live").arg(on.length), free && qsTr("%1 free").arg(free)]
                .filter(Boolean).join(", ");
            const who = !root.open && on.length ? on.map(s => s.title || s.artist || qsTr("Live")).join(", ") : "";
            if (x.status === "silent")
                return [x.title, counts].filter(Boolean).join(". ");
            return who ? counts + ": " + who : counts;
        }
        if (!root.several || x.status === "silent" || (root.mixed && !lv.length))
            return [x.by, x.title].filter(Boolean).join(" - ");
        if (!lv.length)
            return qsTr("Nobody live now");
        if (root.mixed)
            return lv.map(l => l.title || l.artist).filter(Boolean).join(", ") || qsTr("Live");
        if (lv.length === 1)
            return [lv[0].artist, lv[0].title].filter(Boolean).join(" - ") || qsTr("Live");
        return qsTr("%1 live now").arg(lv.length);
    }
    // "2026-10-25" as "25 Oct 2026", the web's and admin's days; none for who is live on a channel of several
    function date() {
        const d = root.channel.date;
        if (!d || (root.several && root.liveShows.length))
            return "";
        const p = d.split("-").map(Number);
        const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
        return p[2] + " " + months[p[1] - 1] + " " + p[0];
    }

    implicitHeight: content.implicitHeight + 2 * root.gap
    radius: 6
    color: Material.backgroundColor.lighter()
    border.width: 1
    border.color: root.playing || root.held ? Material.accentColor : Material.frameColor

    // The 44 px square play or stop of a card and of a slot row, the web's, a busy ring over it while tuning in
    component PlayButton: ToolButton {
        id: playButton
        property bool playing: false
        property bool tuning: false
        implicitWidth: 44
        implicitHeight: 44
        padding: 0
        icon.source: playing ? "qrc:/images/stop.svg" : "qrc:/images/play.svg"
        icon.color: Material.accentColor
        opacity: enabled ? 1 : 0.3
        background: Rectangle {
            radius: 4
            color: "transparent"
            border.width: 1
            border.color: playButton.enabled ? Material.accentColor : Material.frameColor
        }
        BusyIndicator {
            anchors.centerIn: parent
            implicitWidth: 40
            implicitHeight: 40
            running: playButton.tuning
            visible: running
        }
    }

    ColumnLayout {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root.gap
        spacing: root.gap / 2

        RowLayout {
            Layout.fillWidth: true
            spacing: root.gap

            PlayButton {
                visible: !root.many
                playing: root.playing
                tuning: root.playing && root.controller.isTuning(root.streamChannel)
                enabled: (!root.off && root.streamChannel !== "") || root.playing
                onClicked: root.playing ? root.controller.stop() : root.controller.selectChannel(root.streamChannel)
            }

            // an unmixed channel of several: its slots open or folded instead of a play
            ToolButton {
                visible: root.many
                implicitWidth: 44
                implicitHeight: 44
                padding: 0
                enabled: !root.held
                icon.source: root.open ? "qrc:/images/arrow_drop_up.svg" : "qrc:/images/arrow_drop_down.svg"
                onClicked: root.controller.setFoldOpen(root.channel.id, !root.open)
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Label {
                        Layout.fillWidth: true
                        text: root.channel.name || root.channel.id
                        font.pointSize: 16
                        elide: Text.ElideRight
                        opacity: root.off ? 0.5 : 1
                    }

                    Label {
                        text: root.channel.status === "silent" ? qsTr("SILENT")
                              : root.off ? qsTr("OFFLINE") : qsTr("ON AIR")
                        font.family: root.monoFamily
                        font.pointSize: 10
                        font.letterSpacing: 1
                        color: root.channel.status === "silent" || root.off ? Material.foreground : Material.accentColor
                        opacity: root.off ? 0.5 : 1
                    }
                }

                // what plays, as long as it is, the date right after it; cut short only when both do not fit.
                // An Item, not a RowLayout: the line's width is set here and never read back as the row's size
                Item {
                    id: lineRow
                    Layout.fillWidth: true
                    implicitHeight: Math.max(lineLabel.implicitHeight, dateLabel.implicitHeight)
                    visible: lineLabel.text !== "" || dateLabel.text !== ""

                    Label {
                        id: lineLabel
                        width: Math.min(implicitWidth, lineRow.width
                                        - (dateLabel.visible ? dateLabel.implicitWidth + 8 : 0))
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.line()
                        elide: Text.ElideRight
                        opacity: 0.75
                    }

                    Label {
                        id: dateLabel
                        x: lineLabel.text !== "" ? lineLabel.width + 8 : 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.date()
                        visible: text !== ""
                        font.family: root.monoFamily
                        font.pointSize: 10
                        opacity: 0.6
                    }
                }
            }
        }

        // the slots of an unmixed channel of several, every one in its place: a live one plays, a free one is greyed
        Repeater {
            model: root.open ? root.slots : []

            delegate: RowLayout {
                id: slotRow
                required property var modelData
                readonly property bool playing: root.controller.isPlayingChannel(modelData.channel)
                Layout.fillWidth: true
                Layout.leftMargin: 2 * root.gap
                spacing: root.gap

                PlayButton {
                    playing: slotRow.playing
                    tuning: slotRow.playing && root.controller.isTuning(slotRow.modelData.channel)
                    enabled: slotRow.modelData.live || slotRow.playing
                    onClicked: slotRow.playing ? root.controller.stop()
                                               : root.controller.selectChannel(slotRow.modelData.channel)
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Label {
                        Layout.fillWidth: true
                        text: slotRow.modelData.live ? (slotRow.modelData.title || slotRow.modelData.artist || qsTr("Live"))
                                                     : qsTr("Free")
                        elide: Text.ElideRight
                        opacity: slotRow.modelData.live ? 1 : 0.5
                    }

                    Label {
                        Layout.fillWidth: true
                        text: slotRow.modelData.live && slotRow.modelData.title ? slotRow.modelData.artist : ""
                        visible: text !== ""
                        elide: Text.ElideRight
                        opacity: 0.75
                    }
                }
            }
        }
    }
}
