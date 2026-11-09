#include "transcribe_request.h"

#include "a11y_log.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QElapsedTimer>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QTimer>

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#include <memory>

namespace line_a11y {
namespace {

NSURL *g_answerURL = nil;
std::function<void(bool)> g_answerDone;
quint64 g_answerRequest = 0;

void noteAnswered()
{
    if (g_answerDone) {
        auto done = std::move(g_answerDone);
        g_answerDone = nullptr;
        done(true);
    }
    // Qt reads the panel's URL after it has "closed".
    const quint64 request = g_answerRequest;
    QTimer::singleShot(3000, qApp, [request] {
        if (request == g_answerRequest)
            g_answerURL = nil;
    });
}

void hookPanelClass(Class cls)
{
    {
        SEL sel = @selector(runModal);
        Method m = class_getInstanceMethod(cls, sel);
        auto original = reinterpret_cast<NSModalResponse (*)(id, SEL)>(method_getImplementation(m));
        class_replaceMethod(cls, sel, imp_implementationWithBlock(^NSModalResponse(id self) {
            if (g_answerURL) {
                noteAnswered();
                return NSModalResponseOK;
            }
            return original(self, sel);
        }), method_getTypeEncoding(m));
    }
    {
        SEL sel = @selector(URL);
        Method m = class_getInstanceMethod(cls, sel);
        auto original = reinterpret_cast<NSURL *(*)(id, SEL)>(method_getImplementation(m));
        class_replaceMethod(cls, sel, imp_implementationWithBlock(^NSURL *(id self) {
            return g_answerURL ? g_answerURL : original(self, sel);
        }), method_getTypeEncoding(m));
    }
    {
        SEL sel = @selector(beginSheetModalForWindow:completionHandler:);
        Method m = class_getInstanceMethod(cls, sel);
        auto original = reinterpret_cast<void (*)(id, SEL, NSWindow *, void (^)(NSModalResponse))>(method_getImplementation(m));
        class_replaceMethod(cls, sel, imp_implementationWithBlock(^(id self, NSWindow *window, void (^handler)(NSModalResponse)) {
            if (g_answerURL) {
                noteAnswered();
                dispatch_async(dispatch_get_main_queue(), ^{ handler(NSModalResponseOK); });
                return;
            }
            original(self, sel, window, handler);
        }), method_getTypeEncoding(m));
    }
    {
        SEL sel = @selector(beginWithCompletionHandler:);
        Method m = class_getInstanceMethod(cls, sel);
        auto original = reinterpret_cast<void (*)(id, SEL, void (^)(NSModalResponse))>(method_getImplementation(m));
        class_replaceMethod(cls, sel, imp_implementationWithBlock(^(id self, void (^handler)(NSModalResponse)) {
            if (g_answerURL) {
                noteAnswered();
                dispatch_async(dispatch_get_main_queue(), ^{ handler(NSModalResponseOK); });
                return;
            }
            original(self, sel, handler);
        }), method_getTypeEncoding(m));
    }
}

} // namespace

void answerNextSavePanel(const QString &path, int timeoutMs, std::function<void(bool)> done)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hookPanelClass([NSSavePanel class]);
        // (A sandboxed app's panels are of this subclass, which overrides the methods.)
        if (Class remote = NSClassFromString(@"NSRemoteSavePanel"))
            hookPanelClass(remote);
    });
    g_answerURL = [NSURL fileURLWithPath:path.toNSString()];
    g_answerDone = std::move(done);
    const quint64 request = ++g_answerRequest;
    QTimer::singleShot(timeoutMs, qApp, [request] {
        if (request != g_answerRequest || !g_answerDone)
            return;
        auto done = std::move(g_answerDone);
        g_answerDone = nullptr;
        g_answerURL = nil;
        a11yLog("[transcribe] LINE asked for no file name");
        done(false);
    });
}

void stopAwaitingSavePanel()
{
    if (!g_answerDone)
        return;
    auto done = std::move(g_answerDone);
    g_answerDone = nullptr;
    g_answerURL = nil;
    ++g_answerRequest;
    a11yLog("[transcribe] LINE showed an alert instead of a save panel");
    done(false);
}

void waitForFinishedFile(const QString &path, std::function<void(bool)> done)
{
    auto *timer = new QTimer(qApp);
    auto since = std::make_shared<QElapsedTimer>();
    since->start();
    auto lastSize = std::make_shared<qint64>(-1);
    auto steady = std::make_shared<int>(0);
    QObject::connect(timer, &QTimer::timeout, timer, [=] {
        const qint64 size = QFileInfo(path).size();
        *steady = size > 0 && size == *lastSize ? *steady + 1 : 0;
        *lastSize = size;
        const bool finished = *steady >= 3;
        if (!finished && since->elapsed() < 60000)
            return;
        timer->stop();
        timer->deleteLater();
        done(finished);
    });
    timer->start(250);
}

bool requestTranscription(const QString &file, const QString &kind, int seconds, const QString &title)
{
    QFile request(bridgeDirectory() + QStringLiteral("transcribe-request.txt"));
    if (!request.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return false;
    QString name = title;
    name.replace(u'\t', u' ').replace(u'\n', u' ').replace(u'\r', u' ');
    request.write(QStringLiteral("file\t%1\nkind\t%2\nseconds\t%3\ntitle\t%4\n").arg(file, kind).arg(seconds).arg(name).toUtf8());
    request.close();
    @autoreleasepool {
        const bool ok = [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"linemr://transcribe"]];
        a11yLog("[transcribe] LINE MR asked: %s, %d s (%d)", qPrintable(kind), seconds, int(ok));
        return ok;
    }
}

} // namespace line_a11y
