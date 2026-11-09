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
#include "native_message_text.h"
#include "transcribe_request.h"

#include <QtCore/QAbstractItemModel>
#include <QtCore/QCoreApplication>
#include <QtCore/QDateTime>
#include <QtCore/QElapsedTimer>
#include <QtCore/QItemSelectionModel>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QMimeData>
#include <QtCore/QScopedValueRollback>
#include <QtCore/QSettings>
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
#include <QtWidgets/QFileDialog>
#include <QtWidgets/QScrollBar>
#include <QtWidgets/QMenu>
#include <QtGui/QWheelEvent>
#include <QtGui/QClipboard>
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
        return label("%1 unread messages").arg(n);
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
    // Each data class's properties once (names and types; values only for bool / int).
    static QSet<QByteArray> described;
    if (!described.contains(mo->className())) {
        described.insert(mo->className());
        QStringList props;
        for (int i = first; i < mo->propertyCount(); ++i) {
            const QMetaProperty prop = mo->property(i);
            QString entry = QString::fromLatin1(prop.name()) + u':' + QString::fromLatin1(prop.typeName());
            if (prop.metaType().id() == QMetaType::Bool || prop.metaType().id() == QMetaType::Int)
                entry += u'=' + prop.read(data).toString();
            props << entry;
        }
        a11yLog("[list] %s properties: %s", mo->className(), qPrintable(props.join(u' ')));
    }
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

// Time ("2:49 PM", "14:49", "14:49 น.", "下午 2:49") and read receipt ("Read", "Read 3", "อ่านแล้ว",
// "已讀") labels.
bool isTimeOrReceipt(const QString &text)
{
    return isMessageTimeOrReceipt(text);
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
    if (const QString length = cleanText(f.duration); !length.isEmpty() && !kind.isEmpty())
        return kind + QStringLiteral(", ") + spokenDuration(length);
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
        { "ChatSearchResultWindow", "Search results" },
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

QString messageReactions(QAbstractItemView *view, int row, const QString &messageId);
QString firstPaintedLine(QAbstractItemView *view, const QModelIndex &index);
QString withChatStatus(QAbstractItemView *view, int row, const QString &text, QObject *data);
QString packageRowText(QAbstractItemView *view, int row, QObject *data);
QString paintedListRowText(QAbstractItemView *view, int row);

// message-settings.ini next to a11y.log, read at most once a second:
//   [messages]
//   directChatSenderNames=true    read the other person's name before their messages in one-to-one chats
//   senderOnlyWhenChanged=true    read the sender's name only when the sender changes
struct MessageSettings {
    bool directChatSenderNames = false;
    bool senderOnlyWhenChanged = false;
};

const MessageSettings &messageSettings()
{
    static QElapsedTimer checked;
    static MessageSettings settings;
    if (!checked.isValid() || checked.elapsed() >= 1000) {
        checked.start();
        QSettings ini(bridgeDirectory() + QStringLiteral("message-settings.ini"), QSettings::IniFormat);
        settings.directChatSenderNames = ini.value(QStringLiteral("messages/directChatSenderNames"), false).toBool();
        settings.senderOnlyWhenChanged = ini.value(QStringLiteral("messages/senderOnlyWhenChanged"), false).toBool();
    }
    return settings;
}

// The chat shown in `v` is Keep Memo (the chat with the user themselves: its id is the user's own,
// the first profile of the friend list). Worked out once per chat (LINE's name getter is expensive).
bool inKeepMemo(QAbstractItemView *v)
{
    static QString chat;
    static int state = -1;
    static QElapsedTimer tried;
    const QString shown = chatNameFor(v);
    if (chat == shown && (state >= 0 || (tried.isValid() && tried.elapsed() < 2000)))
        return state == 1;
    chat = shown;
    state = -1;
    tried.start();
    if (shown.isEmpty())
        return false;
    // The friend list (the user's own id) may not exist yet: LINE's own names for it first.
    for (const char *name : { "Keep Memo", "Keepメモ", "Keep筆記", "Keep 笔记", "Keep笔记" }) {
        if (shown == QString::fromUtf8(name)) {
            state = 1;
            return true;
        }
    }
    const QString start = shown.endsWith(QStringLiteral("...")) ? shown.chopped(3).trimmed()
        : shown.endsWith(QChar(0x2026)) ? shown.chopped(1).trimmed() : QString();
    QString own, id;
    for (QWidget *top : QApplication::topLevelWidgets()) {
        if (!inheritsClass(top, "AllInOneWindow"))
            continue;
        for (auto *list : top->findChildren<QAbstractItemView *>(QStringLiteral("lineMR_list_friends"))) {
            QAbstractItemModel *m = list->model();
            for (int r = 0; m && own.isEmpty() && r < qMin(m->rowCount(list->rootIndex()), 20); ++r) {
                QObject *data = m->index(r, 0, list->rootIndex()).data(kItemDataRole).value<QObject *>();
                if (inheritsClass(data, "ProfileData"))
                    own = data->property("mid").toString();
            }
        }
        for (auto *list : top->findChildren<QAbstractItemView *>(QStringLiteral("lineMR_list_chats"))) {
            QAbstractItemModel *m = list->model();
            for (int r = 0; m && id.isEmpty() && r < qMin(m->rowCount(list->rootIndex()), 500); ++r) {
                QObject *data = m->index(r, 0, list->rootIndex()).data(kItemDataRole).value<QObject *>();
                if (!inheritsClass(data, "ChatData"))
                    continue;
                const QString name = cleanText(data->property("name").toString());
                if (name == shown || (!start.isEmpty() && name.startsWith(start)))
                    id = data->property("id").toString();
            }
        }
    }
    if (!own.isEmpty() && !id.isEmpty())
        state = id == own ? 1 : 0;
    return state == 1;
}

const MessageLabels &messageLabels()
{
    static const MessageLabels labels = [] {
        MessageLabels l;
        l.you = label("You");
        l.replyTo = label("Reply to %1: %2");
        l.original = label("Original message: %1");
        l.kindsToName = QStringList { label("Location"), label("Contact") };
        l.album = label("Photos");
        l.photoWords = QStringList { QStringLiteral("Photo"), QStringLiteral("รูป"), QStringLiteral("写真"),
                                     QStringLiteral("照片"), QStringLiteral("图片"), QStringLiteral("圖片") };
        l.duration = spokenDuration;
        return l;
    }();
    return labels;
}

// What LINE's own text of a message leaves out, from the row's data (the Windows bridge reads the
// same from the drawn row).
MessageRowParts messageRowParts(QAbstractItemView *view, int row, const ChatMessageFields &f, const QString &cls,
                                ListRowTextCache *cache, const QString &native)
{
    MessageRowParts parts;
    parts.captured = true;
    // Notices ("Message unsent.") have a sender but no time, also when the row's class is not known.
    const bool notice = cls.contains(QLatin1StringView("Info")) || cls.contains(QLatin1StringView("Date"))
        || cls.contains(QLatin1StringView("UnreadMsg")) || cleanText(f.timeLabel).isEmpty();
    if (f.senderMid.isEmpty() || f.id.startsWith(QLatin1Char('l')) || notice)
        return parts;
    parts.own = cache->isOwnMessage(f) || inKeepMemo(view);
    if (!parts.own && messageSettings().directChatSenderNames && !chatHasMemberCount(view))
        parts.sender = chatNameFor(view);
    if (!cleanText(f.locationTitle).isEmpty()) {
        parts.kind = label("Location");
    } else if (cleanText(f.text).isEmpty()) {
        parts.kind = cls.contains(QLatin1StringView("MultipleImage")) ? label("Photos") : messageKindLabel(cls);
        // A row that has not been on screen has no class yet.
        if (parts.kind.isEmpty() && !f.contactMid.isEmpty())
            parts.kind = label("Contact");
        else if (parts.kind.isEmpty() && f.mediaPath.contains(QLatin1StringView("sticker"), Qt::CaseInsensitive))
            parts.kind = label("Sticker");
        // The contact's name is drawn only.
        if (cls.contains(QLatin1StringView("Contact")))
            parts.details << firstPaintedLine(view, view->model()->index(row, 0, view->rootIndex()));
    }
    if (cls.contains(QLatin1StringView("Call")) || cls.contains(QLatin1StringView("Audio")) || cls.contains(QLatin1StringView("Video"))) {
        // "00:07, 20.49, Read": a clock before the time the message was sent is its length.
        static const QRegularExpression clock(QStringLiteral("^\\d{1,2}:\\d{2}(:\\d{2})?$"));
        const QStringList fields = native.split(QStringLiteral(", "));
        qsizetype end = fields.size();
        while (end > 0 && isMessageTimeOrReceipt(fields.at(end - 1)) && !fields.at(end - 1).contains(QLatin1Char(':'))
               && !fields.at(end - 1).contains(QLatin1Char('.')))
            --end;
        for (qsizetype i = 0; i + 1 < end; ++i) {
            if (clock.match(fields.at(i).trimmed()).hasMatch())
                parts.lengths << fields.at(i).trimmed();
        }
        if (parts.lengths.isEmpty() && !cleanText(f.duration).isEmpty())
            parts.lengths << cleanText(f.duration);
    }
    for (const QString &detail : { f.fileSize, f.fileStatus }) {
        if (const QString t = cleanText(detail); !t.isEmpty() && !cleanText(f.fileName).isEmpty())
            parts.details << t;
    }
    parts.reactions = messageReactions(view, row, f.id);
    return parts;
}

// LINE's own text of a message (LINE 26.6: Qt::AccessibleTextRole of ChatMessageModel) with what only
// the row's data tells; "" when LINE gives none.
QString nativeMessageRowText(QAbstractItemView *view, int row, bool checkPrevious = true)
{
    QAbstractItemModel *model = view->model();
    ListRowTextCache *cache = ListRowTextCache::forView(view);
    if (!cache || !inheritsClass(model, "ChatMessageModel") || !ancestorInheriting(view, "ChatMessageView")
        || ancestorInheriting(view, "SearchDetailPanel"))
        return QString();
    const QModelIndex idx = model->index(row, 0, view->rootIndex());
    const QString native = nativeMessageText(idx.data(Qt::AccessibleTextRole));
    if (native.isEmpty())
        return QString();
    const ChatMessageFields fields = readChatMessageData(idx.data(kItemDataRole).value<QObject *>());
    // "Voice message duration 7 seconds", "Video duration 241 seconds": in words, as other lengths.
    QString body = native;
    if (const QString length = cleanText(fields.duration); !length.isEmpty()) {
        const QStringList clock = length.split(QLatin1Char(':'));
        int total = 0;
        for (const QString &part : clock)
            total = total * 60 + part.toInt();
        const QRegularExpression seconds(QStringLiteral("(^|\\D)%1(\\D|$)").arg(total));
        QStringList parts = body.split(QStringLiteral(", "));
        for (QString &field : parts) {
            if (field.contains(seconds) && !isMessageTimeOrReceipt(field)) {
                field = spokenDuration(length);
                break;
            }
        }
        body = parts.join(QStringLiteral(", "));
    }
    QString text = withMessageParts(body, messageRowParts(view, row, fields, cache->delegateClassFor(row), cache, native),
                                    messageLabels());
    if (checkPrevious && row > 0 && messageSettings().senderOnlyWhenChanged)
        text = withoutRepeatedSender(text, nativeMessageRowText(view, row - 1, false));
    static int logged = 0;
    if (logged++ < 8)
        a11yLog("[message-text] row %d: LINE's text (%d chars)", row, int(native.size()));
    return text;
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
        if (QString native = nativeMessageRowText(view, row); !native.isEmpty())
            return native;
        // Message delegates may still show text from an earlier row: use the data object only.
        ListRowTextCache *cache = ListRowTextCache::forView(view);
        const ChatMessageFields fields = readChatMessageData(data);
        if (!cache)
            return chatMessageText(fields, false, QString(), [] { return QStringList(); });
        QString text = chatMessageText(fields, cache->isOwnMessage(fields), cache->delegateClassFor(row),
                                       [cache, row] { return cache->visibleTexts(row); });
        // Reactions are drawn under the message only (ChatMessageData has none).
        if (const QString reactions = messageReactions(view, row, fields.id); !reactions.isEmpty() && !text.isEmpty())
            text += QStringLiteral(", ") + reactions;
        return text;
    }
    // Rows LINE gives no text for (Notes posts, the photo grid, search results, sticker packages): what
    // it draws.
    if (QString painted = paintedListRowText(view, row); !painted.isEmpty())
        return painted;
    if (QString text = packageRowText(view, row, data); !text.isEmpty())
        return text;
    if (QString text = dataObjectText(data); !text.isEmpty()) {
        if (inheritsClass(data, "ChatData") && ancestorInheriting(view, "MainChatPanel"))
            return withChatStatus(view, row, text, data);
        return text;
    }
    if (ListRowTextCache *cache = ListRowTextCache::forView(view)) {
        if (QString text = cache->text(row); !text.isEmpty())
            return text;
    }
    // Plain models (Settings' translation languages) give text even for rows off screen.
    const QVariant display = idx.data(Qt::DisplayRole);
    return display.metaType().id() == QMetaType::QString ? cleanText(display.toString()) : QString();
}

// Whether a row has nothing to say (it is then left out of the accessibility tree). Qt's Cocoa bridge
// asks every row's state() each time VoiceOver reads the list's children, several times per arrow
// step: building the full text of every row there (all of a chat's properties, the open chat's
// header) took about 0.9 s per step in a chat list of a few hundred chats (measured 2026-11-03).
// Rows with a name are never blank; other answers are kept while the row holds the same data object
// (QPointer: LINE reuses freed objects' addresses), a blank one only briefly (OCR may fill it in).
bool rowIsBlank(QAbstractItemView *view, int row)
{
    struct Seen {
        QPointer<QObject> data;
        bool hasData = false;
        bool blank = false;
        qint64 at = 0;
    };
    static QHash<QPair<const QAbstractItemView *, int>, Seen> seen;
    if (seen.size() > 20000)
        seen.clear();
    QObject *data = rowData(view, row);
    Seen &entry = seen[qMakePair(static_cast<const QAbstractItemView *>(view), row)];
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const bool same = entry.at && entry.hasData == (data != nullptr) && entry.data.data() == data;
    if (same && now - entry.at < (entry.blank ? 1000 : 30000))
        return entry.blank;
    bool named = false;
    if (data) {
        // (LINE computes a chat's name in its getter: read only when the row's object is new.)
        for (const char *name : { "name", "displayName" }) {
            const QVariant value = data->property(name);
            if (value.metaType().id() == QMetaType::QString && !value.toString().trimmed().isEmpty()) {
                named = true;
                break;
            }
        }
    }
    const bool blank = !named && rowText(view, row).isEmpty();
    entry = Seen { data, data != nullptr, blank, now };
    return blank;
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

// The row `r` of `view` recorded as it is painted, in "Windows" coordinates relative to the row
// (see kWindowsScale); fromWindows() converts back to viewport units relative to the row.
CaptureResult captureRowRect(QAbstractItemView *view, const QRect &r)
{
    return scaledCapture(captureRegionText(view->viewport(), r), kWindowsScale);
}

QRectF fromWindows(const QRectF &r)
{
    return QRectF(r.topLeft() / kWindowsScale, r.size() / kWindowsScale);
}

QPointF fromWindows(const QPointF &p)
{
    return p / kWindowsScale;
}

// ---- Reactions -----------------------------------------------------------------------------------

// Reactions given to a message: small round faces LINE draws just under its bubble or picture
// ("Windows" coordinates).
bool isReactionBadge(const CaptureResult &cap, const QRectF &icon)
{
    if (icon.width() > 26 || icon.height() > 26)
        return false;
    for (const PaintedImage &above : cap.images) {
        const QRectF &b = above.rect;
        if (b != icon && b.width() >= 40 && b.height() >= 30 && icon.top() >= b.bottom() - 6
            && icon.top() <= b.bottom() + 20 && icon.right() >= b.left() && icon.left() <= b.right())
            return true;
    }
    return false;
}

// The reactions under a message: "Reactions: Like, Funny, 3 people" (LINE draws up to 7 faces, one
// per kind given, left to right, and the number of people; no number per kind), "Like 2 people"
// with one kind, "has reactions" when the faces are not recognised. "" without reactions.
QString reactionSummary(const CaptureResult &cap)
{
    QList<const PaintedImage *> badges;
    QRectF faces;
    for (const PaintedImage &pi : cap.images) {
        if (pi.icon.startsWith(QLatin1StringView("badge-")) && isReactionBadge(cap, pi.rect)) {
            badges << &pi;
            faces = faces.united(pi.rect);
        }
    }
    if (badges.isEmpty())
        return QString();
    std::sort(badges.begin(), badges.end(), [](const PaintedImage *a, const PaintedImage *b) { return a->rect.x() < b->rect.x(); });
    QStringList names;
    for (const PaintedImage *pi : std::as_const(badges)) {
        if (const QString name = humanizeIconName(pi->icon); !names.contains(name))
            names << name;
    }
    // The number of people who reacted, drawn right of the faces.
    QString count;
    static const QRegularExpression number(QStringLiteral("^\\d[\\d,]*\\+?$"));
    for (const CapturedText &it : cap.items) {
        const QString t = cleanText(it.text);
        if (it.pos.x() >= faces.left() && it.pos.y() >= faces.top() - 6 && it.pos.y() <= faces.bottom() + 6
            && number.match(t).hasMatch()) {
            count = t;
            break;
        }
    }
    if (names.isEmpty())
        return label("has reactions");
    if (names.size() == 1)
        return count.isEmpty() ? label("Reaction: %1").arg(names.first()) : label("%1 %2 people").arg(names.first(), count);
    const QString kinds = label("Reactions: %1").arg(names.join(QStringLiteral(", ")));
    return count.isEmpty() ? kinds : label("%1, %2 people").arg(kinds, count);
}

// Reactions of the message at `row`, read from what LINE draws under it; remembered per message
// (by its id) while it is out of view.
QString messageReactions(QAbstractItemView *view, int row, const QString &messageId)
{
    struct Seen {
        QString text;
        qint64 at = 0;
    };
    static QHash<QString, Seen> seen;
    if (messageId.isEmpty() || safeMode())
        return QString();
    Seen &entry = seen[messageId];
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const QRect r = view->visualRect(view->model()->index(row, 0, view->rootIndex()));
    const bool onScreen = !r.isEmpty() && view->viewport()->rect().contains(r);
    if (!onScreen || (entry.at && now - entry.at < 1500))
        return entry.text;
    const CaptureResult cap = captureRowRect(view, r);
    if (cap.skipped)
        return entry.text;
    entry.text = reactionSummary(cap);
    entry.at = now;
    if (seen.size() > 5000)
        seen.clear();
    return entry.text;
}

// A sender's round picture beside a received message (row coordinates; LINE also draws it as a
// filled shape with the picture as its brush).
bool isSenderPicture(const QRectF &r)
{
    return r.width() >= 30 && r.width() <= 45 && r.height() >= 30 && r.height() <= 45 && r.left() < 20 && r.top() >= -4
        && qAbs(r.width() - r.height()) <= 4;
}

QRectF senderPicture(const CaptureResult &cap)
{
    for (const PaintedImage &pi : cap.images) {
        if (isSenderPicture(pi.rect))
            return pi.rect;
    }
    for (const PaintedShape &sh : cap.shapes) {
        if (!sh.texture.isEmpty() && isSenderPicture(sh.rect))
            return sh.rect;
    }
    return QRectF();
}

// Who a message row is from. The Windows bridge tells it from where LINE draws the row; here the
// row's ChatMessageData says it (own messages by ListRowTextCache::isOwnMessage(), dates and
// notices by their id / delegate).
enum class RowSide { Empty, Received, Other };

RowSide rowSide(QAbstractItemView *view, int row)
{
    QObject *data = rowData(view, row);
    if (!inheritsClass(data, "ChatMessageData"))
        return RowSide::Empty;
    const ChatMessageFields f = readChatMessageData(data);
    if (f.id.isEmpty())
        return RowSide::Empty;
    if (f.id.startsWith(QLatin1Char('l')) || f.senderMid.isEmpty())
        return RowSide::Other; // dates, markers, notices
    ListRowTextCache *cache = ListRowTextCache::forView(view);
    if (cache && (cache->isOwnMessage(f) || cache->delegateClassFor(row).contains(QLatin1StringView("Info"))))
        return RowSide::Other;
    return RowSide::Received;
}

// The sender's name of a received message (as LINE shows it, else from the lists' data objects).
QString senderNameOf(QAbstractItemView *view, int row)
{
    const ChatMessageFields f = readChatMessageData(rowData(view, row));
    if (QString name = cleanText(f.senderName); !name.isEmpty())
        return name;
    return contactForMid(f.senderMid).name;
}

struct ProfileOffer {
    QPointer<QAbstractItemView> view;
    QPersistentModelIndex index;
    QElapsedTimer at;
    // Judged before the menu opens (while a menu shows, the capture may differ).
    RowSide side = RowSide::Empty;
    bool reactable = false; // "React" is offered (not for dates, notices, calls)
    bool reacted = false;   // the user has reacted: "Remove reaction" instead
    bool voice = false;     // a voice message: "Transcribe voice message"
    bool video = false;     // a video message: "Transcribe video"
    const char *noReaction = nullptr; // why not, for the log
} g_profileOffer;

constexpr const char *kExtraMenuItemProperty = "_lineA11yExtraMenuItem";

QHash<const QWidget *, std::function<void()>> &extraMenuActions()
{
    static QHash<const QWidget *, std::function<void()>> actions;
    return actions;
}

// The bridge's own menu item: invisible (1 px, paints nothing), present for the keyboard and
// VoiceOver only.
class ExtraMenuItem : public QAccessibleWidget
{
public:
    explicit ExtraMenuItem(QWidget *w)
        : QAccessibleWidget(w, QAccessible::MenuItem)
    {
    }
    QString text(QAccessible::Text t) const override
    {
        return t == QAccessible::Name ? widget()->accessibleName() : QString();
    }
    QAccessible::State state() const override
    {
        QAccessible::State st = QAccessibleWidget::state();
        st.focusable = true;
        st.focused = widget()->hasFocus();
        return st;
    }
    // A 1 px item would be a dot for VoiceOver's cursor: the size of the menu's last item instead.
    QRect rect() const override
    {
        QWidget *menu = widget()->parentWidget();
        if (!menu)
            return QAccessibleWidget::rect();
        const QRect bottom(menu->mapToGlobal(QPoint(0, qMax(0, menu->height() - 30))), QSize(menu->width(), 30));
        return bottom;
    }
    QStringList actionNames() const override { return { pressAction() }; }
    void doAction(const QString &action) override
    {
        if (action != pressAction())
            return;
        if (const std::function<void()> press = extraMenuActions().value(widget()))
            QTimer::singleShot(0, widget(), press);
    }
};

// ---- Search results and Notes (from what LINE paints; "Windows" coordinates) --------------------

// A row of a chat's search results (ChatSearchResultWindow): the sender and the date on the first
// line (the date drawn at the right edge), the matching text below, wrapped. Read as "sender, date,
// text".
QString searchResultRowText(QWidget *viewport, const QRect &rowRect, bool *skipped)
{
    const CaptureResult cap = scaledCapture(captureRegionText(viewport, rowRect), kWindowsScale);
    *skipped = cap.skipped;
    if (cap.skipped)
        return QString();
    struct Part {
        qreal y;
        qreal x;
        qreal right;
        QString text;
    };
    QList<Part> parts;
    for (const CapturedText &it : cap.items) {
        if (it.text.trimmed().isEmpty())
            continue;
        parts.append({ it.pos.y(), it.pos.x(), it.pos.x() + it.width, it.text });
    }
    // Lines: baselines a few pixels apart are one line (the date's font is smaller than the name's).
    std::stable_sort(parts.begin(), parts.end(), [](const Part &a, const Part &b) { return a.y < b.y; });
    qreal lineY = -1000;
    for (Part &p : parts) {
        if (p.y - lineY > 4)
            lineY = p.y;
        p.y = lineY;
    }
    std::stable_sort(parts.begin(), parts.end(), [](const Part &a, const Part &b) {
        return a.y != b.y ? a.y < b.y : a.x < b.x;
    });
    // Runs LINE draws separately but touching are one text.
    QList<Part> merged;
    for (const Part &p : std::as_const(parts)) {
        if (!merged.isEmpty() && merged.last().y == p.y && p.x - merged.last().right < 6) {
            merged.last().text += p.text;
            merged.last().right = p.right;
        } else {
            merged.append(p);
        }
    }
    auto isThai = [](QChar c) { return c.unicode() >= 0x0E00 && c.unicode() <= 0x0E7F; };
    QString out;
    for (qsizetype i = 0; i < merged.size(); ++i) {
        const QString t = cleanText(merged[i].text);
        if (t.isEmpty())
            continue;
        if (out.isEmpty()) {
            out = t;
            continue;
        }
        const bool header = merged[i].y == merged.first().y || merged[i - 1].y == merged.first().y;
        if (header)
            out += QStringLiteral(", ") + t;
        else if (isThai(out.back()) && isThai(t.front()))
            out += t; // Thai wraps anywhere
        else
            out += QLatin1Char(' ') + t;
    }
    return out;
}

// A post's photos and videos (Notes of a group / OpenChat: TimelineListView rows drawn by
// PostContentDelegateWidget): pictures of at least 100x80, duplicates (placeholder + picture) once.
// `videos` tells which ones show a play button (album_note/play_icon.svg, 20x20 at the bottom left).
QList<QRectF> postMedia(const CaptureResult &cap, QList<bool> *videos)
{
    QList<QRectF> media;
    for (const PaintedImage &pi : cap.images) {
        if (pi.rect.width() < 100 || pi.rect.height() < 80)
            continue;
        bool seen = false;
        for (const QRectF &m : std::as_const(media))
            seen = seen || m.intersected(pi.rect).width() * m.intersected(pi.rect).height() > 0.8 * m.width() * m.height();
        if (!seen)
            media << pi.rect;
    }
    if (videos) {
        videos->clear();
        for (const QRectF &m : std::as_const(media)) {
            bool video = false;
            for (const PaintedImage &pi : cap.images) {
                if (!m.contains(pi.rect.center()) || pi.rect.width() > 48 || pi.rect.height() > 48)
                    continue;
                video = video || pi.icon == QLatin1StringView("video")
                    || (pi.alpha && pi.rect.width() >= 14 && pi.rect.height() >= 14 && pi.rect.center().x() < m.center().x()
                        && pi.rect.center().y() > m.center().y());
            }
            videos->append(video);
        }
    }
    return media;
}

// The post's own text (what Copy text copies): the lines under the author's name and above the
// reaction / comment bar, outside the pictures; lines on one baseline joined, others on new lines.
QString postBodyText(const CaptureResult &cap, const QRect &rowRect)
{
    qreal barTop = rowRect.height() * kWindowsScale - 50;
    for (const PaintedImage &pi : cap.images) {
        if (pi.icon.startsWith(QLatin1StringView("note-")))
            barTop = qMin(barTop, pi.rect.top() - 2);
    }
    const QList<QRectF> media = postMedia(cap, nullptr);
    QList<const CapturedText *> lines;
    for (const CapturedText &it : cap.items) {
        if (cleanText(it.text).isEmpty() || it.pos.y() < 40 || it.pos.y() > barTop)
            continue;
        bool inMedia = false;
        for (const QRectF &m : media)
            inMedia = inMedia || m.contains(it.pos);
        if (!inMedia)
            lines << &it;
    }
    std::stable_sort(lines.begin(), lines.end(), [](const CapturedText *a, const CapturedText *b) {
        return qAbs(a->pos.y() - b->pos.y()) > 4 ? a->pos.y() < b->pos.y() : a->pos.x() < b->pos.x();
    });
    QString out;
    qreal lastY = -1000;
    for (const CapturedText *it : std::as_const(lines)) {
        if (out.isEmpty())
            out = it->text.trimmed();
        else if (qAbs(it->pos.y() - lastY) <= 4)
            out += it->text; // runs on one line
        else
            out += QLatin1Char('\n') + it->text.trimmed();
        lastY = it->pos.y();
    }
    return out.trimmed();
}

// The "More options" button of a post (album_note/more_icon.svg, top right), from the hidden row
// template LINE draws the posts with: its centre relative to the row.
QPointF postMoreButtonPoint()
{
    for (QWidget *top : QApplication::topLevelWidgets()) {
        if (!inheritsClass(top, "PostContentDelegateWidget"))
            continue;
        for (QWidget *child : top->findChildren<QWidget *>()) {
            if (inheritsClass(child, "LcButton") && iconSource(child).contains(QLatin1StringView("album_note/more_icon")))
                return QPointF(child->mapTo(top, QPoint())) + QPointF(child->width() / 2.0, child->height() / 2.0);
        }
    }
    return QPointF();
}

// A post: author, text, its photos / videos, the numbers of reactions and comments, the time
// ("Peet, Video, 2 comments, 8 minutes ago").
QString postRowText(QWidget *viewport, const QRect &rowRect, bool *skipped)
{
    const CaptureResult cap = scaledCapture(captureRegionText(viewport, rowRect), kWindowsScale);
    *skipped = cap.skipped;
    if (cap.skipped)
        return QString();
    struct Part {
        qreal y;
        qreal x;
        qreal right;
        QString text;
    };
    QList<Part> parts;
    for (const CapturedText &it : cap.items) {
        if (!cleanText(it.text).isEmpty())
            parts.append({ it.pos.y(), it.pos.x(), it.pos.x() + it.width, it.text });
    }
    // The numbers beside the reaction / comment buttons say what they count.
    static const QRegularExpression number(QStringLiteral("^\\d[\\d,.]*[KkMm+]?$"));
    for (Part &p : parts) {
        if (!number.match(cleanText(p.text)).hasMatch())
            continue;
        for (const PaintedImage &pi : cap.images) {
            if (!pi.icon.startsWith(QLatin1StringView("note-")) || p.x < pi.rect.right() - 2 || p.x > pi.rect.right() + 12
                || p.y < pi.rect.top() || p.y > pi.rect.bottom() + 6)
                continue;
            p.text = label(pi.icon == QLatin1StringView("note-comments") ? "%1 comments" : "%1 reactions").arg(cleanText(p.text));
            break;
        }
    }
    QList<bool> videos;
    const QList<QRectF> media = postMedia(cap, &videos);
    if (!media.isEmpty()) {
        const qsizetype videoCount = videos.count(true);
        const qsizetype photoCount = media.size() - videoCount;
        QStringList kinds;
        if (media.size() == 1) {
            kinds << label(videoCount ? "Video" : "Photo");
        } else {
            if (photoCount)
                kinds << label("%1 photos").arg(photoCount);
            if (videoCount)
                kinds << label("%1 videos").arg(videoCount);
        }
        qreal top = media.first().top();
        for (const QRectF &m : media)
            top = qMin(top, m.top());
        parts.append({ top, 0, 0, kinds.join(QStringLiteral(", ")) });
    }
    // Lines: baselines a few pixels apart are one line.
    std::stable_sort(parts.begin(), parts.end(), [](const Part &a, const Part &b) { return a.y < b.y; });
    qreal lineY = -1000;
    for (Part &p : parts) {
        if (p.y - lineY > 4)
            lineY = p.y;
        p.y = lineY;
    }
    std::stable_sort(parts.begin(), parts.end(), [](const Part &a, const Part &b) {
        return a.y != b.y ? a.y < b.y : a.x < b.x;
    });
    auto isThai = [](QChar c) { return c.unicode() >= 0x0E00 && c.unicode() <= 0x0E7F; };
    QString out;
    const Part *last = nullptr;
    for (const Part &p : std::as_const(parts)) {
        const QString t = cleanText(p.text);
        if (t.isEmpty())
            continue;
        if (!last) {
            out = t;
        } else if (last->y == p.y && p.x - last->right < 6 && p.right > 0) {
            out += t; // runs LINE draws separately
        } else if (last->y != p.y && qAbs(last->x - p.x) <= 2 && p.right > 0 && last->right > 0
                   && p.y - last->y < 30 && p.y > 40) {
            // A wrapped line of the post's text (Thai wraps anywhere).
            out += isThai(out.back()) && isThai(t.front()) ? t : QLatin1Char(' ') + t;
        } else {
            out += QStringLiteral(", ") + t;
        }
        last = &p;
    }
    return out;
}

// ---- Sticker packages ----------------------------------------------------------------------------

// Sticker / emoji package names in package order, read from "My stickers" and kept in
// sticker-packages.txt (kind TAB position TAB name) for the next start.
QStringList &packageNames(bool emoji)
{
    static QStringList lists[2];
    static bool loaded = false;
    if (!loaded) {
        loaded = true;
        QFile file(bridgeDirectory() + QStringLiteral("sticker-packages.txt"));
        if (file.open(QIODevice::ReadOnly | QIODevice::Text)) {
            for (const QString &line : QString::fromUtf8(file.readAll()).split(QLatin1Char('\n'))) {
                const QStringList parts = line.split(QLatin1Char('\t'));
                if (parts.size() != 3)
                    continue;
                QStringList &list = lists[parts.at(0) == QLatin1StringView("emoji") ? 1 : 0];
                const int at = parts.at(1).toInt();
                if (at < 0 || at > 500)
                    continue;
                while (list.size() <= at)
                    list << QString();
                list[at] = parts.at(2);
            }
        }
    }
    return lists[emoji ? 1 : 0];
}

void notePackageName(bool emoji, int row, const QString &name, int rows)
{
    QStringList &list = packageNames(emoji);
    if (rows <= 0 || row < 0 || row >= rows || (list.size() == rows && list.at(row) == name))
        return;
    while (list.size() < rows)
        list << QString();
    while (list.size() > rows)
        list.removeLast();
    list[row] = name;
    QString out;
    for (int kind = 0; kind < 2; ++kind) {
        const QStringList &names = packageNames(kind == 1);
        for (qsizetype i = 0; i < names.size(); ++i)
            out += QStringLiteral("%1\t%2\t%3\n").arg(kind == 1 ? QStringLiteral("emoji") : QStringLiteral("sticker")).arg(i).arg(names.at(i));
    }
    QFile file(bridgeDirectory() + QStringLiteral("sticker-packages.txt"));
    if (file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
        file.write(out.toUtf8());
    a11yLog("[sticker] %s package %d is \"%s\"", emoji ? "emoji" : "sticker", row + 1, qUtf8Printable(name));
}

// The topmost line LINE draws in a list row (a package's name above its status).
QString firstPaintedLine(QAbstractItemView *view, const QModelIndex &index)
{
    const QRect r = view->visualRect(index);
    if (r.isEmpty() || !view->viewport()->rect().intersects(r))
        return QString();
    const CaptureResult cap = captureRegionText(view->viewport(), r);
    if (cap.skipped || cap.items.isEmpty())
        return QString();
    qreal top = cap.items.first().pos.y();
    for (const CapturedText &it : cap.items)
        top = qMin(top, it.pos.y());
    QList<const CapturedText *> line;
    for (const CapturedText &it : cap.items) {
        if (qAbs(it.pos.y() - top) < 1 && !it.text.trimmed().isEmpty())
            line << &it;
    }
    std::sort(line.begin(), line.end(), [](const CapturedText *a, const CapturedText *b) { return a->pos.x() < b->pos.x(); });
    QString text;
    for (const CapturedText *it : std::as_const(line))
        text += it->text;
    return cleanText(text);
}

// The whole text LINE draws in a row, in reading order (rows of lists whose data has no properties).
QString paintedRowLines(QAbstractItemView *view, const QModelIndex &index)
{
    const QRect r = view->visualRect(index);
    if (r.isEmpty() || !view->viewport()->rect().intersects(r))
        return QString();
    const CaptureResult cap = captureRegionText(view->viewport(), r);
    if (cap.skipped)
        return QString();
    return cleanText(capturedTextInReadingOrder(cap).replace(QLatin1Char('\n'), QLatin1StringView(", ")));
}

// The chat list: "Selected" before the name for the chat that is open (LINE's current row; the
// bridge's cursor is separate; user request on Windows), and "Pinned" right after the name (LINE
// draws a pin badge on the picture; ChatData has no property for it).
bool chatPinned(QAbstractItemView *view, int row, QObject *data)
{
    struct Seen {
        bool pinned = false;
        qint64 at = 0;
    };
    static QHash<QString, Seen> seen;
    const QString id = data->property("id").toString();
    Seen &entry = seen[id];
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const QRect r = view->visualRect(view->model()->index(row, 0, view->rootIndex()));
    const bool onScreen = !r.isEmpty() && view->viewport()->rect().contains(r);
    if (!onScreen || safeMode() || (entry.at && now - entry.at < 1500))
        return entry.pinned; // off screen: what the row showed last time
    const CaptureResult cap = captureRegionText(view->viewport(), r);
    if (cap.skipped)
        return entry.pinned;
    entry.pinned = false;
    static int logged = 0;
    if (logged++ < 12) {
        QStringList drawn;
        for (const PaintedImage &image : cap.images)
            drawn << QStringLiteral("%1x%2@%3,%4%5 %6").arg(image.size.width()).arg(image.size.height()).arg(image.rect.x())
                         .arg(image.rect.y()).arg(image.icon.isEmpty() ? QString() : u'=' + image.icon,
                                                  image.average.isValid() ? image.average.name() : QString());
        for (const PaintedShape &shape : cap.shapes)
            drawn << QStringLiteral("shape %1x%2@%3,%4 %5").arg(shape.rect.width()).arg(shape.rect.height())
                         .arg(shape.rect.x()).arg(shape.rect.y()).arg(shape.texture.isEmpty() ? QString() : QStringLiteral("textured"));
        for (const CapturedText &it : cap.items)
            drawn << QStringLiteral("text@%1,%2").arg(it.pos.x()).arg(it.pos.y());
        a11yLog("[list] chat row %d: %s", row, qPrintable(drawn.join(u' ')));
    }
    for (const PaintedImage &image : cap.images) {
        // The blue badge (pin-badge.svg, #587DE4) on the picture's lower right corner; the same place
        // holds a green badge for OpenChats. (Its shape alone matches round profile pictures.)
        const QColor c = image.average;
        if (c.isValid() && image.size.width() >= 20 && c.blue() > c.red() + 60 && c.blue() > c.green() + 30)
            entry.pinned = true;
    }
    entry.at = now;
    return entry.pinned;
}

// Is `data` (a ChatData of the chat list) the chat shown beside the list? LINE's current row is not:
// it follows the arrows and right clicks without opening the chat. The open chat is the one named in
// the chat header (name, and member count for groups: two chats can have the same name).
bool isOpenChat(QAbstractItemView *view, QObject *data)
{
    QString shown;
    int members = -1;
    if (!openChatHeader(view, &shown, &members))
        return false;
    const QString name = cleanText(data->property("name").toString());
    if (name.isEmpty())
        return false;
    bool same = name == shown;
    // A long name is cut short in the header ("Grande Pleno (รังสิต): ขายอา...").
    for (const QString &ellipsis : { QStringLiteral("..."), QStringLiteral("\u2026") }) {
        if (!same && shown.endsWith(ellipsis)) {
            const QString start = shown.chopped(ellipsis.size()).trimmed();
            same = !start.isEmpty() && name.startsWith(start);
        }
    }
    if (!same)
        return false;
    const QVariant count = data->property("memberCount");
    return members < 0 || !count.isValid() || count.toInt() <= 0 || count.toInt() == members;
}

QString withChatStatus(QAbstractItemView *view, int row, const QString &text, QObject *data)
{
    QString result = text;
    // Right after the name: "Pinned" and the kind of chat (ChatData.type 3 = group, 5 = OpenChat;
    // nothing tells official accounts apart from friends).
    QStringList status;
    if (chatPinned(view, row, data))
        status << label("Pinned");
    const int type = data->property("type").toInt();
    if (type == 3)
        status << label("Group");
    else if (type == 5)
        status << label("OpenChat");
    if (!status.isEmpty()) {
        const QString name = cleanText(data->property("name").toString());
        const QString added = status.join(QStringLiteral(", "));
        if (!name.isEmpty() && text.startsWith(name))
            result = name + QStringLiteral(", ") + added + text.mid(name.size());
        else
            result = added + QStringLiteral(", ") + text;
    }
    if (isOpenChat(view, data))
        result = label("Selected") + u' ' + result;
    return result;
}

// The sticker window: "My stickers" (its Edit) draws each package's name, remembered for the package
// strip, which shows pictures only (the first is the recently used ones).
QString packageRowText(QAbstractItemView *view, int row, QObject *data)
{
    const int rows = view->model()->rowCount(view->rootIndex());
    if (inheritsClass(data, "StickerEditPackageData") || inheritsClass(data, "SticonEditPackageData")) {
        const QModelIndex idx = view->model()->index(row, 0, view->rootIndex());
        const QString text = paintedRowLines(view, idx);
        const QString name = firstPaintedLine(view, idx);
        if (name.isEmpty())
            return text;
        notePackageName(inheritsClass(data, "SticonEditPackageData"), row, name, rows);
        // Name, then its status ("never expires").
        if (text.startsWith(name) && text.size() > name.size())
            return name + QStringLiteral(", ") + text.mid(name.size()).remove(QRegularExpression(QStringLiteral("^[,\\s]+")));
        return text;
    }
    if (inheritsClass(data, "StickerPackageData") || inheritsClass(data, "SticonPackageData")) {
        if (row == 0)
            return label("Recently used");
        const QStringList &names = packageNames(inheritsClass(data, "SticonPackageData"));
        if (names.size() == rows - 1 && !names.at(row - 1).isEmpty())
            return names.at(row - 1);
        return label("Package %1").arg(row);
    }
    return QString();
}

// Rows read from what LINE paints: Notes posts, search results, the photo grid / viewer strip.
// Remembered per row position while out of view (until the list's model changes).
QString paintedListRowText(QAbstractItemView *v, int row)
{
    const bool posts = isPostList(v);
    const bool results = inheritsClass(v->window(), "ChatSearchResultWindow") && !inheritsClass(rowData(v, row), "ChatMessageData");
    const bool viewerStrip = inheritsClass(v->window(), "MediaViewerWindow");
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    const QRect r = v->visualRect(idx);
    const bool grid = ancestorInheriting(v, "MediaListPanel") && !r.isEmpty() && r.width() < v->viewport()->width() / 2;
    if (!posts && !results && !viewerStrip && !grid)
        return QString();
    struct Seen {
        QPointer<QAbstractItemModel> model;
        QString text;
        qint64 at = 0;
    };
    static QHash<QPair<const QAbstractItemView *, int>, Seen> seen;
    Seen &entry = seen[qMakePair(static_cast<const QAbstractItemView *>(v), row)];
    if (entry.model != v->model())
        entry = Seen { v->model(), QString(), 0 };
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (r.isEmpty() || !v->viewport()->rect().intersects(r) || (entry.at && now - entry.at < 1500))
        return entry.text;
    bool skipped = false;
    QString text;
    if (posts) {
        text = postRowText(v->viewport(), r, &skipped);
    } else if (results) {
        text = searchResultRowText(v->viewport(), r, &skipped);
    } else {
        // Photos and videos: a video's thumbnail has a play icon or its length.
        const CaptureResult cap = captureRowRect(v, r);
        skipped = cap.skipped;
        if (!skipped) {
            static const QRegularExpression length(QStringLiteral("^\\d{1,2}:\\d{2}(:\\d{2})?$"));
            // Only a video's length counts: LINE draws "See in chat" over the thumbnail under the mouse.
            QString painted = cleanText(capturedTextInReadingOrder(cap).replace(QLatin1Char('\n'), QLatin1Char(' ')));
            if (!length.match(painted).hasMatch())
                painted.clear();
            bool video = !painted.isEmpty();
            for (const PaintedImage &pi : cap.images) {
                video = video || pi.icon == QLatin1StringView("video") || pi.icon == QLatin1StringView("voice");
                // The grid draws a video's mark at the thumbnail's bottom left (36 px at 12,228 of 276,
                // over a shaded strip; the icon matcher may take it for something else).
                if (grid) {
                    const QRectF &ir = pi.rect;
                    video = video || (pi.alpha && ir.width() >= 24 && ir.width() <= 50 && ir.center().x() < r.width() * kWindowsScale * 0.3
                                      && ir.center().y() > r.height() * kWindowsScale * 0.65);
                }
                // The viewer's strip draws a video's mark itself: a picture at the thumbnail's bottom left.
                if (viewerStrip) {
                    const QRectF &ir = pi.rect;
                    video = video || (pi.alpha && ir.width() >= 14 && ir.width() <= 28 && ir.height() >= 14 && ir.height() <= 28
                                      && ir.center().y() > r.height() * kWindowsScale * 0.5 && ir.center().x() < r.width() * kWindowsScale * 0.4);
                }
            }
            text = painted.isEmpty() ? label(video ? "Video" : "Photo") : label(video ? "Video" : "Photo") + QStringLiteral(", ") + painted;
            // The grid's MediaData holds no sender or date: the month heading above is all there is.
            if (grid) {
                for (int h = row - 1; h >= 0; --h) {
                    const QModelIndex hi = v->model()->index(h, 0, v->rootIndex());
                    if (v->visualRect(hi).width() < v->viewport()->width() / 2)
                        continue;
                    if (const QString month = rowText(v, h); !month.isEmpty())
                        text += QStringLiteral(", ") + month;
                    break;
                }
            }
        }
    }
    if (skipped)
        return entry.text;
    if (!text.isEmpty())
        entry.text = text;
    entry.at = now;
    if (seen.size() > 4000)
        seen.clear();
    return entry.text;
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

void sendDoubleClick(QWidget *target, QPointF local)
{
    QPointer<QWidget> guard(target);
    sendClick(target, local);
    if (!guard)
        return;
    const QPointF scene = target->mapTo(target->window(), local);
    const QPointF global = target->mapToGlobal(local);
    QMouseEvent dbl(QEvent::MouseButtonDblClick, local, scene, global, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
    QCoreApplication::sendEvent(target, &dbl);
    if (!guard)
        return;
    QMouseEvent release(QEvent::MouseButtonRelease, local, scene, global, Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
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
// A chat's Photos & videos grid: the items (not the month headings, which span the grid).
bool isMediaGridItem(const QAbstractItemView *v, const QModelIndex &idx)
{
    return v && idx.isValid() && ancestorInheriting(v, "MediaListPanel")
        && v->visualRect(idx).width() < v->viewport()->width() / 2;
}

// Where a grid item's check button is, in the view (Windows, at 150 %: 20 px at 154,10 of 189 px).
QPointF mediaCheckPoint(const QRect &itemRect)
{
    return QPointF(itemRect.topLeft()) + fromWindows(QPointF(itemRect.width() * kWindowsScale - 25, 20));
}

// Whether a Photos & videos item is ticked: its check button is drawn green (unticked: a white tick
// on grey). 1 ticked, 0 not, -1 not known (not drawn). Cached briefly: VoiceOver asks many times.
int mediaTickState(QAbstractItemView *v, const QModelIndex &idx, bool fresh = false)
{
    struct Seen {
        int state = -1;
        QElapsedTimer age;
    };
    static QHash<QPair<quintptr, int>, Seen> seen;
    const QPair<quintptr, int> key(quintptr(v), idx.row());
    if (auto it = seen.constFind(key); !fresh && it != seen.cend() && it->age.isValid() && it->age.elapsed() < 400)
        return it->state;
    const QRect r = v->visualRect(idx);
    if (r.isEmpty() || !v->viewport()->rect().intersects(r))
        return -1;
    const CaptureResult cap = captureRowRect(v, r);
    if (cap.skipped)
        return seen.value(key).state;
    int state = -1;
    const QPointF check(r.width() * kWindowsScale - 25, 20); // in the capture's (Windows) coordinates
    for (const PaintedImage &pi : cap.images) {
        if (pi.rect.width() < 12 || pi.rect.width() > 40 || !pi.rect.adjusted(-6, -6, 6, 6).contains(check))
            continue;
        const QColor c = pi.average;
        if (!c.isValid())
            continue;
        state = c.green() > c.red() + 40 && c.green() > c.blue() + 20 ? 1 : 0;
        break;
    }
    if (seen.size() > 500)
        seen.clear();
    Seen &entry = seen[key];
    entry.state = state;
    entry.age.start();
    return state;
}

// The row above the oldest message of a chat, for VoiceOver (LineAccessibleList::offersOlder()):
// VoiceOver reading it means it has moved past the oldest message.
class LineAccessibleOlderItem : public QAccessibleInterface
{
public:
    explicit LineAccessibleOlderItem(QAbstractItemView *view) : m_view(view) {}
    bool isValid() const override { return m_view; }
    QObject *object() const override { return nullptr; }
    QWindow *window() const override { return m_view ? m_view->window()->windowHandle() : nullptr; }
    QAccessibleInterface *parent() const override { return QAccessible::queryAccessibleInterface(m_view.data()); }
    QAccessibleInterface *child(int) const override { return nullptr; }
    int childCount() const override { return 0; }
    int indexOfChild(const QAccessibleInterface *) const override { return -1; }
    QAccessibleInterface *childAt(int, int) const override { return nullptr; }
    void setText(QAccessible::Text, const QString &) override {}
    QAccessible::Role role() const override { return QAccessible::StaticText; }
    QAccessible::State state() const override { return QAccessible::State(); }
    QRect rect() const override
    {
        if (!m_view)
            return QRect();
        return QRect(m_view->viewport()->mapToGlobal(QPoint(0, 0)), QSize(m_view->viewport()->width(), 4));
    }
    QString text(QAccessible::Text t) const override
    {
        if (t != QAccessible::Name)
            return QString();
        nameAsked();
        return label("Loading older messages");
    }

private:
    // VoiceOver asks a row's name several times at once when its cursor lands on it, and not while
    // it reads the rows around it (measured 2026-11-09). Right after a key the keyboard focus has
    // moved and VoiceOver looks over the list the same way (a VoiceOver command is no key to LINE).
    void nameAsked() const
    {
        if (!m_nameAt.isValid() || m_nameAt.elapsed() > 300) {
            m_askedTimes = 0;
            m_afterKey = keyPressedRecently(800);
        }
        m_nameAt.start();
        if (++m_askedTimes != 2 || m_afterKey)
            return;
        // Deferred: this arrives inside a synchronous Cocoa accessibility request.
        QPointer<QAbstractItemView> view = m_view;
        QMetaObject::invokeMethod(view, [view] {
            if (LineAccessibleList *list = LineAccessibleList::listFor(view))
                list->loadOlderForVoiceOver();
        }, Qt::QueuedConnection);
    }

    QPointer<QAbstractItemView> m_view;
    mutable QElapsedTimer m_nameAt;
    mutable int m_askedTimes = 0;
    mutable bool m_afterKey = false;
};

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
        if (auto *list = dynamic_cast<LineAccessibleList *>(parent()))
            list->noteRowNameAsked(m_row);
        if (isMediaGridItem(m_view, index()) && mediaTickState(m_view, index()) == 1)
            return label("Selected") + QStringLiteral(", ") + rowText(m_view, m_row);
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
        } else if (isMediaGridItem(m_view, index())) {
            st.checkable = true;
            st.checked = mediaTickState(m_view, index()) == 1;
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
        if (m_view->visualRect(idx).height() <= 1 || !m_view->isVisible() || rowIsBlank(m_view, m_row))
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
                // (or the menu key) there. With the keyboard in the list, a menu gives it back there.
                if (menu && !view->hasFocus()) {
                    view->window()->activateWindow();
                    view->setFocus(Qt::PopupFocusReason); // keeps LINE's current row (see the event filter)
                }
                if (view->currentIndex() != index)
                    view->setCurrentIndex(index);
                if (menu)
                    list->openRowMenu();
                else
                    list->activateMessage();
                return;
            }
            if (menu && !view->hasFocus()) {
                // The menu gives the keyboard back to where it was opened from: this list.
                view->window()->activateWindow();
                view->setFocus(Qt::PopupFocusReason);
            }
            if (menu && list && isCursorList(view)) {
                list->setCursorRow(index.row());
                list->openCursorMenu();
                return;
            }
            // Photos & videos / Links / Files and Notes: the bridge's own menu for the item.
            if (menu && list) {
                list->setCursorRow(index.row());
                list->openContentMenu();
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
            else if (list && ancestorInheriting(view, "MainChatPanel") && isCursorList(view))
                list->focusInputWhenOpened(index.row()); // a chat: start typing (user request)
            else if (!messages)
                view->setFocus(Qt::OtherFocusReason);
        }, Qt::QueuedConnection);
    }

    int row() const { return m_row; }

private:
    bool hasMenu() const
    {
        return ancestorInheriting(m_view, "ChatMessageView") || isCursorList(m_view) || isPostList(m_view)
            || (inheritsClass(m_view->window(), "ContentViewerWindow") && !ancestorInheriting(m_view, "LcListView"));
    }

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

bool isPostList(const QWidget *w)
{
    return isLineListView(w) && inheritsClass(w, "TimelineListView");
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
    ++m_edgeRequest;
    for (const QMetaObject::Connection &c : std::as_const(m_modelConnections))
        QObject::disconnect(c);
    m_modelConnections.clear();
    m_cursor = QPersistentModelIndex();
    m_lastRead = QPersistentModelIndex();
    m_noOlder = false;
    m_voiceOverRow = -1;
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
    if (!v || !v->isVisible() || hasCursor() || (v->hasFocus() && preserveChatOpenScroll(v)))
        return;
    const QModelIndex current = v->currentIndex();
    if (!current.isValid())
        return;
    if (v->hasFocus()) {
        m_lastRead = current;
        if (!m_selectingVisibleRow)
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

void LineAccessibleList::focusLastVisibleRow(bool keepLastRead)
{
    QAbstractItemView *v = view();
    if (!v || !v->model())
        return;
    // A panel over the list (LINE's translation) can scroll it, or move LINE's own row.
    if (keepLastRead && m_lastRead.isValid() && m_lastRead.model() == v->model()) {
        if (v->currentIndex() != m_lastRead)
            v->setCurrentIndex(m_lastRead);
        else
            v->scrollTo(m_lastRead);
        return;
    }
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
    m_voiceOverRow = -1;
    ++m_edgeRequest;
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

void LineAccessibleList::focusVisibleRowOnBacktab()
{
    checkModel();
    QAbstractItemView *v = view();
    if (!v)
        return;
    const QRect area = v->viewport()->rect();
    const auto readable = [this](const QModelIndex &idx) {
        QAccessibleInterface *item = idx.isValid() ? itemAt(idx.row()) : nullptr;
        return item && !item->text(QAccessible::Name).isEmpty();
    };
    QModelIndex target;
    if (m_lastRead.isValid() && area.intersects(v->visualRect(m_lastRead)) && readable(m_lastRead)) {
        target = m_lastRead;
    } else {
        QModelIndex partlyVisible;
        for (int y = area.top(), checked = 0; y <= area.bottom() && checked < 8;) {
            const QModelIndex idx = v->indexAt(QPoint(area.center().x(), y));
            if (!idx.isValid()) {
                ++y;
                continue;
            }
            const QRect rect = v->visualRect(idx);
            y = qMax(y + 1, rect.bottom() + 1);
            ++checked;
            if (!readable(idx))
                continue;
            if (rect.top() >= area.top() && rect.bottom() <= area.bottom()) {
                target = idx;
                break;
            }
            if (!partlyVisible.isValid())
                partlyVisible = idx;
        }
        if (!target.isValid())
            target = partlyVisible;
    }
    if (!target.isValid())
        return;
    const bool autoScroll = v->hasAutoScroll();
    const QPointer<QAbstractItemView> guard = v;
    QScopedValueRollback<bool> selecting(m_selectingVisibleRow, true);
    v->setAutoScroll(false);
    v->setCurrentIndex(target);
    if (guard)
        guard->setAutoScroll(autoScroll);
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
    m_voiceOverRow = -1;
    const quint64 request = ++m_edgeRequest;
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
    // At an edge, actually reach the scroll limit (EnsureVisible can leave a spacer or
    // part of a tall row off screen). Do not makeCurrent(): it scrolls back to the anchor.
    // Only older history is loaded this way: at the newest message, Down reads it again at once
    // (below), so the user knows it is the last one.
    if (target == current && step < 0 && ancestorInheriting(v, "ChatMessageView")) {
        const QPersistentModelIndex anchor(v->currentIndex());
        // LINE only loaded history when a wheel movement CROSSED the edge: a wheel
        // sent while already at zero was accepted but did nothing. Re-arm that transition
        // by one scrollbar unit, then let LINE's own wheel handler cross the boundary.
        if (QScrollBar *bar = v->verticalScrollBar()) {
            const int inset = qMin(1, bar->maximum() - bar->minimum());
            bar->setValue(step < 0 ? bar->minimum() + inset : bar->maximum() - inset);
        }
        QWidget *viewport = v->viewport();
        const QPoint pos = viewport->rect().center();
        QWheelEvent wheel(QPointF(pos), QPointF(viewport->mapToGlobal(pos)), QPoint(),
                          QPoint(0, step < 0 ? 120 : -120), Qt::NoButton, Qt::NoModifier,
                          Qt::NoScrollPhase, false);
        QCoreApplication::sendEvent(viewport, &wheel);
        continueEdgeStep(request, key, anchor, 30);
        return true;
    }
    if (target == current)
        v->scrollTo(v->model()->index(step < 0 ? 0 : rows - 1, 0, v->rootIndex()));
    makeCurrent(target);
    return true;
}

void LineAccessibleList::continueEdgeStep(quint64 request, int key, QPersistentModelIndex anchor, int attempts)
{
    const QPointer<QAbstractItemView> listView = view();
    if (!listView || attempts <= 0)
        return;
    QTimer::singleShot(100, listView, [listView, request, key, anchor, attempts] {
        auto *list = listFor(listView);
        if (!list || list->m_edgeRequest != request || !listView->hasFocus() || !listView->isVisible()
            || !anchor.isValid() || anchor.model() != listView->model() || listView->currentIndex() != anchor) {
            return;
        }
        listView->doItemsLayout();
        const int step = (key == Qt::Key_Up || key == Qt::Key_PageUp) ? -1 : 1;
        for (int row = anchor.row() + step; row >= 0 && row < list->rowCount(); row += step) {
            const QModelIndex idx = listView->model()->index(row, 0, listView->rootIndex());
            listView->scrollTo(idx);
            if (auto *item = list->itemAt(row); item && !item->text(QAccessible::Name).isEmpty()) {
                // One key resumes once, even if LINE inserted an entire page.
                list->stepRow(key);
                return;
            }
        }
        if (attempts <= 1) {
            // Nothing older (the start of the chat): read the message again, as at any other edge.
            list->makeCurrent(anchor.row());
            return;
        }
        // Probing blank spacer rows must not undo the edge scroll either.
        if (QScrollBar *bar = listView->verticalScrollBar())
            bar->setValue(step < 0 ? bar->minimum() : bar->maximum());
        list->continueEdgeStep(request, key, anchor, attempts - 1);
    });
}

void LineAccessibleList::loadOlderForVoiceOver()
{
    static QElapsedTimer last;
    QAbstractItemView *v = view();
    if (!v || !v->isVisible() || m_loadingOlder || !offersOlder() || (last.isValid() && last.elapsed() < 1500))
        return;
    int first = -1;
    // The first real message: LINE makes new ids ("l...") for date rows when it rebuilds them.
    for (int row = 0; row < qMin(rowCount(), 40) && first < 0; ++row) {
        const QString id = readChatMessageData(rowData(v, row)).id;
        if (!id.isEmpty() && !id.startsWith(QLatin1Char('l')) && !rowText(v, row).isEmpty())
            first = row;
    }
    const QString anchorId = first >= 0 ? readChatMessageData(rowData(v, first)).id : QString();
    if (anchorId.isEmpty())
        return;
    last.start();
    m_loadingOlder = true;
    a11yLog("[list] VoiceOver went above the oldest message (row %d): asking LINE for older ones", first);
    // As Up on the oldest message (stepRow()): LINE loads history when a wheel movement crosses the edge.
    if (QScrollBar *bar = v->verticalScrollBar())
        bar->setValue(bar->minimum() + qMin(1, bar->maximum() - bar->minimum()));
    QWidget *viewport = v->viewport();
    const QPoint pos = viewport->rect().center();
    QWheelEvent wheel(QPointF(pos), QPointF(viewport->mapToGlobal(pos)), QPoint(), QPoint(0, 120), Qt::NoButton,
                      Qt::NoModifier, Qt::NoScrollPhase, false);
    QCoreApplication::sendEvent(viewport, &wheel);

    const QPointer<QAbstractItemView> listView = v;
    auto attempts = std::make_shared<int>(60);
    auto *timer = new QTimer(v);
    QObject::connect(timer, &QTimer::timeout, timer, [=] {
        auto stop = [timer] { timer->stop(); timer->deleteLater(); };
        LineAccessibleList *list = listFor(listView);
        if (!list)
            return stop();
        // By message id: LINE may rebuild its rows when it adds older ones (persistent indexes die).
        int anchorRow = -1;
        for (int row = 0; row < qMin(list->rowCount(), 400) && anchorRow < 0; ++row) {
            if (readChatMessageData(rowData(listView, row)).id == anchorId)
                anchorRow = row;
        }
        listView->doItemsLayout();
        int target = -1;
        for (int row = anchorRow - 1; row >= 0 && target < 0; --row) {
            if (!rowText(listView, row).isEmpty())
                target = row;
        }
        if (target < 0 && --*attempts > 0) {
            if (QScrollBar *bar = listView->verticalScrollBar())
                bar->setValue(bar->minimum());
            return;
        }
        stop();
        list->m_loadingOlder = false;
        if (anchorRow < 0) // another chat by now
            return;
        markUserActivity();
        const bool older = target >= 0;
        if (!older) {
            list->m_noOlder = true;
            QAccessibleEvent changed(listView.data(), QAccessible::ObjectReorder);
            QAccessible::updateAccessibility(&changed);
            target = anchorRow;
            announce(label("No older messages"), AnnounceWhen::LineActive);
        }
        a11yLog("[list] older messages: %s; VoiceOver goes to row %d of %d", older ? "loaded" : "none", target, list->rowCount());
        // VoiceOver follows the keyboard focus: to the newest of the loaded messages.
        endListBrowsing();
        if (!listView->window()->isActiveWindow())
            listView->window()->activateWindow();
        if (!listView->hasFocus())
            listView->setFocus(Qt::PopupFocusReason);
        list->makeCurrent(target);
    });
    timer->start(100);
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
        // An empty list shows a text beside it instead ("No files shared in this chat"): say it.
        if (rowCount() == 0 && widget()->parentWidget()) {
            for (QObject *sibling : widget()->parentWidget()->children()) {
                auto *text = qobject_cast<QWidget *>(sibling);
                if (text && text->isVisible() && inheritsClass(text, "LcText"))
                    if (const QString empty = cleanText(extractLcTextString(text)); !empty.isEmpty())
                        return empty;
            }
        }
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

void LineAccessibleList::noteRowNameAsked(int row)
{
    QAbstractItemView *v = view();
    if (!v || !voiceOverRunning() || !ancestorInheriting(v, "ChatMessageView"))
        return;
    if (row != m_nameRow || !m_nameAt.isValid() || m_nameAt.elapsed() > 300) {
        m_nameRow = row;
        m_nameTimes = 0;
        m_nameAfterKey = keyPressedRecently(800);
    }
    m_nameAt.start();
    if (++m_nameTimes != 2 || m_nameAfterKey)
        return;
    m_voiceOverRow = row;
    m_voiceOverId = readChatMessageData(rowData(v, row)).id;
    static int logged = 0;
    if (logged++ < 400)
        a11yLog("[voiceover] on row %d", row);
}

void LineAccessibleList::syncToVoiceOverRow()
{
    QAbstractItemView *v = view();
    if (!v || !v->model() || m_voiceOverRow < 0)
        return;
    int row = -1;
    if (!m_voiceOverId.isEmpty() && !m_voiceOverId.startsWith(QLatin1Char('l'))) {
        const int rows = rowCount();
        // Nearest first: the row has usually moved by what LINE added above it, or not at all.
        for (int distance = 0; distance < rows && row < 0; ++distance) {
            for (int candidate : { m_voiceOverRow + distance, m_voiceOverRow - distance }) {
                if (candidate >= 0 && candidate < rows && readChatMessageData(rowData(v, candidate)).id == m_voiceOverId) {
                    row = candidate;
                    break;
                }
            }
        }
    } else if (m_voiceOverRow < rowCount()) {
        row = m_voiceOverRow;
    }
    if (row < 0)
        return;
    const QModelIndex target = v->model()->index(row, 0, v->rootIndex());
    if (target != v->currentIndex()) {
        a11yLog("[keyboard] command on VoiceOver's row %d (LINE's current row was %d)", row, v->currentIndex().row());
        v->setCurrentIndex(target);
    }
}

bool LineAccessibleList::offersOlder() const
{
    QAbstractItemView *v = view();
    return v && !m_noOlder && voiceOverRunning() && rowCount() > 0 && ancestorInheriting(v, "ChatMessageView")
        && !ancestorInheriting(v, "SearchDetailPanel") && !ancestorInheriting(v, "LcListView")
        && inheritsClass(v->model(), "ChatMessageModel");
}

int LineAccessibleList::childCount() const
{
    return rowCount() + (offersOlder() ? 1 : 0);
}

QAccessibleInterface *LineAccessibleList::child(int index) const
{
    if (!offersOlder())
        return itemAt(index);
    if (index > 0)
        return itemAt(index - 1);
    if (index < 0)
        return nullptr;
    // (Key -1 of m_items: deleted with the others; schedulePrune() only drops rows past the end.)
    if (const QAccessible::Id id = m_items.value(-1)) {
        if (QAccessibleInterface *item = QAccessible::accessibleInterface(id))
            return item;
    }
    auto *item = new LineAccessibleOlderItem(view());
    m_items.insert(-1, QAccessible::registerAccessibleInterface(item));
    return item;
}

int LineAccessibleList::indexOfChild(const QAccessibleInterface *child) const
{
    if (dynamic_cast<const LineAccessibleOlderItem *>(child))
        return offersOlder() ? 0 : -1;
    const auto *item = dynamic_cast<const LineAccessibleListItem *>(child);
    if (!item || item->parent() != this)
        return -1;
    return item->row() + (offersOlder() ? 1 : 0);
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

bool LineAccessibleList::moveGridCursor(int key)
{
    QAbstractItemView *v = view();
    const int rows = rowCount();
    if (!v || rows == 0)
        return false;
    const int from = qMax(0, cursorRow());
    auto rectOf = [v](int r) { return v->visualRect(v->model()->index(r, 0, v->rootIndex())); };
    // The nearest item in the next line up or down (items are laid out in model order). From a
    // full-width heading ("October 2026") the line's first item.
    auto nextLine = [&](int start, int step) {
        const QRect a = rectOf(start);
        int lineTop = 0, best = start;
        bool inLine = false;
        qreal bestDistance = 0;
        for (int r = start + step; r >= 0 && r < rows; r += step) {
            const QRect b = rectOf(r);
            if (b.isEmpty())
                continue;
            if (!inLine) {
                if (qAbs(b.center().y() - a.center().y()) < qMax(4, a.height() / 2))
                    continue; // same line
                lineTop = b.top();
                inLine = true;
            } else if (b.top() != lineTop) {
                break;
            }
            const bool fromHeading = a.width() > 2 * b.width();
            const qreal distance = fromHeading ? qAbs(b.left() - a.left()) : qAbs(b.center().x() - a.center().x());
            if (best == start || distance < bestDistance) {
                best = r;
                bestDistance = distance;
            }
        }
        return best;
    };
    int row = from;
    switch (key) {
    case Qt::Key_Left:
        row = from - 1;
        break;
    case Qt::Key_Right:
        row = from + 1;
        break;
    case Qt::Key_Up:
    case Qt::Key_Down:
        row = nextLine(from, key == Qt::Key_Down ? 1 : -1);
        break;
    case Qt::Key_PageUp:
    case Qt::Key_PageDown: {
        const int height = qMax(1, rectOf(from).height());
        for (int i = qMax(1, v->viewport()->height() / height); i > 0; --i)
            row = nextLine(row, key == Qt::Key_PageDown ? 1 : -1);
        break;
    }
    case Qt::Key_Home:
        row = 0;
        break;
    case Qt::Key_End:
        row = rows - 1;
        break;
    default:
        return false;
    }
    row = qBound(0, row, rows - 1);
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    m_cursor = idx;
    v->scrollTo(idx);
    if (QAccessibleInterface *item = itemAt(row)) {
        // NVDA ignores a second Focus event for the same item: at either end, repeat the name.
        QAccessibleEvent event(item, row == from ? QAccessible::NameChanged : QAccessible::Focus);
        QAccessible::updateAccessibility(&event);
    }
    return true;
}

bool LineAccessibleList::clickCursorRow()
{
    QAbstractItemView *v = view();
    const int row = cursorRow();
    if (!v || row < 0)
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    const QRect r = v->visualRect(idx).intersected(v->viewport()->rect());
    if (r.isEmpty())
        return false;
    a11yLog("[keyboard] click on row %d of %s", row, v->window()->metaObject()->className());
    sendClick(v->viewport(), QRectF(r).center());
    return true;
}

bool LineAccessibleList::openCursorRow(bool newWindow)
{
    QAbstractItemView *v = view();
    QPersistentModelIndex idx = m_cursor;
    m_cursor = QPersistentModelIndex();
    if (newWindow && !idx.isValid() && v)
        idx = QPersistentModelIndex(v->currentIndex());
    if (!v || !idx.isValid())
        return false;
    // Nothing to open if it is open already. For chats that is the one in the chat header: LINE's
    // current row also moves on a right click (a row's menu) without opening that chat.
    QObject *data = idx.data(kItemDataRole).value<QObject *>();
    if (!newWindow && (inheritsClass(data, "ChatData") ? isOpenChat(v, data) : idx == QPersistentModelIndex(v->currentIndex())))
        return false;
    // A click opens the chat the way LINE expects (setting the current row alone may not). With the
    // chat room hidden a click only selects the row: a double click opens its own window.
    v->scrollTo(idx);
    const QPointF at = QRectF(v->visualRect(idx)).center();
    if (newWindow)
        sendDoubleClick(v->viewport(), at);
    else
        sendClick(v->viewport(), at);
    return true;
}

void LineAccessibleList::focusInputWhenOpened(int row)
{
    QAbstractItemView *v = view();
    QObject *data = rowData(v, row);
    if (!v || !inheritsClass(data, "ChatData"))
        return;
    QPointer<QAbstractItemView> listView(v);
    QPointer<QObject> chat(data);
    QWidget *window = v->window();
    auto started = std::make_shared<QElapsedTimer>();
    started->start();
    auto *timer = new QTimer(v);
    QObject::connect(timer, &QTimer::timeout, timer, [timer, listView, chat, window, started] {
        // LINE loads the chat (up to a few seconds) and builds its message input afresh.
        auto done = [timer] { timer->stop(); timer->deleteLater(); };
        if (!listView || !chat || started->elapsed() > 5000)
            return done();
        // The user went somewhere else meanwhile (another window, a search field): leave it there.
        QWidget *focus = QApplication::focusWidget();
        if (focus && (focus->window() != window || (isLineInputWidget(focus) && !isMessageInput(focus))))
            return done();
        if (!isOpenChat(listView, chat))
            return;
        for (QWidget *w : window->findChildren<QWidget *>()) {
            if (!w->isVisible() || !w->isEnabled() || !isMessageInput(w))
                continue;
            if (!window->isActiveWindow())
                window->activateWindow();
            endListBrowsing();
            armMessageInputFocus(); // LINE may yet move focus into the messages
            if (!w->hasFocus())
                w->setFocus(Qt::OtherFocusReason);
            a11yLog("[keyboard] chat opened from the list: focus to its message input after %lld ms",
                    static_cast<long long>(started->elapsed()));
            return done();
        }
    });
    timer->start(100);
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
    const bool sticker = cls.contains(QLatin1StringView("Sticker"));
    if (action.isEmpty() && !sticker)
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    QRect r;
    const CaptureResult cap = captureRow(v, row, &r);
    if (cap.skipped)
        return false;
    // A sound sticker's speaker button plays its sound again (user request). A click on the sticker
    // itself opens the sticker window at its package: not done.
    if (sticker) {
        QStringList seen;
        QPointF speaker;
        for (const PaintedImage &icon : cap.images) {
            seen << QStringLiteral("%1x%2@%3,%4:%5").arg(icon.rect.width()).arg(icon.rect.height()).arg(icon.rect.x())
                        .arg(icon.rect.y()).arg(icon.icon);
            if (icon.icon == QLatin1StringView("sticker-sound") && speaker.isNull())
                speaker = icon.rect.center();
        }
        const QPointF local = speaker.isNull() ? QPointF() : viewportPoint(v, r, speaker);
        if (local.isNull()) {
            a11yLog("[keyboard] sticker in message row %d has no sound button (%s)", row, qPrintable(seen.join(QLatin1Char(' '))));
            return false;
        }
        a11yLog("[keyboard] sound sticker in message row %d: click at %.0f,%.0f", row, local.x(), local.y());
        sendClick(v->viewport(), local);
        return true;
    }
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

bool LineAccessibleList::openPostMedia()
{
    QAbstractItemView *v = view();
    const int row = cursorRow();
    if (!v || !v->model() || row < 0 || !isPostList(v))
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    const QRect r = v->visualRect(idx);
    const CaptureResult cap = captureRowRect(v, r);
    if (cap.skipped)
        return false;
    QList<bool> videos;
    const QList<QRectF> media = postMedia(cap, &videos);
    if (media.isEmpty()) {
        QStringList seen;
        for (const PaintedImage &pi : cap.images)
            seen << QStringLiteral("%1x%2@%3,%4%5:%6").arg(pi.rect.width()).arg(pi.rect.height()).arg(pi.rect.x())
                        .arg(pi.rect.y()).arg(pi.alpha ? QStringLiteral("a") : QString()).arg(pi.icon);
        a11yLog("[keyboard] post row %d shows no photo or video (%s)", row, qPrintable(seen.join(QLatin1Char(' '))));
        return false;
    }
    // The first one (top, then left), where a mouse user clicks: the middle of the part on screen.
    qsizetype first = 0;
    for (qsizetype i = 1; i < media.size(); ++i) {
        if (media[i].top() < media[first].top() - 4 || (qAbs(media[i].top() - media[first].top()) <= 4 && media[i].left() < media[first].left()))
            first = i;
    }
    const QRectF shown = fromWindows(media[first]).translated(r.topLeft()).intersected(QRectF(v->viewport()->rect()).adjusted(1, 1, -1, -1));
    if (shown.isEmpty())
        return false;
    const QPointF local = shown.center();
    a11yLog("[keyboard] %s in post row %d: click at %.0f,%.0f", videos[first] ? "video" : "photo", row, local.x(), local.y());
    noteMediaOpenedFrom(v->window());
    QPointer<QWidget> viewport = v->viewport();
    QMouseEvent move(QEvent::MouseMove, local, viewport->mapTo(viewport->window(), local),
                     viewport->mapToGlobal(local), Qt::NoButton, Qt::NoButton, Qt::NoModifier);
    QCoreApplication::sendEvent(viewport, &move);
    if (viewport)
        sendClick(viewport, local);
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

bool LineAccessibleList::openSearchResult()
{
    QAbstractItemView *v = view();
    const int row = cursorRow();
    if (!v || !v->model() || row < 0 || !inheritsClass(v->window(), "ChatSearchResultWindow"))
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    sendDoubleClick(v->viewport(), QRectF(v->visualRect(idx)).center());
    // The chat this window searched: a popped-out chat window titled like it, else the main window.
    auto windowName = [](QWidget *w) {
        QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(w);
        return iface ? iface->text(QAccessible::Name) : QString();
    };
    const QString title = windowName(v->window()); // the chat's name (and member count)
    QWidget *chat = nullptr;
    for (QWidget *top : QApplication::topLevelWidgets()) {
        if (!top->isVisible())
            continue;
        const QString name = inheritsClass(top, "ChatWindow") ? windowName(top) : QString();
        if (!name.isEmpty() && !title.isEmpty() && (title.startsWith(name) || name.startsWith(title)))
            chat = top;
        else if (!chat && inheritsClass(top, "AllInOneWindow"))
            chat = top;
    }
    a11yLog("[search] result row %d opened in %s", row, chat ? chat->metaObject()->className() : "-");
    if (!chat)
        return true;
    QPointer<QWidget> guard(chat);
    QTimer::singleShot(400, chat, [guard] {
        if (!guard)
            return;
        for (auto *list : guard->findChildren<QAbstractItemView *>(QStringLiteral("lineMR_list_messages"))) {
            if (!list->isVisible())
                continue;
            guard->activateWindow();
            // Entering the messages while the search bar shows a result starts at the match.
            list->setFocus(Qt::OtherFocusReason);
            break;
        }
    });
    return true;
}

int LineAccessibleList::senderPictureRow(int row, bool scroll, QRectF *picture) const
{
    QAbstractItemView *v = view();
    if (!v || !v->model() || row < 0 || !ancestorInheriting(v, "ChatMessageView") || rowSide(v, row) != RowSide::Received)
        return -1;
    const QString sender = readChatMessageData(rowData(v, row)).senderMid;
    const QRect shownArea = v->viewport()->rect();
    // A run of messages from one person rarely has more than a few dozen rows.
    for (int r = row; r >= 0 && r > row - 40; --r) {
        const RowSide side = rowSide(v, r);
        if (side == RowSide::Empty)
            continue; // spacer rows between messages
        if (side == RowSide::Other || readChatMessageData(rowData(v, r)).senderMid != sender)
            return -1;
        const QModelIndex idx = v->model()->index(r, 0, v->rootIndex());
        if (scroll)
            v->scrollTo(idx);
        const QRect rect = v->visualRect(idx);
        if (!rect.intersects(shownArea))
            return -1;
        const CaptureResult cap = captureRowRect(v, rect);
        if (cap.skipped)
            return -1;
        const QRectF found = senderPicture(cap);
        if (found.isEmpty())
            continue;
        if (picture)
            *picture = fromWindows(found);
        return r;
    }
    return -1;
}

bool LineAccessibleList::openSenderProfile(int row)
{
    QAbstractItemView *v = view();
    QRectF picture;
    const int pictureRow = senderPictureRow(row, true, &picture);
    if (!v || pictureRow < 0)
        return false;
    const QModelIndex idx = v->model()->index(pictureRow, 0, v->rootIndex());
    QRect r = v->visualRect(idx);
    QPointF local = r.topLeft() + picture.center();
    // The picture is at the top of its row, which may reach above the viewport.
    if (!v->viewport()->rect().contains(local.toPoint())) {
        v->scrollTo(idx, QAbstractItemView::PositionAtTop);
        r = v->visualRect(idx);
        local = r.topLeft() + picture.center();
    }
    if (!v->viewport()->rect().contains(local.toPoint()))
        return false;
    a11yLog("[keyboard] sender's picture of message row %d (row %d): click at %.0f,%.0f", row, pictureRow, local.x(),
            local.y());
    QPointer<QWidget> viewport = v->viewport();
    QMouseEvent move(QEvent::MouseMove, local, viewport->mapTo(viewport->window(), local), viewport->mapToGlobal(local),
                     Qt::NoButton, Qt::NoButton, Qt::NoModifier);
    QCoreApplication::sendEvent(viewport, &move);
    if (viewport)
        sendClick(viewport, local);
    return true;
}

namespace {

// One of the bridge's items at the bottom of `menu`; `press` runs after the menu has closed.
QWidget *addExtraMenuItem(QWidget *menu, const QString &name, std::function<void()> press)
{
    auto *item = new QWidget(menu);
    item->setProperty(kExtraMenuItemProperty, true);
    item->setAccessibleName(name);
    item->setAttribute(Qt::WA_TransparentForMouseEvents);
    item->setFocusPolicy(Qt::TabFocus);
    // Below LINE's items: the menu keys reach it last (menu items are ordered top to bottom).
    item->setGeometry(0, menu->height() - 1, 1, 1);
    QPointer<QWidget> guard(menu);
    extraMenuActions().insert(item, [guard, press] {
        if (guard)
            guard->hide();
        // After the menu has closed and focus is back on the message.
        QTimer::singleShot(150, qApp, press);
    });
    QObject::connect(item, &QObject::destroyed, [item] { extraMenuActions().remove(item); });
    item->show();
    a11yLog("[menu] added \"%s\"", qUtf8Printable(name));
    return item;
}

} // namespace

namespace {
void sendHover(QWidget *target, QPointF local);
} // namespace

void addProfileMenuItem(QWidget *menu)
{
    removeExtraMenuItems(menu);
    ProfileOffer offer = g_profileOffer;
    g_profileOffer = ProfileOffer();
    if (!menu || !offer.view || !offer.index.isValid() || !offer.at.isValid() || offer.at.elapsed() > 3000)
        return;
    // "React", or "Remove reaction" once the user has reacted (judgeReactions()). LINE draws the
    // (filled) reaction button of the message under the mouse a little later: looked for again while
    // the menu shows, and the item renamed.
    if (offer.reactable) {
        QPointer<QAbstractItemView> view = offer.view;
        QPersistentModelIndex index = offer.index;
        auto remove = std::make_shared<bool>(offer.reacted);
        QPointer<QWidget> item = addExtraMenuItem(menu, label(*remove ? "Remove reaction" : "React"), [view, index, remove] {
            auto *l = view ? dynamic_cast<LineAccessibleList *>(QAccessible::queryAccessibleInterface(view.data())) : nullptr;
            if (!l || !index.isValid() || !l->openReactions(index.row(), *remove))
                a11yLog("[reaction] message row %d could not be looked at", index.isValid() ? index.row() : -1);
        });
        for (int delay : { 100, 250, 500, 900 }) {
            QTimer::singleShot(delay, item, [view, index, remove, item] {
                if (*remove || !view || !index.isValid() || !item || !item->isVisible())
                    return;
                const CaptureResult cap = captureRowRect(view, view->visualRect(index));
                if (std::none_of(cap.images.cbegin(), cap.images.cend(),
                                 [](const PaintedImage &pi) { return pi.icon == QLatin1StringView("reaction-button-on"); }))
                    return;
                *remove = true;
                item->setAccessibleName(label("Remove reaction"));
                a11yLog("[menu] the user has reacted to row %d: \"%s\"", index.row(), qUtf8Printable(item->accessibleName()));
            });
        }
    } else {
        a11yLog("[menu] no reaction item: row %d (%s)", offer.index.row(), offer.noReaction ? offer.noReaction : "empty row");
    }
    if (offer.voice || offer.video) {
        QPointer<QAbstractItemView> view = offer.view;
        QPersistentModelIndex index = offer.index;
        addExtraMenuItem(menu, label(offer.video ? "Transcribe video" : "Transcribe voice message"), [view, index] {
            auto *l = view ? dynamic_cast<LineAccessibleList *>(QAccessible::queryAccessibleInterface(view.data())) : nullptr;
            if (l && index.isValid())
                l->transcribeMessage(index.row());
        });
    }
    // The user's own messages, notices and dates have no sender to show.
    if (offer.side != RowSide::Received) {
        a11yLog("[menu] no profile item: message row %d is not a received message (%d)", offer.index.row(), int(offer.side));
        return;
    }
    auto *list = dynamic_cast<LineAccessibleList *>(QAccessible::queryAccessibleInterface(offer.view.data()));
    if (!list)
        return;
    // One-to-one chats: the chat is the other person's already, no profile item (user request on
    // Windows). (The first message of a run, with the picture, may be out of view: it is looked for
    // on press.)
    if (!chatHasMemberCount(offer.view))
        return;
    const QString name = senderNameOf(offer.view, offer.index.row());
    QPointer<QAbstractItemView> view = offer.view;
    QPersistentModelIndex index = offer.index;
    addExtraMenuItem(menu, name.isEmpty() ? label("Show the sender's profile") : label("Show %1's profile").arg(name),
                     [view, index] {
        auto *l = view ? dynamic_cast<LineAccessibleList *>(QAccessible::queryAccessibleInterface(view.data())) : nullptr;
        if (!l || !index.isValid() || !l->openSenderProfile(index.row()))
            a11yLog("[menu] no sender's picture found for message row %d", index.isValid() ? index.row() : -1);
    });
}

void removeExtraMenuItems(QWidget *menu)
{
    if (!menu)
        return;
    for (QWidget *w : menu->findChildren<QWidget *>()) {
        if (isExtraMenuItem(w)) {
            w->hide();
            w->deleteLater();
        }
    }
}

bool isExtraMenuItem(const QWidget *w)
{
    return w && w->property(kExtraMenuItemProperty).toBool();
}

QAccessibleInterface *extraMenuItemAccessible(QWidget *w)
{
    if (!isExtraMenuItem(w))
        return nullptr;
    return new ExtraMenuItem(w);
}

namespace {

// Whether the message menu offers "React" / "Remove reaction" for a row. LINE draws a message's
// reaction button (filled when the user has reacted) while the mouse is over it; dates and notices
// get none, and calls are left out (user request: LINE draws the button beside them too). Without
// the button, a row with a time that is not centred is a message.
void judgeReactions(ProfileOffer &offer, QAbstractItemView *view, int row, const QRect &r, const CaptureResult &first)
{
    // What the row is comes from its data: dates, markers and notices get no reactions, and calls
    // are left out (user request on Windows: LINE draws the button beside them too).
    const ChatMessageFields f = readChatMessageData(rowData(view, row));
    ListRowTextCache *cache = ListRowTextCache::forView(view);
    const QString cls = cache ? cache->delegateClassFor(row) : QString();
    if (f.id.isEmpty() || f.id.startsWith(QLatin1Char('l')) || f.senderMid.isEmpty() || cls.contains(QLatin1StringView("Info")))
        offer.noReaction = "a date or notice";
    else if (cls.contains(QLatin1StringView("Call")))
        offer.noReaction = "a call";
    // LINE draws a message's reaction button (filled when the user has reacted) while the mouse is
    // over it, a moment later (addProfileMenuItem() looks again).
    if (const QPointF content = messageContentPoint(first, scaledRect(r, kWindowsScale)); !content.isNull())
        sendHover(view->viewport(), QPointF(r.topLeft()) + fromWindows(content));
    const CaptureResult hovered = captureRowRect(view, r);
    for (const PaintedImage &pi : (hovered.skipped ? first : hovered).images)
        offer.reacted = offer.reacted || pi.icon == QLatin1StringView("reaction-button-on");
    offer.reactable = !offer.noReaction;
}

} // namespace

namespace {
void pressOpenFolderFirst(QAbstractItemView *v, const QModelIndex &idx, int row);
} // namespace

bool LineAccessibleList::openRowMenu()
{
    QAbstractItemView *v = view();
    const int row = cursorRow();
    if (!v || !v->model() || row < 0)
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    g_profileOffer = ProfileOffer();
    QRect r;
    const CaptureResult cap = captureRow(v, row, &r);
    if (cap.skipped)
        return false;
    pressOpenFolderFirst(v, idx, row);
    // The bridge's own items for this message's menu (addProfileMenuItem()).
    g_profileOffer.view = v;
    g_profileOffer.index = idx;
    g_profileOffer.side = rowSide(v, row);
    judgeReactions(g_profileOffer, v, row, r, cap);
    if (ListRowTextCache *c = cache()) {
        const QString cls = c->delegateClassFor(row);
        g_profileOffer.voice = cls.contains(QLatin1StringView("Audio"));
        g_profileOffer.video = cls.contains(QLatin1StringView("Video"));
    }
    // Keep Memo has no reactions (LINE draws no reaction button there).
    if (g_profileOffer.reactable && inKeepMemo(v)) {
        g_profileOffer.reactable = false;
        g_profileOffer.noReaction = "Keep Memo";
    }
    g_profileOffer.at.start();
    QList<QPointF> points = messageMenuPoints(cap, scaledRect(r, kWindowsScale));
    // A voice message reacts on its bubble: its play button first (nothing else is sure to be on it).
    if (ListRowTextCache *c = cache(); c && c->delegateClassFor(row).contains(QLatin1StringView("Audio"))) {
        for (const PaintedImage &icon : cap.images) {
            if (icon.icon == QLatin1StringView("voice") && icon.rect.top() >= -4) {
                points.prepend(icon.rect.center());
                break;
            }
        }
    }
    if (points.isEmpty()) // nothing recorded: the middle of the row
        points << QPointF(r.width() / 2.0, r.height() / 2.0) * kWindowsScale;
    tryRowMenu(v, idx, points, 0);
    return true;
}

namespace {

enum class ContentKind { Media, Link, File, Other };

// Which tab of a chat's Photos & videos / Links / Files window (ContentViewerWindow) `v` is.
ContentKind contentKind(const QWidget *v)
{
    if (ancestorInheriting(v, "MediaListPanel"))
        return ContentKind::Media;
    if (ancestorInheriting(v, "LinkListPanel"))
        return ContentKind::Link;
    if (ancestorInheriting(v, "FileListPanel"))
        return ContentKind::File;
    return ContentKind::Other;
}

void sendHover(QWidget *target, QPointF local)
{
    const QPointF scene = target->mapTo(target->window(), local);
    const QPointF global = target->mapToGlobal(local);
    QEnterEvent enter(local, scene, global);
    QCoreApplication::sendEvent(target, &enter);
    QMouseEvent move(QEvent::MouseMove, local, scene, global, Qt::NoButton, Qt::NoButton, Qt::NoModifier);
    QCoreApplication::sendEvent(target, &move);
}

// Ends sendHover(): LINE stops drawing the hovered row's extras (a message's reaction button, which
// replaces its time).
void sendLeave(QWidget *target)
{
    QEvent leave(QEvent::Leave);
    QCoreApplication::sendEvent(target, &leave);
}

// LINE draws a link's copy button and a file's download button only while the mouse is over the row
// (UrlPreviewListDelegateWidget: contents_link_copy_icon.png at the row's right, then "View in chat").
// After hovering: the rightmost small square picture without text in the right half of the row
// (row coordinates), or a null point.
QPointF hoverButtonPoint(const CaptureResult &cap, const QRect &rowRect)
{
    QRectF best;
    for (const PaintedImage &pi : cap.images) {
        const QRectF &r = pi.rect;
        const bool small = r.width() >= 14 && r.width() <= 40 && qAbs(r.width() - r.height()) <= 6;
        if (!small || r.center().x() < rowRect.width() * 0.55)
            continue;
        const bool hasText = std::any_of(cap.items.cbegin(), cap.items.cend(), [&r](const CapturedText &it) {
            return !it.text.trimmed().isEmpty() && r.contains(it.pos);
        });
        if (!hasText && (best.isEmpty() || r.right() > best.right()))
            best = r;
    }
    return best.isEmpty() ? QPointF() : best.center();
}

// The selection bar's buttons under the Photos & videos grid (Cancel, Download, Send to Keep Memo,
// Share; right to left), if shown.
QList<QWidget *> selectionBarButtons(const QWidget *window)
{
    QList<QWidget *> buttons;
    for (QWidget *b : window->findChildren<QWidget *>()) {
        if (b->isVisible() && inheritsClass(b, "LcButton")
            && b->property("source").toString().contains(QLatin1StringView("common_btn_photo_right")))
            buttons << b;
    }
    std::sort(buttons.begin(), buttons.end(), [](const QWidget *a, const QWidget *b) {
        return a->mapToGlobal(QPoint(0, 0)).x() > b->mapToGlobal(QPoint(0, 0)).x();
    });
    return buttons;
}

bool fileDialogShown()
{
    for (QWidget *w : QApplication::topLevelWidgets()) {
        if (w->isVisible() && inheritsClass(w, "LcFileDialog"))
            return true;
    }
    return false;
}

// Photos & videos: tick the item's check button (MediaListDelegateWidget: 20 px at 154,10 of 189 px),
// press Download in the selection bar that appears (LINE asks for a folder in Windows' dialog), and
// clear the selection once that dialog has closed.
void saveMediaItem(QAbstractItemView *v, const QModelIndex &idx)
{
    const QRect r = v->visualRect(idx);
    const QPointF check = mediaCheckPoint(r);
    // Already ticked (Space): Download saves it with the other ticked items.
    if (mediaTickState(v, idx, true) != 1) {
        sendHover(v->viewport(), check);
        sendClick(v->viewport(), check);
    }
    QPointer<QWidget> window(v->window());
    QTimer::singleShot(300, window, [window] {
        if (!window)
            return;
        const QList<QWidget *> bar = selectionBarButtons(window);
        static const QStringList kDownload = { QStringLiteral("ดาวน์โหลด"), QStringLiteral("Download"),
                                               QStringLiteral("ダウンロード"), QStringLiteral("下载"),
                                               QStringLiteral("下載") };
        QWidget *download = nullptr;
        for (QWidget *b : bar) {
            if (kDownload.contains(cleanText(b->property("text").toString())))
                download = b;
        }
        if (!download && bar.size() >= 2)
            download = bar.at(1);
        if (!download) {
            a11yLog("[content] save: no Download button after ticking the item");
            return;
        }
        a11yLog("[content] save: Download pressed");
        sendClick(download, QRectF(download->rect()).center());
        // After the folder dialog (saved or cancelled), leave selection mode.
        auto *timer = new QTimer(window);
        auto seen = std::make_shared<bool>(false);
        auto started = std::make_shared<QElapsedTimer>();
        started->start();
        QObject::connect(timer, &QTimer::timeout, timer, [window, timer, seen, started] {
            if (fileDialogShown()) {
                *seen = true;
                return;
            }
            if (!*seen && started->elapsed() < 3000)
                return;
            timer->deleteLater();
            if (!window)
                return;
            if (const QList<QWidget *> left = selectionBarButtons(window); !left.isEmpty())
                sendClick(left.first(), QRectF(left.first()->rect()).center());
        });
        timer->start(300);
    });
}

// Links / files: hover the row, then click its button (copy link / download).
void clickHoverButton(QAbstractItemView *v, const QModelIndex &idx, const char *what)
{
    const QRect r = v->visualRect(idx);
    sendHover(v->viewport(), QRectF(r).center());
    QPointer<QAbstractItemView> view(v);
    const QPersistentModelIndex index(idx);
    QTimer::singleShot(150, v, [view, index, what] {
        if (!view || !index.isValid())
            return;
        const QRect rect = view->visualRect(index);
        const CaptureResult cap = captureRegionText(view->viewport(), rect);
        const QPointF point = cap.skipped ? QPointF() : hoverButtonPoint(cap, rect);
        QStringList seen;
        for (const PaintedImage &pi : cap.images)
            seen << QStringLiteral("%1x%2@%3,%4").arg(pi.rect.width()).arg(pi.rect.height()).arg(pi.rect.x()).arg(pi.rect.y());
        for (const PaintedShape &sh : cap.shapes)
            seen << QStringLiteral("shape %1x%2@%3,%4").arg(sh.rect.width()).arg(sh.rect.height()).arg(sh.rect.x()).arg(sh.rect.y());
        for (const CapturedText &it : cap.items)
            seen << QStringLiteral("\"%1\"@%2,%3").arg(it.text.trimmed()).arg(it.pos.x()).arg(it.pos.y());
        a11yLog("[content] %s: %s (pictures %s)", what,
                point.isNull() ? "no button found"
                               : qPrintable(QStringLiteral("click at %1,%2").arg(point.x()).arg(point.y())),
                qPrintable(seen.join(QLatin1Char(' '))));
        if (!point.isNull())
            sendClick(view->viewport(), rect.topLeft() + point);
    });
}

struct PendingMenuChoice {
    QStringList texts;
    QStringList wordsIn; // an item containing one of these counts too (wording LINE varies)
    QElapsedTimer at;
} g_menuChoice;

struct PendingMessageCommand {
    QPointer<QAbstractItemView> source;
    QPersistentModelIndex row;
    QStringList labels;
    QElapsedTimer at;
    // A plain command, LINE's "Save as...", or Copy for the bridge to save the text.
    enum Purpose { Command, SaveAs, CopyText, FetchFile, OpenFolder } purpose = Command;
    QString kind;     // the command (Reply ...) or "Text", for what is said
    QString fileName; // suggested name of the text file; FetchFile: the file LINE is to save
    int seconds = -1; // FetchFile: the recording's length
    QString title;    // FetchFile: the chat
} g_messageCommand;

// Messages whose file LINE saved for a transcription. LINE then offers "Open folder" instead of
// "Save as..." for that message, also after the file is deleted, until "Open folder" is pressed: LINE
// then finds the file gone and offers "Save as..." again. Kept in a file (LINE keeps its side too).
QSet<QString> &savedForTranscription()
{
    static QSet<QString> *ids = [] {
        auto *set = new QSet<QString>;
        QFile file(bridgeDirectory() + QStringLiteral("transcribe-saved.txt"));
        if (file.open(QIODevice::ReadOnly)) {
            for (const QByteArray &line : file.readAll().split('\n')) {
                if (!line.isEmpty())
                    set->insert(QString::fromLatin1(line));
            }
        }
        return set;
    }();
    return *ids;
}

void storeSavedForTranscription()
{
    QFile file(bridgeDirectory() + QStringLiteral("transcribe-saved.txt"));
    if (file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        file.write(QStringList(savedForTranscription().values()).join(QLatin1Char('\n')).toLatin1());
}

// LINE saved this message's file for a transcription and LINE MR has deleted it since.
bool savedFileGone(const QString &id)
{
    const QString base = bridgeDirectory() + QStringLiteral("transcribe/") + id;
    return !id.isEmpty() && savedForTranscription().contains(id) && !QFile::exists(base + QStringLiteral(".m4a"))
        && !QFile::exists(base + QStringLiteral(".mp4"));
}

// LINE offers "Open folder" for a file that is gone: pressed first (nothing opens), then the real menu.
// The opening of the menu that follows this call is the one that presses it.
void pressOpenFolderFirst(QAbstractItemView *v, const QModelIndex &idx, int row)
{
    if (const QString id = readChatMessageData(idx.data(kItemDataRole).value<QObject *>()).id; savedFileGone(id)) {
        savedForTranscription().remove(id);
        storeSavedForTranscription();
        PendingMessageCommand then = g_messageCommand;
        static const QStringList openFolder = { QStringLiteral("Open folder"), QStringLiteral("เปิดโฟลเดอร์"), QStringLiteral("フォルダを開く"),
                                                QStringLiteral("フォルダーを開く"), QStringLiteral("打开文件夹"), QStringLiteral("開啟資料夾"),
                                                QStringLiteral("打開資料夾") };
        g_messageCommand = PendingMessageCommand();
        g_messageCommand.source = v;
        g_messageCommand.row = idx;
        g_messageCommand.labels = openFolder;
        g_messageCommand.purpose = PendingMessageCommand::OpenFolder;
        g_messageCommand.at.start();
        if (v->currentIndex() != idx)
            v->setCurrentIndex(idx);
        a11yLog("[transcribe] row %d: the saved file is gone; pressing Open folder so that LINE offers Save as again", row);
        QPointer<QAbstractItemView> guard(v);
        QTimer::singleShot(700, v, [guard, then]() mutable {
            auto *list = LineAccessibleList::listFor(guard);
            if (!list)
                return;
            if (then.source) {
                then.at.start();
                g_messageCommand = then;
            }
            list->openRowMenu();
        });
    }
}

void sayCommandUnavailable(const QString &command)
{
    const char *const message = command == QLatin1StringView("Reply") ? "This message cannot be replied to."
        : command == QLatin1StringView("React") ? "This message takes no reactions."
        : command == QLatin1StringView("Delete") ? "This message cannot be deleted."
        : command == QLatin1StringView("Unsend") ? "This message cannot be unsent."
        : command == QLatin1StringView("Translate") ? "This message cannot be translated." : "Not available for this message.";
    announce(label(message), AnnounceWhen::LineActive);
}

// Save message: asks where (LINE is sandboxed; the save panel gives it the file) and writes the text.
void saveTextFile(const QString &fileName, const QString &text)
{
    QTimer::singleShot(0, qApp, [fileName, text] {
        QString name = fileName;
        name.replace(QLatin1Char('/'), QLatin1Char('-')).replace(QLatin1Char(':'), QLatin1Char('-'));
        const QString path = QFileDialog::getSaveFileName(QApplication::activeWindow(), label("Save message as text file"),
                                                          name + QStringLiteral(".txt"), QStringLiteral("*.txt"));
        if (path.isEmpty())
            return;
        QFile file(path);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate) || file.write(text.toUtf8()) < 0) {
            announce(label("The message could not be saved: %1").arg(file.errorString()), AnnounceWhen::LineActive);
            return;
        }
        file.close();
        announce(label("Saved as %1").arg(QFileInfo(path).fileName()), AnnounceWhen::LineActive);
    });
}

// LINE's Copy puts the message on the clipboard; the text is taken from there and what the clipboard
// held before is put back.
void captureCopiedText(const QString &fileName)
{
    QClipboard *clipboard = QGuiApplication::clipboard();
    auto *backup = new QMimeData;
    if (const QMimeData *before = clipboard->mimeData()) {
        for (const QString &format : before->formats())
            backup->setData(format, before->data(format));
    }
    auto done = std::make_shared<bool>(false);
    auto conn = std::make_shared<QMetaObject::Connection>();
    auto finish = [clipboard, backup, done, conn, fileName](bool changed) {
        if (*done)
            return;
        *done = true;
        QObject::disconnect(*conn);
        const QString text = changed ? clipboard->text() : QString();
        if (backup->formats().isEmpty()) {
            clipboard->clear();
            delete backup;
        } else {
            clipboard->setMimeData(backup); // the clipboard owns it now
        }
        if (text.isEmpty())
            announce(label("LINE offers no way to save this message (it may have expired)."), AnnounceWhen::LineActive);
        else
            saveTextFile(fileName, text);
    };
    *conn = QObject::connect(clipboard, &QClipboard::dataChanged, qApp, [finish] {
        // LINE may set the text in steps: read it once LINE is done.
        QTimer::singleShot(50, qApp, [finish] { finish(true); });
    });
    QTimer::singleShot(2000, qApp, [finish] { finish(false); });
}

// The chat's message list in a window showing one (the main window or a popped-out chat).
QAbstractItemView *visibleMessageList()
{
    for (QWidget *top : QApplication::topLevelWidgets()) {
        if (!top->isVisible())
            continue;
        for (QWidget *w : top->findChildren<QWidget *>()) {
            if (inheritsClass(w, "LcListView") && w->isVisible() && ancestorInheriting(w, "ChatMessageView")
                && !ancestorInheriting(w, "SearchDetailPanel") && !ancestorInheriting(w, "LcListView"))
                return static_cast<QAbstractItemView *>(w);
        }
    }
    return nullptr;
}

// Files: LINE draws no download button on the row, only "View in chat" (on hover); the message's own
// menu has "Save as...". So: View in chat, then that message's menu, then Save as (LINE asks where).
void saveFileItem(QAbstractItemView *v, const QModelIndex &idx)
{
    const QRect r = v->visualRect(idx);
    sendHover(v->viewport(), QRectF(r).center());
    QPointer<QAbstractItemView> view(v);
    const QPersistentModelIndex index(idx);
    QTimer::singleShot(150, v, [view, index] {
        if (!view || !index.isValid())
            return;
        const QRect rect = view->visualRect(index);
        const CaptureResult cap = captureRegionText(view->viewport(), rect);
        // The text button in the right half of the row ("View in chat", 62x27).
        QRectF button;
        for (const PaintedShape &sh : cap.shapes) {
            const QRectF &b = sh.rect;
            if (b.width() < 40 || b.width() > 160 || b.height() < 18 || b.height() > 40 || b.center().x() < rect.width() * 0.55)
                continue;
            const bool hasText = std::any_of(cap.items.cbegin(), cap.items.cend(), [&b](const CapturedText &it) {
                return !it.text.trimmed().isEmpty() && b.adjusted(-2, -2, 2, 30).contains(it.pos);
            });
            if (hasText)
                button = b;
        }
        if (button.isEmpty()) {
            a11yLog("[content] save file: no View in chat button");
            return;
        }
        a11yLog("[content] save file: View in chat");
        sendClick(view->viewport(), rect.topLeft() + button.center());
        // Once the chat shows the message (LINE makes it the current row), its menu: Save as.
        QTimer::singleShot(1200, qApp, [] {
            QAbstractItemView *messages = visibleMessageList();
            LineAccessibleList *list = messages ? LineAccessibleList::listFor(messages) : nullptr;
            if (!list) {
                a11yLog("[content] save file: no message list after View in chat");
                return;
            }
            g_menuChoice.texts = { QStringLiteral("บันทึกเป็น..."), QStringLiteral("Save as..."), QStringLiteral("Save As..."),
                                   QStringLiteral("名前を付けて保存"), QStringLiteral("另存为"), QStringLiteral("另存新檔") };
            g_menuChoice.at.start();
            messages->window()->activateWindow();
            messages->setFocus(Qt::OtherFocusReason);
            if (!list->openRowMenu())
                a11yLog("[content] save file: no menu for the message");
        });
    });
}

} // namespace

namespace {

// LINE's reaction picker (a ReactionDockWidget in the chat's ChatMessageView): its choices in
// display order (LcImages of cache category "reactionDock").
QList<QWidget *> reactionChoices(QWidget *dock)
{
    QList<QWidget *> choices;
    for (QWidget *w : dock->findChildren<QWidget *>()) {
        if (w->isVisible() && inheritsClass(w, "LcImage") && stringProp(w, "cacheCategory") == QLatin1StringView("reactionDock"))
            choices << w;
    }
    std::sort(choices.begin(), choices.end(), [dock](QWidget *a, QWidget *b) {
        return a->mapTo(dock, QPoint()).x() < b->mapTo(dock, QPoint()).x();
    });
    return choices;
}

// Nothing drawn: every pixel (nearly) transparent, or (QWidget::grab() on macOS paints the picker's
// background) all of one colour.
bool isBlankImage(const QImage &image)
{
    const QImage argb = image.convertToFormat(QImage::Format_ARGB32);
    if (argb.isNull())
        return false;
    const QRgb background = argb.pixel(0, 0);
    auto same = [background](QRgb p) {
        return qAbs(qRed(p) - qRed(background)) < 16 && qAbs(qGreen(p) - qGreen(background)) < 16
            && qAbs(qBlue(p) - qBlue(background)) < 16;
    };
    for (int y = 0; y < argb.height(); ++y) {
        const QRgb *line = reinterpret_cast<const QRgb *>(argb.constScanLine(y));
        for (int x = 0; x < argb.width(); ++x) {
            if (qAlpha(line[x]) > 16 && !(qAlpha(background) > 16 && same(line[x])))
                return false;
        }
    }
    return true;
}

QWidget *visibleReactionDock(QWidget *window)
{
    for (QWidget *w : window->findChildren<QWidget *>()) {
        if (w->isVisible() && inheritsClass(w, "ReactionDockWidget"))
            return w;
    }
    return nullptr;
}

// LINE placed the picker where the row template was drawn (far off screen): put it above the
// reaction button `at` (viewport coordinates), make its choices Tab stops and focus the first. Once
// it closes (a choice made, Escape), focus goes back to the message.
void prepareReactionDock(QAbstractItemView *view, QPointF at, bool remove)
{
    QWidget *dock = visibleReactionDock(view->window());
    if (!dock || !dock->parentWidget()) {
        a11yLog("[reaction] the picker did not open");
        return;
    }
    QWidget *parent = dock->parentWidget();
    const QPoint button = view->viewport()->mapTo(parent, at.toPoint());
    const int x = std::clamp(button.x() - dock->width() / 2, 0, qMax(0, parent->width() - dock->width()));
    int y = button.y() - 12 - dock->height();
    if (y < 0)
        y = qMin(button.y() + 12, qMax(0, parent->height() - dock->height()));
    dock->move(x, y);
    dock->raise();
    const QList<QWidget *> choices = reactionChoices(dock);
    QStringList names;
    for (QWidget *choice : choices) {
        choice->setFocusPolicy(Qt::TabFocus);
        choice->setProperty("_lineA11yFocusable", true);
        // The pictures are LINE's reaction faces (text_capture.cpp: "reaction-love", ...).
        const QImage picture = choice->paintingActive() ? QImage() : choice->grab().toImage();
        const QString icon = reactionIcon(picture);
        // <a11y dir>/icon-debug: keep the pictures for comparing them with LINE's icons.
        if (QFile::exists(bridgeDirectory() + QStringLiteral("icon-debug")))
            picture.save(bridgeDirectory() + QStringLiteral("reaction-choice-%1.png").arg(choices.indexOf(choice)));
        choice->setProperty("_lineA11yReaction", icon);
        // The faces are animated (16 frames a second): each frame repainted the messages under the
        // picker, and a long message kept LINE so busy that every NVDA query waited ~130 ms (NVDA
        // froze and said nothing). Still faces while the keyboard uses the picker.
        if (choice->property("running").toBool())
            choice->setProperty("running", false);
        // Qt's own interface (a grouping) may be cached from before: now a button.
        repairCachedInterface(choice);
        // LINE leaves the reaction the user already gave blank (pressing it takes it back).
        choice->setProperty("_lineA11yReactionChosen", !picture.isNull() && isBlankImage(picture));
        QString name = icon.startsWith(QLatin1StringView("reaction-")) ? humanizeIconName(icon) : QString();
        // The last, smaller choice (a plain smiley) opens LINE's other reactions.
        if (name.isEmpty() && choice == choices.last() && choice->width() < choices.first()->width())
            name = label("More reactions");
        if (name.isEmpty())
            name = label("Reactions");
        choice->setAccessibleName(name);
        names << QStringLiteral("%1 (%2 %3x%4 clicked()=%5)").arg(name, icon).arg(choice->width()).arg(choice->height())
                         .arg(int(isSignalConnected(choice, "clicked()")));
    }
    // The reaction already chosen is drawn highlighted and is not recognised. The picker shows LINE's
    // five basic reactions (in an order LINE changes: the one given came first once), so a single
    // unknown face is the kind missing from the others, and it is the chosen one.
    static const char *const kBasic[] = { "reaction-like", "reaction-love", "reaction-fun", "reaction-envy", "reaction-sad" };
    if (choices.size() == 6) {
        int unknown = -1;
        QStringList missing;
        for (const char *kind : kBasic)
            missing << QLatin1String(kind);
        for (int i = 0; i < 5; ++i) {
            const QString icon = choices.at(i)->property("_lineA11yReaction").toString();
            if (icon.isEmpty())
                unknown = unknown < 0 ? i : 99;
            else
                missing.removeAll(icon);
        }
        if (unknown >= 0 && unknown < 5 && missing.size() == 1) {
            choices.at(unknown)->setProperty("_lineA11yReaction", missing.first());
            choices.at(unknown)->setAccessibleName(humanizeIconName(missing.first()));
            names[unknown] = choices.at(unknown)->accessibleName() + QStringLiteral(" (the missing kind)");
            choices.at(unknown)->setProperty("_lineA11yReactionChosen", true);
        }
    }
    for (qsizetype i = 0; i < choices.size(); ++i) {
        QWidget *choice = choices.at(i);
        if (choice->property("_lineA11yReactionChosen").toBool()) {
            choice->setAccessibleName(label("%1, chosen").arg(choice->accessibleName()));
            names[i] = choice->accessibleName();
        }
    }
    a11yLog("[reaction] picker at %d,%d with %d choices: %s", x, y, int(choices.size()), qUtf8Printable(names.join(u", ")));
    if (choices.isEmpty())
        return;
    // "Remove reaction": choosing the reaction given again takes it back.
    if (remove) {
        for (QWidget *choice : choices) {
            if (choice->property("_lineA11yReactionChosen").toBool()) {
                a11yLog("[reaction] removing \"%s\"", qUtf8Printable(choice->accessibleName()));
                sendMouseClick(choice);
                for (QWidget *c : choices)
                    c->setProperty("running", true);
                QPointer<QAbstractItemView> list(view);
                QTimer::singleShot(150, view, [list] {
                    if (!list)
                        return;
                    sendLeave(list->viewport());
                    list->setFocus(Qt::PopupFocusReason);
                });
                return;
            }
        }
        a11yLog("[reaction] no chosen reaction to remove: the picker stays open");
    }
    for (qsizetype i = 1; i < choices.size(); ++i)
        QWidget::setTabOrder(choices.at(i - 1), choices.at(i));
    // Not a list LINE pulled focus away from: the bridge's list guard must not send it back.
    endListBrowsing();
    choices.first()->setFocus(Qt::OtherFocusReason);
    QPointer<QWidget> guard(dock);
    QPointer<QAbstractItemView> list(view);
    // Qt moves focus on (to the title bar) when the picker hides: remember it was in the picker.
    // (The timer belongs to the list: LINE for macOS deletes the picker when it closes.)
    auto *timer = new QTimer(view);
    auto started = std::make_shared<QElapsedTimer>();
    started->start();
    auto focused = std::make_shared<bool>(true);
    QObject::connect(timer, &QTimer::timeout, timer, [timer, guard, list, started, focused] {
        if (guard && guard->isVisible() && started->elapsed() < 120000) {
            QWidget *focus = QApplication::focusWidget();
            *focused = focus && guard->isAncestorOf(focus);
            return;
        }
        timer->deleteLater();
        if (guard && guard->isVisible())
            return;
        // Animated again for the mouse.
        if (guard) {
            for (QWidget *choice : guard->findChildren<QWidget *>()) {
                if (choice->property("_lineA11yReaction").isValid() && !choice->property("running").toBool())
                    choice->setProperty("running", true);
            }
        }
        if (list)
            sendLeave(list->viewport());
        if (list && list->isVisible() && *focused) {
            a11yLog("[reaction] picker closed: back to the message");
            list->setFocus(Qt::PopupFocusReason);
        }
    });
    timer->start(100);
}

// The reaction button of LINE's hidden row template (a *DelegateWidget top-level) that was just set
// to the row `rect` of `view`: same width, button at the same place. LINE does not always give the
// template the row's height (a 58 px message drawn by a 256 px template): an equal size comes first.
QWidget *reactionTemplateButton(QAbstractItemView *view, const QRect &rect, const QRectF &button)
{
    QWidget *sameWidth = nullptr;
    for (QWidget *w : QApplication::allWidgets()) {
        if (!iconSource(w).contains(QLatin1StringView("ic-reaction-o")) || !inheritsClass(w, "LcButton"))
            continue;
        QWidget *top = w->window();
        if (top == view->window() || top->width() != rect.width() || w->mapTo(top, QPoint()) != button.topLeft().toPoint())
            continue;
        if (top->height() == rect.height())
            return w;
        if (!sameWidth)
            sameWidth = w;
    }
    return sameWidth;
}

QString reactionTemplateCandidates()
{
    QStringList candidates;
    for (QWidget *w : QApplication::allWidgets()) {
        if (!iconSource(w).contains(QLatin1StringView("ic-reaction-o")) || !inheritsClass(w, "LcButton"))
            continue;
        QWidget *top = w->window();
        const QPoint p = w->mapTo(top, QPoint());
        candidates << QStringLiteral("%1 %2x%3 button %4,%5").arg(QLatin1String(top->metaObject()->className()))
                          .arg(top->width()).arg(top->height()).arg(p.x()).arg(p.y());
    }
    return candidates.join(QStringLiteral("; "));
}

void pressReactionTemplate(QAbstractItemView *view, QWidget *templateButton, QPointF at, bool remove)
{
    QMetaObject::invokeMethod(templateButton, "clicked");
    QPointer<QAbstractItemView> guard(view);
    QTimer::singleShot(80, view, [guard, at, remove] {
        if (guard)
            prepareReactionDock(guard, at, remove);
    });
}

} // namespace

bool LineAccessibleList::openReactions(int row, bool remove)
{
    QAbstractItemView *v = view();
    if (!v || !v->model() || row < 0 || row >= rowCount())
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    const QRect r = v->visualRect(idx);
    const CaptureResult cap = captureRegionText(v->viewport(), r);
    if (cap.skipped)
        return false;
    // LINE draws the reaction button beside the message while the mouse is over it.
    QPointF content = messageContentPoint(cap, r);
    if (content.isNull())
        content = QRectF(r).center() - QPointF(r.topLeft());
    sendHover(v->viewport(), QPointF(r.topLeft()) + content);
    QList<QRectF> before;
    for (const PaintedImage &pi : cap.images)
        before << pi.rect;
    QPointer<QAbstractItemView> view(v);
    const QPersistentModelIndex index(idx);
    QTimer::singleShot(200, v, [view, index, before, remove] {
        if (!view || !index.isValid())
            return;
        const QRect rect = view->visualRect(index);
        // Drawing the row also sets LINE's row template (a hidden *DelegateWidget) to this message.
        const CaptureResult hovered = captureRegionText(view->viewport(), rect);
        QRectF button;
        QStringList seen;
        for (const PaintedImage &pi : hovered.images) {
            seen << QStringLiteral("%1x%2@%3,%4%5").arg(pi.rect.width()).arg(pi.rect.height()).arg(pi.rect.x()).arg(pi.rect.y())
                        .arg(pi.icon.isEmpty() ? QString() : QLatin1Char(':') + pi.icon);
            // A small square picture outside every bubble and photo (a thin smiley: its shape alone is
            // too close to a video's play button, which lies inside the thumbnail). One that appeared
            // with the mouse comes first (the menu's right click may have hovered the row already).
            const bool small = pi.rect.width() >= 14 && pi.rect.width() <= 32 && qAbs(pi.rect.width() - pi.rect.height()) <= 3;
            const bool inside = std::any_of(hovered.images.cbegin(), hovered.images.cend(), [&pi](const PaintedImage &o) {
                return o.rect.width() > pi.rect.width() + 4 && o.rect.adjusted(-1, -1, 1, 1).contains(pi.rect);
            });
            if (!small || inside || !pi.alpha)
                continue;
            const bool appeared = std::none_of(before.cbegin(), before.cend(), [&pi](const QRectF &b) {
                return qAbs(b.x() - pi.rect.x()) < 1 && qAbs(b.y() - pi.rect.y()) < 1;
            });
            if (button.isEmpty() || appeared || pi.icon.startsWith(QLatin1StringView("reaction-button")))
                button = pi.rect;
        }
        if (button.isEmpty() || hovered.skipped) {
            a11yLog("[reaction] row %d: no reaction button (pictures %s)", index.row(), qPrintable(seen.join(QLatin1Char(' '))));
            return;
        }
        const QPointF at = QPointF(rect.topLeft()) + button.center();
        // A click on the drawn button does nothing (LINE checks the real mouse); the button of the row
        // template drawing this message opens the picker. LINE may draw the row from its cache, leaving
        // the template set to another message: a data change for the row (the data stays the same)
        // makes the next capture draw it through a template.
        QAbstractItemModel *model = const_cast<QAbstractItemModel *>(index.model());
        Q_EMIT model->dataChanged(QModelIndex(index), QModelIndex(index));
        const QString pictures = seen.join(QLatin1Char(' '));
        QTimer::singleShot(100, view, [view, index, button, at, pictures, remove] {
            if (!view || !index.isValid())
                return;
            const QRect rect = view->visualRect(index);
            const CaptureResult again = captureRegionText(view->viewport(), rect);
            if (QWidget *templateButton = again.skipped ? nullptr : reactionTemplateButton(view, rect, button)) {
                a11yLog("[reaction] row %d: opening the picker (%s %dx%d; pictures %s)", index.row(),
                        templateButton->window()->metaObject()->className(), templateButton->window()->width(),
                        templateButton->window()->height(), qPrintable(pictures));
                pressReactionTemplate(view, templateButton, at, remove);
                return;
            }
            a11yLog("[reaction] row %d: no row template with the button at %.0f,%.0f (%s); clicking", index.row(),
                    button.x(), button.y(),
                    qPrintable(reactionTemplateCandidates()));
            sendHover(view->viewport(), at);
            sendClick(view->viewport(), at);
            QTimer::singleShot(80, view, [view, at, remove] {
                if (view)
                    prepareReactionDock(view, at, remove);
            });
        });
    });
    return true;
}

bool LineAccessibleList::openMessageCommand(int command)
{
    QAbstractItemView *v = view();
    if (!v || !v->hasFocus() || !v->currentIndex().isValid() || command < 0 || command > 4)
        return false;
    if (g_messageCommand.source && g_messageCommand.at.isValid() && g_messageCommand.at.elapsed() < 3000)
        return true;
    const QStringList labels[] = {
        { QStringLiteral("Reply"), QStringLiteral("回覆"), QStringLiteral("回复"), QStringLiteral("回復"), QStringLiteral("返信"), QStringLiteral("ตอบกลับ") },
        { QStringLiteral("Delete"), QStringLiteral("刪除"), QStringLiteral("删除"), QStringLiteral("削除"), QStringLiteral("ลบ") },
        { QStringLiteral("Unsend"), QStringLiteral("收回"), QStringLiteral("撤回"), QStringLiteral("送信取消"), QStringLiteral("送信を取り消す"), QStringLiteral("ยกเลิกข้อความ"), QStringLiteral("ยกเลิกการส่ง") },
        { QStringLiteral("Translate"), QStringLiteral("翻譯"), QStringLiteral("翻译"), QStringLiteral("翻訳"), QStringLiteral("แปล") },
        // The bridge's own item (addProfileMenuItem()): React, or Remove reaction once the user has reacted.
        { label("React"), label("Remove reaction") },
    };
    static const char *const names[] = { "Reply", "Delete", "Unsend", "Translate", "React" };
    g_messageCommand = PendingMessageCommand();
    g_messageCommand.source = v;
    g_messageCommand.row = v->currentIndex();
    g_messageCommand.labels = labels[command];
    g_messageCommand.kind = QString::fromLatin1(names[command]);
    g_messageCommand.at.start();
    a11yLog("[message-command] requested %s on row %d", names[command], v->currentIndex().row());
    if (!openRowMenu()) {
        g_messageCommand = PendingMessageCommand();
        return false;
    }
    return true;
}

bool LineAccessibleList::saveMessage()
{
    QAbstractItemView *v = view();
    const int row = cursorRow();
    if (!v || !v->model() || row < 0)
        return false;
    if (g_messageCommand.source && g_messageCommand.at.isValid() && g_messageCommand.at.elapsed() < 3000)
        return true;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    const ChatMessageFields f = readChatMessageData(idx.data(kItemDataRole).value<QObject *>());
    ListRowTextCache *cache = ListRowTextCache::forView(v);
    const QString cls = cache ? cache->delegateClassFor(row) : QString();
    const auto is = [&cls](const char *marker) { return cls.contains(QLatin1StringView(marker)); };
    const bool message = !f.senderMid.isEmpty() && !f.id.startsWith(QLatin1Char('l')) && !is("Info") && !is("Date") && !is("UnreadMsg");
    const QString chat = chatNameFor(v);
    const QString fileName = (chat.isEmpty() ? QStringLiteral("LINE") : chat) + u' '
        + QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HHmm"));
    const auto unsupported = [] {
        announce(label("Saving this kind of message is not supported."), AnnounceWhen::LineActive);
        return true;
    };
    PendingMessageCommand::Purpose purpose;
    if (!message)
        return unsupported();
    if (is("Location") || is("Contact")) {
        // LINE's Copy is for text messages; these are saved as read.
        QAccessibleInterface *item = itemAt(row);
        const QString text = item ? item->text(QAccessible::Name) : QString();
        if (text.isEmpty())
            return unsupported();
        saveTextFile(fileName, text);
        return true;
    }
    if (!cleanText(f.text).isEmpty())
        purpose = PendingMessageCommand::CopyText;
    else if (is("Image") || is("Video") || is("File") || is("Audio") || is("Compress") || !f.fileName.isEmpty() || !f.mediaPath.isEmpty())
        purpose = PendingMessageCommand::SaveAs;
    else
        return unsupported(); // stickers, calls
    static const QStringList saveAs = { QStringLiteral("Save as"), QStringLiteral("บันทึกเป็น"), QStringLiteral("名前を付けて保存"),
                                        QStringLiteral("另存为"), QStringLiteral("另存新檔"), QStringLiteral("另存為") };
    static const QStringList copy = { QStringLiteral("Copy"), QStringLiteral("คัดลอก"), QStringLiteral("コピー"),
                                      QStringLiteral("复制"), QStringLiteral("複製") };
    g_messageCommand = PendingMessageCommand();
    g_messageCommand.source = v;
    g_messageCommand.row = idx;
    g_messageCommand.labels = purpose == PendingMessageCommand::SaveAs ? saveAs : copy;
    g_messageCommand.purpose = purpose;
    g_messageCommand.kind = QStringLiteral("Save");
    g_messageCommand.fileName = fileName;
    g_messageCommand.at.start();
    if (v->currentIndex() != idx)
        v->setCurrentIndex(idx);
    a11yLog("[save] row %d: %s", row, purpose == PendingMessageCommand::SaveAs ? "LINE's Save as" : "text");
    if (!openRowMenu()) {
        g_messageCommand = PendingMessageCommand();
        announce(label("LINE is busy. Press Command+S again."), AnnounceWhen::LineActive);
    }
    return true;
}

bool LineAccessibleList::transcribeMessage(int row)
{
    QAbstractItemView *v = view();
    if (!v || !v->model() || row < 0)
        return false;
    if (g_messageCommand.source && g_messageCommand.at.isValid() && g_messageCommand.at.elapsed() < 3000)
        return true;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    const ChatMessageFields f = readChatMessageData(idx.data(kItemDataRole).value<QObject *>());
    ListRowTextCache *c = cache();
    const QString cls = c ? c->delegateClassFor(row) : QString();
    const bool video = cls.contains(QLatin1StringView("Video")) || (cls.isEmpty() && !f.duration.isEmpty() && !f.mediaPath.isEmpty());
    const bool voice = cls.contains(QLatin1StringView("Audio")) || (cls.isEmpty() && !f.duration.isEmpty() && f.mediaPath.isEmpty());
    if (f.id.isEmpty() || (!video && !voice)) {
        announce(label("Not a voice message or video."), AnnounceWhen::LineActive);
        return true;
    }
    int seconds = -1;
    if (!f.duration.isEmpty()) {
        seconds = 0;
        for (const QString &part : f.duration.split(QLatin1Char(':')))
            seconds = seconds * 60 + part.toInt();
    }
    const QString folder = bridgeDirectory() + QStringLiteral("transcribe/");
    QDir().mkpath(folder);
    const QString target = folder + f.id + (video ? QStringLiteral(".mp4") : QStringLiteral(".m4a"));
    QFile::remove(target);
    static const QStringList saveAs = { QStringLiteral("Save as"), QStringLiteral("บันทึกเป็น"), QStringLiteral("名前を付けて保存"),
                                        QStringLiteral("另存为"), QStringLiteral("另存新檔"), QStringLiteral("另存為") };
    g_messageCommand = PendingMessageCommand();
    g_messageCommand.source = v;
    g_messageCommand.row = idx;
    g_messageCommand.labels = saveAs;
    g_messageCommand.purpose = PendingMessageCommand::FetchFile;
    g_messageCommand.kind = video ? QStringLiteral("video") : QStringLiteral("voice");
    g_messageCommand.fileName = target;
    g_messageCommand.seconds = seconds;
    g_messageCommand.title = chatNameFor(v);
    g_messageCommand.at.start();
    if (v->currentIndex() != idx)
        v->setCurrentIndex(idx);
    a11yLog("[transcribe] row %d: having LINE save the %s", row, video ? "video" : "voice message");
    if (!openRowMenu()) {
        g_messageCommand = PendingMessageCommand();
        announce(label("LINE did not save the file. Try again."), AnnounceWhen::LineActive);
    }
    return true;
}

void LineAccessibleList::openVideoForTranscription()
{
    QAbstractItemView *v = view();
    const int row = cursorRow();
    QAccessibleInterface *item = v && row >= 0 ? itemAt(row) : nullptr;
    // Items read "Video, ..." and posts "..., Video, ..." / "2 photos, 1 video".
    if (!item || !item->text(QAccessible::Name).contains(label("Video"), Qt::CaseInsensitive)) {
        announce(label("Not a voice message or video."), AnnounceWhen::LineActive);
        return;
    }
    QFile request(bridgeDirectory() + QStringLiteral("viewer-transcribe-request"));
    if (request.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        request.write(QByteArray::number(QDateTime::currentMSecsSinceEpoch()));
        request.close();
    }
    const bool opened = isPostList(v) ? openPostMedia() : clickCursorRow();
    a11yLog("[transcribe] row %d: video %s in the viewer", row, opened ? "opened" : "could not be opened");
    if (!opened) {
        request.remove();
        announce(label("Not a voice message or video."), AnnounceWhen::LineActive);
    }
}

bool LineAccessibleList::toggleMediaTick()
{
    QAbstractItemView *v = view();
    const int row = cursorRow();
    if (!v || !v->model() || row < 0)
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    if (!isMediaGridItem(v, idx))
        return false;
    v->scrollTo(idx);
    const QPointF check = mediaCheckPoint(v->visualRect(idx));
    if (!v->viewport()->rect().contains(check.toPoint()))
        return false;
    a11yLog("[content] tick item %d", row);
    sendHover(v->viewport(), check);
    sendClick(v->viewport(), check);
    QPointer<QAbstractItemView> guard(v);
    QTimer::singleShot(200, v, [guard, row] {
        auto *list = listFor(guard);
        if (!list || !list->view())
            return;
        // The hover made LINE draw "View in chat" over the item.
        sendLeave(list->view()->viewport());
        const QModelIndex item = list->view()->model()->index(row, 0, list->view()->rootIndex());
        const int ticked = mediaTickState(list->view(), item, true);
        a11yLog("[content] item %d ticked: %d", row, ticked);
        // (VoiceOver says no state for a static text.)
        if (ticked >= 0)
            announce(label(ticked ? "Selected" : "Not selected"));
        if (QAccessibleInterface *iface = list->itemAt(row)) {
            QAccessible::State changed;
            changed.checked = true;
            QAccessibleStateChangeEvent event(iface, changed);
            QAccessible::updateAccessibility(&event);
        }
    });
    return true;
}

QWidget *takePendingMenuChoice(const QList<QWidget *> &items)
{
    if (g_messageCommand.source) {
        const PendingMessageCommand command = g_messageCommand;
        g_messageCommand = PendingMessageCommand(); // consume once; never continue into a confirmation
        const bool valid = command.at.isValid() && command.at.elapsed() < 3000 && command.row.isValid()
            && command.row.model() == command.source->model() && command.source->currentIndex() == command.row;
        if (!valid) {
            if (command.purpose != PendingMessageCommand::Command)
                announce(label("LINE offers no way to save this message (it may have expired)."), AnnounceWhen::LineActive);
            return nullptr;
        }
        for (QWidget *item : items) {
            QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(item);
            QString text = iface ? cleanText(iface->text(QAccessible::Name)).remove(u'&').trimmed() : QString();
            while (text.endsWith(u'.') || text.endsWith(QChar(0x2026)))
                text.chop(1);
            if (!item->isEnabled() || !command.labels.contains(text.trimmed()))
                continue;
            a11yLog("[message-command] activating %s", qUtf8Printable(text));
            if (command.purpose == PendingMessageCommand::CopyText)
                captureCopiedText(command.fileName);
            if (command.purpose == PendingMessageCommand::FetchFile) {
                const QString target = command.fileName;
                saveThenTranscribe(target, command.kind, command.seconds, command.title, [target] {
                    savedForTranscription().insert(QFileInfo(target).completeBaseName());
                    storeSavedForTranscription();
                });
            }
            return item;
        }
        // Not offered for this message (Reply in Keep Memo, Unsend on someone else's): the menu is
        // closed and that is said (left open, it read as if the command had opened the menu).
        if (!items.isEmpty()) {
            QPointer<QWidget> menu = items.first()->window();
            QTimer::singleShot(0, qApp, [menu] {
                if (menu)
                    menu->hide();
            });
        }
        if (command.purpose == PendingMessageCommand::OpenFolder)
            a11yLog("[transcribe] no Open folder in the menu");
        else if (command.purpose == PendingMessageCommand::FetchFile)
            announce(label("LINE did not save the file. Try again."), AnnounceWhen::LineActive);
        else if (command.purpose == PendingMessageCommand::Command)
            sayCommandUnavailable(command.kind);
        else
            announce(label("LINE offers no way to save this message (it may have expired)."), AnnounceWhen::LineActive);
        a11yLog("[message-command] %s unavailable for this row", qPrintable(command.kind));
        return nullptr;
    }
    if ((g_menuChoice.texts.isEmpty() && g_menuChoice.wordsIn.isEmpty()) || !g_menuChoice.at.isValid()
        || g_menuChoice.at.elapsed() > 5000)
        return nullptr;
    for (QWidget *item : items) {
        QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(item);
        const QString text = iface ? cleanText(iface->text(QAccessible::Name)) : QString();
        const bool word = std::any_of(g_menuChoice.wordsIn.cbegin(), g_menuChoice.wordsIn.cend(),
                                      [&text](const QString &w) { return text.contains(w, Qt::CaseInsensitive); });
        if (word || g_menuChoice.texts.contains(text)) {
            g_menuChoice = PendingMenuChoice();
            a11yLog("[content] pressing \"%s\" in the message's menu", qUtf8Printable(text));
            return item;
        }
    }
    return nullptr;
}

bool LineAccessibleList::openPostMenu()
{
    QAbstractItemView *v = view();
    const int row = cursorRow();
    if (!v || !v->model() || row < 0 || !isPostList(v))
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    const QRect r = v->visualRect(idx);
    const CaptureResult cap = captureRegionText(v->viewport(), r);
    if (cap.skipped || r.isEmpty())
        return false;
    QList<bool> videos;
    const QList<QRectF> media = postMedia(cap, &videos);
    const QString body = postBodyText(cap, r);
    const QPointF more = postMoreButtonPoint();
    if (media.isEmpty() && body.isEmpty() && more.isNull())
        return false;
    const QPersistentModelIndex keep(idx);
    QPointer<QAbstractItemView> view(v);
    auto *menu = new QMenu(v);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    if (!media.isEmpty()) {
        QObject::connect(menu->addAction(label("Open")), &QAction::triggered, v, [view, keep] {
            if (LineAccessibleList *list = view ? listFor(view) : nullptr; list && keep.isValid()) {
                view->setCurrentIndex(keep);
                list->openPostMedia();
            }
        });
        // LINE saves from its viewer only (Download, shown while the mouse is over the picture): open
        // the picture and ask the viewer's bridge to press it (Windows' Save As follows).
        QObject::connect(menu->addAction(label("Save as...")), &QAction::triggered, v, [view, keep] {
            LineAccessibleList *list = view ? listFor(view) : nullptr;
            if (!list || !keep.isValid())
                return;
            QFile request(bridgeDirectory() + QStringLiteral("viewer-save-request"));
            if (request.open(QIODevice::WriteOnly | QIODevice::Truncate))
                request.write(QByteArray::number(QDateTime::currentMSecsSinceEpoch()));
            request.close();
            view->setCurrentIndex(keep);
            if (!list->openPostMedia())
                QFile::remove(request.fileName());
        });
    }
    if (!body.isEmpty()) {
        QObject::connect(menu->addAction(label("Copy text")), &QAction::triggered, v, [body] {
            QGuiApplication::clipboard()->setText(body);
        });
    }
    if (!more.isNull()) {
        QObject::connect(menu->addAction(label("More options")), &QAction::triggered, v, [view, keep, more] {
            if (!view || !keep.isValid())
                return;
            const QRect rr = view->visualRect(keep);
            const QPointF local = QPointF(rr.topLeft()) + more;
            a11yLog("[post] more options of row %d: click at %.0f,%.0f", keep.row(), local.x(), local.y());
            QPointer<QWidget> viewport = view->viewport();
            QMouseEvent move(QEvent::MouseMove, local, viewport->mapTo(viewport->window(), local),
                             viewport->mapToGlobal(local), Qt::NoButton, Qt::NoButton, Qt::NoModifier);
            QCoreApplication::sendEvent(viewport, &move);
            if (viewport)
                sendClick(viewport, local);
        });
    }
    a11yLog("[post] menu for row %d (%d actions, %d pictures, text %d chars)", row, int(menu->actions().size()),
            int(media.size()), int(body.size()));
    menu->popup(v->viewport()->mapToGlobal(QRectF(r.intersected(v->viewport()->rect())).center().toPoint()));
    menu->setActiveAction(menu->actions().value(0));
    // The item under the real mouse pointer may take the highlight as the menu shows: the first again.
    QTimer::singleShot(80, menu, [menu] { menu->setActiveAction(menu->actions().value(0)); });
    return true;
}

bool LineAccessibleList::openContentMenu()
{
    QAbstractItemView *v = view();
    if (v && isPostList(v))
        return openPostMenu();
    const int row = cursorRow();
    const ContentKind kind = v ? contentKind(v) : ContentKind::Other;
    if (!v || !v->model() || row < 0 || kind == ContentKind::Other)
        return false;
    const QModelIndex idx = v->model()->index(row, 0, v->rootIndex());
    v->scrollTo(idx);
    const QRect r = v->visualRect(idx);
    // Month headings span the list.
    if (r.isEmpty() || r.width() > v->viewport()->width() * 0.75)
        return false;
    const QPersistentModelIndex keep(idx);
    QPointer<QAbstractItemView> view(v);
    // The actions' clicks reset the cursor (see the event filter): it stays on the item.
    auto restore = [view, keep] {
        if (LineAccessibleList *list = view ? listFor(view) : nullptr; list && keep.isValid())
            list->m_cursor = keep;
    };
    auto *menu = new QMenu(v);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    QObject::connect(menu->addAction(label("Open")), &QAction::triggered, v, [view, keep, restore] {
        if (view && keep.isValid())
            sendClick(view->viewport(), QRectF(view->visualRect(keep)).center());
        restore();
    });
    if (kind == ContentKind::Media || kind == ContentKind::File) {
        QObject::connect(menu->addAction(label("Save")), &QAction::triggered, v, [view, keep, kind, restore] {
            if (!view || !keep.isValid())
                return;
            if (kind == ContentKind::Media)
                saveMediaItem(view, keep);
            else
                saveFileItem(view, keep);
            restore();
        });
    }
    if (kind == ContentKind::Link) {
        QObject::connect(menu->addAction(label("Copy link")), &QAction::triggered, v, [view, keep, restore] {
            if (view && keep.isValid())
                clickHoverButton(view, keep, "copy link");
            restore();
        });
        QObject::connect(menu->addAction(label("Copy text")), &QAction::triggered, v, [view, keep] {
            LineAccessibleList *list = view ? listFor(view) : nullptr;
            if (QAccessibleInterface *item = list && keep.isValid() ? list->itemAt(keep.row()) : nullptr)
                QGuiApplication::clipboard()->setText(item->text(QAccessible::Name));
        });
    }
    a11yLog("[content] menu for row %d (%d actions)", row, int(menu->actions().size()));
    menu->popup(v->viewport()->mapToGlobal(QRectF(r).center().toPoint()));
    menu->setActiveAction(menu->actions().value(0));
    // The item under the real mouse pointer may take the highlight as the menu shows: the first again.
    QTimer::singleShot(80, menu, [menu] { menu->setActiveAction(menu->actions().value(0)); });
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

bool LineAccessibleList::openCursorRowInNewWindow()
{
    // The chat row menu's "Open in new window", pressed by menuShown() (a double click opens the chat
    // in the main window while the chat room is shown). Without the item the menu stays open.
    // ("Open in separate window" on the Mac, "Open in new window" on Windows.)
    g_menuChoice.wordsIn = { QStringLiteral("window"), QStringLiteral("หน้าต่าง"), QStringLiteral("ウィンドウ"),
                             QStringLiteral("窗口"), QStringLiteral("視窗") };
    g_menuChoice.at.start();
    if (openCursorMenu())
        return true;
    g_menuChoice = PendingMenuChoice();
    return false;
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


namespace {

QAbstractItemView *packageList(QWidget *window, const char *modelClass, bool visibleOnly)
{
    for (QAbstractItemView *v : window->findChildren<QAbstractItemView *>()) {
        if (v->model() && inheritsClass(v->model(), modelClass) && (!visibleOnly || v->isVisible())
            && v->model()->rowCount(v->rootIndex()) > 0)
            return v;
    }
    return nullptr;
}

QWidget *buttonWithIcon(QWidget *window, const char *icon)
{
    for (QWidget *w : window->findChildren<QWidget *>()) {
        if (w->isVisible() && inheritsClass(w, "LcButton") && iconSource(w).contains(QLatin1StringView(icon)))
            return w;
    }
    return nullptr;
}

// Tried this session to read emoji package names (there may be none: not again then).
bool g_emojiNamesTried = false;
// A refresh is under way.
bool g_namesRefreshing = false;

// Names known for every package of the strip? LINE loads the emoji strip only when its tab is
// opened, so emoji names are also missing while none were read yet.
bool packageNamesKnown(QWidget *window)
{
    if (packageNames(true).isEmpty() && !g_emojiNamesTried)
        return false;
    for (const auto &[model, emoji] : { std::pair { "StickerPackageModel", false }, std::pair { "SticonPackageModel", true } }) {
        QAbstractItemView *strip = packageList(window, model, false);
        if (!strip)
            continue;
        const QStringList &names = packageNames(emoji);
        if (names.size() != strip->model()->rowCount(strip->rootIndex()) - 1 || names.contains(QString()))
            return false;
    }
    return true;
}

// Reads every row of the "My stickers" list of stickers or emoji (both stay "visible" in their
// stack); returns how many names it got.
int readMyStickers(QWidget *window, bool emoji, bool quiet = false)
{
    QAbstractItemView *list = nullptr;
    for (QAbstractItemView *v : window->findChildren<QAbstractItemView *>()) {
        if (!v->isVisible() || !v->model() || !inheritsClass(v->model(), "ShopEditPackageModel")
            || v->model()->rowCount(v->rootIndex()) == 0)
            continue;
        QObject *first = v->model()->index(0, 0, v->rootIndex()).data(kItemDataRole).value<QObject *>();
        if (inheritsClass(first, emoji ? "SticonEditPackageData" : "StickerEditPackageData"))
            list = v;
    }
    if (!list) {
        if (!quiet)
            a11yLog("[sticker] My stickers: no %s list", emoji ? "emoji" : "sticker");
        return 0;
    }
    const int rows = list->model()->rowCount(list->rootIndex());
    int read = 0;
    for (int row = 0; row < rows; ++row) {
        const QModelIndex idx = list->model()->index(row, 0, list->rootIndex());
        QObject *data = idx.data(kItemDataRole).value<QObject *>();
        list->scrollTo(idx);
        if (const QString name = firstPaintedLine(list, idx); !name.isEmpty()) {
            notePackageName(inheritsClass(data, "SticonEditPackageData"), row, name, rows);
            ++read;
        }
    }
    list->scrollTo(list->model()->index(0, 0, list->rootIndex()));
    return read;
}

// The tabs of "My stickers" (stickers, emoji), left to right.
QList<QWidget *> myStickersTabs(QWidget *window)
{
    QList<QWidget *> tabs;
    QAbstractItemView *list = packageList(window, "ShopEditPackageModel", true);
    for (QWidget *panel = list ? list->parentWidget() : nullptr; panel && panel != window; panel = panel->parentWidget()) {
        for (QWidget *w : panel->findChildren<QWidget *>()) {
            if (w->isVisible() && inheritsClass(w, "LcCheckBox"))
                tabs << w;
        }
        if (tabs.size() >= 2)
            break;
        tabs.clear();
    }
    std::sort(tabs.begin(), tabs.end(), [window](QWidget *a, QWidget *b) {
        return a->mapTo(window, QPoint()).x() < b->mapTo(window, QPoint()).x();
    });
    return tabs;
}

} // namespace

void refreshStickerPackageNames(QWidget *stickerWindow)
{
    QPointer<QWidget> window(stickerWindow);
    if (g_namesRefreshing || !window || !window->isVisible() || packageNamesKnown(window))
        return;
    QWidget *editButton = buttonWithIcon(window, "edit_icon");
    if (!editButton)
        return;
    g_namesRefreshing = true;
    g_emojiNamesTried = true;
    const QPointer<QWidget> focus = QApplication::focusWidget();
    a11yLog("[sticker] reading the package names from My stickers");
    pressButtonQuietly(editButton);
    // Each step after LINE has shown and drawn the panel.
    QTimer::singleShot(400, window, [window, focus] {
        int read = readMyStickers(window, false);
        const QList<QWidget *> tabs = myStickersTabs(window);
        a11yLog("[sticker] My stickers: %d tabs", int(tabs.size()));
        if (tabs.size() >= 2)
            pressButtonQuietly(tabs.at(1));
        // LINE loads the emoji list a while after its tab is chosen: looked for every 200 ms.
        auto finish = [window, focus, tabs](int all) {
            if (tabs.size() >= 2 && tabs.first())
                pressButtonQuietly(tabs.first());
            if (QWidget *back = buttonWithIcon(window, "back_icon"))
                pressButtonQuietly(back);
            QTimer::singleShot(300, window, [window, focus, all] {
                g_namesRefreshing = false;
                if (focus && focus->isVisible())
                    focus->setFocus(Qt::OtherFocusReason);
                a11yLog("[sticker] %d package names read; focus back on %s", all,
                        focus ? focus->metaObject()->className() : "nothing");
            });
        };
        auto poll = std::make_shared<std::function<void(int)>>();
        *poll = [window, read, finish, poll](int tries) {
            if (!window)
                return;
            const int emoji = readMyStickers(window, true, tries > 0);
            if (emoji > 0 || tries == 0) {
                finish(read + emoji);
                *poll = nullptr;
                return;
            }
            QTimer::singleShot(200, window, [poll, tries] {
                if (*poll)
                    (*poll)(tries - 1);
            });
        };
        QTimer::singleShot(200, window, [poll] { (*poll)(10); });
    });
    // The flag is reset by the last step; a window closed meanwhile takes its timers along.
    QObject::connect(window, &QObject::destroyed, [] { g_namesRefreshing = false; });
}

} // namespace line_a11y
