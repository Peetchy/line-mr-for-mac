// LINE MR: opens LINE with the VoiceOver bridge.
//
// The bridge (Contents/Resources/libline_a11y.dylib) is copied to the only places LINE's and
// LineCall's sandboxes may map code from, LINE is started with QT_PLUGIN_PATH pointing there, and
// LINE's call helper is swapped for one with the bridge. tools/line-a11y-launcher.sh does the same
// from a shell.
//
// Apps are opened through LaunchServices (not spawned as children) so that LINE and LineCall stay
// their own "responsible process" for microphone and camera permissions.

import AppKit

let lineID = "jp.naver.line.mac"
let callID = "jp.naver.line.mac.LineCall"
let testedVersion = "26.5.0 (3975)"
let repository = "Peetchy/line-mr-for-mac"
let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

// MARK: - Text and log

let thai = Locale.preferredLanguages.first?.hasPrefix("th") ?? false
func tr(_ en: String, _ th: String) -> String { thai ? th : en }

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LINE MR.log")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
    if size < 1_000_000, let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Helpers

/// Runs the run loop until `done()` is true or `timeout` seconds pass; returns `done()`.
@discardableResult
func wait(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: timeout)
    while !done() {
        if Date() >= end { return false }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    return true
}

/// Shows an alert; returns the index of the button pressed.
@discardableResult
func alert(_ message: String, _ info: String, buttons: [String] = [], style: NSAlert.Style = .warning) -> Int {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = info
    alert.alertStyle = style
    for title in buttons.isEmpty ? [tr("OK", "ตกลง")] : buttons {
        alert.addButton(withTitle: title)
    }
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
}

func fail(_ message: String, _ info: String) -> Never {
    log("error: \(message): \(info)")
    alert(message, info, style: .critical)
    exit(1)
}

func cacheDirectory() -> URL? {
    let length = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
    guard length > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: length)
    confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, length)
    return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
}

func running(_ bundleID: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
}

/// While the bridge runs it keeps its process id in session.running (crash guard, src/plugin_main.mm).
func hasBridge(_ app: NSRunningApplication, _ a11yDir: URL) -> Bool {
    guard let text = try? String(contentsOf: a11yDir.appendingPathComponent("session.running"), encoding: .utf8) else {
        return false
    }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) == app.processIdentifier
}

func install(_ dylib: URL, into a11yDir: URL) throws {
    let fm = FileManager.default
    let dest = a11yDir.appendingPathComponent("platformthemes/libline_a11y.dylib")
    if !fm.contentsEqual(atPath: dylib.path, andPath: dest.path) {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest) // never overwrite a signed Mach-O in place
        try fm.copyItem(at: dylib, to: dest)
        log("installed \(dest.path)")
    }
    // Gatekeeper would check a quarantined library (copied from a downloaded disk image) when LINE loads it.
    removexattr(dest.path, "com.apple.quarantine", 0)
}

func open(_ url: URL, pluginPath: URL, activate: Bool) -> NSRunningApplication? {
    let config = NSWorkspace.OpenConfiguration()
    config.environment = ["QT_PLUGIN_PATH": pluginPath.path]
    config.activates = activate
    config.addsToRecentItems = false
    var result: NSRunningApplication?
    var finished = false
    NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
        DispatchQueue.main.async {
            if let error { log("could not open \(url.lastPathComponent): \(error.localizedDescription)") }
            result = app
            finished = true
        }
    }
    wait(30) { finished }
    return result
}

// MARK: - Updates

/// "v0.1.1" -> [0, 1, 1]. A suffix ("0.1.1-abc1234", a build between releases) is ignored.
func versionNumbers(_ version: String) -> [Int] {
    let core = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: "-").first ?? ""
    return core.split(separator: ".").map { Int($0) ?? 0 }
}

func isNewer(_ version: String, than other: String) -> Bool {
    let a = versionNumbers(version), b = versionNumbers(other)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

struct Release {
    let version: String // the tag, "v0.1.2"
    let page: URL
    let diskImage: URL?
}

/// The repository's latest published release (drafts and pre-releases are not "latest").
func latestRelease(timeout: TimeInterval) -> Release? {
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!,
                             timeoutInterval: timeout)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("LINE-MR/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    var body: Data?
    var finished = false
    URLSession.shared.dataTask(with: request) { data, response, error in
        DispatchQueue.main.async {
            if let error {
                log("update check failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                log("update check failed: HTTP \(http.statusCode)")
            } else {
                body = data
            }
            finished = true
        }
    }.resume()
    wait(timeout + 1) { finished }
    guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let tag = json["tag_name"] as? String,
          let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
    let assets = json["assets"] as? [[String: Any]] ?? []
    let diskImage = assets.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".dmg") }
    return Release(version: tag, page: page, diskImage: diskImage.flatMap(URL.init(string:)))
}

/// At most once a day, once LINE is open: offer a newer LINE MR from the repository's releases.
func checkForUpdate() {
    let defaults = UserDefaults.standard
    if let last = defaults.object(forKey: "lastUpdateCheck") as? Date, Date().timeIntervalSince(last) < 24 * 60 * 60 {
        return
    }
    guard let release = latestRelease(timeout: 8) else { return }
    defaults.set(Date(), forKey: "lastUpdateCheck")
    log("latest release \(release.version), this is \(currentVersion)")
    guard isNewer(release.version, than: currentVersion), defaults.string(forKey: "skippedVersion") != release.version else {
        return
    }
    let version = release.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    let choice = alert(
        tr("A new version of LINE MR is available", "มี LINE MR เวอร์ชันใหม่"),
        tr("LINE MR \(version) is available (this Mac has \(currentVersion)). Download it, then install it the same way as before: open the disk image and run Install LINE MR.pkg.",
           "LINE MR \(version) พร้อมให้ดาวน์โหลดแล้ว (เครื่องนี้เป็น \(currentVersion)) ดาวน์โหลดแล้วติดตั้งแบบเดียวกับครั้งก่อน คือเปิดไฟล์ DMG แล้วเปิด Install LINE MR.pkg"),
        buttons: [tr("Download", "ดาวน์โหลด"), tr("Later", "ไว้ทีหลัง"), tr("Skip This Version", "ข้ามเวอร์ชันนี้")],
        style: .informational)
    switch choice {
    case 0:
        let url = release.diskImage ?? release.page
        log("opening \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    case 2:
        defaults.set(release.version, forKey: "skippedVersion")
    default:
        break // asked again tomorrow
    }
}

// MARK: - Steps

func lineLocation() -> URL? {
    let standard = URL(fileURLWithPath: "/Applications/LINE.app")
    if FileManager.default.fileExists(atPath: standard.path) { return standard }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: lineID)
}

/// The bridge reads LINE's memory at offsets found in one version; on others those features switch
/// themselves off. Ask once per untested version.
func checkVersion(_ lineURL: URL) {
    let info = Bundle(url: lineURL)?.infoDictionary
    let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    let defaults = UserDefaults.standard
    guard version != testedVersion, defaults.string(forKey: "acceptedLINEVersion") != version else { return }
    log("LINE \(version) is not the tested \(testedVersion)")
    let choice = alert(
        tr("This version of LINE has not been tested", "LINE เวอร์ชันนี้ยังไม่ได้ทดสอบ"),
        tr("LINE MR was tested with LINE \(testedVersion), but this Mac has LINE \(version). LINE will work, but VoiceOver may not read some parts. Check whether a newer LINE MR is available.",
           "LINE MR ทดสอบกับ LINE \(testedVersion) แต่เครื่องนี้เป็น LINE \(version) LINE ใช้งานได้ตามปกติ แต่ VoiceOver อาจอ่านบางส่วนไม่ได้ ลองตรวจดูว่ามี LINE MR เวอร์ชันใหม่หรือไม่"),
        buttons: [tr("Open LINE", "เปิด LINE"), tr("Cancel", "ยกเลิก")])
    if choice != 0 { exit(0) }
    defaults.set(version, forKey: "acceptedLINEVersion")
}

/// LINE starts LineCall through LaunchServices without our environment and replaces a LineCall started
/// before it, so wait for LINE's own LineCall and swap it for one with the bridge (LINE keeps talking to
/// the new instance).
func swapCallHelper(_ callURL: URL, _ callDir: URL) {
    guard FileManager.default.fileExists(atPath: callURL.path) else { return }
    var call: NSRunningApplication?
    wait(30) {
        call = running(callID)
        return call != nil
    }
    guard let old = call else {
        log("LineCall did not start")
        return
    }
    if hasBridge(old, callDir) { return }
    wait(1) { false }
    // Killing it on purpose is not a crash.
    try? FileManager.default.removeItem(at: callDir.appendingPathComponent("session.running"))
    kill(old.processIdentifier, SIGTERM)
    wait(5) { old.isTerminated }
    guard let new = open(callURL, pluginPath: callDir, activate: false) else { return }
    log("started LineCall \(new.processIdentifier)")
    if !wait(15, until: { hasBridge(new, callDir) }) {
        log("the bridge did not load in LineCall")
    }
}

func run() {
    let noLog = tr("Details are in ~/Library/Logs/LINE MR.log.", "ดูรายละเอียดได้ที่ ~/Library/Logs/LINE MR.log")
    guard let dylib = Bundle.main.url(forResource: "libline_a11y", withExtension: "dylib") else {
        fail(tr("LINE MR is damaged", "LINE MR เสียหาย"), tr("Download and install LINE MR again.", "ดาวน์โหลดและติดตั้ง LINE MR ใหม่"))
    }
    guard let lineURL = lineLocation() else {
        fail(tr("LINE is not installed", "ยังไม่ได้ติดตั้ง LINE"),
             tr("Install LINE from the Mac App Store, then open LINE MR again.", "ติดตั้ง LINE จาก Mac App Store แล้วเปิด LINE MR อีกครั้ง"))
    }
    guard let cache = cacheDirectory() else {
        fail(tr("Could not find the cache folder", "ไม่พบโฟลเดอร์ cache"), noLog)
    }
    let lineDir = cache.appendingPathComponent("\(lineID)/a11y")
    let callDir = cache.appendingPathComponent("\(callID)/a11y")
    let callURL = lineURL.appendingPathComponent("Contents/Frameworks/LineCall.app")
    log("LINE MR \(currentVersion), LINE at \(lineURL.path)")

    checkVersion(lineURL)
    do {
        try install(dylib, into: lineDir)
        try install(dylib, into: callDir)
    } catch {
        fail(tr("Could not install VoiceOver support", "ติดตั้งส่วนเสริม VoiceOver ไม่สำเร็จ"), error.localizedDescription)
    }

    if let line = running(lineID) {
        if hasBridge(line, lineDir) {
            // Already bridged: just bring LINE back (also when its window is closed to the menu bar).
            log("LINE \(line.processIdentifier) already has the bridge")
            _ = open(lineURL, pluginPath: lineDir, activate: true)
            checkForUpdate()
            exit(0)
        }
        let choice = alert(
            tr("LINE is open without VoiceOver support", "LINE เปิดอยู่โดยยังไม่มีส่วนเสริม VoiceOver"),
            tr("LINE MR will quit LINE and open it again.", "LINE MR จะปิด LINE แล้วเปิดใหม่ให้"),
            buttons: [tr("Restart LINE", "เปิด LINE ใหม่"), tr("Cancel", "ยกเลิก")])
        if choice != 0 { exit(0) }
        line.terminate()
        if !wait(15, until: { line.isTerminated }) {
            fail(tr("LINE did not quit", "ปิด LINE ไม่ได้"),
                 tr("Quit LINE with Command+Q, then open LINE MR again.", "ปิด LINE ด้วย Command+Q แล้วเปิด LINE MR อีกครั้ง"))
        }
        // LINE starts its call helper again only if the old one is gone.
        if let call = running(callID) { wait(5) { call.isTerminated } }
    }

    guard let line = open(lineURL, pluginPath: lineDir, activate: true) else {
        fail(tr("Could not open LINE", "เปิด LINE ไม่ได้"), noLog)
    }
    log("started LINE \(line.processIdentifier)")
    if !wait(30, until: { hasBridge(line, lineDir) || line.isTerminated }) || line.isTerminated {
        log("the bridge did not load in LINE")
        alert(tr("VoiceOver support did not start", "ส่วนเสริม VoiceOver ไม่ทำงาน"),
              tr("LINE opened, but without VoiceOver support. Quit LINE and open LINE MR again. ", "LINE เปิดแล้วแต่ไม่มีส่วนเสริม VoiceOver ให้ปิด LINE แล้วเปิด LINE MR อีกครั้ง ") + noLog)
        exit(1)
    }
    log("the bridge is running in LINE")
    swapCallHelper(callURL, callDir)
    checkForUpdate()
    exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
// Started from a timer, not the main dispatch queue: run() waits in nested run loops for work that
// is delivered on the main queue, which a block already running on that queue would block.
Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in run() }
application.run()
