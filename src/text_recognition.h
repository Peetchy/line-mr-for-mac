// On-device text recognition (Vision framework) for things LINE only exposes as pixels, such as
// the date separators and message times of the chat message list.

#pragma once

#include <QtCore/QStringList>

#include <functional>

QT_BEGIN_NAMESPACE
class QImage;
class QObject;
QT_END_NAMESPACE

namespace line_a11y {

// Lines of text recognised in `image`, in reading order (top to bottom, then left to right).
// Recognises English and Thai. Runs synchronously and can take seconds the first time (model load).
QStringList recognizeTextLines(const QImage &image);

// Same, on a background queue (one recognition at a time). `done` runs on the main thread, and only
// if `context` still exists.
void recognizeTextLinesAsync(const QImage &image, QObject *context, std::function<void(const QStringList &)> done);

} // namespace line_a11y
