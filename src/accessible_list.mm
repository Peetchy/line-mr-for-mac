#include "accessible_list.h"

#include "a11y_EventFilter.h"
#include "a11y_log.h"
#include "a11y_update_filter.h"
#include "accessible_widgets.h"
#include "line_introspect.h"
#include "qt_signal_utils.h"
#include "text_recognition.h"

#include <QtCore/QAbstractItemModel>
#include <QtCore/QDateTime>
#include <QtCore/QItemSelectionModel>
#include <QtCore/QMetaMethod>
#include <QtCore/QMetaProperty>
#include <QtCore/QRegularExpression>
#include <QtCore/QSet>
#include <QtCore/QTimer>
#include <QtGui/QImage>
#include <QtGui/QTextDocumentFragment>
#include <QtGui/QPalette>
#include <QtGui/QPixmap>
#include <QtGui/QWindow>
#include <QtWidgets/QAbstractItemView>
#include <QtWidgets/QApplication>
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
                                            "Key", "WithoutQuery", "Query" };
    // "mid" is LINE's internal user / group id.
    if (name == "id" || name == "mid" || name == "objectName" || name == "section" || name == "sectionId"
        || name == "type")
        return true;
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
        return value == 1 ? QStringLiteral("1 member") : QStringLiteral("%1 members").arg(value);
    if (name == "count") // SectionData: number of entries under a section header
        return QString::number(value);
    if (name == "unreadCount" || name == "badgeCount" || name == "newCount") {
        const QString n = value > 999 ? QStringLiteral("999+") : QString::number(value);
        return QStringLiteral("%1 unread").arg(n);
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
        content.prepend(QStringLiteral("You"));
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
            return QLatin1StringView(k.label);
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
        QStringList parts { QStringLiteral("File"), name };
        for (const QString &extra : { f.fileSize, f.fileStatus }) {
            if (QString t = cleanText(extra); !t.isEmpty())
                parts << t;
        }
        return parts.join(QLatin1StringView(", "));
    }
    const QString kind = messageKindLabel(delegateClass);
    if (!f.mediaPath.isEmpty())
        return kind.isEmpty() || kind == QLatin1StringView("File") ? QStringLiteral("Photo") : kind;
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
            sender = QStringLiteral("You");
        else if (QString name = cleanText(f.senderName); !name.isEmpty())
            sender = name;
        else
            sender = contactForMid(f.senderMid).name;
        // Notices already name the person ("X made an announcement.").
        if (!sender.isEmpty() && !content.startsWith(sender))
            parts << sender;
    }
    parts << (content.isEmpty() ? QStringLiteral("Message") : content);
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
            return QLatin1StringView(c.name);
    }
    return QString();
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
    // reads for static text) for the StaticText role itself.
    QAccessible::Role role() const override { return QAccessible::StaticText; }

    QString text(QAccessible::Text t) const override
    {
        const QModelIndex idx = index();
        if (!idx.isValid() || t != QAccessible::Name)
            return QString();
        QObject *data = idx.data(kItemDataRole).value<QObject *>();
        if (inheritsClass(data, "ChatMessageData")) {
            // Message delegates may still show text from an earlier row: use the data object only.
            ListRowTextCache *cache = ListRowTextCache::forView(m_view);
            const ChatMessageFields fields = readChatMessageData(data);
            if (!cache)
                return chatMessageText(fields, false, QString(), [] { return QStringList(); });
            const int row = m_row;
            return chatMessageText(fields, cache->isOwnMessage(fields), cache->delegateClassFor(m_row),
                                   [cache, row] { return cache->visibleTexts(row); });
        }
        if (QString text = dataObjectText(data); !text.isEmpty())
            return text;
        if (ListRowTextCache *cache = ListRowTextCache::forView(m_view)) {
            if (QString text = cache->text(m_row); !text.isEmpty())
                return text;
        }
        const QVariant display = idx.data(Qt::DisplayRole);
        return display.metaType().id() == QMetaType::QString ? cleanText(display.toString()) : QString();
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
        st.selected = isSelected();
        // Rows scrolled out of view stay reachable (not "offscreen", which Cocoa would ignore);
        // pressing one scrolls it into view first.
        st.focused = m_view->hasFocus() && m_view->currentIndex() == idx;
        st.active = m_view->currentIndex() == idx;
        // Rows with nothing to say yet (e.g. a date separator scrolled out of view, which exists only
        // as pixels) are left out instead of being read as an empty "text".
        if (m_view->visualRect(idx).isEmpty() || !m_view->isVisible() || text(QAccessible::Name).isEmpty())
            st.invisible = true;
        return st;
    }

    void *interface_cast(QAccessible::InterfaceType t) override
    {
        if (t == QAccessible::ActionInterface)
            return static_cast<QAccessibleActionInterface *>(this);
        return nullptr;
    }

    bool isSelected() const
    {
        auto *list = dynamic_cast<LineAccessibleList *>(parent());
        return list && list->isRowSelected(m_row);
    }

    // QAccessibleActionInterface
    QStringList actionNames() const override { return { pressAction(), setFocusAction() }; }
    QStringList keyBindingsForAction(const QString &) const override { return {}; }
    void doAction(const QString &actionName) override
    {
        if (!isValid())
            return;
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
        if (actionName != pressAction())
            return;
        // LcListView dispatches viewport mouse events to the row's delegate controller
        // (performMouseEventTriggered), so a click at the row's centre selects / opens it.
        view->scrollTo(index);
        synthesizeClickAt(view->viewport(), view->visualRect(index).center(), [view] {
            if (view)
                view->setFocus(Qt::OtherFocusReason);
        });
    }

    int row() const { return m_row; }

private:
    QPointer<QAbstractItemView> m_view;
    int m_row;
};

} // namespace

bool isLineListView(const QWidget *w)
{
    return w && qobject_cast<const QAbstractItemView *>(w) && inheritsClass(w, "LcListView");
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
    if (!view || !view->model() || m_rendering || !lcListDelegateDataPointerAvailable())
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
    if (!view || !view->model() || m_rendering)
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

LineAccessibleList::LineAccessibleList(QWidget *w)
    : QAccessibleWidget(w, QAccessible::List)
{
    connectView();
}

LineAccessibleList::~LineAccessibleList()
{
    if (QAbstractItemView *v = view()) {
        for (QObject *child : v->children()) {
            if (auto *c = dynamic_cast<ListRowTextCache *>(child))
                c->onRowTextChanged = nullptr;
        }
    }
    for (const QMetaObject::Connection &c : std::as_const(m_connections))
        QObject::disconnect(c);
    for (QAccessible::Id id : std::as_const(m_items)) {
        if (QAccessible::accessibleInterface(id))
            QAccessible::deleteAccessibleInterface(id);
    }
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
    if (ListRowTextCache *c = cache()) {
        const QAccessible::Id listId = QAccessible::uniqueId(this);
        c->onRowTextChanged = [this, listId](int row, const QString &) {
            if (QAccessible::accessibleInterface(listId) != this)
                return;
            const QAccessible::Id itemId = m_items.value(row);
            QAbstractItemView *view = this->view();
            if (!itemId || !view)
                return;
            // Called while LINE paints; post the notification afterwards.
            QTimer::singleShot(0, view, [itemId] {
                if (QAccessibleInterface *item = QAccessible::accessibleInterface(itemId)) {
                    QAccessibleEvent event(item, QAccessible::NameChanged);
                    QAccessible::updateAccessibility(&event);
                }
            });
        };
    }
    auto notify = [this] { notifyCurrentRow(); };
    if (QItemSelectionModel *sm = v->selectionModel())
        m_connections << QObject::connect(sm, &QItemSelectionModel::currentChanged, v, notify);
    if (const int sig = signalIndex(v, kCurrentIndexSignal); sig >= 0)
        m_connections << connectRaw(v, sig, v, [notify](void **) { notify(); });
    if (QAbstractItemModel *model = v->model()) {
        auto prune = [this] { schedulePrune(); };
        m_connections << QObject::connect(model, &QAbstractItemModel::rowsRemoved, v, prune)
                      << QObject::connect(model, &QAbstractItemModel::modelReset, v, prune)
                      << QObject::connect(model, &QAbstractItemModel::layoutChanged, v, prune);
    }
}

void LineAccessibleList::schedulePrune() const
{
    QAbstractItemView *v = view();
    if (!v || m_prunePending)
        return;
    m_prunePending = true;
    const QAccessible::Id id = QAccessible::uniqueId(const_cast<LineAccessibleList *>(this));
    QTimer::singleShot(0, v, [id] {
        auto *list = dynamic_cast<LineAccessibleList *>(QAccessible::accessibleInterface(id));
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
    if (!v || !v->isVisible())
        return;
    const QModelIndex current = v->currentIndex();
    if (!current.isValid())
        return;
    // The current row also moves when LINE reorders the list (a chat with a new message jumps to
    // the top): only follow changes the user caused.
    if (!userActedRecently())
        return;
    QAccessibleInterface *item = itemAt(current.row());
    if (!item)
        return;
    if (v->hasFocus()) {
        QAccessibleEvent event(item, QAccessible::Focus);
        QAccessible::updateAccessibility(&event);
    } else if (v->window()->isActiveWindow()) {
        // Keyboard focus is elsewhere (e.g. the search field), so VoiceOver would not follow
        // a focus change; announce the new row instead.
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
    if (!child || child->parent() != this)
        return -1;
    const auto *item = dynamic_cast<const LineAccessibleListItem *>(child);
    return item ? item->row() : -1;
}

QAccessibleInterface *LineAccessibleList::focusChild() const
{
    QAbstractItemView *v = view();
    if (!v || !v->hasFocus() || !v->currentIndex().isValid())
        return nullptr;
    return itemAt(v->currentIndex().row());
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
