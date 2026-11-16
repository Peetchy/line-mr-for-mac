// Keys for calls (the counterpart of the Windows add-on's Alt+A / Alt+D).
//
// The Windows add-on's Alt+A / Alt+D are Control+A / Control+D in LINE's windows (A11yEventFilter):
// answer or decline a ringing call; during a call, Control+D ends it. From another application,
// Control+Shift+A / Control+Shift+D (the add-on's NVDA+Shift+Control+A / D) answer or decline: they
// are registered as system-wide hot keys (Carbon RegisterEventHotKey, allowed in the sandbox) only
// while the call rings, so they never take those keys from other applications otherwise.
// Option+Command+A / D (LINE MR 0.1) work in both places too. Control+Shift+W is registered
// while LINE is running and reports the call state and caller when known.
//
// The incoming-call notification and the call window belong to LineCall.app, the keyboard usually to
// LINE: the two bridges tell each other through distributed notifications (startCallLink()) that a
// call rings or is going on, pass the answer / decline commands on, and let the one whose
// application is in front speak (VoiceOver only speaks announcements of the application in front;
// with another application in front the text is spoken with the system's voice instead).

#pragma once

#include <QtCore/QString>

QT_BEGIN_NAMESPACE
class QObject;
QT_END_NAMESPACE

namespace line_a11y {

// An incoming-call notification appeared or went away (`window`: the Qt Quick window): registers or
// unregisters the hot keys.
void incomingCallChanged(QObject *window);

// "Control+A answers, Control+D declines. ..." in LINE's UI language.
QString callKeysHint();

// Starts listening to the other process's bridge (LINE <-> LineCall). Once, at bridge start.
void startCallLink();
// Every second (the watchdog): tells the other process what this one shows (`ringing`: an incoming
// call notification, `inCall`: a call window).
void callHeartbeat(bool ringing, bool inCall);
// The other process shows an incoming call / a call window.
bool remoteCallRinging();
bool remoteCallActive();
// An incoming call notification appeared: "Incoming call: <caller>, ..." is spoken with the keys'
// hint and kept for sayCaller().
void announceIncomingCall(const QString &text);
// Control+Shift+W: reports the caller or call state (false if there is no call).
bool sayCaller();

// Presses the tagged call button (answer / decline / end) in a Qt Quick or widget window of this
// process. Announces when there is none. Returns whether a button was pressed.
bool answerCall();
bool declineOrEndCall();

} // namespace line_a11y
