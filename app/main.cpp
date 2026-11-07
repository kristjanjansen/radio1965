#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QSortFilterProxyModel>
#include <QSysInfo>

#include "eventsapiclient.h"
#include "screenkeeper.h"

#ifdef RADIO65_ENABLE_NOTIFICATIONS
#include "notificationmanager.h"
#endif

#ifdef RADIO65_ENABLE_BROADCAST
#include "icecastbroadcaster.h"
#endif

#ifdef RADIO65_LAYOUT_PREVIEW
#include "fakeicecastbroadcaster.h"
#endif

#if defined(Q_OS_ANDROID) && defined(RADIO65_ENABLE_PUSH)
#include <QJniObject>
#endif

#if defined(Q_OS_IOS) && defined(RADIO65_ENABLE_PUSH)
#include "iospush.h"
#include "iosaudiosession.h"
#endif

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);

    app.setOrganizationName("Tarmo Johannes Events and Software");
    app.setOrganizationDomain("eccm.org");
    app.setApplicationName("VÄIN");
    app.setApplicationVersion(QStringLiteral(APP_VERSION));

    EventsApiClient eventsApiClient;
    ScreenKeeper screenKeeper;

#ifdef RADIO65_ENABLE_NOTIFICATIONS
    NotificationManager notificationManager;

    QObject::connect(&eventsApiClient, &EventsApiClient::eventsReceived,
                      &notificationManager, [&notificationManager](const QJsonArray &events) {
                          notificationManager.upsertEvents(events);
                      });

    // "New Arrivals" (status=new) - project-description.md #2.1. Shelving
    // happens silently via server/cron_publish.py (no push), so this only
    // picks it up once EventsApiClient::fetchEvents() re-hydrates the
    // source model. "Collection" (status=shelved) no longer needs its own
    // proxy model here - CollectionPage.qml reads the shelved subset
    // directly via NotificationManager::shelvedEvents() instead, since it
    // groups/sorts the set in QML JS rather than rendering it through a
    // flat ListView.
    QSortFilterProxyModel newEventsModel;
    newEventsModel.setSourceModel(&notificationManager);
    newEventsModel.setFilterRole(NotificationManager::StatusRole);
    newEventsModel.setFilterFixedString("new");
#endif

#ifdef RADIO65_ENABLE_BROADCAST
    IcecastBroadcaster icecastBroadcaster;
#endif

#if defined(Q_OS_ANDROID) && defined(RADIO65_ENABLE_PUSH)
    QJniObject::callStaticMethod<void>(
        "org/eccm/radio65/PushMessagingService", "subscribeToTopic",
        "(Ljava/lang/String;)V",
        QJniObject::fromString("radio65_event").object<jstring>());
    // v2in's own notifications (https://v2in.stream: a live show, an air-raid alert in Kyiv, the all clear)
    QJniObject::callStaticMethod<void>(
        "org/eccm/radio65/PushMessagingService", "subscribeToTopic",
        "(Ljava/lang/String;)V",
        QJniObject::fromString("v2in_notification").object<jstring>());
#endif

#if defined(Q_OS_IOS) && defined(RADIO65_ENABLE_PUSH)
    iosPushInit();
    iosPushSubscribeToTopic("radio65_event");
    iosPushSubscribeToTopic("v2in_notification");   // v2in's own notifications (https://v2in.stream)
    // Baseline route for a fresh launch - .playback always defaults to the
    // loudspeaker, unlike .playAndRecord (only entered while broadcasting,
    // see IcecastBroadcaster::startBroadcast()/teardown()), which otherwise
    // defaults to the quiet earpiece receiver.
    iosAudioSessionActivatePlayback();
#endif

#if !defined(RADIO65_ENABLE_BROADCAST) && defined(RADIO65_LAYOUT_PREVIEW)
    // Declared before the engine so it outlives it - otherwise the context
    // property goes null during engine teardown and bindings error out.
    FakeIcecastBroadcaster fakeBroadcaster;
#endif

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("eventsApiClient", &eventsApiClient);
    engine.rootContext()->setContextProperty("screenKeeper", &screenKeeper);
#ifdef RADIO65_ENABLE_NOTIFICATIONS
    engine.rootContext()->setContextProperty("notificationManager", &notificationManager);
    engine.rootContext()->setContextProperty("newEventsModel", &newEventsModel);
#endif
#ifdef RADIO65_ENABLE_BROADCAST
    engine.rootContext()->setContextProperty("icecastBroadcaster", &icecastBroadcaster);
#elif defined(RADIO65_LAYOUT_PREVIEW)
    engine.rootContext()->setContextProperty("icecastBroadcaster", &fakeBroadcaster);
#endif
    // OS name/version for the "Send Feedback" email (Main.qml's feedbackDialog).
    engine.rootContext()->setContextProperty("systemInfo", QSysInfo::prettyProductName());
    // Main.qml branches startup/refresh on this instead of hitting the
    // real server - seeded from DummyEvents.js via
    // notificationManager.upsertEvents() (see app/CMakeLists.txt's
    // RADIO65_LAYOUT_PREVIEW option).
#ifdef RADIO65_LAYOUT_PREVIEW
    engine.rootContext()->setContextProperty("layoutPreview", true);
#else
    engine.rootContext()->setContextProperty("layoutPreview", false);
#endif
    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);
    engine.loadFromModule("radio65", "Main");

    return app.exec();
}
