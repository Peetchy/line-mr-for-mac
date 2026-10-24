#include "navigation_order.h"

#include "a11y_log.h"
#include "line_introspect.h"

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

NSArray *childrenInNavigationOrder(id self, SEL cmd)
{
    QWidget *window = widgetWindowFor(self);
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
}

} // namespace line_a11y
