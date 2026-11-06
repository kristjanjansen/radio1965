#pragma once

#include <QAudioFormat>
#include <QByteArray>
#include <QElapsedTimer>
#include <QNetworkAccessManager>
#include <QObject>
#include <QStringList>
#include <QTimer>
#include <QVariantList>

struct lame_global_struct;
typedef struct lame_global_struct lame_global_flags;

class QAudioSource;
class QIODevice;
class QNetworkReply;
class QTcpSocket;

// Captures microphone audio and streams it to v2in's harbor
// (https://v2in.stream, port 8005), the Icecast source protocol:
// QAudioSource -> libmp3lame -> a hand-rolled Icecast HTTP-source client
// over QTcpSocket. The password is the broadcaster's key: a contributor's
// or manager's access_token from this app's login, or the temporary
// contributor password; a pool (e.g. "community") is first claimed over
// v2in's API, which answers with the pool channel to connect to. v2in
// checks the key with this app's server. Built on Desktop
// and Android (see app/CMakeLists.txt's RADIO65_ENABLE_BROADCAST gate,
// which cross-compiles libmp3lame via the NDK on Android) - registered as
// QML context property "icecastBroadcaster" only when that macro is
// defined, so BroadcastPage.qml checks `typeof icecastBroadcaster !==
// "undefined"` rather than relying on a separate platform flag.
class IcecastBroadcaster : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool broadcasting READ isBroadcasting NOTIFY broadcastStateChanged)
    Q_PROPERTY(bool onAir READ isOnAir NOTIFY onAirChanged)
    Q_PROPERTY(int elapsedSeconds READ elapsedSeconds NOTIFY elapsedSecondsChanged)
    // Peak of the most recently captured PCM buffer, post-gain, normalized
    // to [0, 1] - drives BroadcastPage.qml's input level meter. Only ever
    // updates while m_audioSource is actually running (i.e. while
    // broadcasting), since mic capture is tied to startBroadcast().
    Q_PROPERTY(qreal inputLevel READ inputLevel NOTIFY inputLevelChanged)
    // Linear multiplier applied to captured samples before MP3 encoding, so
    // BroadcastPage.qml's gain slider affects the actual streamed signal
    // (and the meter above, which reads post-gain samples) rather than
    // just a UI-only value. 1.0 = unity, clamped to [0, 4] in setGain().
    Q_PROPERTY(qreal gain READ gain WRITE setGain NOTIFY gainChanged)
    // When v2in ends this session (ms since the epoch), 0 for no limit -
    // from the pool claim's "until" (a temporary contributor's 3 minutes); the server
    // enforces it, this is only for showing the time left.
    Q_PROPERTY(qint64 until READ until NOTIFY untilChanged)

public:
    explicit IcecastBroadcaster(QObject *parent = nullptr);
    ~IcecastBroadcaster() override;

    bool isBroadcasting() const { return m_broadcasting; }
    bool isOnAir() const { return m_onAir; }
    int elapsedSeconds() const;
    qreal inputLevel() const { return m_inputLevel; }
    qreal gain() const { return m_gain; }
    void setGain(qreal gain);
    qint64 until() const { return m_until; }

    // target: a main channel of v2in (e.g. "live", the mount the key is
    // sent to) or, with pool set, a pool (e.g. "community"): then
    // POST /api/live/claim { pool, key, keep } first, and the channel it
    // answers with is the mount, held for this key 60 s. A refusal (the
    // claim's, or the harbor's, asked again at /api/live/check for its
    // reason) comes back as refused(). key: the access_token, or the
    // temporary contributor password; it goes only as the harbor password,
    // never into a header Icecast publishes.
    // name/description become the ice-name/ice-description headers.
    // sendNotification/saveStream: both forwarded packed into the
    // ice-audio-info header as "send_notification=<0|1>;save_stream=<0|1>",
    // which v2in reads as the source connects (save_stream keeps the
    // session's recording); saveStream is also the claim's keep.
    Q_INVOKABLE void startBroadcast(const QString &target, bool pool, const QString &key, const QString &name, const QString &description, bool sendNotification, bool saveStream);
    Q_INVOKABLE void stopBroadcast();

    // Queries v2in's GET /api/now and reports which channels have someone
    // live (main channels and pool channels) via occupiedChannelsChanged().
    // Best-effort: a network failure reports an empty list rather than
    // raising broadcastError, since occupancy is advisory (disables
    // channel choices in the UI), not a hard gate on broadcasting.
    Q_INVOKABLE void refreshOccupiedChannels();

    // Where this key may go live, as v2in says: POST /api/live/check
    // { key } with no channel or pool answers may: [{ id, name, pool }],
    // reported via destinationsChanged(). The app names no destination.
    Q_INVOKABLE void refreshDestinations(const QString &key);

signals:
    void broadcastStateChanged();
    void onAirChanged();
    void elapsedSecondsChanged();
    void broadcastError(const QString &message);
    void occupiedChannelsChanged(const QStringList &occupied);
    void inputLevelChanged();
    void gainChanged();
    void untilChanged();
    // v2in said no: reason as the server words it ("unknown key", "pool
    // full", "cooldown", ...), next when it may work (ISO time, or empty),
    // target the channel or pool asked for. BroadcastPage.qml words it.
    void refused(const QString &reason, const QString &next, const QString &target);
    // may: refreshDestinations()'s answer, each { id, name, pool }; empty
    // with reason when v2in refuses the key ("unknown key", "banned", ...)
    // or "no answer" when v2in could not be reached.
    void destinationsChanged(const QVariantList &may, const QString &reason);

private slots:
    void onSocketConnected();
    void onSocketReadyRead();
    void onSocketErrorOccurred();
    void onSocketDisconnected();
    void onAudioReadyRead();
    void onElapsedTick();
    void onStatusJsonReply();
    void onClaimReply();
    void onCheckReply();
    void onMayReply();

private:
    // startBroadcast() once the microphone may be used: the claim, or the
    // stream straight away.
    void goLive(const QString &target, bool pool, const QString &key, const QString &name, const QString &description, bool sendNotification, bool saveStream);
    void openStream(const QString &channel);
    void sendIcecastHandshake();
    void closedByServer();
    void askWhy();
    void encodeAndSend(const QByteArray &pcm);
    void teardown();

    QTcpSocket *m_socket = nullptr;
    QAudioSource *m_audioSource = nullptr;
    QIODevice *m_audioDevice = nullptr;
    QNetworkAccessManager m_statusNam;
    // The claim or check in flight, aborted by teardown()/a new start.
    QNetworkReply *m_apiReply = nullptr;
    // refreshDestinations()'s check in flight; a newer one replaces it.
    QNetworkReply *m_mayReply = nullptr;

    // This session, kept from startBroadcast() for the claim's answer and
    // the handshake: m_channel is the mount (the pool's pick for a pool).
    QString m_target;
    bool m_pool = false;
    QString m_key;
    QString m_name;
    QString m_description;
    bool m_sendNotification = false;
    bool m_saveStream = false;
    QString m_channel;
    qint64 m_until = 0;

    lame_global_flags *m_lame = nullptr;

    bool m_broadcasting = false;
    bool m_onAir = false;
    bool m_handshakeAccepted = false;
    qreal m_inputLevel = 0.0;
    qreal m_gain = 1.0;
    QByteArray m_httpResponseBuffer;
    // MP3 bytes encoded before the handshake response arrives - flushed to
    // the socket once accepted, never written mid-handshake.
    QByteArray m_pendingBody;

    QElapsedTimer m_elapsed;
    QTimer m_elapsedTicker;
};
