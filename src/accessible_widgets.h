// QAccessibleInterface implementations for LINE's custom Lc* widgets.

#pragma once

#include <QtGui/QAccessible>
#include <QtWidgets/QAccessibleWidget>

#include <functional>

QT_BEGIN_NAMESPACE
class QLineEdit;
class QTextEdit;
QT_END_NAMESPACE

namespace line_a11y {

// Factory installed with QAccessible::installFactory(). Returns nullptr for widgets that the
// stock Qt widget accessibility already handles well.
QAccessibleInterface *lineAccessibleFactory(const QString &key, QObject *object);

// Which bridge interface (if any) a widget should get.
enum class WidgetKind { None, Input, Menu, List, Delegate, Button, Text, Window, ScrollArea };
WidgetKind classifyWidget(const QWidget *w);

// If Qt cached a stock interface for a widget that should use a bridge interface (this happens
// when Qt queries the widget while it is still being constructed), drop the stale entry so the
// next query goes through lineAccessibleFactory.
void repairCachedInterface(QWidget *w);

// Synthesises a left click (press + release at rect().center()) after giving `w` focus.
void synthesizeClick(QWidget *w);

// Same, at `local` (in w's coordinates), without the QAbstractButton::click() shortcut.
// `prepare` (optional) runs first, inside the deferred call.
void synthesizeClickAt(QWidget *w, QPoint local, std::function<void()> prepare = {});

// A left click in the middle of `w` the way the mouse makes one (enter, move, press, release),
// sent right away. LINE's chat folder tabs and context menu items act only on such a click.
void sendMouseClick(QWidget *w);

// Is `w` one of LINE's input classes (LcTextField, PasswordTextField, LcTextArea,
// ChatDetailInputTextEdit) or a QLineEdit / QTextEdit nested inside an Lc widget?
bool isLineInputWidget(const QWidget *w);

// The message input of a chat (ChatDetailInputTextEdit, or AutoSuggestTextArea in group chats):
// a multi-line LINE text field inside the chat panel.
bool isMessageInput(const QWidget *w);

// Name of the chat shown in the ChatMessagePanel of `w`'s window (first LcText of its header).
QString chatNameFor(const QWidget *w);

// Accessible name / description for an input, following the precedence in CLAUDE.md:
// explicit accessibleName -> chat name (message input) -> placeholderText -> class/context
// heuristics -> nearby LcText.
QString inputAccessibleName(QWidget *w);
QString inputAccessibleDescription(QWidget *w);

// Writes inputAccessibleName()/Description() into w->setAccessibleName()/Description() so
// that even Qt's native QAccessibleLineEdit exposes a label. Never overrides names that
// LINE itself set; refreshes names previously set by the bridge.
void ensureInputLabel(QWidget *w);

// ----------------------------------------------------------------------------------------------

class LineAccessibleWidget : public QAccessibleWidget
{
public:
    LineAccessibleWidget(QWidget *w, QAccessible::Role role);

    QString text(QAccessible::Text t) const override;
    QAccessible::State state() const override;

    // QAccessibleActionInterface
    QStringList actionNames() const override;
    void doAction(const QString &actionName) override;
    QStringList keyBindingsForAction(const QString &actionName) const override;

protected:
    virtual QString computeName() const = 0;
    virtual QString computeDescription() const;
    virtual QString computeValue() const;
    virtual bool isPressable() const;
    virtual void press();

    QString toolTipText() const;
};

class LineAccessibleButton : public LineAccessibleWidget
{
public:
    explicit LineAccessibleButton(QWidget *w);

    // Buttons are leaves: their label already comes from the child LcText, and exposing that
    // child again would make VoiceOver read a redundant AXStaticText inside the AXButton.
    int childCount() const override;
    QAccessibleInterface *child(int index) const override;
    int indexOfChild(const QAccessibleInterface *child) const override;

    QAccessible::State state() const override;
    QStringList actionNames() const override;
    void doAction(const QString &actionName) override;

protected:
    QString computeName() const override;
    QString computeDescription() const override;
    QString computeValue() const override;
    // LcButton reacts to the real cursor position, so synthetic mouse events are ignored; emit
    // its clicked() signals instead (after updating LcCheckBox's "selected" like a click does).
    void press() override;

private:
    static QAccessible::Role roleFor(const QWidget *w);
    bool isCheckable() const;
    bool isChecked() const;
    bool isSelected() const;
};

class LineAccessibleText : public LineAccessibleWidget
{
public:
    explicit LineAccessibleText(QWidget *w);

    // Clickable texts ("Log in with smartphone >") are links. Decided per query: LINE connects
    // clicked() after the widget (and possibly its interface) was created.
    QAccessible::Role role() const override;
    QAccessible::State state() const override;
    QStringList actionNames() const override;

protected:
    QString computeName() const override;
    QString computeValue() const override;
    bool isPressable() const override;
    void press() override;
};

class LineAccessibleInput : public LineAccessibleWidget,
                            public QAccessibleTextInterface,
                            public QAccessibleEditableTextInterface
{
public:
    explicit LineAccessibleInput(QWidget *w);

    void *interface_cast(QAccessible::InterfaceType t) override;
    QAccessible::State state() const override;
    QStringList actionNames() const override;
    void doAction(const QString &actionName) override;
    using LineAccessibleWidget::text;

    // The hint LcText / images inside a text field are not separate elements; real buttons (show
    // password, clear search) stay reachable.
    int childCount() const override;
    QAccessibleInterface *child(int index) const override;
    int indexOfChild(const QAccessibleInterface *child) const override;

    // QAccessibleTextInterface
    void selection(int selectionIndex, int *startOffset, int *endOffset) const override;
    int selectionCount() const override;
    void addSelection(int startOffset, int endOffset) override;
    void removeSelection(int selectionIndex) override;
    void setSelection(int selectionIndex, int startOffset, int endOffset) override;
    int cursorPosition() const override;
    void setCursorPosition(int position) override;
    QString text(int startOffset, int endOffset) const override;
    int characterCount() const override;
    QRect characterRect(int offset) const override;
    int offsetAtPoint(const QPoint &point) const override;
    void scrollToSubstring(int startIndex, int endIndex) override;
    QString attributes(int offset, int *startOffset, int *endOffset) const override;

    // QAccessibleEditableTextInterface
    void deleteText(int startOffset, int endOffset) override;
    void insertText(int offset, const QString &text) override;
    void replaceText(int startOffset, int endOffset, const QString &text) override;

protected:
    QString computeName() const override;
    QString computeDescription() const override;
    QString computeValue() const override;
    bool isPressable() const override;

private:
    QLineEdit *lineEdit() const;
    QTextEdit *textEdit() const;
    bool isMasked() const;
    QString plainText() const;   // unmasked
    QString exposedText() const; // masked for password fields
};

class LineAccessibleDelegate : public LineAccessibleWidget
{
public:
    explicit LineAccessibleDelegate(QWidget *w);

    QAccessible::State state() const override;

protected:
    QString computeName() const override;
    QString computeDescription() const override;
};

// LINE's secondary windows (photos & files, settings, ...) are titled "LINE" or nothing; their
// name is the title shown in their title bar.
class LineAccessibleWindow : public QAccessibleWidget
{
public:
    explicit LineAccessibleWindow(QWidget *w);
    QString text(QAccessible::Text t) const override;
};

// Qt's scroll-area interface exposes only the viewport and scroll bars; LINE puts headers next to
// the viewport (Settings > Chats: the "Basic / Hidden chats" tabs). This one exposes every child.
class LineAccessibleScrollArea : public QAccessibleWidget
{
public:
    explicit LineAccessibleScrollArea(QWidget *w);
};

class LineAccessibleMenu : public LineAccessibleWidget
{
public:
    explicit LineAccessibleMenu(QWidget *w);

    QAccessible::State state() const override;
    QStringList actionNames() const override;

protected:
    QString computeName() const override;
    bool isPressable() const override;
    // Context menu items are clicked like with the mouse (emitting clicked() runs only some
    // commands); if the menu is still open afterwards, the connected signal is emitted.
    void press() override;

private:
    static QAccessible::Role roleFor(const QWidget *w);
};

} // namespace line_a11y
