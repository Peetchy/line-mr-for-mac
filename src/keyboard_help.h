// The keyboard help page (Command+Shift+K): LINE MR's keys in LINE's language.

#pragma once

#include <QtCore/qglobal.h>

QT_BEGIN_NAMESPACE
class QKeyEvent;
class QWidget;
QT_END_NAMESPACE

namespace line_a11y {

// Opens the page, or brings it to the front.
void showKeyboardHelp();
// `w` is in the page.
bool isKeyboardHelp(const QWidget *w);
// Escape / Command+W close the page; the other keys go straight to its text. True if handled.
bool handleKeyboardHelpKey(QWidget *w, QKeyEvent *key);

} // namespace line_a11y
