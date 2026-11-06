#pragma once

#include <QObject>
#include <QTimer>
#include <QStringList>

// RADIO65_LAYOUT_PREVIEW stand-in for IcecastBroadcaster: same QML-facing
// surface (properties/signals/invokables BroadcastPage.qml uses), but no
// mic, lame or network - so the broadcast screen can be styled/tested.
class FakeIcecastBroadcaster : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool broadcasting READ isBroadcasting NOTIFY broadcastStateChanged)
    Q_PROPERTY(bool onAir READ isOnAir NOTIFY onAirChanged)
    Q_PROPERTY(int elapsedSeconds READ elapsedSeconds NOTIFY elapsedSecondsChanged)
    Q_PROPERTY(qreal inputLevel READ inputLevel NOTIFY inputLevelChanged)
    Q_PROPERTY(qreal gain READ gain WRITE setGain NOTIFY gainChanged)
    Q_PROPERTY(qint64 until READ until NOTIFY untilChanged)

public:
    explicit FakeIcecastBroadcaster(QObject *parent = nullptr);

    bool isBroadcasting() const { return m_broadcasting; }
    bool isOnAir() const { return m_broadcasting; }
    int elapsedSeconds() const { return m_elapsed; }
    qreal inputLevel() const { return 0.4; }
    qreal gain() const { return m_gain; }
    void setGain(qreal gain);
    qint64 until() const { return 0; }

    Q_INVOKABLE void startBroadcast(const QString &target, bool pool, const QString &key, const QString &name, const QString &description, bool sendNotification, bool saveStream);
    Q_INVOKABLE void stopBroadcast();
    Q_INVOKABLE void refreshOccupiedChannels();

signals:
    void broadcastStateChanged();
    void onAirChanged();
    void elapsedSecondsChanged();
    void broadcastError(const QString &message);
    void occupiedChannelsChanged(const QStringList &occupied);
    void inputLevelChanged();
    void gainChanged();
    void untilChanged();
    void refused(const QString &reason, const QString &next, const QString &target);

private:
    QTimer m_timer;
    bool m_broadcasting = false;
    int m_elapsed = 0;
    qreal m_gain = 1.0;
};
