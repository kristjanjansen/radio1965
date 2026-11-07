import QtQuick
import QtQuick.Controls

// One tab's worth of the feed ("New Arrivals" or "Collection") -
// project-description.md #2.1. Navigation on tap pushes onto the
// enclosing StackView (see Main.qml's feedComponent).
Item {
    id: root

    property var eventsModel
    // Passed in explicitly: "stackView"/"app" are ids local to Main.qml's
    // document scope, invisible from this separate .qml file, and the
    // StackView.view attached property is only set on the item actually
    // pushed onto the StackView (feedComponent's ColumnLayout), not on
    // EventListView, which sits two levels deeper inside SwipeView.
    // Named differently from Main.qml's "stackView" id: writing
    // `EventListView { stackView: stackView }` with a same-named property
    // would resolve the right-hand side to this instance's own property
    // first (local scope wins over outer ids), causing a self-referencing
    // binding loop instead of picking up the outer StackView.
    required property StackView navigationStack
    // Server base URL (e.g. "https://live.uuu.ee/radio1965/api"), needed so
    // WebViewPage can call eventsApiClient.fetchArticle() for Joomla
    // "article" events. Passed in explicitly for the same reason as
    // navigationStack above.
    required property string serverBaseUrl
    // Same explicit-passing reason as navigationStack above - named
    // "controller" rather than "playbackController" so it doesn't collide
    // with Main.qml's "playbackController" id (same class of
    // self-referencing-binding footgun navigationStack's own comment
    // documents for "stackView").
    required property PlaybackController controller
    // Optional: drawn above the events and scrolled with them (the Home tab's channel cards, ChannelList.qml);
    // Collection sets none
    property Component listHeader: null
    // Main.qml's app.gap: the list's edges and the space between its cards
    required property int gap
    // the list's width and its events, for the header
    readonly property real listWidth: listView.width
    readonly property int count: listView.count

    ListView {
        id: listView
        anchors.fill: parent
        anchors.margins: root.gap
        model: root.eventsModel
        spacing: root.gap
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        header: root.listHeader

        delegate: EventDelegate {
            // eventId/eventType/title/summary/url/tags/status are populated
            // automatically: their names match NotificationManager's role
            // names exactly (see notificationmanager.cpp roleNames()).

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
}
