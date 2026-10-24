// Application-wide event filter that keeps LINE's accessibility pipeline alive and makes LINE
// usable from the keyboard (ported from the Windows bridge, line-mr-for-win).

#pragma once

#include <QtCore/QElapsedTimer>
#include <QtCore/QObject>
#include <QtCore/QPointer>
#include <QtCore/QString>
#include <QtWidgets/QWidget>

#include <functional>

#include "a11y_announce.h"

QT_BEGIN_NAMESPACE
class QKeyEvent;
class QTimer;
QT_END_NAMESPACE

namespace line_a11y {

// Re-installs the bridge's update handler (undoing LcApplication's no-op handler) and marks
// accessibility active. Logs whenever a foreign handler had to be removed.
void enforceAccessibilityHandler(const char *reason);

// The user moved focus or pressed a control through VoiceOver: stop sending focus back to a list
// LINE pulled it away from.
void endListBrowsing();

// Is the user browsing `list` (focus there, or briefly pulled into the open chat by LINE)?
bool isBrowsingList(const QWidget *list);

// A control was pressed (keyboard or VoiceOver): a panel it opens gets focus.
void notePress(QWidget *pressed);

// A context menu item was pressed by the bridge (`how`: the signal emitted, or "click"): a window
// it opens (confirmation dialogs) gets activated instead of focus going back behind the menu.
void noteMenuPress(QWidget *item, const char *how);

// The bridge right-clicks a message (LineAccessibleList::openRowMenu): if the next context menu
// LINE shows within 1.5 s is the chat background's (Select all / Set wallpaper), it is closed and
// `retry` runs (a click on another part of the message). A null `retry` keeps any menu.
void setMenuRetry(std::function<void()> retry);

// How many context menus LINE has shown so far.
int contextMenusShown();

class A11yEventFilter : public QObject
{
public:
    explicit A11yEventFilter(QObject *parent = nullptr);

    bool eventFilter(QObject *watched, QEvent *event) override;

    // Called by the watchdog timer: re-enforces the handler, stays LINE's first application event
    // filter, keeps the bridge factory last in Qt's factory list, labels inputs and makes LINE's
    // controls reachable with Tab in every visible top-level window.
    void watchdogTick();

    void startWatchdog(int intervalMs);

    void endBrowsing() { m_browsingList = nullptr; }
    bool browsing(const QWidget *list) const;
    // LINE is pulling focus into the open chat while the user browses a list (the bridge sends it
    // back right away): such focus changes are not reported.
    bool suppressFocusOn(const QWidget *w) const;

private:
    bool handleKeyPress(QWidget *w, QKeyEvent *key);
    // Option+Command commands (the Windows add-on's Alt keys). True if `key` was one.
    bool handleCommandKey(QWidget *w, QKeyEvent *key);
    bool handleMenuKey(QWidget *menu, const QKeyEvent *key);
    void handleShow(QWidget *w);
    void handleFocusIn(QWidget *w, Qt::FocusReason reason);
    void handleWindowActivate(QWidget *w);
    void menuShown(QWidget *menu);
    void menuHidden();
    void scheduleSelectionScan(QWidget *origin);
    void scanForSelection(QWidget *scope);
    void announceDelegate(QWidget *delegate);
    void labelInputsIn(QWidget *root);
    void updateTabFocusBehavior();

    QTimer *m_watchdog = nullptr;
    QPointer<QWidget> m_lastAnnounced;
    QString m_lastAnnouncement;
    bool m_scanPending = false;
    quint64 m_ticks = 0;
    QPointer<QWidget> m_browsingList;
    QElapsedTimer m_listKeyTimer;
    // When the menu key opened a row's menu (a keyboard context menu event may follow).
    QElapsedTimer m_cursorMenuKey;
    QPointer<QWidget> m_menu;
    QPointer<QWidget> m_menuReturnFocus;
    int m_systemTabBehavior = -1; // Qt::TabFocusBehavior before the bridge changed it
};

} // namespace line_a11y
