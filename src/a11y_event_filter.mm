#include "a11y_EventFilter.h"

#include "a11y_diagnostics.h"
#include "a11y_log.h"
#include "a11y_update_filter.h"
#include "accessible_list.h"
#include "accessible_widgets.h"
#include "line_introspect.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QElapsedTimer>
#include <QtCore/QEvent>
#include <QtCore/QTimer>
#include <QtGui/QAccessible>
#include <QtGui/QKeyEvent>
#include <QtWidgets/QAbstractItemView>
#include <QtWidgets/QApplication>
#include <QtWidgets/QLineEdit>
#include <QtWidgets/QTextEdit>
#include <QtWidgets/QWidget>

#import <AppKit/AppKit.h>

namespace line_a11y {
namespace {

bool isNavigationKey(int key)
{
    switch (key) {
    case Qt::Key_Up:
    case Qt::Key_Down:
    case Qt::Key_Left:
    case Qt::Key_Right:
    case Qt::Key_PageUp:
    case Qt::Key_PageDown:
    case Qt::Key_Home:
    case Qt::Key_End:
    case Qt::Key_Tab:
    case Qt::Key_Backtab:
        return true;
    default:
        return false;
    }
}

QWidget *delegateAncestorOrSelf(QWidget *w)
{
    for (QWidget *p = w; p; p = p->parentWidget()) {
        if (classifyWidget(p) == WidgetKind::Delegate)
            return p;
        if (p->isWindow())
            break;
    }
    return nullptr;
}

bool delegateIsSelected(const QWidget *w)
{
    for (const char *name : { "selected", "isSelected", "current", "isCurrent", "highlighted" }) {
        const QVariant v = w->property(name);
        if (v.isValid() && v.metaType().id() == QMetaType::Bool)
            return v.toBool();
    }
    return false;
}

bool voiceOverRunning()
{
    @autoreleasepool {
        return [[NSWorkspace sharedWorkspace] isVoiceOverEnabled];
    }
}

// LINE's hover tooltips (LcToolTip) are separate native windows. With VoiceOver the mouse follows
// the VoiceOver cursor, so a tooltip keeps popping up over the button being read and VoiceOver
// announces every new window. The tooltip text is already the button's accessible help.
void suppressToolTipWindow(QWidget *w)
{
    constexpr const char *kHiddenByBridge = "_lineA11yHiddenToolTip";
    if (!w->isWindow() || w->windowType() != Qt::ToolTip)
        return;
    const bool hidden = w->property(kHiddenByBridge).toBool();
    if (!voiceOverRunning()) {
        if (hidden) { // VoiceOver was turned off: show tooltips normally again
            w->setAttribute(Qt::WA_DontShowOnScreen, false);
            w->setProperty(kHiddenByBridge, false);
        }
        return;
    }
    if (hidden || w->testAttribute(Qt::WA_DontShowOnScreen))
        return;
    // QShowEvent is delivered before the native window is shown, so this keeps it off screen.
    w->setAttribute(Qt::WA_DontShowOnScreen, true);
    w->setProperty(kHiddenByBridge, true);
    static bool logged = false;
    if (!logged) {
        logged = true;
        a11yLog("[tooltip] keeping %s windows off screen while VoiceOver runs", w->metaObject()->className());
    }
}

void postFocus(QWidget *w)
{
    QAccessibleEvent event(w, QAccessible::Focus);
    QAccessible::updateAccessibility(&event);
}

} // namespace

void enforceAccessibilityHandler(const char *reason)
{
    const QAccessible::UpdateHandler ours = bridgeUpdateHandler();
    const QAccessible::UpdateHandler previous = QAccessible::installUpdateHandler(ours);
    if (previous && previous != ours)
        a11yLog("[handler] removed foreign QAccessible update handler %p (%s)",
                reinterpret_cast<void *>(previous), reason);
    QAccessible::setActive(true);
}

A11yEventFilter::A11yEventFilter(QObject *parent)
    : QObject(parent)
{
}

void A11yEventFilter::startWatchdog(int intervalMs)
{
    if (!m_watchdog) {
        m_watchdog = new QTimer(this);
        QObject::connect(m_watchdog, &QTimer::timeout, this, [this] { watchdogTick(); });
    }
    m_watchdog->start(intervalMs);
}

void A11yEventFilter::watchdogTick()
{
    ++m_ticks;
    enforceAccessibilityHandler("watchdog");

    // Keep the bridge factory at the end of Qt's list (factories are consulted last-first).
    QAccessible::removeFactory(lineAccessibleFactory);
    QAccessible::installFactory(lineAccessibleFactory);

    for (QWidget *top : QApplication::topLevelWidgets()) {
        if (top->isVisible())
            labelInputsIn(top);
    }
    pollDumpRequest();
    if (m_ticks % 10 == 0)
        logUpdateStatistics();
    if (m_ticks == 1 || m_ticks % 600 == 0)
        a11yLog("[watchdog] tick %llu, accessibility active=%d, VoiceOver=%d",
                static_cast<unsigned long long>(m_ticks), QAccessible::isActive() ? 1 : 0,
                voiceOverRunning() ? 1 : 0);
}

void A11yEventFilter::labelInputsIn(QWidget *root)
{
    if (isLineInputWidget(root))
        ensureInputLabel(root);
    for (QLineEdit *le : root->findChildren<QLineEdit *>())
        ensureInputLabel(le);
    for (QTextEdit *te : root->findChildren<QTextEdit *>())
        ensureInputLabel(te);
}

bool A11yEventFilter::eventFilter(QObject *watched, QEvent *event)
{
    switch (event->type()) {
    case QEvent::KeyPress:
    case QEvent::MouseButtonPress:
    case QEvent::Wheel:
        if (event->spontaneous())
            markUserActivity();
        break;
    default:
        break;
    }
    switch (event->type()) {
    case QEvent::WindowActivate:
        enforceAccessibilityHandler("WindowActivate");
        if (watched->isWidgetType())
            labelInputsIn(static_cast<QWidget *>(watched)->window());
        break;
    case QEvent::Polish:
        if (watched->isWidgetType())
            repairCachedInterface(static_cast<QWidget *>(watched));
        break;
    case QEvent::Show:
        if (watched->isWidgetType())
            handleShow(static_cast<QWidget *>(watched));
        break;
    case QEvent::FocusIn:
        enforceAccessibilityHandler("FocusIn");
        if (watched->isWidgetType())
            handleFocusIn(static_cast<QWidget *>(watched));
        break;
    case QEvent::MouseButtonRelease:
        if (watched->isWidgetType()) {
            if (QWidget *delegate = delegateAncestorOrSelf(static_cast<QWidget *>(watched))) {
                QPointer<QWidget> guard(delegate);
                QTimer::singleShot(0, this, [this, guard] {
                    if (guard && guard->isVisible()) {
                        postFocus(guard);
                        announceDelegate(guard);
                    }
                });
            }
        }
        break;
    case QEvent::KeyPress:
        if (watched->isWidgetType() && isNavigationKey(static_cast<QKeyEvent *>(event)->key()))
            scheduleSelectionScan(static_cast<QWidget *>(watched));
        break;
    default:
        break;
    }
    return QObject::eventFilter(watched, event);
}

void A11yEventFilter::handleShow(QWidget *w)
{
    suppressToolTipWindow(w);
    if (w->isWindow())
        enforceAccessibilityHandler("Show");
    repairCachedInterface(w);
    // Start capturing row texts before VoiceOver first asks for them.
    if (isLineListView(w))
        ListRowTextCache::forView(static_cast<QAbstractItemView *>(w));
    if (isLineInputWidget(w))
        ensureInputLabel(w);
    else if (w->isWindow())
        labelInputsIn(w);
}

void A11yEventFilter::handleFocusIn(QWidget *w)
{
    if (isLineInputWidget(w))
        ensureInputLabel(w);
    // Qt only emits Focus for widgets while accessibility is active; LINE's custom widgets
    // also need it after the update handler has been restored.
    if (inheritsClass(w, "LcWidget") && !qobject_cast<QLineEdit *>(w) && !qobject_cast<QTextEdit *>(w))
        postFocus(w);
}

void A11yEventFilter::scheduleSelectionScan(QWidget *origin)
{
    if (m_scanPending)
        return;
    m_scanPending = true;
    QPointer<QWidget> guard(origin);
    // Let LINE process the key first so the new selection is in place.
    QTimer::singleShot(30, this, [this, guard] {
        m_scanPending = false;
        if (guard)
            scanForSelection(guard);
    });
}

void A11yEventFilter::scanForSelection(QWidget *scope)
{
    // Search the nearest list/scroll container around the widget that received the key.
    QWidget *container = scope;
    for (QWidget *p = scope; p; p = p->parentWidget()) {
        if (inheritsAnyClass(p, { "LcListView", "LcTableView", "LcAbstractScrollWidget", "LcScrollArea" })) {
            container = p;
            break;
        }
        if (p->isWindow())
            break;
    }

    QList<QWidget *> candidates;
    if (classifyWidget(container) == WidgetKind::Delegate)
        candidates << container;
    for (QWidget *child : container->findChildren<QWidget *>()) {
        if (classifyWidget(child) == WidgetKind::Delegate)
            candidates << child;
    }
    for (QWidget *delegate : candidates) {
        if (delegate->isVisible() && delegateIsSelected(delegate)) {
            if (delegate != m_lastAnnounced.data()) {
                postFocus(delegate);
                announceDelegate(delegate);
            }
            return;
        }
    }
}

void A11yEventFilter::announceDelegate(QWidget *delegate)
{
    QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(delegate);
    const QString text = iface ? iface->text(QAccessible::Name) : collectVisibleChildTexts(delegate);
    const bool repeated = delegate == m_lastAnnounced.data() && text == m_lastAnnouncement;
    m_lastAnnounced = delegate;
    m_lastAnnouncement = text;
    if (!repeated)
        postAnnouncement(text);
}

void postAnnouncement(const QString &text)
{
    if (text.isEmpty() || !voiceOverRunning())
        return;
    // Never speak about LINE updating itself, and never repeat ourselves.
    static QString lastText;
    static QElapsedTimer lastTime;
    if (!userActedRecently() || (text == lastText && lastTime.isValid() && lastTime.elapsed() < 3000)) {
        noteAnnouncement(text, false);
        return;
    }
    lastText = text;
    lastTime.start();
    noteAnnouncement(text, true);
    @autoreleasepool {
        NSDictionary *info = @{
            NSAccessibilityAnnouncementKey: text.toNSString(),
            NSAccessibilityPriorityKey: @(NSAccessibilityPriorityHigh),
        };
        NSAccessibilityPostNotificationWithUserInfo(NSApp, NSAccessibilityAnnouncementRequestedNotification, info);
    }
}

} // namespace line_a11y
