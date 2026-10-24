// Accessibility for LINE's Qt Quick (QML) windows: member lists, group profiles, call screens.
//
// Qt Quick exposes only items that declare Accessible properties, and LINE's QML declares almost
// none: such a window reaches VoiceOver as an empty window (a search field at most). The
// bridge gives the QQuickWindow its own interface whose children are the window's visible texts
// (QQuickText "text" property), clickable areas (MouseArea / TapHandler with a connected handler,
// named from the texts and icons inside them) and the items Qt Quick already exposes (text fields,
// Controls), in reading order. Clickable areas join the Tab chain; Space/Enter clicks them.

#pragma once

#include <QtGui/QAccessible>

QT_BEGIN_NAMESPACE
class QObject;
class QQuickWindow;
QT_END_NAMESPACE

namespace line_a11y {

bool isQuickWindow(const QObject *o);

// Bridge interfaces for Qt Quick windows and the items they present (nullptr for anything else).
QAccessibleInterface *quickAccessibleFactory(const QString &key, QObject *object);

// A Qt Quick window was shown: make its clickable areas reachable by Tab, give it a sensible
// first focus and report focus changes between its items.
void quickWindowShown(QQuickWindow *window);

// Space / Enter on a clickable area that has keyboard focus: clicks it. Returns true if handled.
bool handleQuickKey(QQuickWindow *window, int key);

// Clicks the visible Qt Quick item tagged `lineMR_<tag>` (call-answer, call-decline, call-end).
// False if there is none.
bool pressQuickTag(const QString &tag);

// Is an incoming-call notification (Answer / Decline) showing?
bool incomingCallShowing();

} // namespace line_a11y
