import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The "Collection" SwipeView tab (project-description.md #2.1) - shelved
// events grouped into per-type Shelves, each further grouped by
// Author/Month/Title, plus a collapsible search strip that pushes
// SearchResultsPage.qml onto the shared StackView. Replaces the plain
// EventListView the Collection tab used before - "New Arrivals" keeps using
// EventListView unchanged.
Page {
    id: root

    required property StackView navigationStack
    required property string serverBaseUrl
    required property PlaybackController controller
    // Main.qml's app.gap: the page's edges and the space between its parts
    required property int gap

    property string groupMode: "month"
    property bool searchVisible: false
    property bool showEvents: false

    // Remembers the "Show events" checkbox across app restarts.
    Settings {
        category: "Collection"
        property alias showEvents: root.showEvents
    }

    background: Rectangle { color: "transparent" }

    // Folds server/db.py's EVENT_TYPES into project-description.md's 6
    // shelves plus "Stream Recordings". "streamrecording" (a finished "Save
    // stream" livestream recording, see server/icecast_on_disconnect.sh's
    // finalize-recording call) gets its own shelf rather than folding into
    // "Audio", so it stays visually distinct from readymade/uploaded audio
    // content. Colors are a simple hue-per-shelf scheme suited to the app's
    // existing dark background (Main.qml's Material.background gradient).
    //
    // Deliberately no "livestream" shelf: an in-progress broadcast isn't a
    // collectible item (it's covered live via "New Arrivals"/the "LIVE"
    // badge) - once it ends, icecast_on_disconnect.sh's finalize-recording
    // call retypes it to "streamrecording" if it was saved, which does get
    // a shelf here; if it wasn't saved, it simply has nothing left to show.
    readonly property var shelfDefs: [
        { types: ["article"], title: qsTr("Article"), color: "#4a3416" },
        { types: ["webcontent"], title: qsTr("Web Content"), color: "#16403c" },
        { types: ["text"], title: qsTr("Message"), color: "#2c4a16" },
        { types: ["audio"], title: qsTr("Audio"), color: "#16304a" },
        { types: ["video"], title: qsTr("Video"), color: "#2a1a4a" },
        { types: ["streamrecording"], title: qsTr("Stream Recordings"), color: "#3a2a4a" }
    ]

    property var events: notificationManager.shelvedEvents()

    // Recompute whenever the underlying model changes - same Connections
    // pattern PlaybackController.qml already uses for notificationManager.
    Connections {
        target: notificationManager
        function onDataChanged() { root.events = notificationManager.shelvedEvents(); }
        function onRowsInserted() { root.events = notificationManager.shelvedEvents(); }
        function onRowsRemoved() { root.events = notificationManager.shelvedEvents(); }
    }

    function runSearch() {
        const query = searchField.text.trim();
        if (query.length === 0)
            return;
        root.navigationStack.push(Qt.resolvedUrl("SearchResultsPage.qml"), {
            query: query,
            events: root.events,
            navigationStack: root.navigationStack,
            serverBaseUrl: root.serverBaseUrl,
            controller: root.controller,
            gap: root.gap
        });
    }

    header: ToolBar {
        background: Rectangle { color: "transparent" }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 5

            Label {
                text: qsTr("Collection")
                font.bold: true
                Layout.fillWidth: true
            }

            ToolButton {
                icon.source: "qrc:/images/search.svg"
                onClicked: root.searchVisible = !root.searchVisible
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: root.gap
        spacing: root.gap

        RowLayout {
            Layout.fillWidth: true
            visible: root.searchVisible
            spacing: 8

            TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: qsTr("Search title, author, or word…")
                onAccepted: root.runSearch()
            }

            ToolButton {
                icon.source: "qrc:/images/search.svg"
                onClicked: root.runSearch()
            }
        }

        Flow {
            Layout.fillWidth: true
            spacing: 6

            // Flow (unlike RowLayout) doesn't support per-child vertical
            // alignment - it always top-aligns each item within its row.
            // RadioButton/CheckBox are taller than a plain Label, so match
            // one of their implicit heights and center the text within it.
            Label {
                text: qsTr("Group by:")
                height: authorRadio.implicitHeight
                verticalAlignment: Text.AlignVCenter
            }

            ButtonGroup { id: groupButtons }

            RadioButton {
                id: authorRadio
                text: qsTr("Author")
                ButtonGroup.group: groupButtons
                checked: root.groupMode === "author"
                onToggled: root.groupMode = "author"
            }
            RadioButton {
                text: qsTr("Month")
                ButtonGroup.group: groupButtons
                checked: root.groupMode === "month"
                onToggled: root.groupMode = "month"
            }
            RadioButton {
                text: qsTr("Title")
                ButtonGroup.group: groupButtons
                checked: root.groupMode === "title"
                onToggled: root.groupMode = "title"
            }

            Item { Layout.fillWidth: true }

            CheckBox {
                text: qsTr("Show events")
                checked: root.showEvents
                onToggled: root.showEvents = checked
            }
        }

        ScrollView {
            id: shelvesScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            // Pinned to the viewport width, horizontal scrolling off - we
            // never want the grid itself to scroll sideways, only down.
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            GridLayout {
                id: shelvesGrid
                width: shelvesScroll.availableWidth
                columnSpacing: 12
                rowSpacing: 12

                // At least 1 column, more as the screen gets wider - each
                // column stays close to a ~200px target rather than
                // stretching indefinitely (Shelf.qml also caps its own
                // Layout.maximumWidth so a lone shelf in a row doesn't blow
                // up on very wide screens). Accounts for spacing between
                // columns: N columns need N*itemWidth + (N-1)*spacing to
                // fit, i.e. N <= (width + spacing) / (itemWidth + spacing).
                columns: Math.max(2, Math.floor(width / (200 + (3*columnSpacing))))

                Repeater {
                    model: root.shelfDefs
                    delegate: Shelf {
                        required property var modelData

                        shelfTitle: modelData.title
                        categoryColor: modelData.color
                        events: root.events.filter(e => modelData.types.includes(e.eventType))
                        groupMode: root.groupMode
                        showEvents: root.showEvents
                        navigationStack: root.navigationStack
                        serverBaseUrl: root.serverBaseUrl
                        controller: root.controller
                    }
                }

                Label {
                    Layout.columnSpan: shelvesGrid.columns
                    Layout.fillWidth: true
                    Layout.margins: 16
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("Nothing in the Collection yet.")
                    visible: root.events.length === 0
                    opacity: 0.7
                }
            }
        }
    }
}
