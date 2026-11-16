#include "call_keys.h"

#include "a11y_announce.h"
#include "a11y_log.h"
#include "accessible_quick.h"
#include "line_introspect.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QElapsedTimer>
#include <QtCore/QMetaObject>
#include <QtGui/QGuiApplication>
#include <QtWidgets/QApplication>
#include <QtWidgets/QWidget>

#include <Carbon/Carbon.h>

#import <AppKit/AppKit.h>

#include <unistd.h>

namespace line_a11y {
namespace {

constexpr OSType kHotKeySignature = 'LnMR';
enum HotKey : UInt32 { Answer = 1, Decline = 2, Who = 3 };

EventHandlerRef g_handler = nullptr;
// Control+Shift+A / D (the Windows add-on's NVDA+Shift+Control+A / D) and Option+Command+A / D (LINE
// MR 0.1's keys).
EventHotKeyRef g_answerKey = nullptr;
EventHotKeyRef g_declineKey = nullptr;
EventHotKeyRef g_answerKeyOld = nullptr;
EventHotKeyRef g_declineKeyOld = nullptr;
EventHotKeyRef g_whoKey = nullptr;

// ---- LINE <-> LineCall -----------------------------------------------------------------------------

// One notification name; its object is "<pid>\t<verb>[\t<text>]" (sandboxed applications may post
// distributed notifications without a user info dictionary only). Verbs: ringing (with the caller
// text), incall, answer, decline, say (with a text to speak).
NSString *const kCallLinkName = @"io.github.peetchy.line-mr.call";
// A state not repeated for this long is over (the heartbeat comes every second).
constexpr qint64 kRemoteStateMs = 4000;

QString g_ringText;       // this process's incoming call ("Incoming call: <caller>, ...")
QString g_remoteRingText; // the other process's
QString g_callText;
QString g_remoteCallText;
bool g_localCallActive = false;
QElapsedTimer g_lastCallSeen;
QElapsedTimer g_remoteRinging;
QElapsedTimer g_remoteInCall;
id g_linkObserver = nil;

void postToOtherProcess(const QString &verb, const QString &text = QString())
{
    @autoreleasepool {
        QString object = QString::number(getpid()) + u'\t' + verb;
        if (!text.isEmpty())
            object += u'\t' + QString(text).replace(u'\t', u' ').replace(u'\n', u' ');
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kCallLinkName
                                                                       object:object.toNSString()
                                                                     userInfo:nil
                                                           deliverImmediately:YES];
    }
}

bool otherLineProcessInFront()
{
    @autoreleasepool {
        NSString *front = [[[NSWorkspace sharedWorkspace] frontmostApplication] bundleIdentifier];
        NSString *own = [[NSBundle mainBundle] bundleIdentifier];
        return front && ![front isEqualToString:own] && [front hasPrefix:@"jp.naver.line.mac"];
    }
}

// The system's voice: for when no LINE process is in front (VoiceOver would not speak the bridge's
// announcement then). A voice of the text's language if there is one.
void speakWithSystemVoice(const QString &text)
{
    if (text.isEmpty() || !voiceOverRunning())
        return;
    @autoreleasepool {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        const char *language = nullptr;
        for (const QChar c : text) {
            const ushort u = c.unicode();
            if (u >= 0x0E00 && u <= 0x0E7F) { language = "th"; break; }
            if (u >= 0x3040 && u <= 0x30FF) { language = "ja"; break; }
            if (u >= 0x4E00 && u <= 0x9FFF && !language) language = "zh";
        }
        NSString *voice = nil;
        if (language) {
            NSString *prefix = [NSString stringWithUTF8String:language];
            for (NSString *candidate in [NSSpeechSynthesizer availableVoices]) {
                NSString *locale = [NSSpeechSynthesizer attributesForVoice:candidate][NSVoiceLocaleIdentifier];
                if ([locale hasPrefix:prefix]) {
                    voice = candidate;
                    break;
                }
            }
        }
        static NSSpeechSynthesizer *synthesizer = nil;
        [synthesizer stopSpeaking];
        synthesizer = [[NSSpeechSynthesizer alloc] initWithVoice:voice];
        const BOOL ok = [synthesizer startSpeakingString:text.toNSString()];
        a11yLog("[call] spoken with the system's voice (%s, %d)", voice ? voice.UTF8String : "default", int(ok));
#pragma clang diagnostic pop
    }
}

// Speaks `text` wherever the user is: here if this application is in front, through the other LINE
// process if that one is, else with the system's voice.
void sayEverywhere(const QString &text)
{
    if (QGuiApplication::applicationState() == Qt::ApplicationActive)
        announce(text, AnnounceWhen::Always);
    else if (otherLineProcessInFront())
        postToOtherProcess(QStringLiteral("say"), text);
    else
        speakWithSystemVoice(text);
}

bool pressLocalAnswer();
bool pressLocalDeclineOrEnd();

void linkMessage(const QString &object)
{
    const QStringList parts = object.split(u'\t');
    if (parts.size() < 2 || parts.at(0).toLongLong() == getpid())
        return;
    const QString verb = parts.at(1);
    const QString text = parts.size() > 2 ? parts.at(2) : QString();
    if (verb == QLatin1StringView("ringing")) {
        if (!g_remoteRinging.isValid() || g_remoteRinging.elapsed() > kRemoteStateMs)
            a11yLog("[call] the other process shows an incoming call");
        g_remoteRingText = text;
        g_remoteRinging.start();
    } else if (verb == QLatin1StringView("incall")) {
        g_remoteCallText = text;
        g_remoteInCall.start();
    } else if (verb == QLatin1StringView("answer")) {
        a11yLog("[call] asked to answer by the other process");
        pressLocalAnswer();
    } else if (verb == QLatin1StringView("decline")) {
        a11yLog("[call] asked to decline / end by the other process");
        if (incomingCallShowing() || !endQuickCall())
            pressLocalDeclineOrEnd();
    } else if (verb == QLatin1StringView("say")) {
        if (QGuiApplication::applicationState() == Qt::ApplicationActive)
            announce(text, AnnounceWhen::Always);
    }
}

OSStatus hotKeyPressed(EventHandlerCallRef, EventRef event, void *)
{
    EventHotKeyID id {};
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, nullptr, sizeof(id), nullptr, &id) != noErr
        || id.signature != kHotKeySignature)
        return eventNotHandledErr;
    const UInt32 which = id.id;
    // Carbon calls this from the main run loop; act after the event has been dispatched.
    QMetaObject::invokeMethod(QCoreApplication::instance(), [which] {
        a11yLog("[call] hot key %u pressed", unsigned(which));
        if (which == Answer)
            answerCall();
        else if (which == Who)
            sayCaller();
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
    const OSStatus a = RegisterEventHotKey(kVK_ANSI_A, controlKey | shiftKey, EventHotKeyID { kHotKeySignature, Answer },
                                           GetApplicationEventTarget(), 0, &g_answerKey);
    const OSStatus d = RegisterEventHotKey(kVK_ANSI_D, controlKey | shiftKey, EventHotKeyID { kHotKeySignature, Decline },
                                           GetApplicationEventTarget(), 0, &g_declineKey);
    RegisterEventHotKey(kVK_ANSI_A, cmdKey | optionKey, EventHotKeyID { kHotKeySignature, Answer },
                        GetApplicationEventTarget(), 0, &g_answerKeyOld);
    RegisterEventHotKey(kVK_ANSI_D, cmdKey | optionKey, EventHotKeyID { kHotKeySignature, Decline },
                        GetApplicationEventTarget(), 0, &g_declineKeyOld);
    a11yLog("[call] hot keys Control+Shift+A / D registered (%d, %d)", int(a), int(d));
}

void unregisterHotKeys()
{
    for (EventHotKeyRef key : { g_answerKey, g_declineKey, g_answerKeyOld, g_declineKeyOld }) {
        if (key)
            UnregisterEventHotKey(key);
    }
    if (g_answerKey || g_declineKey)
        a11yLog("[call] hot keys Control+Shift+A / D released");
    g_answerKey = g_declineKey = g_answerKeyOld = g_declineKeyOld = nullptr;
}

void registerWhoKey()
{
    if (g_whoKey)
        return;
    // LINE owns this key; registering it in both processes makes the owner unpredictable.
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"jp.naver.line.mac"])
        return;
    if (!g_handler) {
        const EventTypeSpec spec { kEventClassKeyboard, kEventHotKeyPressed };
        InstallApplicationEventHandler(&hotKeyPressed, 1, &spec, nullptr, &g_handler);
    }
    const OSStatus status = RegisterEventHotKey(kVK_ANSI_W, controlKey | shiftKey,
                                                EventHotKeyID { kHotKeySignature, Who },
                                                GetApplicationEventTarget(), 0, &g_whoKey);
    a11yLog("[call] hot key Control+Shift+W registered (%d)", int(status));
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

bool pressLocalAnswer()
{
    return pressQuickTag(QStringLiteral("call-answer")) || pressWidgetTag(QStringLiteral("call-answer"));
}

bool pressLocalDeclineOrEnd()
{
    return pressQuickTag(QStringLiteral("call-decline")) || pressQuickTag(QStringLiteral("call-end"))
        || pressWidgetTag(QStringLiteral("call-end"));
}

} // namespace

void startCallLink()
{
    if (g_linkObserver)
        return;
    @autoreleasepool {
        NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
        g_linkObserver = [center addObserverForName:kCallLinkName
                                             object:nil
                                              queue:[NSOperationQueue mainQueue]
                                         usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[NSString class]])
                linkMessage(QString::fromNSString((NSString *)note.object));
        }];
        // (Delivered also while this application is in the background.)
        [center setSuspended:NO];
    }
    a11yLog("[call] link to the other LINE process started");
    registerWhoKey();
}

void callHeartbeat(bool ringing, bool inCall)
{
    g_localCallActive = inCall;
    if (ringing || inCall)
        g_lastCallSeen.start();
    else if (g_lastCallSeen.isValid() && g_lastCallSeen.elapsed() > kRemoteStateMs)
        g_callText.clear();
    if (ringing)
        postToOtherProcess(QStringLiteral("ringing"), g_ringText);
    else if (inCall)
        postToOtherProcess(QStringLiteral("incall"), g_callText);
    if (!ringing && !g_ringText.isEmpty() && !incomingCallShowing())
        g_ringText.clear();
}

bool remoteCallRinging()
{
    return g_remoteRinging.isValid() && g_remoteRinging.elapsed() < kRemoteStateMs;
}

bool remoteCallActive()
{
    return g_remoteInCall.isValid() && g_remoteInCall.elapsed() < kRemoteStateMs;
}

void announceIncomingCall(const QString &text)
{
    g_ringText = text;
    g_callText = text;
    postToOtherProcess(QStringLiteral("ringing"), text);
    sayEverywhere(text + QStringLiteral(". ") + callKeysHint());
}

bool sayCaller()
{
    QString text = !g_ringText.isEmpty() && incomingCallShowing() ? g_ringText
        : remoteCallRinging() ? g_remoteRingText
        : g_localCallActive ? g_callText : remoteCallActive() ? g_remoteCallText : QString();
    if (text.isEmpty()) {
        const bool active = g_localCallActive || remoteCallActive();
        text = label(active ? "Call in progress; caller unknown" : "No incoming call or active call");
        speakWithSystemVoice(text);
        return active;
    }
    a11yLog("[call] saying who is calling");
    speakWithSystemVoice(text);
    return true;
}

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
    // In LINE (the notification is shown without taking the keyboard) and from other applications.
    return label("Control+A answers, Control+D declines. From another application: Control+Shift+A or Control+Shift+D. Control+Shift+W says who is calling.");
}

bool answerCall()
{
    if (pressLocalAnswer())
        return true;
    // The notification is LineCall's; the key came to LINE.
    if (remoteCallRinging()) {
        a11yLog("[call] answer: passed on to the other process");
        postToOtherProcess(QStringLiteral("answer"));
        return true;
    }
    sayEverywhere(label("No incoming call"));
    return false;
}

bool declineOrEndCall()
{
    if (pressLocalDeclineOrEnd())
        return true;
    if (remoteCallRinging() || remoteCallActive()) {
        a11yLog("[call] decline / end: passed on to the other process");
        postToOtherProcess(QStringLiteral("decline"));
        return true;
    }
    sayEverywhere(label("No incoming call"));
    return false;
}

} // namespace line_a11y
