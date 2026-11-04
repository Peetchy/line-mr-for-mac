# Line MR for Mac (Line Mai Roo)

A VoiceOver accessibility bridge for **LINE for macOS** (`/Applications/LINE.app`, 26.5.0.3975, Qt 6.6.3).

ทำให้ผู้ใช้ VoiceOver ใช้ LINE บน Mac ได้ เช่น อ่านปุ่มที่ไม่มีชื่อ รายการแชท ข้อความในห้องแชท (ทั้งข้อความ ไฟล์ รูป และวันที่) และหน้าต่างการโทร พร้อมลดการแจ้งเตือนที่ VoiceOver พูดซ้ำ ๆ โดยไม่ต้องแก้ไฟล์ใน `LINE.app` และไม่ต้องปิด SIP

## การติดตั้งสำหรับผู้ใช้ / Installation

**เวอร์ชันล่าสุด: [v0.2.1](https://github.com/Peetchy/line-mr-for-mac/releases/tag/v0.2.1)**

| ไฟล์ | ลิงก์ดาวน์โหลด |
|---|---|
| **DMG (แนะนำ)**: ตัวติดตั้ง ตัวโปรแกรม และวิธีติดตั้ง | [LINE-MR-0.2.1.dmg](https://github.com/Peetchy/line-mr-for-mac/releases/download/v0.2.1/LINE-MR-0.2.1.dmg) |
| **PKG**: ตัวติดตั้งอย่างเดียว | [LINE-MR-0.2.1.pkg](https://github.com/Peetchy/line-mr-for-mac/releases/download/v0.2.1/LINE-MR-0.2.1.pkg) |
| เวอร์ชันทั้งหมด | [Releases](https://github.com/Peetchy/line-mr-for-mac/releases) |

> English summary: download the `.dmg` above, allow it in **System Settings > Privacy & Security > Open Anyway** (it is not signed with an Apple Developer ID), install with `Install LINE MR.pkg` or drag `LINE MR` to Applications, then always open LINE through **LINE MR**. Details in Thai below; an English copy is in the disk image's Read Me.

### สิ่งที่ต้องมี

- Mac ชิป Apple Silicon (M1 ขึ้นไป) และ macOS 14 ขึ้นไป
  ตรวจได้ที่เมนู Apple > About This Mac ถ้าบรรทัด Chip ขึ้นว่า Apple M1, M2, M3 หรือใหม่กว่า ใช้ได้ (ถ้าเป็น Intel ยังใช้ไม่ได้)
- LINE จาก Mac App Store ที่ติดตั้งไว้ที่ Applications (ทดสอบกับ LINE 26.5.0 (3975) ถ้าเป็นเวอร์ชันอื่น LINE MR จะแจ้งเตือนครั้งแรก และบางส่วนอาจอ่านไม่ได้)

### ขั้นที่ 1: ดาวน์โหลด

1. กดลิงก์ [LINE-MR-0.2.1.dmg](https://github.com/Peetchy/line-mr-for-mac/releases/download/v0.2.1/LINE-MR-0.2.1.dmg) ในตารางด้านบน หรือเข้าหน้า [Releases](https://github.com/Peetchy/line-mr-for-mac/releases) แล้วเลือกไฟล์ `.dmg` ในหัวข้อ Assets ของเวอร์ชันล่าสุด
2. ถ้า Safari ถามว่าจะอนุญาตให้ดาวน์โหลดจาก github.com ไหม ให้กด **Allow**
3. ไฟล์จะอยู่ในโฟลเดอร์ **Downloads** (เปิดด้วย Option+Command+L ใน Finder)
4. (ไม่บังคับ) ตรวจว่าไฟล์ไม่เสียหาย ด้วยคำสั่งใน Terminal แล้วเทียบกับไฟล์ `SHA256SUMS.txt` ในหน้า Release:
   ```sh
   shasum -a 256 ~/Downloads/LINE-MR-*.dmg
   ```

ในไฟล์ DMG มี:

| ไฟล์ | ใช้ทำอะไร |
|---|---|
| `Install LINE MR.pkg` | ตัวติดตั้ง กด Continue ไปเรื่อย ๆ (แนะนำสำหรับผู้ใช้ VoiceOver) |
| `LINE MR.app` | ตัวโปรแกรม ใช้ลากไปวางที่ Applications แทนการใช้ตัวติดตั้งได้ |
| `Applications` | ทางลัดไปโฟลเดอร์ Applications สำหรับลากไปวาง |
| `อ่านก่อนติดตั้ง - Read Me.txt` | วิธีติดตั้งแบบย่อ ภาษาไทยและอังกฤษ |

### ขั้นที่ 2: อนุญาตให้ macOS เปิดแอปจากภายนอก (Gatekeeper)

Gatekeeper คือระบบของ macOS ที่อนุญาตให้เปิดเฉพาะแอปจาก App Store หรือแอปที่เซ็นด้วยบัญชี Apple Developer LINE MR ไม่ได้เซ็นด้วยบัญชีนี้ เมื่อดาวน์โหลดมา macOS จะบล็อกการเปิดครั้งแรกและแจ้งว่า *"Apple could not verify "LINE MR" is free of malware…"* หรือ *"…cannot be opened because the developer cannot be verified"*

เลือกวิธีใดวิธีหนึ่งด้านล่าง วิธี ก. ปลอดภัยที่สุดเพราะอนุญาตเฉพาะ LINE MR ส่วนวิธี ค. คือการปิด Gatekeeper ทั้งเครื่องเพื่อให้ติดตั้งแอปภายนอกได้ทุกตัว

**วิธี ก. อนุญาตเฉพาะโปรแกรมนี้ (แนะนำ)**

1. เปิด `Install LINE MR.pkg` หรือ `LINE MR` เมื่อมีกล่องข้อความแจ้งว่าเปิดไม่ได้ ให้กด **Done** (ห้ามกด Move to Trash)
2. เปิด **System Settings > Privacy & Security** หรือเปิดหน้านี้โดยตรงด้วยคำสั่งใน Terminal:
   ```sh
   open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
   ```
3. เลื่อนลงไปที่หัวข้อ **Security** จะมีข้อความว่า "LINE MR" ถูกบล็อก ให้กด **Open Anyway**
   (ผู้ใช้ VoiceOver: กด VO+U เลือก Buttons แล้วหา "Open Anyway")
4. ใส่รหัสผ่านหรือใช้ Touch ID แล้วเปิดโปรแกรมอีกครั้ง กด **Open Anyway** ในกล่องข้อความ
5. ถ้าใช้ทั้งตัวติดตั้งและตัวโปรแกรม อาจต้องทำขั้นนี้กับแต่ละไฟล์ ทำครั้งเดียว ครั้งต่อไปเปิดได้ตามปกติ

**วิธี ข. ปลดล็อกไฟล์ด้วย Terminal**

เปิด Terminal (Applications > Utilities > Terminal) แล้วพิมพ์คำสั่งก่อนเปิด DMG (แก้ชื่อไฟล์และตำแหน่งให้ตรง):

```sh
xattr -dr com.apple.quarantine ~/Downloads/LINE-MR-*.dmg
```

หรือถ้าติดตั้งแล้วแต่ยังเปิดไม่ได้:

```sh
xattr -dr com.apple.quarantine "/Applications/LINE MR.app"
```

**วิธี ค. ปิด Gatekeeper ทั้งเครื่อง (ไม่แนะนำ)**

วิธีนี้ทำให้เปิดโปรแกรมจากที่ใดก็ได้โดยไม่มีการตรวจสอบ ควรเปิด Gatekeeper กลับหลังติดตั้งเสร็จ

1. ใน Terminal พิมพ์ แล้วใส่รหัสผ่านของเครื่อง:
   ```sh
   sudo spctl --master-disable
   ```
2. ตั้งแต่ macOS 15 คำสั่งนี้ยังไม่ปิดทันที ให้เปิด **System Settings > Privacy & Security** เลื่อนไปที่ **Allow applications from** แล้วเลือก **Anywhere** (ตัวเลือกนี้จะปรากฏหลังรันคำสั่งในข้อ 1) ใส่รหัสผ่านเพื่อยืนยัน
3. ตรวจสถานะด้วย `spctl --status` ถ้าปิดแล้วจะแสดง `assessments disabled`
4. ติดตั้งและเปิด LINE MR ครั้งแรกให้เรียบร้อย
5. **เปิด Gatekeeper กลับ:**
   ```sh
   sudo spctl --master-enable
   ```
   หรือเลือก **App Store & Known Developers** ที่ Allow applications from โปรแกรม LINE MR ที่อนุญาตไปแล้วยังเปิดได้ตามปกติ

### ขั้นที่ 3: ติดตั้ง

**แบบที่ 1: ใช้ตัวติดตั้ง `.pkg` (แนะนำ)**

1. ดับเบิลคลิกไฟล์ `LINE-MR-<เวอร์ชัน>.dmg` เพื่อเปิด
2. เปิด `Install LINE MR.pkg` (ถ้าถูกบล็อก ทำตามขั้นที่ 2)
3. หน้า Introduction กด **Continue**
4. หน้า Installation Type กด **Install** แล้วใส่รหัสผ่านของเครื่อง
5. เมื่อขึ้นว่า "The installation was successful" กด **Close** (ถ้าถามว่าจะย้ายตัวติดตั้งไปถังขยะไหม ตอบได้ตามสะดวก)

ตัวติดตั้งจะวาง `LINE MR.app` ไว้ที่ `/Applications` เสมอ ไม่แก้ไขตัวโปรแกรม LINE

**แบบที่ 2: ลากไปวาง**

1. เปิดไฟล์ DMG
2. ลาก `LINE MR` ไปวางบน `Applications`
   ผู้ใช้ VoiceOver: เลือก `LINE MR` กด Command+C แล้วกด Shift+Command+A เพื่อเปิดโฟลเดอร์ Applications จากนั้นกด Command+V
3. Eject DMG (เลือกไอคอน DMG แล้วกด Command+E)

### ขั้นที่ 4: เริ่มใช้งาน

1. เปิด **Applications > LINE MR** (หรือกด Command+Space พิมพ์ `LINE MR` แล้วกด Return)
2. LINE MR จะติดตั้งส่วนเสริมให้ เปิด LINE พร้อมส่วนเสริม VoiceOver แล้วปิดตัวเองโดยไม่ค้างใน Dock
   - ถ้า LINE เปิดอยู่แล้วแต่ยังไม่มีส่วนเสริม จะมีกล่องข้อความถาม ให้กด **Restart LINE** (เปิด LINE ใหม่)
   - ถ้า LINE เปิดพร้อมส่วนเสริมอยู่แล้ว LINE MR จะเรียกหน้าต่าง LINE ขึ้นมาเฉย ๆ
3. **ต่อจากนี้ให้เปิด LINE ผ่าน LINE MR ทุกครั้ง** ถ้าเปิด LINE จาก Dock หรือ Launchpad โดยตรง ส่วนเสริมจะไม่ทำงาน
   - แนะนำให้เอา LINE ออกจาก Dock แล้ววาง LINE MR แทน (ลาก LINE MR จาก Applications ไปที่ Dock)
   - ถ้าต้องการให้ LINE เปิดเองตอนเข้าเครื่อง: ปิดการเปิด LINE อัตโนมัติตอนเข้าเครื่อง (ถ้า LINE อยู่ใน Login Items ให้เอาออก) แล้วเพิ่ม LINE MR ใน **System Settings > General > Login Items & Extensions > Open at Login**

### อัปเดตและถอนการติดตั้ง

- **ตรวจหาเวอร์ชันใหม่อัตโนมัติ:** ทุกครั้งที่เปิด LINE MR (ไม่เกินวันละครั้ง) หลังจากเปิด LINE แล้ว LINE MR จะตรวจหน้า [Releases](https://github.com/Peetchy/line-mr-for-mac/releases) ถ้ามีเวอร์ชันใหม่กว่าจะมีกล่องข้อความ "มี LINE MR เวอร์ชันใหม่" ให้เลือก
  - **ดาวน์โหลด**: เปิดเบราว์เซอร์และดาวน์โหลดไฟล์ DMG เวอร์ชันใหม่ลงโฟลเดอร์ Downloads
  - **ไว้ทีหลัง**: ถามใหม่ในวันถัดไป
  - **ข้ามเวอร์ชันนี้**: ไม่ถามถึงเวอร์ชันนี้อีก จะถามอีกครั้งเมื่อมีเวอร์ชันที่ใหม่กว่า
  
  ถ้าไม่มีอินเทอร์เน็ตหรือเชื่อมต่อ GitHub ไม่ได้ LINE MR จะข้ามการตรวจไปเฉย ๆ ไม่มีผลกับการเปิด LINE
- **อัปเดต LINE MR:** ติดตั้งเวอร์ชันใหม่ทับได้เลยทั้งสองแบบ (ครั้งแรกของแต่ละเวอร์ชันอาจต้องกด Open Anyway ตามขั้นที่ 2 อีกครั้ง) จากนั้นปิด LINE แล้วเปิดผ่าน LINE MR ใหม่
- **เมื่อ LINE อัปเดต:** LINE MR จะแจ้งเตือนถ้าเป็นเวอร์ชันที่ยังไม่ได้ทดสอบ ใช้ต่อได้ แต่บางส่วนอาจอ่านไม่ได้จนกว่าจะมี LINE MR เวอร์ชันใหม่
- **ถอนการติดตั้ง:**
  1. ลบ `/Applications/LINE MR.app` (ย้ายไปถังขยะ)
  2. ลบส่วนเสริมที่ติดตั้งไว้ ด้วยคำสั่งใน Terminal:
     ```sh
     rm -rf "$(getconf DARWIN_USER_CACHE_DIR)jp.naver.line.mac/a11y" "$(getconf DARWIN_USER_CACHE_DIR)jp.naver.line.mac.LineCall/a11y"
     pkgutil --forget io.github.peetchy.line-mr   # ถ้าเคยติดตั้งด้วย .pkg (อาจต้องใช้ sudo)
     ```
  3. ปิดแล้วเปิด LINE ใหม่

### แก้ปัญหา

| อาการ | วิธีแก้ |
|---|---|
| "LINE MR" is damaged / can't be opened | ทำตามขั้นที่ 2 วิธี ข. แล้วเปิดใหม่ |
| VoiceOver ยังอ่านปุ่มใน LINE ไม่ได้ | ตรวจว่าเปิด LINE ผ่าน LINE MR ปิด LINE ด้วย Command+Q แล้วเปิด LINE MR อีกครั้ง |
| "VoiceOver support did not start" | ปิด LINE แล้วเปิด LINE MR ใหม่ ถ้ายังไม่ได้ ส่งไฟล์บันทึกให้ผู้พัฒนา |
| ปุ่มในหน้าต่างการโทรอ่านไม่ได้ | ต้องเปิด LINE ผ่าน LINE MR ตั้งแต่แรก (LINE MR เปิดตัวจัดการการโทรของ LINE ใหม่ให้มีส่วนเสริม) |

ไฟล์บันทึก: `~/Library/Logs/LINE MR.log` (ตัวเปิด) และ `$(getconf DARWIN_USER_CACHE_DIR)jp.naver.line.mac/a11y/a11y.log` (ส่วนเสริมใน LINE)

## What it does

- **Buttons and controls:** names icon-only buttons (sidebar, chat header, call button, ad banner), exposes checkboxes and radio tabs, and lets VO+Space press LINE's custom buttons.
- **Text fields:** labels the login, search and message input fields.
- **Chat list and friend list:** reads every row (name, last message, time, unread count).
- **Messages:** reads the sender, the text, files (name, size, validity), photos, date separators and read receipts. Vision OCR (Thai and English) is the fallback for rows LINE only draws.
- **Less noise:** drops background change notifications that the user did not cause and stops hover tooltips from triggering repeated announcements.
- **Calls:** runs inside `LineCall.app` too, so the call window's buttons (end call, microphone, speaker, video) and text can be read.
- **Keyboard (like the Windows version):** Tab reaches every button, checkbox and link in reading order while VoiceOver runs; Space or Return presses. The chat and friend lists can be browsed with the arrows without opening each chat. In a chat, Return or Space on a message opens "See more" (long messages, then read line by line), its link, a voice message, photo, video or file; VO+Shift+M opens the message's menu.
- **Other windows:** Settings, profiles and member lists (Qt Quick pages), share and create-chat / create-group pickers, a chat's Photos & videos / Links / Files, Notes, chat search results, the sticker window, the photo / video viewer (Play / Pause, seeking) and LINE's context menus are readable and usable from the keyboard.
- **Reactions:** messages say which reactions they have; the message menu's "React" opens LINE's reaction picker.
- **Languages:** labels the bridge adds follow LINE's language (English, Thai, Japanese, Simplified or Traditional Chinese).

## How it works

LINE is sandboxed but allows library loading (`disable-library-validation`). Qt looks up a "cocoa" platform-theme plugin on `QT_PLUGIN_PATH`. The bridge is that plugin, installed in the one directory LINE's sandbox may map code from:

```
$(getconf DARWIN_USER_CACHE_DIR)/jp.naver.line.mac/a11y/platformthemes/libline_a11y.dylib
```

The plugin returns `nullptr`, so Qt falls back to its built-in theme. Meanwhile the bridge:

- removes LINE's no-op `QAccessible` update handler;
- installs accessibility factories for LINE's `Lc*` widgets;
- reads widget text and message data through reverse-engineered offsets, which are gated by version and instruction-signature checks.

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

Distribution (ad-hoc signed, Apple silicon):

```sh
make app      # build/LINE MR.app: Swift launcher (packaging/LineMR.swift) with the bridge in Contents/Resources
make pkg      # build/LINE-MR-<version>.pkg: installs LINE MR.app into /Applications (Thai/English installer pages)
make dmg      # build/LINE-MR-<version>.dmg: LINE MR.app, the .pkg, an Applications link and the Read Me
make dist     # both
```

The version is `VERSION` in the `Makefile`. Without LINE installed, build against the official Qt 6.6.3: `make dist QT_FW=<Qt>/6.6.3/macos/lib` (same imports as LINE's own Qt; verified by loading it into LINE).

**Releases:** `.github/workflows/release.yml` builds on a GitHub macOS (Apple silicon) runner with Qt 6.6.3 from `install-qt-action`. Push a tag to publish a release with the `.dmg`, the `.pkg` and `SHA256SUMS.txt`:

```sh
# bump VERSION in the Makefile and the download links in this README, commit, then:
git tag v0.1.2 && git push origin v0.1.2
```

Running the workflow by hand (Actions > Release > Run workflow) builds without releasing; the files are attached to the run. To rebuild an existing release's files (same version), move its tag: `git tag -f v0.1.1 && git push -f origin v0.1.1`.

**Update check:** `LINE MR.app` asks `https://api.github.com/repos/Peetchy/line-mr-for-mac/releases/latest` (no login, at most once a day, 8 s timeout, after LINE is open) and compares its `tag_name` with the app's `CFBundleShortVersionString`. A newer release gets an alert: Download (opens the release's `.dmg`), Later, Skip This Version. Drafts and pre-releases are never offered. Settings: `defaults read io.github.peetchy.line-mr` (`lastUpdateCheck`, `skippedVersion`); delete `lastUpdateCheck` to check again now. `LINE MR.app` opens LINE and LineCall through LaunchServices with `QT_PLUGIN_PATH` (as the launcher script does), so both keep their own microphone/camera permissions.

Logs: `$(getconf DARWIN_USER_CACHE_DIR)/jp.naver.line.mac/a11y/a11y.log`. The call window logs to `jp.naver.line.mac.LineCall/a11y/`.

## Keyboard commands / คำสั่งแป้นพิมพ์

The NVDA add-on's Alt keys are Control keys on the Mac (Option+Command, the keys of LINE MR 0.1, still work). Control+Option is VoiceOver's own modifier and is not used.

คำสั่ง Alt ของ NVDA บน Windows ใช้ Control แทนบน Mac (Option+Command ของ LINE MR 0.1 ยังใช้ได้)

| Command | Action | การทำงาน |
|---|---|---|
| Control+1 / 2 / 3 | Friends / Chats / Add friends tab | แท็บเพื่อน / แชท / เพิ่มเพื่อน |
| Control+C | Chat list (switches to the Chats tab first) | ไปที่รายการแชท (สลับไปแท็บแชทก่อนถ้าจำเป็น) |
| Control+L | Chat list or friend list | ไปที่รายการแชทหรือรายชื่อเพื่อน |
| Control+F | Search field of the list | ไปที่ช่องค้นหาของรายการ |
| Control+M | Messages of the open chat (newest first) | ไปที่ข้อความของแชทที่เปิดอยู่ (เริ่มที่ข้อความล่าสุด) |
| Control+I | Message input | ไปที่ช่องพิมพ์ข้อความ |
| Control+Shift+1 … 9 | Read a recent message (1 = newest) | อ่านข้อความล่าสุด (1 = ใหม่สุด) |
| Control+A / Control+D in LINE | Answer / decline an incoming call; during a call Control+D ends it. Without a call they do what they normally do in text fields (start of line / delete) | รับสาย / ปฏิเสธสาย; ระหว่างคุยกด Control+D วางสาย (ถ้าไม่มีสาย ปุ่มทำงานตามปกติในช่องพิมพ์) |
| Control+Shift+A / Control+Shift+D from any app | Answer / decline while a LINE call rings | รับสาย / ปฏิเสธสายจากโปรแกรมอื่นขณะมีสายเรียกเข้า |
| Command+S in the photo viewer | Save the photo or video | บันทึกรูปหรือวิดีโอในหน้าดูรูป |

In lists: chat and friend list — arrows, Page Up/Down, Home/End move without opening a chat, Return (or VO+Space) opens it and, in the chat list, moves to its message input once it has opened. Messages — Up/Down one message (Up on the oldest loads older ones), Page Up/Down about a screen, Home or ⌘↑ the oldest loaded message, End or ⌘↓ the newest; Return or Space opens "See more", a link, a voice message, photo, video or file, or plays a sound sticker again. Tab back into a chat returns to the message read last.

Menus (VO+Shift+M, or Shift+F10 / the PC menu key): on a message, a chat or friend list row, a photo / link / file of a chat's Photos & videos, Links or Files window, and a post in Notes. Arrows move, Right opens a sub-menu and Left or Escape goes back, Return or Space chooses, Escape closes and returns to the row. The message menu adds "React" (LINE's reaction picker: Left/Right, Return gives the reaction, Escape closes; "Remove reaction" once you reacted) and, in groups, "Show <name>'s profile".

Stickers: the package strip reads the package names; the first Return or Space on a sticker selects it and plays LINE's preview with its sound, the second sends it. Chat search (the magnifier in the chat header): Return searches, Up/Down go to older / newer matches, and the result is read ("Result 3 of 7" and the message).

ในรายการ: รายการแชทและเพื่อน — ลูกศร Page Up/Down Home/End เลื่อนโดยไม่เปิดแชท, Return (หรือ VO+Space) เปิดแชท และในรายการแชทจะย้ายไปช่องพิมพ์ข้อความให้อัตโนมัติเมื่อแชทเปิดเสร็จ. ข้อความ — ลูกศรขึ้นลงทีละข้อความ (ขึ้นที่ข้อความเก่าสุดจะโหลดข้อความเก่ากว่า), Home หรือ ⌘↑ ไปข้อความเก่าสุดที่โหลดแล้ว, End หรือ ⌘↓ ไปข้อความล่าสุด, Return หรือ Space เปิด "ดูเพิ่มเติม" ลิงก์ ข้อความเสียง รูป วิดีโอ ไฟล์ หรือเล่นเสียงสติกเกอร์อีกครั้ง. เมนู (VO+Shift+M หรือ Shift+F10): ใช้ได้กับข้อความ แถวในรายการแชท/เพื่อน รูป/ลิงก์/ไฟล์ และโพสต์ในโน้ต; ลูกศรขวาเปิดเมนูย่อย ลูกศรซ้ายหรือ Escape ย้อนกลับ; เมนูข้อความมี "แสดงความรู้สึก" และในกลุ่มมี "แสดงโปรไฟล์ <ชื่อ>". สติกเกอร์: กดครั้งแรกเลือกและเล่นตัวอย่างพร้อมเสียง กดอีกครั้งเพื่อส่ง. ค้นหาในแชท: Return ค้นหา, ลูกศรขึ้นลงไปผลลัพธ์ก่อนหน้า/ถัดไป แล้วอ่านผลลัพธ์ให้ฟัง

### Focus highlight / กรอบโฟกัส

For low-vision users, a yellow frame with a black outline marks the control that has the keyboard focus (also chats, messages and menu items); it hides while another app is in front. Change it in `$(getconf DARWIN_USER_CACHE_DIR)/jp.naver.line.mac/a11y/focus-highlight.ini` (LINE applies the change within a second):

```ini
[highlight]
enabled=true
color=FFD600
width=4
```

`enabled=false` turns it off; `color` is RGB in hex without `#`; `width` is 1-12 points.

## Tools

- `build/ax_inspect [--pid PID] [--depth N] [--press TITLE [--nth N] [--prefix] [--action AXShowMenu|AXFocus] [--set-value TEXT]] [--focused]` prints LINE's live AX tree, presses elements (or performs VO+Shift+M's AXShowMenu, focuses them, sets their value) and prints the focused element.
- `touch "$(getconf DARWIN_USER_CACHE_DIR)/jp.naver.line.mac/a11y/dump-request"` makes the bridge write `widget-dump.txt` (widget tree, models, accessible tree).

## Layout

| Path | Purpose |
|---|---|
| `src/plugin_main.mm` | Plugin entry points and bootstrap |
| `src/accessible_widgets.*` | Buttons, texts, inputs, menus |
| `src/accessible_list.*` | Chat, friend and message list rows |
| `src/line_introspect.*` | Offsets, safe memory reads, icon names, labels in five languages, links |
| `src/text_capture.*` | Records what LINE paints (where to click, painted labels, LINE's icons) |
| `src/accessible_quick.*` | Qt Quick windows (profiles, member lists, incoming calls) |
| `src/full_text_view.*` | Long messages read line by line |
| `src/a11y_announce.*`, `src/call_keys.*` | VoiceOver announcements, call keys |
| `src/a11y_update_filter.*`, `src/a11y_event_filter.mm` | Event filtering, tooltip suppression |
| `src/text_recognition.*` | Vision OCR fallback |
| `src/call_launch_hook.*`, `src/platform_shim.mm` | Getting the bridge into LineCall.app |
| `tools/`, `tests/` | Launcher, AX inspector, verification script |
| `packaging/` | `LINE MR.app` launcher, Info.plist, installer pages, Read Me for the disk image |

## Status and limits

- Verified only against LINE 26.5.0 (3975) on arm64.
- Ported from the Windows version 0.5.5 (2026-11-02) and checked in a logged-in LINE through the accessibility tree and synthesized keys: menus (VO+Shift+M on messages, chat rows, photos, Notes posts), the reaction picker, stickers, Photos & videos, Notes, chat search and the Control keys. Not yet heard with VoiceOver by a user; calls, the video player, sub-menus and the "Pinned" mark still need testing.
- Stickers, videos, locations and contacts are only recognised once they have been seen on screen. Group sender names and the call window's labels need more testing.
- This is an unofficial, independent project. It is not affiliated with or endorsed by LY Corporation / LINE.
