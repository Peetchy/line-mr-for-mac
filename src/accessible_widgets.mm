#include "accessible_widgets.h"

#include "a11y_log.h"
#include "accessible_list.h"
#include "line_introspect.h"
#include "a11y_update_filter.h"
#include "qt_signal_utils.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QMetaMethod>
#include <QtCore/QMetaProperty>
#include <QtCore/QPointer>
#include <QtCore/QSet>
#include <QtCore/QVariant>
#include <QtGui/QEnterEvent>
#include <QtGui/QFontMetrics>
#include <QtGui/QMouseEvent>
#include <QtGui/QTextCursor>
#include <QtGui/QTextDocument>
#include <QtWidgets/QAbstractButton>
#include <QtWidgets/QLabel>
#include <QtWidgets/QLineEdit>
#include <QtWidgets/QTextEdit>
#include <QtWidgets/QWidget>

#include <typeinfo>

namespace line_a11y {
namespace {

constexpr const char *kAutoNameProperty = "_lineA11yAutoName";
constexpr const char *kAutoDescriptionProperty = "_lineA11yAutoDescription";

constexpr QChar kMaskChar = QChar(0x2022); // BULLET, as used by native macOS secure fields

QVariant readProperty(const QObject *o, const char *name)
{
    const QMetaObject *mo = o->metaObject();
    const int index = mo->indexOfProperty(name);
    if (index >= 0)
        return mo->property(index).read(o);
    return o->property(name); // dynamic property, invalid QVariant if absent
}

QString stringProp(const QObject *o, const char *name)
{
    const QVariant v = readProperty(o, name);
    return v.metaType().id() == QMetaType::QString ? cleanText(v.toString()) : QString();
}

// Returns 1 / 0 for a bool property, -1 if the property does not exist.
int boolProp(const QObject *o, const char *name)
{
    const QVariant v = readProperty(o, name);
    if (!v.isValid() || v.metaType().id() != QMetaType::Bool)
        return -1;
    return v.toBool() ? 1 : 0;
}

bool firstTrueBoolProp(const QObject *o, std::initializer_list<const char *> names)
{
    for (const char *name : names) {
        const int value = boolProp(o, name);
        if (value >= 0)
            return value == 1;
    }
    return false;
}

// accessibleName() unless the bridge itself wrote it (then it is recomputed instead).
QString explicitAccessibleName(const QWidget *w)
{
    const QString name = w->accessibleName();
    if (name.isEmpty() || name == w->property(kAutoNameProperty).toString())
        return QString();
    return cleanText(name);
}

QString explicitAccessibleDescription(const QWidget *w)
{
    const QString desc = w->accessibleDescription();
    if (desc.isEmpty() || desc == w->property(kAutoDescriptionProperty).toString())
        return QString();
    return cleanText(desc);
}

QString iconDerivedName(const QWidget *w)
{
    for (const char *prop : { "iconSource", "source", "icon", "imageSource", "image", "defaultSource" }) {
        const QString path = stringProp(w, prop);
        if (!path.isEmpty()) {
            const QString name = humanizeIconName(path);
            if (!name.isEmpty())
                return name;
        }
    }
    // LcImage keeps its source outside the meta-object system.
    if (const QString source = lcImageSource(w); !source.isEmpty())
        return humanizeIconName(source);
    return QString();
}

QString objectNameDerived(const QWidget *w)
{
    const QString on = w->objectName();
    if (on.isEmpty() || on.startsWith(QLatin1StringView("qt_")))
        return QString();
    return humanizeIdentifier(on);
}

bool contextContains(const QWidget *w, QLatin1StringView word, int levels)
{
    const QWidget *p = w;
    for (int i = 0; p && i <= levels; ++i, p = p->parentWidget()) {
        if (p->objectName().contains(word, Qt::CaseInsensitive))
            return true;
        if (QLatin1StringView(p->metaObject()->className()).contains(word, Qt::CaseInsensitive))
            return true;
    }
    return false;
}

QStringList withBaseActions(QStringList actions, const QStringList &base)
{
    for (const QString &a : base) {
        if (!actions.contains(a))
            actions << a;
    }
    return actions;
}

// LcImages LINE uses as icon buttons (e.g. the call button in the chat header) emit clicked();
// decorative images have nobody listening.
bool isClickableImage(const QWidget *w)
{
    if (!inheritsClass(w, "LcImage"))
        return false;
    struct Peek : QObject {
        using QObject::isSignalConnected;
    };
    const auto *peek = static_cast<const Peek *>(static_cast<const QObject *>(w));
    const QMetaObject *mo = w->metaObject();
    for (const char *signature : { "clicked()", "clicked(LcImage*)" }) {
        const int index = mo->indexOfSignal(signature);
        if (index >= 0 && peek->isSignalConnected(mo->method(index)))
            return true;
    }
    return false;
}

bool isInputClass(const QWidget *w)
{
    if (!qobject_cast<const QLineEdit *>(w) && !qobject_cast<const QTextEdit *>(w))
        return false;
    return inheritsAnyClass(w, { "LcTextField", "PasswordTextField", "LcTextArea", "ChatDetailInputTextEdit" });
}

// LINE's search boxes are plain LcTextFields with a magnifier image and a hidden
// "search" / clear button as children.
bool hasSearchAffordance(const QWidget *w)
{
    for (QObject *child : w->children()) {
        if (!child->isWidgetType() || !inheritsClass(child, "LcButton"))
            continue;
        auto *button = static_cast<QWidget *>(child);
        for (const QString &hint : { iconDerivedName(button), stringProp(button, "text"),
                                     extractLcWidgetToolTip(button), button->objectName() }) {
            if (hint.contains(QLatin1StringView("search"), Qt::CaseInsensitive))
                return true;
        }
    }
    return false;
}

QString heuristicInputLabel(QWidget *w)
{
    auto *le = qobject_cast<QLineEdit *>(w);
    if (inheritsClass(w, "PasswordTextField") || (le && le->echoMode() == QLineEdit::Password))
        return QStringLiteral("Password");
    if (ancestorInheriting(w, "LoginEmailPhoneNumberPanel"))
        return QStringLiteral("Email address");
    if (ancestorInheriting(w, "LoginPasswordlessPanel"))
        return QStringLiteral("Phone number");
    if (inheritsClass(w, "ChatDetailInputTextEdit"))
        return QStringLiteral("Message input");
    // A search box nested inside the chat panel is still a search box, so check the close
    // context for "search"/"filter" before falling back to the chat-panel heuristic.
    const bool inChat = ancestorInheriting(w, "ChatMessageInputPanel") || ancestorInheriting(w, "ChatMessagePanel");
    if (!inChat && hasSearchAffordance(w)) {
        if (ancestorInheriting(w, "MainChatPanel"))
            return QStringLiteral("Search chats");
        if (ancestorInheriting(w, "MainFriendPanel"))
            return QStringLiteral("Search friends");
    }
    if (hasSearchAffordance(w) || contextContains(w, QLatin1StringView("search"), 3)
        || contextContains(w, QLatin1StringView("filter"), 3))
        return QStringLiteral("Search");
    if (inChat)
        return QStringLiteral("Message input");
    return QString();
}

QString placeholderOf(const QWidget *w)
{
    if (auto *le = qobject_cast<const QLineEdit *>(w))
        return cleanText(le->placeholderText());
    if (auto *te = qobject_cast<const QTextEdit *>(w))
        return cleanText(te->placeholderText());
    return QString();
}

} // namespace

// ---- Classification / factory ------------------------------------------------------------------

WidgetKind classifyWidget(const QWidget *w)
{
    if (!w)
        return WidgetKind::None;
    if (isInputClass(w))
        return WidgetKind::Input;
    if (isLineListView(w))
        return WidgetKind::List;
    if (inheritsAnyClass(w, { "LcContextMenu", "LcContextMenuItem", "LcCheckableContextMenuItem",
                              "LcCheckboxContextMenuItem", "LcContextMenuSeperator" }))
        return WidgetKind::Menu;
    if (inheritsClass(w, "LcListDelegateWidget")
        || (inheritsClass(w, "LcWidget") && QLatin1StringView(w->metaObject()->className()).endsWith(QLatin1StringView("DelegateWidget"))))
        return WidgetKind::Delegate;
    if (inheritsAnyClass(w, { "LcButton", "LcIconTextButton", "LcRadioButton", "LcCheckBox" }) || isClickableImage(w))
        return WidgetKind::Button;
    if (inheritsAnyClass(w, { "LcText", "HighlightableTextWidget", "LcLabel" }))
        return WidgetKind::Text;
    return WidgetKind::None;
}

QAccessibleInterface *lineAccessibleFactory(const QString &key, QObject *object)
{
    if (!object || !object->isWidgetType())
        return nullptr;
    // Qt calls the factory once per class in the hierarchy; decide on the most-derived one.
    if (key != QLatin1StringView(object->metaObject()->className()))
        return nullptr;
    auto *w = static_cast<QWidget *>(object);
    const WidgetKind kind = classifyWidget(w);
    if (kind != WidgetKind::None) {
        static QSet<QByteArray> loggedClasses;
        const QByteArray cls = object->metaObject()->className();
        if (!loggedClasses.contains(cls)) {
            loggedClasses.insert(cls);
            a11yLog("[factory] first bridge interface for %s (kind %d)", cls.constData(), int(kind));
        }
    }
    switch (kind) {
    case WidgetKind::Input:
        return new LineAccessibleInput(w);
    case WidgetKind::Menu:
        return new LineAccessibleMenu(w);
    case WidgetKind::List:
        return new LineAccessibleList(w);
    case WidgetKind::Delegate:
        return new LineAccessibleDelegate(w);
    case WidgetKind::Button:
        return new LineAccessibleButton(w);
    case WidgetKind::Text:
        return new LineAccessibleText(w);
    case WidgetKind::None:
        break;
    }
    return nullptr;
}

void repairCachedInterface(QWidget *w)
{
    if (classifyWidget(w) == WidgetKind::None)
        return;
    QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(w);
    if (!iface || dynamic_cast<LineAccessibleWidget *>(iface) || dynamic_cast<LineAccessibleList *>(iface))
        return;
    a11yLog("[factory] replacing stale %s interface for %s", typeid(*iface).name(), w->metaObject()->className());
    QAccessible::deleteAccessibleInterface(QAccessible::uniqueId(iface));
}

// ---- Actions -------------------------------------------------------------------------------------

namespace {

void sendClickEvents(QWidget *target, QPointF local)
{
    QPointer<QWidget> guard(target);
    const QPointF scene = target->mapTo(target->window(), local);
    const QPointF global = target->mapToGlobal(local);

    QEnterEvent enter(local, scene, global);
    QCoreApplication::sendEvent(target, &enter);
    if (!guard)
        return;
    QMouseEvent press(QEvent::MouseButtonPress, local, scene, global, Qt::LeftButton, Qt::LeftButton,
                      Qt::NoModifier);
    QCoreApplication::sendEvent(target, &press);
    if (!guard)
        return;
    QMouseEvent release(QEvent::MouseButtonRelease, local, scene, global, Qt::LeftButton, Qt::NoButton,
                        Qt::NoModifier);
    QCoreApplication::sendEvent(target, &release);
    if (!guard)
        return;
    QEvent leave(QEvent::Leave);
    QCoreApplication::sendEvent(target, &leave);
}

} // namespace

void synthesizeClick(QWidget *w)
{
    if (!w)
        return;
    markUserActivity();
    QPointer<QWidget> guard(w);
    // Deferred: doAction() runs inside a synchronous Cocoa accessibility request, and a click
    // that opens a modal dialog would otherwise block VoiceOver until the dialog closes.
    QMetaObject::invokeMethod(w, [guard] {
        QWidget *target = guard.data();
        if (!target || !target->isEnabled() || !target->isVisible())
            return;
        target->setFocus(Qt::OtherFocusReason);
        if (auto *button = qobject_cast<QAbstractButton *>(target)) {
            button->click();
            return;
        }
        sendClickEvents(target, QRectF(target->rect()).center());
    }, Qt::QueuedConnection);
}

void synthesizeClickAt(QWidget *w, QPoint local, std::function<void()> prepare)
{
    if (!w)
        return;
    markUserActivity();
    QPointer<QWidget> guard(w);
    QMetaObject::invokeMethod(w, [guard, local, prepare = std::move(prepare)] {
        if (prepare)
            prepare();
        QWidget *target = guard.data();
        if (!target || !target->isEnabled() || !target->isVisible())
            return;
        sendClickEvents(target, QPointF(local) + QPointF(0.5, 0.5));
    }, Qt::QueuedConnection);
}

// ---- Input labelling -----------------------------------------------------------------------------

bool isLineInputWidget(const QWidget *w)
{
    if (!w || (!qobject_cast<const QLineEdit *>(w) && !qobject_cast<const QTextEdit *>(w)))
        return false;
    return isInputClass(w) || ancestorInheriting(w, "LcWidget") != nullptr;
}

QString inputAccessibleName(QWidget *w)
{
    if (!w)
        return QString();
    if (const QString name = explicitAccessibleName(w); !name.isEmpty())
        return name;
    if (const QString placeholder = placeholderOf(w); !placeholder.isEmpty())
        return placeholder;
    if (const QString heuristic = heuristicInputLabel(w); !heuristic.isEmpty())
        return heuristic;
    // LcTextField draws its hint with a child LcText; otherwise use the caption beside it.
    for (QObject *child : w->children()) {
        if (child->isWidgetType() && inheritsClass(child, "LcText") && !static_cast<QWidget *>(child)->isHidden()) {
            const QString text = extractLcTextString(static_cast<QWidget *>(child));
            if (!text.isEmpty())
                return text;
        }
    }
    if (const QString label = nearbyLabelText(w); !label.isEmpty())
        return label;
    if (const QString fromName = objectNameDerived(w); !fromName.isEmpty())
        return fromName;
    return qobject_cast<QTextEdit *>(w) ? QStringLiteral("Text area") : QStringLiteral("Text field");
}

QString inputAccessibleDescription(QWidget *w)
{
    if (!w)
        return QString();
    if (const QString desc = explicitAccessibleDescription(w); !desc.isEmpty())
        return desc;
    const QString name = inputAccessibleName(w);
    const QString heuristic = heuristicInputLabel(w);
    if (!heuristic.isEmpty() && heuristic != name)
        return heuristic;
    const QString placeholder = placeholderOf(w);
    if (!placeholder.isEmpty() && placeholder != name)
        return placeholder;
    const QString tip = extractLcWidgetToolTip(w);
    return tip != name ? tip : QString();
}

void ensureInputLabel(QWidget *w)
{
    if (!isLineInputWidget(w))
        return;
    const QString autoName = w->property(kAutoNameProperty).toString();
    const QString currentName = w->accessibleName();
    if (currentName.isEmpty() || currentName == autoName) {
        const QString name = inputAccessibleName(w);
        if (!name.isEmpty() && name != currentName) {
            w->setProperty(kAutoNameProperty, name);
            w->setAccessibleName(name);
            a11yLog("[input] %s '%s' -> name '%s'", w->metaObject()->className(), qPrintable(w->objectName()),
                    qPrintable(name));
        }
    }
    const QString autoDesc = w->property(kAutoDescriptionProperty).toString();
    const QString currentDesc = w->accessibleDescription();
    if (currentDesc.isEmpty() || currentDesc == autoDesc) {
        const QString desc = inputAccessibleDescription(w);
        if (desc != currentDesc) {
            w->setProperty(kAutoDescriptionProperty, desc);
            w->setAccessibleDescription(desc);
        }
    }
}

// ---- LineAccessibleWidget ------------------------------------------------------------------------

LineAccessibleWidget::LineAccessibleWidget(QWidget *w, QAccessible::Role role)
    : QAccessibleWidget(w, role)
{
}

QString LineAccessibleWidget::text(QAccessible::Text t) const
{
    switch (t) {
    case QAccessible::Name:
        return computeName();
    case QAccessible::Description: {
        QString desc = explicitAccessibleDescription(widget());
        if (desc.isEmpty())
            desc = computeDescription();
        return desc == computeName() ? QString() : desc;
    }
    case QAccessible::Value:
        return computeValue();
    case QAccessible::Help:
        return toolTipText();
    default:
        return QAccessibleWidget::text(t);
    }
}

QAccessible::State LineAccessibleWidget::state() const
{
    return QAccessibleWidget::state();
}

QStringList LineAccessibleWidget::actionNames() const
{
    QStringList actions;
    if (isPressable())
        actions << pressAction();
    return withBaseActions(actions, QAccessibleWidget::actionNames());
}

void LineAccessibleWidget::doAction(const QString &actionName)
{
    if ((actionName == pressAction() || actionName == toggleAction()) && isPressable()) {
        press();
        return;
    }
    QAccessibleWidget::doAction(actionName);
}

QStringList LineAccessibleWidget::keyBindingsForAction(const QString &actionName) const
{
    return QAccessibleWidget::keyBindingsForAction(actionName);
}

QString LineAccessibleWidget::computeDescription() const
{
    return toolTipText();
}

QString LineAccessibleWidget::computeValue() const
{
    return QString();
}

bool LineAccessibleWidget::isPressable() const
{
    return widget()->isEnabled();
}

void LineAccessibleWidget::press()
{
    synthesizeClick(widget());
}

QString LineAccessibleWidget::toolTipText() const
{
    return extractLcWidgetToolTip(widget());
}

// ---- LineAccessibleButton ------------------------------------------------------------------------

LineAccessibleButton::LineAccessibleButton(QWidget *w)
    : LineAccessibleWidget(w, roleFor(w))
{
}

// LcCheckBoxes in an LcRadioGroup (sidebar tabs, chat-list filter chips) behave as radio buttons.
static bool inRadioGroup(const QWidget *w)
{
    const QVariant group = readProperty(w, "radioGroup");
    return group.isValid() && !group.isNull();
}

// Numeric badge (unread count) drawn by a sibling LcText over the button's corner.
static QString overlappingBadge(const QWidget *w)
{
    QWidget *parent = w->parentWidget();
    if (!parent)
        return QString();
    const QRect g = w->geometry().adjusted(-4, -4, 4, 4);
    for (QObject *child : parent->children()) {
        if (child == w || !child->isWidgetType() || !inheritsClass(child, "LcText"))
            continue;
        auto *c = static_cast<QWidget *>(child);
        if (c->isHidden() || !g.intersects(c->geometry()))
            continue;
        const QString text = widgetText(c);
        if (isBadgeText(text))
            return text;
    }
    return QString();
}

QAccessible::Role LineAccessibleButton::roleFor(const QWidget *w)
{
    if (inheritsClass(w, "LcCheckBox"))
        return inRadioGroup(w) ? QAccessible::RadioButton : QAccessible::CheckBox;
    if (inheritsClass(w, "LcRadioButton"))
        return QAccessible::RadioButton;
    return QAccessible::Button;
}

bool LineAccessibleButton::isCheckable() const
{
    return role() == QAccessible::CheckBox || role() == QAccessible::RadioButton
        || boolProp(widget(), "checkable") == 1;
}

bool LineAccessibleButton::isChecked() const
{
    return firstTrueBoolProp(widget(), { "checked", "isChecked", "selected" });
}

bool LineAccessibleButton::isSelected() const
{
    return boolProp(widget(), "selected") == 1;
}

// Another visible sibling button laid exactly over this one, later in paint order (so on top and
// receiving the clicks): LINE's ad banner stacks two full-size buttons.
static bool coveredByTwin(const QWidget *w)
{
    QWidget *parent = w->parentWidget();
    if (!parent)
        return false;
    bool after = false;
    for (QObject *child : parent->children()) {
        if (child == w) {
            after = true;
            continue;
        }
        if (!after || !child->isWidgetType() || !inheritsClass(child, "LcButton"))
            continue;
        auto *c = static_cast<QWidget *>(child);
        if (!c->isHidden() && c->geometry() == w->geometry())
            return true;
    }
    return false;
}

QAccessible::State LineAccessibleButton::state() const
{
    QAccessible::State st = LineAccessibleWidget::state();
    if (coveredByTwin(widget()))
        st.invisible = true;
    if (isCheckable()) {
        st.checkable = true;
        st.checked = isChecked();
    } else if (isSelected()) {
        st.selectable = true;
        st.selected = true;
    }
    return st;
}

int LineAccessibleButton::childCount() const
{
    return 0;
}

QAccessibleInterface *LineAccessibleButton::child(int index) const
{
    Q_UNUSED(index);
    return nullptr;
}

int LineAccessibleButton::indexOfChild(const QAccessibleInterface *child) const
{
    Q_UNUSED(child);
    return -1;
}

QStringList LineAccessibleButton::actionNames() const
{
    // Always advertised: macOS reports dimmed buttons through AXEnabled (state().disabled), not by
    // hiding AXPress. Qt's Cocoa bridge translates kAXPressAction into toggleAction() for checkbox
    // and radio roles (and only performs it if listed), so checkables advertise toggleAction()
    // instead of pressAction(); both appear as AXPress and doAction() accepts either.
    return withBaseActions({ isCheckable() ? toggleAction() : pressAction() }, QAccessibleWidget::actionNames());
}

void LineAccessibleButton::doAction(const QString &actionName)
{
    if ((actionName == pressAction() || actionName == toggleAction()) && widget()->isEnabled()) {
        press();
        return;
    }
    QAccessibleWidget::doAction(actionName);
}

// The call window (LineCall.app's VoiceCallWindow / GroupCallWindow): round icon buttons are
// labelled by an LcText right below them ("Mute", "Speaker", ...), and the small arrow laid over
// a button's corner opens that button's device menu.
static QString callWindowButtonName(const QWidget *w)
{
    QWidget *parent = w->parentWidget();
    if (!parent)
        return QString();
    const QRect g = w->geometry();
    const QList<QObject *> siblings = parent->children();
    if (stringProp(w, "source").contains(QLatin1StringView("menu-up"))) {
        for (QObject *child : siblings) {
            if (child == w || !child->isWidgetType() || !inheritsClass(child, "LcButton"))
                continue;
            auto *c = static_cast<QWidget *>(child);
            if (c->isHidden() || !c->geometry().contains(g.center()) || c->geometry().width() <= g.width())
                continue;
            if (QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(c)) {
                if (QString owner = iface->text(QAccessible::Name); !owner.isEmpty())
                    return QStringLiteral("%1 options").arg(owner);
            }
        }
        return QString();
    }
    for (QObject *child : siblings) {
        if (!child->isWidgetType() || !inheritsClass(child, "LcText"))
            continue;
        auto *c = static_cast<QWidget *>(child);
        const QRect t = c->geometry();
        if (c->isHidden() || t.top() < g.bottom() - 2 || t.top() > g.bottom() + 16 || t.left() > g.center().x()
            || t.right() < g.center().x())
            continue;
        if (QString text = widgetText(c); !text.isEmpty())
            return text;
    }
    return QString();
}

QString LineAccessibleButton::computeName() const
{
    QWidget *w = widget();
    if (QString name = explicitAccessibleName(w); !name.isEmpty())
        return name;
    if (QString text = stringProp(w, "text"); !text.isEmpty())
        return text;
    if (QString children = collectVisibleChildTexts(w, QStringLiteral(" ")); !children.isEmpty())
        return children;
    if (isCheckable()) {
        if (QString label = nearbyLabelText(w); !label.isEmpty())
            return label;
    }
    if (QString tip = toolTipText(); !tip.isEmpty())
        return tip;
    if (ancestorInheriting(w, "CallWindow")) {
        if (QString name = callWindowButtonName(w); !name.isEmpty())
            return name;
    }
    if (QString icon = iconDerivedName(w); !icon.isEmpty())
        return icon;
    if (QString name = objectNameDerived(w); !name.isEmpty())
        return name;
    // A transparent button laid over sibling labels (e.g. the pinned announcement bar).
    if (QWidget *parent = w->parentWidget()) {
        QStringList covered;
        for (QObject *child : parent->children()) {
            if (child == w || !child->isWidgetType() || !inheritsClass(child, "LcText"))
                continue;
            auto *c = static_cast<QWidget *>(child);
            if (!c->isHidden() && w->geometry().contains(c->geometry().center())) {
                if (QString text = widgetText(c); !text.isEmpty())
                    covered << text;
            }
        }
        if (!covered.isEmpty())
            return covered.join(QLatin1StringView(", "));
    }
    // A bare container button whose icon is a nested LcButton / LcImage.
    for (QWidget *child : w->findChildren<QWidget *>()) {
        if (child->isHidden())
            continue;
        if (QString icon = iconDerivedName(child); !icon.isEmpty())
            return icon;
    }
    // LINE's ad banners: full-size buttons open the ad; the small one in the corner opens the
    // ad's menu (hide / report). None of them carries text, tooltip or icon name.
    if (ancestorInheriting(w, "AdvertisementPanel"))
        return w->width() <= 40 && w->height() <= 40 ? QStringLiteral("Ad options") : QStringLiteral("Advertisement");
    return QString();
}

void LineAccessibleButton::press()
{
    markUserActivity();
    QWidget *w = widget();
    if (inheritsClass(w, "LcImage")) {
        // Like LcButton, LcImage ignores synthetic mouse events; emit its clicked() signals.
        QPointer<QWidget> guard(w);
        QMetaObject::invokeMethod(w, [guard] {
            if (!guard || !guard->isEnabled() || !guard->isVisible())
                return;
            void *self = guard.data();
            void *args[] = { nullptr, &self };
            emitSignal(guard, "clicked()");
            if (guard)
                emitSignal(guard, "clicked(LcImage*)", args);
        }, Qt::QueuedConnection);
        return;
    }
    if (!inheritsClass(w, "LcButton")) {
        LineAccessibleWidget::press();
        return;
    }
    QPointer<QWidget> guard(w);
    QMetaObject::invokeMethod(w, [guard] {
        QWidget *target = guard.data();
        if (!target || !target->isEnabled() || !target->isVisible())
            return;
        if (inheritsClass(target, "LcCheckBox")) {
            const bool selected = boolProp(target, "selected") == 1;
            // A radio-group member stays selected when clicked again.
            if (!inRadioGroup(target) || !selected)
                target->setProperty("selected", !selected);
            if (!guard)
                return;
        }
        void *self = target;
        void *args[] = { nullptr, &self };
        emitSignal(target, "clicked()");
        if (guard)
            emitSignal(target, "clicked(LcButton*)", args);
    }, Qt::QueuedConnection);
}

QString LineAccessibleButton::computeDescription() const
{
    const QString tip = toolTipText();
    if (const QString badge = overlappingBadge(widget()); !badge.isEmpty()) {
        const QString count = badge + QStringLiteral(" new");
        return tip.isEmpty() ? count : tip + QStringLiteral(", ") + count;
    }
    if (!isCheckable() && isSelected())
        return tip.isEmpty() ? QStringLiteral("Selected") : tip + QStringLiteral(", selected");
    return tip;
}

QString LineAccessibleButton::computeValue() const
{
    if (isCheckable())
        return isChecked() ? QStringLiteral("1") : QStringLiteral("0");
    return QString();
}

// ---- LineAccessibleText --------------------------------------------------------------------------

LineAccessibleText::LineAccessibleText(QWidget *w)
    : LineAccessibleWidget(w, QAccessible::StaticText)
{
}

QString LineAccessibleText::computeName() const
{
    QWidget *w = widget();
    if (QString text = widgetText(w); !text.isEmpty())
        return text;
    return collectVisibleChildTexts(w, QStringLiteral(" "));
}

QString LineAccessibleText::computeValue() const
{
    return computeName();
}

bool LineAccessibleText::isPressable() const
{
    QWidget *w = widget();
    if (!w->isEnabled())
        return false;
    if (firstTrueBoolProp(w, { "clickable", "isClickable", "linkEnabled", "isLink" }))
        return true;
    if (auto *label = qobject_cast<QLabel *>(w)) {
        if ((label->textInteractionFlags() & Qt::LinksAccessibleByMouse) && label->text().contains(QLatin1StringView("<a ")))
            return true;
    }
    return w->testAttribute(Qt::WA_SetCursor) && w->cursor().shape() == Qt::PointingHandCursor;
}

QAccessible::State LineAccessibleText::state() const
{
    QAccessible::State st = LineAccessibleWidget::state();
    // Empty text widgets are layout placeholders; keep VoiceOver from stopping on them.
    if (computeName().isEmpty())
        st.invisible = true;
    return st;
}

// ---- LineAccessibleInput -------------------------------------------------------------------------

LineAccessibleInput::LineAccessibleInput(QWidget *w)
    : LineAccessibleWidget(w, QAccessible::EditableText)
{
}

QLineEdit *LineAccessibleInput::lineEdit() const
{
    return qobject_cast<QLineEdit *>(widget());
}

QTextEdit *LineAccessibleInput::textEdit() const
{
    return qobject_cast<QTextEdit *>(widget());
}

bool LineAccessibleInput::isMasked() const
{
    // PasswordTextField keeps echoMode Normal while empty and only switches once text is
    // entered, so the class alone must already mark it as a secure field.
    if (inheritsClass(widget(), "PasswordTextField"))
        return true;
    QLineEdit *le = lineEdit();
    return le && le->echoMode() != QLineEdit::Normal;
}

QString LineAccessibleInput::plainText() const
{
    if (QLineEdit *le = lineEdit())
        return le->text();
    if (QTextEdit *te = textEdit()) {
        // toRawText() keeps one character per document position (needed for offsets).
        QString raw = te->document()->toRawText();
        raw.replace(QChar::ParagraphSeparator, u'\n');
        raw.replace(QChar::LineSeparator, u'\n');
        raw.replace(QChar::Nbsp, u' ');
        return raw;
    }
    return QString();
}

QString LineAccessibleInput::exposedText() const
{
    if (isMasked()) {
        QLineEdit *le = lineEdit();
        if (le && le->echoMode() == QLineEdit::NoEcho)
            return QString();
        return QString(plainText().size(), kMaskChar);
    }
    return plainText();
}

void *LineAccessibleInput::interface_cast(QAccessible::InterfaceType t)
{
    if (t == QAccessible::TextInterface)
        return static_cast<QAccessibleTextInterface *>(this);
    if (t == QAccessible::EditableTextInterface)
        return static_cast<QAccessibleEditableTextInterface *>(this);
    return LineAccessibleWidget::interface_cast(t);
}

QAccessible::State LineAccessibleInput::state() const
{
    QAccessible::State st = LineAccessibleWidget::state();
    bool readOnly = false;
    if (QLineEdit *le = lineEdit()) {
        readOnly = le->isReadOnly();
        if (le->hasSelectedText())
            st.selectableText = true;
    } else if (QTextEdit *te = textEdit()) {
        readOnly = te->isReadOnly();
        st.multiLine = true;
    }
    if (isMasked())
        st.passwordEdit = true;
    st.editable = !readOnly;
    st.readOnly = readOnly;
    st.focusable = true;
    st.selectableText = true;
    return st;
}

QStringList LineAccessibleInput::actionNames() const
{
    return withBaseActions({ setFocusAction() }, QAccessibleWidget::actionNames());
}

void LineAccessibleInput::doAction(const QString &actionName)
{
    if (actionName == setFocusAction() || actionName == pressAction()) {
        widget()->setFocus(Qt::OtherFocusReason);
        return;
    }
    QAccessibleWidget::doAction(actionName);
}

QString LineAccessibleInput::computeName() const
{
    return inputAccessibleName(widget());
}

QString LineAccessibleInput::computeDescription() const
{
    return inputAccessibleDescription(widget());
}

QString LineAccessibleInput::computeValue() const
{
    return exposedText();
}

bool LineAccessibleInput::isPressable() const
{
    return false;
}

void LineAccessibleInput::selection(int selectionIndex, int *startOffset, int *endOffset) const
{
    *startOffset = *endOffset = 0;
    if (selectionIndex != 0)
        return;
    if (QLineEdit *le = lineEdit()) {
        if (le->hasSelectedText()) {
            *startOffset = le->selectionStart();
            *endOffset = le->selectionEnd();
        }
    } else if (QTextEdit *te = textEdit()) {
        const QTextCursor c = te->textCursor();
        if (c.hasSelection()) {
            *startOffset = c.selectionStart();
            *endOffset = c.selectionEnd();
        }
    }
}

int LineAccessibleInput::selectionCount() const
{
    if (QLineEdit *le = lineEdit())
        return le->hasSelectedText() ? 1 : 0;
    if (QTextEdit *te = textEdit())
        return te->textCursor().hasSelection() ? 1 : 0;
    return 0;
}

void LineAccessibleInput::addSelection(int startOffset, int endOffset)
{
    setSelection(0, startOffset, endOffset);
}

void LineAccessibleInput::removeSelection(int selectionIndex)
{
    if (selectionIndex != 0)
        return;
    if (QLineEdit *le = lineEdit()) {
        le->deselect();
    } else if (QTextEdit *te = textEdit()) {
        QTextCursor c = te->textCursor();
        c.clearSelection();
        te->setTextCursor(c);
    }
}

void LineAccessibleInput::setSelection(int selectionIndex, int startOffset, int endOffset)
{
    if (selectionIndex != 0)
        return;
    const int count = characterCount();
    startOffset = qBound(0, startOffset, count);
    endOffset = qBound(0, endOffset, count);
    if (QLineEdit *le = lineEdit()) {
        le->setSelection(startOffset, endOffset - startOffset);
    } else if (QTextEdit *te = textEdit()) {
        QTextCursor c(te->document());
        c.setPosition(startOffset);
        c.setPosition(endOffset, QTextCursor::KeepAnchor);
        te->setTextCursor(c);
    }
}

int LineAccessibleInput::cursorPosition() const
{
    if (QLineEdit *le = lineEdit())
        return le->cursorPosition();
    if (QTextEdit *te = textEdit())
        return te->textCursor().position();
    return 0;
}

void LineAccessibleInput::setCursorPosition(int position)
{
    position = qBound(0, position, characterCount());
    if (QLineEdit *le = lineEdit()) {
        le->setCursorPosition(position);
    } else if (QTextEdit *te = textEdit()) {
        QTextCursor c = te->textCursor();
        c.setPosition(position);
        te->setTextCursor(c);
    }
}

QString LineAccessibleInput::text(int startOffset, int endOffset) const
{
    const QString all = exposedText();
    startOffset = qBound(0, startOffset, int(all.size()));
    endOffset = qBound(startOffset, endOffset, int(all.size()));
    return all.mid(startOffset, endOffset - startOffset);
}

int LineAccessibleInput::characterCount() const
{
    if (QTextEdit *te = textEdit())
        return qMax(0, te->document()->characterCount() - 1);
    return int(exposedText().size());
}

QRect LineAccessibleInput::characterRect(int offset) const
{
    if (QLineEdit *le = lineEdit()) {
        // QLineEdit only exposes the caret rectangle publicly; measure from there so that
        // horizontal scrolling and text margins are accounted for.
        const QString display = le->displayText();
        offset = qBound(0, offset, int(display.size()));
        const QFontMetrics fm(le->font());
        const QRect caret = le->inputMethodQuery(Qt::ImCursorRectangle).toRect();
        const int cursor = le->cursorPosition();
        int x = caret.x();
        if (offset >= cursor)
            x += fm.horizontalAdvance(display.mid(cursor, offset - cursor));
        else
            x -= fm.horizontalAdvance(display.mid(offset, cursor - offset));
        const int width = offset < display.size() ? fm.horizontalAdvance(display.at(offset)) : 1;
        const QRect local(x, caret.y(), qMax(1, width), caret.height());
        return QRect(le->mapToGlobal(local.topLeft()), local.size());
    }
    if (QTextEdit *te = textEdit()) {
        QTextCursor c(te->document());
        c.setPosition(qBound(0, offset, characterCount()));
        const QRect caret = te->cursorRect(c);
        const QString all = plainText();
        const QFontMetrics fm(c.charFormat().font());
        const int width = offset >= 0 && offset < all.size() && all.at(offset) != u'\n'
            ? fm.horizontalAdvance(all.at(offset)) : 1;
        const QRect local(caret.x(), caret.y(), qMax(1, width), caret.height());
        return QRect(te->viewport()->mapToGlobal(local.topLeft()), local.size());
    }
    return QRect();
}

int LineAccessibleInput::offsetAtPoint(const QPoint &point) const
{
    if (QLineEdit *le = lineEdit())
        return le->cursorPositionAt(le->mapFromGlobal(point));
    if (QTextEdit *te = textEdit())
        return te->cursorForPosition(te->viewport()->mapFromGlobal(point)).position();
    return -1;
}

void LineAccessibleInput::scrollToSubstring(int startIndex, int endIndex)
{
    if (QLineEdit *le = lineEdit()) {
        const int keep = le->cursorPosition();
        le->setCursorPosition(qBound(0, endIndex, int(le->text().size())));
        le->setCursorPosition(qBound(0, startIndex, int(le->text().size())));
        le->setCursorPosition(keep);
    } else if (QTextEdit *te = textEdit()) {
        const QTextCursor keep = te->textCursor();
        QTextCursor c(te->document());
        c.setPosition(qBound(0, endIndex, characterCount()));
        te->setTextCursor(c);
        te->ensureCursorVisible();
        c.setPosition(qBound(0, startIndex, characterCount()));
        te->setTextCursor(c);
        te->ensureCursorVisible();
        te->setTextCursor(keep);
    }
}

QString LineAccessibleInput::attributes(int offset, int *startOffset, int *endOffset) const
{
    Q_UNUSED(offset);
    *startOffset = 0;
    *endOffset = characterCount();
    return QString();
}

void LineAccessibleInput::deleteText(int startOffset, int endOffset)
{
    replaceText(startOffset, endOffset, QString());
}

void LineAccessibleInput::insertText(int offset, const QString &text)
{
    replaceText(offset, offset, text);
}

void LineAccessibleInput::replaceText(int startOffset, int endOffset, const QString &text)
{
    const int count = characterCount();
    startOffset = qBound(0, startOffset, count);
    endOffset = qBound(startOffset, endOffset, count);
    if (QLineEdit *le = lineEdit()) {
        if (le->isReadOnly())
            return;
        // Selection + insert() keeps the edit on QLineEdit's undo stack (setText() would not).
        le->setSelection(startOffset, endOffset - startOffset);
        if (text.isEmpty() && endOffset > startOffset)
            le->del();
        else
            le->insert(text);
    } else if (QTextEdit *te = textEdit()) {
        if (te->isReadOnly())
            return;
        QTextCursor c(te->document());
        c.setPosition(startOffset);
        c.setPosition(endOffset, QTextCursor::KeepAnchor);
        c.insertText(text);
        te->setTextCursor(c);
    }
}

// ---- LineAccessibleDelegate ----------------------------------------------------------------------

LineAccessibleDelegate::LineAccessibleDelegate(QWidget *w)
    : LineAccessibleWidget(w, QAccessible::ListItem)
{
}

QString LineAccessibleDelegate::computeName() const
{
    QWidget *w = widget();
    if (QString name = explicitAccessibleName(w); !name.isEmpty())
        return name;
    if (QString texts = collectVisibleChildTexts(w); !texts.isEmpty())
        return texts;
    return toolTipText();
}

QString LineAccessibleDelegate::computeDescription() const
{
    return toolTipText();
}

QAccessible::State LineAccessibleDelegate::state() const
{
    QAccessible::State st = LineAccessibleWidget::state();
    st.selectable = true;
    st.selected = firstTrueBoolProp(widget(), { "selected", "isSelected", "current", "isCurrent", "highlighted" });
    return st;
}

// ---- LineAccessibleMenu --------------------------------------------------------------------------

LineAccessibleMenu::LineAccessibleMenu(QWidget *w)
    : LineAccessibleWidget(w, roleFor(w))
{
}

QAccessible::Role LineAccessibleMenu::roleFor(const QWidget *w)
{
    if (inheritsClass(w, "LcContextMenuSeperator"))
        return QAccessible::Separator;
    if (inheritsAnyClass(w, { "LcContextMenuItem", "LcCheckableContextMenuItem", "LcCheckboxContextMenuItem" }))
        return QAccessible::MenuItem;
    return QAccessible::PopupMenu;
}

QAccessible::State LineAccessibleMenu::state() const
{
    QAccessible::State st = LineAccessibleWidget::state();
    if (inheritsAnyClass(widget(), { "LcCheckableContextMenuItem", "LcCheckboxContextMenuItem" })) {
        st.checkable = true;
        st.checked = firstTrueBoolProp(widget(), { "checked", "isChecked", "selected" });
    }
    return st;
}

QStringList LineAccessibleMenu::actionNames() const
{
    QStringList actions;
    if (isPressable())
        actions << pressAction(); // no toggleAction(): Cocoa maps it to AXPress too
    return withBaseActions(actions, QAccessibleWidget::actionNames());
}

QString LineAccessibleMenu::computeName() const
{
    QWidget *w = widget();
    if (role() == QAccessible::Separator)
        return QString();
    if (QString name = explicitAccessibleName(w); !name.isEmpty())
        return name;
    if (QString text = stringProp(w, "text"); !text.isEmpty())
        return text;
    if (role() == QAccessible::MenuItem) {
        if (QString texts = collectVisibleChildTexts(w, QStringLiteral(" ")); !texts.isEmpty())
            return texts;
    } else if (QString title = cleanText(w->windowTitle()); !title.isEmpty()) {
        return title;
    }
    if (QString tip = toolTipText(); !tip.isEmpty())
        return tip;
    return role() == QAccessible::PopupMenu ? QStringLiteral("Context menu") : QString();
}

bool LineAccessibleMenu::isPressable() const
{
    return role() == QAccessible::MenuItem && widget()->isEnabled();
}

} // namespace line_a11y
