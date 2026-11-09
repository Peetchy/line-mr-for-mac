// Voice message and video transcription, LINE's side. LINE is sandboxed and has no speech recognition
// permission, so the work is done by LINE MR.app: LINE saves the message's own file into the a11y
// directory (the only place both can reach), the bridge describes it in transcribe-request.txt and
// opens linemr://transcribe. The URL carries nothing: a web page opening it finds no request.

#pragma once

#include <QtCore/QString>

#include <functional>

namespace line_a11y {

// The next save panel LINE shows is not shown: it answers `path` at once. `done(false)` if none was
// asked for within `timeoutMs` (LINE downloads a video before it asks), `done(true)` once one was.
void answerNextSavePanel(const QString &path, int timeoutMs, std::function<void(bool)> done);

// LINE answered with an alert instead (an expired file): no save panel is coming. No-op if none is awaited.
void stopAwaitingSavePanel();

// Calls `done(true)` once LINE has finished writing `path` (its size has stopped changing), `done(false)`
// after a minute without it.
void waitForFinishedFile(const QString &path, std::function<void(bool)> done);

// Answers LINE's next save panel with `target`, waits for the file and hands it over to LINE MR.app;
// says so if any of that fails. `onSaved` runs once the file is there. Armed before LINE is asked.
void saveThenTranscribe(const QString &target, const QString &kind, int seconds, const QString &title,
                        std::function<void()> onSaved = nullptr);

// Hands `file` over to LINE MR.app. False if it could not be asked (LINE MR.app is not installed).
bool requestTranscription(const QString &file, const QString &kind, int seconds, const QString &title);

} // namespace line_a11y
