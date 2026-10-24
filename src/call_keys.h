// Keys for calls (the counterpart of the Windows add-on's Alt+A / Alt+D).
//
// While an incoming-call notification shows, Option+Command+A answers and Option+Command+D declines,
// also while another application is in front: the keys are registered as system-wide hot keys
// (Carbon RegisterEventHotKey, allowed in the sandbox) only while the call rings, so they never
// take those keys from other applications otherwise. During a call, Option+Command+D in LINE's
// windows ends it (A11yEventFilter).

#pragma once

#include <QtCore/QString>

QT_BEGIN_NAMESPACE
class QObject;
QT_END_NAMESPACE

namespace line_a11y {

// An incoming-call notification appeared or went away (`window`: the Qt Quick window): registers or
// unregisters the hot keys.
void incomingCallChanged(QObject *window);

// "Option+Command+A answers, Option+Command+D declines." in LINE's UI language.
QString callKeysHint();

// Presses the tagged call button (answer / decline / end) in a Qt Quick or widget window of this
// process. Announces when there is none. Returns whether a button was pressed.
bool answerCall();
bool declineOrEndCall();

} // namespace line_a11y
