// On-demand diagnostics: dumps LINE's live widget / item-view / accessibility tree.
//
// Trigger from outside the sandbox with
//   touch "$(getconf DARWIN_USER_CACHE_DIR)/jp.naver.line.mac/a11y/dump-request"
// The watchdog notices the file, deletes it and writes "widget-dump.txt" next to it.

#pragma once

namespace line_a11y {

// Checks for the dump-request file and, if present, writes the dump. Cheap when absent.
void pollDumpRequest();

// Writes the dump unconditionally. Returns false if the output file could not be opened.
bool writeWidgetDump();

} // namespace line_a11y
