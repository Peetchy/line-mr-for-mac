# Line MR for Mac (Line Mai Roo)

A VoiceOver accessibility bridge for **LINE for macOS** (`/Applications/LINE.app`, 26.5.0.3975, Qt 6.6.3).

ทำให้ผู้ใช้ VoiceOver ใช้ LINE บน Mac ได้ เช่น อ่านปุ่มที่ไม่มีชื่อ รายการแชท ข้อความในห้องแชท (ทั้งข้อความ ไฟล์ รูป และวันที่) และหน้าต่างการโทร พร้อมลดการแจ้งเตือนที่ VoiceOver พูดซ้ำ ๆ โดยไม่ต้องแก้ไฟล์ใน `LINE.app` และไม่ต้องปิด SIP

## What it does

- **Buttons and controls:** names icon-only buttons (sidebar, chat header, call button, ad banner), exposes checkboxes and radio tabs, and lets VO+Space press LINE's custom buttons.
- **Text fields:** labels the login, search and message input fields.
- **Chat list and friend list:** reads every row (name, last message, time, unread count).
- **Messages:** reads the sender, the text, files (name, size, validity), photos, date separators and read receipts. Vision OCR (Thai and English) is the fallback for rows LINE only draws.
- **Less noise:** drops background change notifications that the user did not cause and stops hover tooltips from triggering repeated announcements.
- **Calls:** runs inside `LineCall.app` too, so the call window's buttons (end call, microphone, speaker, video) and text can be read.

## How it works

LINE is sandboxed but allows library loading (`disable-library-validation`). Qt looks up a "cocoa" platform-theme plugin on `QT_PLUGIN_PATH`. The bridge is that plugin, installed in the one directory LINE's sandbox may map code from:

```
$(getconf DARWIN_USER_CACHE_DIR)/jp.naver.line.mac/a11y/platformthemes/libline_a11y.dylib
```

The plugin returns `nullptr`, so Qt falls back to its built-in theme. Meanwhile the bridge:

- removes LINE's no-op `QAccessible` update handler;
- installs accessibility factories for LINE's `Lc*` widgets;
- reads widget text and message data through reverse-engineered offsets, which are gated by version and instruction-signature checks.

[`CLAUDE.md`](CLAUDE.md) documents every verified offset and finding.

## Requirements

- macOS 14 or later on Apple silicon (arm64)
- LINE 26.5.0 (3975); on other versions the offset-based features switch themselves off
- Xcode Command Line Tools (clang, swiftc)

## Build and run

```sh
make                          # build/libline_a11y.dylib, build/libqcocoa_a11y.dylib, build/ax_inspect
make install                  # install and ad-hoc sign the plugin (LINE and LineCall)
tools/line-a11y-launcher.sh --restart   # quit LINE, start it with the bridge (and swap in a bridged LineCall)
make test                     # automated accessibility-tree checks (restarts LINE)
```

Logs: `$(getconf DARWIN_USER_CACHE_DIR)/jp.naver.line.mac/a11y/a11y.log`. The call window logs to `jp.naver.line.mac.LineCall/a11y/`.

## Tools

- `build/ax_inspect [--pid PID] [--depth N] [--press TITLE [--nth N] [--prefix]]` prints LINE's live AX tree and can press elements.
- `touch "$(getconf DARWIN_USER_CACHE_DIR)/jp.naver.line.mac/a11y/dump-request"` makes the bridge write `widget-dump.txt` (widget tree, models, accessible tree).

## Layout

| Path | Purpose |
|---|---|
| `src/plugin_main.mm` | Plugin entry points and bootstrap |
| `src/accessible_widgets.*` | Buttons, texts, inputs, menus |
| `src/accessible_list.*` | Chat, friend and message list rows |
| `src/line_introspect.*` | Offsets, safe memory reads, icon names |
| `src/a11y_update_filter.*`, `src/a11y_event_filter.mm` | Event filtering, tooltip suppression |
| `src/text_recognition.*` | Vision OCR fallback |
| `src/call_launch_hook.*`, `src/platform_shim.mm` | Getting the bridge into LineCall.app |
| `tools/`, `tests/` | Launcher, AX inspector, verification script |

## Status and limits

- Verified only against LINE 26.5.0 (3975) on arm64.
- Stickers, videos, locations and contacts are only recognised once they have been seen on screen. Group sender names and the call window's labels need more testing.
- This is an unofficial, independent project. It is not affiliated with or endorsed by LY Corporation / LINE.
