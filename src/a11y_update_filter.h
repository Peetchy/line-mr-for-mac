// The bridge's own QAccessible::UpdateHandler.
//
// Instead of re-installing Qt's default handler (nullptr), the bridge installs this one: it
// forwards each QAccessibleEvent straight to the platform (Cocoa) accessibility backend, except
// for events that would make VoiceOver chatter about changes the user did not cause. It also
// keeps per-type statistics that are written to a11y.log.

#pragma once

#include <QtGui/QAccessible>

QT_BEGIN_NAMESPACE
class QString;
QT_END_NAMESPACE

namespace line_a11y {

// The handler, or nullptr if the platform backend is unavailable (then Qt's default is used).
QAccessible::UpdateHandler bridgeUpdateHandler();

// User activity: keyboard / mouse input seen by the event filter, or an action performed through
// VoiceOver. Changes that happen without recent activity are LINE updating itself (new messages,
// list reordering) and are not worth interrupting the user for.
void markUserActivity();
bool userActedRecently(int withinMs = 1500);

// Focus events for which `suppress` returns true are dropped (LINE pulling focus into the chat it
// opens while the user browses the chat list; see A11yEventFilter).
void setFocusSuppressor(bool (*suppress)(QObject *object));

// Records an NSAccessibility announcement made by the bridge (for the statistics).
void noteAnnouncement(const QString &text, bool spoken);

// Writes the statistics gathered since the last call to a11y.log (no-op when nothing happened).
void logUpdateStatistics();

} // namespace line_a11y
