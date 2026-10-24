#include "a11y_EventFilter.h"

#include "a11y_diagnostics.h"
#include "a11y_log.h"
#include "a11y_update_filter.h"
#include "accessible_list.h"
#include "accessible_quick.h"
#include "accessible_widgets.h"
#include "call_keys.h"
#include "full_text_view.h"
#include "native_buttons.h"
#include "line_introspect.h"
#include "qt_signal_utils.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QElapsedTimer>
#include <QtCore/QEvent>
#include <QtCore/QRegularExpression>
#include <QtCore/QSet>
#include <QtCore/QTimer>
#include <QtCore/QUrl>
#include <QtGui/QAccessible>
#include <QtGui/QContextMenuEvent>
#include <QtGui/QKeyEvent>
#include <QtGui/QStyleHints>
#include <QtGui/QTextBlock>
#include <QtQuick/QQuickWindow>
#include <QtWidgets/QAbstractItemView>
#include <QtWidgets/QApplication>
#include <QtWidgets/QLineEdit>
#include <QtWidgets/QPlainTextEdit>
#include <QtWidgets/QSplitter>
#include <QtWidgets/QTextEdit>
#include <QtWidgets/QWidget>

#include <Carbon/Carbon.h>

#include <algorithm>
#include <memory>

namespace line_a11y {
namespace {

A11yEventFilter *g_filter = nullptr;

// See setMenuRetry(): another try for the menu of a message, for a short while.
std::function<void()> g_menuRetry;
QElapsedTimer g_menuRetrySet;
int g_menusShown = 0;

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

bool isListNavigationKey(int key)
{
    switch (key) {
    case Qt::Key_Up:
    case Qt::Key_Down:
    case Qt::Key_PageUp:
    case Qt::Key_PageDown:
    case Qt::Key_Home:
    case Qt::Key_End:
        return true;
    default:
        return false;
    }
}

// Qt on macOS: Command is ControlModifier, Option is AltModifier, Control is MetaModifier.
constexpr Qt::KeyboardModifiers kAnyModifier = Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier;

bool plainKey(const QKeyEvent *e)
{
    return !(e->modifiers() & (kAnyModifier | Qt::ShiftModifier));
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

// ---- Tab stops ---------------------------------------------------------------------------------
//
// LINE's LcButton / LcCheckBox / clickable LcImage / clickable LcText have Qt::NoFocus; only the text
// fields take Tab. The bridge gives them Qt::TabFocus (clicks still do not move focus), turns Space /
// Return on them into their press action and orders each window's Tab chain like the widget tree,
// with the title bar last.

// Marks widgets whose focus policy the bridge changed (so it only ever touches those).
constexpr const char *kMadeFocusableProperty = "_lineA11yFocusable";

bool wantsKeyboardFocus(QWidget *w)
{
    if (w->isWindow() || w->focusPolicy() != Qt::NoFocus)
        return false;
    if (classifyWidget(w) == WidgetKind::Button || classifyWidget(w) == WidgetKind::List)
        return true;
    if (classifyWidget(w) == WidgetKind::Text) {
        QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(w);
        return iface && iface->role() == QAccessible::Link;
    }
    return false;
}

// The same control twice: LINE nests a button in a button (the chat list's show / hide arrow) or lays
// equal buttons over each other (the chat list's ad). Only the outer / first one becomes a Tab stop.
bool duplicatesTabStop(QWidget *w)
{
    auto nameOf = [](QWidget *o) {
        QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(o);
        return iface ? iface->text(QAccessible::Name) : QString();
    };
    const QString name = nameOf(w);
    if (name.isEmpty())
        return false;
    for (QWidget *p = w->parentWidget(); p && !p->isWindow(); p = p->parentWidget()) {
        if (classifyWidget(p) == WidgetKind::Button && nameOf(p) == name)
            return true;
    }
    QWidget *parent = w->parentWidget();
    if (!parent)
        return false;
    for (QObject *o : parent->children()) {
        if (o == w)
            break;
        auto *sibling = qobject_cast<QWidget *>(o);
        if (sibling && !sibling->isWindow() && sibling->geometry() == w->geometry()
            && (sibling->property(kMadeFocusableProperty).toBool() || wantsKeyboardFocus(sibling))
            && nameOf(sibling) == name)
            return true;
    }
    return false;
}

bool makeFocusable(QWidget *w)
{
    if (w->property(kMadeFocusableProperty).toBool() || !wantsKeyboardFocus(w) || duplicatesTabStop(w))
        return false;
    // TabFocus only: clicking does not move focus, so mouse users see no difference.
    w->setFocusPolicy(Qt::TabFocus);
    w->setProperty(kMadeFocusableProperty, true);
    return true;
}

// `w`'s child widgets in reading order. A splitter's panes are in display order, which is not their
// creation order: the open chat's splitter creates the message input before the message list above it.
QList<QWidget *> childWidgetsInOrder(QWidget *w)
{
    QList<QWidget *> children;
    if (auto *splitter = qobject_cast<QSplitter *>(w)) {
        for (int i = 0; i < splitter->count(); ++i)
            children << splitter->widget(i);
    }
    for (QObject *child : w->children()) {
        if (child->isWidgetType() && !children.contains(static_cast<QWidget *>(child)))
            children << static_cast<QWidget *>(child);
    }
    return children;
}

void collectTabStops(QWidget *w, QList<QWidget *> &content, QList<QWidget *> &titleBar, bool inTitleBar)
{
    inTitleBar = inTitleBar || inheritsClass(w, "LcTitleBar");
    for (QWidget *c : childWidgetsInOrder(w)) {
        if (c->isWindow())
            continue;
        QList<QWidget *> &stops = inTitleBar ? titleBar : content;
        const qsizetype first = stops.size();
        if (c->focusPolicy() & Qt::TabFocus)
            stops << c;
        // A text field's own children (clear / show-password buttons) follow the field.
        collectTabStops(c, content, titleBar, inTitleBar);
        // The message input bar: from the message input (reached from the message list above it)
        // out through its buttons, nearest first (stickers ... attach file).
        if (inheritsClass(c, "MessageInputPanel"))
            std::reverse(stops.begin() + first, stops.end());
        // The open chat's note banner and the buttons over the messages come before the message
        // list, which leads on to the message input.
        if (inheritsClass(c, "ChatMessageView"))
            std::stable_partition(stops.begin() + first, stops.end(), [](QWidget *stop) {
                return !isLineListView(stop) || ancestorInheriting(stop, "LcListView");
            });
        // The chat list panel: its buttons (sort, show / hide, create chat, the ad) first, then the
        // search field and the chat list, which leads on to the open chat.
        if (inheritsClass(c, "MainChatPanel")) {
            auto rank = [](QWidget *stop) {
                if (isLineListView(stop) && !ancestorInheriting(stop, "LcListView"))
                    return 2;
                return inheritsClass(stop, "QLineEdit") || ancestorInheriting(stop, "QLineEdit") ? 1 : 0;
            };
            std::stable_sort(stops.begin() + first, stops.end(),
                             [&rank](QWidget *a, QWidget *b) { return rank(a) < rank(b); });
        }
    }
}

// Qt's focus chain follows widget creation order, which in LINE puts title-bar buttons in the
// middle of a window. Order Tab stops like the widget tree (LINE's panels are built in reading
// order), with the window's title bar last.
void orderTabStops(QWidget *window)
{
    QList<QWidget *> content, titleBar;
    collectTabStops(window, content, titleBar, false);
    // The chat folder tabs (All / Friends / Groups / ...) sit in the title bar but filter the chat
    // list: they go right before the chat list's search field.
    const auto search = std::find_if(content.begin(), content.end(), [](QWidget *stop) {
        return inheritsClass(stop, "QLineEdit") && ancestorInheriting(stop, "MainChatPanel");
    });
    if (search != content.end()) {
        QList<QWidget *> folders;
        titleBar.removeIf([&folders](QWidget *stop) {
            if (!ancestorInheriting(stop, "TabBar"))
                return false;
            // The scroll area holding the tabs would be a nameless stop before them.
            if (inheritsClass(stop, "LcScrollArea"))
                stop->setFocusPolicy(Qt::NoFocus);
            else
                folders << stop;
            return true;
        });
        const qsizetype at = search - content.begin();
        for (qsizetype i = 0; i < folders.size(); ++i)
            content.insert(at + i, folders.at(i));
    }
    const QList<QWidget *> order = content + titleBar;
    for (qsizetype i = 1; i < order.size(); ++i)
        QWidget::setTabOrder(order[i - 1], order[i]);
}

// Makes the mouse-only controls in `root` focusable; re-orders the window's Tab stops when
// anything changed.
void makeFocusableIn(QWidget *root)
{
    bool changed = makeFocusable(root);
    for (QWidget *w : root->findChildren<QWidget *>())
        changed = makeFocusable(w) || changed;
    if (changed && root->window())
        orderTabStops(root->window());
}

// First Tab stop of `window`'s content (title bar excluded) that can take focus now.
QWidget *firstContentTabStop(QWidget *window)
{
    QList<QWidget *> content, titleBar;
    collectTabStops(window, content, titleBar, false);
    for (QWidget *w : content) {
        if (w->isVisible() && w->isEnabled())
            return w;
    }
    return nullptr;
}

// ---- Tags ---------------------------------------------------------------------------------------
//
// Stable, language-independent names for the controls the keyboard commands look for (Qt also
// reports objectName as AXIdentifier): "lineMR_gnb-chat", "lineMR_list_messages", ...

QString tagFor(QWidget *w)
{
    if (isLineListView(w)) {
        // Lists inside a row (photo grids in a message) are part of that row.
        if (ancestorInheriting(w, "LcListView"))
            return QString();
        if (ancestorInheriting(w, "ChatMessageView"))
            return QStringLiteral("list_messages");
        if (ancestorInheriting(w, "MainChatPanel"))
            return QStringLiteral("list_chats");
        if (ancestorInheriting(w, "MainFriendPanel"))
            return QStringLiteral("list_friends");
        return QString();
    }
    if (isMessageInput(w))
        return QStringLiteral("input_message");
    // The search boxes above the chat and friend lists.
    if (qobject_cast<const QLineEdit *>(w) && inheritsClass(w, "LcTextField")) {
        if (ancestorInheriting(w, "MainChatPanel"))
            return QStringLiteral("search_chats");
        if (ancestorInheriting(w, "MainFriendPanel"))
            return QStringLiteral("search_friends");
    }
    if (inheritsAnyClass(w, { "LcButton", "LcImage" })) {
        QString icon;
        for (const char *prop : { "iconSource", "source", "defaultSource" }) {
            icon = stringProp(w, prop);
            if (!icon.isEmpty())
                break;
        }
        if (icon.isEmpty())
            icon = lcImageSource(w);
        if (const qsizetype slash = icon.lastIndexOf(u'/'); slash >= 0)
            icon = icon.mid(slash + 1);
        if (const qsizetype dot = icon.lastIndexOf(u'.'); dot > 0)
            icon.truncate(dot);
        icon.remove(QRegularExpression(QStringLiteral("@\\d+x$")));
        if (icon.startsWith(QLatin1String("gnb")) || icon.startsWith(QLatin1String("chatroom-")))
            return icon;
        // Call windows (VoiceCallWindow): the answer / hang-up commands press these.
        if (icon == QLatin1String("call_end_bt") || icon == QLatin1String("call-end-icon") || icon == QLatin1String("hangup"))
            return QStringLiteral("call-end");
        if (icon == QLatin1String("btn_call_answer"))
            return QStringLiteral("call-answer");
    }
    return QString();
}

// LINE's combo boxes (Settings: language, font, lock delay) have no name; their label is the
// LcText right above them.
void labelComboBox(QWidget *box)
{
    if (!inheritsClass(box, "QComboBox") || !box->accessibleName().isEmpty() || !box->isVisible())
        return;
    if (const QString text = labelAboveText(box); !text.isEmpty())
        box->setAccessibleName(text);
    else if (const QString text = nearbyLabelText(box); !text.isEmpty())
        box->setAccessibleName(text);
}

void tagWidget(QWidget *w)
{
    labelComboBox(w);
    if (!w->objectName().isEmpty())
        return;
    if (const QString tag = tagFor(w); !tag.isEmpty())
        w->setObjectName(QStringLiteral("lineMR_") + tag);
}

void tagWidgetsIn(QWidget *root)
{
    tagWidget(root);
    for (QWidget *w : root->findChildren<QWidget *>())
        tagWidget(w);
}

// The visible widget tagged lineMR_<tag> in LINE's windows (the active one first).
QWidget *taggedWidget(const QString &tag)
{
    const QString name = QStringLiteral("lineMR_") + tag;
    QList<QWidget *> windows;
    if (QWidget *active = QApplication::activeWindow())
        windows << active;
    for (QWidget *top : QApplication::topLevelWidgets()) {
        if (top->isVisible() && !windows.contains(top))
            windows << top;
    }
    for (QWidget *top : std::as_const(windows)) {
        for (QWidget *w : top->findChildren<QWidget *>(name)) {
            if (w->isVisible())
                return w;
        }
    }
    return nullptr;
}

bool isActivationKey(const QKeyEvent *e)
{
    if (e->modifiers() & kAnyModifier)
        return false;
    return e->key() == Qt::Key_Space || e->key() == Qt::Key_Return || e->key() == Qt::Key_Enter;
}

// ---- Pages opened by a press ---------------------------------------------------------------------
//
// A press that opens a panel inside the window (profile, settings page, search) leaves focus on the
// pressed control, so VoiceOver says nothing about the new page. Panels shown shortly after a press
// are remembered, and focus moves to the first control of the outermost one.

QPointer<QWidget> g_pressed;
QElapsedTimer g_pressTimer;
QPointer<QWidget> g_newContent;

bool pressIsRecent()
{
    return g_pressed && g_pressTimer.isValid() && g_pressTimer.elapsed() < 1500;
}

// The last context menu item press, and the window it opened.
QElapsedTimer g_menuPressTimer;
QPointer<QWidget> g_windowAfterMenu;

bool menuPressIsRecent()
{
    return g_menuPressTimer.isValid() && g_menuPressTimer.elapsed() < 3000;
}

void noteShownAfterPress(QWidget *w)
{
    QWidget *pressed = g_pressed;
    if (w->isWindow() || w->window() != pressed->window() || w == pressed || w->isAncestorOf(pressed)
        || pressed->isAncestorOf(w) || w->width() < 80 || w->height() < 40 || ancestorInheriting(w, "LcTitleBar"))
        return;
    if (g_newContent && (g_newContent == w || g_newContent->isAncestorOf(w)))
        return;
    if (!g_newContent || w->isAncestorOf(g_newContent))
        g_newContent = w;
}

void moveFocusToNewContent()
{
    QWidget *content = g_newContent;
    g_newContent = nullptr;
    if (!content || !content->isVisible() || !content->window()->isActiveWindow())
        return;
    QWidget *focus = QApplication::focusWidget();
    if (focus && focus->isVisible() && focus != g_pressed.data() && !focus->isAncestorOf(content))
        return; // LINE (or the user) already put focus somewhere on purpose
    if (focus && content->isAncestorOf(focus))
        return;
    QList<QWidget *> stops, titleBar;
    collectTabStops(content, stops, titleBar, false);
    // A page built around a list (friends, chats, search results) starts in the list.
    std::stable_partition(stops.begin(), stops.end(), [](QWidget *stop) { return isLineListView(stop); });
    for (QWidget *stop : std::as_const(stops) + titleBar) {
        if (stop->isVisible() && stop->isEnabled()) {
            static int logged = 0;
            if (logged++ < 10)
                a11yLog("[keyboard] new %s after a press: focus to %s", content->metaObject()->className(),
                        stop->metaObject()->className());
            stop->setFocus(Qt::TabFocusReason);
            return;
        }
    }
}

void pressWithKeyboard(QWidget *w)
{
    QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(w);
    QAccessibleActionInterface *actions = iface ? iface->actionInterface() : nullptr;
    if (!actions)
        return;
    const QStringList names = actions->actionNames();
    // Checkables advertise toggleAction() only (see LineAccessibleButton::actionNames()).
    actions->doAction(names.contains(QAccessibleActionInterface::pressAction()) ? QAccessibleActionInterface::pressAction()
                                                                                : QAccessibleActionInterface::toggleAction());
    // When the press switches the view (e.g. "Log in with smartphone >" swaps the login panel),
    // the pressed control disappears and Qt hands focus to whatever follows it in the chain.
    // Start at the top of the new view instead.
    QPointer<QWidget> pressed(w);
    QPointer<QWidget> window(w->window());
    QTimer::singleShot(200, window, [pressed, window] {
        if (!window || !window->isActiveWindow() || (pressed && pressed->isVisible()))
            return;
        if (QWidget *first = firstContentTabStop(window))
            first->setFocus(Qt::TabFocusReason);
    });
}

// The message input of the chat shown in `window`, if any.
QWidget *messageInputIn(QWidget *window)
{
    for (QWidget *w : window->findChildren<QWidget *>()) {
        if (isMessageInput(w) && w->isVisible())
            return w;
    }
    return nullptr;
}

// Inside the chat shown on the right: its message view, header or message input (which LINE
// places outside ChatMessagePanel in group chats).
bool isInOpenChat(const QWidget *w)
{
    return isMessageInput(w) || inheritsAnyClass(w, { "ChatMessageView", "ChatMessagePanel" })
        || ancestorInheriting(w, "ChatMessagePanel") || ancestorInheriting(w, "ChatMessageView")
        || ancestorInheriting(w, "BaseChatPanel");
}

// ---- Context menus (LcContextMenu) --------------------------------------------------------------
//
// LINE's context menus are mouse-only: no item takes focus, so VoiceOver hears nothing and the
// arrows do nothing. The bridge focuses the first item when a menu opens; Up/Down/Home/End move
// between items, Return/Space press, Escape closes.

bool isContextMenu(const QWidget *w)
{
    return inheritsClass(w, "LcContextMenu");
}

bool isContextMenuItem(const QWidget *w)
{
    return inheritsAnyClass(w, { "LcContextMenuItem", "LcCheckableContextMenuItem", "LcCheckboxContextMenuItem" });
}

QWidget *contextMenuOf(QWidget *w)
{
    if (!w)
        return nullptr;
    return isContextMenu(w) ? w : ancestorInheriting(w, "LcContextMenu");
}

// The menu's usable items, top to bottom (items of a sub-menu belong to that sub-menu).
QList<QWidget *> menuItems(QWidget *menu)
{
    QList<QWidget *> items;
    for (QWidget *w : menu->findChildren<QWidget *>()) {
        if (isContextMenuItem(w) && w->isVisible() && w->isEnabled() && contextMenuOf(w->parentWidget()) == menu)
            items << w;
    }
    std::stable_sort(items.begin(), items.end(), [menu](QWidget *a, QWidget *b) {
        return a->mapTo(menu, QPoint(0, 0)).y() < b->mapTo(menu, QPoint(0, 0)).y();
    });
    return items;
}

void logMenu(QWidget *menu)
{
    static int logged = 0;
    if (logged++ >= 5)
        return;
    QWidget *popup = QApplication::activePopupWidget();
    a11yLog("[menu] %s shown: window=%d flags=0x%x active=%d popup=%s", menu->metaObject()->className(),
            int(menu->isWindow()), unsigned(menu->window()->windowFlags()), int(menu->window()->isActiveWindow()),
            popup ? popup->metaObject()->className() : "-");
    for (QWidget *item : menuItems(menu)) {
        QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(item);
        a11yLog("[menu]   %s \"%s\" clicked()=%d triggered()=%d", item->metaObject()->className(),
                iface ? qUtf8Printable(iface->text(QAccessible::Name)) : "", int(isSignalConnected(item, "clicked()")),
                int(isSignalConnected(item, "triggered()")));
    }
}

void focusMenuItem(QWidget *item)
{
    if (!item)
        return;
    if (item->focusPolicy() == Qt::NoFocus)
        item->setFocusPolicy(Qt::TabFocus);
    QWidget *window = item->window();
    // A popup gets the keyboard without being activated; other menu windows must be activated.
    if (!window->isActiveWindow() && window->windowType() != Qt::Popup)
        window->activateWindow();
    item->setFocus(Qt::PopupFocusReason);
    // VoiceOver follows the Focus event of the item (LcContextMenuItem posts none itself).
    postFocus(item);
}

// Moves focus within `menu` by key (Up/Down wrap around, Home/End go to the ends).
void moveInMenu(QWidget *menu, int key)
{
    const QList<QWidget *> items = menuItems(menu);
    if (items.isEmpty())
        return;
    qsizetype i = items.indexOf(QApplication::focusWidget());
    if (key == Qt::Key_Home || (i < 0 && key == Qt::Key_Down))
        i = 0;
    else if (key == Qt::Key_End || (i < 0 && key == Qt::Key_Up))
        i = items.size() - 1;
    else if (key == Qt::Key_Down)
        i = (i + 1) % items.size();
    else if (key == Qt::Key_Up)
        i = (i + items.size() - 1) % items.size();
    focusMenuItem(items[i]);
}

void pressMenuItem(QWidget *item)
{
    QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(item);
    if (QAccessibleActionInterface *actions = iface ? iface->actionInterface() : nullptr)
        actions->doAction(QAccessibleActionInterface::pressAction()); // also closes the menu
}

// Is `menu` the chat background's menu (Select all / Set wallpaper), not a message's? LINE shows it
// when a right click misses the part of a message it reacts to.
bool isChatBackgroundMenu(QWidget *menu)
{
    // "Set wallpaper" in the languages LINE offers.
    static const QStringList kWallpaper = { QStringLiteral("วอลล์เปเปอร์"), QStringLiteral("wallpaper"),
                                            QStringLiteral("壁紙"), QStringLiteral("壁纸"), QStringLiteral("桌布"),
                                            QStringLiteral("背景") };
    // Select all / Set wallpaper. A photo's menu has "Use as wallpaper" too, among many other items.
    const QList<QWidget *> items = menu ? menuItems(menu) : QList<QWidget *>();
    if (items.isEmpty() || items.size() > 2)
        return false;
    for (QWidget *item : items) {
        QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(item);
        const QString name = iface ? iface->text(QAccessible::Name) : QString();
        for (const QString &word : kWallpaper) {
            if (name.contains(word, Qt::CaseInsensitive))
                return true;
        }
    }
    return false;
}

// ---- Windows -------------------------------------------------------------------------------------

bool isCallWindow(const QWidget *w)
{
    const QLatin1StringView cls(w->metaObject()->className());
    return cls.contains(QLatin1StringView("Call"), Qt::CaseInsensitive)
        || cls.contains(QLatin1StringView("Voip"), Qt::CaseInsensitive);
}

void windowShown(QWidget *w)
{
    static QSet<QByteArray> loggedClasses;
    const QByteArray cls = w->metaObject()->className();
    if (!loggedClasses.contains(cls)) {
        loggedClasses.insert(cls);
        a11yLog("[window] first %s shown: flags=0x%x active=%d", cls.constData(), unsigned(w->windowFlags()),
                int(w->isActiveWindow()));
    }
    // A long message's full text ("See more"): one list row, read in one go. A text view laid over
    // it reads by line (full_text_view.h); while LINE keeps painting, try again, then start on the
    // text row (the first row is a blank spacer).
    if (inheritsClass(w, "ChatDetailTextMessageWindow")) {
        QPointer<QWidget> window(w);
        auto attach = std::make_shared<std::function<void(int)>>();
        *attach = [window, attach](int tries) {
            if (!window || !window->isVisible() || attachFullTextView(window))
                return;
            if (tries > 0) {
                QTimer::singleShot(300, window, [attach, tries] { (*attach)(tries - 1); });
                return;
            }
            for (auto *view : window->findChildren<QAbstractItemView *>()) {
                LineAccessibleList *list = LineAccessibleList::listFor(view);
                if (!list || !view->isVisible())
                    continue;
                if (!window->isActiveWindow())
                    window->activateWindow();
                view->setFocus(Qt::OtherFocusReason);
                list->focusEdgeRow(false);
                break;
            }
        };
        QTimer::singleShot(300, w, [attach] { (*attach)(5); });
    }
    if (!isCallWindow(w))
        return;
    // LINE may show a call window without activating it, so focus never gets there: say what it shows.
    QPointer<QWidget> window(w);
    QTimer::singleShot(1500, w, [window] {
        if (!window || !window->isVisible() || window->isActiveWindow())
            return;
        const QString text = collectVisibleChildTexts(window);
        a11yLog("[call] %s not active; announcing %d chars", window->metaObject()->className(), int(text.size()));
        announce(text, AnnounceWhen::Always);
    });
}

// ---- Option+Command commands ---------------------------------------------------------------------

void focusWidget(QWidget *w, Qt::FocusReason reason = Qt::OtherFocusReason)
{
    QWidget *window = w->window();
    if (!window->isActiveWindow())
        window->activateWindow();
    w->setFocus(reason);
}

// Presses the sidebar tab tagged lineMR_<tag> (or named `name`).
bool pressSidebarTab(const QString &tag, const char *name)
{
    QWidget *tab = taggedWidget(tag);
    if (!tab) {
        const QString wanted = label(name);
        for (QWidget *top : QApplication::topLevelWidgets()) {
            if (!top->isVisible() || !inheritsClass(top, "AllInOneWindow"))
                continue;
            for (QWidget *w : top->findChildren<QWidget *>()) {
                if (!w->isVisible() || !inheritsClass(w, "LcCheckBox") || ancestorInheriting(w, "TabBar"))
                    continue;
                QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(w);
                if (iface && iface->text(QAccessible::Name) == wanted) {
                    tab = w;
                    break;
                }
            }
        }
    }
    QAccessibleInterface *iface = tab ? QAccessible::queryAccessibleInterface(tab) : nullptr;
    QAccessibleActionInterface *actions = iface ? iface->actionInterface() : nullptr;
    if (!actions)
        return false;
    if (!(iface->state().checked))
        actions->doAction(actions->actionNames().value(0));
    return true;
}

QWidget *visibleList()
{
    if (QWidget *chats = taggedWidget(QStringLiteral("list_chats")))
        return chats;
    return taggedWidget(QStringLiteral("list_friends"));
}

// Focuses a list once it has been shown (after a sidebar tab switch).
void focusListLater(const QString &tag, int tries = 10)
{
    QTimer::singleShot(100, qApp, [tag, tries] {
        if (QWidget *list = taggedWidget(tag)) {
            focusWidget(list);
            return;
        }
        if (tries > 0)
            focusListLater(tag, tries - 1);
    });
}

// Option+Command+1 ... 3 / C / L / F / M / I / A / D, Shift+Option+Command+1 ... 9: the bridge's
// commands (see A11yEventFilter::handleCommandKey). The physical key counts, not the character it
// types (Thai and other layouts). Returns the digit (1-9), -1 for a letter command, 0 for other keys.
int commandKeyDigit(const QKeyEvent *key, bool *shift = nullptr)
{
    const Qt::KeyboardModifiers mods = key->modifiers() & (kAnyModifier | Qt::ShiftModifier);
    const bool command = mods == (Qt::ControlModifier | Qt::AltModifier);
    const bool shiftCommand = mods == (Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier);
    if (shift)
        *shift = shiftCommand;
    if (!command && !shiftCommand)
        return 0;
    static const quint32 digits[] = { kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9 };
    const quint32 vk = key->nativeVirtualKey();
    for (int i = 0; i < 9; ++i) {
        if (vk == digits[i])
            return shiftCommand || i < 3 ? i + 1 : 0;
    }
    if (shiftCommand)
        return 0;
    for (quint32 letter : { kVK_ANSI_C, kVK_ANSI_L, kVK_ANSI_F, kVK_ANSI_M, kVK_ANSI_I, kVK_ANSI_A, kVK_ANSI_D }) {
        if (vk == letter)
            return -1;
    }
    return 0;
}

bool isCommandKey(const QKeyEvent *key)
{
    return commandKeyDigit(key) != 0;
}

// LINE's chat list or friend list moved keyboard focus elsewhere while the user browses it.
bool suppressFocus(QObject *object)
{
    return g_filter && object->isWidgetType() && g_filter->suppressFocusOn(static_cast<QWidget *>(object));
}

} // namespace

void enforceAccessibilityHandler(const char *reason)
{
    const QAccessible::UpdateHandler ours = bridgeUpdateHandler();
    const QAccessible::UpdateHandler previous = QAccessible::installUpdateHandler(ours);
    if (previous && previous != ours) {
        static int logged = 0;
        if (logged++ < 20)
            a11yLog("[handler] removed foreign QAccessible update handler %p (%s)",
                    reinterpret_cast<void *>(previous), reason);
    }
    QAccessible::setActive(true);
}

void endListBrowsing()
{
    if (g_filter)
        g_filter->endBrowsing();
}

bool isBrowsingList(const QWidget *list)
{
    return g_filter && g_filter->browsing(list);
}

void notePress(QWidget *pressed)
{
    g_pressed = pressed;
    g_pressTimer.start();
    g_newContent = nullptr;
    if (pressed)
        QTimer::singleShot(450, pressed->window(), [] { moveFocusToNewContent(); });
}

void noteMenuPress(QWidget *item, const char *how)
{
    g_menuPressTimer.start();
    g_windowAfterMenu = nullptr;
    QAccessibleInterface *iface = item ? QAccessible::queryAccessibleInterface(item) : nullptr;
    a11yLog("[menu] pressed \"%s\" (%s)", iface ? qUtf8Printable(iface->text(QAccessible::Name)) : "", how);
}

void setMenuRetry(std::function<void()> retry)
{
    g_menuRetry = std::move(retry);
    g_menuRetrySet.start();
}

int contextMenusShown()
{
    return g_menusShown;
}

A11yEventFilter::A11yEventFilter(QObject *parent)
    : QObject(parent)
{
    g_filter = this;
    setFocusSuppressor(&suppressFocus);
}

bool A11yEventFilter::browsing(const QWidget *list) const
{
    return list && m_browsingList.data() == list && m_listKeyTimer.isValid() && m_listKeyTimer.elapsed() < 5000;
}

bool A11yEventFilter::suppressFocusOn(const QWidget *w) const
{
    return m_browsingList && w != m_browsingList.data() && m_listKeyTimer.isValid()
        && m_listKeyTimer.elapsed() < 5000 && isInOpenChat(w);
}

void A11yEventFilter::startWatchdog(int intervalMs)
{
    if (!m_watchdog) {
        m_watchdog = new QTimer(this);
        QObject::connect(m_watchdog, &QTimer::timeout, this, [this] { watchdogTick(); });
    }
    m_watchdog->start(intervalMs);
}

void A11yEventFilter::updateTabFocusBehavior()
{
    // Qt on macOS lets Tab reach only text fields and lists unless Full Keyboard Access is on. While
    // VoiceOver runs, Tab reaches every control (as with Full Keyboard Access); the system's choice
    // comes back when VoiceOver is turned off.
    QStyleHints *hints = QGuiApplication::styleHints();
    if (voiceOverRunning()) {
        if (m_systemTabBehavior < 0) {
            m_systemTabBehavior = int(hints->tabFocusBehavior());
            if (hints->tabFocusBehavior() != Qt::TabFocusAllControls) {
                hints->setTabFocusBehavior(Qt::TabFocusAllControls);
                a11yLog("[keyboard] VoiceOver on: Tab reaches all controls");
            }
        }
    } else if (m_systemTabBehavior >= 0) {
        hints->setTabFocusBehavior(Qt::TabFocusBehavior(m_systemTabBehavior));
        m_systemTabBehavior = -1;
        a11yLog("[keyboard] VoiceOver off: Tab behaviour back to the system's");
    }
}

void A11yEventFilter::watchdogTick()
{
    ++m_ticks;
    // Qt calls the most recently installed application filter first, and LINE installs its own
    // filters (which consume keys such as the arrows in the chat list): stay in front.
    if (QCoreApplication *app = QCoreApplication::instance()) {
        app->removeEventFilter(this);
        app->installEventFilter(this);
    }
    enforceAccessibilityHandler("watchdog");

    // Keep the bridge factory at the end of Qt's list (factories are consulted last-first).
    QAccessible::removeFactory(lineAccessibleFactory);
    QAccessible::installFactory(lineAccessibleFactory);

    updateTabFocusBehavior();
    labelNativeButtons();
    for (QWidget *top : QApplication::topLevelWidgets()) {
        if (!top->isVisible())
            continue;
        labelInputsIn(top);
        // Widgets LINE shows without a Show event reaching us (re-parented, re-laid out).
        if (m_ticks % 3 == 0) {
            makeFocusableIn(top);
            tagWidgetsIn(top);
        }
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
    case QEvent::WindowActivate:
        enforceAccessibilityHandler("WindowActivate");
        break;
    case QEvent::FocusIn:
        enforceAccessibilityHandler("FocusIn");
        break;
    default:
        break;
    }
    if (!watched->isWidgetType()) {
        if (auto *window = qobject_cast<QQuickWindow *>(watched)) {
            if (event->type() == QEvent::Show)
                quickWindowShown(window);
            else if (event->type() == QEvent::KeyPress) {
                auto *key = static_cast<QKeyEvent *>(event);
                if (!key->isAutoRepeat() && !(key->modifiers() & kAnyModifier) && handleQuickKey(window, key->key()))
                    return true;
            }
        }
        return false;
    }
    auto *w = static_cast<QWidget *>(watched);
    switch (event->type()) {
    case QEvent::Polish:
        repairCachedInterface(w);
        break;
    case QEvent::Show:
        handleShow(w);
        break;
    case QEvent::Hide:
        if (isContextMenu(w) && w == m_menu.data())
            menuHidden();
        break;
    case QEvent::WindowActivate:
        handleWindowActivate(w);
        break;
    case QEvent::FocusIn:
        handleFocusIn(w, static_cast<QFocusEvent *>(event)->reason());
        break;
    case QEvent::MouseButtonPress:
        if (event->spontaneous()) {
            m_browsingList = nullptr; // the user went somewhere on purpose
            // A click opens a chat itself: the chat list cursor follows LINE's current row again.
            if (QWidget *view = isLineListView(w) ? w : w->parentWidget(); view && isLineListView(view)) {
                if (LineAccessibleList *list = LineAccessibleList::listFor(view))
                    list->resetCursor();
            }
        }
        break;
    case QEvent::MouseButtonRelease:
        if (QWidget *delegate = delegateAncestorOrSelf(w)) {
            QPointer<QWidget> guard(delegate);
            QTimer::singleShot(0, this, [this, guard] {
                if (guard && guard->isVisible()) {
                    postFocus(guard);
                    announceDelegate(guard);
                }
            });
        }
        break;
    case QEvent::ContextMenu:
        // Keyboard context menus (menu key on PC keyboards): the row the user is on, not the centre
        // of LINE's current row (see LineAccessibleList::openRowMenu / openCursorMenu).
        if (static_cast<QContextMenuEvent *>(event)->reason() == QContextMenuEvent::Keyboard
            && (isCursorList(w) || (isLineListView(w) && ancestorInheriting(w, "ChatMessageView")))) {
            if (m_cursorMenuKey.isValid() && m_cursorMenuKey.elapsed() < 1000)
                return true; // the key press already opened it
            if (LineAccessibleList *list = LineAccessibleList::listFor(w)) {
                if (isCursorList(w) ? list->openCursorMenu() : list->openRowMenu())
                    return true;
            }
        }
        break;
    case QEvent::ShortcutOverride: {
        // Option+Command commands must reach the key press (LINE's shortcuts would take them).
        auto *key = static_cast<QKeyEvent *>(event);
        if (isCommandKey(key)) {
            event->accept();
            return true;
        }
        break;
    }
    case QEvent::KeyPress:
        if (handleKeyPress(w, static_cast<QKeyEvent *>(event)))
            return true;
        break;
    default:
        break;
    }
    return QObject::eventFilter(watched, event);
}

bool A11yEventFilter::handleKeyPress(QWidget *w, QKeyEvent *key)
{
    if (handleCommandKey(w, key))
        return true;
    if (QWidget *menu = contextMenuOf(w); menu && menu->isVisible() && handleMenuKey(menu, key))
        return true;
    // LINE's own application event filters (after this one) switch to the previous / next chat on
    // Up/Down in the message input: the input gets them directly instead.
    if ((key->key() == Qt::Key_Up || key->key() == Qt::Key_Down) && !(key->modifiers() & (Qt::ControlModifier | Qt::AltModifier))
        && w->hasFocus() && isMessageInput(w)) {
        static int logged = 0;
        if (logged++ < 3)
            a11yLog("[keyboard] key 0x%x in the message input bypasses LINE's filters", key->key());
        static_cast<QObject *>(w)->event(key);
        return true;
    }
    // The full-text view (full_text_view.h): LINE's filters eat the arrows too. Tab and Escape go the
    // usual way (next control, LINE closes the window). Return there opens a web address on the
    // caret's line (or one wrapped onto it).
    if (w->hasFocus() && w->objectName() == QLatin1StringView("lineMR_fulltext")) {
        if ((key->key() == Qt::Key_Return || key->key() == Qt::Key_Enter) && !key->isAutoRepeat()) {
            if (auto *edit = qobject_cast<QPlainTextEdit *>(w)) {
                const QTextBlock line = edit->textCursor().block();
                QStringList lines;
                for (QTextBlock b = line; b.isValid() && lines.size() < 4; b = b.next())
                    lines << b.text();
                QString url = firstWebAddress(lines);
                if (url.isEmpty() && line.previous().isValid())
                    url = firstWebAddress({ line.previous().text(), line.text() });
                if (!url.isEmpty() && openInBrowser(url)) {
                    a11yLog("[fulltext] link (%s) opened in the browser", qUtf8Printable(QUrl(url).host()));
                    return true;
                }
            }
        }
        if (key->key() != Qt::Key_Tab && key->key() != Qt::Key_Backtab && key->key() != Qt::Key_Escape) {
            static_cast<QObject *>(w)->event(key);
            return true;
        }
    }
    if (isNavigationKey(key->key()))
        scheduleSelectionScan(w);
    if (!isLineListView(w) || !isListNavigationKey(key->key()))
        m_browsingList = nullptr;
    const bool messages = isLineListView(w) && ancestorInheriting(w, "ChatMessageView");
    LineAccessibleList *list = isLineListView(w) ? LineAccessibleList::listFor(w) : nullptr;
    if (messages && list && isListNavigationKey(key->key())) {
        m_browsingList = w;
        m_listKeyTimer.start();
        // Home / End: the oldest loaded / the newest message (LINE loads older messages when the
        // top is reached, so Home again goes further back). Command+Up / Down too (the Mac way).
        const bool commandArrow = (key->modifiers() & Qt::ControlModifier) && !(key->modifiers() & Qt::AltModifier)
            && (key->key() == Qt::Key_Up || key->key() == Qt::Key_Down);
        if ((key->key() == Qt::Key_Home || key->key() == Qt::Key_End) && !(key->modifiers() & (Qt::AltModifier | Qt::ShiftModifier))) {
            list->focusEdgeRow(key->key() == Qt::Key_End);
            return true;
        }
        if (commandArrow) {
            list->focusEdgeRow(key->key() == Qt::Key_Down);
            return true;
        }
        // The arrows move from the bridge's row too (LINE keeps a position of its own).
        if (plainKey(key) && list->stepRow(key->key()))
            return true;
    }
    if (list && (key->key() == Qt::Key_Space || key->key() == Qt::Key_Return || key->key() == Qt::Key_Enter)
        && plainKey(key)) {
        if (!key->isAutoRepeat() && (messages ? list->activateMessage() : list->toggleCursorRow()))
            return true;
    }
    // The menu key (PC keyboards) or Shift+F10 on a message / a chat or friend list row: its menu.
    const bool menuKey = key->key() == Qt::Key_Menu
        || (key->key() == Qt::Key_F10 && (key->modifiers() & Qt::ShiftModifier));
    if (list && menuKey && !key->isAutoRepeat() && (messages || isCursorList(w))) {
        if (messages ? list->openRowMenu() : list->openCursorMenu()) {
            m_cursorMenuKey.start();
            return true;
        }
    }
    // The chat and friend lists open the row on every step, and LINE then moves focus into the chat:
    // they get the bridge's own cursor.
    if (list && isCursorList(w)) {
        const bool friendList = ancestorInheriting(w, "MainFriendPanel") != nullptr;
        if (isListNavigationKey(key->key())) {
            m_browsingList = w;
            m_listKeyTimer.start();
            // The bridge's cursor moves; LINE's current row (the open chat) stays.
            if (plainKey(key) && list->moveCursor(key->key()))
                return true;
        } else if ((key->key() == Qt::Key_Return || key->key() == Qt::Key_Enter)
                   && !(key->modifiers() & (Qt::ControlModifier | Qt::AltModifier))) {
            // Friends: click the row and let LINE decide (a section header folds, a friend's chat
            // opens and LINE moves focus there itself).
            if (friendList) {
                if (list->openCursorRow()) {
                    m_browsingList = nullptr;
                    return true;
                }
                return false;
            }
            // Return: open the chat under the cursor, go to it and start typing.
            if (list->openCursorRow()) {
                m_browsingList = nullptr;
                QPointer<QWidget> listView = w;
                QTimer::singleShot(0, this, [listView] {
                    if (!listView || !listView->hasFocus())
                        return;
                    if (QWidget *input = messageInputIn(listView->window()))
                        input->setFocus(Qt::OtherFocusReason);
                });
                return true;
            }
            if (QWidget *input = messageInputIn(w->window())) {
                input->setFocus(Qt::OtherFocusReason);
                return true;
            }
        }
    }
    if (w->property(kMadeFocusableProperty).toBool() && w->hasFocus() && isActivationKey(key)) {
        if (!key->isAutoRepeat())
            pressWithKeyboard(w);
        return true;
    }
    return false;
}

bool A11yEventFilter::handleCommandKey(QWidget *w, QKeyEvent *key)
{
    bool shiftCommand = false;
    const int which = commandKeyDigit(key, &shiftCommand);
    if (which == 0)
        return false;
    if (key->isAutoRepeat())
        return true;
    const int digit = qMax(which, 0);
    const quint32 vk = key->nativeVirtualKey();
    markUserActivity();
    endListBrowsing();
    // Shift+Option+Command+1 ... 9: read a recent message (1 = newest) without moving.
    if (shiftCommand) {
        if (!digit)
            return false;
        QWidget *messages = taggedWidget(QStringLiteral("list_messages"));
        LineAccessibleList *list = messages ? LineAccessibleList::listFor(messages) : nullptr;
        if (!list) {
            announce(label("No chat is open"));
            return true;
        }
        const QString text = list->recentMessageText(digit);
        announce(text.isEmpty() ? label("No message %1").arg(digit) : text);
        return true;
    }
    switch (digit) {
    case 1:
        if (!pressSidebarTab(QStringLiteral("gnb-friends"), "Friends"))
            announce(label("Not available here"));
        return true;
    case 2:
        if (!pressSidebarTab(QStringLiteral("gnb-chat"), "Chats"))
            announce(label("Not available here"));
        return true;
    case 3:
        if (!pressSidebarTab(QStringLiteral("gnb-add-friend"), "Add friends"))
            announce(label("Not available here"));
        return true;
    default:
        break;
    }
    if (digit)
        return false;
    switch (vk) {
    case kVK_ANSI_C: // the chat list (switching to the Chats tab first if needed)
        if (QWidget *chats = taggedWidget(QStringLiteral("list_chats"))) {
            focusWidget(chats);
        } else if (pressSidebarTab(QStringLiteral("gnb-chat"), "Chats")) {
            focusListLater(QStringLiteral("list_chats"));
        } else {
            announce(label("Not available here"));
        }
        return true;
    case kVK_ANSI_L: // whichever list is shown
        if (QWidget *list = visibleList())
            focusWidget(list);
        else
            announce(label("Not available here"));
        return true;
    case kVK_ANSI_F: // the search field above the list
        if (QWidget *search = taggedWidget(QStringLiteral("search_chats")))
            focusWidget(search);
        else if (QWidget *search = taggedWidget(QStringLiteral("search_friends")))
            focusWidget(search);
        else
            announce(label("Not available here"));
        return true;
    case kVK_ANSI_M: // the messages of the open chat (newest first)
        if (QWidget *messages = taggedWidget(QStringLiteral("list_messages")))
            focusWidget(messages, Qt::OtherFocusReason);
        else
            announce(label("No chat is open"));
        return true;
    case kVK_ANSI_I: // the message input
        if (QWidget *input = taggedWidget(QStringLiteral("input_message")))
            focusWidget(input);
        else
            announce(label("No chat is open"));
        return true;
    case kVK_ANSI_A:
        answerCall();
        return true;
    case kVK_ANSI_D:
        declineOrEndCall();
        return true;
    default:
        break;
    }
    Q_UNUSED(w);
    return false;
}

bool A11yEventFilter::handleMenuKey(QWidget *menu, const QKeyEvent *key)
{
    if (key->modifiers() & kAnyModifier)
        return false;
    switch (key->key()) {
    case Qt::Key_Up:
    case Qt::Key_Down:
    case Qt::Key_Home:
    case Qt::Key_End:
        moveInMenu(menu, key->key());
        return true;
    case Qt::Key_Escape:
        menu->hide();
        return true;
    case Qt::Key_Return:
    case Qt::Key_Enter:
    case Qt::Key_Space: {
        QWidget *item = QApplication::focusWidget();
        if (!item || !isContextMenuItem(item) || contextMenuOf(item) != menu)
            return false;
        if (!key->isAutoRepeat())
            pressMenuItem(item);
        return true;
    }
    default:
        return false;
    }
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
    makeFocusableIn(w);
    tagWidgetsIn(w);
    if (w->isWindow() && !isContextMenu(w) && menuPressIsRecent()) {
        a11yLog("[menu] after the press: %s shown, active=%d", w->metaObject()->className(), int(w->isActiveWindow()));
        // A confirmation (AlertWindow, shown inactive): the user has to answer it.
        g_windowAfterMenu = w;
        QPointer<QWidget> window(w);
        QTimer::singleShot(150, w, [window] {
            if (!window || !window->isVisible() || window->isActiveWindow())
                return;
            window->raise();
            window->activateWindow();
        });
    }
    if (w->isWindow())
        windowShown(w);
    else if (pressIsRecent())
        noteShownAfterPress(w);
    if (isContextMenu(w))
        menuShown(w);
}

void A11yEventFilter::handleWindowActivate(QWidget *w)
{
    if (!w->isWindow()) {
        return;
    }
    labelInputsIn(w);
    if (isContextMenu(w))
        return;
    // A dialog window LINE opens with nothing focused, or (first activation) with focus on a
    // title-bar button such as Close: start at its first control.
    const auto unfocused = [](QWidget *window, bool first) {
        QWidget *f = window->focusWidget();
        return !f || (first && ancestorInheriting(f, "LcTitleBar")
                      && !inheritsAnyClass(window, { "AllInOneWindow", "ChatWindow" }));
    };
    const bool first = !w->property("_lineA11yActivated").toBool();
    w->setProperty("_lineA11yActivated", true);
    if (unfocused(w, first)) {
        QPointer<QWidget> window(w);
        QTimer::singleShot(150, w, [window, first, unfocused] {
            if (window && window->isActiveWindow() && unfocused(window, first))
                if (QWidget *stop = firstContentTabStop(window))
                    stop->setFocus(Qt::TabFocusReason);
        });
    }
}

void A11yEventFilter::handleFocusIn(QWidget *w, Qt::FocusReason reason)
{
    if (isLineInputWidget(w))
        ensureInputLabel(w);
    // Entering the chat or friend list starts at LINE's current row (unless the bridge is sending
    // focus back while the user browses).
    if (isCursorList(w) && w != m_browsingList.data()) {
        if (LineAccessibleList *list = LineAccessibleList::listFor(w))
            list->resetCursor();
    }
    if (isLineListView(w) && ancestorInheriting(w, "ChatMessageView")) {
        // Entering the messages (Tab, Shift+Tab, Option+Command+M) starts at the newest one; coming
        // back (focus sent back by the bridge, menu closed, window activated, click) keeps the place.
        const bool returning = (w == m_browsingList.data() && m_listKeyTimer.isValid() && m_listKeyTimer.elapsed() < 5000)
            || reason == Qt::PopupFocusReason || reason == Qt::ActiveWindowFocusReason || reason == Qt::MouseFocusReason;
        if (LineAccessibleList *list = LineAccessibleList::listFor(w)) {
            // Tab / Shift+Tab back into the same chat: the message last read.
            const bool tab = reason == Qt::TabFocusReason || reason == Qt::BacktabFocusReason;
            if (returning)
                list->focusLastVisibleRow();
            else if (!tab || !list->focusRememberedRow())
                list->focusEdgeRow(true);
        }
        // LINE hands focus on from the message list to the message input; reading messages needs it
        // to stay (Tab still moves on).
        m_browsingList = w;
        m_listKeyTimer.start();
    }
    // Arrowing through the chat list opens each chat, and once it has loaded (up to a few seconds
    // later) LINE moves focus into the chat: keep the user in the list instead.
    if (m_browsingList && m_browsingList->isVisible() && w != m_browsingList.data() && isInOpenChat(w)
        && m_listKeyTimer.isValid() && m_listKeyTimer.elapsed() < 5000) {
        static int logged = 0;
        if (logged++ < 10)
            a11yLog("[keyboard] LINE moved focus to %s while browsing; back to the list", w->metaObject()->className());
        QPointer<QWidget> list = m_browsingList;
        QTimer::singleShot(0, this, [list] {
            if (list && list->isVisible())
                list->setFocus(Qt::OtherFocusReason);
        });
        return;
    }
    // Qt only emits Focus for widgets while accessibility is active; LINE's custom widgets also need
    // it after the update handler has been restored.
    if (inheritsClass(w, "LcWidget") && !qobject_cast<QLineEdit *>(w) && !qobject_cast<QTextEdit *>(w)
        && !isLineListView(w))
        postFocus(w);
}

void A11yEventFilter::menuShown(QWidget *menu)
{
    ++g_menusShown;
    logMenu(menu);
    QWidget *focus = QApplication::focusWidget();
    if (!contextMenuOf(focus))
        m_menuReturnFocus = focus;
    m_menu = menu;
    // LINE fills and lays out the menu right after showing it.
    QPointer<QWidget> guard(menu);
    QTimer::singleShot(50, menu, [guard] {
        if (!guard || !guard->isVisible())
            return;
        // The bridge's right click on a message missed: close the background's menu (which also ends
        // LINE's menu loop) and click the message's next part.
        std::function<void()> retry;
        if (g_menuRetrySet.isValid() && g_menuRetrySet.elapsed() < 1500)
            retry = std::move(g_menuRetry);
        g_menuRetry = nullptr;
        if (retry && isChatBackgroundMenu(guard)) {
            a11yLog("[menu] the chat background's menu: trying another point");
            guard->hide();
            QTimer::singleShot(50, qApp, retry);
            return;
        }
        const QList<QWidget *> items = menuItems(guard);
        if (!items.isEmpty())
            focusMenuItem(items.first());
        static int logged = 0;
        QWidget *now = QApplication::focusWidget();
        if (logged++ < 5)
            a11yLog("[menu] focused first of %d items; focus now %s", int(items.size()),
                    now ? now->metaObject()->className() : "-");
    });
}

void A11yEventFilter::menuHidden()
{
    m_menu = nullptr;
    QPointer<QWidget> back = m_menuReturnFocus;
    m_menuReturnFocus = nullptr;
    // The menu is a window of its own: give the keyboard back to the window it was opened from, to
    // the widget the chosen item focused there (e.g. "Reply" focuses the message input) or else to
    // where the menu was opened.
    QTimer::singleShot(0, this, [back] {
        if (!back || !back->isVisible())
            return;
        // The chosen item opened a window (a confirmation): it keeps the keyboard.
        if (g_windowAfterMenu && g_windowAfterMenu->isVisible() && g_windowAfterMenu->window() != back->window()) {
            a11yLog("[menu] closed; %s keeps the focus", g_windowAfterMenu->metaObject()->className());
            return;
        }
        QWidget *window = back->window();
        QWidget *target = window->focusWidget();
        if (!target || !target->isVisible() || contextMenuOf(target))
            target = back;
        if (!window->isActiveWindow())
            window->activateWindow();
        target->setFocus(Qt::PopupFocusReason);
        static int logged = 0;
        if (logged++ < 5)
            a11yLog("[menu] closed; focus to %s", target->metaObject()->className());
    });
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

} // namespace line_a11y
