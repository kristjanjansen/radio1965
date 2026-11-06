#include "notificationmanager.h"

#include <QJsonArray>
#include <QSet>

NotificationManager *NotificationManager::s_instance = nullptr;

namespace {

EventItem eventItemFromJson(const QJsonObject &event)
{
    EventItem item;
    item.id = event.value("id").toString();
    item.type = event.value("type").toString();
    item.title = event.value("title").toString();
    item.summary = event.value("summary").toString();
    item.url = event.value("url").toString();
    item.publishAt = event.value("publish_at").toString();
    item.shelfAt = event.value("shelf_at").toString();
    item.status = event.value("status").toString();
    item.authorName = event.value("author_name").toString();

    for (const QJsonValue &tag : event.value("tags").toArray())
        item.tags.append(tag.toString());

    item.payload = event.value("payload").toObject().toVariantMap();

    return item;
}

} // namespace

NotificationManager::NotificationManager(QObject *parent)
    : QAbstractListModel(parent)
{
    s_instance = this;
}

NotificationManager *NotificationManager::instance()
{
    return s_instance;
}

int NotificationManager::rowCount(const QModelIndex &parent) const
{
    if (parent.isValid())
        return 0;
    return m_events.size();
}

QVariant NotificationManager::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_events.size())
        return {};

    const EventItem &event = m_events.at(index.row());
    switch (role) {
    case IdRole:
        return event.id;
    case TypeRole:
        return event.type;
    case TitleRole:
        return event.title;
    case SummaryRole:
        return event.summary;
    case UrlRole:
        return event.url;
    case PublishAtRole:
        return event.publishAt;
    case ShelfAtRole:
        return event.shelfAt;
    case StatusRole:
        return event.status;
    case TagsRole:
        return event.tags;
    case PayloadRole:
        return event.payload;
    case AuthorNameRole:
        return event.authorName;
    default:
        return {};
    }
}

QHash<int, QByteArray> NotificationManager::roleNames() const
{
    // Role names match EventDelegate's required property names exactly
    // (eventId/eventType, not id/type - "id" is a reserved QML property
    // name) so QQmlDelegateModel auto-populates the delegate's required
    // properties directly from role data at construction time, instead of
    // going through an explicit `model.xxx` binding. That binding style is
    // what caused ListView delegates to intermittently see `model` as
    // undefined when several rows were inserted in one batch.
    return {
        { IdRole, "eventId" },
        { TypeRole, "eventType" },
        { TitleRole, "title" },
        { SummaryRole, "summary" },
        { UrlRole, "url" },
        { PublishAtRole, "publishAt" },
        { ShelfAtRole, "shelfAt" },
        { StatusRole, "status" },
        { TagsRole, "tags" },
        { PayloadRole, "payload" },
        { AuthorNameRole, "authorName" }
    };
}

int NotificationManager::indexOfId(const QString &id) const
{
    for (int i = 0; i < m_events.size(); ++i) {
        if (m_events.at(i).id == id)
            return i;
    }
    return -1;
}

void NotificationManager::upsertEvents(const QJsonArray &events, const QString &source)
{
    const bool fromV2in = source == QStringLiteral("v2in");
    const auto ours = [fromV2in](const QString &id) { return id.startsWith(QStringLiteral("v2in_")) == fromV2in; };
    QSet<QString> seenIds;
    QVector<EventItem> newItems;

    for (const QJsonValue &value : events) {
        const EventItem item = eventItemFromJson(value.toObject());
        if (item.id.isEmpty())
            continue;
        seenIds.insert(item.id);

        const int existingRow = indexOfId(item.id);
        if (existingRow >= 0) {
            m_events[existingRow] = item;
            const QModelIndex changed = index(existingRow);
            emit dataChanged(changed, changed);
        } else {
            newItems.append(item);
        }
    }

    if (!newItems.isEmpty()) {
        beginInsertRows(QModelIndex(), 0, newItems.size() - 1);
        for (const EventItem &item : newItems)
            m_events.prepend(item);
        endInsertRows();
    }

    // Prune rows of this source that no longer come back from it (e.g. deleted
    // from the DB) - GET /events is the source of truth on every fetch
    // (launch, manual refresh, push-triggered refresh), so anything absent
    // from a fresh response shouldn't linger locally. Doing this as part of
    // a successful fetch response, rather than clearing the model up front
    // before the request, means a failed/offline fetch leaves the existing
    // list alone instead of blanking it.
    for (int i = m_events.size() - 1; i >= 0; --i) {
        if (ours(m_events.at(i).id) && !seenIds.contains(m_events.at(i).id)) {
            beginRemoveRows(QModelIndex(), i, i);
            m_events.removeAt(i);
            endRemoveRows();
        }
    }
}

void NotificationManager::addMessage(const QString &, const QString &, const QString &)
{
    emit refreshRequested();
}

QVariantMap NotificationManager::findLiveStream(const QString &url) const
{
    for (const EventItem &item : m_events) {
        if (item.type == QStringLiteral("livestream") && item.status == QStringLiteral("new")
            && item.url == url)
            return { { "title", item.title }, { "summary", item.summary } };
    }
    return {};
}

namespace {

QVariantMap eventItemToMap(const EventItem &item)
{
    // Keys match roleNames() exactly (eventId/eventType, not id/type) so
    // CollectionPage.qml/Shelf.qml/Box.qml bindings read the same field
    // names regardless of whether an event came from this list or from a
    // ListView delegate's auto-populated role properties.
    QVariantList tags;
    for (const QString &tag : item.tags)
        tags.append(tag);

    return {
        { "eventId", item.id },
        { "eventType", item.type },
        { "title", item.title },
        { "summary", item.summary },
        { "url", item.url },
        { "publishAt", item.publishAt },
        { "shelfAt", item.shelfAt },
        { "status", item.status },
        { "tags", tags },
        { "payload", item.payload },
        { "authorName", item.authorName }
    };
}

} // namespace

QVariantList NotificationManager::shelvedEvents() const
{
    QVariantList result;
    for (const EventItem &item : m_events) {
        if (item.status == QStringLiteral("shelved"))
            result.append(eventItemToMap(item));
    }
    return result;
}
