// Structured diagnostic logging for the LINE accessibility bridge.
//
// Log lines are appended to "<DARWIN_USER_CACHE_DIR>/jp.naver.line.mac/a11y/a11y.log",
// a directory that LINE's sandbox profile allows the app to read and write.

#pragma once

namespace line_a11y {

// printf-style; thread-safe. Each line is prefixed with a timestamp, pid and thread id.
void a11yLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// Absolute path of the "a11y" directory (the one containing "platformthemes/").
const char *a11yDirectory();

} // namespace line_a11y

#include <QtCore/QString>

namespace line_a11y {
// a11yDirectory() as a QString ending in '/', for files next to a11y.log (named as in the Windows
// bridge, whose code uses it).
inline QString bridgeDirectory()
{
    return QString::fromUtf8(a11yDirectory()) + u'/';
}

} // namespace line_a11y
