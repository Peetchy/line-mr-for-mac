#include "accessible_list.h"

#include "a11y_EventFilter.h"
#include "a11y_announce.h"
#include "a11y_log.h"
#include "a11y_update_filter.h"
#include "accessible_widgets.h"
#include "line_introspect.h"
#include "qt_signal_utils.h"
#include "text_capture.h"
#include "text_recognition.h"

#include <QtCore/QAbstractItemModel>
#include <QtCore/QCoreApplication>
#include <QtCore/QDateTime>
#include <QtCore/QElapsedTimer>
#include <QtCore/QItemSelectionModel>
#include <QtCore/QMetaMethod>
#include <QtCore/QMetaProperty>
#include <QtCore/QRegularExpression>
#include <QtCore/QSet>
#include <QtCore/QTimer>
#include <QtCore/QUrl>
#include <QtGui/QEnterEvent>
#include <QtGui/QContextMenuEvent>
#include <QtGui/QImage>
#include <QtGui/QMouseEvent>
#include <QtGui/QTextDocumentFragment>
#include <QtGui/QPalette>
#include <QtGui/QPixmap>
#include <QtGui/QWindow>
#include <QtWidgets/QAbstractItemView>
#include <QtWidgets/QApplication>
#include <QtWidgets/QScrollBar>
#include <QtWidgets/QStyleOptionViewItem>

#include <algorithm>

namespace line_a11y {
namespace {

constexpr const char *kCacheObjectName = "_lineA11yRowTextCache";
constexpr const char *kCurrentIndexSignal = "currentIndexChanged()";
constexpr int kItemDataRole = Qt::UserRole + 1; // MultipleSectionListModel / LcSimpleListModel "itemData"

// ---- Row text from the model's data object ------------------------------------------------------

// LINE's list models hand out one QObject per row (ChatData, ...). Most expose the row's content as
// Q_PROPERTYs, which is both cheaper and more reliable than reading the painted delegate.
int propertyPriority(const QByteArray &name)
{
    static const char *const groups[][8] = {
        { "name", "displayName", "title", "senderName", "nickname", "userName", "fromName", nullptr },
        { "memberCount", "count", nullptr },
        { "lastMessage", "text", "message", "content", "statusMessage", "description", "subtitle", nullptr },
        { "lastUpdatedTimeForUI", "time", "timeText", "date", "dateText", "createdTime", "elapsedTime", nullptr },
        { "unreadCount", "badgeCount", "newCount", nullptr },
    };
    for (int g = 0; g < int(std::size(groups)); ++g) {
        for (const char *const *n = groups[g]; *n; ++n) {
            if (name == *n)
                return g;
        }
    }
    return 2; // unknown text-like properties sit with the content
}

bool isIdentifierProperty(const QByteArray &name)
{
    static const char *const suffixes[] = { "Id", "Source", "Path", "Url", "URL", "Uri", "Image", "Icon", "Color",
                                            "Key", "WithoutQuery", "Query", "Time" };
    // "mid" is LINE's internal user / group id; "elapsedTime" duplicates lastUpdatedTimeForUI.
    if (name == "id" || name == "mid" || name == "objectName" || name == "section" || name == "sectionId"
        || name == "type" || name == "status")
        return true;
    if (name == "lastUpdatedTimeForUI")
        return false;
    for (const char *suffix : suffixes) {
        if (name.endsWith(suffix))
            return true;
    }
    return false;
}

QString countPhrase(const QByteArray &name, int value)
{
    if (value <= 0)
        return QString();
    if (name == "memberCount")
        return value == 1 ? label("1 member") : label("%1 members").arg(value);
    if (name == "count") // SectionData: number of entries under a section header
        return QString::number(value);
    if (name == "unreadCount" || name == "badgeCount" || name == "newCount") {
        const QString n = value > 999 ? QStringLiteral("999+") : QString::number(value);
        return label("%1 unread").arg(n);
    }
    return QString();
}

QString dataObjectText(const QObject *data)
{
    if (!data)
        return QString();
    struct Part {
        int priority;
        int order;
        QString text;
    };
    QList<Part> parts;
    const QMetaObject *mo = data->metaObject();
    const int first = QObject::staticMetaObject.propertyCount();
    for (int i = first; i < mo->propertyCount(); ++i) {
        const QMetaProperty prop = mo->property(i);
        const QByteArray name = prop.name();
        if (isIdentifierProperty(name))
            continue;
        const QVariant v = prop.read(data);
        QString text;
        if (v.metaType().id() == QMetaType::QString)
            text = cleanText(v.toString());
        else if (v.metaType().id() == QMetaType::Int)
            text = countPhrase(name, v.toInt());
        if (!text.isEmpty())
            parts.append({ propertyPriority(name), i, text });
    }
    std::stable_sort(parts.begin(), parts.end(), [](const Part &a, const Part &b) {
        return a.priority != b.priority ? a.priority < b.priority : a.order < b.order;
    });
    QStringList texts;
    for (const Part &p : std::as_const(parts)) {
        if (!texts.contains(p.text))
            texts << p.text;
    }
    return texts.join(QLatin1StringView(", "));
}

// Visible texts of a delegate widget. Chat message rows are reordered from their visual layout
// (time and read receipt sit beside the bubble) to sender, content, time, receipt.
QString delegateText(QWidget *delegate)
{
    const QString cls = QLatin1StringView(delegate->metaObject()->className());
    const bool sent = cls.startsWith(QLatin1StringView("ChatSend"));
    if (!sent && !cls.startsWith(QLatin1StringView("ChatRecv")))
        return collectVisibleChildTexts(delegate);

    static const QRegularExpression time(QStringLiteral("^\\d{1,2}:\\d{2}(\\s?[AaPp][Mm])?$"));
    static const QRegularExpression receipt(QStringLiteral("^Read( \\d+)?$"));
    QStringList content, trailing;
    for (const PositionedText &item : collectPositionedChildTexts(delegate)) {
        const QString text = item.text.trimmed();
        if (text.isEmpty() || content.contains(text) || trailing.contains(text))
            continue;
        (time.match(text).hasMatch() || receipt.match(text).hasMatch() ? trailing : content) << text;
    }
    if (content.isEmpty() && trailing.isEmpty())
        return QString();
    if (sent)
        content.prepend(label("You"));
    return (content + trailing).join(QLatin1StringView(", "));
}

// ---- Chat messages ----------------------------------------------------------------------------

struct Contact {
    QString name;
    bool self = false;
};

// LINE user id -> display name, from the data objects of every list model (friend list, groups,
// chat list). ProfileData is the logged-in user. Rebuilt at most every few seconds.
Contact contactForMid(const QString &mid)
{
    static QHash<QString, Contact> contacts;
    static qint64 builtAt = 0;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - builtAt > 5000) {
        builtAt = now;
        contacts.clear();
        for (QWidget *top : QApplication::topLevelWidgets()) {
            for (QAbstractItemView *view : top->findChildren<QAbstractItemView *>()) {
                QAbstractItemModel *model = view->model();
                if (!model || !isLineListView(view))
                    continue;
                for (int r = 0, n = model->rowCount(); r < n; ++r) {
                    QObject *o = model->index(r, 0).data(kItemDataRole).value<QObject *>();
                    if (!o)
                        continue;
                    QString id = o->property("mid").toString();
                    QString name = cleanText(o->property("displayName").toString());
                    // ChatData of a 1:1 chat: the chat id is the partner's user id.
                    if (id.isEmpty() && inheritsClass(o, "ChatData")) {
                        id = o->property("id").toString();
                        name = cleanText(o->property("name").toString());
                        if (!id.startsWith(QLatin1Char('u')))
                            id.clear();
                    }
                    if (!id.isEmpty() && !name.isEmpty() && !contacts.contains(id))
                        contacts.insert(id, { name, inheritsClass(o, "ProfileData") });
                }
            }
        }
    }
    return contacts.value(mid);
}

// Spoken kind of a message row without text, from the delegate class LINE paints it with.
QString messageKindLabel(const QString &delegateClass)
{
    struct Kind {
        const char *marker;
        const char *label;
    };
    static const Kind kinds[] = {
        { "Date", "Date" },           { "UnreadMsg", "Unread messages below" },
        { "Sticon", "Emoji" },        { "Sticker", "Sticker" },
        { "Image", "Photo" },         { "Video", "Video" },
        { "File", "File" },           { "Audio", "Voice message" },
        { "Call", "Call" },           { "Location", "Location" },
        { "Contact", "Contact" },     { "Gift", "Gift" },
        { "Post", "Post" },           { "Music", "Music" },
        { "Link", "Link" },           { "Compress", "Compressed file" },
    };
    for (const Kind &k : kinds) {
        if (delegateClass.contains(QLatin1StringView(k.marker)))
            return label(k.label);
    }
    return QString();
}

// Time ("2:49 PM", "14:49", "14:49 น.") and read receipt ("Read", "Read 3", "อ่านแล้ว") labels.
bool isTimeOrReceipt(const QString &text)
{
    static const QRegularExpression pattern(
        QStringLiteral("^(\\d{1,2}[:.]\\d{2}(\\s?([AaPp][Mm]|น\\.?))?|Read( \\d+)?|อ่านแล้ว( \\d+)?)$"));
    return pattern.match(text.trimmed()).hasMatch();
}

// What the message row shows, without sender / time: its text, the file, or the kind of content.
QString chatMessageContent(const ChatMessageFields &f, const QString &delegateClass)
{
    // LINE stores links as HTML inside otherwise plain text ("Source: ... <a href=...>...</a>"),
    // which Qt::mightBeRichText() does not recognise.
    QString raw = f.text;
    if (raw.contains(QLatin1StringView("<a ")) || raw.contains(QLatin1StringView("</")))
        raw = QTextDocumentFragment::fromHtml(QString(raw).replace(QLatin1Char('\n'), QLatin1StringView("<br>"))).toPlainText();
    if (QString text = cleanText(raw); !text.isEmpty())
        return text;
    if (QString name = cleanText(f.fileName); !name.isEmpty()) {
        QStringList parts { label("File"), name };
        for (const QString &extra : { f.fileSize, f.fileStatus }) {
            if (QString t = cleanText(extra); !t.isEmpty())
                parts << t;
        }
        return parts.join(QLatin1StringView(", "));
    }
    const QString kind = messageKindLabel(delegateClass);
    if (!f.mediaPath.isEmpty())
        return kind.isEmpty() || kind == label("File") ? label("Photo") : kind;
    return kind;
}

// `self`: sent by the logged-in user. `visible`: texts recognised in the row's picture (only asked
// for when the data object has nothing to say, e.g. system notices such as "X made an announcement").
QString chatMessageText(const ChatMessageFields &f, bool self, const QString &delegateClass,
                        const std::function<QStringList()> &visible)
{
    // Local rows without a sender: date separators ("Oct 16(Fri)", "Yesterday") and markers.
    if (f.id.startsWith(QLatin1Char('l')) && f.senderMid.isEmpty()) {
        if (QString label = cleanText(f.timeLabel); !label.isEmpty())
            return label;
        const QStringList lines = visible();
        return lines.isEmpty() ? messageKindLabel(delegateClass) : lines.join(QLatin1StringView(" "));
    }
    QStringList parts;
    QString content = chatMessageContent(f, delegateClass);
    const bool notice = delegateClass.contains(QLatin1StringView("Info"));
    if (content.isEmpty() || notice) {
        QStringList lines;
        for (const QString &line : visible()) {
            if (!isTimeOrReceipt(line))
                lines << line;
        }
        if (!lines.isEmpty())
            content = lines.join(QLatin1StringView(" "));
    }
    if (!notice) {
        QString sender;
        if (self)
            sender = label("You");
        else if (QString name = cleanText(f.senderName); !name.isEmpty())
            sender = name;
        else
            sender = contactForMid(f.senderMid).name;
        // Notices already name the person ("X made an announcement.").
        if (!sender.isEmpty() && !content.startsWith(sender))
            parts << sender;
    }
    parts << (content.isEmpty() ? label("Message") : content);
    for (const QString &extra : { f.timeLabel, f.receipt }) {
        if (QString t = cleanText(extra); !t.isEmpty())
            parts << t;
    }
    return parts.join(QLatin1StringView(", "));
}

QString listContextName(const QWidget *view)
{
    struct Context {
        const char *ancestor;
        const char *name;
    };
    static const Context contexts[] = {
        { "ChatMessageView", "Messages" },
        { "MainChatPanel", "Chats" },
        { "MainFriendPanel", "Friends" },
        { "MainAddFriendPanel", "Add friends" },
        { "MainCallPanel", "Calls" },
    };
    for (const Context &c : contexts) {
        if (ancestorInheriting(view, c.ancestor))
            return label(c.name);
    }
    return QString();
}

QObject *rowData(QAbstractItemView *view, int row)
{
    QAbstractItemModel *model = view ? view->model() : nullptr;
    if (!model || row < 0 || row >= model->rowCount(view->rootIndex()))
        return nullptr;
    return model->index(row, 0, view->rootIndex()).data(kItemDataRole).value<QObject *>();
}

// The spoken text of `row` (see the file comment for where it comes from).
QString rowText(QAbstractItemView *view, int row)
{
    QAbstractItemModel *model = view ? view->model() : nullptr;
    if (!model || row < 0 || row >= model->rowCount(view->rootIndex()))
        return QString();
    const QModelIndex idx = model->index(row, 0, view->rootIndex());
    QObject *data = idx.data(kItemDataRole).value<QObject *>();
    if (inheritsClass(data, "ChatMessageData")) {
        // Message delegates may still show text from an earlier row: use the data object only.
        ListRowTextCache *cache = ListRowTextCache::forView(view);
        const ChatMessageFields fields = readChatMessageData(data);
        if (!cache)
            return chatMessageText(fields, false, QString(), [] { return QStringList(); });
        return chatMessageText(fields, cache->isOwnMessage(fields), cache->delegateClassFor(row),
                               [cache, row] { return cache->visibleTexts(row); });
    }
    if (QString text = dataObjectText(data); !text.isEmpty())
        return text;
    if (ListRowTextCache *cache = ListRowTextCache::forView(view)) {
        if (QString text = cache->text(row); !text.isEmpty())
            return text;
    }
    // Plain models (Settings' translation languages) give text even for rows off screen.
    const QVariant display = idx.data(Qt::DisplayRole);
    return display.metaType().id() == QMetaType::QString ? cleanText(display.toString()) : QString();
}

// ---- Where a message's parts are drawn --------------------------------------------------------
//
// The Windows bridge learnt the sizes below from LINE for Windows at 150 % display scale, where
// LINE draws in device pixels. LINE for macOS draws in points (Retina is a device pixel ratio), so
// recorded geometry is scaled by kWindowsScale before these rules are applied, and points found
// are scaled back.

constexpr qreal kWindowsScale = 1.5;

CaptureResult scaledCapture(const CaptureResult &cap, qreal f)
{
    CaptureResult out = cap;
    for (CapturedText &it : out.items) {
        it.pos *= f;
        it.width *= f;
    }
    for (QRectF &r : out.pixmapRects)
        r = QRectF(r.topLeft() * f, r.size() * f);
    for (PaintedImage &pi : out.images)
        pi.rect = QRectF(pi.rect.topLeft() * f, pi.rect.size() * f);
    for (PaintedShape &s : out.shapes)
        s.rect = QRectF(s.rect.topLeft() * f, s.rect.size() * f);
    return out;
}

QRect scaledRect(const QRect &r, qreal f)
{
    return QRect(QPoint(0, 0), (QSizeF(r.size()) * f).toSize());
}

// A row of `view` recorded as it is painted, in "Windows" coordinates relative to the row.
CaptureResult captureRow(QAbstractItemView *view, int row, QRect *rowRect)
{
    const QModelIndex idx = view->model()->index(row, 0, view->rootIndex());
    *rowRect = view->visualRect(idx);
    const CaptureResult cap = captureRegionText(view->viewport(), *rowRect);
    return scaledCapture(cap, kWindowsScale);
}

// Where a mouse user right-clicks or clicks a message (row coordinates): its bubble or picture (an
// image with text inside, else the largest image or shape that is neither the row's background nor
// the avatar), else its first line of text. Null if the row drew nothing of the kind.
QPointF messageContentPoint(const CaptureResult &cap, const QRect &rowRect)
{
    auto textInside = [&cap](const QRectF &r) {
        for (const CapturedText &it : cap.items) {
            if (!it.text.trimmed().isEmpty() && !isTimeOrReceipt(cleanText(it.text)) && r.contains(it.pos))
                return true;
        }
        return false;
    };
    auto candidate = [&rowRect](const QRectF &r) {
        const bool avatar = r.width() >= 30 && r.width() <= 45 && r.height() <= 45 && r.left() < 20;
        return r.top() >= -4 && r.width() >= 16 && r.height() >= 16 && r.width() < rowRect.width() - 20 && !avatar;
    };
    QRectF best;
    bool bestHasText = false;
    auto consider = [&](const QRectF &r) {
        if (!candidate(r))
            return;
        const bool hasText = textInside(r);
        if ((hasText && !bestHasText) || (hasText == bestHasText && r.width() * r.height() > best.width() * best.height())) {
            best = r;
            bestHasText = hasText;
        }
    };
    for (const PaintedImage &pi : cap.images)
        consider(pi.rect);
    for (const PaintedShape &s : cap.shapes)
        consider(s.rect);
    if (!best.isEmpty())
        return best.center();
    for (const CapturedText &it : cap.items) {
        const QString t = cleanText(it.text);
        if (!t.isEmpty() && !isTimeOrReceipt(t))
            return it.pos + QPointF(qMin<qreal>(it.width / 2, 12), -4);
    }
    return QPointF();
}

// Where to right-click a message (row coordinates), best first: messageContentPoint(), then the other
// pictures, bubbles and icons drawn for it (largest first), then its lines of text. LINE shows the
// message's menu only over the part its row reacts to, the chat background's menu elsewhere.
QList<QPointF> messageMenuPoints(const CaptureResult &cap, const QRect &rowRect)
{
    QList<QPointF> points;
    auto add = [&points](const QPointF &p) {
        if (p.isNull() || points.size() >= 6)
            return;
        for (const QPointF &q : std::as_const(points)) {
            if ((q - p).manhattanLength() < 8)
                return;
        }
        points << p;
    };
    add(messageContentPoint(cap, rowRect));
    QList<QRectF> parts;
    auto consider = [&parts, &rowRect](const QRectF &r) {
        const bool avatar = r.width() >= 30 && r.width() <= 45 && r.height() <= 45 && r.left() < 20;
        if (r.top() >= -4 && r.width() >= 8 && r.height() >= 8 && r.width() < rowRect.width() - 20 && !avatar)
            parts << r;
    };
    for (const PaintedImage &pi : cap.images)
        consider(pi.rect);
    for (const PaintedShape &sh : cap.shapes)
        consider(sh.rect);
    std::stable_sort(parts.begin(), parts.end(), [](const QRectF &a, const QRectF &b) {
        return a.width() * a.height() > b.width() * b.height();
    });
    for (const QRectF &r : std::as_const(parts))
        add(r.center());
    for (const CapturedText &it : cap.items) {
        if (!cleanText(it.text).isEmpty())
            add(it.pos + QPointF(qMin<qreal>(it.width / 2, 12), -4));
    }
    return points;
}

// From "Windows" row coordinates to the viewport, inside the part of the row that is shown (a tall
// message may reach past the viewport). Null if nothing of the row is shown.
QPointF viewportPoint(QAbstractItemView *view, const QRect &rowRect, const QPointF &point)
{
    const QRectF shown = QRectF(rowRect.intersected(view->viewport()->rect())).adjusted(1, 1, -1, -1);
    if (shown.isEmpty())
        return QPointF();
    return QPointF(qBound(shown.left(), rowRect.left() + point.x() / kWindowsScale, shown.right()),
                   qBound(shown.top(), rowRect.top() + point.y() / kWindowsScale, shown.bottom()));
}

void sendClick(QWidget *target, QPointF local)
{
    QPointer<QWidget> guard(target);
    const QPointF scene = target->mapTo(target->window(), local);
    const QPointF global = target->mapToGlobal(local);
    QEnterEvent enter(local, scene, global);
    QCoreApplication::sendEvent(target, &enter);
    // LINE's row widgets track the mouse: move there first, as a real click does.
    QMouseEvent move(QEvent::MouseMove, local, scene, global, Qt::NoButton, Qt::NoButton, Qt::NoModifier);
    if (guard)
        QCoreApplication::sendEvent(target, &move);
    QMouseEvent press(QEvent::MouseButtonPress, local, scene, global, Qt::LeftButton, Qt::LeftButton,
                      Qt::NoModifier);
    if (guard)
        QCoreApplication::sendEvent(target, &press);
    QMouseEvent release(QEvent::MouseButtonRelease, local, scene, global, Qt::LeftButton, Qt::NoButton,
                        Qt::NoModifier);
    if (guard)
        QCoreApplication::sendEvent(target, &release);
}

// A right click at `local`: hover, press, release and, if LINE opened no menu on those, the mouse
// context menu event.
void sendContextClick(QWidget *target, QPointF local)
{
    QPointer<QWidget> guard(target);
    const QPointF scene = target->mapTo(target->window(), local);
    const QPointF global = target->mapToGlobal(local);
    QEnterEvent enter(local, scene, global);
    QCoreApplication::sendEvent(target, &enter);
    QMouseEvent move(QEvent::MouseMove, local, scene, global, Qt::NoButton, Qt::NoButton, Qt::NoModifier);
    if (guard)
        QCoreApplication::sendEvent(target, &move);
    QMouseEvent press(QEvent::MouseButtonPress, local, scene, global, Qt::RightButton, Qt::RightButton,
                      Qt::NoModifier);
    if (guard)
        QCoreApplication::sendEvent(target, &press);
    QMouseEvent release(QEvent::MouseButtonRelease, local, scene, global, Qt::RightButton, Qt::NoButton,
                        Qt::NoModifier);
    if (guard)
        QCoreApplication::sendEvent(target, &release);
    if (!guard || contextMenuVisible())
        return;
    QContextMenuEvent menu(QContextMenuEvent::Mouse, local.toPoint(), global.toPoint());
    QCoreApplication::sendEvent(target, &menu);
}

// Right-clicks `points[i]` of the message at `index` (row coordinates). If LINE shows the chat
// background's menu, the event filter closes it and the next point is tried (setMenuRetry()); if it
// shows no menu at all, the next point too.
void tryRowMenu(QPointer<QAbstractItemView> view, QPersistentModelIndex index, QList<QPointF> points, int i)
{
    if (!view || !index.isValid() || i >= points.size()) {
        setMenuRetry(nullptr);
        return;
    }
    view->scrollTo(index);
    const QRect r = view->visualRect(index);
    const QPointF local = viewportPoint(view, r, points[i]);
    if (local.isNull()) {
        setMenuRetry(nullptr);
        return;
    }
    static int logged = 0;
    if (logged++ < 30)
        a11yLog("[menu] keyboard menu on message row %d: right click %d/%d at %.0f,%.0f (row %d,%d %dx%d)",
                index.row(), i + 1, int(points.size()), local.x(), local.y(), r.x(), r.y(), r.width(), r.height());
    auto next = [view, index, points, i] { tryRowMenu(view, index, points, i + 1); };
    setMenuRetry(i + 1 < points.size() ? std::function<void()>(next) : std::function<void()>());
    const int menusBefore = contextMenusShown();
    // LINE may run its menu in a loop of its own: then this returns once the menu has closed.
    sendContextClick(view->viewport(), local);
    if (!view || contextMenusShown() != menusBefore)
        return;
    QTimer::singleShot(150, view, [next, menusBefore, more = i + 1 < points.size()] {
        if (contextMenusShown() != menusBefore)
            return;
        a11yLog("[menu] no menu at that point%s", more ? "; trying another one" : "");
        if (more)
            next();
        else
            setMenuRetry(nullptr);
    });
}

// Pickers (ShareWindow "Share with...") tick rows: their data (ChatData, ProfileData) has `checked`.
// The main window's lists carry the same property, always false; section headers have it too.
bool isPickerRow(const QAbstractItemView *view, const QObject *data, bool *checked = nullptr)
{
    if (!view || !data || data->metaObject()->indexOfProperty("checked") < 0 || data->property("section").toBool()
        || inheritsAnyClass(view->window(), { "AllInOneWindow", "ChatWindow" }))
        return false;
    if (checked)
        *checked = data->property("checked").toBool();
    return true;
}

// A picker row was clicked: tell VoiceOver once LINE has ticked it.
void notifyPickerRowLater(QAbstractItemView *view, int row)
{
    QPointer<QAbstractItemView> guard(view);
    QTimer::singleShot(150, view, [guard, row] {
        auto *list = LineAccessibleList::listFor(guard);
        QAccessibleInterface *item = list ? list->itemAt(row) : nullptr;
        if (!item)
            return;
        QAccessible::State changed;
        changed.checked = true;
        QAccessibleStateChangeEvent event(item, changed);
        QAccessible::updateAccessibility(&event);
    });
}

// One row of an LcListView. An item stands for a row *position* (its index is resolved on every
// query), so it stays valid across LINE's frequent model changes.
class LineAccessibleListItem : public QAccessibleInterface, public QAccessibleActionInterface
{
public:
    LineAccessibleListItem(QAbstractItemView *view, int row)
        : m_view(view)
        , m_row(row)
    {
    }

    QModelIndex index() const
    {
        QAbstractItemModel *model = m_view ? m_view->model() : nullptr;
        return model ? model->index(m_row, 0, m_view->rootIndex()) : QModelIndex();
    }

    bool isValid() const override { return index().isValid(); }
    QObject *object() const override { return nullptr; }
    QWindow *window() const override { return m_view ? m_view->window()->windowHandle() : nullptr; }
    QAccessibleInterface *parent() const override { return QAccessible::queryAccessibleInterface(m_view.data()); }
    QAccessibleInterface *child(int) const override { return nullptr; }
    int childCount() const override { return 0; }
    int indexOfChild(const QAccessibleInterface *) const override { return -1; }
    QAccessibleInterface *childAt(int, int) const override { return nullptr; }
    void setText(QAccessible::Text, const QString &) override {}
    // Qt's Cocoa bridge maps ListItem to AXStaticText but only exposes AXValue (what VoiceOver
    // reads for static text) for the StaticText role itself. Picker rows are checkboxes.
    QAccessible::Role role() const override
    {
        return isPickerRow(m_view, rowData(m_view, m_row)) ? QAccessible::CheckBox : QAccessible::StaticText;
    }

    QString text(QAccessible::Text t) const override
    {
        if (t != QAccessible::Name || !index().isValid())
            return QString();
        return rowText(m_view, m_row);
    }

    QRect rect() const override
    {
        const QModelIndex idx = index();
        if (!idx.isValid())
            return QRect();
        const QRect r = m_view->visualRect(idx);
        return QRect(m_view->viewport()->mapToGlobal(r.topLeft()), r.size());
    }

    QAccessible::State state() const override
    {
        QAccessible::State st;
        const QModelIndex idx = index();
        if (!idx.isValid()) {
            st.invalid = true;
            return st;
        }
        st.selectable = true;
        st.focusable = true;
        if (bool checked = false; isPickerRow(m_view, rowData(m_view, m_row), &checked)) {
            st.checkable = true;
            st.checked = checked;
        }
        auto *list = dynamic_cast<LineAccessibleList *>(parent());
        const int cursor = list ? list->cursorRow() : m_view->currentIndex().row();
        // LINE moves the current row without selecting it.
        if (list && list->hasCursor())
            st.selected = m_row == cursor;
        else
            st.selected = (list && list->isRowSelected(m_row)) || m_view->currentIndex() == idx;
        // VoiceOver ignores a focus event unless the element still has focus when it looks: count the
        // current row as focused while LINE briefly pulls focus into the chat being opened.
        st.focused = m_row == cursor && (m_view->hasFocus() || isBrowsingList(m_view));
        st.active = m_view->currentIndex() == idx;
        // Rows scrolled out of view stay reachable (not "offscreen", which Cocoa would ignore);
        // pressing one scrolls it into view first. Rows with nothing to say yet (e.g. a date
        // separator scrolled out of view, which exists only as pixels) are left out instead of
        // being read as an empty "text".
        if (m_view->visualRect(idx).height() <= 1 || !m_view->isVisible() || text(QAccessible::Name).isEmpty())
            st.invisible = true;
        return st;
    }

    void *interface_cast(QAccessible::InterfaceType t) override
    {
        if (t == QAccessible::ActionInterface)
            return static_cast<QAccessibleActionInterface *>(this);
        return nullptr;
    }

    // QAccessibleActionInterface. Qt's Cocoa bridge maps press / toggle to AXPress (performing
    // toggleAction() for checkboxes only if listed) and showMenuAction() to AXShowMenu (VO+Shift+M).
    QStringList actionNames() const override
    {
        QStringList actions;
        actions << (isPickerRow(m_view, rowData(m_view, m_row)) ? toggleAction() : pressAction());
        if (hasMenu())
            actions << showMenuAction();
        actions << setFocusAction();
        return actions;
    }
    QStringList keyBindingsForAction(const QString &) const override { return {}; }
    void doAction(const QString &actionName) override
    {
        if (!isValid())
            return;
        markUserActivity();
        endListBrowsing();
        QPointer<QAbstractItemView> view = m_view;
        const QPersistentModelIndex index = this->index();
        if (actionName == setFocusAction()) {
            QMetaObject::invokeMethod(view, [view, index] {
                if (view && index.isValid()) {
                    view->setFocus(Qt::OtherFocusReason);
                    view->setCurrentIndex(index);
                }
            }, Qt::QueuedConnection);
            return;
        }
        const bool menu = actionName == showMenuAction();
        if (actionName != pressAction() && actionName != toggleAction() && !menu)
            return;
        const bool messages = ancestorInheriting(m_view, "ChatMessageView") != nullptr;
        const bool picker = isPickerRow(m_view, rowData(m_view, m_row));
        // Deferred: actions arrive inside synchronous Cocoa accessibility requests.
        QMetaObject::invokeMethod(view, [view, index, messages, picker, menu] {
            if (!view || !index.isValid())
                return;
            LineAccessibleList *list = LineAccessibleList::listFor(view);
            view->scrollTo(index);
            if (messages && list) {
                // The message VoiceOver is on becomes the current one, then acts like Space / Enter
                // (or the menu key) there.
                if (view->currentIndex() != index)
                    view->setCurrentIndex(index);
                if (menu)
                    list->openRowMenu();
                else
                    list->activateMessage();
                return;
            }
            if (menu && list && isCursorList(view)) {
                list->setCursorRow(index.row());
                list->openCursorMenu();
                return;
            }
            // LcListView dispatches viewport mouse events to the row's delegate controller
            // (performMouseEventTriggered), so a click at the row's centre selects / opens it
            // (opening a chat, folding a section, ticking a picker row).
            if (list)
                list->resetCursor();
            sendClick(view->viewport(), QRectF(view->visualRect(index)).center());
            if (picker)
                notifyPickerRowLater(view, index.row());
            else if (!messages)
                view->setFocus(Qt::OtherFocusReason);
        }, Qt::QueuedConnection);
    }

    int row() const { return m_row; }

private:
    bool hasMenu() const { return ancestorInheriting(m_view, "ChatMessageView") || isCursorList(m_view); }

    QPointer<QAbstractItemView> m_view;
    int m_row;
};

} // namespace

bool isLineListView(const QWidget *w)
{
    return w && qobject_cast<const QAbstractItemView *>(w) && inheritsClass(w, "LcListView");
}

bool isCursorList(const QWidget *w)
{
    return isLineListView(w) && !ancestorInheriting(w, "LcListView")
        && (ancestorInheriting(w, "MainChatPanel") || ancestorInheriting(w, "MainFriendPanel"));
}

bool contextMenuVisible()
{
    for (QWidget *w : QApplication::topLevelWidgets()) {
        if (w->isVisible() && inheritsClass(w, "LcContextMenu"))
            return true;
    }
    return false;
}

// ---- ListRowTextCache ----------------------------------------------------------------------------

namespace {

QList<QPointer<ListRowTextCache>> &allCaches()
{
    static QList<QPointer<ListRowTextCache>> caches;
    return caches;
}

} // namespace

ListRowTextCache *ListRowTextCache::forView(QAbstractItemView *view)
{
    if (!view || !isLineListView(view))
        return nullptr;
    for (QObject *child : view->children()) {
        if (child->objectName() == QLatin1StringView(kCacheObjectName))
            if (auto *cache = dynamic_cast<ListRowTextCache *>(child))
                return cache;
    }
    return new ListRowTextCache(view);
}

ListRowTextCache::ListRowTextCache(QAbstractItemView *view)
    : QObject(view)
    , m_view(view)
{
    setObjectName(QLatin1StringView(kCacheObjectName));
    auto &caches = allCaches();
    caches.removeAll(nullptr);
    caches << this;
    watchModel();
    view->viewport()->installEventFilter(this);
}

void ListRowTextCache::watchModel()
{
    QAbstractItemView *view = m_view;
    QAbstractItemModel *model = view ? view->model() : nullptr;
    if (model == m_model.data())
        return;
    for (const QMetaObject::Connection &c : std::as_const(m_modelConnections))
        QObject::disconnect(c);
    m_modelConnections.clear();
    clear();
    m_model = model;
    if (!model)
        return;
    // Texts are keyed by data object, so only the object -> row index needs refreshing.
    auto dirty = [this] { m_rowsDirty = true; };
    // Data objects that left the model may have their addresses reused: forget everything keyed
    // by address. Entries keyed by message id stay valid (bounded in size).
    auto forget = [this] {
        m_rowsDirty = true;
        m_texts.clear();
        for (auto *map : { &m_classes }) {
            for (auto it = map->begin(); it != map->end();)
                it = it.key().startsWith(QLatin1Char('@')) ? map->erase(it) : std::next(it);
        }
        for (auto it = m_visible.begin(); it != m_visible.end();)
            it = it.key().startsWith(QLatin1Char('@')) ? m_visible.erase(it) : std::next(it);
        if (m_classes.size() > 4000)
            m_classes.clear();
        if (m_visible.size() > 4000)
            m_visible.clear();
    };
    m_modelConnections << connect(model, &QAbstractItemModel::modelReset, this, forget)
                       << connect(model, &QAbstractItemModel::layoutChanged, this, forget)
                       << connect(model, &QAbstractItemModel::rowsMoved, this, dirty)
                       << connect(model, &QAbstractItemModel::rowsInserted, this, dirty)
                       << connect(model, &QAbstractItemModel::rowsRemoved, this, forget)
                       << connect(model, &QAbstractItemModel::dataChanged, this, dirty);
}

int ListRowTextCache::rowOf(quintptr dataObject)
{
    if (m_view && m_model.data() != m_view->model())
        watchModel();
    if (m_rowsDirty) {
        m_rowsDirty = false;
        m_rowOfObject.clear();
        if (QAbstractItemModel *model = m_model.data()) {
            const QModelIndex root = m_view ? m_view->rootIndex() : QModelIndex();
            const int rows = model->rowCount(root);
            m_rowOfObject.reserve(rows);
            m_otherSenders.clear();
            for (int r = 0; r < rows; ++r) {
                QObject *o = model->index(r, 0, root).data(kItemDataRole).value<QObject *>();
                if (!o)
                    continue;
                m_rowOfObject.insert(reinterpret_cast<quintptr>(o), r);
                // Received messages carry the sender's profile image; sent ones do not.
                if (inheritsClass(o, "ChatMessageData")) {
                    const ChatMessageFields f = readChatMessageData(o);
                    if (!f.senderMid.isEmpty() && !f.senderImage.isEmpty())
                        m_otherSenders.insert(f.senderMid);
                }
            }
        }
    }
    return dataObject ? m_rowOfObject.value(dataObject, -1) : -1;
}

void ListRowTextCache::record(quintptr dataObject, const QString &text)
{
    if (text.isEmpty())
        return;
    const QString previous = m_texts.value(dataObject);
    if (previous == text)
        return;
    m_texts.insert(dataObject, text);
    if (!m_loggedFirstText) {
        m_loggedFirstText = true;
        a11yLog("[list] first row text (%s, row %d): %s", m_model ? m_model->metaObject()->className() : "-",
                rowOf(dataObject), qPrintable(text.left(80)));
    }
    if (!previous.isEmpty() && onRowTextChanged)
        onRowTextChanged(rowOf(dataObject), text);
}

void ListRowTextCache::clear()
{
    m_texts.clear();
    m_classes.clear();
    m_visible.clear();
    m_rowOfObject.clear();
    m_rowsDirty = true;
}

QString ListRowTextCache::text(int row)
{
    QAbstractItemView *view = m_view;
    if (!view || !view->model())
        return QString();
    QObject *data = view->model()->index(row, 0, view->rootIndex()).data(kItemDataRole).value<QObject *>();
    if (!data)
        return QString();
    const quintptr key = reinterpret_cast<quintptr>(data);
    if (const auto it = m_texts.constFind(key); it != m_texts.cend())
        return *it;
    if (QString text = textFromDelegates(key); !text.isEmpty())
        return text;
    return renderRow(row) ? textFromDelegates(key) : QString();
}

QWidget *ListRowTextCache::delegateShowing(quintptr dataObject) const
{
    for (QWidget *w : QApplication::allWidgets()) {
        if (w->isWindow() && lcListDelegateDataPointer(w) == dataObject)
            return w;
    }
    return nullptr;
}

bool ListRowTextCache::renderRow(int row)
{
    QAbstractItemView *view = m_view;
    if (!view || !view->model() || m_rendering || !lcListDelegateDataPointerAvailable() || safeMode())
        return false;
    const QRect rect = view->visualRect(view->model()->index(row, 0, view->rootIndex())) & view->viewport()->rect();
    if (rect.isEmpty())
        return false;
    // LINE points a delegate at a row (and fills it) only while painting that row: paint just
    // this row into an offscreen pixmap.
    m_rendering = true;
    QPixmap scratch(rect.size());
    view->viewport()->render(&scratch, QPoint(), QRegion(rect), QWidget::DrawChildren);
    m_rendering = false;
    return true;
}

QString ListRowTextCache::delegateClassFor(int row)
{
    QAbstractItemView *view = m_view;
    if (!view || !view->model())
        return QString();
    QObject *data = view->model()->index(row, 0, view->rootIndex()).data(kItemDataRole).value<QObject *>();
    const QString key = rowKey(row);
    if (!data || key.isEmpty())
        return QString();
    if (const auto it = m_classes.constFind(key); it != m_classes.cend())
        return *it;
    // Only a delegate LINE has just pointed at this row counts: an idle delegate may still hold
    // the address of a freed row that now belongs to a different message.
    if (!renderRow(row))
        return QString(); // not on screen; known once it has been
    QWidget *delegate = delegateShowing(reinterpret_cast<quintptr>(data));
    if (!delegate)
        return QString();
    const QString cls = QLatin1StringView(delegate->metaObject()->className());
    m_classes.insert(key, cls); // a row's type never changes
    return cls;
}

bool ListRowTextCache::isOwnMessage(const ChatMessageFields &f)
{
    if (f.senderMid.isEmpty())
        return false;
    if (contactForMid(f.senderMid).self || !f.receipt.isEmpty())
        return true;
    if (!f.senderImage.isEmpty())
        return false;
    rowOf(0); // refreshes m_otherSenders when the model changed
    return !m_otherSenders.contains(f.senderMid);
}

QString ListRowTextCache::rowKey(int row) const
{
    QAbstractItemView *view = m_view;
    if (!view || !view->model())
        return QString();
    QObject *data = view->model()->index(row, 0, view->rootIndex()).data(kItemDataRole).value<QObject *>();
    if (!data)
        return QString();
    const QString id = readChatMessageData(data).id;
    // '@' marks address-based keys, which are dropped whenever rows go away.
    return !id.isEmpty() ? id : QLatin1Char('@') + QString::number(reinterpret_cast<quintptr>(data), 16);
}

QStringList ListRowTextCache::visibleTexts(int row)
{
    QAbstractItemView *view = m_view;
    if (!view || !view->model() || m_rendering)
        return {};
    const QString key = rowKey(row);
    if (key.isEmpty())
        return {};
    requestRecognition(row); // refreshes stale results; usually prefetched before this query
    return m_visible.value(key).lines;
}

void ListRowTextCache::requestRecognition(int row)
{
    QAbstractItemView *view = m_view;
    if (!view || !view->model() || m_rendering || safeMode())
        return;
    const QModelIndex index = view->model()->index(row, 0, view->rootIndex());
    const QString key = rowKey(row);
    if (key.isEmpty() || m_recognizing.contains(key))
        return;
    // Re-read now and then: read receipts ("Read", "Read 3") change after the message was sent.
    constexpr qint64 kRefreshMs = 30000;
    if (const auto it = m_visible.constFind(key);
        it != m_visible.cend() && QDateTime::currentMSecsSinceEpoch() - it->at < kRefreshMs)
        return;
    const QRect rect = view->visualRect(index);
    // Only fully visible rows: a clipped row would yield a partial date or time.
    if (rect.isEmpty() || !view->viewport()->rect().contains(rect))
        return;
    const qreal dpr = qMax<qreal>(2, view->devicePixelRatioF());
    QImage image((QSizeF(rect.size()) * dpr).toSize(), QImage::Format_ARGB32_Premultiplied);
    image.setDevicePixelRatio(dpr);
    image.fill(Qt::white);
    m_rendering = true;
    view->viewport()->render(&image, QPoint(), QRegion(rect), QWidget::DrawChildren);
    m_rendering = false;
    // Times and read receipts are small light-grey text: binarise so they stand out (bubble and
    // date-pill backgrounds are light enough to become white).
    QImage gray = image.convertToFormat(QImage::Format_Grayscale8);
    for (int y = 0; y < gray.height(); ++y) {
        uchar *line = gray.scanLine(y);
        for (int x = 0; x < gray.width(); ++x)
            line[x] = line[x] < 205 ? 0 : 255;
    }
    if (qEnvironmentVariableIntValue("LINE_A11Y_SAVE_OCR") == 1)
        gray.save(QString::fromUtf8(a11yDirectory()) + QStringLiteral("/ocr-row-%1.png").arg(row));
    m_recognizing.insert(key);
    recognizeTextLinesAsync(gray, this, [this, key, row](const QStringList &lines) {
        m_recognizing.remove(key);
        const bool changed = m_visible.value(key).lines != lines;
        m_visible.insert(key, { lines, QDateTime::currentMSecsSinceEpoch() });
        static int logged = 0;
        if (logged++ < 6)
            a11yLog("[ocr] %s: %s", qPrintable(key.left(20)), qPrintable(lines.join(QLatin1StringView(" | ")).left(120)));
        if (changed && !lines.isEmpty() && onRowTextChanged && rowKey(row) == key)
            onRowTextChanged(row, lines.join(QLatin1StringView(" ")));
    });
}

void ListRowTextCache::prefetchVisibleRows()
{
    QAbstractItemView *view = m_view;
    if (!view || !view->isVisible() || !view->model())
        return;
    const QRect area = view->viewport()->rect();
    const QModelIndex first = view->indexAt(area.topLeft());
    if (!first.isValid())
        return;
    for (int row = first.row(), rows = view->model()->rowCount(view->rootIndex()); row < rows; ++row) {
        const QModelIndex index = view->model()->index(row, 0, view->rootIndex());
        const QRect rect = view->visualRect(index);
        if (rect.top() > area.bottom())
            break;
        QObject *data = index.data(kItemDataRole).value<QObject *>();
        if (!inheritsClass(data, "ChatMessageData"))
            continue;
        const ChatMessageFields f = readChatMessageData(data);
        if (!f.text.isEmpty() || !f.fileName.isEmpty())
            continue; // fully described by the data object
        const QString cls = delegateClassFor(row); // sticker, photo, notice, ...
        if (cls.contains(QLatin1StringView("Info")) || chatMessageContent(f, cls).isEmpty())
            requestRecognition(row); // text that exists only as pixels
    }
}

bool ListRowTextCache::eventFilter(QObject *watched, QEvent *event)
{
    // Recognise the visible rows shortly after LINE painted the list (scrolling, new messages).
    if (event->type() == QEvent::Paint && m_view && watched == m_view->viewport() && !m_rendering) {
        if (!m_prefetchTimer) {
            m_prefetchTimer = new QTimer(this);
            m_prefetchTimer->setSingleShot(true);
            m_prefetchTimer->setInterval(250);
            connect(m_prefetchTimer, &QTimer::timeout, this, &ListRowTextCache::prefetchVisibleRows);
        }
        m_prefetchTimer->start();
    }
    return QObject::eventFilter(watched, event);
}

QString ListRowTextCache::textFromDelegates(quintptr dataObject)
{
    QWidget *delegate = delegateShowing(dataObject);
    const QString text = delegate ? delegateText(delegate) : QString();
    record(dataObject, text);
    return text;
}

// ---- LineAccessibleList --------------------------------------------------------------------------

namespace {

QElapsedTimer &listClock()
{
    static QElapsedTimer t;
    if (!t.isValid())
        t.start();
    return t;
}

// LINE's link under a long message, in the languages LINE offers.
bool isSeeMore(const QString &text)
{
    static const QStringList kSeeMore = { QStringLiteral("ดูเพิ่มเติม"), QStringLiteral("See more"),
                                          QStringLiteral("Read more"), QStringLiteral("もっと見る"),
                                          QStringLiteral("続きを読む"), QStringLiteral("查看更多"),
                                          QStringLiteral("查看全文"), QStringLiteral("顯示更多"),
                                          QStringLiteral("查看更多內容"), QStringLiteral("Lihat selengkapnya") };
    return kSeeMore.contains(cleanText(text));
}

// What a mouse user clicks to open a message's content, from the class of the delegate LINE paints
// it with: "voice", "video", "open" (photo, album, file, location) or "" (text, sticker, call, ...).
QString contentAction(const QString &delegateClass, const ChatMessageFields &fields)
{
    if (delegateClass.contains(QLatin1StringView("Audio")) || delegateClass.contains(QLatin1StringView("Voice")))
        return QStringLiteral("voice");
    if (delegateClass.contains(QLatin1StringView("Video")))
        return QStringLiteral("video");
    for (const char *marker : { "Image", "Photo", "Album", "File", "Location", "Compress" }) {
        if (delegateClass.contains(QLatin1StringView(marker)))
            return QStringLiteral("open");
    }
    if (!fields.fileName.isEmpty() || !fields.mediaPath.isEmpty())
        return QStringLiteral("open");
    return QString();
}

} // namespace

LineAccessibleList::LineAccessibleList(QWidget *w)
    : QAccessibleWidget(w, QAccessible::List)
{
    connectView();
}

LineAccessibleList::~LineAccessibleList()
{
    for (const QMetaObject::Connection &c : std::as_const(m_connections))
        QObject::disconnect(c);
    for (const QMetaObject::Connection &c : std::as_const(m_modelConnections))
        QObject::disconnect(c);
    // This destructor runs inside QAccessibleCache::deleteInterface() (the view was destroyed): do not
    // change Qt's cache from here. The row items are invalid once the view is gone; delete them on the
    // next turn of the event loop.
    const QList<QAccessible::Id> items = m_items.values();
    if (!items.isEmpty()) {
        QTimer::singleShot(0, QCoreApplication::instance(), [items] {
            for (QAccessible::Id id : items) {
                if (QAccessible::accessibleInterface(id))
                    QAccessible::deleteAccessibleInterface(id);
            }
        });
    }
}

LineAccessibleList *LineAccessibleList::listFor(const QWidget *view)
{
    if (!view || !isLineListView(view))
        return nullptr;
    return dynamic_cast<LineAccessibleList *>(QAccessible::queryAccessibleInterface(const_cast<QWidget *>(view)));
}

QAbstractItemView *LineAccessibleList::view() const
{
    return qobject_cast<QAbstractItemView *>(object());
}

ListRowTextCache *LineAccessibleList::cache() const
{
    return ListRowTextCache::forView(view());
}

void LineAccessibleList::connectView()
{
    QAbstractItemView *v = view();
    if (!v)
        return;
    const QPointer<QAbstractItemView> listView = v;
    if (ListRowTextCache *c = cache()) {
        c->onRowTextChanged = [listView](int row, const QString &) {
            // Called while LINE paints; post the notification afterwards.
            QTimer::singleShot(0, listView, [listView, row] {
                LineAccessibleList *list = listFor(listView);
                const QAccessible::Id itemId = list ? list->m_items.value(row) : 0;
                if (QAccessibleInterface *item = itemId ? QAccessible::accessibleInterface(itemId) : nullptr) {
                    QAccessibleEvent event(item, QAccessible::NameChanged);
                    QAccessible::updateAccessibility(&event);
                }
            });
        };
    }
    auto notify = [listView] {
        if (LineAccessibleList *list = listFor(listView))
            list->notifyCurrentRow();
    };
    if (const int sig = signalIndex(v, kCurrentIndexSignal); sig >= 0)
        m_connections << connectRaw(v, sig, v, [notify](void **) { notify(); });
    connectModel();
}

void LineAccessibleList::checkModel() const
{
    QAbstractItemView *v = view();
    if (v && v->model() != m_model.data())
        const_cast<LineAccessibleList *>(this)->connectModel();
}

// LINE gives the view a new model (and selection model) for each chat it opens: follow it.
void LineAccessibleList::connectModel()
{
    for (const QMetaObject::Connection &c : std::as_const(m_modelConnections))
        QObject::disconnect(c);
    m_modelConnections.clear();
    m_cursor = QPersistentModelIndex();
    m_lastRead = QPersistentModelIndex();
    m_modelLoadedAt = listClock().elapsed();
    QAbstractItemView *v = view();
    m_model = v ? v->model() : nullptr;
    if (!v)
        return;
    const QPointer<QAbstractItemView> listView = v;
    auto notify = [listView] {
        if (LineAccessibleList *list = listFor(listView))
            list->notifyCurrentRow();
    };
    if (QItemSelectionModel *sm = v->selectionModel())
        m_modelConnections << QObject::connect(sm, &QItemSelectionModel::currentChanged, v, notify);
    QAbstractItemModel *model = v->model();
    if (!model)
        return;
    auto prune = [listView] {
        if (LineAccessibleList *list = listFor(listView))
            list->schedulePrune();
    };
    m_modelConnections << QObject::connect(model, &QAbstractItemModel::rowsRemoved, v, prune)
                       << QObject::connect(model, &QAbstractItemModel::modelReset, v, prune)
                       << QObject::connect(model, &QAbstractItemModel::layoutChanged, v, prune);
    if (ancestorInheriting(v, "ChatMessageView")) {
        // New messages arrive as rows appended at the end; a chat being opened or scrolled back
        // loads many rows at once (or resets the model) and is not announced.
        m_modelConnections << QObject::connect(model, &QAbstractItemModel::modelReset, v, [listView] {
            if (LineAccessibleList *list = listFor(listView))
                list->m_modelLoadedAt = listClock().elapsed();
        });
        m_modelConnections << QObject::connect(model, &QAbstractItemModel::rowsInserted, v,
            [listView](const QModelIndex &, int first, int last) {
                LineAccessibleList *list = listFor(listView);
                if (!list || last - first > 2 || listClock().elapsed() - list->m_modelLoadedAt < 2000
                    || last != list->rowCount() - 1)
                    return;
                QTimer::singleShot(400, listView, [listView] {
                    if (LineAccessibleList *list = listFor(listView))
                        list->announceNewRow();
                });
            });
    }
}

void LineAccessibleList::announceNewRow()
{
    QAbstractItemView *v = view();
    if (!v || !v->isVisible() || !v->window()->isActiveWindow())
        return;
    const int row = rowCount() - 1;
    QObject *data = rowData(v, row);
    if (inheritsClass(data, "ChatMessageData")) {
        // The user's own messages were just typed by them.
        ListRowTextCache *c = cache();
        if (c && c->isOwnMessage(readChatMessageData(data)))
            return;
    }
    const QString text = rowText(v, row);
    if (text.isEmpty() || text.startsWith(label("You") + QLatin1Char(',')))
        return;
    static int logged = 0;
    if (logged++ < 5)
        a11yLog("[list] new message in the open chat (%d chars) announced", int(text.size()));
    announce(text, AnnounceWhen::LineActive);
}

void LineAccessibleList::schedulePrune() const
{
    QAbstractItemView *v = view();
    if (!v || m_prunePending)
        return;
    m_prunePending = true;
    const QPointer<QAbstractItemView> listView = v;
    QTimer::singleShot(0, v, [listView] {
        LineAccessibleList *list = listFor(listView);
        if (!list)
            return;
        list->m_prunePending = false;
        // Items are row positions; only those past the new end go away.
        const int rows = list->rowCount();
        for (auto it = list->m_items.begin(); it != list->m_items.end();) {
            if (it.key() >= rows) {
                if (QAccessible::accessibleInterface(it.value()))
                    QAccessible::deleteAccessibleInterface(it.value());
                it = list->m_items.erase(it);
            } else {
                ++it;
            }
        }
    });
}

void LineAccessibleList::notifyCurrentRow()
{
    QAbstractItemView *v = view();
    // While the chat list cursor is elsewhere, LINE moving its current row is not the user's doing.
    if (!v || !v->isVisible() || hasCursor())
        return;
    const QModelIndex current = v->currentIndex();
    if (!current.isValid())
        return;
    if (v->hasFocus()) {
        m_lastRead = current;
        v->scrollTo(current);
        if (QAccessibleInterface *item = itemAt(current.row())) {
            QAccessibleEvent event(item, QAccessible::Focus);
            QAccessible::updateAccessibility(&event);
        }
        return;
    }
    // The current row also moves when LINE reorders the list (a chat with a new message jumps to
    // the top): only follow changes the user caused.
    if (!userActedRecently() || !v->window()->isActiveWindow())
        return;
    // Keyboard focus is elsewhere (e.g. the search field), so VoiceOver would not follow a focus
    // change; announce the new row instead.
    if (QAccessibleInterface *item = itemAt(current.row()))
        postAnnouncement(item->text(QAccessible::Name));
}

void LineAccessibleList::focusLastVisibleRow()
{
    QAbstractItemView *v = view();
    if (!v || !v->model())
        return;
    const QModelIndex current = v->currentIndex();
    if (current.isValid() && v->viewport()->rect().intersects(v->visualRect(current)))
        return;
    // The newest row that says something (the bottom rows can be blank spacers).
    const QRect area = v->viewport()->rect();
    int lastRow = -1;
    for (int y = area.bottom() - 2; y > area.top(); y -= 8) {
        const QModelIndex idx = v->indexAt(QPoint(area.center().x(), y));
        if (!idx.isValid() || idx.row() == lastRow)
            continue;
        lastRow = idx.row();
        if (!rowText(v, idx.row()).isEmpty()) {
            v->setCurrentIndex(idx);
            return;
        }
    }
    // Only the text-less part of a tall row (a picture message) is on screen: go to the newest row
    // that says something instead of leaving the oldest row current.
    focusEdgeRow(true);
}

void LineAccessibleList::focusEdgeRow(bool last)
{
    QAbstractItemView *v = view();
    const int rows = rowCount();
    if (!v || rows == 0)
        return;
    // Rows LINE just added have no position until the view's delayed layout has run.
    v->doItemsLayout();
    const int step = last ? -1 : 1;
    int target = last ? rows - 1 : 0;
    // The rows at the ends can be blank spacers: take the first one from that end with text.
    for (int row = target, tries = 0; row >= 0 && row < rows && tries < 10; row += step, ++tries) {
        v->scrollTo(v->model()->index(row, 0, v->rootIndex()));
        if (!rowText(v, row).isEmpty()) {
            target = row;
            break;
        }
    }
    makeCurrent(target);
}

bool LineAccessibleList::focusRememberedRow()
{
    QAbstractItemView *v = view();
    checkModel();
    if (!v || !m_lastRead.isValid() || m_lastRead.model() != m_model.data())
        return false;
    const int row = m_lastRead.row();
    v->scrollTo(m_lastRead);
    if (rowText(v, row).isEmpty())
        return false;
    makeCurrent(row);
    return true;
}

bool LineAccessibleList::stepRow(int key)
{
    QAbstractItemView *v = view();
    const int rows = rowCount();
    if (!v || rows == 0)
        return false;
    const bool page = key == Qt::Key_PageUp || key == Qt::Key_PageDown;
    int step = 0;
    if (key == Qt::Key_Up || key == Qt::Key_PageUp)
        step = -1;
    else if (key == Qt::Key_Down || key == Qt::Key_PageDown)
        step = 1;
    else
        return false;
    const int current = v->currentIndex().isValid() ? v->currentIndex().row() : -1;
    if (current < 0) {
        focusEdgeRow(true);
        return true;
    }
    const int pageHeight = v->viewport()->height();
    int target = current;
    int travelled = 0;
    for (int row = current + step; row >= 0 && row < rows; row += step) {
        const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
        v->scrollTo(idx);
        // Blank rows (spacers) are skipped.
        if (!rowText(v, row).isEmpty()) {
            target = row;
            if (!page || travelled >= pageHeight)
                break;
        }
        travelled += v->visualRect(idx).height();
    }
    // At the top LINE loads older messages once the first row is in view; Up then goes on.
    if (target == current)
        v->scrollTo(v->model()->index(step < 0 ? 0 : rows - 1, 0, v->rootIndex()));
    makeCurrent(target);
    return true;
}

void LineAccessibleList::makeCurrent(int row)
{
    QAbstractItemView *v = view();
    if (!v || !v->model())
        return;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    if (idx != v->currentIndex()) {
        v->setCurrentIndex(idx); // LINE reports the change (notifyCurrentRow)
        return;
    }
    v->scrollTo(idx);
    if (v->hasFocus())
        m_lastRead = idx;
    if (QAccessibleInterface *item = itemAt(row)) {
        // VoiceOver ignores a second Focus event for the element it is on: read it again.
        QAccessibleEvent event(item, QAccessible::Focus);
        QAccessible::updateAccessibility(&event);
        postAnnouncement(item->text(QAccessible::Name));
    }
}

QString LineAccessibleList::text(QAccessible::Text t) const
{
    if (t == QAccessible::Name) {
        if (QString name = cleanText(widget()->accessibleName()); !name.isEmpty())
            return name;
        return listContextName(widget());
    }
    return QAccessibleWidget::text(t);
}

QAccessible::State LineAccessibleList::state() const
{
    QAccessible::State st = QAccessibleWidget::state();
    st.focusable = true;
    return st;
}

int LineAccessibleList::childCount() const
{
    return rowCount();
}

QAccessibleInterface *LineAccessibleList::child(int index) const
{
    return itemAt(index);
}

int LineAccessibleList::indexOfChild(const QAccessibleInterface *child) const
{
    const auto *item = dynamic_cast<const LineAccessibleListItem *>(child);
    if (!item || item->parent() != this)
        return -1;
    return item->row();
}

QAccessibleInterface *LineAccessibleList::focusChild() const
{
    QAbstractItemView *v = view();
    if (!v || !v->hasFocus())
        return nullptr;
    const int row = cursorRow();
    return row >= 0 ? itemAt(row) : nullptr;
}

bool LineAccessibleList::moveCursor(int key)
{
    QAbstractItemView *v = view();
    const int rows = rowCount();
    if (!v || rows == 0)
        return false;
    int row = cursorRow();
    const int height = v->visualRect(v->model()->index(qMax(row, 0), 0, v->rootIndex())).height();
    const int page = height > 0 ? qMax(1, v->viewport()->height() / height - 1) : 5;
    switch (key) {
    case Qt::Key_Up:
        row = row < 0 ? 0 : row - 1;
        break;
    case Qt::Key_Down:
        row = row < 0 ? 0 : row + 1;
        break;
    case Qt::Key_PageUp:
        row -= page;
        break;
    case Qt::Key_PageDown:
        row = row < 0 ? page : row + page;
        break;
    case Qt::Key_Home:
        row = 0;
        break;
    case Qt::Key_End:
        row = rows - 1;
        break;
    default:
        return false;
    }
    setCursorRow(qBound(0, row, rows - 1));
    return true;
}

void LineAccessibleList::setCursorRow(int row)
{
    QAbstractItemView *v = view();
    if (!v || !v->model() || row < 0 || row >= rowCount())
        return;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    m_cursor = idx;
    // Scrolling does not change LINE's current row (so no chat is opened).
    v->scrollTo(idx);
    if (QAccessibleInterface *item = itemAt(row)) {
        QAccessibleEvent event(item, QAccessible::Focus);
        QAccessible::updateAccessibility(&event);
    }
}

bool LineAccessibleList::openCursorRow()
{
    QAbstractItemView *v = view();
    const QPersistentModelIndex idx = m_cursor;
    m_cursor = QPersistentModelIndex();
    if (!v || !idx.isValid() || idx == QPersistentModelIndex(v->currentIndex()))
        return false;
    // A click opens the chat the way LINE expects (setting the current row alone may not).
    v->scrollTo(idx);
    sendClick(v->viewport(), QRectF(v->visualRect(idx)).center());
    return true;
}

void LineAccessibleList::resetCursor()
{
    m_cursor = QPersistentModelIndex();
}

int LineAccessibleList::cursorRow() const
{
    if (m_cursor.isValid() && m_cursor.model() == m_model.data())
        return m_cursor.row();
    QAbstractItemView *v = view();
    return v && v->currentIndex().isValid() ? v->currentIndex().row() : -1;
}

bool LineAccessibleList::activateMessage()
{
    const int row = cursorRow();
    if (row < 0)
        return false;
    return openSeeMore(row) || openLink(row) || openMessageContent(row);
}

bool LineAccessibleList::openSeeMore(int row)
{
    QAbstractItemView *v = view();
    if (!v || !v->model())
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    QRect r;
    const CaptureResult cap = captureRow(v, row, &r);
    if (cap.skipped)
        return false;
    for (const CapturedText &it : cap.items) {
        if (!isSeeMore(it.text))
            continue;
        // Text positions are baselines: click a little above, in the middle of the word.
        const QPointF inRow((it.pos.x() + qMax<qreal>(it.width, 8) / 2) / kWindowsScale, it.pos.y() / kWindowsScale - 4);
        QPointF local = QPointF(r.topLeft()) + inRow;
        // A long message is taller than the list: bring its end (where the link is) into view.
        if (!v->viewport()->rect().contains(local.toPoint())) {
            if (QScrollBar *bar = v->verticalScrollBar())
                bar->setValue(bar->value() + int(local.y() - v->viewport()->height() / 2));
            local = QPointF(v->visualRect(idx).topLeft()) + inRow;
        }
        if (!v->viewport()->rect().contains(local.toPoint())) {
            a11yLog("[keyboard] \"See more\" in message row %d is out of view (%.0f,%.0f)", row, local.x(), local.y());
            return false;
        }
        a11yLog("[keyboard] \"See more\" in message row %d: click at %.0f,%.0f", row, local.x(), local.y());
        sendClick(v->viewport(), local);
        return true;
    }
    return false;
}

bool LineAccessibleList::openLink(int row)
{
    QAbstractItemView *v = view();
    if (!v || !v->model())
        return false;
    QString url;
    QObject *data = rowData(v, row);
    if (inheritsClass(data, "ChatMessageData")) {
        // The message's own text holds its links (<a href> or plain addresses).
        url = firstLinkTarget(readChatMessageData(data).text);
    } else {
        QRect r;
        const CaptureResult cap = captureRow(v, row, &r);
        QList<CapturedText> items = cap.items;
        std::stable_sort(items.begin(), items.end(), [](const CapturedText &a, const CapturedText &b) {
            return qAbs(a.pos.y() - b.pos.y()) >= 1 ? a.pos.y() < b.pos.y() : a.pos.x() < b.pos.x();
        });
        QStringList lines;
        qreal lastY = -1e9;
        for (const CapturedText &it : std::as_const(items)) {
            if (it.text.trimmed().isEmpty())
                continue;
            if (!lines.isEmpty() && qAbs(it.pos.y() - lastY) < 1)
                lines.last() += it.text;
            else
                lines << it.text;
            lastY = it.pos.y();
        }
        lines.removeIf([](const QString &l) { return isTimeOrReceipt(cleanText(l)); });
        url = firstWebAddress(lines);
    }
    if (url.isEmpty())
        return false;
    const bool opened = openInBrowser(url);
    // The address may be private: the log names only its host.
    a11yLog("[keyboard] link in message row %d (%s): %s", row, qUtf8Printable(QUrl(url).host()),
            opened ? "opened in the browser" : "macOS refused to open it");
    return opened;
}

bool LineAccessibleList::openMessageContent(int row)
{
    QAbstractItemView *v = view();
    if (!v || !v->model())
        return false;
    QObject *data = rowData(v, row);
    ListRowTextCache *c = cache();
    const QString cls = c ? c->delegateClassFor(row) : QString();
    const QString action = contentAction(cls, readChatMessageData(data));
    if (action.isEmpty())
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    QRect r;
    const CaptureResult cap = captureRow(v, row, &r);
    if (cap.skipped)
        return false;
    const QRect windowsRow = scaledRect(r, kWindowsScale);
    auto isPlayIcon = [](const PaintedImage &icon) {
        return icon.icon == QLatin1StringView("voice") || icon.icon == QLatin1StringView("video");
    };
    // Where a mouse user clicks: the play / pause button of a voice message, the play button of a
    // video, else the bubble or picture (a file's bubble opens the file, a photo's picture the viewer).
    QPointF point;
    if (action != QLatin1StringView("open")) {
        for (const PaintedImage &icon : cap.images) {
            if (isPlayIcon(icon) && icon.rect.top() >= -4) {
                point = icon.rect.center();
                break;
            }
        }
    }
    if (point.isNull())
        point = messageContentPoint(cap, windowsRow);
    const QPointF local = point.isNull() ? QPointF() : viewportPoint(v, r, point);
    if (local.isNull()) {
        a11yLog("[keyboard] %s in message row %d (%s): nothing to click", qPrintable(action), row, qPrintable(cls));
        return false;
    }
    a11yLog("[keyboard] %s in message row %d (%s): click at %.0f,%.0f", qPrintable(action), row, qPrintable(cls),
            local.x(), local.y());
    sendClick(v->viewport(), local);
    return true;
}

bool LineAccessibleList::toggleCursorRow()
{
    QAbstractItemView *v = view();
    const int row = cursorRow();
    if (!v || !v->model() || row < 0)
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    if (!isPickerRow(v, rowData(v, row)))
        return false;
    v->scrollTo(idx);
    sendClick(v->viewport(), QRectF(v->visualRect(idx)).center());
    notifyPickerRowLater(v, row);
    return true;
}

bool LineAccessibleList::openRowMenu()
{
    QAbstractItemView *v = view();
    const int row = cursorRow();
    if (!v || !v->model() || row < 0)
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    QRect r;
    const CaptureResult cap = captureRow(v, row, &r);
    if (cap.skipped)
        return false;
    QList<QPointF> points = messageMenuPoints(cap, scaledRect(r, kWindowsScale));
    if (points.isEmpty()) // nothing recorded: the middle of the row
        points << QPointF(r.width() / 2.0, r.height() / 2.0) * kWindowsScale;
    tryRowMenu(v, idx, points, 0);
    return true;
}

bool LineAccessibleList::openCursorMenu()
{
    QAbstractItemView *v = view();
    const int row = cursorRow();
    if (!v || !v->model() || row < 0)
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    const QRect r = v->visualRect(idx);
    const QRectF shown = QRectF(r.intersected(v->viewport()->rect())).adjusted(1, 1, -1, -1);
    if (shown.isEmpty())
        return false;
    const QPersistentModelIndex keep(idx);
    a11yLog("[menu] keyboard menu on list row %d: right click at %.0f,%.0f", row, shown.center().x(),
            shown.center().y());
    sendContextClick(v->viewport(), shown.center());
    // The click made the cursor follow LINE's current row again (see the event filter); once the
    // menu has closed, go back to the row the menu was for (unless it is gone: deleted, hidden).
    m_cursor = keep;
    QPointer<QAbstractItemView> guard(v);
    auto *timer = new QTimer(v);
    timer->setInterval(200);
    QObject::connect(timer, &QTimer::timeout, timer, [guard, keep, timer] {
        if (!guard || !keep.isValid()) {
            timer->deleteLater();
            return;
        }
        if (contextMenuVisible())
            return;
        timer->deleteLater();
        LineAccessibleList *list = listFor(guard);
        if (!list || !guard->hasFocus())
            return;
        list->setCursorRow(keep.row());
    });
    timer->start();
    return true;
}

QString LineAccessibleList::recentMessageText(int n)
{
    QAbstractItemView *v = view();
    if (!v || n < 1)
        return QString();
    int found = 0;
    for (int row = rowCount() - 1; row >= 0; --row) {
        QObject *data = rowData(v, row);
        // Date separators and markers are not messages.
        if (inheritsClass(data, "ChatMessageData")) {
            const ChatMessageFields f = readChatMessageData(data);
            if (f.id.startsWith(QLatin1Char('l')) && f.senderMid.isEmpty())
                continue;
        }
        const QString text = rowText(v, row);
        if (text.isEmpty())
            continue;
        if (++found == n)
            return text;
    }
    return QString();
}

QAccessibleInterface *LineAccessibleList::childAt(int x, int y) const
{
    QAbstractItemView *v = view();
    if (!v)
        return nullptr;
    const QModelIndex index = v->indexAt(v->viewport()->mapFromGlobal(QPoint(x, y)));
    return index.isValid() ? itemAt(index.row()) : nullptr;
}

QAccessibleInterface *LineAccessibleList::itemAt(int row) const
{
    QAbstractItemView *v = view();
    if (!v || row < 0 || row >= rowCount())
        return nullptr;
    if (const QAccessible::Id id = m_items.value(row)) {
        if (QAccessibleInterface *item = QAccessible::accessibleInterface(id))
            return item;
    }
    auto *item = new LineAccessibleListItem(v, row);
    m_items.insert(row, QAccessible::registerAccessibleInterface(item));
    return item;
}

int LineAccessibleList::rowCount() const
{
    checkModel();
    QAbstractItemView *v = view();
    return v && v->model() ? v->model()->rowCount(v->rootIndex()) : 0;
}

bool LineAccessibleList::isRowSelected(int row) const
{
    QAbstractItemView *v = view();
    if (!v || !v->model())
        return false;
    QItemSelectionModel *sm = v->selectionModel();
    return sm && sm->isRowSelected(row, v->rootIndex());
}

} // namespace line_a11y
