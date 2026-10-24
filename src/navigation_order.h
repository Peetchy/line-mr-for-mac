// VoiceOver reading order of a window's elements.
//
// Without AXChildrenInNavigationOrder (Qt 6.6's Cocoa plugin does not implement it) VoiceOver orders
// a window's elements by their position on screen, which interleaves side-by-side columns (the login
// window's form and its QR-code panel). The bridge adds -accessibilityChildrenInNavigationOrder to
// Qt's window class: for windows with a rule below, it returns the window's elements in that order;
// other windows keep AppKit's default.

#pragma once

#include <QtCore/qglobal.h>

QT_BEGIN_NAMESPACE
class QAccessibleInterface;
class QWidget;
QT_END_NAMESPACE

namespace line_a11y {

// Installs the method (once libqcocoa is loaded; retried until then). Logs the result.
void installNavigationOrder();

// The reading-order rank of `child` (an element of `window`; lower first, equal ranks keep their
// order), or -1 if `window` has no rule (AppKit's order is used).
int navigationRank(QWidget *window, QAccessibleInterface *child);

} // namespace line_a11y
