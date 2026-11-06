import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import QtQuick.Dialogs
import QtCore
import QtQuick.Window
import QtWebView
import "DummyEvents.js" as DummyEvents


ApplicationWindow {
    id: app
    width: 480
    height: 640
    visible: true
    property string version: Qt.application.version
    title: qsTr("VÄIN") + " v" + version
    color: Material.background

    //font.family: "monospace"
    //font.pointSize: 12

    property color backgroundEndColor: "#245a28"   // primary container — deep green

    // icecastBroadcaster is only registered as a context property on
    // builds with RADIO65_ENABLE_BROADCAST (see app/CMakeLists.txt) -
    // guarded the same way BroadcastPage.qml already does, so this stays
    // safe even if a future platform ends up without it.
    readonly property bool broadcastAvailable: typeof icecastBroadcaster !== "undefined"
    readonly property bool isBroadcasting: app.broadcastAvailable && icecastBroadcaster.broadcasting

    // Exposed so pushed pages in a *different* QML file (e.g. WebViewPage.qml,
    // reached via the ApplicationWindow.window attached property) can react
    // to the drawer without a direct id reference, which only works within
    // the same document. See WebViewPage.qml's WebView.visible - QtWebView's
    // native content always renders on top of the whole Qt Quick scene
    // (documented Qt limitation, no z value fixes it), so the only way to
    // let the Drawer be usable/visible while an article is open is to
    // temporarily hide the WebView itself while the drawer is open.
    property alias drawerOpened: drawer.opened

    // Drawer, a PlayerBar combobox dropdown or the feedback dialog is open -
    // anything that has to render above a native WebView, which is hidden
    // while this is true.
    readonly property bool overlayOpen: drawer.opened || playerBar.popupOpen || feedbackDialog.opened

    Settings {
        id: appSettings
        property string serverUrl: "https://live.uuu.ee/radio1965/api"
        property bool showInfoOnStartup: true
        // contributor/index.html - register/login/forgot-password page
        // embedded by contributorDialog's WebView below.
        property string contributorWebUrl: "https://eccm.ee/radio1965/contributor/"
        // editor/index.html - opened externally by "Share a gem" below,
        // with userSettings.accessToken appended so the user lands there
        // already logged in (editor/index.html's ?token= handling).
        property string editorWebUrl: "https://eccm.ee/radio1965/editor/"
    }

    // "Become a Contributor" gate (project-description.md #10) - role is
    // "none"/"pending"/"contributor"/"temporaryContributor"/"manager", or
    // "banned" - see bannedDialog below for that last one.
    Settings {
        id: userSettings
        category: "User"
        // layout preview: start as temporaryContributor to expose the broadcast screen
        property string role: layoutPreview ? "temporaryContributor" : "none"
        property string contributorName: ""
        property string contributorEmail: ""
        // Opaque per-account secret from POST /contributors/register -
        // doubles as the credential for checkContributorStatus()'s
        // GET /contributors/status calls. Only ever set for the permanent
        // "Become a Contributor" flow (#10.2) - temporaryContributor
        // (#10.1) has no account/token of its own.
        property string accessToken: ""
    }

    Component.onCompleted: {
        // RADIO65_LAYOUT_PREVIEW build (app/CMakeLists.txt) - seed the real
        // model with local dummy data instead of hitting a live server, so
        // the UI has something to show on a simulator/emulator with no
        // backend reachable. checkContributorStatus() is skipped too since
        // there's no account behind the dummy accessToken (if any).
        if (layoutPreview) {
            notificationManager.upsertEvents(DummyEvents.events);
        } else {
            eventsApiClient.fetchEvents(appSettings.serverUrl);
            checkContributorStatus();
        }
        if (appSettings.showInfoOnStartup) {
            infoDialog.showDontShowCheckbox = true;
            infoDialog.open();
        }
    }

    // Polls GET /contributors/status (project-description.md #10.2) to
    // notice both a "pending" -> "contributor" transition (once the user
    // clicks the emailed confirmation link) and a later ban - the doc's
    // own suggested sync point, "on Refresh events" (called from both here
    // and the header's refresh button below), plus on startup. A no-op
    // whenever there's no account to check (no token - "none" and
    // "temporaryContributor" never have one).
    function checkContributorStatus() {
        if (!userSettings.accessToken)
            return;
        const xhr = new XMLHttpRequest();
        xhr.open("GET", appSettings.serverUrl + "/contributors/status?token=" + encodeURIComponent(userSettings.accessToken));
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            if (xhr.status === 200) {
                const response = JSON.parse(xhr.responseText);
                userSettings.role = response.role;
            }
            // Non-200 (network error, 404 unknown token): leave role as
            // "pending" and silently try again next time - this runs
            // often enough (startup + every refresh) that surfacing a
            // transient failure to the user isn't worth it.
        };
        xhr.send();
    }

    // Push is FYI-only (project-description.md #5): NotificationManager
    // never mutates the event list from a push payload itself - any push
    // arrival (foreground, background, or a notification tap while the app
    // was already running) just re-fetches the real list from the server,
    // same as the manual refresh button.
    Connections {
        target: notificationManager
        function onRefreshRequested() {
            eventsApiClient.fetchEvents(appSettings.serverUrl);
        }
    }

    background: Rectangle {
        gradient: Gradient {
            GradientStop { position: 0.0; color: Material.backgroundColor }
            GradientStop { position: 0.6; color: Material.backgroundColor }
            GradientStop { position: 0.8; color: backgroundEndColor.darker() }
            GradientStop { position: 1.0; color: backgroundEndColor }
        }
    }

    flags: Qt.ExpandedClientAreaHint | Qt.NoTitleBarBackgroundHint

    header: ToolBar {
        id: toolBar
        width: parent.width
        // Covered by lockOverlay while locked anyway, but belt-and-
        // suspenders: input events can't reach menu/refresh either.
        enabled: !lockOverlay.opened

        implicitHeight: contentItem.implicitHeight + topPadding + bottomPadding

        background: Rectangle {color: "transparent" }

        topPadding: parent.SafeArea ? parent.SafeArea.margins.top : 10
        bottomPadding: 10

        contentItem:  Item {
            anchors.topMargin: 10
            implicitHeight: titleLabel.implicitHeight + 10

            Label {
                id: titleLabel
                anchors.centerIn: parent
                text: title
                font.pointSize: 16
                font.bold: true
                horizontalAlignment: Qt.AlignHCenter

            }

            ToolButton {
                id: menuButton

                anchors.left: parent.left
                anchors.leftMargin: 5
                anchors.verticalCenter: parent.verticalCenter
                icon.source: "qrc:/images/menu.svg"
                onClicked: drawer.opened ? drawer.close() : drawer.open()
            }

            ToolButton {
                id: refreshButton

                anchors.right: parent.right
                anchors.rightMargin: 5
                anchors.verticalCenter: parent.verticalCenter
                //text: "⟳"
                icon.source: "qrc:/images/refresh.svg"
                onClicked: {
                    if (layoutPreview) {
                        notificationManager.upsertEvents(DummyEvents.events);
                    } else {
                        eventsApiClient.fetchEvents(appSettings.serverUrl);
                        checkContributorStatus();
                    }
                }
            }

            // Android only: without a foreground service, Android's Doze/
            // App Standby can suspend playback once the screen sleeps or
            // the app is backgrounded - this (combined with ScreenKeeper,
            // see PlaybackController.qml, which keeps the display on while
            // playing) lets a user who's about to pocket the phone
            // deliberately lock the UI instead, without risking a stray tap
            // on play/stop/menu. Not needed on iOS, which already has a
            // working background-audio setup (UIBackgroundModes: audio +
            // AVAudioSession .playback, see iosaudiosession.mm). Replaces
            // the old "Send Feedback" shortcut here - still reachable from
            // the drawer menu below.
            ToolButton {
                id: lockButton

                anchors.right: refreshButton.left
                anchors.verticalCenter: parent.verticalCenter
                visible: Qt.platform.os === "android"
                icon.source: "qrc:/images/lock.svg"
                onClicked: lockOverlay.open()
            }
        }
    }

    Drawer {
        id: drawer
        width: Math.min(Math.max(app.width * 0.7, 360), app.width - 24)
        height: app.height
        //y: toolBar.height
        property int marginLeft: 20

        background: Rectangle {
            anchors.fill:parent;
            color: Material.backgroundColor.lighter()
        }

        ScrollView {
            anchors.fill: parent
            anchors.margins: 10
            clip: true
            // contentWidth: availableWidth

            ColumnLayout {
                width: parent.width //  availableWidth
                spacing: 10



                MenuItem {
                    text: qsTr("Become a Contributor / Log in")
                    // Was `!== "contributor"` - now also hidden while
                    // "pending" (see the Label just below) and while
                    // already "manager". Still offered for
                    // temporaryContributor, so upgrading to a real account
                    // is possible. One entry covers both register and
                    // login - contributor/index.html's own views handle
                    // that split (project-description.md #10's "Become a
                    // contributor/Log in" TODO).
                    visible: userSettings.role === "none" || userSettings.role === "temporaryContributor"
                    onTriggered: {
                        contributorDialog.open()
                        drawer.close()
                    }
                }

                Label {
                    text: qsTr("Registration pending - check your email")
                    visible: userSettings.role === "pending"
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                    opacity: 0.8
                }

                MenuItem {
                    text: qsTr("Share a gem")
                    // project-description.md #10's "Share a gem" action -
                    // opens editor/index.html in the system browser
                    // (rather than the in-app WebView used by
                    // contributorDialog) so the full editing form has a
                    // real browser's room/affordances to work with, with
                    // accessToken appended so the user lands there already
                    // logged in (editor/index.html's ?token= handling).
                    // Only contributor|manager per the doc - excludes
                    // temporaryContributor, which has no account/token to
                    // log the editor in with anyway.
                    visible: userSettings.role === "contributor" || userSettings.role === "manager"
                    onTriggered: {
                        Qt.openUrlExternally(appSettings.editorWebUrl + "?token=" + encodeURIComponent(userSettings.accessToken))
                        drawer.close()
                    }
                }

                MenuItem {
                    text: qsTr("Temporary contributor")
                    // Hidden once you're already either kind of contributor -
                    // "Become a Contributor" above stays offered even as a
                    // temporaryContributor, so upgrading later is still
                    // possible; this one has nothing left to offer then.
                    visible: userSettings.role === "none"
                    onTriggered: {
                        temporaryContributorDialog.open()
                        drawer.close()
                    }
                }

                MenuItem {
                    text: qsTr("Leave contributor role")
                    visible: userSettings.role !== "none"
                    onTriggered: {
                        drawer.close()
                        // temporaryContributor has no account/token at all
                        // (project-description.md #10.1 - password-only, no
                        // DB row) - nothing server-side to offer deleting,
                        // so skip straight to the local-only reset below.
                        if (userSettings.accessToken) {
                            leaveContributorDialog.open()
                        } else {
                            userSettings.role = "none"
                        }
                    }
                }

                MenuItem {
                    text: qsTr("Send feedback")
                    onTriggered: {
                        feedbackDialog.open()
                        drawer.close()
                    }
                }

                MenuItem {
                    text: qsTr("Info")
                    onTriggered: {
                        infoDialog.showDontShowCheckbox = false;
                        infoDialog.open()
                        drawer.close()
                    }
                }

            }
        }

    }

    // project-description.md #10: "If user is marked 'banned' - do not
    // allow use of the app at all." Bound directly to userSettings.role
    // rather than opened via open()/close(), so it reappears immediately
    // (even across restarts) for as long as the server says "banned" -
    // caught by checkContributorStatus() on startup and every refresh.
    // No close button and closePolicy: NoAutoClose - modal already blocks
    // clicks on everything behind it, and there's nothing to confirm/
    // dismiss here.
    // Asked whenever "Leave contributor role" is triggered for an account
    // that actually has a server-side row (pending/contributor/manager -
    // temporaryContributor skips this entirely, see that MenuItem above).
    // POST /contributors/delete scrubs email/password/access_token/role
    // but keeps id and name, since already-published events still
    // reference this user as their author (server/main.py's
    // delete_contributor()).
    Dialog {
        id: leaveContributorDialog
        title: qsTr("Leave contributor role")
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Cancel
        width: Math.min(app.width - 40, 420)

        property bool deleting: false

        function leaveLocally() {
            userSettings.role = "none"
            // Stale otherwise - harmless (checkContributorStatus() is a
            // no-op without a token), but no reason to keep it around once
            // the account is disowned locally.
            userSettings.accessToken = ""
            leaveContributorDialog.close()
        }

        onOpened: leaveContributorDialog.deleting = false

        ColumnLayout {
            width: leaveContributorDialog.availableWidth
            spacing: 8

            Label {
                text: qsTr("Do you want to delete your registration data from the database? If you published any items, these will still carry your name.")
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 8

                BusyIndicator {
                    implicitWidth: 20
                    implicitHeight: 20
                    running: leaveContributorDialog.deleting
                    visible: running
                }

                Button {
                    text: qsTr("Delete my data")
                    enabled: !leaveContributorDialog.deleting
                    onClicked: {
                        leaveContributorDialog.deleting = true;
                        const xhr = new XMLHttpRequest();
                        xhr.open("POST", appSettings.serverUrl + "/contributors/delete");
                        xhr.setRequestHeader("Content-Type", "application/json");
                        xhr.onreadystatechange = function() {
                            if (xhr.readyState !== XMLHttpRequest.DONE)
                                return;
                            // Best-effort either way - whether the delete
                            // actually reached the server or not, there's
                            // nothing more useful to do here than fall back
                            // to the local-only reset (same as "Keep my
                            // data"), so the role gate doesn't get stuck on
                            // a network hiccup.
                            leaveContributorDialog.leaveLocally();
                        };
                        xhr.send(JSON.stringify({ access_token: userSettings.accessToken }));
                    }
                }

                Button {
                    text: qsTr("Keep my data")
                    enabled: !leaveContributorDialog.deleting
                    onClicked: leaveContributorDialog.leaveLocally()
                }
            }
        }
    }

    Dialog {
        id: bannedDialog
        title: qsTr("Access revoked")
        modal: true
        anchors.centerIn: parent
        closePolicy: Popup.NoAutoClose
        visible: userSettings.role === "banned"
        width: Math.min(app.width - 40, 420)

        ColumnLayout {
            width: bannedDialog.availableWidth

            Label {
                text: qsTr("You are exiled. Contact the administrators if it feels unjust.")
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }
    }

    Dialog {
        id: infoDialog
        title: qsTr("About VÄIN")
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Close
        // Dialog doesn't auto-size itself from an explicit `width:` set on
        // an inner child (that only ever controls the ColumnLayout's own
        // width, not the Dialog's actual content-area/frame) - same fix as
        // contributorDialog below: the width has to go on the Dialog itself.
        width: Math.min(app.width - 40, 420)

        // Only true when this dialog was auto-opened at startup (see
        // Component.onCompleted above) - set back to false whenever it's
        // opened from the drawer's "Info" MenuItem, so the checkbox below
        // (which controls appSettings.showInfoOnStartup, a startup-only
        // concern) doesn't show up in a context where it wouldn't mean
        // anything.
        property bool showDontShowCheckbox: false

        ColumnLayout {
            spacing: 8
            width: infoDialog.availableWidth

            // Label {
            //     text: qsTr("Radio 1965 %1").arg(version)
            //     font.bold: true
            //     font.pointSize: 16
            // }

            Label {
                text: qsTr(`
Väin (Estonian for 'strait'), a seemingly narrow body of water with a depth undetectable from the surface and a layered structure that constantly varies. It is an intermediate area that bridges one time to another.

VÄIN is an app created for the 'Radio Tallinn 1965' project, run by the Estonian Centre for Contemporary Music. It connects not only the past and the present, but also the people using it. Follow or broadcast audio streams, receive notifications about key events, and read, listen to, watch, or share something meaningful. Be connected with ECCM.
                           `)
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            Label {
                text: qsTr("Based on Qt Framework — qt.io")
                font.italic: true
            }

            Label {
                text: qsTr("© Tarmo Johannes\ntrmjhnns@gmail.com")
                font.pointSize: 10
            }

            CheckBox {
                text: qsTr("Don't show on startup")
                visible: infoDialog.showDontShowCheckbox
                checked: !appSettings.showInfoOnStartup
                onToggled: appSettings.showInfoOnStartup = !checked
            }
        }
    }

    Dialog {
        id: contributorDialog
        title: qsTr("Become a Contributor / Log in")
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Cancel
        // A mid-register/login tap on the surrounding dimmed area is easy to
        // trigger by accident on a phone - only Cancel/Back (or the embedded
        // page completing) should close this, not an outside tap.
        closePolicy: Popup.CloseOnEscape
        // Dialog doesn't auto-size itself from an explicit `width:` set on
        // an inner child - same fix as infoDialog above. Taller than the
        // other dialogs here since it now hosts a full web page rather
        // than a few fields.
        width: Math.min(app.width - 40, 480)
        height: Math.min(app.height - 80, 640)

        property bool loading: true

        // Reload the page fresh on every open - including after a
        // previous attempt handed off a result - so it always starts back
        // at the register view.
        onOpened: {
            contributorDialog.loading = true
            // "?embed=app" tells contributor/index.html to hand its result
            // back via the "?action=result&data=" navigation below instead of
            // redirecting to the editor page (which only makes sense for a
            // standalone browser visit).
            // "&t=" cache-buster: eccm.ee sends no Cache-Control, so iOS's
            // WKWebView could keep serving an older cached copy of the page
            // (heuristic caching off Last-Modified) after it's redeployed.
            contributorWebView.url = appSettings.contributorWebUrl + "?embed=app&t=" + Date.now()
        }

        // contributor/index.html (register/login/forgot-password) embedded
        // via WebView instead of native fields - project-description.md
        // #10's "Become a contributor/Log in" TODO, plus "also on the web".
        // QtWebView has no JS bridge (unlike WebEngine's WebChannel), so
        // the page hands results back via a real navigation to
        // "?action=result&data=<json>" on itself, caught below via
        // onLoadingChanged's LoadStartedStatus (loadRequest.url, not
        // contributorWebView.url - the request is observed as it starts,
        // before the new page even loads). Was a same-document
        // "#result=..." hash change instead, with no real navigation at
        // all - worked on Android/desktop but never reliably reached
        // onUrlChanged on iOS's WKWebView backend (confirmed: login
        // worked on Android/Linux, silently did nothing on iOS). A real
        // navigation forces every backend's navigation-lifecycle
        // callbacks to fire, which is what onLoadingChanged already
        // depends on for the loading indicator below regardless.
        WebView {
            id: contributorWebView
            anchors.fill: parent
            visible: !contributorDialog.loading

            // Checked on every loading status and on urlChanged, not just
            // LoadStartedStatus: which callback carries the result URL
            // differs per backend - on iOS (WKWebView) LoadStarted can still
            // report the previous URL, while LoadSucceeded and urlChanged
            // only fire once the result page has committed.
            function handleResultUrl(url) {
                const urlString = url.toString();
                const marker = "action=result&data=";
                const index = urlString.indexOf(marker);
                if (index === -1)
                    return;
                try {
                    handleResultPayload(JSON.parse(decodeURIComponent(urlString.substring(index + marker.length))));
                } catch (e) {
                    console.warn("[contributorDialog] bad result payload:", e, urlString);
                }
            }

            function handleResultPayload(payload) {
                if (!payload || !contributorDialog.opened)
                    return;
                userSettings.role = payload.role;
                userSettings.accessToken = payload.token;
                if (payload.name)
                    userSettings.contributorName = payload.name;
                if (payload.email)
                    userSettings.contributorEmail = payload.email;
                contributorDialog.close();
            }

            // Extra channel alongside the URL checks: contributor/index.html
            // also puts the result into document.title as
            // "radio65-result:<json>", and Qt's iOS (WKWebView) backend
            // reliably reports every title change. (runJavaScript() polling
            // was tried first and crashed on iOS.)
            onTitleChanged: {
                const marker = "radio65-result:";
                const t = contributorWebView.title;
                if (!t || !t.startsWith(marker))
                    return;
                try {
                    handleResultPayload(JSON.parse(t.substring(marker.length)));
                } catch (e) {
                    console.warn("[contributorDialog] bad result title:", e, t);
                }
            }

            onLoadingChanged: function(loadRequest) {
                if (loadRequest.status !== WebView.LoadStartedStatus)
                    contributorDialog.loading = false
                handleResultUrl(loadRequest.url)
            }

            onUrlChanged: {
                handleResultUrl(contributorWebView.url)
            }
        }

        BusyIndicator {
            anchors.centerIn: parent
            running: contributorDialog.loading
            visible: running
        }
    }

    Dialog {
        id: temporaryContributorDialog
        title: qsTr("Temporary contributor")
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Cancel
        // Same reasoning as contributorDialog above - width has to go on
        // the Dialog itself, not an inner child.
        width: Math.min(app.width - 40, 420)
        // Same reasoning as contributorDialog above - an accidental outside
        // tap while typing a name/password shouldn't dismiss this, but
        // Cancel/Back still should.
        closePolicy: Popup.CloseOnEscape

        property string errorMessage: ""
        property bool verifying: false

        // Same reasoning as contributorDialog's onOpened above.
        onOpened: {
            tempNameField.text = ""
            tempPasswordField.text = ""
            temporaryContributorDialog.errorMessage = ""
            temporaryContributorDialog.verifying = false
        }

        // Checked server-side, not locally (project-description.md #10.1
        // item 1 is explicit about this - unlike contributorDialog's still-
        // placeholder "1965" check above) against
        // config.TEMPORARY_CONTRIBUTOR_PASSWORD_PATH, a plain-text file an
        // admin can edit directly on the server - see server/main.py's
        // verify_temporary_contributor_password(). Plain XMLHttpRequest
        // here rather than routing through EventsApiClient (C++): this is
        // the only place in the app that needs a one-off POST, so adding a
        // whole C++ method (+ rebuild) for it isn't worth it.
        function submit() {
            temporaryContributorDialog.errorMessage = "";
            temporaryContributorDialog.verifying = true;
            const xhr = new XMLHttpRequest();
            xhr.open("POST", appSettings.serverUrl + "/temporary-contributor/verify");
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== XMLHttpRequest.DONE)
                    return;
                temporaryContributorDialog.verifying = false;
                if (xhr.status === 200) {
                    userSettings.role = "temporaryContributor";
                    userSettings.contributorName = tempNameField.text;
                    temporaryContributorDialog.close();
                } else if (xhr.status === 403) {
                    temporaryContributorDialog.errorMessage = qsTr("Incorrect password.");
                } else {
                    temporaryContributorDialog.errorMessage = qsTr("Could not reach the server. Try again later.");
                }
            };
            xhr.send(JSON.stringify({ password: tempPasswordField.text }));
        }

        ColumnLayout {
            spacing: 8
            width: temporaryContributorDialog.availableWidth

            // No email field - project-description.md #10.1 item 1
            // explicitly says temporary contributors don't need to give one.
            TextField {
                id: tempNameField
                Layout.fillWidth: true
                enabled: !temporaryContributorDialog.verifying
                placeholderText: qsTr("Name")
            }

            TextField {
                id: tempPasswordField
                Layout.fillWidth: true
                enabled: !temporaryContributorDialog.verifying
                placeholderText: qsTr("Password")
                echoMode: TextInput.Password
            }

            Label {
                text: temporaryContributorDialog.errorMessage
                color: "crimson"
                visible: text !== ""
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 8

                BusyIndicator {
                    implicitWidth: 20
                    implicitHeight: 20
                    running: temporaryContributorDialog.verifying
                    visible: running
                }

                Button {
                    text: qsTr("Submit")
                    enabled: !temporaryContributorDialog.verifying
                    onClicked: temporaryContributorDialog.submit()
                }
            }
        }
    }

    // Tester feedback, emailed by the server's POST /feedback.
    Dialog {
        id: feedbackDialog
        title: qsTr("Send Feedback")
        modal: true
        standardButtons: Dialog.Cancel
        // Same reasoning as contributorDialog above - width has to go on
        // the Dialog itself, not an inner child.
        width: Math.min(app.width - 40, 420)
        // Same reasoning as contributorDialog above - an accidental outside
        // tap while typing feedback shouldn't dismiss (and discard) it, but
        // Cancel/Back still should.
        closePolicy: Popup.CloseOnEscape

        // Capped to the window; the content scrolls (contentItem below) when
        // it doesn't fit, e.g. on a phone in landscape. No manual keyboard
        // handling - the platform already shifts the window for the
        // on-screen keyboard, and doing it here too broke the dialog apart.
        anchors.centerIn: parent
        height: Math.min(implicitHeight, parent.height - 20)

        property string errorMessage: ""
        property bool sending: false

        // Keeps any unsent text (e.g. after an accidental Cancel), only
        // the error state is reset.
        onOpened: {
            feedbackDialog.errorMessage = ""
            if (!feedbackEmailField.text)
                feedbackEmailField.text = userSettings.contributorEmail
        }

        function submit() {
            feedbackDialog.errorMessage = "";
            feedbackDialog.sending = true;
            const xhr = new XMLHttpRequest();
            xhr.open("POST", appSettings.serverUrl + "/feedback");
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== XMLHttpRequest.DONE)
                    return;
                feedbackDialog.sending = false;
                if (xhr.status === 200) {
                    feedbackTextArea.text = "";
                    feedbackDialog.close();
                    feedbackThanks.open();
                } else if (xhr.status === 429) {
                    feedbackDialog.errorMessage = qsTr("Too many messages, try again later.");
                } else {
                    feedbackDialog.errorMessage = qsTr("Could not send feedback. Try again later.");
                }
            };
            xhr.send(JSON.stringify({
                text: feedbackTextArea.text,
                email: feedbackEmailField.text.trim(),
                name: userSettings.contributorName,
                role: userSettings.role,
                app_version: Qt.application.version,
                platform: Qt.platform.os + " / " + systemInfo
            }));
        }

        contentItem: ScrollView {
            id: feedbackScroll
            clip: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

          ColumnLayout {
            spacing: 8
            width: feedbackScroll.availableWidth

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: qsTr("What did you like or dislike? If there was a problem, describe what you did, what happened and what would you expect to happen")
            }

            // Responsive: about a quarter of the window, 60-150 px.
            ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(60, Math.min(150, app.height * 0.25))

                TextArea {
                    id: feedbackTextArea
                    wrapMode: TextEdit.Wrap
                    enabled: !feedbackDialog.sending
                    placeholderText: qsTr("Your feedback")
                }
            }

            TextField {
                id: feedbackEmailField
                Layout.fillWidth: true
                enabled: !feedbackDialog.sending
                placeholderText: qsTr("Your email (optional, for replies)")
                inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: feedbackDialog.errorMessage
                color: "crimson"
                visible: text !== ""
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 8

                BusyIndicator {
                    implicitWidth: 20
                    implicitHeight: 20
                    running: feedbackDialog.sending
                    visible: running
                }

                Button {
                    text: qsTr("Send")
                    enabled: !feedbackDialog.sending && feedbackTextArea.text.trim() !== ""
                    onClicked: feedbackDialog.submit()
                }
            }
          }
        }
    }

    // Short auto-hiding confirmation after feedback was sent.
    Popup {
        id: feedbackThanks
        anchors.centerIn: parent
        modal: false
        closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape
        onOpened: feedbackThanksTimer.restart()

        Label { text: qsTr("Thanks for your feedback!") }

        Timer {
            id: feedbackThanksTimer
            interval: 2500
            onTriggered: feedbackThanks.close()
        }
    }

    // "Press back again to exit" hint - shown by the Keys.onBackPressed
    // handler above on the first Back press at the true root (home tab, no
    // pages pushed, not broadcasting), same auto-hide pattern as
    // feedbackThanks above.
    Popup {
        id: exitHintToast
        anchors.centerIn: parent
        modal: false
        closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape

        Label { text: qsTr("Press Back again to exit") }
    }

    // Shown by the Keys.onBackPressed handler above instead of immediately
    // backgrounding/exiting the app while a broadcast is live - an
    // accidental Back press shouldn't silently cut a live broadcast.
    Dialog {
        id: leaveBroadcastConfirmDialog
        title: qsTr("Leave while broadcasting?")
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Cancel
        width: Math.min(app.width - 40, 420)

        ColumnLayout {
            width: leaveBroadcastConfirmDialog.availableWidth
            spacing: 8

            Label {
                text: qsTr("You're currently broadcasting live. Leaving now may end the broadcast.")
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            Button {
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("Leave anyway")
                onClicked: {
                    leaveBroadcastConfirmDialog.close();
                    Qt.quit();
                }
            }
        }
    }

    // Android-only "pocket lock" (see lockButton in the header above) - a
    // dark, control-free overlay covering the whole window (via
    // Overlay.overlay, same window-covering-popup pattern Box.qml's
    // groupPopup already uses - sits above the header too) so accidental
    // taps/swipes don't do anything. Playback itself is untouched - this
    // only blocks input/visuals. closePolicy: NoAutoClose - only the
    // triple-tap below closes it (plus toolBar/the main ColumnLayout above
    // are both explicitly disabled while this is open, as a second layer of
    // protection against any swipe reaching the SwipeView underneath).
    Popup {
        id: lockOverlay
        parent: Overlay.overlay
        x: 0
        y: 0
        width: parent ? parent.width : app.width
        height: parent ? parent.height : app.height
        modal: true
        focus: true
        closePolicy: Popup.NoAutoClose
        background: Rectangle { color: "black" }

        // Explicitly swallow Back while locked - a predictive-back/Key_Back
        // event reaching the outer ColumnLayout's Keys.onBackPressed would
        // pop the StackView or background the app, bypassing the lock
        // entirely. Only the triple-tap above should ever close this.
        Keys.onBackPressed: (event) => event.accepted = true

        // All 3 taps must land within this window (measured from the
        // first tap, not just consecutive-pair gaps - a slow 3-tap
        // shouldn't unlock it) or the count restarts from the next tap.
        readonly property int tapWindowMs: 1000
        property int tapCount: 0
        property real firstTapTime: 0

        onOpened: lockOverlay.tapCount = 0

        contentItem: MouseArea {
            anchors.fill: parent
            onClicked: {
                const now = Date.now();
                if (lockOverlay.tapCount === 0 || now - lockOverlay.firstTapTime > lockOverlay.tapWindowMs) {
                    lockOverlay.tapCount = 1;
                    lockOverlay.firstTapTime = now;
                } else {
                    lockOverlay.tapCount += 1;
                }
                if (lockOverlay.tapCount >= 3)
                    lockOverlay.close();
            }

            Label {
                anchors.centerIn: parent
                text: qsTr("Locked - tap 3 times quickly to unlock")
                color: "white"
                opacity: 0.6
                font.pointSize: 12
            }
        }
    }

    // Instantiated exactly once here and threaded down explicitly to
    // PlayerBar, VideoPage (as a pushed initial property) and both
    // EventListView instances - see PlaybackController.qml for why this is
    // plain explicit passing rather than `pragma Singleton` global access.
    PlaybackController {
        id: playbackController
    }

    // PlayerBar sits above the StackView (not inside feedComponent) so it
    // stays visible across tab switches and over pushed pages (WebViewPage,
    // VideoPage).
    ColumnLayout {
        id: mainColumn
        anchors.fill: parent
        spacing: 0
        // Belt-and-suspenders alongside lockOverlay's own modal/
        // NoAutoClose blocking: disabling this outright means the
        // SwipeView/TabBar/PlayerBar underneath can't receive so much as a
        // swipe gesture while locked, regardless of z-order subtleties. As a
        // side effect this also means this Item (and its Keys.onBackPressed
        // below) can't hold focus/receive the Back key at all while locked -
        // lockOverlay's own Keys.onBackPressed handles that case instead.
        enabled: !lockOverlay.opened
        focus: true

        // Android targetSdkVersion 36 routes Back through Qt Quick as a key
        // event (see android/AndroidManifest.xml's enableOnBackInvokedCallback
        // comment) rather than finishing the Activity outright - this is
        // where that gets turned into in-app navigation instead of exiting
        // from any sub-screen. WebViewPage.qml/VideoPage.qml both already
        // implement their own back button as a plain stackView.pop(), so
        // popping the StackView here covers both uniformly.

        // True for ~2s after a Back press at the true root (home tab, no
        // pages pushed, not broadcasting) - a second Back press within that
        // window actually exits; otherwise it's just re-armed and a hint is
        // shown. Standard Android "press back again to exit" pattern, so a
        // single accidental Back from the root screen can't silently close
        // the app.
        property bool backExitArmed: false

        Keys.onBackPressed: (event) => {
            if (drawer.opened) {
                drawer.close();
                event.accepted = true;
            } else if (stackView.depth > 1) {
                // A WebViewPage/VideoPage is pushed - pop it, same as their
                // own back buttons already do. VideoPage specifically needs
                // its closeVideoPage() (stop playback + restore out of
                // fullscreen), not a bare pop - duck-typed via the function
                // check since Main.qml can't import VideoPage.qml's type.
                if (stackView.currentItem && stackView.currentItem.closeVideoPage)
                    stackView.currentItem.closeVideoPage();
                else
                    stackView.pop();
                event.accepted = true;
            } else if (stackView.currentItem && stackView.currentItem.currentTabIndex !== 0) {
                // On the Collection/Broadcast tab - go back to the home
                // ("New Arrivals") tab first, same as navigating back a
                // level, rather than exiting straight from a non-home tab.
                stackView.currentItem.currentTabIndex = 0;
                event.accepted = true;
            } else if (app.broadcastAvailable && icecastBroadcaster.broadcasting) {
                leaveBroadcastConfirmDialog.open();
                event.accepted = true;
            } else if (!backExitArmed) {
                backExitArmed = true;
                backExitTimer.restart();
                exitHintToast.open();
                event.accepted = true;
            } else {
                // Second Back press within the window above, at the true
                // root - exit. Deliberately NOT event.accepted = false:
                // leaving it to Android's native fallback (finish the
                // Activity on an unaccepted Back key) worked right after
                // launch but produced a black screen once a SwipeView tab
                // had been touched/focused first - calling Qt.quit()
                // ourselves sidesteps that native pass-through path
                // entirely and exits deterministically.
                event.accepted = true;
                Qt.quit();
            }
        }

        Timer {
            id: backExitTimer
            interval: 2000
            onTriggered: {
                mainColumn.backExitArmed = false;
                exitHintToast.close();
            }
        }

        PlayerBar {
            id: playerBar
            Layout.fillWidth: true
            controller: playbackController
            // Hidden (not just occluded) while VideoPage is fullscreen so
            // StackView/VideoPage can actually claim its space too - a
            // Layout child's visible:false is excluded from space
            // allocation. Keyed off the window's own visibility rather
            // than a new custom signal/alias: Window.FullScreen is
            // currently only ever entered via VideoPage.qml's own toggle,
            // so this stays correct without a new cross-file channel.
            visible: app.visibility !== Window.FullScreen
        }

        StackView {
            id: stackView
            Layout.fillWidth: true
            Layout.fillHeight: true
            initialItem: feedComponent

            // WebViewPage.qml's QtWebView content renders via a native
            // platform view (Android's real WebView widget / iOS's
            // WKWebView) composited on top of the entire Qt Quick scene -
            // it's not a real scene-graph item, so no z value can put the
            // Drawer (or any QML Popup/Overlay) above it once it's pushed.
            // Closing the drawer whenever the current page changes sidesteps
            // that platform limitation instead of trying to out-z-order it.
            onCurrentItemChanged: if (drawer.opened) drawer.close()
        }
    }

    // Pushes/pops VideoPage.qml as the currently-playing media's video
    // track appears/disappears - covers both video files and a
    // (hypothetical, future) video stream the same way. Tracked with an
    // explicit bool rather than sniffing stackView.currentItem's type, so
    // a manual pop by the user (VideoPage's back button) doesn't get
    // immediately re-pushed - onHasVideoChanged only fires on a genuine
    // change, not continuously.
    property bool videoPageOpen: false

    Connections {
        target: playbackController.player
        function onHasVideoChanged() {
            if (playbackController.player.hasVideo && !app.videoPageOpen) {
                stackView.push(Qt.resolvedUrl("VideoPage.qml"), { controller: playbackController });
                app.videoPageOpen = true;
            } else if (!playbackController.player.hasVideo && app.videoPageOpen) {
                stackView.pop();
                app.videoPageOpen = false;
            }
        }
    }

    Component {
        id: feedComponent

        ColumnLayout {
            spacing: 0

            // Exposed so the app-level Keys.onBackPressed handler (Main.qml,
            // on the ColumnLayout wrapping PlayerBar+StackView) can send
            // Back to the home tab before it considers exiting - this
            // ColumnLayout is stackView.currentItem while viewing any tab.
            property alias currentTabIndex: tabBar.currentIndex

            TabBar {
                id: tabBar
                Layout.fillWidth: true

                TabButton { icon.source: "qrc:/images/home.svg"   /*text: qsTr("New Arrivals")*/ }
                TabButton { icon.source: "qrc:/images/cards_stack.svg" /*text: qsTr("Collection")*/ }
                TabButton {
                    id: broadcastTabButton
                    icon.source: "qrc:/images/broadcast.svg" /*text: qsTr("Broadcast")*/
                    icon.color: app.isBroadcasting ? "crimson" : Material.foreground

                    // Small blinking "recording" dot overlay, on-air only -
                    // declared as a plain child of the TabButton control,
                    // which Qt Quick Controls renders as an overlay on top
                    // of its own contentItem (the usual way to badge a
                    // control without touching its template).
                    Rectangle {
                        id: broadcastDot
                        width: 8
                        height: 8
                        radius: 4
                        color: "crimson"
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: 6
                        visible: app.isBroadcasting

                        SequentialAnimation on opacity {
                            running: broadcastDot.visible
                            loops: Animation.Infinite
                            NumberAnimation { from: 1.0; to: 0.2; duration: 500 }
                            NumberAnimation { from: 0.2; to: 1.0; duration: 500 }
                        }
                    }
                }
            }

            SwipeView {
                id: swipeView
                clip: true
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: tabBar.currentIndex
                onCurrentIndexChanged: tabBar.currentIndex = currentIndex

                EventListView {
                    eventsModel: newEventsModel;
                    navigationStack: stackView;
                    serverBaseUrl: appSettings.serverUrl;
                    controller: playbackController
                }

                CollectionPage {
                    clip: true // this did the tric of overflowing to next page
                    navigationStack: stackView;
                    serverBaseUrl: appSettings.serverUrl;
                    controller: playbackController
                }

                BroadcastPage {
                    // "manager" per project-description.md #10.2: "Only
                    // people with role 'contributor', 'temporaryContributor'
                    // and 'manager' can broadcast". Nothing assigns
                    // "manager" yet (manual DB update only - see the
                    // registration plan's "Out of scope" notes), but the
                    // gate itself should already respect it.
                    isContributor: userSettings.role === "contributor" || userSettings.role === "temporaryContributor"
                                   || userSettings.role === "manager"
                    isTemporaryContributor: userSettings.role === "temporaryContributor"
                    // Threaded down into IcecastBroadcaster's ice-audio-info
                    // header so server/icecast_on_connect.sh can set the
                    // published event's author_id - empty for
                    // temporaryContributor, which has no account/token.
                    accessToken: userSettings.accessToken
                    isManager: userSettings.role === "manager"
                }



            }
        }
    }

}
