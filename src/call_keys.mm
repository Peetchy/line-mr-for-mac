#include "call_keys.h"

#include "a11y_announce.h"
#include "a11y_log.h"
#include "accessible_quick.h"
#include "line_introspect.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QMetaObject>
#include <QtWidgets/QApplication>
#include <QtWidgets/QWidget>

#include <Carbon/Carbon.h>

namespace line_a11y {
namespace {

constexpr OSType kHotKeySignature = 'LnMR';
enum HotKey : UInt32 { Answer = 1, Decline = 2 };

EventHandlerRef g_handler = nullptr;
EventHotKeyRef g_answerKey = nullptr;
EventHotKeyRef g_declineKey = nullptr;

OSStatus hotKeyPressed(EventHandlerCallRef, EventRef event, void *)
{
    EventHotKeyID id {};
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, nullptr, sizeof(id), nullptr, &id) != noErr
        || id.signature != kHotKeySignature)
        return eventNotHandledErr;
    const UInt32 which = id.id;
    // Carbon calls this from the main run loop; act after the event has been dispatched.
    QMetaObject::invokeMethod(QCoreApplication::instance(), [which] {
        if (which == Answer)
            answerCall();
        else
            declineOrEndCall();
    }, Qt::QueuedConnection);
    return noErr;
}

void registerHotKeys()
{
    if (g_answerKey)
        return;
    if (!g_handler) {
        const EventTypeSpec spec { kEventClassKeyboard, kEventHotKeyPressed };
        InstallApplicationEventHandler(&hotKeyPressed, 1, &spec, nullptr, &g_handler);
    }
    const OSStatus a = RegisterEventHotKey(kVK_ANSI_A, cmdKey | optionKey, EventHotKeyID { kHotKeySignature, Answer },
                                           GetApplicationEventTarget(), 0, &g_answerKey);
    const OSStatus d = RegisterEventHotKey(kVK_ANSI_D, cmdKey | optionKey, EventHotKeyID { kHotKeySignature, Decline },
                                           GetApplicationEventTarget(), 0, &g_declineKey);
    a11yLog("[call] hot keys Option+Command+A / D registered (%d, %d)", int(a), int(d));
}

void unregisterHotKeys()
{
    if (g_answerKey)
        UnregisterEventHotKey(g_answerKey);
    if (g_declineKey)
        UnregisterEventHotKey(g_declineKey);
    if (g_answerKey || g_declineKey)
        a11yLog("[call] hot keys Option+Command+A / D released");
    g_answerKey = g_declineKey = nullptr;
}

// A widget tagged lineMR_<tag> (the call window's End call button), pressed through its interface.
bool pressWidgetTag(const QString &tag)
{
    const QString name = QStringLiteral("lineMR_") + tag;
    for (QWidget *top : QApplication::topLevelWidgets()) {
        if (!top->isVisible())
            continue;
        for (QWidget *w : top->findChildren<QWidget *>(name)) {
            if (!w->isVisible())
                continue;
            QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(w);
            if (QAccessibleActionInterface *actions = iface ? iface->actionInterface() : nullptr) {
                a11yLog("[call] pressing %s in %s", qPrintable(name), top->metaObject()->className());
                actions->doAction(QAccessibleActionInterface::pressAction());
                return true;
            }
        }
    }
    return false;
}

} // namespace

void incomingCallChanged(QObject *)
{
    // Checked after the notification settled (it is filled, then shown or hidden).
    QMetaObject::invokeMethod(QCoreApplication::instance(), [] {
        if (incomingCallShowing())
            registerHotKeys();
        else
            unregisterHotKeys();
    }, Qt::QueuedConnection);
}

QString callKeysHint()
{
    return label("Option+Command+A answers, Option+Command+D declines.");
}

bool answerCall()
{
    if (pressQuickTag(QStringLiteral("call-answer")) || pressWidgetTag(QStringLiteral("call-answer")))
        return true;
    announce(label("No incoming call"), AnnounceWhen::Always);
    return false;
}

bool declineOrEndCall()
{
    if (pressQuickTag(QStringLiteral("call-decline")) || pressQuickTag(QStringLiteral("call-end"))
        || pressWidgetTag(QStringLiteral("call-end")))
        return true;
    announce(label("No incoming call"), AnnounceWhen::Always);
    return false;
}

} // namespace line_a11y
