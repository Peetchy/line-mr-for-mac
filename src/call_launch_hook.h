// Voice and video calls run in a separate helper app, LINE.app/Contents/Frameworks/LineCall.app
// (bundle id jp.naver.line.mac.LineCall), which LINE launches through LaunchServices
// (-[NSWorkspace openApplicationAtURL:configuration:completionHandler:]) when it starts. Launched
// that way, LineCall does not inherit LINE's environment, so it would never load the bridge.
//
// LaunchServices also drops the environment a sandboxed app passes, so QT_PLUGIN_PATH does not
// work. This hook adds `-platformpluginpath <dir>/platforms` to LineCall's arguments instead, with
// <dir> = $(getconf DARWIN_USER_CACHE_DIR)/jp.naver.line.mac.LineCall/a11y (the one place
// LineCall's sandbox lets it map plugins from); the platform shim there (src/platform_shim.mm)
// loads the bridge. `make install` installs both dylibs there. QT_PLUGIN_PATH is set as well, in
// case a future macOS passes the environment on.

#pragma once

namespace line_a11y {

// Installs the NSWorkspace hook (in LINE only; no-op elsewhere or when called again).
void installCallLaunchHook();

} // namespace line_a11y
