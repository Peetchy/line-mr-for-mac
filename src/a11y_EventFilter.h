// Application-wide event filter that keeps LINE's accessibility pipeline alive.

#pragma once

#include <QtCore/QObject>
#include <QtCore/QPointer>
#include <QtCore/QString>

QT_BEGIN_NAMESPACE
class QTimer;
class QWidget;
QT_END_NAMESPACE

namespace line_a11y {

// Re-installs Qt's default update handler (undoing LcApplication's no-op handler) and marks
// accessibility active. Logs whenever a foreign handler had to be removed.
void enforceAccessibilityHandler(const char *reason);

// Asks VoiceOver to speak `text` (no-op when VoiceOver is off or text is empty).
void postAnnouncement(const QString &text);

class A11yEventFilter : public QObject
{
public:
    explicit A11yEventFilter(QObject *parent = nullptr);

    bool eventFilter(QObject *watched, QEvent *event) override;

    // Called by the watchdog timer: re-enforces the handler, keeps the bridge factory first in
    // Qt's factory list and labels inputs in every visible top-level window.
    void watchdogTick();

    void startWatchdog(int intervalMs);

private:
    void handleShow(QWidget *w);
    void handleFocusIn(QWidget *w);
    void scheduleSelectionScan(QWidget *origin);
    void scanForSelection(QWidget *scope);
    void announceDelegate(QWidget *delegate);
    void labelInputsIn(QWidget *root);

    QTimer *m_watchdog = nullptr;
    QPointer<QWidget> m_lastAnnounced;
    QString m_lastAnnouncement;
    bool m_scanPending = false;
    quint64 m_ticks = 0;
};

} // namespace line_a11y
