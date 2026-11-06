#pragma once

#include <QAbstractListModel>
#include <QJsonArray>
#include <QJsonObject>
#include <QVariantMap>
#include <QVector>

struct EventItem
{
    QString id;
    QString type;
    QString title;
    QString summary;
    QString url;
    QString publishAt;
    QString shelfAt;
    QString status;
    QStringList tags;
    QVariantMap payload;
    // "Shared by: <name>" on Collection/search cards (project-description.md
    // #10) - empty when the event has no author (nothing published it via
    // a logged-in contributor, or predates this feature).
    QString authorName;
};

// Holds the event feed (project-description.md #4), fed exclusively by
// GET /events (EventsApiClient, on launch/refresh/push). FCM push is
// FYI-only: it shows a system notification (Android/iOS native side) and
// nudges the app to re-fetch from the server - the app never trusts or
// parses event content out of the push payload itself. Nothing is
// persisted across app restarts - EventsApiClient::fetchEvents()
// re-hydrates on launch instead. Exposed to QML as context property
// "notificationManager"; "New Arrivals"/"Collection" are
// QSortFilterProxyModels over this, set up in main.cpp.
class NotificationManager : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        TypeRole,
        TitleRole,
        SummaryRole,
        UrlRole,
        PublishAtRole,
        ShelfAtRole,
        StatusRole,
        TagsRole,
        PayloadRole,
        AuthorNameRole
    };

    explicit NotificationManager(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    // Applies a whole GET /events batch under a single
    // beginInsertRows/endInsertRows pair. Calling this once per event
    // instead (several synchronous begin/endInsertRows(parent, 0, 0) in a
    // row, all at row 0) confuses ListView's delegate incubation - the
    // proxy models end up with the right rows/data (confirmed via direct
    // data() calls and via Repeater, which isn't affected) but ListView
    // delegates for those rows get created with no `model` context at all.
    Q_INVOKABLE void upsertEvents(const QJsonArray &events);

    // Called from the Android JNI / iOS bridges whenever a push arrives
    // (foreground, background, or a notification tap) - title/summary/data
    // are intentionally ignored (push is FYI-only, never a data source; the
    // system notification itself is built independently, natively, from
    // the same FCM payload). This just asks QML to re-fetch from the
    // server, same as the manual refresh button - see refreshRequested().
    Q_INVOKABLE void addMessage(const QString &title, const QString &summary, const QString &data);

    // Title/summary of the current type=="livestream" && status=="new"
    // event whose url matches `url` exactly, or an empty map if none -
    // metadata only (project-description.md #8). PlaybackController.qml
    // passes channelUrl(selectedChannel) so this only ever surfaces the
    // title for the channel actually being listened to - without this
    // filter, an always-on channel (e.g. radio1965's ezstream filler,
    // whose event stays status="new" indefinitely) would permanently win
    // this lookup and its title would keep showing even after switching to
    // a completely different, silent channel.
    Q_INVOKABLE QVariantMap findLiveStream(const QString &url) const;

    // The "shelved" subset as plain QVariantMaps (same field names as
    // roleNames(), e.g. "eventType" not "type") - lets CollectionPage.qml
    // group/sort/search over the full set in plain JS
    // (project-description.md #2.1), which plain QAbstractListModel role
    // access from QML doesn't support without per-role data() calls. Same
    // shape/spirit as findLiveStream() above, just for the whole subset.
    Q_INVOKABLE QVariantList shelvedEvents() const;

    // Singleton-style accessor so the Android JNI callback (which runs outside
    // of any QML context) can reach the instance created in main.cpp.
    static NotificationManager *instance();

signals:
    // Emitted by addMessage(). Main.qml connects this to
    // eventsApiClient.fetchEvents() - handled in QML rather than here since
    // the server base URL lives in QML's Settings, not in C++.
    void refreshRequested();

private:
    int indexOfId(const QString &id) const;

    QVector<EventItem> m_events;
    static NotificationManager *s_instance;
};
