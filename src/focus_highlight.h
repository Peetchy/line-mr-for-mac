// Focus highlight for low-vision users: a coloured frame around the control that has the focus
// (ported from the Windows bridge, line-mr-for-win 0.5.5).
//
// It follows the focus the bridge reports to VoiceOver (QAccessible::Focus events, after the bridge
// dropped the ones LINE makes while the user browses a list), so it also marks the bridge's own list
// rows, menu items and Qt Quick items. The frame is a borderless, click-through NSWindow attached to
// the focused window as a child window: drawing it never makes LINE repaint, and VoiceOver does not
// see it. It hides while another application is in front.
//
// Settings: <a11y dir>/focus-highlight.ini (read again within a second when it changes):
//   [highlight]
//   enabled=true      (false: no frame)
//   color=FFD600      (RGB in hex, without '#')
//   width=4           (of the coloured band, in points, 1-12)

#pragma once

class QAccessibleEvent;
class QCoreApplication;

namespace line_a11y {

void startFocusHighlight(QCoreApplication *app);

// Called by the bridge's QAccessible update handler for every event it passes on.
void noteAccessibleEvent(QAccessibleEvent *event);

} // namespace line_a11y
