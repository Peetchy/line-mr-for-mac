#include "a11y_update_filter.h"

#include "a11y_log.h"

#include <QtCore/QElapsedTimer>
#include <QtCore/QHash>
#include <QtCore/QMetaEnum>
#include <QtCore/QString>
#include <QtCore/QStringList>
#include <QtWidgets/QApplication>
#include <QtWidgets/QWidget>
#include <qpa/qplatformaccessibility.h>
#include <qpa/qplatformintegration.h>

#include <algorithm>

// QGuiApplicationPrivate::platform_integration is exported by QtGui but declared only in the
// private qguiapplication_p.h, which drags in most of QtGui's internals.
QT_BEGIN_NAMESPACE
class QGuiApplicationPrivate
{
public:
    Q_DECL_IMPORT static QPlatformIntegration *platform_integration;
};
QT_END_NAMESPACE

namespace line_a11y {
namespace {

struct Statistics {
    QHash<QString, int> forwarded;
    QHash<QString, int> dropped;
    QStringList announcements;
    int announcementsSuppressed = 0;
};

Statistics &stats()
{
    static Statistics s;
    return s;
}

QPlatformAccessibility *platformAccessibility()
{
    QPlatformIntegration *integration = QGuiApplicationPrivate::platform_integration;
    return integration ? integration->accessibility() : nullptr;
}

QString eventKey(QAccessibleEvent *event)
{
    static const QMetaEnum events = QMetaEnum::fromType<QAccessible::Event>();
    const char *type = events.valueToKey(event->type());
    QObject *object = event->object();
    QString cls = object ? QLatin1StringView(object->metaObject()->className()) : QStringLiteral("-");
    if (!object) {
        if (QAccessibleInterface *iface = event->accessibleInterface())
            cls = QStringLiteral("iface:%1").arg(int(iface->role()));
    }
    return QStringLiteral("%1 %2").arg(type ? QLatin1StringView(type) : QLatin1StringView("?"), cls);
}

bool (*g_focusSuppressor)(QObject *) = nullptr;

QElapsedTimer &activityClock()
{
    static QElapsedTimer clock;
    return clock;
}

// Is the event about what the user is on (the focused widget, its ancestors, a focused item)?
bool concernsFocus(QAccessibleEvent *event)
{
    QObject *object = event->object();
    if (object && object->isWidgetType()) {
        auto *w = static_cast<QWidget *>(object);
        if (w->isWindow())
            return true; // window activation / title: VoiceOver relies on these
        QWidget *focus = QApplication::focusWidget();
        return focus && (w == focus || w->isAncestorOf(focus));
    }
    QAccessibleInterface *iface = event->accessibleInterface();
    return iface && iface->state().focused;
}

// Event types the Cocoa bridge turns into VoiceOver-visible notifications about a change.
bool isChangeNotification(QAccessible::Event type)
{
    switch (type) {
    case QAccessible::NameChanged:
    case QAccessible::ValueChanged:
    case QAccessible::StateChanged:
    case QAccessible::TextInserted:
    case QAccessible::TextRemoved:
    case QAccessible::TextUpdated:
    case QAccessible::TextCaretMoved:
    case QAccessible::TextSelectionChanged:
        return true;
    default:
        return false;
    }
}

void handleUpdate(QAccessibleEvent *event)
{
    QPlatformAccessibility *platform = platformAccessibility();
    if (!platform)
        return;
    if (event->type() == QAccessible::Focus && g_focusSuppressor && event->object()
        && g_focusSuppressor(event->object())) {
        stats().dropped[eventKey(event)]++;
        return;
    }
    // LINE constantly updates widgets in the background (unread badges, timestamps, list rows).
    // Only report changes the user is looking at or has just caused.
    if (isChangeNotification(event->type()) && !userActedRecently() && !concernsFocus(event)) {
        stats().dropped[eventKey(event)]++;
        return;
    }
    stats().forwarded[eventKey(event)]++;
    platform->notifyAccessibilityUpdate(event);
}

QString topEntries(const QHash<QString, int> &counts, int limit)
{
    QList<QPair<int, QString>> sorted;
    for (auto it = counts.cbegin(); it != counts.cend(); ++it)
        sorted.append({ it.value(), it.key() });
    std::sort(sorted.begin(), sorted.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
    QStringList parts;
    for (int i = 0; i < int(sorted.size()) && i < limit; ++i)
        parts << QStringLiteral("%1x %2").arg(sorted[i].first).arg(sorted[i].second);
    return parts.join(QLatin1StringView("; "));
}

} // namespace

void markUserActivity()
{
    activityClock().start();
}

bool userActedRecently(int withinMs)
{
    const QElapsedTimer &clock = activityClock();
    return clock.isValid() && clock.elapsed() <= withinMs;
}

void setFocusSuppressor(bool (*suppress)(QObject *object))
{
    g_focusSuppressor = suppress;
}

QAccessible::UpdateHandler bridgeUpdateHandler()
{
    return platformAccessibility() ? &handleUpdate : nullptr;
}

void noteAnnouncement(const QString &text, bool spoken)
{
    Statistics &s = stats();
    if (!spoken) {
        ++s.announcementsSuppressed;
        return;
    }
    if (s.announcements.size() < 20)
        s.announcements << text.left(60);
}

void logUpdateStatistics()
{
    Statistics &s = stats();
    if (s.forwarded.isEmpty() && s.dropped.isEmpty() && s.announcements.isEmpty() && !s.announcementsSuppressed)
        return;
    int forwarded = 0, dropped = 0;
    for (int n : std::as_const(s.forwarded))
        forwarded += n;
    for (int n : std::as_const(s.dropped))
        dropped += n;
    a11yLog("[events] forwarded %d: %s", forwarded, qPrintable(topEntries(s.forwarded, 8)));
    if (dropped)
        a11yLog("[events] dropped %d: %s", dropped, qPrintable(topEntries(s.dropped, 8)));
    if (!s.announcements.isEmpty() || s.announcementsSuppressed)
        a11yLog("[events] announcements spoken %d (suppressed %d): %s", int(s.announcements.size()),
                s.announcementsSuppressed, qPrintable(s.announcements.join(QLatin1StringView(" | "))));
    s = Statistics();
}

} // namespace line_a11y
