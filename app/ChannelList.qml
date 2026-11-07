import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The Home tab's top: v2in's channels as cards (ChannelCard.qml), from the GET /api/now PlaybackController reads,
// the raid's line over them while Kyiv has an air-raid alert, and a heading over the new events below. Set as
// EventListView's listHeader, so it scrolls with the events in one list.
ColumnLayout {
    id: root

    required property PlaybackController controller
    // Main.qml's app.gap: the space between the cards and their padding
    required property int gap
    // the new events under the cards, for the heading over them
    property int eventCount: 0

    readonly property var now: controller.v2inNow
    readonly property bool raid: !!now && !!now.raid && now.raid.on
    // The raid's time in Kyiv: the channels' title already tells it ("Air raid alert in Kyiv since 14:04"), and
    // QML's Date has no time zones to compute it
    readonly property string raidSince: {
        if (!raid)
            return "";
        for (const c of now.channels) {
            const m = /since (\d\d?:\d\d)/.exec(c.title || "");
            if (m)
                return m[1];
        }
        return "";
    }

    spacing: root.gap

    Label {
        Layout.fillWidth: true
        visible: root.raid
        wrapMode: Text.Wrap
        opacity: 0.75
        text: (root.raidSince ? qsTr("Air-raid alert in Kyiv since %1 Kyiv time.").arg(root.raidSince)
                              : qsTr("Air-raid alert in Kyiv.")) + " "
              + qsTr("Every channel is silent until it ends, then plays a short piece of Ukrainian music and goes back to its programme.")
    }

    Label {
        Layout.fillWidth: true
        visible: root.controller.v2inError
        wrapMode: Text.Wrap
        color: "crimson"
        text: qsTr("The radio cannot be reached right now. Trying again.")
    }

    BusyIndicator {
        Layout.alignment: Qt.AlignHCenter
        visible: !root.now && !root.controller.v2inError
        running: visible
    }

    // by count, not the list itself, so a new answer every 10 s updates the cards instead of making them again
    Repeater {
        model: root.now ? root.now.channels.length : 0

        delegate: ChannelCard {
            required property int index
            Layout.fillWidth: true
            channel: root.now.channels[index] || ({})
            controller: root.controller
            gap: root.gap
        }
    }

    Label {
        visible: root.eventCount > 0
        text: qsTr("New")
        font.bold: true
        font.pointSize: 11
        opacity: 0.8
    }

    // the ListView's spacing does not reach its header: the column's spacing after this gives it
    Item { implicitHeight: 0 }
}
