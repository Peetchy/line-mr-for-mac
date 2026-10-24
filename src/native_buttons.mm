#include "native_buttons.h"

#include "a11y_log.h"
#include "line_introspect.h"

#import <AppKit/AppKit.h>
#include <objc/message.h>
#include <objc/runtime.h>

namespace line_a11y {
namespace {

// Every NSButton in the window's view hierarchy, title bar included (the frame view is the
// content view's superview).
void collectButtons(NSView *view, NSMutableArray<NSButton *> *out)
{
    if ([view isKindOfClass:[NSButton class]])
        [out addObject:(NSButton *)view];
    for (NSView *child in view.subviews)
        collectButtons(child, out);
}

NSArray<NSButton *> *windowButtons(NSWindow *window)
{
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    NSView *root = window.contentView.superview ?: window.contentView;
    if (root)
        collectButtons(root, buttons);
    return buttons;
}

// The window's own close / minimize / zoom buttons are labelled by AppKit.
bool isStandardWindowButton(NSWindow *window, NSButton *button)
{
    for (NSWindowButton kind : { NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton,
                                 NSWindowToolbarButton, NSWindowDocumentIconButton }) {
        if ([window standardWindowButton:kind] == button)
            return true;
    }
    return false;
}

QString describe(NSButton *button)
{
    return QStringLiteral("label=\"%1\" title=\"%2\" image=\"%3\" alt=\"%4\" action=%5 target=%6 tooltip=\"%7\" frame=%8")
        .arg(QString::fromNSString(button.accessibilityLabel ?: @""), QString::fromNSString(button.title ?: @""),
             QString::fromNSString(button.image.name ?: @""), QString::fromNSString(button.alternateImage.name ?: @""),
             QString::fromNSString(button.action ? NSStringFromSelector(button.action) : @"-"),
             QString::fromNSString(button.target ? NSStringFromClass([button.target class]) : @"-"),
             QString::fromNSString(button.toolTip ?: @""), QString::fromNSString(NSStringFromRect(button.frame)));
}

// The accessibility label for an unlabelled native button of LINE's, or nil.
NSString *labelFor(NSButton *button)
{
    // LINE's own title-bar buttons (the login window's "menu" and "help") keep their name in a
    // property; the names are icon names in the Windows build too (image://login/login-menu.svg).
    if ([button respondsToSelector:@selector(name)]) {
        id name = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(button, @selector(name));
        if ([name isKindOfClass:[NSString class]] && [name length]) {
            const QString text = humanizeIconName(QString::fromNSString(name));
            if (!text.isEmpty())
                return text.toNSString();
        }
    }
    // LINE's icon in the menu bar.
    if ([button isKindOfClass:NSClassFromString(@"NSStatusBarButton")])
        return @"LINE";
    return nil;
}

} // namespace

void labelNativeButtons()
{
    @autoreleasepool {
        for (NSWindow *window in NSApp.windows) {
            if (!window.visible)
                continue;
            for (NSButton *button in windowButtons(window)) {
                if (isStandardWindowButton(window, button) || button.accessibilityLabel.length || button.title.length)
                    continue;
                NSString *label = labelFor(button);
                if (label) {
                    button.accessibilityLabel = label;
                    a11yLog("[native] %s button labelled \"%s\"", NSStringFromClass([button class]).UTF8String, label.UTF8String);
                    continue;
                }
                static int logged = 0;
                if (logged++ < 10)
                    a11yLog("[native] unlabelled button in %s: %s", window.className.UTF8String, qPrintable(describe(button)));
            }
        }
    }
}

namespace {

// Ivars, properties and methods of `cls` (and the ivar values of `object`), for the dump.
QStringList classReport(id object)
{
    QStringList lines;
    for (Class cls = [object class]; cls && cls != [NSObject class] && cls != [NSView class]; cls = class_getSuperclass(cls)) {
        lines << QStringLiteral("    class %1").arg(QString::fromUtf8(class_getName(cls)));
        unsigned n = 0;
        Ivar *ivars = class_copyIvarList(cls, &n);
        for (unsigned i = 0; i < n; ++i) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            QString value;
            if (type && type[0] == '@') {
                id v = object_getIvar(object, ivars[i]);
                value = v ? QString::fromNSString([[v description] substringToIndex:MIN([[v description] length], 120u)]) : QStringLiteral("nil");
            }
            lines << QStringLiteral("      ivar %1 %2 %3").arg(QString::fromUtf8(ivar_getName(ivars[i])), QString::fromUtf8(type ? type : "?"), value);
        }
        free(ivars);
        Method *methods = class_copyMethodList(cls, &n);
        QStringList names;
        for (unsigned i = 0; i < n; ++i)
            names << QString::fromUtf8(sel_getName(method_getName(methods[i])));
        free(methods);
        lines << QStringLiteral("      methods %1").arg(names.join(QLatin1Char(' ')));
    }
    return lines;
}

} // namespace

QStringList nativeButtonReport()
{
    QStringList lines;
    @autoreleasepool {
        for (NSWindow *window in NSApp.windows) {
            if (!window.visible)
                continue;
            for (NSButton *button in windowButtons(window)) {
                if (!button.target || isStandardWindowButton(window, button))
                    continue;
                lines << QStringLiteral("  target of %1:").arg(describe(button));
                lines << classReport(button.target);
                lines << QStringLiteral("    button class %1, image size %2, cell image %3").arg(
                    QString::fromNSString(NSStringFromClass([button class])), QString::fromNSString(NSStringFromSize(button.image.size)),
                    QString::fromNSString([button.cell image].name ?: @"-"));
            }
        }
    }
    @autoreleasepool {
        for (NSWindow *window in NSApp.windows) {
            if (!window.visible)
                continue;
            for (NSButton *button in windowButtons(window)) {
                lines << QStringLiteral("%1 %2%3").arg(QString::fromNSString(window.className), describe(button),
                                                       isStandardWindowButton(window, button) ? QStringLiteral(" [standard]") : QString());
            }
        }
    }
    return lines;
}

} // namespace line_a11y
