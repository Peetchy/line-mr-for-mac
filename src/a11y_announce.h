// Spoken announcements (NSAccessibilityAnnouncementRequestedNotification), which VoiceOver speaks
// without moving its cursor.

#pragma once

#include <QtCore/QString>

namespace line_a11y {

enum class AnnounceWhen {
    UserAction, // only right after the user's own input (LINE updates itself constantly)
    LineActive, // while one of LINE's windows is active (new messages in the open chat)
    Always,     // even while another application is in front (incoming calls)
};

// Asks VoiceOver to speak `text` (no-op when VoiceOver is off or text is empty). Identical texts
// within 3 s are dropped.
void announce(const QString &text, AnnounceWhen when = AnnounceWhen::UserAction);

// Same as announce(text, AnnounceWhen::UserAction).
void postAnnouncement(const QString &text);

// Is VoiceOver running?
bool voiceOverRunning();

} // namespace line_a11y
