#include "transcribe_request.h"

#include "a11y_announce.h"
#include "a11y_log.h"
#include "line_introspect.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QElapsedTimer>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QTimer>
#include <QtCore/QUrl>

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

// ---- The folder saved to last ----------------------------------------------------------------------
// LINE starts every save panel in the home folder (Command+S on a message, Save as...). The folder
// the user saved to last is put there instead (user request 2026-11-16) and kept in save-folder.txt
// beside a11y.log. Only save panels: open panels (attach a file) keep LINE's own place.

bool isPlainSavePanel(id panel)
{
    return ![panel isKindOfClass:[NSOpenPanel class]]
        && ![NSStringFromClass([panel class]) containsString:@"Open"];
}

NSString *saveFolderFile()
{
    return (bridgeDirectory() + QStringLiteral("save-folder.txt")).toNSString();
}

void startInLastSaveFolder(NSSavePanel *panel)
{
    if (!isPlainSavePanel(panel))
        return;
    NSString *path = [[NSString stringWithContentsOfFile:saveFolderFile() encoding:NSUTF8StringEncoding error:nil]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (path.length == 0)
        return;
    // (A sandboxed application may name any folder here; whether it still exists is the panel's to find out.)
    panel.directoryURL = [NSURL fileURLWithPath:path isDirectory:YES];
    a11yLog("[save] the save panel starts in the folder saved to last");
}

void rememberSaveFolder(NSSavePanel *panel, NSModalResponse response, NSURL *url)
{
    if (response != NSModalResponseOK || !isPlainSavePanel(panel) || !url.isFileURL)
        return;
    NSString *folder = url.URLByDeletingLastPathComponent.path;
    if (folder.length == 0)
        return;
    [folder writeToFile:saveFolderFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
            startInLastSaveFolder(self);
            const NSModalResponse response = original(self, sel);
            rememberSaveFolder(self, response, [self URL]);
            return response;
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
            startInLastSaveFolder(self);
            original(self, sel, window, ^(NSModalResponse response) {
                rememberSaveFolder(self, response, [self URL]);
                if (handler)
                    handler(response);
            });
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
            startInLastSaveFolder(self);
            original(self, sel, ^(NSModalResponse response) {
                rememberSaveFolder(self, response, [self URL]);
                if (handler)
                    handler(response);
            });
        }), method_getTypeEncoding(m));
    }
}

} // namespace

QString lastSaveFolder()
{
    QFile file(bridgeDirectory() + QStringLiteral("save-folder.txt"));
    if (!file.open(QIODevice::ReadOnly))
        return QString();
    const QString folder = QString::fromUtf8(file.readAll()).trimmed();
    return !folder.isEmpty() && QFileInfo(folder).isDir() ? folder : QString();
}

void rememberSaveFolder(const QString &folder)
{
    if (folder.isEmpty())
        return;
    QFile file(bridgeDirectory() + QStringLiteral("save-folder.txt"));
    if (file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        file.write(folder.toUtf8());
}

void installSavePanelHooks()
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hookPanelClass([NSSavePanel class]);
        // (A sandboxed app's panels are of this subclass, which overrides the methods.)
        if (Class remote = NSClassFromString(@"NSRemoteSavePanel"))
            hookPanelClass(remote);
    });
}

void answerNextSavePanel(const QString &path, int timeoutMs, std::function<void(bool)> done)
{
    installSavePanelHooks();
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

void saveThenTranscribe(const QString &target, const QString &kind, int seconds, const QString &title,
                        std::function<void()> onSaved)
{
    // (LINE downloads a video before it asks where to save it.)
    answerNextSavePanel(target, kind == QLatin1StringView("video") ? 120000 : 20000, [=](bool asked) {
        if (!asked) {
            announce(label("LINE did not save the file. Try again."), AnnounceWhen::LineActive);
            return;
        }
        waitForFinishedFile(target, [=](bool saved) {
            if (!saved) {
                announce(label("LINE did not save the file. Try again."), AnnounceWhen::LineActive);
                return;
            }
            if (onSaved)
                onSaved();
            if (!requestTranscription(target, kind, seconds, title))
                announce(label("LINE MR.app could not be opened for this."), AnnounceWhen::LineActive);
        });
    });
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

void requestYouTubeDownload(const QString &url)
{
    QString safeUrl = url;
    safeUrl.remove(u'\t').remove(u'\n').remove(u'\r');
    bool ok = false;
    QFile request(bridgeDirectory() + QStringLiteral("youtube-request.txt"));
    if (request.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        request.write(QStringLiteral("url\t%1\n").arg(safeUrl).toUtf8());
        request.close();
        @autoreleasepool {
            ok = [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"linemr://youtube"]];
        }
    }
    // The address may be private: only its host.
    a11yLog("[youtube] LINE MR asked: %s (%d)", qPrintable(QUrl(url).host()), int(ok));
    if (!ok)
        announce(label("LINE MR.app could not be opened for the download."), AnnounceWhen::LineActive);
}

} // namespace line_a11y
