#include "navigation_order.h"

#include "a11y_EventFilter.h"
#include "a11y_log.h"
#include "line_introspect.h"

#include <QtCore/QDateTime>
#include <QtCore/QPointer>
#include <QtGui/QAccessible>
#include <QtGui/QWindow>
#include <QtWidgets/QApplication>
#include <QtWidgets/QLineEdit>
#include <QtWidgets/QWidget>

#import <AppKit/AppKit.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include <algorithm>

namespace line_a11y {
namespace {

// The login window, top to bottom as a VoiceOver user expects it: the form (fields, "log me in
// automatically", Log in, Reset password), then the QR-code panel (heading, instructions, the code),
// then the link that switches between email and smartphone login.
int loginRank(QAccessibleInterface *child)
{
    QObject *object = child->object();
    if (!object || !object->isWidgetType())
        return 9;
    auto *w = static_cast<QWidget *>(object);
    if (ancestorInheriting(w, "LoginQRCodePanel") || inheritsClass(w, "LoginQRCodePanel")) {
        switch (child->role()) {
        case QAccessible::StaticText:
            return 5;
        default:
            return 6;
        }
    }
    switch (child->role()) {
    case QAccessible::StaticText:
        // The QR panel's heading and instructions; the "+66" beside the phone number stays there.
        return child->text(QAccessible::Value).startsWith(u'+') || child->text(QAccessible::Name).startsWith(u'+') ? 1 : 5;
    case QAccessible::EditableText:
        return 0;
    case QAccessible::CheckBox:
        return 2;
    case QAccessible::Link:
        return 7;
    case QAccessible::Button:
        return inheritsClass(w, "LcButton") && !stringProp(w, "text").isEmpty() ? 3 : 1; // "+66" beside its field
    default:
        return 1;
    }
}

// QMacAccessibilityElement keeps its interface id in the ivar "axid" (Qt 6.6).
Ivar g_axidIvar = nullptr;
Class g_elementClass = nil;
IMP g_defaultImp = nullptr;
IMP g_elementDefaultImp = nullptr;

// Windows read in the order their Tab stops follow (readingOrderKeys(), the Windows bridge's order).
// The login window has its own rule; call windows are ordered like the screen (AppKit's order).
bool usesReadingOrder(QWidget *window)
{
    return window && !inheritsAnyClass(window, { "LoginWindow", "CallWindow" });
}

// readingOrderKeys() of `window`, computed at most every 300 ms (VoiceOver asks group by group).
const QHash<const QWidget *, int> &cachedKeys(QWidget *window)
{
    struct Cached {
        QPointer<QWidget> window;
        qint64 at = 0;
        QHash<const QWidget *, int> keys;
    };
    static Cached cache[4];
    static int next = 0;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    for (Cached &c : cache) {
        if (c.window == window && now - c.at < 300)
            return c.keys;
    }
    Cached *slot = nullptr;
    for (Cached &c : cache) {
        if (c.window == window)
            slot = &c;
    }
    if (!slot) {
        slot = &cache[next];
        next = (next + 1) % 4;
    }
    slot->window = window;
    slot->at = now;
    slot->keys = readingOrderKeys(window);
    return slot->keys;
}

QAccessibleInterface *interfaceOf(id element)
{
    if (!g_elementClass || !g_axidIvar || ![element isKindOfClass:g_elementClass])
        return nullptr;
    const auto id = *reinterpret_cast<const QAccessible::Id *>(reinterpret_cast<const char *>((__bridge void *)element)
                                                                + ivar_getOffset(g_axidIvar));
    return QAccessible::accessibleInterface(id);
}

// The Qt widget window behind an NSWindow.
QWidget *widgetWindowFor(NSWindow *window)
{
    for (QWidget *top : QApplication::topLevelWidgets()) {
        QWindow *handle = top->windowHandle();
        if (handle && top->isVisible() && ((__bridge NSView *)reinterpret_cast<void *>(handle->winId())).window == window)
            return top;
    }
    return nullptr;
}

NSArray *defaultOrder(id self, SEL cmd)
{
    return g_defaultImp ? reinterpret_cast<NSArray *(*)(id, SEL)>(g_defaultImp)(self, cmd) : nil;
}

// `children` (elements of `window`) in reading order. Qt elements without a widget keep their place
// after the element before them; native elements come first.
NSArray *inReadingOrder(QWidget *window, NSArray *children)
{
    const QHash<const QWidget *, int> &keys = cachedKeys(window);
    struct Entry {
        id element;
        int key;
        int index;
    };
    std::vector<Entry> entries;
    int index = 0;
    int previous = -1;
    for (id element in children) {
        int key = previous;
        if (QAccessibleInterface *iface = interfaceOf(element)) {
            QObject *object = iface->object();
            if (object && object->isWidgetType())
                key = keys.value(static_cast<QWidget *>(object), previous);
        } else {
            key = -1; // native (the window's own buttons, LINE's title-bar icons): first, as AppKit has them
        }
        entries.push_back({ element, key, index++ });
        previous = key;
    }
    std::stable_sort(entries.begin(), entries.end(), [](const Entry &a, const Entry &b) { return a.key < b.key; });
    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:entries.size()];
    for (const Entry &e : entries)
        [ordered addObject:e.element];
    return ordered;
}

// -[QMacAccessibilityElement accessibilityChildrenInNavigationOrder]: a group's elements (the split
// view of the chat list and the open chat, the chat header, ...). Lists keep their rows' order.
NSArray *elementChildrenInNavigationOrder(id self, SEL cmd)
{
    auto fallback = [self, cmd]() -> NSArray * {
        if (g_elementDefaultImp)
            return reinterpret_cast<NSArray *(*)(id, SEL)>(g_elementDefaultImp)(self, cmd);
        return NSAccessibilityUnignoredChildren([self accessibilityChildren] ?: @[]);
    };
    QAccessibleInterface *iface = interfaceOf(self);
    QObject *object = iface ? iface->object() : nullptr;
    if (!object || !object->isWidgetType())
        return fallback();
    switch (iface->role()) {
    case QAccessible::List:
    case QAccessible::Table:
    case QAccessible::Tree:
        return fallback();
    default:
        break;
    }
    QWidget *window = static_cast<QWidget *>(object)->window();
    if (!usesReadingOrder(window))
        return fallback();
    NSArray *children = NSAccessibilityUnignoredChildren([self accessibilityChildren] ?: @[]);
    if (children.count < 2)
        return children;
    return inReadingOrder(window, children);
}

NSArray *childrenInNavigationOrder(id self, SEL cmd)
{
    QWidget *window = widgetWindowFor(self);
    if (window && navigationRank(window, nullptr) < 0 && usesReadingOrder(window))
        return inReadingOrder(window, NSAccessibilityUnignoredChildren([self accessibilityChildren] ?: @[]));
    if (!window || navigationRank(window, nullptr) < 0)
        return defaultOrder(self, cmd);
    // The elements VoiceOver sees as the window's children (ignored containers flattened).
    NSArray *children = NSAccessibilityUnignoredChildren([self accessibilityChildren] ?: @[]);
    struct Entry {
        id element;
        int rank;
        int index;
    };
    std::vector<Entry> entries;
    int index = 0;
    for (id element in children) {
        QAccessibleInterface *iface = interfaceOf(element);
        // Native elements (window buttons, LINE's title-bar buttons) stay first, as AppKit has them.
        entries.push_back({ element, iface ? navigationRank(window, iface) : -1, index++ });
    }
    std::stable_sort(entries.begin(), entries.end(), [](const Entry &a, const Entry &b) { return a.rank < b.rank; });
    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:entries.size()];
    for (const Entry &e : entries)
        [ordered addObject:e.element];
    return ordered;
}


bool g_installed = false;

} // namespace

int navigationRank(QWidget *window, QAccessibleInterface *child)
{
    if (!window || !inheritsClass(window, "LoginWindow"))
        return -1;
    return child ? loginRank(child) : 0;
}

void installNavigationOrder()
{
    if (g_installed)
        return;
    Class windowClass = objc_getClass("QNSWindow");
    g_elementClass = objc_getClass("QMacAccessibilityElement");
    if (!windowClass || !g_elementClass)
        return; // libqcocoa not loaded yet
    g_installed = true;
    g_axidIvar = class_getInstanceVariable(g_elementClass, "axid");
    if (!g_axidIvar) {
        a11yLog("[order] QMacAccessibilityElement has no axid ivar; reading order unchanged");
        return;
    }
    const SEL sel = @selector(accessibilityChildrenInNavigationOrder);
    if (Method inherited = class_getInstanceMethod(windowClass, sel))
        g_defaultImp = method_getImplementation(inherited);
    if (class_addMethod(windowClass, sel, reinterpret_cast<IMP>(childrenInNavigationOrder), "@@:"))
        a11yLog("[order] added -[QNSWindow accessibilityChildrenInNavigationOrder]");
    else
        a11yLog("[order] QNSWindow already implements accessibilityChildrenInNavigationOrder; unchanged");
    if (Method inherited = class_getInstanceMethod(g_elementClass, sel))
        g_elementDefaultImp = method_getImplementation(inherited);
    if (class_addMethod(g_elementClass, sel, reinterpret_cast<IMP>(elementChildrenInNavigationOrder), "@@:"))
        a11yLog("[order] added -[QMacAccessibilityElement accessibilityChildrenInNavigationOrder]");
    else
        a11yLog("[order] QMacAccessibilityElement already implements accessibilityChildrenInNavigationOrder; unchanged");
}

} // namespace line_a11y
