#include "icecastbroadcaster.h"

#include <QAudioSource>
#include <QCoreApplication>
#include <QDateTime>
#include <QIODevice>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QMediaDevices>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QTcpSocket>
#include <QUrl>
#include <QVarLengthArray>
#include <qpermissions.h>

#include <lame/lame.h>

#include <algorithm>
#include <cmath>

#ifdef Q_OS_IOS
#include "iosaudiosession.h"
#endif

namespace {

// v2in's harbor: Liquidsoap taking Icecast sources, mount = channel, user
// "source", password = the stream key. No password lives in the app.
const char *const ICECAST_HOST = "v2in.stream";
const quint16 ICECAST_PORT = 8005;
// v2in's API: /api/live/claim, /api/live/check, /api/now.
const char *const V2IN_API = "https://v2in.stream/api";
const char *const ICE_GENRE = "avant-garde";

constexpr int SAMPLE_RATE = 44100;
constexpr int MP3_BITRATE_KBPS = 128;
// Worst-case buffer size per lame.h: 1.25*num_samples + 7200.
constexpr int MP3_BUF_SIZE = static_cast<int>(1.25 * 8192) + 7200;

} // namespace

IcecastBroadcaster::IcecastBroadcaster(QObject *parent)
    : QObject(parent)
{
    m_elapsedTicker.setInterval(1000);
    connect(&m_elapsedTicker, &QTimer::timeout, this, &IcecastBroadcaster::onElapsedTick);
}

IcecastBroadcaster::~IcecastBroadcaster()
{
    teardown();
}

int IcecastBroadcaster::elapsedSeconds() const
{
    return m_broadcasting ? static_cast<int>(m_elapsed.elapsed() / 1000) : 0;
}

void IcecastBroadcaster::startBroadcast(const QString &target, bool pool, const QString &key, const QString &name, const QString &description, bool sendNotification, bool saveStream)
{
    if (m_broadcasting)
        return;

    // No-op on platforms without a permission backend (e.g. desktop) -
    // checkPermission() returns Granted immediately there. On Android this
    // is required before QAudioSource::start() will produce real audio.
    QMicrophonePermission micPermission;
    switch (qApp->checkPermission(micPermission)) {
    case Qt::PermissionStatus::Granted:
        break;
    case Qt::PermissionStatus::Undetermined:
        qApp->requestPermission(micPermission, this, [this, target, pool, key, name, description, sendNotification, saveStream](const QPermission &permission) {
            if (qApp->checkPermission(permission) == Qt::PermissionStatus::Granted)
                startBroadcast(target, pool, key, name, description, sendNotification, saveStream);
            else
                emit broadcastError(tr("Microphone permission was denied."));
        });
        return;
    case Qt::PermissionStatus::Denied:
        emit broadcastError(tr("Microphone permission was denied. Enable it in system settings."));
        return;
    }

    goLive(target, pool, key, name, description, sendNotification, saveStream);
}

void IcecastBroadcaster::goLive(const QString &target, bool pool, const QString &key, const QString &name, const QString &description, bool sendNotification, bool saveStream)
{
    m_target = target;
    m_pool = pool;
    m_key = key.trimmed();
    m_name = name;
    m_description = description;
    m_sendNotification = sendNotification;
    m_saveStream = saveStream;
    m_channel.clear();

    // broadcasting from here on, so Stop works while the claim is out too
    m_broadcasting = true;
    emit broadcastStateChanged();

    if (!pool) {
        openStream(target);
        return;
    }

    // A pool names no channel: v2in picks a free one and holds it for this
    // key 60 s, which openStream() connects to well within.
    QNetworkRequest request(QUrl(QString::fromLatin1(V2IN_API) + "/live/claim"));
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    const QJsonObject body{{"pool", target}, {"key", m_key}, {"keep", saveStream}};
    m_apiReply = m_statusNam.post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(m_apiReply, &QNetworkReply::finished, this, &IcecastBroadcaster::onClaimReply);
}

void IcecastBroadcaster::onClaimReply()
{
    auto *reply = qobject_cast<QNetworkReply *>(sender());
    if (!reply)
        return;
    reply->deleteLater();
    // stopped meanwhile (teardown() aborts and forgets it) or an older one
    if (reply != m_apiReply)
        return;
    m_apiReply = nullptr;

    const QJsonObject answer = QJsonDocument::fromJson(reply->readAll()).object();
    if (reply->error() != QNetworkReply::NoError && answer.isEmpty()) {
        emit broadcastError(tr("Could not reach v2in: %1").arg(reply->errorString()));
        teardown();
        return;
    }
    if (!answer.value("ok").toBool()) {
        emit refused(answer.value("reason").toString(), answer.value("next").toString(), m_target);
        teardown();
        return;
    }
    const QString until = answer.value("until").toString();
    m_until = until.isEmpty() ? 0 : QDateTime::fromString(until, Qt::ISODateWithMs).toMSecsSinceEpoch();
    emit untilChanged();
    openStream(answer.value("channel").toString());
}

void IcecastBroadcaster::openStream(const QString &channel)
{
    m_channel = channel;

#ifdef Q_OS_IOS
    // Must happen before QAudioSource opens the mic below - otherwise Qt
    // Multimedia's iOS backend switches AVAudioSession to .playAndRecord on
    // its own, which defaults to the quiet earpiece receiver instead of the
    // loudspeaker.
    // Capture at the hardware rate instead of SAMPLE_RATE: when they differ
    // (e.g. iPhone mic at 48 kHz), Qt's iOS input resamples and its buffer
    // size is off by a frame now and then ("expected 2030-byte buffer ...
    // AudioUnitRender failed -50") - each failed render drops a chunk of
    // audio, heard as crackling. LAME is fed the same rate below.
    const double hwRate = iosAudioSessionActivateRecording();
    const int sampleRate = hwRate > 0 ? static_cast<int>(hwRate) : SAMPLE_RATE;
#else
    const int sampleRate = SAMPLE_RATE;
#endif

    QAudioFormat format;
    format.setSampleRate(sampleRate);
    format.setChannelCount(1);
    format.setSampleFormat(QAudioFormat::Int16);

    m_audioSource = new QAudioSource(QMediaDevices::defaultAudioInput(), format, this);
    m_audioDevice = m_audioSource->start();
    if (m_audioDevice)
        connect(m_audioDevice, &QIODevice::readyRead, this, &IcecastBroadcaster::onAudioReadyRead);

    m_lame = lame_init();
    lame_set_in_samplerate(m_lame, sampleRate);
    lame_set_num_channels(m_lame, 1);
    lame_set_brate(m_lame, MP3_BITRATE_KBPS);
    lame_init_params(m_lame);

    m_httpResponseBuffer.clear();
    m_pendingBody.clear();
    m_handshakeAccepted = false;

    m_socket = new QTcpSocket(this);
    connect(m_socket, &QTcpSocket::connected, this, &IcecastBroadcaster::onSocketConnected);
    connect(m_socket, &QTcpSocket::readyRead, this, &IcecastBroadcaster::onSocketReadyRead);
    connect(m_socket, &QTcpSocket::errorOccurred, this, &IcecastBroadcaster::onSocketErrorOccurred);
    connect(m_socket, &QTcpSocket::disconnected, this, &IcecastBroadcaster::onSocketDisconnected);

    m_socket->connectToHost(QString::fromLatin1(ICECAST_HOST), ICECAST_PORT);

    m_elapsed.start();
    m_elapsedTicker.start();
}

void IcecastBroadcaster::sendIcecastHandshake()
{
    // HTTP/1.0, no Content-Length/Transfer-Encoding: Icecast's source-over-
    // PUT protocol treats the connection as a continuous stream once
    // headers end, matching ffmpeg's icecast:// muxer / libshout, and
    // matching Icecast's own "HTTP/1.0 200 OK"-style reply. The key is the
    // password, so it never shows in a header Icecast publishes.
    const QString &channel = m_channel;
    const QByteArray auth = QByteArray("source:") + m_key.toUtf8();
    QByteArray request;
    request += "PUT /" + channel.toUtf8() + " HTTP/1.0\r\n";
    request += "Authorization: Basic " + auth.toBase64() + "\r\n";
    request += "Content-Type: audio/mpeg\r\n";
    // ice-name/ice-description use the legacy ICY/Shoutcast convention of
    // Latin-1 (ISO-8859-1) bytes on the wire, not UTF-8 - Icecast re-serves
    // these as UTF-8 (e.g. via status-json.xsl) by converting from Latin-1,
    // so sending UTF-8 bytes here gets double-encoded into mojibake (e.g.
    // "ü" turning into "Ã¼"). Estonian diacritics (ä/ö/õ/ü) all fall inside
    // Latin-1's range so this covers them; characters outside it (e.g.
    // š/ž) would still come through as '?' - a real limitation of the ICY
    // header protocol itself, not fixable client-side.
    request += "ice-name: " + m_name.toLatin1() + "\r\n";
    request += "ice-description: " + m_description.toLatin1() + "\r\n";
    request += QByteArray("ice-genre: ") + ICE_GENRE + "\r\n";
    // ice-url is formed by the server as host:port/<this value> - pass just
    // the mountpoint (channel), not a separate homepage URL, so listeners
    // land on the stream itself (e.g. http://185.169.69.8:8001/user1).
    request += "ice-url: " + channel.toUtf8() + "\r\n";
    // ice-audio-info repurposed as a carrier for BroadcastPage.qml's "Send
    // notification"/"Save stream" checkboxes - Icecast parses this header's
    // semicolon-separated key=value pairs and hoists any key (not just its
    // own recognized ones like bitrate/samplerate/channels) onto the
    // source; v2in's harbor hands the header to its gate as the source
    // connects, which keeps or deletes the session's recording by
    // save_stream.
    const QByteArray audioInfo = QByteArray("send_notification=") + (m_sendNotification ? "1" : "0")
        + ";save_stream=" + (m_saveStream ? "1" : "0");
    request += "ice-audio-info: " + audioInfo + "\r\n";
    request += "\r\n";
    m_socket->write(request);
}

void IcecastBroadcaster::onSocketConnected()
{
    sendIcecastHandshake();
}

void IcecastBroadcaster::onSocketReadyRead()
{
    if (m_handshakeAccepted) {
        // Icecast source connections don't send anything further after the
        // initial response - just drain to avoid unbounded buffering.
        m_socket->readAll();
        return;
    }

    m_httpResponseBuffer += m_socket->readAll();
    const int lineEnd = m_httpResponseBuffer.indexOf("\r\n");
    if (lineEnd < 0)
        return;

    const QByteArray statusLine = m_httpResponseBuffer.left(lineEnd);
    if (statusLine.contains(" 200")) {
        m_handshakeAccepted = true;
        m_onAir = true;
        emit onAirChanged();
        if (!m_pendingBody.isEmpty()) {
            m_socket->write(m_pendingBody);
            m_pendingBody.clear();
        }
    } else {
        closedByServer();
    }
}

void IcecastBroadcaster::onSocketErrorOccurred()
{
    if (!m_broadcasting)
        return;
    if (m_socket->error() == QAbstractSocket::RemoteHostClosedError) {
        closedByServer();
        return;
    }
    emit broadcastError(m_socket->errorString());
    teardown();
}

void IcecastBroadcaster::onSocketDisconnected()
{
    if (m_broadcasting)
        closedByServer();
}

// The harbor said no (any status but 200) or hung up. Before the handshake
// that is a refusal, whose reason the harbor never says - v2in's
// /api/live/check does. After it, v2in ended the session: its time limit,
// a kick, a restart.
void IcecastBroadcaster::closedByServer()
{
    const bool accepted = m_handshakeAccepted;
    const bool timeIsUp = m_until && QDateTime::currentMSecsSinceEpoch() >= m_until - 5000;
    teardown();
    if (!accepted)
        askWhy();
    else if (timeIsUp)
        emit broadcastError(tr("Time is up: v2in ended the session at its limit."));
    else
        emit broadcastError(tr("v2in closed the connection."));
}

void IcecastBroadcaster::askWhy()
{
    QNetworkRequest request(QUrl(QString::fromLatin1(V2IN_API) + "/live/check"));
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    // a pool channel is asked by its own name, which this key holds
    const QJsonObject body{{"channel", m_channel.isEmpty() ? m_target : m_channel}, {"key", m_key}};
    m_apiReply = m_statusNam.post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
    m_apiReply->setProperty("target", m_target);
    connect(m_apiReply, &QNetworkReply::finished, this, &IcecastBroadcaster::onCheckReply);
}

void IcecastBroadcaster::onCheckReply()
{
    auto *reply = qobject_cast<QNetworkReply *>(sender());
    if (!reply)
        return;
    reply->deleteLater();
    if (reply != m_apiReply)
        return;
    m_apiReply = nullptr;

    const QJsonObject answer = QJsonDocument::fromJson(reply->readAll()).object();
    const QString reason = answer.value("reason").toString();
    if (answer.value("ok").toBool() || reason.isEmpty())
        emit broadcastError(tr("v2in did not take the connection. Try again."));
    else
        emit refused(reason, answer.value("next").toString(), reply->property("target").toString());
}

void IcecastBroadcaster::onAudioReadyRead()
{
    if (!m_audioDevice)
        return;
    const QByteArray pcm = m_audioDevice->readAll();
    if (!pcm.isEmpty())
        encodeAndSend(pcm);
}

void IcecastBroadcaster::setGain(qreal gain)
{
    gain = std::clamp(gain, 0.0, 4.0);
    if (qFuzzyCompare(m_gain, gain))
        return;
    m_gain = gain;
    emit gainChanged();
}

void IcecastBroadcaster::encodeAndSend(const QByteArray &pcm)
{
    if (!m_lame)
        return;

    const auto *rawSamples = reinterpret_cast<const short int *>(pcm.constData());
    const int numSamples = static_cast<int>(pcm.size() / sizeof(short int));
    if (numSamples <= 0)
        return;

    // Gain is applied here, not left to the OS input mixer, so
    // BroadcastPage.qml's gain slider affects the actual encoded/streamed
    // signal - and so the peak meter below (inputLevel) reflects the same
    // post-gain, clipped samples that end up on the wire, not the raw mic
    // level.
    QVarLengthArray<short int, 8192> adjusted(numSamples);
    int peak = 0;
    for (int i = 0; i < numSamples; ++i) {
        const int scaled = static_cast<int>(std::lround(rawSamples[i] * m_gain));
        const int clamped = std::clamp(scaled, -32768, 32767);
        adjusted[i] = static_cast<short int>(clamped);
        peak = std::max(peak, std::abs(clamped));
    }

    const qreal level = std::clamp(peak / 32768.0, 0.0, 1.0);
    if (!qFuzzyCompare(m_inputLevel, level)) {
        m_inputLevel = level;
        emit inputLevelChanged();
    }

    QByteArray mp3Buf(MP3_BUF_SIZE, Qt::Uninitialized);
    // Mono input: LAME's own convention is to pass the same buffer as both
    // the left and right channel argument (see lame.h's lame_encode_buffer
    // docs) rather than a null right-channel pointer.
    const int written = lame_encode_buffer(m_lame, adjusted.constData(), adjusted.constData(), numSamples,
                                            reinterpret_cast<unsigned char *>(mp3Buf.data()), mp3Buf.size());
    if (written <= 0)
        return;

    if (m_handshakeAccepted && m_socket && m_socket->state() == QAbstractSocket::ConnectedState)
        m_socket->write(mp3Buf.constData(), written);
    else
        m_pendingBody += QByteArray(mp3Buf.constData(), written);
}

void IcecastBroadcaster::stopBroadcast()
{
    if (!m_broadcasting)
        return;

    if (m_lame && m_socket && m_handshakeAccepted) {
        QByteArray mp3Buf(MP3_BUF_SIZE, Qt::Uninitialized);
        const int written = lame_encode_flush(m_lame, reinterpret_cast<unsigned char *>(mp3Buf.data()), mp3Buf.size());
        if (written > 0)
            m_socket->write(mp3Buf.constData(), written);
    }

    teardown();
}

void IcecastBroadcaster::teardown()
{
    m_elapsedTicker.stop();

    if (m_apiReply) {
        QNetworkReply *reply = m_apiReply;
        m_apiReply = nullptr;
        reply->abort();
    }

    if (m_audioSource) {
        m_audioSource->stop();
        m_audioSource->deleteLater();
        m_audioSource = nullptr;
    }
    m_audioDevice = nullptr;

#ifdef Q_OS_IOS
    // Mic released - hand AVAudioSession back to .playback so normal
    // listening resumes on the loudspeaker rather than staying on
    // whatever route .playAndRecord left it on.
    iosAudioSessionActivatePlayback();
#endif

    if (m_lame) {
        lame_close(m_lame);
        m_lame = nullptr;
    }

    if (m_socket) {
        // Disconnect signals and clear the member *before* calling
        // disconnectFromHost()/deleteLater(), not after: on a socket that's
        // already in an error state (e.g. connection refused - Icecast
        // unreachable), disconnectFromHost() can synchronously re-emit
        // disconnected() right here, which was direct-connected to
        // onSocketDisconnected() - since m_broadcasting is still true at
        // this point (only cleared later below), that reentrant call would
        // invoke teardown() again *while this call is still paused inside
        // disconnectFromHost()*, nulling m_socket out from under this frame
        // and crashing the very next line (m_socket->deleteLater() on a
        // null m_socket, even though the `if (m_socket)` guard above had
        // already passed). Disconnecting first prevents the reentrancy
        // outright rather than merely surviving it.
        QTcpSocket *socket = m_socket;
        m_socket = nullptr;
        socket->disconnect(this);
        socket->disconnectFromHost();
        socket->deleteLater();
    }

    m_httpResponseBuffer.clear();
    m_pendingBody.clear();

    const bool wasBroadcasting = m_broadcasting;
    const bool wasOnAir = m_onAir;
    m_broadcasting = false;
    m_onAir = false;
    m_handshakeAccepted = false;

    if (m_inputLevel != 0.0) {
        m_inputLevel = 0.0;
        emit inputLevelChanged();
    }

    if (m_until) {
        m_until = 0;
        emit untilChanged();
    }

    if (wasBroadcasting)
        emit broadcastStateChanged();
    if (wasOnAir)
        emit onAirChanged();
}

void IcecastBroadcaster::onElapsedTick()
{
    emit elapsedSecondsChanged();
}

void IcecastBroadcaster::refreshOccupiedChannels()
{
    const QUrl url(QString::fromLatin1(V2IN_API) + "/now");
    QNetworkReply *reply = m_statusNam.get(QNetworkRequest(url));
    connect(reply, &QNetworkReply::finished, this, &IcecastBroadcaster::onStatusJsonReply);
}

void IcecastBroadcaster::onStatusJsonReply()
{
    auto *reply = qobject_cast<QNetworkReply *>(sender());
    if (!reply)
        return;
    reply->deleteLater();

    // GET /api/now: a main channel with someone live has status "live"; a
    // pool lists its live channels under "live" (https://v2in.stream).
    QStringList occupied;
    if (reply->error() == QNetworkReply::NoError) {
        const QJsonObject root = QJsonDocument::fromJson(reply->readAll()).object();
        for (const QJsonValue &channel : root.value("channels").toArray()) {
            if (channel.toObject().value("status").toString() == QStringLiteral("live"))
                occupied << channel.toObject().value("id").toString();
        }
        for (const QJsonValue &pool : root.value("pools").toArray()) {
            for (const QJsonValue &live : pool.toObject().value("live").toArray())
                occupied << live.toObject().value("channel").toString();
        }
    }
    emit occupiedChannelsChanged(occupied);
}
