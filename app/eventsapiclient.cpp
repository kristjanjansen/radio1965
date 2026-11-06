#include "eventsapiclient.h"

#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSslError>
#include <QUrl>

EventsApiClient::EventsApiClient(QObject *parent)
    : QObject(parent)
{
}

void EventsApiClient::fetchEvents(const QString &baseUrl)
{
    QNetworkRequest request(QUrl(baseUrl + "/events"));
    //qDebug() << "EventsApiClient: requesting" << request.url();

    QNetworkReply *reply = m_networkManager.get(request);
    //qDebug() << "EventsApiClient: reply created" << reply << "isRunning:" << reply->isRunning();

    connect(reply, &QNetworkReply::errorOccurred, this, [](QNetworkReply::NetworkError err) {
        qDebug() << "EventsApiClient: errorOccurred" << err;
    });
    connect(reply, &QNetworkReply::sslErrors, this, [](const QList<QSslError> &errors) {
        qDebug() << "EventsApiClient: sslErrors" << errors;
    });

    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        //qDebug() << "EventsApiClient: finished signal received, error=" << reply->error();
        reply->deleteLater();

        if (reply->error() != QNetworkReply::NoError) {
            emit fetchFailed(reply->errorString());
            return;
        }

        const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        const QJsonArray events = doc.object().value("events").toArray();
        emit eventsReceived(events);
    });
}

void EventsApiClient::fetchArticle(const QString &baseUrl, int articleId)
{
    QNetworkRequest request(QUrl(baseUrl + "/articles/" + QString::number(articleId)));

    QNetworkReply *reply = m_networkManager.get(request);

    connect(reply, &QNetworkReply::errorOccurred, this, [](QNetworkReply::NetworkError err) {
        qDebug() << "EventsApiClient: fetchArticle errorOccurred" << err;
    });
    connect(reply, &QNetworkReply::sslErrors, this, [](const QList<QSslError> &errors) {
        qDebug() << "EventsApiClient: fetchArticle sslErrors" << errors;
    });

    connect(reply, &QNetworkReply::finished, this, [this, reply, articleId]() {
        reply->deleteLater();

        if (reply->error() != QNetworkReply::NoError) {
            emit articleFetchFailed(articleId, reply->errorString());
            return;
        }

        const QJsonObject obj = QJsonDocument::fromJson(reply->readAll()).object();
        emit articleReceived(articleId,
                              obj.value("title").toString(),
                              obj.value("html").toString(),
                              obj.value("base_url").toString());
    });
}
