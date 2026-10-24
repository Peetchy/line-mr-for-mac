// LINE's native (AppKit) controls outside Qt: buttons LINE puts into a window's title bar on macOS
// (the login window's menu and help buttons), which Qt's accessibility never sees.

#pragma once

#include <QtCore/QStringList>

namespace line_a11y {

// Gives unlabelled native buttons in LINE's windows an accessibility label (from their image,
// action or tooltip). Cheap when there is nothing to do; called by the watchdog.
void labelNativeButtons();

// One line per native button (label, image, action, target, frame), for widget-dump.txt.
QStringList nativeButtonReport();

} // namespace line_a11y
