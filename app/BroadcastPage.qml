import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Lets a contributor, temporary contributor or manager go live on v2in
// (https://v2in.stream), broadcasting microphone audio via
// IcecastBroadcaster (app/icecastbroadcaster.h/.cpp). Where it may go is
// v2in's to say (POST /api/live/check { key }, its "may"): a pool such as
// "community" is claimed first, a channel such as "live" taken straight at
// the harbor. The harbor password is the login's access_token, or the temporary
// contributor password; v2in checks it with this app's server and refuses
// with a reason worded here. Desktop and Android only: that C++ object is
// only registered as context property "icecastBroadcaster" when
// app/CMakeLists.txt's RADIO65_ENABLE_BROADCAST is defined, so this page
// checks for its existence at runtime rather than relying on a separate
// platform flag - keeps the tab itself always present (needed to keep
// TabBar/SwipeView index alignment, same convention used for "Live").
Item {
    id: root

    readonly property bool broadcastAvailable: typeof icecastBroadcaster !== "undefined"
    // Passed in from Main.qml (userSettings.role === "contributor",
    // "temporaryContributor" or "manager") - gates the broadcast UI the
    // same way broadcastAvailable does, without removing the tab itself
    // (see the class comment above).
    property bool isContributor: false
    // Passed in from Main.qml (userSettings.role === "temporaryContributor")
    // - only for wording: v2in itself limits a temporary contributor to 3
    // minutes, and the claim's "until" shows the time left.
    property bool isTemporaryContributor: false
    // Passed in from Main.qml: userSettings.accessToken, or for a temporary
    // contributor the password they typed (userSettings.temporaryPassword).
    // Sent only as the harbor password and in the claim, never in
    // published metadata.
    property string key: ""
    // { id, name, pool } for the ComboBox below: v2in's "may" for this key
    // (IcecastBroadcaster.refreshDestinations), empty until it answers.
    property var targets: []
    // Why targets is empty once v2in answered: its refusal of the key, or
    // "no answer"; "" while asking or when there are targets.
    property string destinationsReason: ""
    property bool destinationsAsked: false
    property string errorMessage: ""

    function refreshDestinations() {
        if (!root.broadcastAvailable || !root.isContributor || root.key === "")
            return;
        root.destinationsAsked = false;
        icecastBroadcaster.refreshDestinations(root.key);
    }
    onKeyChanged: root.refreshDestinations()
    onIsContributorChanged: root.refreshDestinations()
    Component.onCompleted: root.refreshDestinations()
    // asked again on opening the tab, so a role changed since is seen
    SwipeView.onIsCurrentItemChanged: if (SwipeView.isCurrentItem) root.refreshDestinations()

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
        case "unknown key": return root.isTemporaryContributor
                                   ? qsTr("The temporary contributor password is not accepted. Enter the current one from the menu.")
                                   : qsTr("v2in did not accept your contributor login.");
        case "account not confirmed yet": return qsTr("Your contributor account is not confirmed yet. Open the link in the email you were sent.");
        case "banned": return qsTr("This account may not broadcast.");
        case "no answer": return qsTr("Could not reach v2in. Try again later.");
        case "revoked": return qsTr("Your broadcasting access no longer works.");
        case "kicked": return qsTr("Your broadcast was stopped by v2in's admins.");
        case "expired": return qsTr("Your broadcasting access has expired.");
        case "too early": return qsTr("Your show has not started yet.");
        case "wrong channel": return qsTr("You may not broadcast on %1.").arg(name);
        case "no such channel": return qsTr("%1 is not on v2in any more.").arg(name);
        case "channel taken": return qsTr("Someone is live on %1 now.").arg(name);
        case "pool full": return at ? qsTr("Every %1 channel is taken. Try again at %2.").arg(name).arg(at)
                                    : qsTr("Every %1 channel is taken. Try again later.").arg(name);
        case "cooldown": return at ? qsTr("You were live a moment ago. Try again at %1.").arg(at)
                                   : qsTr("You were live a moment ago. Try again later.");
        case "time is up": return at ? qsTr("Your time is up. Try again at %1.").arg(at)
                                     : qsTr("Your time is up.");
        case "too many tries": return qsTr("Too many wrong tries. Wait a minute and try again.");
        default:
            // "cannot reach live.uuu.ee to check this login", the host named
            if (reason.indexOf("cannot reach") === 0)
                return qsTr("v2in cannot check your login with this app's server right now. Try again in a minute.");
            return qsTr("v2in refused: %1").arg(reason);
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
        function onDestinationsChanged(may, reason) {
            root.targets = may;
            root.destinationsReason = reason;
            root.destinationsAsked = true;
        }
    }

    Label {
        anchors.centerIn: parent
        anchors.margins: 16
        width: parent.width - 32
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
        visible: !root.broadcastAvailable || !root.isContributor
        text: !root.broadcastAvailable
              ? qsTr("Broadcasting is only available on desktop for now.")
              : qsTr("Become a Contributor from the menu to unlock broadcasting.")
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
        active: root.broadcastAvailable && root.isContributor
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
            // Main.qml's appSettings - remembers the last-used name,
            // description and channel so the user doesn't retype them every
            // broadcast.
            Settings {
                id: broadcastSettings
                category: "Broadcast"
                property string name: ""
                property string description: ""
                // the last destination chosen, used only while it is in may
                property string lastChannel: ""
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


            // A temporary contributor from an earlier version has no password
            // kept: the menu's Temporary contributor asks for it again.
            Label {
                Layout.fillWidth: true
                visible: !icecastBroadcaster.broadcasting && root.key === ""
                wrapMode: Text.Wrap
                color: "crimson"
                text: qsTr("Enter the temporary contributor password again from the menu to broadcast.")
            }

            Label {
                Layout.fillWidth: true
                visible: !icecastBroadcaster.broadcasting && root.key !== "" && root.targets.length === 0
                wrapMode: Text.Wrap
                color: root.destinationsAsked ? "crimson" : Material.foreground
                text: !root.destinationsAsked ? qsTr("Asking v2in where you may go live.")
                      : root.destinationsReason !== "" ? root.refusalText(root.destinationsReason, "", "")
                      : qsTr("v2in offers you nowhere to go live now.")
            }

            ComboBox {
                id: channelCombo
                Layout.fillWidth: true
                visible: !icecastBroadcaster.broadcasting && root.targets.length > 0
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
                // Stop is always clickable; Start needs a key. Whether it may
                // go there is v2in's to say, on Start.
                enabled: icecastBroadcaster.broadcasting
                         || (root.key !== "" && channelCombo.target !== null)
                onClicked: {
                    if (icecastBroadcaster.broadcasting) {
                        icecastBroadcaster.stopBroadcast();
                    } else {
                        root.errorMessage = "";
                        const t = channelCombo.target;
                        icecastBroadcaster.startBroadcast(t.id, t.pool, root.key, nameField.text, descriptionField.text, sendNotificationCheck.checked, saveStreamCheck.checked);
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
                // until: the session's end from v2in's claim (a temporary
                // contributor's 3 minutes), 0 for none; re-read on each
                // elapsed tick
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
