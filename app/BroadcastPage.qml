import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Lets the user go live on v2in (https://v2in.stream) with a stream key,
// broadcasting microphone audio via IcecastBroadcaster
// (app/icecastbroadcaster.h/.cpp). What can be chosen is v2in's own GET
// /api/now, read by PlaybackController.qml: its pools (e.g. "community",
// claimed first) and its main channels (e.g. "live", the key straight to
// the harbor). The key decides where it may go; v2in refuses one that does
// not fit, with a reason worded here. Desktop and Android only: that C++
// object is only registered as context property "icecastBroadcaster" when
// app/CMakeLists.txt's RADIO65_ENABLE_BROADCAST is defined, so this page
// checks for its existence at runtime rather than relying on a separate
// platform flag - keeps the tab itself always present (needed to keep
// TabBar/SwipeView index alignment, same convention used for "Live").
Item {
    id: root

    readonly property bool broadcastAvailable: typeof icecastBroadcaster !== "undefined"
    // Main.qml's playbackController: its v2inNow is GET /api/now's latest
    // answer, the same one the player reads.
    property var controller: null
    readonly property var v2inNow: root.controller ? root.controller.v2inNow : null
    // Pools first (where most broadcasts go), then the main channels, as
    // { id, name, pool } for the ComboBox below.
    readonly property var targets: root.v2inNow
        ? (root.v2inNow.pools || []).map(p => ({ id: p.id, name: p.name || p.id, pool: true }))
              .concat((root.v2inNow.channels || []).map(c => ({ id: c.id, name: c.name || c.id, pool: false })))
        : []
    // Kyiv's air raid alert: v2in holds every channel silent until it ends.
    readonly property bool raidOn: !!(root.v2inNow && root.v2inNow.raid && root.v2inNow.raid.on)
    property string errorMessage: ""

    function targetName(id) {
        const t = root.targets.find(x => x.id === id);
        return t ? t.name : id;
    }

    // v2in's refusals (POST /api/live/claim, /api/live/check), in words;
    // next is when it may work, shown as a local time.
    function refusalText(reason, next, target) {
        const at = next ? Qt.formatTime(new Date(next), "HH:mm") : "";
        const name = root.targetName(target);
        switch (reason) {
        case "unknown key": return qsTr("This stream key is not known. Check it, or ask v2in's admins for one.");
        case "revoked": return qsTr("This stream key no longer works. Ask v2in's admins for a new one.");
        case "kicked": return qsTr("This stream key was stopped by v2in's admins.");
        case "expired": return qsTr("This stream key has expired.");
        case "too early": return qsTr("This stream key's show has not started yet.");
        case "wrong channel": return qsTr("This stream key is not for %1.").arg(name);
        case "no such channel": return qsTr("%1 is not on v2in any more.").arg(name);
        case "channel taken": return qsTr("Someone is live on %1 now.").arg(name);
        case "pool full": return at ? qsTr("Every %1 channel is taken. Try again at %2.").arg(name).arg(at)
                                    : qsTr("Every %1 channel is taken. Try again later.").arg(name);
        case "cooldown": return at ? qsTr("You were live a moment ago. Try again at %1.").arg(at)
                                   : qsTr("You were live a moment ago. Try again later.");
        case "time is up": return at ? qsTr("Your time is up. Try again at %1.").arg(at)
                                     : qsTr("Your time is up.");
        case "too many tries": return qsTr("Too many wrong keys. Wait a minute and try again.");
        default: return qsTr("v2in refused: %1").arg(reason);
        }
    }

    function formatElapsed(seconds) {
        // Not Qt.formatTime(new Date(seconds*1000), ...): that Date is
        // epoch-relative (UTC), and formatTime renders it in local time, so
        // e.g. Estonia's UTC+3 summer offset would always show "03:00:00"
        // at seconds=0. Format the duration directly instead.
        function pad(n) { return (n < 10 ? "0" : "") + n; }
        const total = Math.max(0, Math.floor(seconds));
        const h = Math.floor(total / 3600);
        const m = Math.floor((total % 3600) / 60);
        const s = total % 60;
        return pad(h) + ":" + pad(m) + ":" + pad(s);
    }

    Connections {
        target: root.broadcastAvailable ? icecastBroadcaster : null
        // root.errorMessage, not a Loader-internal id: ids declared inside
        // the Loader's inline sourceComponent below live in that Component's
        // own scope and aren't reachable from this outer Connections (that
        // was the "errorLabel is not defined" crash - e.g. when Icecast
        // rejects a connect attempt to an already-occupied channel).
        function onBroadcastError(message) { root.errorMessage = message; }
        function onRefused(reason, next, target) { root.errorMessage = root.refusalText(reason, next, target); }
    }

    // Fresh pools, channels and raid on opening the tab, not the player's
    // next minute.
    SwipeView.onIsCurrentItemChanged: if (SwipeView.isCurrentItem && root.controller) root.controller.refreshV2inNow()

    Label {
        anchors.centerIn: parent
        anchors.margins: 16
        width: parent.width - 32
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
        visible: !root.broadcastAvailable
        text: qsTr("Broadcasting is only available on desktop for now.")
    }

    // Loader, not a plain Item with visible:false: this subtree's bindings
    // reference the "icecastBroadcaster" context property directly, which
    // doesn't exist at all on builds without RADIO65_ENABLE_BROADCAST -
    // visible:false alone wouldn't stop those bindings from being evaluated
    // (same ReferenceError class this session already hit once with
    // ListView's `model`), but an inactive Loader never instantiates its
    // content, so the bindings are simply never created.
    Loader {
        anchors.fill: parent
        anchors.margins: 16
        active: root.broadcastAvailable
        // ScrollView so the Start button stays reachable when the content is
        // taller than the page (e.g. a small phone in landscape).
        sourceComponent: ScrollView {
            id: scroll
            clip: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

          ColumnLayout {
            id: form
            width: scroll.availableWidth
            spacing: 12

            // Persisted across app restarts, same QtCore Settings pattern as
            // Main.qml's appSettings - remembers the stream key, the last-used
            // name, description and channel so the user doesn't retype them
            // every broadcast.
            Settings {
                id: broadcastSettings
                category: "Broadcast"
                // from v2in's admins, typed once
                property string key: ""
                property string name: ""
                property string description: ""
                property string lastChannel: "community"
                property bool sendNotification: true
                property bool saveStream: true
                property real gain: 1.0
            }

            // Restores the last-used gain onto the C++ broadcaster - m_gain
            // itself defaults to 1.0 and isn't persisted there, only here in
            // Settings, same division of responsibility as the other fields
            // above (broadcastSettings holds the value, the checkboxes/
            // fields push it into icecastBroadcaster).
            Component.onCompleted: icecastBroadcaster.gain = broadcastSettings.gain


            TextField {
                id: keyField
                Layout.fillWidth: true
                visible: !icecastBroadcaster.broadcasting
                placeholderText: qsTr("Stream key")
                // shown while typing, dots otherwise
                echoMode: TextInput.PasswordEchoOnEdit
                inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText | Qt.ImhSensitiveData
                enabled: !icecastBroadcaster.broadcasting
                text: broadcastSettings.key
                onTextChanged: broadcastSettings.key = text.trim()
            }

            Label {
                Layout.fillWidth: true
                visible: !icecastBroadcaster.broadcasting && keyField.text.trim() === ""
                wrapMode: Text.Wrap
                opacity: 0.8
                text: qsTr("A stream key comes from v2in's admins. It says where you may go live.")
            }

            ComboBox {
                id: channelCombo
                Layout.fillWidth: true
                visible: !icecastBroadcaster.broadcasting
                enabled: !icecastBroadcaster.broadcasting
                model: root.targets
                textRole: "name"
                valueRole: "id"
                currentIndex: Math.max(0, root.targets.findIndex(t => t.id === broadcastSettings.lastChannel))
                onActivated: broadcastSettings.lastChannel = channelCombo.currentValue
                readonly property var target: root.targets[currentIndex] || null

                // ComboBox has no built-in placeholderText equivalent (unlike
                // TextField above), so this mimics one by hand: a small
                // caption straddling the control's top border - anchoring
                // verticalCenter to parent.top centers it exactly on the
                // border line, and the background rectangle "cuts" through
                // that line the same way Material's own outlined-field
                // placeholder does, rather than just overlapping it.
                Label {
                    text: qsTr("Channel:")
                    font.pointSize: 10
                    color: Material.frameColor
                    padding: 2
                    background: Rectangle { color: Material.background }
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.top
                }
            }

            TextField {
                id: nameField
                Layout.fillWidth: true
                visible: !icecastBroadcaster.broadcasting
                placeholderText: qsTr("Title")
                enabled: !icecastBroadcaster.broadcasting
                text: broadcastSettings.name
                onTextChanged: broadcastSettings.name = text
            }

            TextField {
                id: descriptionField
                Layout.fillWidth: true
                visible: !icecastBroadcaster.broadcasting
                placeholderText: qsTr("Description")
                enabled: !icecastBroadcaster.broadcasting
                text: broadcastSettings.description
                onTextChanged: broadcastSettings.description = text
            }

            // Combined into one Flow (rather than two separate rows) to save
            // vertical space - Flow (unlike RowLayout) wraps onto a second
            // line by itself on narrow/portrait screens instead of forcing
            // either control to shrink or overflow.
            Flow {
                Layout.fillWidth: true
                visible: !icecastBroadcaster.broadcasting
                spacing: 12

                CheckBox {
                    id: sendNotificationCheck
                    text: qsTr("Send notification")
                    enabled: !icecastBroadcaster.broadcasting
                    checked: broadcastSettings.sendNotification
                    onToggled: broadcastSettings.sendNotification = checked
                }

                CheckBox {
                    id: saveStreamCheck
                    text: qsTr("Save stream")
                    enabled: !icecastBroadcaster.broadcasting
                    checked: broadcastSettings.saveStream
                    onToggled: broadcastSettings.saveStream = checked
                }
            }

            // Replaces the Channel/Title/Description/checkboxes controls
            // above (all hidden via visible:!broadcasting) once live - those
            // values can't be changed mid-broadcast anyway (see their own
            // enabled:!broadcasting), so showing the static result instead
            // saves the vertical space they'd otherwise keep occupying.
            Label {
                Layout.fillWidth: true
                visible: icecastBroadcaster.broadcasting
                wrapMode: Text.Wrap
                font.bold: true
                text: qsTr("Broadcasting \"%1\" on %2").arg(nameField.text).arg(channelCombo.currentText)
            }

            // Kyiv's air raid alert (GET /api/now's raid.on), shown before and
            // while going live: v2in keeps broadcasting from the app, but every
            // channel is silent to listeners until the alert ends.
            Label {
                Layout.fillWidth: true
                visible: root.raidOn
                wrapMode: Text.Wrap
                color: "orange"
                text: qsTr("Air raid alert in Kyiv: your broadcast is silent on air until the alert ends.")
            }

            // Level meter + gain slider, vertical and side by side so they
            // read like a mixing-desk channel strip - only meaningful while
            // QAudioSource is actually capturing (i.e. while broadcasting),
            // so tucked away here rather than shown alongside the
            // pre-broadcast form controls above.
            // In landscape (little vertical room) both become horizontal bars
            // (still side by side) instead.
            GridLayout {
                id: strip
                Layout.alignment: Qt.AlignHCenter
                visible: icecastBroadcaster.broadcasting
                columns: 2
                columnSpacing: 24
                rowSpacing: 8

                readonly property bool landscape: root.Window.width > root.Window.height
                readonly property int meterHeight: 120
                readonly property int meterWidth: 200

                ColumnLayout {
                    spacing: 4

                    Label { Layout.alignment: Qt.AlignHCenter; text: qsTr("Level") }

                    // Peak meter fed by IcecastBroadcaster::inputLevel -
                    // reads post-gain samples, so this reflects the same
                    // clipped signal that's actually being streamed, not
                    // the raw mic input.
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: strip.landscape ? strip.meterWidth : 20
                        Layout.preferredHeight: strip.landscape ? 20 : strip.meterHeight
                        radius: 4
                        color: Material.dividerColor
                        clip: true

                        Rectangle {
                            x: 0
                            y: strip.landscape ? 0 : parent.height - height
                            radius: 4
                            width: strip.landscape ? parent.width * icecastBroadcaster.inputLevel : parent.width
                            height: strip.landscape ? parent.height : parent.height * icecastBroadcaster.inputLevel
                            color: icecastBroadcaster.inputLevel > 0.9 ? "crimson"
                                   : icecastBroadcaster.inputLevel > 0.7 ? "orange" : "limegreen"

                            Behavior on height { NumberAnimation { duration: 80 } }
                            Behavior on width { NumberAnimation { duration: 80 } }
                        }
                    }
                }

                ColumnLayout {
                    spacing: 4

                    Label {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("Gain: %1%").arg(Math.round(gainSlider.value * 100))
                    }

                    Slider {
                        id: gainSlider
                        orientation: strip.landscape ? Qt.Horizontal : Qt.Vertical
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: strip.landscape ? strip.meterWidth : implicitWidth
                        Layout.preferredHeight: strip.landscape ? implicitHeight : strip.meterHeight
                        from: 0.0
                        to: 2.0
                        value: broadcastSettings.gain
                        onMoved: {
                            broadcastSettings.gain = value;
                            icecastBroadcaster.gain = value;
                        }
                    }
                }
            }

            Button {
                Layout.alignment: Qt.AlignHCenter
                text: icecastBroadcaster.broadcasting ? qsTr("Stop") : qsTr("Start")
                // Stop is always clickable; Start needs a key and somewhere to
                // go. Whether the key fits is v2in's to say, on Start.
                enabled: icecastBroadcaster.broadcasting
                         || (keyField.text.trim() !== "" && channelCombo.target !== null)
                onClicked: {
                    if (icecastBroadcaster.broadcasting) {
                        icecastBroadcaster.stopBroadcast();
                    } else {
                        root.errorMessage = "";
                        const t = channelCombo.target;
                        icecastBroadcaster.startBroadcast(t.id, t.pool, keyField.text.trim(), nameField.text, descriptionField.text, sendNotificationCheck.checked, saveStreamCheck.checked);
                    }
                }
            }

            Label {
                Layout.alignment: Qt.AlignHCenter
                visible: icecastBroadcaster.onAir
                text: qsTr("● On air")
                color: "crimson"
                font.bold: true
            }

            Label {
                Layout.alignment: Qt.AlignHCenter
                visible: icecastBroadcaster.broadcasting
                // until: the session's end from v2in's claim (a guest key's 3
                // minutes), 0 for none; re-read on each elapsed tick
                text: icecastBroadcaster.until > 0
                      ? qsTr("%1 (%2 left)").arg(root.formatElapsed(icecastBroadcaster.elapsedSeconds))
                            .arg(root.formatElapsed(icecastBroadcaster.elapsedSeconds >= 0 ? (icecastBroadcaster.until - Date.now()) / 1000 : 0))
                      : root.formatElapsed(icecastBroadcaster.elapsedSeconds)
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "crimson"
                text: root.errorMessage
                visible: text !== ""
            }

            Item { Layout.fillHeight: true }
          }
        }
    }
}
