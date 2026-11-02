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
//
// Keyboard (ported from the Windows bridge): the chat and friend lists get a cursor of the bridge's
// own (LINE opens a chat on every arrow key), the message list steps over blank rows, and Space /
// Enter / the menu key act on the message the user is on.

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

// The chat or friend list of the main window (not lists inside rows).
bool isCursorList(const QWidget *w);

// Is a LcContextMenu showing?
bool contextMenuVisible();

// The posts of a group's / OpenChat's Notes (TimelineListView).
bool isPostList(const QWidget *w);

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
//
// Never keep this interface's id from its constructor: QAccessible::uniqueId() there registers the
// interface in Qt's cache before Qt does, Qt registers it a second time, and destroying the view
// deletes it twice (LINE's heap-corruption crashes on Windows). Look it up through the view instead
// (listFor()).
class LineAccessibleList : public QAccessibleWidget
{
public:
    explicit LineAccessibleList(QWidget *w);
    ~LineAccessibleList() override;

    // The bridge interface of `view`, or nullptr.
    static LineAccessibleList *listFor(const QWidget *view);

    QString text(QAccessible::Text t) const override;
    QAccessible::State state() const override;

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
    // Sends a Focus event for the current row's item (or a VoiceOver announcement while keyboard
    // focus is elsewhere, e.g. in the search field).
    void notifyCurrentRow();

    // Makes the newest visible row current (messages start at the bottom).
    void focusLastVisibleRow();
    // Makes the first (or last) row that has text current, scrolling it into view.
    void focusEdgeRow(bool last);
    // Coming back to the messages with Tab / Shift+Tab: makes the row the user last read current
    // again. False (nothing changed) if there is none in this chat (LINE gives each chat a new model).
    bool focusRememberedRow();
    // Up / Down / PageUp / PageDown in the message list: the previous / next row with text (a page:
    // about a screen further). Returns false for other keys.
    bool stepRow(int key);

    // Chat / friend list cursor. LINE opens a chat whenever the current row changes and stalls while
    // it loads, so Up/Down/PageUp/PageDown/Home/End move the bridge's own cursor instead; Enter opens
    // the row under it. Returns false for other keys.
    bool moveCursor(int key);
    // Clicks the row under the cursor if it is not LINE's current one; false if there is nothing to open.
    bool openCursorRow();
    // The chat at `row` of the chat list is being opened: once LINE shows it beside the list, the
    // keyboard goes to its message input (user request). Gives up after 5 s or when the user moves
    // focus to another window or field meanwhile.
    void focusInputWhenOpened(int row);
    // Puts the cursor on `row` (VoiceOver's own navigation landed there).
    void setCursorRow(int row);
    // Back to following LINE's current row (the open chat).
    void resetCursor();
    // The row the user is on: the cursor while it is set, else LINE's current row (-1: none).
    int cursorRow() const;
    bool hasCursor() const { return m_cursor.isValid() && m_cursor.model() == m_model.data(); }

    // Space / Enter on a message: "See more" of a long message, else its link, else what a mouse
    // user would click (voice message play button, video, photo, file, location). False if the
    // row has none of these.
    bool activateMessage();
    // Space / Enter in a picker list (Share with...): ticks or unticks the current row the way a
    // click does. False if the row is not a picker row.
    bool toggleCursorRow();
    // The menu of the message the user is on (right-clicks its bubble; if LINE shows the chat
    // background's menu instead, tries the message's other parts). False if no point can be placed.
    bool openRowMenu();
    // The menu of the chat / friend list row under the cursor (not of LINE's current row).
    bool openCursorMenu();
    // The text of the `n`-th newest message with text (1 = newest), or "" if there is none.
    QString recentMessageText(int n);

    // Grids and lists LINE gives no keyboard (a chat's Photos & videos, Links, Files; the sticker
    // window's packages): the arrows, PageUp/PageDown and Home/End move the bridge's cursor by what is
    // on screen (Left/Right one item, Up/Down the nearest item in the line above / below). Returns
    // false for other keys.
    bool moveGridCursor(int key);
    // Clicks the item under the cursor (or the current one), as a mouse user would.
    bool clickCursorRow();
    // Space / Enter on a post in Notes: clicks its first photo or video (a video's play button), which
    // LINE opens in its media viewer. False if the post shows none.
    bool openPostMedia();
    // The menu key on a post in Notes: the bridge's menu (Open, Save as..., Copy text, LINE's own
    // "More options" menu). LINE has no context menu there.
    bool openPostMenu();
    // The menu key in a chat's Photos & videos / Links / Files window, where LINE has no menu: the
    // bridge's own (Open; Save for photos, videos and files; Copy link and Copy text for links).
    bool openContentMenu();
    // Space / Enter in a chat's search results (ChatSearchResultWindow, the search bar's list button):
    // double-clicks the row like a mouse user (LINE then moves the chat to that message; a single
    // click does nothing) and puts the keyboard on that message in the chat. False in other lists.
    bool openSearchResult();
    // The sender's picture of the received message at `row`: in that row, or (LINE draws the picture
    // and the name only on the first of several messages in a row from one person) in a row above it.
    // Returns that row, or -1 (own messages, notices, dates, or not found). With `scroll`, rows are
    // scrolled into view to be looked at; without, only rows already shown are. Sets `picture` to the
    // picture's place in its row (viewport units, relative to the row).
    int senderPictureRow(int row, bool scroll, QRectF *picture = nullptr) const;
    // Clicks the sender's picture of the message at `row` like a mouse user: LINE opens that
    // person's profile. False if the message has none.
    bool openSenderProfile(int row);
    // Hovers the message at `row` and presses the reaction button LINE then draws beside it (LINE
    // opens its reaction picker). False if the row cannot be looked at.
    // remove: take back the reaction the user gave (press the chosen face).
    bool openReactions(int row, bool remove = false);

private:
    void connectView();
    void connectModel();
    // Reconnects when the view got a new model (LINE gives the message view one per chat).
    void checkModel() const;
    // Drops items past the end once the model has settled after rows went away.
    void schedulePrune() const;
    // Makes `row` current, or reads it again if it already is (VoiceOver ignores a repeated focus).
    void makeCurrent(int row);
    bool openSeeMore(int row);
    bool openLink(int row);
    bool openMessageContent(int row);
    // A new message from someone else at the end of the open chat: announce it.
    void announceNewRow();
    // Bounded wait for rows loaded by an edge scroll (Up on the oldest message). Persistent indices
    // follow prepends.
    void continueEdgeStep(quint64 request, int key, QPersistentModelIndex anchor, int attempts);
    quint64 m_edgeRequest = 0;

    mutable QHash<int, QAccessible::Id> m_items;
    mutable bool m_prunePending = false;
    QList<QMetaObject::Connection> m_connections;
    QList<QMetaObject::Connection> m_modelConnections;
    mutable QPointer<QAbstractItemModel> m_model;
    // Follows its chat when LINE re-sorts the list (new messages move chats to the top).
    QPersistentModelIndex m_cursor;
    // The message row last read while the list had focus (focusRememberedRow()).
    QPersistentModelIndex m_lastRead;
    qint64 m_modelLoadedAt = 0;
};

// The message menu the keyboard opened (openRowMenu) gets more items of the bridge's own: "React" /
// "Remove reaction" for messages, "Show <sender>'s profile" for received messages in groups (user
// requests). They are widgets inside LINE's menu, reached and pressed with the menu keys the bridge
// already handles. Called once the menu is shown.
void addProfileMenuItem(QWidget *menu);
// Removes those items again (the menu is hidden; LINE may show the same menu widget again).
void removeExtraMenuItems(QWidget *menu);
bool isExtraMenuItem(const QWidget *w);
// The item's interface (menu item with a press action), nullptr for other widgets.
QAccessibleInterface *extraMenuItemAccessible(QWidget *w);
// An item the bridge asked to press in the next menu LINE shows within a few seconds (a file's
// "Save as..." after jumping to its message), matched by text; nullptr if none is pending or matches.
QWidget *takePendingMenuChoice(const QList<QWidget *> &items);

// The sticker window's package strip has no names; LINE draws them only in "My stickers" (its Edit
// button). When names are missing or the number of packages changed, open "My stickers", read both
// tabs, go back and put focus back (user request on Windows). Called when a StickerWindow shows.
void refreshStickerPackageNames(QWidget *stickerWindow);

} // namespace line_a11y
