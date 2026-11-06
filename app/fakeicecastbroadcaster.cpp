#include "fakeicecastbroadcaster.h"

#include <QVariantMap>

FakeIcecastBroadcaster::FakeIcecastBroadcaster(QObject *parent)
    : QObject(parent)
{
    m_timer.setInterval(1000);
    connect(&m_timer, &QTimer::timeout, this, [this]() {
        ++m_elapsed;
        emit elapsedSecondsChanged();
    });
}

void FakeIcecastBroadcaster::setGain(qreal gain)
{
    if (qFuzzyCompare(m_gain, gain))
        return;
    m_gain = gain;
    emit gainChanged();
}

void FakeIcecastBroadcaster::startBroadcast(const QString &, bool, const QString &, const QString &, const QString &, bool, bool)
{
    if (m_broadcasting)
        return;
    m_broadcasting = true;
    m_elapsed = 0;
    m_timer.start();
    emit broadcastStateChanged();
    emit onAirChanged();
    emit elapsedSecondsChanged();
}

void FakeIcecastBroadcaster::stopBroadcast()
{
    if (!m_broadcasting)
        return;
    m_broadcasting = false;
    m_timer.stop();
    m_elapsed = 0;
    emit broadcastStateChanged();
    emit onAirChanged();
    emit elapsedSecondsChanged();
}

void FakeIcecastBroadcaster::refreshOccupiedChannels()
{
    emit occupiedChannelsChanged({});
}

void FakeIcecastBroadcaster::refreshDestinations(const QString &)
{
    emit destinationsChanged({QVariantMap{{"id", "community"}, {"name", "Community"}, {"pool", true}}}, QString());
}
