#include "a11y_EventFilter.h"

#include "a11y_diagnostics.h"
#include "transcribe_request.h"
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
#include "text_capture.h"
#include "video_controls.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QDateTime>
#include <QtCore/QFile>
#include <QtCore/QElapsedTimer>
#include <QtCore/QEvent>
#include <QtCore/QRegularExpression>
#include <QtCore/QSet>
#include <QtCore/QScopedValueRollback>
#include <QtCore/QTimer>
#include <QtCore/QUrl>
#include <QtGui/QAccessible>
#include <QtGui/QContextMenuEvent>
#include <QtGui/QGuiApplication>
#include <QtGui/QKeyEvent>
#include <QtGui/QWindow>
#include <QtGui/QStyleHints>
#include <QtGui/QTextBlock>
#include <QtQuick/QQuickWindow>
#include <QtWidgets/QAbstractItemView>
#include <QtWidgets/QApplication>
#include <QtWidgets/QComboBox>
#include <QtWidgets/QLineEdit>
#include <QtWidgets/QPlainTextEdit>
#include <QtWidgets/QScrollArea>
#include <QtWidgets/QSplitter>
#include <QtWidgets/QTextEdit>
#include <QtWidgets/QWidget>

#include <Carbon/Carbon.h>

#include <algorithm>
#include <limits>
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

// ---- Lists, grids and windows the Windows bridge learnt about (v0.5.3-0.5.5) -------------------

// The messages of a chat (not the search bar's suggestion list, which also sits in ChatMessageView).
bool isMessageList(const QWidget *w)
{
    return isLineListView(w) && ancestorInheriting(w, "ChatMessageView") && !ancestorInheriting(w, "SearchDetailPanel")
        && !ancestorInheriting(w, "LcListView") && !inMentionSuggester(w);
}

// The lists of a chat's Photos & videos / Links / Files window and the sticker window's packages: LINE
// gives them no keyboard (the arrows did nothing), so the bridge moves its own cursor
// (LineAccessibleList::moveGridCursor).
bool isContentList(const QWidget *w)
{
    return isLineListView(w) && !ancestorInheriting(w, "LcListView")
        && (inheritsClass(w->window(), "ContentViewerWindow") || inheritsClass(w->window(), "StickerWindow"));
}

// A sticker (or emoji) in the sticker window's grid (named by stickerName()).
bool isStickerItem(const QWidget *w)
{
    return !stickerName(w).isEmpty();
}

// The arrows in the sticker grid: the nearest sticker that way (Tab still goes one by one).
bool moveInStickerGrid(QWidget *w, int key)
{
    const QPoint from = w->geometry().center();
    QWidget *best = nullptr;
    int bestScore = std::numeric_limits<int>::max();
    for (QWidget *other : w->parentWidget()->findChildren<QWidget *>(Qt::FindDirectChildrenOnly)) {
        if (other == w || !other->isVisible() || !isStickerItem(other))
            continue;
        const QPoint d = other->geometry().center() - from;
        const bool ahead = (key == Qt::Key_Right && d.x() > 4 && qAbs(d.y()) < 8)
            || (key == Qt::Key_Left && d.x() < -4 && qAbs(d.y()) < 8)
            || (key == Qt::Key_Down && d.y() > 4) || (key == Qt::Key_Up && d.y() < -4);
        if (!ahead)
            continue;
        // Along the line first, then the closest column.
        const int score = (key == Qt::Key_Up || key == Qt::Key_Down) ? qAbs(d.y()) * 4 + qAbs(d.x()) : qAbs(d.x());
        if (score < bestScore) {
            bestScore = score;
            best = other;
        }
    }
    if (!best)
        return true; // at the edge: stay
    for (QWidget *p = best->parentWidget(); p; p = p->parentWidget()) {
        if (auto *scroll = qobject_cast<QScrollArea *>(p)) {
            scroll->ensureWidgetVisible(best);
            break;
        }
    }
    best->setFocus(Qt::OtherFocusReason);
    return true;
}

// The chat's search bar shows a result ("41/42"): LINE has made the matching message its current row.
bool chatSearchShowsResult(const QWidget *messageList)
{
    QWidget *view = ancestorInheriting(messageList, "ChatMessageView");
    if (!view)
        return false;
    for (QWidget *b : view->findChildren<QWidget *>()) {
        if (b->isVisible() && chatSearchArrow(b) != 0)
            return true;
    }
    return false;
}

// LINE for macOS shows photos and videos in a MediaViewerWindow of its own process (on Windows a
// separate LineMediaPlayer.exe).
bool isViewerWindow(const QWidget *w)
{
    return w->isWindow() && inheritsClass(w, "MediaViewerWindow");
}

// The viewer's video player (a QQuickWidget, VideoRenderPanelWidget).
bool isVideoWidget(const QWidget *w)
{
    return inheritsClass(w, "QQuickWidget") && inheritsClass(w->window(), "MediaViewerWindow");
}

// The viewer's Download button (image://viewer/download.svg): LINE shows it only while the mouse is
// over the picture, so keyboard users press it through the bridge (Command+S, or Save as... in a
// post's menu in Notes). LINE then asks where to save.
bool saveViewerMedia(QWidget *viewer)
{
    for (QWidget *button : viewer->findChildren<QWidget *>()) {
        if (inheritsClass(button, "LcButton") && iconSource(button).endsWith(QLatin1StringView("/download.svg"))) {
            // The accessible press skips hidden buttons: emit its clicked() signals as a click does.
            a11yLog("[viewer] save: pressing Download (%s)", button->isVisible() ? "shown" : "hidden");
            QPointer<QWidget> guard(button);
            void *self = button;
            void *args[] = { nullptr, &self };
            emitSignal(button, "clicked()");
            if (guard)
                emitSignal(button, "clicked(LcButton*)", args);
            return true;
        }
    }
    a11yLog("[viewer] save: no Download button");
    return false;
}

void viewerShown(QWidget *w)
{
    // "Save as..." chosen in a post's menu (Notes) just before this window showed: save once the
    // picture or video has loaded.
    QPointer<QWidget> viewer(w);
    for (int delay : { 800, 1600, 2400 }) {
        QTimer::singleShot(delay, w, [viewer] {
            if (!viewer || !viewer->isVisible())
                return;
            QFile request(bridgeDirectory() + QStringLiteral("viewer-save-request"));
            if (!request.open(QIODevice::ReadOnly))
                return;
            const qint64 at = request.readAll().trimmed().toLongLong();
            request.close();
            request.remove();
            if (QDateTime::currentMSecsSinceEpoch() - at < 15000)
                saveViewerMedia(viewer);
        });
    }
    // A video starts on the player (Play / Pause, Position, Playback speed), not the thumbnail strip,
    // where Space and the arrows do nothing for the video. Tried until the window is active and the
    // player shows.
    for (int delay : { 300, 700, 1200, 2000 }) {
        QTimer::singleShot(delay, w, [viewer] {
            if (!viewer || !viewer->isActiveWindow() || viewer->property("_lineA11yPlayerFocused").toBool())
                return;
            for (QWidget *video : viewer->findChildren<QWidget *>()) {
                const QWidget *panel = ancestorInheriting(video, "VideoPlayerPanel");
                if (!isVideoWidget(video) || !video->isVisible() || !panel || !panel->isVisible())
                    continue;
                viewer->setProperty("_lineA11yPlayerFocused", true);
                if (viewer->focusWidget() != video) {
                    a11yLog("[viewer] focus to the video player (was %s)",
                            viewer->focusWidget() ? viewer->focusWidget()->metaObject()->className() : "nothing");
                    video->setFocus(Qt::OtherFocusReason);
                }
                return;
            }
        });
    }
}

// The window a photo / video was opened from with the keyboard (Notes), until LINE comes back from
// its media viewer.
QPointer<QWidget> g_mediaReturnWindow;
QElapsedTimer g_mediaReturnTimer;

// Up / Down in the message input while LINE shows sticker suggestions for the text (StickerSuggester
// above the input): moves the caret by a line itself (Shift selects), also nowhere at the first / last
// line, since LINE would move focus into the suggestions (not made accessible yet). False if no
// suggestions show, so the key goes to the input as usual.
bool moveCaretPastStickerSuggester(QWidget *input, const QKeyEvent *key)
{
    auto *edit = qobject_cast<QTextEdit *>(input);
    if (!edit)
        return false;
    bool suggesting = false;
    for (QWidget *c : input->window()->findChildren<QWidget *>()) {
        if (inheritsClass(c, "StickerSuggester") && c->isVisible()) {
            suggesting = true;
            break;
        }
    }
    if (!suggesting)
        return false;
    edit->moveCursor(key->key() == Qt::Key_Up ? QTextCursor::Up : QTextCursor::Down,
                     key->modifiers() & Qt::ShiftModifier ? QTextCursor::KeepAnchor : QTextCursor::MoveAnchor);
    static int logged = 0;
    if (logged++ < 3)
        a11yLog("[keyboard] caret moved past LINE's sticker suggestions (key 0x%x)", key->key());
    return true;
}

// Up / Down (Shift for selecting) in the focused message input. LINE switches to the previous / next
// chat on them from its own event filters.
bool isMessageInputArrow(QWidget *w, const QKeyEvent *key)
{
    return (key->key() == Qt::Key_Up || key->key() == Qt::Key_Down)
        && !(key->modifiers() & (Qt::ControlModifier | Qt::AltModifier))
        && w->hasFocus() && isMessageInput(w) && !mentionSuggesterShown(w); // there they choose a member
}

// Gives the input the key itself, so no event filter (LINE's application or object filters) sees it.
void passArrowToMessageInput(QWidget *input, QKeyEvent *key)
{
    static int logged = 0;
    if (logged++ < 3)
        a11yLog("[keyboard] key 0x%x in the message input bypasses LINE's filters", key->key());
    // While LINE suggests stickers for the line at the caret ("1234", "ขอบคุณ"...), the input moves
    // focus into the suggestions on Up: reading a text upwards lost focus there.
    if (!moveCaretPastStickerSuggester(input, key))
        static_cast<QObject *>(input)->event(key);
    key->accept();
}

// The base name of an LcButton's / LcImage's icon ("image://main/sorting.svg" -> "sorting").
QString iconBaseName(const QWidget *w)
{
    QString icon = iconSource(w);
    if (const qsizetype slash = icon.lastIndexOf(u'/'); slash >= 0)
        icon = icon.mid(slash + 1);
    if (const qsizetype dot = icon.lastIndexOf(u'.'); dot > 0)
        icon.truncate(dot);
    icon.remove(QRegularExpression(QStringLiteral("@\\d+x$")));
    return icon;
}

bool isChatSortButton(const QWidget *w)
{
    return inheritsClass(w, "LcButton") && ancestorInheriting(w, "MainChatPanel")
        && iconBaseName(w) == QLatin1String("sorting");
}

// ---- Chat search (the magnifier in a chat's header) ----------------------------------------------
//
// LINE does not filter the messages: it moves the chat to a matching message (its current row) and
// shows "41/42" with Previous / Next result buttons; Up / Down in the search field do the same, and
// Return searches again from the newest match. VoiceOver hears none of it: after these keys the
// result number and the message are announced (the Windows add-on's chatSearch.py).

struct SearchResult {
    int current = -1;
    int total = -1;
    QString message;
};

SearchResult chatSearchResult(QWidget *anyInChat)
{
    SearchResult result;
    QWidget *view = ancestorInheriting(anyInChat, "ChatMessageView");
    if (!view)
        return result;
    static const QRegularExpression counter(QStringLiteral("^\\s*(\\d+)\\s*/\\s*(\\d+)\\s*$"));
    for (QWidget *t : view->findChildren<QWidget *>()) {
        if (!t->isVisible() || !inheritsClass(t, "LcText"))
            continue;
        if (const auto m = counter.match(extractLcTextString(t)); m.hasMatch()) {
            result.current = m.captured(1).toInt();
            result.total = m.captured(2).toInt();
            break;
        }
    }
    for (QAbstractItemView *list : view->findChildren<QAbstractItemView *>()) {
        if (!isMessageList(list) || !list->isVisible() || !list->currentIndex().isValid())
            continue;
        if (LineAccessibleList *l = LineAccessibleList::listFor(list))
            if (QAccessibleInterface *item = l->itemAt(list->currentIndex().row()))
                result.message = item->text(QAccessible::Name);
        break;
    }
    return result;
}

// (Up to 2 s after the key: not limited to right after the user's input.)
void announceSearchResult(const SearchResult &r)
{
    if (r.current < 0) {
        announce(label("No results"), AnnounceWhen::LineActive);
        return;
    }
    const QString text = label("Result %1 of %2").arg(r.current).arg(r.total);
    announce(r.message.isEmpty() ? text : text + QStringLiteral(", ") + r.message, AnnounceWhen::LineActive);
}

// Called before LINE handles the key; reports once LINE has moved to the match (it may load older
// messages first), or after 2 s (the first / last match, or none).
void reportSearchResultAfterKey(QWidget *w)
{
    const SearchResult before = chatSearchResult(w);
    QPointer<QWidget> guard(w);
    auto check = std::make_shared<std::function<void(int)>>();
    *check = [guard, before, check](int waited) {
        if (!guard) {
            *check = nullptr;
            return;
        }
        const SearchResult now = chatSearchResult(guard);
        if ((now.current >= 0 && now.current != before.current && !now.message.isEmpty() && now.message != before.message)
            || waited >= 2000) {
            announceSearchResult(now);
            *check = nullptr;
            return;
        }
        QTimer::singleShot(100, guard, [check, waited] {
            if (*check)
                (*check)(waited + 100);
        });
    };
    QTimer::singleShot(100, w, [check] {
        if (*check)
            (*check)(100);
    });
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
    // The reply bar's Cancel reply button takes focus on a click only (Qt::ClickFocus).
    const bool clickOnly = w->focusPolicy() == Qt::ClickFocus && w->parentWidget()
        && inheritsClass(w->parentWidget(), "MessageReplyLayer");
    if (w->isWindow() || (w->focusPolicy() != Qt::NoFocus && !clickOnly))
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
// equal buttons over each other (the chat list's ad). Only the outer / top one becomes a Tab stop.
bool duplicatesTabStop(QWidget *w)
{
    auto nameOf = [](QWidget *o) {
        QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(o);
        return iface ? iface->text(QAccessible::Name) : QString();
    };
    // The one on top (later in paint order, and the one VoiceOver sees: the accessible button hides
    // the one it covers) is the stop. Keeping the lower one put the Tab focus on an element missing
    // from the accessibility tree, which VoiceOver read as the unnamed split group around the chat list.
    if (coveredByTwin(w))
        return true;
    const QString name = nameOf(w);
    if (name.isEmpty())
        return false;
    for (QWidget *p = w->parentWidget(); p && !p->isWindow(); p = p->parentWidget()) {
        if (classifyWidget(p) == WidgetKind::Button && nameOf(p) == name)
            return true;
    }
    // A small arrow LINE lays over its own combo box (Create OpenChat's category): the combo box is the stop.
    const QRect rect(w->mapTo(w->window(), QPoint()), w->size());
    for (QComboBox *box : w->window()->findChildren<QComboBox *>()) {
        if (box->isVisible() && QRect(box->mapTo(w->window(), QPoint()), box->size()).contains(rect))
            return true;
    }
    return false;
}

bool makeFocusable(QWidget *w)
{
    if (inMentionSuggester(w))
        return false;
    // The chat header's member count: the chat name stop says it (and opens the same member list).
    // Checked again later: the text can turn into a count after the widget was made focusable.
    if (isChatHeaderMemberCount(w)) {
        if (!w->property(kMadeFocusableProperty).toBool())
            return false;
        w->setFocusPolicy(Qt::NoFocus);
        w->setProperty(kMadeFocusableProperty, false);
        return true;
    }
    if (w->property(kMadeFocusableProperty).toBool() || !wantsKeyboardFocus(w) || duplicatesTabStop(w))
        return false;
    // The sticker window's hover copy of a sticker (a click on it sends): the sticker is the stop.
    if (inheritsClass(w, "AnimatedSticker") && inheritsClass(w->window(), "StickerWindow"))
        return false;
    // TabFocus only: clicking does not move focus, so mouse users see no difference (a control that
    // took focus on a click keeps doing so).
    w->setFocusPolicy(Qt::FocusPolicy(w->focusPolicy() | Qt::TabFocus));
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
        if (c->isWindow() || inMentionSuggester(c))
            continue;
        QList<QWidget *> &stops = inTitleBar ? titleBar : content;
        const qsizetype first = stops.size();
        // The ad's lower twin became a stop before the button over it was shown.
        if (c->property(kMadeFocusableProperty).toBool() && coveredByTwin(c)) {
            c->setFocusPolicy(Qt::NoFocus);
            c->setProperty(kMadeFocusableProperty, false);
        }
        if (c->focusPolicy() & Qt::TabFocus)
            stops << c;
        // A text field's own children (clear / show-password buttons) follow the field.
        collectTabStops(c, content, titleBar, inTitleBar);
        // The message input bar: from the message input (reached from the message list above it)
        // out through its buttons, nearest first (stickers ... attach file).
        if (inheritsClass(c, "MessageInputPanel"))
            std::reverse(stops.begin() + first, stops.end());
        // The selection bar under Photos & videos was created right to left: read it like the screen.
        if (inheritsClass(c, "LcImage") && ancestorInheriting(c, "MediaListPanel"))
            std::stable_sort(stops.begin() + first, stops.end(), [c](QWidget *a, QWidget *b) {
                return a->mapTo(c, QPoint(0, 0)).x() < b->mapTo(c, QPoint(0, 0)).x();
            });
        // The open chat's note banner and the buttons over the messages come before the message
        // list, which leads on to the message input. The reply bar sits between the list and the
        // input it belongs to.
        if (inheritsClass(c, "ChatMessageView"))
            std::stable_partition(stops.begin() + first, stops.end(), [](QWidget *stop) {
                return (!isLineListView(stop) || ancestorInheriting(stop, "LcListView"))
                    && !ancestorInheriting(stop, "MessageReplyLayer");
            });
        // The chat list panel: its buttons (show / hide, create chat, the ad) first, then Sort right
        // before the search field, and the chat list, which leads on to the open chat.
        if (inheritsClass(c, "MainChatPanel")) {
            auto rank = [](QWidget *stop) {
                if (isLineListView(stop) && !ancestorInheriting(stop, "LcListView"))
                    return 3;
                if (inheritsClass(stop, "QLineEdit") || ancestorInheriting(stop, "QLineEdit"))
                    return 2;
                return isChatSortButton(stop) ? 1 : 0;
            };
            std::stable_sort(stops.begin() + first, stops.end(),
                             [&rank](QWidget *a, QWidget *b) { return rank(a) < rank(b); });
        }
    }
}

// Call windows (VoiceCallWindow) have no LcTitleBar: close, pin and settings are plain buttons
// along the top, created before the call controls. Order them like the screen instead: the call
// controls row by row, left to right (microphone, its options, video, speaker, its options, then
// End call below), and the buttons along the top edge last.
void orderCallWindowStops(QWidget *window, QList<QWidget *> &content, QList<QWidget *> &titleBar)
{
    if (!inheritsClass(window, "CallWindow"))
        return;
    const auto top = [window](QWidget *w) { return w->mapTo(window, QPoint(0, 0)).y(); };
    const auto centreX = [window](QWidget *w) { return w->mapTo(window, QPoint(w->width() / 2, 0)).x(); };
    QList<QWidget *> controls;
    for (QWidget *w : std::as_const(content)) {
        if (top(w) < 27) // 40 px at 150 % on Windows
            titleBar << w;
        else
            controls << w;
    }
    std::stable_sort(controls.begin(), controls.end(), [&top](QWidget *a, QWidget *b) { return top(a) < top(b); });
    // Rows: an options arrow sits in the lower corner of its button.
    content.clear();
    for (qsizetype start = 0; start < controls.size();) {
        qsizetype end = start + 1;
        while (end < controls.size() && top(controls[end]) < top(controls[start]) + 40)
            ++end;
        QList<QWidget *> row = controls.mid(start, end - start);
        std::stable_sort(row.begin(), row.end(), [&centreX](QWidget *a, QWidget *b) { return centreX(a) < centreX(b); });
        content << row;
        start = end;
    }
}

// Qt's focus chain follows widget creation order, which in LINE puts title-bar buttons in the
// middle of a window. Order Tab stops like the widget tree (LINE's panels are built in reading
// order), with the window's title bar last.
void orderTabStops(QWidget *window)
{
    QList<QWidget *> content, titleBar;
    collectTabStops(window, content, titleBar, false);
    orderCallWindowStops(window, content, titleBar);
    // The chat folder tabs (All / Friends / Groups / ...) sit in the title bar but filter the chat
    // list: they go before the chat list's Sort button and search field.
    auto search = std::find_if(content.begin(), content.end(), [](QWidget *stop) { return isChatSortButton(stop); });
    if (search == content.end())
        search = std::find_if(content.begin(), content.end(), [](QWidget *stop) {
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
    // While replying: the message list, the reply bar (Go to the original message, Cancel reply),
    // then the message input it belongs to.
    auto lastReplyStop = std::find_if(content.rbegin(), content.rend(), [](QWidget *stop) {
        return ancestorInheriting(stop, "MessageReplyLayer") != nullptr;
    });
    auto replyInput = std::find_if(content.begin(), content.end(), [](QWidget *stop) { return isMessageInput(stop); });
    if (lastReplyStop != content.rend() && replyInput != content.end()) {
        QWidget *field = *replyInput;
        QWidget *replyStop = *lastReplyStop;
        content.erase(replyInput);
        content.insert(content.indexOf(replyStop) + 1, field);
    }
    const QList<QWidget *> order = content + titleBar;
    for (qsizetype i = 1; i < order.size(); ++i)
        QWidget::setTabOrder(order[i - 1], order[i]);
}

// ---- Reading order (VoiceOver's VO+arrows; navigation_order.h) ----------------------------------
//
// Every shown widget of a window in the order the Tab stops follow (the Windows bridge's order):
// widget tree, splitter panes as displayed, the message input bar from the input outwards, the
// buttons over the messages before the message list, the chat list panel's buttons before its Sort
// button, search field and list, and the title bar last. The chat folder tabs (in the title bar) go
// before the chat list panel: VoiceOver reads the panel as one group.

namespace {

// `w` or one of its ancestors below `top` matches `pred`.
template <typename Pred>
bool atOrUnder(QWidget *w, const QWidget *top, Pred pred)
{
    for (QWidget *p = w; p && p != top; p = p->parentWidget()) {
        if (pred(p))
            return true;
    }
    return false;
}

void collectReadingOrder(QWidget *w, QList<QWidget *> &content, QList<QWidget *> &titleBar, bool inTitleBar)
{
    inTitleBar = inTitleBar || inheritsClass(w, "LcTitleBar");
    for (QWidget *c : childWidgetsInOrder(w)) {
        if (c->isWindow() || c->isHidden())
            continue;
        QList<QWidget *> &list = inTitleBar ? titleBar : content;
        const qsizetype first = list.size();
        list << c;
        collectReadingOrder(c, content, titleBar, inTitleBar);
        if (inheritsClass(c, "MessageInputPanel"))
            std::reverse(list.begin() + first + 1, list.end());
        if (inheritsClass(c, "ChatMessageView"))
            std::stable_partition(list.begin() + first + 1, list.end(), [c](QWidget *x) {
                return !atOrUnder(x, c, [](QWidget *p) { return isLineListView(p) && !ancestorInheriting(p, "LcListView"); });
            });
        if (inheritsClass(c, "MainChatPanel")) {
            auto rank = [c](QWidget *x) {
                if (atOrUnder(x, c, [](QWidget *p) { return isLineListView(p) && !ancestorInheriting(p, "LcListView"); }))
                    return 3;
                if (atOrUnder(x, c, [](QWidget *p) { return inheritsClass(p, "QLineEdit"); }))
                    return 2;
                return atOrUnder(x, c, [](QWidget *p) { return isChatSortButton(p); }) ? 1 : 0;
            };
            std::stable_sort(list.begin() + first + 1, list.end(),
                             [&rank](QWidget *a, QWidget *b) { return rank(a) < rank(b); });
        }
    }
}

} // namespace

QHash<const QWidget *, int> readingOrderKeysIn(QWidget *window)
{
    QList<QWidget *> content, titleBar;
    collectReadingOrder(window, content, titleBar, false);
    // The folder tabs, before the chat list panel.
    const auto panel = std::find_if(content.begin(), content.end(), [](QWidget *w) { return inheritsClass(w, "MainChatPanel"); });
    if (panel != content.end()) {
        QList<QWidget *> folders;
        titleBar.removeIf([&folders](QWidget *w) {
            if (!inheritsClass(w, "TabBar") && !ancestorInheriting(w, "TabBar"))
                return false;
            folders << w;
            return true;
        });
        const qsizetype at = panel - content.begin();
        for (qsizetype i = 0; i < folders.size(); ++i)
            content.insert(at + i, folders.at(i));
    }
    const QList<QWidget *> order = content + titleBar;
    // A widget's key is its first shown leaf's place: a group is read where its first element is.
    QHash<const QWidget *, int> keys;
    for (int i = 0; i < order.size(); ++i) {
        QWidget *w = order.at(i);
        const bool leaf = std::none_of(w->children().cbegin(), w->children().cend(), [](QObject *o) {
            return o->isWidgetType() && !static_cast<QWidget *>(o)->isWindow() && !static_cast<QWidget *>(o)->isHidden();
        });
        if (!leaf)
            continue;
        for (QWidget *p = w; p && p != window; p = p->parentWidget()) {
            auto it = keys.find(p);
            if (it == keys.end())
                keys.insert(p, i);
            else if (i < *it)
                *it = i;
        }
    }
    return keys;
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
    orderCallWindowStops(window, content, titleBar);
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
        if (isMessageList(w))
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
        // The search bar of the open chat (LINE moves the chat to the matching message).
        if (ancestorInheriting(w, "ChatMessageView"))
            return QStringLiteral("search_messages");
    }
    if (const int arrow = chatSearchArrow(w); arrow != 0)
        return arrow < 0 ? QStringLiteral("search_previous") : QStringLiteral("search_next");
    if (inheritsAnyClass(w, { "LcButton", "LcImage" })) {
        const QString icon = iconBaseName(w);
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
    // Create OpenChat draws "Category" and the value over its combo box: the text at the left.
    const QRect boxRect(box->mapTo(box->window(), QPoint()), box->size());
    QWidget *inside = nullptr;
    for (QWidget *t : box->window()->findChildren<QWidget *>()) {
        if (!inheritsClass(t, "LcText") || !t->isVisible())
            continue;
        const QRect r(t->mapTo(box->window(), QPoint()), t->size());
        if (boxRect.contains(r.center()) && (!inside || r.left() < inside->mapTo(box->window(), QPoint()).x()))
            inside = t;
    }
    const QString insideText = inside ? extractLcTextString(inside) : QString();
    if (!insideText.isEmpty() && insideText != cleanText(static_cast<QComboBox *>(box)->currentText()))
        box->setAccessibleName(insideText);
    else if (const QString text = labelAboveText(box); !text.isEmpty())
        box->setAccessibleName(text);
    else if (const QString text = nearbyLabelText(box); !text.isEmpty())
        box->setAccessibleName(text);
    // The text profile editor's font list has no label at all.
    else if (inheritsClass(box->window(), "CustomProfileEditorWindow"))
        box->setAccessibleName(label("Font"));
}

void tagWidget(QWidget *w)
{
    if (inMentionSuggester(w))
        return;
    labelComboBox(w);
    // The text profile editor's colour swatches sit in a scroll area that would be a nameless stop.
    if (inheritsClass(w, "LcScrollArea") && inheritsClass(w->window(), "CustomProfileEditorWindow"))
        w->setFocusPolicy(Qt::NoFocus);
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
// The same for a Qt Quick window (Create chat -> the friend picker).
QPointer<QQuickWindow> g_quickWindowAfterMenu;
// The pressed menu item was one of a set of options (Sort: Time received / Unread).
bool g_menuOptionPressed = false;
// The chosen item was the message menu's Reply: the keyboard goes to the message input.
bool g_menuReplyPressed = false;
// Return in the chat list or Reply: for 3 s the user is going to the message input. Focus moving
// there is not LINE pulling the user out of a list, and LINE moving focus into the messages (once the
// chat has loaded) is sent on to the input. Tab, Escape, a click or a command cancel it.
QElapsedTimer g_editorFocusTimer;
QElapsedTimer g_chatOpenTimer;
QPointer<QWidget> g_chatOpenWindow;
// Shift+Return in the chat list: the row menu's "Open in new window" is pressed for the user.
QElapsedTimer g_chatWindowByKey;
bool g_openingChatByEnter = false;

bool editorFocusPending()
{
    return g_editorFocusTimer.isValid() && g_editorFocusTimer.elapsed() < 3000;
}

bool isReplyItemName(const QString &name)
{
    static const QStringList names = { QStringLiteral("Reply"), QStringLiteral("ตอบกลับ"), QStringLiteral("リプライ"),
                                       QStringLiteral("返信"), QStringLiteral("回覆"), QStringLiteral("回复") };
    return names.contains(name.trimmed());
}

bool menuPressIsRecent()
{
    return g_menuPressTimer.isValid() && g_menuPressTimer.elapsed() < 3000;
}

// A menu command was chosen a moment ago: focus moves now come from it (Reply focuses the message
// input; the menu closing first returns focus to the list), not from LINE pulling focus away from a
// list being read.
bool menuCommandJustRan()
{
    return g_menuPressTimer.isValid() && g_menuPressTimer.elapsed() < 1500;
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
    if (focus && content->isAncestorOf(focus))
        return;
    // When the pressed control went away with the old page (Create OpenChat's Next), Qt moved focus
    // to the next stop, often the title bar's Close: that was not on purpose.
    const bool movedByQt = (g_pressed && !g_pressed->isVisible()) || (focus && ancestorInheriting(focus, "LcTitleBar"));
    if (focus && focus->isVisible() && focus != g_pressed.data() && !focus->isAncestorOf(content) && !movedByQt)
        return; // LINE (or the user) already put focus somewhere on purpose
    QList<QWidget *> stops, titleBar;
    collectTabStops(content, stops, titleBar, false);
    // A page built around a list (friends, chats, search results) starts in the list.
    std::stable_partition(stops.begin(), stops.end(), [](QWidget *stop) { return isLineListView(stop); });
    // A form page (Create OpenChat's nickname) starts in its text field, whose description tells what
    // the page is for; the picture buttons come first in the Tab order.
    if (inheritsClass(content, "PagePanel"))
        std::stable_partition(stops.begin(), stops.end(), [](QWidget *stop) { return isLineInputWidget(stop); });
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
        if (g_newContent && g_newContent->isVisible() && g_newContent->window() == window)
            return; // moveFocusToNewContent() starts at the new page's own first control
        if (QWidget *first = firstContentTabStop(window))
            first->setFocus(Qt::TabFocusReason);
    });
}

// The message input of the chat shown in `window`, if any.
QWidget *messageInputIn(QWidget *window);

// In the open chat Tab / Shift+Tab go message list, (while replying) Go to the original message and
// Cancel reply, message input, then the message bar's buttons: LINE moves focus there itself on Tab
// (the reply bar's buttons went straight to the input), so the bridge does it. Null when `w` is not
// one of these or the move leaves them.
QWidget *chatTabTarget(QWidget *w, bool backward)
{
    QWidget *bar = nullptr;
    for (QWidget *candidate : w->window()->findChildren<QWidget *>()) {
        if (inheritsClass(candidate, "MessageReplyLayer") && candidate->isVisible()) {
            bar = candidate;
            break;
        }
    }
    QList<QWidget *> stops;
    for (QWidget *view : w->window()->findChildren<QWidget *>()) {
        if (isMessageList(view) && view->isVisible()) {
            stops << view;
            break;
        }
    }
    for (QObject *child : bar ? bar->children() : QObjectList()) {
        auto *stop = qobject_cast<QWidget *>(child);
        if (stop && stop->isVisible() && stop->isEnabled() && (stop->focusPolicy() & Qt::TabFocus))
            stops << stop;
    }
    if (QWidget *input = messageInputIn(w->window()); input && input->isEnabled())
        stops << input;
    if (stops.isEmpty() || !isMessageList(stops.first()) || !isMessageInput(stops.last()))
        return nullptr; // not a chat with both
    QWidget *input = stops.last();
    const qsizetype at = stops.indexOf(w);
    QWidget *afterInput = nullptr;
    for (QWidget *c = input->nextInFocusChain(); c && c != input; c = c->nextInFocusChain()) {
        if (c->window() == w->window() && c->isVisible() && c->isEnabled() && (c->focusPolicy() & Qt::TabFocus)
            && !input->isAncestorOf(c) && !(bar && bar->isAncestorOf(c)) && c != stops.first()) {
            afterInput = c;
            break;
        }
    }
    if (w == input && !backward)
        return afterInput;
    if (w == afterInput && backward)
        return input;
    const qsizetype next = backward ? at - 1 : at + 1;
    if (at < 0 || next < 0 || next >= stops.size())
        return nullptr;
    return stops.at(next);
}

// Return in the chat list / Reply: focuses the message input, waiting up to 0.8 s for it to appear.
void focusMessageEditor(QPointer<QWidget> window, int attempts = 8)
{
    if (!editorFocusPending() || !window || !window->isVisible())
        return;
    if (QWidget *input = messageInputIn(window); input && input->isEnabled() && window->isActiveWindow()) {
        input->setFocus(Qt::OtherFocusReason);
        return;
    }
    if (attempts > 0)
        QTimer::singleShot(100, window, [window, attempts] { focusMessageEditor(window, attempts - 1); });
}

// A chat opening in its own window: when it is shown (up to 5 s), the keyboard goes to its input.
void focusChatWindowInputLater()
{
    QSet<QWidget *> before;
    for (QWidget *top : QApplication::topLevelWidgets()) {
        if (inheritsClass(top, "ChatWindow") && top->isVisible())
            before.insert(top);
    }
    auto started = std::make_shared<QElapsedTimer>();
    started->start();
    auto *timer = new QTimer(qApp);
    QObject::connect(timer, &QTimer::timeout, timer, [timer, before, started] {
        QWidget *chat = nullptr;
        for (QWidget *top : QApplication::topLevelWidgets()) {
            if (inheritsClass(top, "ChatWindow") && top->isVisible() && (top->isActiveWindow() || !before.contains(top))) {
                chat = top;
                if (top->isActiveWindow())
                    break;
            }
        }
        QWidget *input = chat ? messageInputIn(chat) : nullptr;
        if (input && input->isEnabled()) {
            if (!chat->isActiveWindow())
                chat->activateWindow();
            input->setFocus(Qt::OtherFocusReason);
            g_editorFocusTimer.start();
            a11yLog("[keyboard] chat opened in its own window: focus to its message input");
        } else if (started->elapsed() < 5000) {
            return;
        }
        timer->stop();
        timer->deleteLater();
    });
    timer->start(100);
}

// Message commands in the message list: 0 Reply (Control+R), 1 Delete (Delete), 2 Unsend (Shift+
// Delete), 3 Translate (Control+T), 4 React (Control+Shift+R), 5 Save (Command+S), 6 Transcribe
// (Control+Shift+T). -1 for other keys.
// The physical key counts (Thai and other layouts), as for the other commands.
int messageCommandOf(const QKeyEvent *key)
{
    const Qt::KeyboardModifiers mods = key->modifiers() & (kAnyModifier | Qt::ShiftModifier);
    const quint32 vk = key->nativeVirtualKey();
    if (key->key() == Qt::Key_Backspace || key->key() == Qt::Key_Delete)
        return mods == Qt::NoModifier ? 1 : mods == Qt::ShiftModifier ? 2 : -1;
    if (vk == kVK_ANSI_R)
        return mods == Qt::MetaModifier ? 0 : mods == (Qt::MetaModifier | Qt::ShiftModifier) ? 4 : -1;
    if (vk == kVK_ANSI_T && mods == Qt::MetaModifier)
        return 3;
    if (vk == kVK_ANSI_T && mods == (Qt::MetaModifier | Qt::ShiftModifier))
        return 6;
    if (vk == kVK_ANSI_S && mods == Qt::ControlModifier)
        return 5;
    return -1;
}

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
    return inheritsAnyClass(w, { "LcContextMenuItem", "LcCheckableContextMenuItem", "LcCheckboxContextMenuItem" })
        || isExtraMenuItem(w);
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

// Sub-menus (LINE opens one beside an item, as a menu window of its own): the item it was opened
// from, to go back to with Left / Escape.
QHash<const QWidget *, QPointer<QWidget>> &submenuParents()
{
    static QHash<const QWidget *, QPointer<QWidget>> parents;
    return parents;
}

// Right on an item: what the mouse does to open its sub-menu (LINE opens it on hover); menuShown()
// then focuses the sub-menu's first item. Nothing happens for items without one.
void hoverMenuItem(QWidget *item)
{
    const QPointF local = QRectF(item->rect()).center();
    const QPointF scene = item->mapTo(item->window(), local);
    const QPointF global = item->mapToGlobal(local);
    item->setAttribute(Qt::WA_UnderMouse, true);
    QEnterEvent enter(local, scene, global);
    QCoreApplication::sendEvent(item, &enter);
    QMouseEvent move(QEvent::MouseMove, local, scene, global, Qt::NoButton, Qt::NoButton, Qt::NoModifier);
    QCoreApplication::sendEvent(item, &move);
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
    // "Set wallpaper" / "Background Settings" (LINE 26.6) in the languages LINE offers.
    static const QStringList kWallpaper = { QStringLiteral("วอลล์เปเปอร์"), QStringLiteral("wallpaper"),
                                            QStringLiteral("background"), QStringLiteral("พื้นหลัง"),
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
    // LineCall stacks identical one-button alerts ("No camera found ...", 8 at once seen in a video
    // call on Windows): each OK closed one, so the button seemed broken. A copy of an alert that is
    // already shown is closed with its own OK.
    if (inheritsClass(w, "AlertWindow")) {
        QPointer<QWidget> alert(w);
        QTimer::singleShot(300, w, [alert] {
            auto textOf = [](QWidget *window) {
                QStringList texts;
                for (QWidget *t : window->findChildren<QWidget *>()) {
                    if (t->isVisible() && inheritsClass(t, "LcText"))
                        texts << extractLcTextString(t);
                }
                return texts.join(QLatin1Char('\n'));
            };
            if (!alert || !alert->isVisible())
                return;
            QList<QWidget *> buttons;
            for (QWidget *b : alert->findChildren<QWidget *>()) {
                if (b->isVisible() && inheritsClass(b, "LcButton") && !b->property("source").toString().contains(QLatin1StringView("system")))
                    buttons << b;
            }
            const QString text = textOf(alert);
            if (buttons.size() != 1 || text.isEmpty())
                return;
            for (QWidget *other : QApplication::topLevelWidgets()) {
                if (other == alert || !other->isVisible() || !inheritsClass(other, "AlertWindow") || textOf(other) != text)
                    continue;
                a11yLog("[window] closed a duplicate alert");
                if (QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(buttons.first()))
                    if (QAccessibleActionInterface *action = iface->actionInterface())
                        action->doAction(QAccessibleActionInterface::pressAction());
                return;
            }
        });
    }
    // The sticker window's package strip has pictures only: read the names from "My stickers".
    if (inheritsClass(w, "StickerWindow")) {
        QPointer<QWidget> window(w);
        QTimer::singleShot(500, w, [window] {
            if (window)
                refreshStickerPackageNames(window);
        });
    }
    if (isViewerWindow(w))
        viewerShown(w);
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
    // Also from a chat in its own window: LINE's main window comes to the front first.
    if (!tab->window()->isActiveWindow())
        tab->window()->activateWindow();
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

// A call rings or is shown in this process (LINE's incoming-call notification, LineCall's window).
bool callInProgress()
{
    if (incomingCallShowing())
        return true;
    for (QWidget *top : QApplication::topLevelWidgets()) {
        if (top->isVisible() && inheritsClass(top, "CallWindow"))
            return true;
    }
    for (QWindow *w : QGuiApplication::topLevelWindows()) {
        if (w->isVisible() && w->property("mouseRollover").isValid()) // the video call window (QML)
            return true;
    }
    return false;
}

// The bridge's commands, the Windows add-on's Alt keys with Control instead (user request):
// Control+1 ... 3 / C / L / F / M / I / A / D, Control+Shift+1 ... 9. Option+Command still works the
// same (the keys of LINE MR 0.1). The physical key counts, not the character it types (Thai and other
// layouts). Qt on macOS reports Control as MetaModifier. Control+A / Control+D move to the start of
// the line / delete in text fields: they are commands only while a call rings or is shown, as Alt+A /
// Alt+D on Windows. Returns the digit (1-9), -1 for a letter command, 0 for other keys.
int commandKeyDigit(const QKeyEvent *key, bool *shift = nullptr)
{
    const Qt::KeyboardModifiers mods = key->modifiers() & (kAnyModifier | Qt::ShiftModifier);
    const bool control = mods == Qt::MetaModifier;
    const bool shiftControl = mods == (Qt::MetaModifier | Qt::ShiftModifier);
    const bool optionCommand = mods == (Qt::ControlModifier | Qt::AltModifier);
    const bool shiftOptionCommand = mods == (Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier);
    const bool command = control || optionCommand;
    const bool shiftCommand = shiftControl || shiftOptionCommand;
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
    if (control && (vk == kVK_ANSI_A || vk == kVK_ANSI_D) && !callInProgress())
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

// After a Sort option: the chat or friend list in the panel of `button`, focused, its cursor on the
// first row once LINE has re-sorted it. False if `button` is not in such a panel.
bool focusSortedListTop(QWidget *button)
{
    if (!inheritsClass(button, "LcButton"))
        return false; // a row's menu (opened from the list itself)
    QWidget *panel = ancestorInheriting(button, "MainChatPanel");
    if (!panel)
        panel = ancestorInheriting(button, "MainFriendPanel");
    if (!panel)
        return false;
    QAbstractItemView *view = nullptr;
    for (QAbstractItemView *candidate : panel->findChildren<QAbstractItemView *>()) {
        if (candidate->isVisible() && isCursorList(candidate)) {
            view = candidate;
            break;
        }
    }
    if (!view)
        return false;
    if (!view->window()->isActiveWindow())
        view->window()->activateWindow();
    view->setFocus(Qt::PopupFocusReason);
    QPointer<QAbstractItemView> guard(view);
    QTimer::singleShot(300, view, [guard] {
        if (LineAccessibleList *list = guard && guard->hasFocus() ? LineAccessibleList::listFor(guard) : nullptr)
            list->moveCursor(Qt::Key_Home);
    });
    a11yLog("[menu] closed after a sort option; focus to the top of %s",
            view->parentWidget() ? view->parentWidget()->metaObject()->className() : "the list");
    return true;
}

} // namespace

QHash<const QWidget *, int> readingOrderKeys(QWidget *window)
{
    return readingOrderKeysIn(window);
}


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

void A11yEventFilter::endBrowsing()
{
    m_browsingList = nullptr;
    g_editorFocusTimer.invalidate();
}

void armMessageInputFocus()
{
    g_editorFocusTimer.start();
}

bool preserveChatOpenScroll(const QWidget *list)
{
    return list && g_chatOpenWindow && list->window() == g_chatOpenWindow.data()
        && g_chatOpenTimer.isValid() && g_chatOpenTimer.elapsed() < 2000 && isMessageList(list);
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
    if (!pressed)
        return;
    QTimer::singleShot(450, pressed->window(), [] { moveFocusToNewContent(); });
    // The chat header's Search shows the search bar but leaves nothing focused: its field.
    if (pressed->objectName() == QLatin1StringView("lineMR_chatroom-search")) {
        QPointer<QWidget> window(pressed->window());
        for (int delay : { 300, 700 }) {
            QTimer::singleShot(delay, window, [window] {
                QWidget *focus = QApplication::focusWidget();
                if (!window || (focus && isLineInputWidget(focus)))
                    return;
                for (QWidget *field : window->findChildren<QWidget *>(QStringLiteral("lineMR_search_messages"))) {
                    if (field->isVisible()) {
                        a11yLog("[keyboard] chat search shown: focus to its field (was %s)",
                                focus ? focus->metaObject()->className() : "nothing");
                        if (!window->isActiveWindow())
                            window->activateWindow();
                        field->setFocus(Qt::OtherFocusReason);
                        break;
                    }
                }
            });
        }
    }
}

void noteMenuPress(QWidget *item, const char *how)
{
    g_menuPressTimer.start();
    g_windowAfterMenu = nullptr;
    g_quickWindowAfterMenu = nullptr;
    QAccessibleInterface *iface = item ? QAccessible::queryAccessibleInterface(item) : nullptr;
    g_menuOptionPressed = iface && iface->state().checkable;
    const QString name = iface ? iface->text(QAccessible::Name) : QString();
    g_menuReplyPressed = isReplyItemName(name);
    // A command was chosen: where LINE moves the keyboard now is meant (Reply focuses the message
    // input), not LINE pulling focus away from the list being read (the bridge sent it back).
    endListBrowsing();
    if (g_menuReplyPressed) {
        g_editorFocusTimer.start();
    } else if (g_chatWindowByKey.isValid() && g_chatWindowByKey.elapsed() < 3000) {
        g_chatWindowByKey.invalidate();
        focusChatWindowInputLater();
    }
    a11yLog("[menu] pressed \"%s\" (%s)", qUtf8Printable(name), how);
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

void noteMediaOpenedFrom(QWidget *window)
{
    g_mediaReturnWindow = window;
    g_mediaReturnTimer.start();
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
        && m_listKeyTimer.elapsed() < 5000 && isInOpenChat(w) && !menuCommandJustRan();
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
            if (event->type() == QEvent::Show) {
                if (menuPressIsRecent()) {
                    a11yLog("[menu] after the press: %s shown", window->metaObject()->className());
                    g_quickWindowAfterMenu = window;
                }
                quickWindowShown(window);
            } else if (event->type() == QEvent::KeyPress) {
                auto *key = static_cast<QKeyEvent *>(event);
                if (handleCommandKey(nullptr, key)) {
                    key->accept();
                    return true;
                }
                // Held arrows repeat (lists); held Space / Return must not click again.
                const bool repeats = key->key() == Qt::Key_Up || key->key() == Qt::Key_Down
                    || key->key() == Qt::Key_PageUp || key->key() == Qt::Key_PageDown;
                if ((!key->isAutoRepeat() || repeats) && !(key->modifiers() & kAnyModifier) && handleQuickKey(window, key->key())) {
                    key->accept();
                    return true;
                }
            }
        }
        return false;
    }
    auto *w = static_cast<QWidget *>(watched);
    // LINE's @ mention suggestions are LINE's own (focus, keys). While they show, the message input's
    // keys go to LINE's filters too: Up / Down / Return choose a member there.
    switch (event->type()) {
    case QEvent::Polish:
    case QEvent::Show:
    case QEvent::FocusIn:
    case QEvent::KeyPress:
    case QEvent::KeyRelease:
        if (inMentionSuggester(w)
            || ((event->type() == QEvent::KeyPress || event->type() == QEvent::KeyRelease) && isMessageInput(w)
                && mentionSuggesterShown(w))) {
            if (event->type() == QEvent::FocusIn || event->type() == QEvent::KeyPress) {
                m_browsingList = nullptr;
                g_editorFocusTimer.invalidate();
            }
            return false;
        }
        break;
    default:
        break;
    }
    switch (event->type()) {
    case QEvent::Polish:
        repairCachedInterface(w);
        break;
    case QEvent::Show:
        handleShow(w);
        break;
    case QEvent::Hide:
        if (isContextMenu(w))
            removeExtraMenuItems(w);
        if (isContextMenu(w) && w == m_menu.data()) {
            // A sub-menu closed while its menu stays open: back to the item it was opened from.
            QPointer<QWidget> parent = submenuParents().take(w);
            QWidget *parentMenu = parent ? contextMenuOf(parent) : nullptr;
            if (parentMenu && parentMenu->isVisible()) {
                m_menu = parentMenu;
                QPointer<QWidget> item = parent;
                QTimer::singleShot(0, parentMenu, [item, parentMenu = QPointer<QWidget>(parentMenu)] {
                    if (!parentMenu || !parentMenu->isVisible())
                        return;
                    if (item && item != parentMenu.data())
                        focusMenuItem(item);
                    else if (const QList<QWidget *> items = menuItems(parentMenu); !items.isEmpty())
                        focusMenuItem(items.first());
                });
            } else {
                menuHidden();
            }
        }
        if (isViewerWindow(w))
            w->setProperty("_lineA11yPlayerFocused", false);
        // Photos & videos: Cancel in the selection bar hides the bar, and Qt moved focus to the title
        // bar. Back to the grid the photos were ticked in.
        if (inheritsClass(w, "LcImage") && ancestorInheriting(w, "MediaListPanel")) {
            QPointer<QWidget> bar(w);
            QTimer::singleShot(150, w, [bar] {
                QWidget *focus = QApplication::focusWidget();
                if (!bar || bar->isVisible() || !bar->window()->isActiveWindow()
                    || (focus && focus->isVisible() && !ancestorInheriting(focus, "LcTitleBar")))
                    return;
                for (QAbstractItemView *grid : ancestorInheriting(bar, "MediaListPanel")->findChildren<QAbstractItemView *>()) {
                    if (grid->isVisible() && isLineListView(grid)) {
                        grid->setFocus(Qt::OtherFocusReason);
                        return;
                    }
                }
            });
        }
        break;
    case QEvent::WindowActivate:
        // Back from the media viewer: LINE activates its main window, not the Notes window the photo
        // / video was opened from.
        if (g_mediaReturnWindow && w->isWindow() && !isViewerWindow(w)) {
            QPointer<QWidget> back = g_mediaReturnWindow;
            g_mediaReturnWindow = nullptr;
            if (w != back && g_mediaReturnTimer.elapsed() < 600000) {
                a11yLog("[viewer] %s activated after the viewer: back to %s", w->metaObject()->className(),
                        back->metaObject()->className());
                QTimer::singleShot(0, back, [back] {
                    if (back && back->isVisible()) {
                        back->raise();
                        back->activateWindow();
                    }
                });
            }
        }
        handleWindowActivate(w);
        break;
    case QEvent::FocusIn:
        handleFocusIn(w, static_cast<QFocusEvent *>(event)->reason());
        break;
    case QEvent::MouseButtonPress:
        if (!g_openingChatByEnter)
            g_chatOpenTimer.invalidate();
        if (event->spontaneous()) {
            g_editorFocusTimer.invalidate(); // not the bridge's own clicks (opening a chat, menu items)
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
        // of LINE's current row (see LineAccessibleList::openRowMenu / openCursorMenu); in the photo
        // grids and Notes the bridge's own menu.
        if (static_cast<QContextMenuEvent *>(event)->reason() == QContextMenuEvent::Keyboard
            && (isCursorList(w) || isMessageList(w) || isContentList(w) || isPostList(w))) {
            if (m_cursorMenuKey.isValid() && m_cursorMenuKey.elapsed() < 1000)
                return true; // the key press already opened it
            if (LineAccessibleList *list = LineAccessibleList::listFor(w)) {
                if (isMessageList(w) ? list->openRowMenu()
                    : isContentList(w) || isPostList(w) ? list->openContentMenu() : list->openCursorMenu())
                    return true;
            }
        }
        break;
    case QEvent::ShortcutOverride: {
        // The bridge's commands must reach the key press (LINE's shortcuts would take them), and so
        // must the video player's keys (LINE's viewer: Right = next photo, Space).
        auto *key = static_cast<QKeyEvent *>(event);
        if (isCommandKey(key) || (isVideoWidget(w) && videoWantsShortcut(w, key))
            || (isMessageList(w) && messageCommandOf(key) >= 0)) {
            event->accept();
            return true;
        }
        // LINE for macOS has window shortcuts for keys the bridge handles itself (Escape closes the
        // open chat): in its menus and the reaction picker they must reach the key press.
        if (plainKey(key) && (contextMenuOf(w) || ancestorInheriting(w, "ReactionDockWidget"))) {
            switch (key->key()) {
            case Qt::Key_Escape:
            case Qt::Key_Up:
            case Qt::Key_Down:
            case Qt::Key_Left:
            case Qt::Key_Right:
            case Qt::Key_Home:
            case Qt::Key_End:
            case Qt::Key_Return:
            case Qt::Key_Enter:
            case Qt::Key_Space:
                event->accept();
                return true;
            default:
                break;
            }
        }
        break;
    }
    case QEvent::KeyPress:
        // One Tab, one step. LINE's widgets leave Tab unaccepted after Qt has moved the focus, so
        // QApplication::notify passed it on to every parent (TabButton, LcScrollArea, TabBar,
        // LcTitleBar, the window), and each moved the focus again: a press jumped 6 to 12 controls
        // (seen 2026-11-03). The first widget's move stands; the parents get nothing.
        if (const auto *key = static_cast<QKeyEvent *>(event);
            key->key() == Qt::Key_Tab || key->key() == Qt::Key_Backtab) {
            static const QEvent *tabEvent = nullptr;
            static QPointer<QWidget> tabTarget;
            static QPointer<QWidget> focusBefore;
            const bool passedOn = !event->spontaneous() && event == tabEvent && tabTarget && w != tabTarget.data()
                && w->isAncestorOf(tabTarget);
            // (A widget that ignored Tab without moving the focus leaves it to its parents, as before.)
            if (passedOn && QApplication::focusWidget() != focusBefore.data()) {
                event->accept();
                return true;
            }
            if (!passedOn) {
                tabEvent = event;
                tabTarget = w;
                focusBefore = QApplication::focusWidget();
            }
        }
        // Qt passes a key on to the parent widgets unless it was accepted, even when a filter took
        // it: Escape in the reaction picker then reached LINE's chat panel, which closed the chat.
        if (handleKeyPress(w, static_cast<QKeyEvent *>(event))) {
            event->accept();
            return true;
        }
        break;
    default:
        break;
    }
    return QObject::eventFilter(watched, event);
}

bool A11yEventFilter::handleKeyPress(QWidget *w, QKeyEvent *key)
{
    g_chatOpenTimer.invalidate();
    if (key->key() == Qt::Key_Tab || key->key() == Qt::Key_Backtab || key->key() == Qt::Key_Escape)
        g_editorFocusTimer.invalidate(); // the user goes elsewhere
    if ((key->key() == Qt::Key_Tab || key->key() == Qt::Key_Backtab) && !(key->modifiers() & kAnyModifier)) {
        const bool backward = key->key() == Qt::Key_Backtab || (key->modifiers() & Qt::ShiftModifier);
        if (QWidget *target = chatTabTarget(w, backward)) {
            m_browsingList = nullptr; // the user leaves the list on purpose
            target->setFocus(backward ? Qt::BacktabFocusReason : Qt::TabFocusReason);
            return true;
        }
    }
    if (handleCommandKey(w, key))
        return true;
    // Reply, Delete, Unsend, Translate, React and Save on the message read last.
    if (isMessageList(w)) {
        if (const int command = messageCommandOf(key); command >= 0) {
            if (!key->isAutoRepeat()) {
                markUserActivity();
                if (LineAccessibleList *list = LineAccessibleList::listFor(w)) {
                    if (command == 6)
                        list->transcribeMessage(list->cursorRow());
                    else if (command == 5)
                        list->saveMessage();
                    else
                        list->openMessageCommand(command);
                }
            }
            return true;
        }
    }
    // The video player's keys (Play / Pause, seeking; video_controls.h).
    if (isVideoWidget(w) && handleVideoKey(w, key))
        return true;
    if (isStickerItem(w) && plainKey(key)
        && (key->key() == Qt::Key_Left || key->key() == Qt::Key_Right || key->key() == Qt::Key_Up || key->key() == Qt::Key_Down)
        && moveInStickerGrid(w, key->key()))
        return true;
    if (QWidget *menu = contextMenuOf(w); menu && menu->isVisible() && handleMenuKey(menu, key))
        return true;
    // LINE's reaction picker (opened by the message menu's "React"): the arrows move between the
    // reactions, Escape closes it (focus goes back to the message).
    if (QWidget *dock = ancestorInheriting(w, "ReactionDockWidget"); dock && w->hasFocus() && plainKey(key)) {
        if (key->key() == Qt::Key_Escape) {
            dock->hide();
            return true;
        }
        if (isActivationKey(key)) {
            if (!key->isAutoRepeat()) {
                const bool signal = line_a11y::isSignalConnected(w, "clicked()");
                a11yLog("[reaction] chose \"%s\" (%s)", qUtf8Printable(w->accessibleName()), signal ? "clicked()" : "click");
                if (signal)
                    QMetaObject::invokeMethod(w, "clicked");
                else
                    sendMouseClick(w);
            }
            return true;
        }
        QList<QWidget *> choices;
        for (QWidget *c : dock->findChildren<QWidget *>()) {
            if (c->isVisible() && c->property(kMadeFocusableProperty).toBool())
                choices << c;
        }
        std::sort(choices.begin(), choices.end(), [dock](QWidget *a, QWidget *b) {
            return a->mapTo(dock, QPoint()).x() < b->mapTo(dock, QPoint()).x();
        });
        const qsizetype at = choices.indexOf(w);
        qsizetype to = -1;
        if (key->key() == Qt::Key_Left || key->key() == Qt::Key_Up)
            to = at - 1;
        else if (key->key() == Qt::Key_Right || key->key() == Qt::Key_Down)
            to = at + 1;
        else if (key->key() == Qt::Key_Home)
            to = 0;
        else if (key->key() == Qt::Key_End)
            to = choices.size() - 1;
        if (at >= 0 && to != -1) {
            if (to >= 0 && to < choices.size())
                choices.at(to)->setFocus(Qt::TabFocusReason);
            return true;
        }
    }
    // The chat's search field (Return, Up / Down) and its Previous / Next result buttons: say where
    // LINE moved to.
    if (!key->isAutoRepeat() && !(key->modifiers() & kAnyModifier)
        && ((w->objectName() == QLatin1StringView("lineMR_search_messages")
             && (key->key() == Qt::Key_Up || key->key() == Qt::Key_Down || key->key() == Qt::Key_Return
                 || key->key() == Qt::Key_Enter))
            || (chatSearchArrow(w) != 0 && isActivationKey(key))))
        reportSearchResultAfterKey(w);
    // Command+S in the photo / video viewer saves what it shows (LINE shows Download only while the
    // mouse is over the picture).
    if (key->key() == Qt::Key_S && (key->modifiers() & kAnyModifier) == Qt::ControlModifier && !key->isAutoRepeat()
        && isViewerWindow(w->window()) && saveViewerMedia(w->window()))
        return true;
    // LINE's own application event filters switch to the previous / next chat on Up/Down in the
    // message input: the input gets them directly instead (normally earlier, in earlyKeyHook()).
    if (isMessageInputArrow(w, key)) {
        passArrowToMessageInput(w, key);
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
    const bool messages = isMessageList(w);
    LineAccessibleList *list = isLineListView(w) ? LineAccessibleList::listFor(w) : nullptr;
    // Notes: LINE's arrows move from a row of its own (Return then hit another post) and stop on the
    // blank row behind the search field: the bridge steps through the posts itself.
    if (list && isPostList(w) && isListNavigationKey(key->key()) && plainKey(key)) {
        if (key->key() == Qt::Key_Home || key->key() == Qt::Key_End
            || !static_cast<QAbstractItemView *>(w)->currentIndex().isValid())
            list->focusEdgeRow(key->key() == Qt::Key_End);
        else
            list->stepRow(key->key());
        return true;
    }
    if (list && isContentList(w) && plainKey(key)) {
        if ((isListNavigationKey(key->key()) || key->key() == Qt::Key_Left || key->key() == Qt::Key_Right)
            && list->moveGridCursor(key->key()))
            return true;
        // Space in Photos & videos ticks the item (several can then be downloaded or shared at once);
        // Return opens it.
        if (!key->isAutoRepeat() && key->key() == Qt::Key_Space && list->toggleMediaTick())
            return true;
        // Space / Return: what a click does (a photo or video opens in LINE's viewer; a sticker
        // package shows its stickers, and the first one takes focus).
        if (!key->isAutoRepeat()
            && (key->key() == Qt::Key_Space || key->key() == Qt::Key_Return || key->key() == Qt::Key_Enter)
            && list->clickCursorRow()) {
            if (inheritsClass(w->window(), "StickerWindow")) {
                QPointer<QWidget> window(w->window());
                QTimer::singleShot(400, window, [window] {
                    if (!window)
                        return;
                    QWidget *first = nullptr;
                    for (QWidget *item : window->findChildren<QWidget *>()) {
                        if (item->isVisible() && isStickerItem(item)
                            && (!first || item->mapTo(window, QPoint()).y() < first->mapTo(window, QPoint()).y()
                                || (item->mapTo(window, QPoint()).y() == first->mapTo(window, QPoint()).y()
                                    && item->mapTo(window, QPoint()).x() < first->mapTo(window, QPoint()).x())))
                            first = item;
                    }
                    if (first)
                        first->setFocus(Qt::OtherFocusReason);
                });
            }
            return true;
        }
    }
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
        // Messages: never left to LINE. LINE acts on a row it keeps itself, which is not the one read
        // (Return on a sticker opened its package in the store).
        if (messages) {
            if (!key->isAutoRepeat() && !list->activateMessage())
                a11yLog("[keyboard] message row %d: nothing to open", list->cursorRow());
            return true;
        }
        if (!key->isAutoRepeat() && (list->openSearchResult() || list->toggleCursorRow() || list->openPostMedia()))
            return true;
    }
    // The menu key (PC keyboards) or Shift+F10 on a message / a chat or friend list row: its menu.
    const bool menuKey = key->key() == Qt::Key_Menu
        || (key->key() == Qt::Key_F10 && (key->modifiers() & Qt::ShiftModifier));
    if (list && menuKey && !key->isAutoRepeat() && (messages || isCursorList(w) || isContentList(w) || isPostList(w))) {
        if (messages ? list->openRowMenu()
            : isContentList(w) || isPostList(w) ? list->openContentMenu() : list->openCursorMenu()) {
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
        } else if ((key->key() == Qt::Key_Return || key->key() == Qt::Key_Enter || key->key() == Qt::Key_Space)
                   && !(key->modifiers() & (Qt::ControlModifier | Qt::AltModifier))) {
            if (key->isAutoRepeat())
                return true;
            // Shift+Return: the chat in its own window (its menu's "Open in new window"), then its
            // input. With the chat room hidden LINE's menu has no such item: there Return does it.
            if (!friendList && key->key() != Qt::Key_Space && (key->modifiers() & Qt::ShiftModifier)
                && !chatRoomHidden(w->window())) {
                m_browsingList = nullptr;
                // Armed first: the menu is pressed and the window shown inside LINE's menu loop.
                g_chatWindowByKey.start();
                if (!list->openCursorRowInNewWindow())
                    g_chatWindowByKey.invalidate();
                return true;
            }
            // Friends: click the row and let LINE decide (a section header folds, a friend's chat
            // opens and LINE moves focus there itself).
            if (friendList) {
                if (list->openCursorRow()) {
                    m_browsingList = nullptr;
                    return true;
                }
                return false;
            }
            // Return: open the chat under the cursor, go to it and start typing (once LINE shows it:
            // its message input is built afresh for each chat).
            const int row = list->cursorRow();
            const bool roomHidden = chatRoomHidden(w->window());
            // Armed before the synthetic click: opening can focus the messages at once.
            g_chatOpenWindow = w->window();
            g_chatOpenTimer.start();
            m_browsingList = nullptr;
            if (roomHidden) {
                // A click only selects the row there: LINE opens the chat in its own window.
                if (list->openCursorRow(true))
                    focusChatWindowInputLater();
                return true;
            }
            const bool opened = [&] {
                QScopedValueRollback<bool> opening(g_openingChatByEnter, true);
                return list->openCursorRow();
            }();
            g_editorFocusTimer.start();
            if (opened) {
                list->focusInputWhenOpened(row);
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
    // Control+Shift+1 ... 9: read a recent message (1 = newest) without moving.
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
        if (QWidget *messages = taggedWidget(QStringLiteral("list_messages"))) {
            // Already there no focus event follows: back to the newest message all the same.
            if (messages->hasFocus()) {
                if (LineAccessibleList *list = LineAccessibleList::listFor(messages))
                    list->focusEdgeRow(true);
            }
            focusWidget(messages, Qt::OtherFocusReason);
        }
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
        // The video call window (QML) hides its End call button while the mouse is elsewhere: ended
        // like its End call confirmation does.
        if (incomingCallShowing() || !endQuickCall())
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
    case Qt::Key_Right: {
        // Opens the focused item's sub-menu, if it has one.
        QWidget *item = QApplication::focusWidget();
        if (item && isContextMenuItem(item) && !isExtraMenuItem(item) && contextMenuOf(item) == menu && !key->isAutoRepeat())
            hoverMenuItem(item);
        return true;
    }
    case Qt::Key_Left:
    case Qt::Key_Escape:
        // In a sub-menu: back to the item it belongs to (the menu stays open); else Escape closes.
        if (submenuParents().value(menu)) {
            menu->hide();
            return true;
        }
        if (key->key() == Qt::Key_Escape)
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
    // (Armed for up to 2 minutes while LINE downloads a video: never to catch a later Save as.)
    if (w->isWindow() && inheritsClass(w, "AlertWindow"))
        stopAwaitingSavePanel();
    // Their stops were made focusable the first time; the order may have changed since.
    if (inheritsClass(w, "MessageReplyLayer") || (inheritsClass(w, "LcImage") && ancestorInheriting(w, "MediaListPanel")))
        orderTabStops(w->window());
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
    if (isVideoWidget(w))
        videoWidgetFocused(w);
    if (isCursorList(w) && w != m_browsingList.data()) {
        if (LineAccessibleList *list = LineAccessibleList::listFor(w))
            list->resetCursor();
    }
    // Notes: start on a post, not on the blank row behind the search field.
    if (isPostList(w)) {
        QPointer<QWidget> view(w);
        QTimer::singleShot(0, w, [view] {
            LineAccessibleList *list = LineAccessibleList::listFor(view);
            const QModelIndex current = view ? static_cast<QAbstractItemView *>(view.data())->currentIndex() : QModelIndex();
            QAccessibleInterface *item = list && current.isValid() ? list->itemAt(current.row()) : nullptr;
            if (list && (!item || item->text(QAccessible::Name).isEmpty()))
                list->focusEdgeRow(false);
        });
    }
    // Return in the chat list / Reply: LINE moves focus into the messages once the chat has loaded
    // (or the closed menu gives it back): on to the message input.
    if (isMessageList(w) && editorFocusPending() && reason != Qt::TabFocusReason && reason != Qt::BacktabFocusReason
        && reason != Qt::MouseFocusReason) {
        m_browsingList = nullptr;
        const QPointer<QWidget> window(w->window());
        QTimer::singleShot(0, this, [window] { focusMessageEditor(window); });
        return;
    }
    if (isMessageList(w) && preserveChatOpenScroll(w)) {
        m_browsingList = nullptr;
        return;
    }
    if (isMessageInput(w) && editorFocusPending())
        m_browsingList = nullptr;
    if (isMessageList(w)) {
        // Entering the messages (Tab, Control+M) starts at the newest one; Shift+Tab stays where the
        // chat is scrolled to; coming back
        // (focus sent back by the bridge, menu closed, window activated, click) keeps the place, and
        // after a search LINE's current row is the match: start there.
        const bool returning = (w == m_browsingList.data() && m_listKeyTimer.isValid() && m_listKeyTimer.elapsed() < 5000)
            || reason == Qt::PopupFocusReason || reason == Qt::ActiveWindowFocusReason || reason == Qt::MouseFocusReason
            || chatSearchShowsResult(w);
        if (LineAccessibleList *list = LineAccessibleList::listFor(w)) {
            // Tab back into the same chat: the message last read.
            const bool tab = reason == Qt::TabFocusReason;
            if (reason == Qt::BacktabFocusReason)
                list->focusVisibleRowOnBacktab();
            else if (returning)
                list->focusLastVisibleRow();
            else if (!tab || !list->focusRememberedRow())
                list->focusEdgeRow(true);
        }
        // LINE hands focus on from the message list to the message input; reading messages needs it
        // to stay (Tab still moves on).
        if (!menuCommandJustRan()) {
            m_browsingList = w;
            m_listKeyTimer.start();
        }
    }
    // Arrowing through the chat list opens each chat, and once it has loaded (up to a few seconds
    // later) LINE moves focus into the chat: keep the user in the list instead.
    if (m_browsingList && m_browsingList->isVisible() && w != m_browsingList.data() && isInOpenChat(w)
        && m_listKeyTimer.isValid() && m_listKeyTimer.elapsed() < 5000 && !menuCommandJustRan()) {
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
    // A sub-menu opened from an item of the menu shown (Right, Return or a hover).
    if (m_menu && m_menu != menu && m_menu->isVisible()) {
        QWidget *parentItem = focus && contextMenuOf(focus) == m_menu.data() ? focus : nullptr;
        submenuParents().insert(menu, parentItem ? parentItem : m_menu.data());
        a11yLog("[menu] sub-menu %s opened from \"%s\"", menu->metaObject()->className(),
                parentItem && QAccessible::queryAccessibleInterface(parentItem)
                    ? qUtf8Printable(QAccessible::queryAccessibleInterface(parentItem)->text(QAccessible::Name)) : "");
    }
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
        // A message's menu opened from the keyboard: the bridge's React / Show <sender>'s profile.
        addProfileMenuItem(guard);
        const QList<QWidget *> items = menuItems(guard);
        // The bridge opened this menu to choose an item itself (a file's "Save as...").
        if (QWidget *choice = takePendingMenuChoice(items)) {
            pressMenuItem(choice);
            return;
        }
        if (!items.isEmpty())
            focusMenuItem(items.first());
        // The menu window becomes active a moment later and Qt may then give the focus to the menu
        // itself (seen with VoiceOver's VO+Shift+M): back on the item.
        QTimer::singleShot(250, guard, [guard] {
            QWidget *focus = QApplication::focusWidget();
            if (!guard || !guard->isVisible() || (focus && focus != guard.data() && contextMenuOf(focus) == guard.data()))
                return;
            if (const QList<QWidget *> again = menuItems(guard); !again.isEmpty())
                focusMenuItem(again.first());
        });
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
        if (g_quickWindowAfterMenu && g_quickWindowAfterMenu->isVisible()) {
            a11yLog("[menu] closed; %s keeps the focus", g_quickWindowAfterMenu->metaObject()->className());
            g_quickWindowAfterMenu->requestActivate();
            return;
        }
        // A Sort option: LINE re-sorts the chat (or friend) list beside the Sort button, which looked
        // the same from the button. Go to the list's top so the new order is heard.
        if (g_menuOptionPressed && g_menuPressTimer.isValid() && g_menuPressTimer.elapsed() < 3000) {
            g_menuOptionPressed = false;
            if (focusSortedListTop(back))
                return;
        }
        QWidget *window = back->window();
        QWidget *target = window->focusWidget();
        if (!target || !target->isVisible() || contextMenuOf(target))
            target = back;
        // Reply: straight to the message input, under LINE's reply bar (user request 2026-11-03).
        if (g_menuReplyPressed && g_menuPressTimer.isValid() && g_menuPressTimer.elapsed() < 3000) {
            g_menuReplyPressed = false;
            if (QWidget *input = messageInputIn(window))
                target = input;
        }
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

namespace {

// QInternal::EventNotifyCallback: Qt calls it in QCoreApplication::notifyInternal2(), before any
// application or object event filter. The bridge's application filter is put back in front of LINE's
// only once a second (watchdogTick()), so for up to a second after LINE installs a filter of its own
// LINE saw Up / Down in the message input first and switched chats ("sometimes" while writing a long
// message, user report 2026-11-03). The key is caught here at both stages of its delivery: the
// QWidgetWindow (where application filters already see it) and the focused input.
bool earlyKeyHook(void **data)
{
    auto *event = static_cast<QEvent *>(data[1]);
    if (event->type() != QEvent::KeyPress && event->type() != QEvent::ShortcutOverride)
        return false;
    auto *receiver = static_cast<QObject *>(data[0]);
    QWidget *input = nullptr;
    if (receiver->isWidgetType()) {
        input = static_cast<QWidget *>(receiver);
    } else if (receiver->isWindowType()) {
        QWidget *focus = QApplication::focusWidget();
        if (!focus || focus->window()->windowHandle() != receiver)
            return false;
        input = focus;
    } else {
        return false;
    }
    auto *key = static_cast<QKeyEvent *>(event);
    // The bridge's commands: before any of LINE's filters, which sometimes took them (LINE installs
    // application filters of its own; the bridge's goes back in front only at the next watchdog tick).
    if (g_filter && (isCommandKey(key) || (isMessageList(input) && messageCommandOf(key) >= 0))) {
        if (event->type() == QEvent::KeyPress) {
            if (event->spontaneous())
                markUserActivity();
            a11yLog("[command] key 0x%x, modifiers 0x%x, in %s", key->key(), uint(key->modifiers()), input->metaObject()->className());
            if (!g_filter->keyPressFromHook(input, key))
                return false;
            key->accept();
        } else {
            event->accept();
        }
        *static_cast<bool *>(data[2]) = true;
        return true;
    }
    if (!isMessageInputArrow(input, key))
        return false;
    // ShortcutOverride accepted: no window or application shortcut takes the key.
    if (event->type() == QEvent::KeyPress) {
        if (event->spontaneous())
            markUserActivity();
        passArrowToMessageInput(input, key);
    } else {
        event->accept();
    }
    *static_cast<bool *>(data[2]) = true;
    return true;
}

} // namespace

void installEarlyKeyHook()
{
    static bool installed = false;
    if (installed)
        return;
    installed = QInternal::registerCallback(QInternal::EventNotifyCallback, earlyKeyHook);
    a11yLog("[keyboard] early key hook %s", installed ? "installed" : "NOT installed");
}

} // namespace line_a11y
