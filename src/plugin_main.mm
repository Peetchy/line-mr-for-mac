// Entry points of libline_a11y.dylib.
//
// Qt loads this file as a "cocoa" platform-theme plugin from
// $QT_PLUGIN_PATH/platformthemes. qt_plugin_instance() bootstraps the accessibility bridge
// and returns nullptr, so Qt falls back to the built-in Cocoa platform theme.

#include "a11y_EventFilter.h"
#include "a11y_log.h"
#include "accessible_widgets.h"
#include "call_launch_hook.h"
#include "line_introspect.h"
#include "line_metadata.h"
#include "navigation_order.h"
#include "text_capture.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QFile>
#include <QtCore/QMetaObject>
#include <QtCore/QTimer>
#include <QtCore/qplugin.h>
#include <QtGui/QAccessible>
#include <QtWidgets/QApplication>

#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include <atomic>

namespace line_a11y {
namespace {

constexpr int kWatchdogIntervalMs = 1000;

std::atomic<bool> g_bootstrapped{ false };
bool g_bridgeStarted = false;
A11yEventFilter *g_filter = nullptr;

// Qt 6.6.3's QMacAccessibilityElement implements the misspelled -accessibilitySubRole, which
// AppKit never calls, so Qt widgets never report a subrole (AXSecureTextField, AXSearchField).
// Add the correctly spelled NSAccessibility method, forwarding to Qt's implementation.
id forwardAccessibilitySubrole(id self, SEL)
{
    return reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(self, sel_registerName("accessibilitySubRole"));
}

bool g_subroleFixed = false;

void installCocoaSubroleFix()
{
    if (g_subroleFixed)
        return;
    Class cls = objc_getClass("QMacAccessibilityElement");
    if (!cls)
        return; // libqcocoa not loaded yet; retried from startBridge()
    g_subroleFixed = true;
    const SEL qtSelector = sel_registerName("accessibilitySubRole");
    const SEL axSelector = sel_registerName("accessibilitySubrole");
    if (!class_getInstanceMethod(cls, qtSelector)) {
        a11yLog("[cocoa] QMacAccessibilityElement has no -accessibilitySubRole; subrole fix not needed");
        return;
    }
    // class_addMethod only fails if the class itself (not a superclass) already defines it,
    // i.e. a Qt build where the typo is fixed.
    if (class_addMethod(cls, axSelector, reinterpret_cast<IMP>(forwardAccessibilitySubrole), "@@:"))
        a11yLog("[cocoa] added -[QMacAccessibilityElement accessibilitySubrole] -> accessibilitySubRole");
    else
        a11yLog("[cocoa] QMacAccessibilityElement already implements -accessibilitySubrole");
}

// Qt never unloads plugins whose instance is null today, but make sure the image stays mapped
// for the lifetime of the process since we install callbacks into QtGui.
void pinSelf()
{
    Dl_info info{};
    if (dladdr(reinterpret_cast<const void *>(&pinSelf), &info) && info.dli_fname)
        dlopen(info.dli_fname, RTLD_NOLOAD | RTLD_NODELETE);
}

// Crash guard: a marker file exists while LINE runs with the bridge and is removed when LINE
// quits normally. If LINE crashed twice in a row, start in safe mode (no rendering of list rows,
// the riskiest part). Tools that kill LINE on purpose delete the marker first.
void checkPreviousSessions(QApplication *app)
{
    const QString dir = QString::fromUtf8(a11yDirectory()) + QLatin1Char('/');
    const QString marker = dir + QStringLiteral("session.running");
    const QString counter = dir + QStringLiteral("crash-count");
    int crashes = 0;
    if (QFile::exists(marker)) {
        QFile c(counter);
        if (c.open(QIODevice::ReadOnly))
            crashes = c.readAll().trimmed().toInt();
        ++crashes;
        a11yLog("[guard] previous LINE session did not end normally (%d in a row)", crashes);
    }
    if (QFile c(counter); c.open(QIODevice::WriteOnly | QIODevice::Truncate))
        c.write(QByteArray::number(crashes));
    if (QFile m(marker); m.open(QIODevice::WriteOnly | QIODevice::Truncate))
        m.write(QByteArray::number(qint64(getpid())));
    if (crashes >= 2) {
        setSafeMode(true);
        a11yLog("[guard] safe mode: list rows are not rendered");
    }
    QObject::connect(app, &QCoreApplication::aboutToQuit, [marker, counter] {
        QFile::remove(marker);
        QFile::remove(counter);
    });
}

void startBridge()
{
    if (g_bridgeStarted)
        return;
    auto *app = qobject_cast<QApplication *>(QCoreApplication::instance());
    if (!app) {
        a11yLog("[bridge] QCoreApplication is not a QApplication (%s); widget bridge not started",
                QCoreApplication::instance() ? QCoreApplication::instance()->metaObject()->className() : "null");
        return;
    }
    g_bridgeStarted = true;
    checkPreviousSessions(app);
    installCocoaSubroleFix();
    installNavigationOrder();

    enforceAccessibilityHandler("startBridge");
    QAccessible::removeFactory(lineAccessibleFactory);
    QAccessible::installFactory(lineAccessibleFactory);

    g_filter = new A11yEventFilter(app);
    app->installEventFilter(g_filter);
    g_filter->startWatchdog(kWatchdogIntervalMs);

    // LcApplication installs its no-op handler late in startup; catch it quickly.
    for (int delay : { 0, 100, 250, 500 }) {
        QTimer::singleShot(delay, g_filter, [] {
            if (g_filter)
                g_filter->watchdogTick();
        });
    }
    a11yLog("[bridge] started: event filter + %d ms watchdog installed on %s", kWatchdogIntervalMs,
            app->metaObject()->className());
}

void startBridgePreRoutine()
{
    // qAddPreRoutine runs while QCoreApplication is still being constructed; defer to the
    // event loop so that LcApplication's constructor has completed.
    QMetaObject::invokeMethod(QCoreApplication::instance(), [] { startBridge(); }, Qt::QueuedConnection);
}

void bootstrap()
{
    bool expected = false;
    if (!g_bootstrapped.compare_exchange_strong(expected, true))
        return;

    pinSelf();

    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        a11yLog("[plugin] libline_a11y loaded into %s %s (%s), Qt runtime %s, log dir %s",
                [[bundle bundleIdentifier] UTF8String] ?: "?",
                [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String] ?: "?",
                [[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String] ?: "?",
                qVersion(), a11yDirectory());
    }
    intptr_t slide = 0;
    if (lineImageSlide(&slide))
        a11yLog("[plugin] LINE image slide 0x%lx", static_cast<long>(slide));
    offsetsAvailable(); // logs the gating result once

    QAccessible::installFactory(lineAccessibleFactory);
    enforceAccessibilityHandler("qt_plugin_instance");
    installCocoaSubroleFix();
    installCallLaunchHook();

    if (QCoreApplication::instance())
        QMetaObject::invokeMethod(QCoreApplication::instance(), [] { startBridge(); }, Qt::QueuedConnection);
    else
        qAddPreRoutine(startBridgePreRoutine);
}

} // namespace
} // namespace line_a11y

__attribute__((constructor)) static void lineA11yImageLoaded()
{
    line_a11y::a11yLog("[plugin] image mapped (pid %d)", getpid());
}

extern "C" Q_DECL_EXPORT QT_PREPEND_NAMESPACE(QPluginMetaData) qt_plugin_query_metadata_v2()
{
    static constexpr QT_PLUGIN_METADATAV2_SECTION QPluginMetaDataV2<line_a11y::kPluginMetaData> md{};
    return md;
}

extern "C" Q_DECL_EXPORT QT_PREPEND_NAMESPACE(QObject) *qt_plugin_instance()
{
    line_a11y::bootstrap();
    return nullptr; // fall back to Qt's built-in Cocoa platform theme
}
