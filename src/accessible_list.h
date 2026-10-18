// Accessibility for LINE's LcListView (chat list, friend list, chat messages, ...).
//
// LcListView does not create a widget per row; Qt's stock QAccessibleTable therefore exposes empty
// cells (the model's display data is an opaque object). Row texts come from, in order:
//  1. the model's per-row data object (role Qt::UserRole + 1, "itemData"): ChatData, ProfileData,
//     SectionData, ... are QObjects whose Q_PROPERTYs hold name, last message, time, counts;
//  2. ChatMessageData (message list): no properties; text and sender are read from fixed offsets
//     (readChatMessageData()), the message kind from the class of the delegate that paints it;
//  3. ListRowTextCache, for other property-less rows (LcModelDataObject). LINE paints every row with
//     a shared, parentless LcListDelegateWidget that it refills per row, without Qt paint events or
//     signals; the delegate keeps the row's data object pointer at this + 0x400
//     (lcListDelegateDataPointer()). The cache finds the delegate showing a row (rendering just that
//     row offscreen if needed) and reads its texts. Delegate texts can lag behind the pointer when
//     LINE paints a row from its own cache, so chat messages never use them.

#pragma once

#include <QtCore/QAbstractItemModel>
#include <QtCore/QHash>
#include <QtCore/QObject>
#include <QtCore/QPersistentModelIndex>
#include <QtCore/QPointer>
#include <QtCore/QSet>
#include <QtCore/QTimer>
#include <QtGui/QAccessible>
#include <QtWidgets/QAccessibleWidget>

#include "line_introspect.h"

#include <functional>

QT_BEGIN_NAMESPACE
class QAbstractItemView;
QT_END_NAMESPACE

namespace line_a11y {

bool isLineListView(const QWidget *w);

class ListRowTextCache : public QObject
{
public:
    // The cache attached to `view` (a child QObject), created on first use.
    static ListRowTextCache *forView(QAbstractItemView *view);

    // Text recorded for `row` (empty until LINE has painted the row at least once).
    QString text(int row);
    // Class of the delegate widget LINE paints `row` with (ChatSendDelegateWidget, ...).
    QString delegateClassFor(int row);
    // Text lines recognised in the picture of `row` (cached; recognised in the background while the
    // row is fully on screen, so empty until that has happened).
    QStringList visibleTexts(int row);
    // Was this chat message sent by the logged-in user?
    bool isOwnMessage(const ChatMessageFields &fields);

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

public:
    void clear();

    // Invoked when a row's text changes (row, new text).
    std::function<void(int, const QString &)> onRowTextChanged;

private:
    explicit ListRowTextCache(QAbstractItemView *view);
    void watchModel();
    int rowOf(quintptr dataObject);
    void record(quintptr dataObject, const QString &text);
    QString textFromDelegates(quintptr dataObject);
    QWidget *delegateShowing(quintptr dataObject) const;
    bool renderRow(int row);
    void requestRecognition(int row);
    void prefetchVisibleRows();

    QPointer<QAbstractItemView> m_view;
    QPointer<QAbstractItemModel> m_model;
    QList<QMetaObject::Connection> m_modelConnections;
    QHash<quintptr, QString> m_texts;   // row data object -> texts
    // Keyed by rowKey(): the message id for chat messages (data objects of a closed chat are freed
    // and their addresses reused by the next chat, so pointers are not stable identities).
    struct Recognized {
        QStringList lines;
        qint64 at = 0; // ms since epoch
    };
    QString rowKey(int row) const;
    QHash<QString, QString> m_classes;    // row key -> delegate class
    QHash<QString, Recognized> m_visible; // row key -> recognised text lines
    QSet<QString> m_recognizing;
    QTimer *m_prefetchTimer = nullptr;
    QHash<quintptr, int> m_rowOfObject; // rebuilt lazily after model changes
    QSet<QString> m_otherSenders;       // senders of received messages in this list
    bool m_rowsDirty = true;
    bool m_loggedFirstText = false;
    bool m_rendering = false;
};

// LcListView as a flat AXList of row items. Deliberately not a QAccessibleTableInterface: Qt's
// Cocoa bridge binds synthesized AXRow/AXCell elements to cell interfaces permanently, and LINE's
// constant model churn (new messages, section folding) leaves those elements dead.
class LineAccessibleList : public QAccessibleWidget
{
public:
    explicit LineAccessibleList(QWidget *w);
    ~LineAccessibleList() override;

    QString text(QAccessible::Text t) const override;

    int childCount() const override;
    QAccessibleInterface *child(int index) const override;
    int indexOfChild(const QAccessibleInterface *child) const override;
    QAccessibleInterface *focusChild() const override;
    QAccessibleInterface *childAt(int x, int y) const override;

    QAccessibleInterface *itemAt(int row) const;
    int rowCount() const;
    bool isRowSelected(int row) const;

    QAbstractItemView *view() const;
    ListRowTextCache *cache() const;
    // Sends a Focus event for the current row's item (or a VoiceOver announcement).
    void notifyCurrentRow();

private:
    void connectView();
    // Drops items past the end once the model has settled after rows went away.
    void schedulePrune() const;

    mutable QHash<int, QAccessible::Id> m_items;
    mutable bool m_prunePending = false;
    QList<QMetaObject::Connection> m_connections;
};

} // namespace line_a11y
