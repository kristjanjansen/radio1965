import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Pushed onto the shared StackView by CollectionPage.qml's search strip
// (project-description.md #2.1). Scoped to the Collection's shelved items
// only (the `events` array passed in) - full Archive-wide search is
// explicitly deferred in the doc ("Search form, do not implement now").
Page {
    id: root

    required property string query
    required property var events
    required property StackView navigationStack
    required property string serverBaseUrl
    required property PlaybackController controller
    // Main.qml's app.gap, as CollectionPage passes it
    required property int gap

    background: Rectangle { color: "transparent" }

    // Case-insensitive substring match against title, summary, any tag, or
    // payload.author (if/when that field exists - project-description.md
    // #2.1 notes it's "not present yet but will be introduced").
    readonly property var results: {
        const needle = root.query.toLowerCase();
        return root.events.filter(event => {
            if ((event.title || "").toLowerCase().includes(needle))
                return true;
            if ((event.summary || "").toLowerCase().includes(needle))
                return true;
            const author = event.payload && event.payload.author;
            if (author && String(author).toLowerCase().includes(needle))
                return true;
            const tags = event.tags || [];
            for (const tag of tags) {
                if (String(tag).toLowerCase().includes(needle))
                    return true;
            }
            return false;
        });
    }

    header: ToolBar {
        background: Rectangle { color: "transparent" }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 5

            ToolButton {
                text: "←"
                onClicked: root.StackView.view.pop()
            }

            Label {
                text: qsTr("Results for “%1”").arg(root.query)
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
    }

    ListView {
        anchors.fill: parent
        anchors.margins: root.gap
        spacing: root.gap
        clip: true
        model: root.results

        delegate: Card {
            required property var modelData

            width: ListView.view.width
            eventId: modelData.eventId
            eventType: modelData.eventType
            title: modelData.title
            summary: modelData.summary
            authorName: modelData.authorName
            url: modelData.url
            tags: modelData.tags
            status: modelData.status
            payload: modelData.payload
            publishAt: modelData.publishAt

            onArticleRequested: (url, title, articleId, isJoomlaArticle) =>
                root.navigationStack.push(Qt.resolvedUrl("WebViewPage.qml"), {
                    pageUrl: url,
                    pageTitle: title,
                    articleId: isJoomlaArticle ? articleId : 0,
                    serverBaseUrl: root.serverBaseUrl
                })

            onPlayerRequested: (url, title, summary, isLive) =>
                root.controller.playMedia(url, title, summary, isLive)
        }
    }

    Label {
        anchors.centerIn: parent
        width: parent.width - 32
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: qsTr("No matches for “%1”.").arg(root.query)
        visible: root.results.length === 0
        opacity: 0.7
    }
}
