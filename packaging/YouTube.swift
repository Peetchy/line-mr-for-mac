// LINE MR: download from YouTube links in chats, a video (MP4) or its sound (MP3), also a whole playlist
// (line-mr-for-win's addon/appModules/line/youtube.py, youtubeCore.py and youtubeModule.py).
//
// 1. The bridge inside LINE (Control+Shift+Y on a message, or "Download video from YouTube" in its
//    menu) finds the message's YouTube address, writes it to youtube-request.txt in its a11y directory
//    and opens linemr://youtube (src/transcribe_request.mm). LINE is sandboxed and could not run the
//    programs itself. The URL carries nothing: a web page opening it finds no request.
// 2. A notice says to download only what the user may download (YouTube's terms); it shows every time
//    until "Don't show this again".
// 3. The download module is made ready (yt-dlp, Deno, FFmpeg and ffprobe for Apple silicon; downloaded
//    the first time, updated when their projects release a new version), then yt-dlp is asked about the
//    address (is it available? title, length, qualities; the playlist too if the address has one).
// 4. The window offers: this video or the whole playlist, Video (MP4) or Audio (MP3), the quality (with
//    the size where YouTube says it), the folder (Downloads; remembered). Cancel stops the download and
//    removes the partial files.
//
// Unlike on Windows the module is not released by this repository: each program comes from its own
// project (its newest release, checked against the SHA-256 that project publishes), so nothing is
// redistributed and no workflow has to run for it.

import AppKit
import CryptoKit

// MARK: - Addresses

struct YouTubeAddress {
    let video: String?
    let playlist: String?
}

private func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

/// The video and playlist ids of a YouTube address; nil if it is not one to download from (channels,
/// search pages, other sites).
func parseYouTubeAddress(_ text: String) -> YouTubeAddress? {
    guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = parts.host?.lowercased(),
          ["youtube.com", "youtu.be", "youtube-nocookie.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
        return nil
    }
    let path = parts.path.split(separator: "/").map(String.init)
    func query(_ name: String) -> String? { parts.queryItems?.first { $0.name == name }?.value }
    var video: String?
    if host.hasSuffix("youtu.be") {
        video = path.first
    } else if let first = path.first, ["shorts", "live", "embed", "v"].contains(first), path.count > 1 {
        video = path[1]
    } else if path.first == "watch" || path.isEmpty {
        video = query("v")
    }
    var playlist = query("list")
    if let v = video, !matches(v, "^[A-Za-z0-9_-]{11}$") { video = nil }
    if let p = playlist, !matches(p, "^[A-Za-z0-9_-]{10,64}$") { playlist = nil }
    // A mix ("RD...") is endless and made for the viewer: not offered as a playlist.
    if playlist?.hasPrefix("RD") == true { playlist = nil }
    if video == nil && playlist == nil { return nil }
    return YouTubeAddress(video: video, playlist: playlist)
}

func readYouTubeRequest() -> String? {
    guard let dir = cacheDirectory()?.appendingPathComponent(lineID).appendingPathComponent("a11y") else { return nil }
    let url = dir.appendingPathComponent("youtube-request.txt")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    try? FileManager.default.removeItem(at: url)
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0] == "url" { return parts[1] }
    }
    return nil
}

// MARK: - What yt-dlp says

struct YouTubeVideoInfo {
    let title: String
    let duration: Double
    let isLive: Bool
    let formats: [[String: Any]]

    init(_ doc: [String: Any]) {
        title = doc["title"] as? String ?? doc["id"] as? String ?? ""
        duration = (doc["duration"] as? NSNumber)?.doubleValue ?? 0
        let status = doc["live_status"] as? String ?? ""
        isLive = (doc["is_live"] as? Bool ?? false) || status == "is_live" || status == "is_upcoming"
        formats = doc["formats"] as? [[String: Any]] ?? []
    }

    private func hasVideo(_ f: [String: Any]) -> Bool { (f["vcodec"] as? String).map { $0 != "none" } ?? false }
    private func hasAudio(_ f: [String: Any]) -> Bool { (f["acodec"] as? String).map { $0 != "none" } ?? false }
    private func size(_ f: [String: Any]) -> Int64 {
        (f["filesize"] as? NSNumber)?.int64Value ?? (f["filesize_approx"] as? NSNumber)?.int64Value ?? 0
    }

    /// Video heights offered, highest first.
    var heights: [Int] {
        Set(formats.filter(hasVideo).compactMap { ($0["height"] as? NSNumber)?.intValue }.filter { $0 >= 144 }).sorted(by: >)
    }

    var audioSize: Int64 {
        formats.filter { ($0["vcodec"] as? String) == "none" && hasAudio($0) }.map(size).max() ?? 0
    }

    /// Bytes of a download at `height` (the best H.264 stream of that height, else any, plus the best
    /// audio), 0 if unknown.
    func videoSize(_ height: Int) -> Int64 {
        let video = formats.filter { ($0["height"] as? NSNumber)?.intValue == height && hasVideo($0) }
        let h264 = video.filter { ($0["vcodec"] as? String ?? "").hasPrefix("avc1") }
        guard let best = (h264.isEmpty ? video : h264).max(by: { size($0) < size($1) }) else { return 0 }
        return hasAudio(best) ? size(best) : size(best) + audioSize
    }
}

struct YouTubePlaylistInfo {
    let title: String
    let count: Int

    init(_ doc: [String: Any]) {
        title = doc["title"] as? String ?? doc["id"] as? String ?? ""
        let entries = (doc["entries"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        count = (doc["playlist_count"] as? NSNumber)?.intValue ?? entries.count
    }
}

enum YouTubeChoices {
    /// Heights offered for a playlist (its videos differ: the best up to that height is taken).
    static let playlistHeights = [2160, 1440, 1080, 720, 480, 360]
    static let audioKbps = [320, 192, 128]
    static let defaultHeight = 1080
    static let defaultKbps = 192

    /// The preferred height, else the highest below it, else the lowest offered.
    static func height(from heights: [Int], preferred: Int) -> Int {
        heights.first { $0 <= preferred } ?? heights.last ?? preferred
    }
}

/// Words for a failed yt-dlp run (its last ERROR line) and for module problems.
func youTubeFailureText(_ reason: String, _ detail: String = "") -> String {
    switch reason {
    case "private": return tr("This video is private or for channel members only.", "วิดีโอนี้เป็นวิดีโอส่วนตัว หรือสำหรับสมาชิกช่องเท่านั้น")
    case "age": return tr("This video is age-restricted and cannot be downloaded without signing in.", "วิดีโอนี้จำกัดอายุผู้ชม ดาวน์โหลดไม่ได้หากไม่ได้ลงชื่อเข้าใช้")
    case "region": return tr("This video is not available in your country.", "วิดีโอนี้ไม่มีให้ดูในประเทศของคุณ")
    case "live": return tr("Live streams and premieres cannot be downloaded.", "ดาวน์โหลดไลฟ์สดและวิดีโอที่ยังไม่เปิดตัวไม่ได้")
    case "signin": return tr("YouTube refused the download for now (it asks to sign in). Try again later.", "YouTube ไม่ยอมให้ดาวน์โหลดในตอนนี้ (ขอให้ลงชื่อเข้าใช้) ลองใหม่ภายหลัง")
    case "network": return tr("YouTube could not be reached. Check the internet connection.", "เชื่อมต่อ YouTube ไม่ได้ ตรวจสอบการเชื่อมต่ออินเทอร์เน็ต")
    case "unavailable": return tr("This video is unavailable: it was removed, or the link is wrong.", "วิดีโอนี้ใช้ไม่ได้ อาจถูกลบไปแล้ว หรือลิงก์ไม่ถูกต้อง")
    case "offline": return tr("The YouTube download module could not be downloaded. Check the internet connection.", "ดาวน์โหลดโมดูลสำหรับดาวน์โหลด YouTube ไม่ได้ ตรวจสอบการเชื่อมต่ออินเทอร์เน็ต")
    case "damaged": return tr("The YouTube download module was damaged while downloading. Try again.", "โมดูลสำหรับดาวน์โหลด YouTube เสียหายระหว่างดาวน์โหลด ลองใหม่อีกครั้ง")
    case "notFound": return tr("The YouTube download module is not available yet. Try again later.", "ยังไม่มีโมดูลสำหรับดาวน์โหลด YouTube ให้ใช้ ลองใหม่ภายหลัง")
    default:
        let text = detail.isEmpty ? "?" : detail
        return tr("The download failed: \(text)", "ดาวน์โหลดไม่สำเร็จ: \(text)")
    }
}

/// (reason, yt-dlp's last ERROR line) of a failed run; "other" if not recognised.
func youTubeErrorReason(_ stderr: String) -> (String, String) {
    let errors = stderr.split(separator: "\n").filter { $0.hasPrefix("ERROR:") }
    let last = errors.last.map { String($0.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
    let patterns: [(String, String)] = [
        ("private", "private video|members-only|join this channel"),
        ("age", "confirm your age|age-restricted|inappropriate for some users"),
        ("region", "not available in your country|geo.?restrict|blocked it in your country"),
        ("live", "live event will begin|premieres in|is not live|this live event"),
        ("signin", "sign in to confirm you.re not a bot|sign in to confirm"),
        ("network", "unable to download (webpage|api page)|getaddrinfo|timed out|connection|network is unreachable|ssl"),
        ("unavailable", "video unavailable|this video is unavailable|has been removed|account .*terminated|does not exist|not found|incomplete youtube id"),
    ]
    for (reason, pattern) in patterns where last.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
        return (reason, last)
    }
    return ("other", last)
}

// MARK: - The download module

struct YouTubeModuleError: Error {
    /// "offline" (no module and no connection), "damaged" (checksum / unpacking), "notFound".
    let reason: String
    let detail: String
}

struct YouTubeCancelled: Error {}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A small request, answered on the calling (never the main) thread. `follow: false` returns the
/// redirect itself, whose Location names a project's newest release.
private func youTubeFetch(_ url: URL, method: String = "GET", follow: Bool = true) -> (Data, HTTPURLResponse)? {
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = method
    request.setValue("LINE-MR/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    let session = URLSession(configuration: .ephemeral, delegate: follow ? nil : NoRedirect(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let done = DispatchSemaphore(value: 0)
    var result: (Data, HTTPURLResponse)?
    session.dataTask(with: request) { data, response, _ in
        if let http = response as? HTTPURLResponse { result = (data ?? Data(), http) }
        done.signal()
    }.resume()
    done.wait()
    return result
}

/// One file to a temporary place, with progress; cancellable from another thread.
private final class YouTubeFileDownload: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Int64, Int64) -> Void)?
    private let done = DispatchSemaphore(value: 0)
    private var task: URLSessionDownloadTask?
    private var file: URL?

    func run(_ url: URL) -> URL? {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("LINE-MR/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
        done.wait()
        session.finishTasksAndInvalidate()
        return file
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
        // The temporary file disappears when this returns.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("linemr-" + UUID().uuidString)
        if (try? FileManager.default.moveItem(at: location, to: kept)) != nil { file = kept }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        done.signal()
    }
}

private func sha256Hex(_ url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    var hash = SHA256()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

/// yt-dlp, Deno (runs YouTube's JavaScript challenges for yt-dlp), FFmpeg and ffprobe (join video and
/// audio, make MP3) in ~/Library/Application Support/LINE MR/youtube/bin. installed.json = {component:
/// version}; check.json = the time and the versions of the last look for newer ones.
enum YouTubeModule {
    /// Seconds between two looks for newer programs (as on Windows: at most every 3 hours).
    static let checkInterval: TimeInterval = 3 * 3600
    static let programs = ["yt-dlp": "yt-dlp_macos", "deno": "deno", "ffmpeg": "ffmpeg", "ffprobe": "ffprobe"]
    static let order = ["yt-dlp", "deno", "ffmpeg", "ffprobe"]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LINE MR/youtube", isDirectory: true)
    }
    static var binDirectory: URL { directory.appendingPathComponent("bin", isDirectory: true) }
    static var cacheDirectory: URL { directory.appendingPathComponent("cache", isDirectory: true) }
    static func program(_ id: String) -> URL { binDirectory.appendingPathComponent(programs[id]!) }

    private static func readJSON(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func writeJSON(_ name: String, _ value: [String: Any]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }

    /// {component: version} of the programs on disk.
    static func installed() -> [String: String] {
        var result: [String: String] = [:]
        for (id, version) in readJSON("installed.json") ?? [:] {
            if let version = version as? String, programs[id] != nil, FileManager.default.isExecutableFile(atPath: program(id).path) {
                result[id] = version
            }
        }
        return result
    }

    static var isComplete: Bool { Set(installed().keys) == Set(order) }

    private static func validVersion(_ text: String) -> Bool { matches(text, "^[0-9A-Za-z._-]{1,60}$") }

    /// A project's newest release on GitHub: the tag its /releases/latest page redirects to (no API,
    /// so no request limit).
    private static func latestTag(_ repository: String) -> String? {
        guard let (_, response) = youTubeFetch(URL(string: "https://github.com/\(repository)/releases/latest")!, method: "HEAD", follow: false),
              (300..<400).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let tag = URL(string: location)?.lastPathComponent, location.contains("/releases/tag/"), validVersion(tag) else { return nil }
        return tag
    }

    /// The newest FFmpeg build for Apple silicon of ffmpeg.martin-riedl.de: the folder its "latest"
    /// address redirects to ("1789931890_9.0.2"), which holds ffmpeg.zip and ffprobe.zip.
    private static func latestFFmpegBuild() -> String? {
        let base = "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
        guard let (_, response) = youTubeFetch(URL(string: base)!, method: "HEAD", follow: false),
              (300..<400).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location") else { return nil }
        let parts = location.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts.last == "ffmpeg.zip", location.contains("/download/macos/arm64/"),
              validVersion(parts[parts.count - 2]) else { return nil }
        return parts[parts.count - 2]
    }

    /// {component: newest version}: from the last look if it was less than `checkInterval` ago, else
    /// asked now. nil if it cannot be looked up (offline).
    static func latestVersions() -> [String: String]? {
        if let check = readJSON("check.json"), let time = check["time"] as? Double, let versions = check["versions"] as? [String: String],
           (0..<checkInterval).contains(Date().timeIntervalSince1970 - time), Set(versions.keys) == Set(order) {
            return versions
        }
        guard let ytdlp = latestTag("yt-dlp/yt-dlp"), let deno = latestTag("denoland/deno"), let ffmpeg = latestFFmpegBuild() else {
            log("youtube: the newest versions could not be looked up")
            return nil
        }
        let versions = ["yt-dlp": ytdlp, "deno": deno, "ffmpeg": ffmpeg, "ffprobe": ffmpeg]
        writeJSON("check.json", ["time": Date().timeIntervalSince1970, "versions": versions])
        return versions
    }

    /// Where a component's file and the SHA-256 its project publishes for it are.
    private static func source(_ id: String, _ version: String) -> (file: URL, sums: URL, name: String, zipped: Bool) {
        switch id {
        case "yt-dlp":
            let base = "https://github.com/yt-dlp/yt-dlp/releases/download/\(version)/"
            return (URL(string: base + "yt-dlp_macos")!, URL(string: base + "SHA2-256SUMS")!, "yt-dlp_macos", false)
        case "deno":
            let name = "deno-aarch64-apple-darwin.zip"
            let base = "https://github.com/denoland/deno/releases/download/\(version)/"
            return (URL(string: base + name)!, URL(string: base + name + ".sha256sum")!, name, true)
        default:
            let base = "https://ffmpeg.martin-riedl.de/download/macos/arm64/\(version)/"
            return (URL(string: base + id + ".zip")!, URL(string: base + id + ".zip.sha256")!, id + ".zip", true)
        }
    }

    /// The SHA-256 of `name` in a checksum file ("<hash>  <name>" lines, or the hash alone).
    private static func checksum(in text: String, for name: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }
        for words in lines {
            guard let hash = words.first?.lowercased(), matches(hash, "^[0-9a-f]{64}$") else { continue }
            if words.count == 1 && lines.count == 1 { return hash }
            if words.count >= 2, words.last!.trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name { return hash }
        }
        return nil
    }

    /// Makes the newest programs available (downloads what is missing or has a new version).
    /// `onProgress(state, index, count, done, total)`: state "checking" / "downloading" / "installing".
    /// Offline, programs already there are used as they are.
    static func ensure(onProgress: @escaping (String, Int, Int, Int64, Int64) -> Void, keep: @escaping (YouTubeFileDownloadHandle) -> Void,
                       cancelled: @escaping () -> Bool) throws {
        onProgress("checking", 0, 0, 0, 0)
        guard let latest = latestVersions() else {
            if isComplete {
                log("youtube: programs not checked (offline?); using the installed ones")
                return
            }
            throw YouTubeModuleError(reason: "offline", detail: "")
        }
        let have = installed()
        let todo = order.filter { have[$0] != latest[$0] }
        for (index, id) in todo.enumerated() {
            if cancelled() { throw YouTubeCancelled() }
            let version = latest[id]!
            let source = source(id, version)
            guard let (sums, response) = youTubeFetch(source.sums), response.statusCode == 200,
                  let expected = checksum(in: String(decoding: sums, as: UTF8.self), for: source.name) else {
                // An older program still works: only a missing one stops the download.
                if have[id] != nil { continue }
                throw YouTubeModuleError(reason: "offline", detail: "no checksum for \(source.name)")
            }
            let download = YouTubeFileDownload()
            download.onProgress = { done, total in onProgress("downloading", index + 1, todo.count, done, total) }
            keep(YouTubeFileDownloadHandle { download.cancel() })
            onProgress("downloading", index + 1, todo.count, 0, 0)
            let file = download.run(source.file)
            if cancelled() {
                if let file { try? FileManager.default.removeItem(at: file) }
                throw YouTubeCancelled()
            }
            guard let file else {
                if have[id] != nil { continue }
                throw YouTubeModuleError(reason: "offline", detail: source.name)
            }
            defer { try? FileManager.default.removeItem(at: file) }
            onProgress("installing", index + 1, todo.count, 0, 0)
            guard sha256Hex(file) == expected else {
                throw YouTubeModuleError(reason: "damaged", detail: "checksum mismatch: \(source.name)")
            }
            try install(id, version, from: file, zipped: source.zipped)
            log("youtube: installed \(id) \(version)")
        }
    }

    /// Puts a checked download in place (a zip is unpacked beside it first, so a failed update leaves
    /// the old program working).
    private static func install(_ id: String, _ version: String, from file: URL, zipped: Bool) throws {
        let fm = FileManager.default
        let name = programs[id]!
        var program = file
        var unpacked: URL?
        if zipped {
            let folder = fm.temporaryDirectory.appendingPathComponent("linemr-" + UUID().uuidString, isDirectory: true)
            unpacked = folder
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", file.path, folder.path]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try? unzip.run()
            unzip.waitUntilExit()
            program = folder.appendingPathComponent(name)
            guard unzip.terminationStatus == 0, fm.fileExists(atPath: program.path) else {
                try? fm.removeItem(at: folder)
                throw YouTubeModuleError(reason: "damaged", detail: "\(name) missing in the download")
            }
        }
        defer { if let unpacked { try? fm.removeItem(at: unpacked) } }
        do {
            try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            let target = self.program(id)
            try? fm.removeItem(at: target) // never overwrite a signed program in place
            try fm.moveItem(at: program, to: target)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            removexattr(target.path, "com.apple.quarantine", 0)
        } catch {
            throw YouTubeModuleError(reason: "damaged", detail: error.localizedDescription)
        }
        var have = (readJSON("installed.json") as? [String: String]) ?? [:]
        have[id] = version
        writeJSON("installed.json", have)
    }
}

/// Lets the window cancel the file being downloaded.
struct YouTubeFileDownloadHandle {
    let cancel: () -> Void
}

// MARK: - Running yt-dlp

/// yt-dlp starts FFmpeg and Deno (and is itself a loader with a child): the whole tree goes.
func killProcessTree(_ pid: pid_t) {
    let list = Process()
    list.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    list.arguments = ["-P", String(pid)]
    let output = Pipe()
    list.standardOutput = output
    list.standardError = FileHandle.nullDevice
    if (try? list.run()) != nil {
        let data = output.fileHandleForReading.readDataToEndOfFile()
        list.waitUntilExit()
        for child in String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap({ pid_t($0) }) {
            killProcessTree(child)
        }
    }
    kill(pid, SIGKILL)
}

private func youTubeCommonArguments() -> [String] {
    ["--ignore-config", "--no-warnings", "--encoding", "utf-8", "--js-runtimes", "deno:" + YouTubeModule.program("deno").path,
     "--cache-dir", YouTubeModule.cacheDirectory.path]
}

func youTubeProbeArguments(_ url: String, playlist: Bool) -> [String] {
    youTubeCommonArguments() + ["-J"] + (playlist ? ["--flat-playlist", "--yes-playlist"] : ["--no-playlist"]) + [url]
}

func youTubeDownloadArguments(_ url: String, folder: String, audio: Bool, height: Int?, kbps: Int, playlist: Bool) -> [String] {
    var args = youTubeCommonArguments() + [
        "--newline", "--progress",
        "--progress-template", "download:LMR %(progress.status)s %(progress._percent_str)s %(info.playlist_index)s %(info.n_entries)s",
        "--print", "after_move:FILE %(filepath)s",
        "--ffmpeg-location", YouTubeModule.binDirectory.path,
        "--no-mtime", "-P", folder,
    ]
    if playlist {
        // One folder per playlist, numbered in its order; an unavailable video does not stop the rest.
        args += ["--yes-playlist", "--ignore-errors", "-o", "%(playlist_title)s/%(playlist_index)03d %(title)s.%(ext)s"]
    } else {
        args += ["--no-playlist", "-o", "%(title)s.%(ext)s"]
    }
    if audio {
        args += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "\(kbps)K"]
    } else {
        // Best up to the height, H.264 + AAC where YouTube has it (plays everywhere), always an MP4 file.
        let sort = (height.map { "res:\($0)," } ?? "res,") + "vcodec:h264,acodec:aac"
        args += ["-f", "bv*+ba/b", "-S", sort, "--merge-output-format", "mp4", "--remux-video", "mp4"]
    }
    return args + [url]
}

/// (status, percent, index, count) of one of yt-dlp's progress lines ("LMR downloading  42.1% 2 13").
func parseYouTubeProgress(_ line: String) -> (String, Double, Int?, Int?)? {
    let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard words.count >= 5, words[0] == "LMR", words[2].hasSuffix("%"), let percent = Double(words[2].dropLast()) else { return nil }
    return (words[1], percent, Int(words[3]), Int(words[4]))
}

/// yt-dlp's lines while FFmpeg joins the streams or makes the MP3.
func isYouTubeProcessingLine(_ line: String) -> Bool {
    ["[Merger]", "[ExtractAudio]", "[VideoRemuxer]", "[FixupM3u8]", "[VideoConvertor]"].contains { line.hasPrefix($0) }
}

/// yt-dlp's partial files in the folder and its sub-folders (a playlist gets one).
private func youTubePartialFiles(_ folder: URL) -> Set<String> {
    var result = Set<String>()
    guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return result }
    for case let url as URL in walker {
        let name = url.lastPathComponent
        if name.hasSuffix(".part") || name.hasSuffix(".ytdl") || name.contains(".part-Frag") || name.contains(".temp.") {
            result.insert(url.path)
        }
    }
    return result
}

// MARK: - The window

final class YouTubeJob: NSObject, NSWindowDelegate {
    static var current: YouTubeJob?

    static func handleURL() {
        TranscribeJob.handledURL = true
        if let job = current {
            // One at a time: the running one comes to the front.
            job.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            job.announce(tr("The YouTube download window is already open.", "หน้าต่างดาวน์โหลด YouTube เปิดอยู่แล้ว"))
            return
        }
        guard let text = readYouTubeRequest(), let address = parseYouTubeAddress(text) else {
            log("youtube: no request, or not a YouTube address")
            if TranscribeJob.current == nil { exit(0) }
            return
        }
        let job = YouTubeJob(address)
        current = job
        job.begin()
    }

    private let address: YouTubeAddress
    private let defaults = UserDefaults.standard
    private let window: TranscribeTextWindow
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let whatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folderLabel = NSTextField(labelWithString: "")
    private let dontShow = NSButton(checkboxWithTitle: tr("Don't show this again", "ไม่ต้องแสดงอีก"), target: nil, action: nil)
    private let closeButton = NSButton(title: tr("Cancel", "ยกเลิก"), target: nil, action: nil)

    private var info: YouTubeVideoInfo?
    private var playlist: YouTubePlaylistInfo?
    private var qualities: [Int] = []
    private var folder: URL
    private var files: [String] = []
    /// Work in progress: its results are dropped once the window moved on (`generation`) or closed.
    private var generation = 0
    private var working = false
    private var cancelled = false
    private var moduleDownload: YouTubeFileDownloadHandle?
    private var processes: [Process] = []
    private var lastOutput = Date()
    private var stallTimer: Timer?
    private var lastAnnouncedStep = -1
    private var partsBefore = Set<String>()

    private static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    init(_ address: YouTubeAddress) {
        self.address = address
        if let saved = UserDefaults.standard.string(forKey: "youtubeFolder"), FileManager.default.fileExists(atPath: saved) {
            folder = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            folder = Self.downloadsFolder
        }
        window = TranscribeTextWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = tr("Download from YouTube", "ดาวน์โหลดจาก YouTube")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onEscape = { [weak self] in self?.window.performClose(nil) }
        window.center()
        statusLabel.preferredMaxLayoutWidth = 520
        titleLabel.preferredMaxLayoutWidth = 400
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 100
        progress.setAccessibilityLabel(tr("Progress", "ความคืบหน้า"))
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.keyEquivalent = "\u{1b}"
    }

    // MARK: Pages

    private func show(_ views: [NSView], focus: NSView) {
        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            content.topAnchor.constraint(equalTo: holder.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 560),
        ])
        window.contentView = holder
        bringForward(focus)
    }

    /// Opened from LINE, which is in front: macOS may not hand over the keyboard at once, so this is
    /// tried again while the window is not the key window.
    private func bringForward(_ control: NSView) {
        let w = window
        func attempt() {
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(control)
            NSAccessibility.post(element: control, notification: .focusedUIElementChanged)
        }
        attempt()
        for delay in [0.25, 0.7, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                // (Not shown at all: ordered front too soon after the app became a regular one.)
                guard let self, !self.cancelled, w.contentView === control.window?.contentView,
                      !w.isVisible || !NSApp.isActive || !w.isKeyWindow else { return }
                log("youtube: the window was not in front; trying again")
                attempt()
            }
        }
    }

    private func buttons(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        return row
    }

    private func announce(_ text: String) {
        statusLabel.stringValue = text
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func setStatus(_ text: String) {
        if statusLabel.stringValue != text { statusLabel.stringValue = text }
    }

    /// nil: nothing measurable is happening.
    private func setPercent(_ percent: Double?) {
        if let percent {
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
            progress.doubleValue = max(0, min(100, percent))
        } else {
            progress.isIndeterminate = true
            progress.startAnimation(nil)
        }
    }

    private func begin() {
        // A regular app while the window is open: macOS gives it the keyboard (and VoiceOver) more
        // reliably than an accessory app, and it can be reached with Command+Tab.
        NSApp.setActivationPolicy(.regular)
        // On the next turn of the run loop: a window ordered front in the same turn as the switch
        // stayed off screen.
        DispatchQueue.main.async { [self] in
            if defaults.object(forKey: "youtubeShowNotice") as? Bool ?? true {
                showNotice()
            } else {
                prepare()
            }
        }
    }

    /// YouTube's terms allow downloading only where YouTube offers it or the owner agrees: said before
    /// each download until "Don't show this again". (A page of the window, not an alert: VoiceOver does
    /// not reliably reach an alert of an app opened from LINE.)
    private func showNotice() {
        let text = NSTextField(wrappingLabelWithString: tr(
            "Download only videos you have the right to download: your own, ones the owner allows you to download, or ones under a free licence. YouTube's terms of service do not allow downloading other videos. You are responsible for how you use what you download.",
            "ดาวน์โหลดเฉพาะวิดีโอที่คุณมีสิทธิ์ดาวน์โหลด: วิดีโอของคุณเอง วิดีโอที่เจ้าของอนุญาตให้ดาวน์โหลด หรือวิดีโอที่ใช้สัญญาอนุญาตแบบเสรี ข้อกำหนดในการให้บริการของ YouTube ไม่อนุญาตให้ดาวน์โหลดวิดีโออื่น คุณต้องรับผิดชอบต่อการใช้งานสิ่งที่ดาวน์โหลดเอง"))
        text.preferredMaxLayoutWidth = 520
        let proceed = NSButton(title: tr("Continue", "ดำเนินการต่อ"), target: self, action: #selector(noticeContinue))
        proceed.keyEquivalent = "\r"
        show([text, dontShow, buttons([proceed, closeButton])], focus: proceed)
        // The button has the keyboard: the notice itself is spoken.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.window.isVisible, !self.working else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    @objc private func noticeContinue() {
        if dontShow.state == .on { defaults.set(false, forKey: "youtubeShowNotice") }
        prepare()
    }

    // MARK: Preparing

    private func showProgressPage() {
        show([statusLabel, progress, buttons([closeButton])], focus: closeButton)
        NSLayoutConstraint.activate([progress.widthAnchor.constraint(equalToConstant: 532)])
    }

    private func prepare() {
        showProgressPage()
        setPercent(nil)
        announce(tr("Checking the download module...", "กำลังตรวจสอบโมดูลดาวน์โหลด..."))
        working = true
        generation += 1
        let token = generation
        let address = self.address
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            func post(_ work: @escaping () -> Void) {
                DispatchQueue.main.async { [self] in if token == generation && !cancelled { work() } }
            }
            do {
                try YouTubeModule.ensure(onProgress: { state, index, count, done, total in
                    post { [self] in moduleProgress(state, index, count, done, total) }
                }, keep: { handle in
                    DispatchQueue.main.async { [self] in
                        moduleDownload = handle
                        if cancelled { handle.cancel() }
                    }
                }, cancelled: { [self] in cancelled })
                post { [self] in
                    moduleDownload = nil
                    setPercent(nil)
                    announce(tr("Checking the link...", "กำลังตรวจสอบลิงก์..."))
                }
                // The video and its playlist are asked about at the same time.
                var video: Result<YouTubeVideoInfo, YouTubeModuleError>?
                var list: Result<YouTubePlaylistInfo, YouTubeModuleError>?
                let group = DispatchGroup()
                if let id = address.video {
                    DispatchQueue.global(qos: .userInitiated).async(group: group) { [self] in
                        let result = probe("https://www.youtube.com/watch?v=" + id, playlist: false)
                        video = result.map { YouTubeVideoInfo($0) }
                    }
                }
                if let id = address.playlist {
                    DispatchQueue.global(qos: .userInitiated).async(group: group) { [self] in
                        let result = probe("https://www.youtube.com/playlist?list=" + id, playlist: true)
                        list = result.flatMap { doc -> Result<YouTubePlaylistInfo, YouTubeModuleError> in
                            guard doc["_type"] as? String == "playlist" else { return .failure(YouTubeModuleError(reason: "unavailable", detail: "")) }
                            return .success(YouTubePlaylistInfo(doc))
                        }
                    }
                }
                group.wait()
                let info = try? video?.get()
                var playlist = try? list?.get()
                if let p = playlist, p.count < 1 { playlist = nil }
                if info == nil && playlist == nil {
                    var failure = YouTubeModuleError(reason: "unavailable", detail: "")
                    if case .failure(let error)? = video { failure = error } else if case .failure(let error)? = list { failure = error }
                    throw failure
                }
                if let info, info.isLive, playlist == nil { throw YouTubeModuleError(reason: "live", detail: "") }
                post { [self] in showOptions(info, playlist) }
            } catch let error as YouTubeModuleError {
                log("youtube: not ready: \(error.reason) \(error.detail)")
                post { [self] in fail(youTubeFailureText(error.reason, error.detail)) }
            } catch {
                log("youtube: preparing was cancelled")
            }
        }
    }

    private func moduleProgress(_ state: String, _ index: Int, _ count: Int, _ done: Int64, _ total: Int64) {
        switch state {
        case "downloading":
            let part = count > 1 ? " (\(index)/\(count))" : ""
            if total > 0 {
                let d = done / 1_000_000, t = max(1, total / 1_000_000)
                setStatus(tr("Downloading the YouTube download module\(part): \(d) of \(t) MB",
                             "กำลังดาวน์โหลดโมดูลดาวน์โหลด YouTube\(part): \(d) จาก \(t) MB"))
                setPercent(Double(done) / Double(total) * 100)
            } else {
                // Said once per program: the megabytes change too often to be spoken.
                setPercent(nil)
                announce(tr("Downloading the YouTube download module\(part)...", "กำลังดาวน์โหลดโมดูลดาวน์โหลด YouTube\(part)..."))
            }
        case "installing":
            setPercent(nil)
            setStatus(tr("Installing the YouTube download module...", "กำลังติดตั้งโมดูลดาวน์โหลด YouTube..."))
        default:
            break
        }
    }

    /// Asks yt-dlp about an address (on a background thread; at most 90 s).
    private func probe(_ url: String, playlist: Bool) -> Result<[String: Any], YouTubeModuleError> {
        let process = Process()
        process.executableURL = YouTubeModule.program("yt-dlp")
        process.arguments = youTubeProbeArguments(url, playlist: playlist)
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            return .failure(YouTubeModuleError(reason: "damaged", detail: error.localizedDescription))
        }
        DispatchQueue.main.async { [self] in
            processes.append(process)
            if cancelled { killProcessTree(process.processIdentifier) }
        }
        let timeout = DispatchWorkItem { if process.isRunning { killProcessTree(process.processIdentifier) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
        var errorText = ""
        let reading = DispatchGroup()
        DispatchQueue.global().async(group: reading) {
            errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else {
            let (reason, detail) = youTubeErrorReason(errorText)
            log("youtube: address not available (\(reason)): \(detail)")
            return .failure(YouTubeModuleError(reason: reason == "other" && detail.isEmpty ? "network" : reason, detail: detail))
        }
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(YouTubeModuleError(reason: "other", detail: "no answer"))
        }
        return .success(doc)
    }

    // MARK: Choices

    private var wholePlaylist: Bool { playlist != nil && (info == nil || whatPopup.indexOfSelectedItem == 1) }
    private var audioOnly: Bool { formatPopup.indexOfSelectedItem == 1 }

    private func lengthText(_ seconds: Double) -> String {
        let total = Int(seconds), h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func showOptions(_ info: YouTubeVideoInfo?, _ playlist: YouTubePlaylistInfo?) {
        working = false
        self.info = info
        self.playlist = playlist
        whatPopup.removeAllItems()
        if let info {
            whatPopup.addItem(withTitle: info.duration > 0
                ? tr("This video only (\(lengthText(info.duration)))", "วิดีโอนี้เท่านั้น (\(lengthText(info.duration)))")
                : tr("This video only", "วิดีโอนี้เท่านั้น"))
        }
        if let playlist {
            whatPopup.addItem(withTitle: tr("Whole playlist: \(playlist.title) (\(playlist.count) videos)",
                                            "ทั้งเพลย์ลิสต์: \(playlist.title) (\(playlist.count) วิดีโอ)"))
        }
        whatPopup.selectItem(at: 0)
        whatPopup.target = self
        whatPopup.action = #selector(choiceChanged)
        whatPopup.setAccessibilityLabel(tr("Download", "ดาวน์โหลด"))
        formatPopup.removeAllItems()
        formatPopup.addItems(withTitles: [tr("Video (MP4)", "วิดีโอ (MP4)"), tr("Audio only (MP3)", "เสียงอย่างเดียว (MP3)")])
        formatPopup.selectItem(at: defaults.string(forKey: "youtubeFormat") == "mp3" ? 1 : 0)
        formatPopup.target = self
        formatPopup.action = #selector(choiceChanged)
        formatPopup.setAccessibilityLabel(tr("Format", "รูปแบบ"))
        qualityPopup.setAccessibilityLabel(tr("Quality", "คุณภาพ"))
        titleLabel.stringValue = info?.title ?? playlist?.title ?? ""
        folderLabel.stringValue = folder.path
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setAccessibilityLabel(tr("Save in", "บันทึกใน"))
        fillQualities()

        var rows: [[NSView]] = [[NSTextField(labelWithString: tr("Title:", "ชื่อ:")), titleLabel]]
        let both = whatPopup.numberOfItems > 1
        if both { rows.append([NSTextField(labelWithString: tr("Download:", "ดาวน์โหลด:")), whatPopup]) }
        rows.append([NSTextField(labelWithString: tr("Format:", "รูปแบบ:")), formatPopup])
        rows.append([NSTextField(labelWithString: tr("Quality:", "คุณภาพ:")), qualityPopup])
        let browse = NSButton(title: tr("Browse...", "เลือก..."), target: self, action: #selector(browse))
        browse.setAccessibilityLabel(tr("Choose the folder for YouTube downloads", "เลือกโฟลเดอร์สำหรับเก็บไฟล์ที่ดาวน์โหลดจาก YouTube"))
        let folderRow = buttons([folderLabel, browse])
        rows.append([NSTextField(labelWithString: tr("Save in:", "บันทึกใน:")), folderRow])
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        let download = NSButton(title: tr("Download", "ดาวน์โหลด"), target: self, action: #selector(startDownload))
        download.keyEquivalent = "\r"
        let views: [NSView] = [statusLabel, grid, buttons([download, closeButton])]
        NSLayoutConstraint.activate([folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300)])
        show(views, focus: both ? whatPopup : formatPopup)
        announce(tr("Ready to download. Choose the format and quality.", "พร้อมดาวน์โหลด เลือกรูปแบบและคุณภาพ"))
    }

    @objc private func choiceChanged() { fillQualities() }

    private func qualityTitle(_ name: String, _ size: Int64) -> String {
        guard size > 0 else { return name }
        let megabytes = max(1, Int((Double(size) / 1_000_000).rounded()))
        return tr("\(name) (about \(megabytes) MB)", "\(name) (ประมาณ \(megabytes) MB)")
    }

    private func fillQualities() {
        qualityPopup.removeAllItems()
        qualities = []
        let single = wholePlaylist ? nil : info
        if audioOnly {
            for kbps in YouTubeChoices.audioKbps {
                let size = single.map { Int64($0.duration * Double(kbps) * 125) } ?? 0
                qualities.append(kbps)
                qualityPopup.addItem(withTitle: qualityTitle("\(kbps) kbps", size))
            }
            let preferred = defaults.object(forKey: "youtubeAudioKbps") as? Int ?? YouTubeChoices.defaultKbps
            qualityPopup.selectItem(at: qualities.firstIndex(of: preferred) ?? 1)
            return
        }
        var heights = single?.heights ?? []
        if heights.isEmpty { heights = YouTubeChoices.playlistHeights }
        for height in heights {
            qualities.append(height)
            qualityPopup.addItem(withTitle: qualityTitle("\(height)p", single?.videoSize(height) ?? 0))
        }
        let preferred = defaults.object(forKey: "youtubeVideoHeight") as? Int ?? YouTubeChoices.defaultHeight
        qualityPopup.selectItem(at: qualities.firstIndex(of: YouTubeChoices.height(from: heights, preferred: preferred)) ?? 0)
    }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.message = tr("Choose the folder for YouTube downloads", "เลือกโฟลเดอร์สำหรับเก็บไฟล์ที่ดาวน์โหลดจาก YouTube")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            folderLabel.stringValue = url.path
        }
    }

    // MARK: Downloading

    @objc private func startDownload() {
        guard !working, !qualities.isEmpty else { return }
        let audio = audioOnly
        let quality = qualities[max(0, qualityPopup.indexOfSelectedItem)]
        defaults.set(audio ? "mp3" : "mp4", forKey: "youtubeFormat")
        defaults.set(quality, forKey: audio ? "youtubeAudioKbps" : "youtubeVideoHeight")
        if folder.standardizedFileURL == Self.downloadsFolder.standardizedFileURL {
            defaults.removeObject(forKey: "youtubeFolder")
        } else {
            defaults.set(folder.path, forKey: "youtubeFolder")
        }
        let whole = wholePlaylist
        let url = whole ? "https://www.youtube.com/playlist?list=" + (address.playlist ?? "")
                        : "https://www.youtube.com/watch?v=" + (address.video ?? "")
        showProgressPage()
        setPercent(0)
        lastAnnouncedStep = -1
        announce(tr("Starting the download...", "กำลังเริ่มดาวน์โหลด..."))
        working = true
        generation += 1
        let token = generation
        let folder = self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        partsBefore = youTubePartialFiles(folder)
        log("youtube: download started (\(whole ? "playlist" : "video"), \(audio ? "mp3 \(quality)" : "mp4 \(quality)"))")

        let process = Process()
        process.executableURL = YouTubeModule.program("yt-dlp")
        process.arguments = youTubeDownloadArguments(url, folder: folder.path, audio: audio, height: audio ? nil : quality,
                                                     kbps: audio ? quality : YouTubeChoices.defaultKbps, playlist: whole)
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            return fail(youTubeFailureText("damaged"))
        }
        processes.append(process)
        lastOutput = Date()
        // Seconds without any output before a download is taken as stuck.
        stallTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.working, token == self.generation, Date().timeIntervalSince(self.lastOutput) > 300 else { return }
            self.generation += 1
            killProcessTree(process.processIdentifier)
            self.removePartialFiles()
            self.fail(youTubeFailureText("network"))
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            func post(_ work: @escaping () -> Void) {
                DispatchQueue.main.async { [self] in if token == generation && !cancelled { work() } }
            }
            var errorText = ""
            let reading = DispatchGroup()
            DispatchQueue.global().async(group: reading) {
                errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            }
            var saved: [String] = []
            var buffer = Data()
            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: 0x0a) {
                    let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self).trimmingCharacters(in: .newlines)
                    buffer.removeSubrange(buffer.startIndex...end)
                    DispatchQueue.main.async { [self] in lastOutput = Date() }
                    if line.hasPrefix("FILE ") {
                        saved.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                    } else if let (status, percent, index, count) = parseYouTubeProgress(line) {
                        post { [self] in downloadProgress(status, percent, index, count) }
                    } else if isYouTubeProcessingLine(line) {
                        post { [self] in setStatus(tr("Processing...", "กำลังประมวลผล...")) }
                    }
                }
            }
            reading.wait()
            process.waitUntilExit()
            let files = saved, stderr = errorText
            post { [self] in
                if files.isEmpty {
                    removePartialFiles()
                    let (reason, detail) = youTubeErrorReason(stderr)
                    log("youtube: download failed (\(reason)): \(detail)")
                    fail(youTubeFailureText(reason, detail))
                } else {
                    // A playlist goes on past unavailable videos: they are counted.
                    let failed = whole ? stderr.split(separator: "\n").filter { $0.hasPrefix("ERROR:") }.count : 0
                    finished(files, failed)
                }
            }
        }
    }

    private func downloadProgress(_ status: String, _ percent: Double, _ index: Int?, _ count: Int?) {
        var overall = percent
        var text = tr("Downloading: \(Int(percent))%", "กำลังดาวน์โหลด: \(Int(percent))%")
        if let index, let count, count > 0 {
            overall = (Double(index - 1) + percent / 100) * 100 / Double(count)
            text = tr("Downloading video \(index) of \(count): \(Int(percent))%", "กำลังดาวน์โหลดวิดีโอที่ \(index) จาก \(count): \(Int(percent))%")
        } else if status == "finished" {
            text = tr("Processing...", "กำลังประมวลผล...")
        }
        setPercent(overall)
        // Spoken every 20 % (video and sound are two downloads: each counts from 0).
        let step = (index ?? 0) * 1000 + Int(percent) / 20
        if step != lastAnnouncedStep && status != "finished" {
            lastAnnouncedStep = step
            announce(text)
        } else {
            setStatus(text)
        }
    }

    private func finished(_ files: [String], _ failed: Int) {
        working = false
        stallTimer?.invalidate()
        self.files = files
        var text = files.count == 1
            ? tr("Saved as \((files[0] as NSString).lastPathComponent)", "บันทึกเป็น \((files[0] as NSString).lastPathComponent)")
            : tr("Saved \(files.count) files", "บันทึกแล้ว \(files.count) ไฟล์")
        if failed > 0 {
            text += " " + tr("\(failed) videos could not be downloaded.", "ดาวน์โหลดไม่ได้ \(failed) วิดีโอ")
        }
        log("youtube: saved \(files.count) file(s), \(failed) failed")
        closeButton.title = tr("Close", "ปิด")
        let reveal = NSButton(title: tr("Show in Finder", "แสดงใน Finder"), target: self, action: #selector(showInFinder))
        reveal.keyEquivalent = "\r"
        setPercent(100)
        show([statusLabel, progress, buttons([reveal, closeButton])], focus: reveal)
        announce(text)
    }

    private func fail(_ text: String) {
        working = false
        stallTimer?.invalidate()
        closeButton.title = tr("Close", "ปิด")
        show([statusLabel, buttons([closeButton])], focus: closeButton)
        announce(text)
    }

    @objc private func showInFinder() {
        let existing = files.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if existing.count == 1 {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        } else if let first = existing.first {
            NSWorkspace.shared.open(first.deletingLastPathComponent())
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    private func removePartialFiles() {
        for path in youTubePartialFiles(folder).subtracting(partsBefore) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: Closing

    @objc private func closeWindow() { window.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        let wasWorking = working
        cancelled = true
        working = false
        stallTimer?.invalidate()
        moduleDownload?.cancel()
        for process in processes where process.isRunning { killProcessTree(process.processIdentifier) }
        if wasWorking {
            removePartialFiles()
            log("youtube: cancelled")
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: tr("Download cancelled.", "ยกเลิกการดาวน์โหลดแล้ว"),
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        YouTubeJob.current = nil
        running(lineID)?.activate(options: [])
        // (A transcription may still be open: the app stays for it.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if TranscribeJob.current == nil { exit(0) }
        }
    }
}
