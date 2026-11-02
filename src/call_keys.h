// Keys for calls (the counterpart of the Windows add-on's Alt+A / Alt+D).
//
// The Windows add-on's Alt+A / Alt+D are Control+A / Control+D in LINE's windows (A11yEventFilter):
// answer or decline a ringing call; during a call, Control+D ends it. From another application,
// Control+Shift+A / Control+Shift+D (the add-on's NVDA+Shift+Control+A / D) answer or decline: they
// are registered as system-wide hot keys (Carbon RegisterEventHotKey, allowed in the sandbox) only
// while the call rings, so they never take those keys from other applications otherwise.
// Option+Command+A / D (LINE MR 0.1) work in both places too.

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

// Presses the tagged call button (answer / decline / end) in a Qt Quick or widget window of this
// process. Announces when there is none. Returns whether a button was pressed.
bool answerCall();
bool declineOrEndCall();

} // namespace line_a11y
