#include "a11y_announce.h"

#include "a11y_update_filter.h"

#include <QtCore/QElapsedTimer>
#include <QtGui/QGuiApplication>

#import <AppKit/AppKit.h>

namespace line_a11y {

bool voiceOverRunning()
{
    @autoreleasepool {
        return [[NSWorkspace sharedWorkspace] isVoiceOverEnabled];
    }
}

void announce(const QString &text, AnnounceWhen when)
{
    if (text.isEmpty() || !voiceOverRunning())
        return;
    static QString lastText;
    static QElapsedTimer lastTime;
    const bool repeated = text == lastText && lastTime.isValid() && lastTime.elapsed() < 3000;
    bool allowed = true;
    switch (when) {
    case AnnounceWhen::UserAction:
        // Never speak about LINE updating itself.
        allowed = userActedRecently();
        break;
    case AnnounceWhen::LineActive:
        allowed = QGuiApplication::applicationState() == Qt::ApplicationActive;
        break;
    case AnnounceWhen::Always:
        break;
    }
    if (!allowed || repeated) {
        noteAnnouncement(text, false);
        return;
    }
    lastText = text;
    lastTime.start();
    noteAnnouncement(text, true);
    @autoreleasepool {
        NSDictionary *info = @{
            NSAccessibilityAnnouncementKey: text.toNSString(),
            NSAccessibilityPriorityKey: @(NSAccessibilityPriorityHigh),
        };
        NSAccessibilityPostNotificationWithUserInfo(NSApp, NSAccessibilityAnnouncementRequestedNotification, info);
    }
}

void postAnnouncement(const QString &text)
{
    announce(text, AnnounceWhen::UserAction);
}

} // namespace line_a11y
