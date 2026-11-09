// LINE MR: voice messages and videos to text, with Apple's speech recognition (the default) or whisper.cpp.
//
// The bridge inside LINE has LINE save the message's own file into its a11y directory, describes it in
// transcribe-request.txt and opens linemr://transcribe (src/transcribe_request.mm). LINE is sandboxed and
// has no speech recognition permission, so the work is done here.

import AppKit
import AVFoundation
import CryptoKit
import Speech

struct TranscribeRequest {
    let file: URL
    let isVideo: Bool
    let seconds: Int
    let title: String
}

func readTranscribeRequest() -> TranscribeRequest? {
    guard let dir = cacheDirectory()?.appendingPathComponent(lineID).appendingPathComponent("a11y") else { return nil }
    let url = dir.appendingPathComponent("transcribe-request.txt")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    try? FileManager.default.removeItem(at: url)
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        if parts.count == 2 { values[parts[0]] = parts[1] }
    }
    // Only a file the bridge put in its own folder is read, and later deleted.
    guard let path = values["file"] else { return nil }
    let file = URL(fileURLWithPath: path).standardizedFileURL
    let folder = dir.appendingPathComponent("transcribe").standardizedFileURL.resolvingSymlinksInPath().path
    guard file.resolvingSymlinksInPath().path.hasPrefix(folder + "/"),
          FileManager.default.fileExists(atPath: file.path) else {
        log("transcribe: refused \(path)")
        return nil
    }
    return TranscribeRequest(file: file, isVideo: values["kind"] == "video", seconds: Int(values["seconds"] ?? "") ?? -1,
                             title: values["title"] ?? "")
}

// MARK: - Speech models

struct SpeechModel: Decodable {
    let id: String
    let name: String
    let file: String
    let url: String
    let sha256: String
    let size: Int64

    var localURL: URL { TranscribeStore.modelsFolder.appendingPathComponent(file) }
    var isDownloaded: Bool {
        ((try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size]) as? Int64) == size
    }
}

struct SpeechModelList: Decodable { let models: [SpeechModel] }

enum SpeechEngine {
    case apple
    case model(SpeechModel)
    case file(URL)

    var id: String {
        switch self {
        case .apple: return "apple"
        case .model(let m): return m.id
        case .file: return "file"
        }
    }
    var isApple: Bool { if case .apple = self { return true } else { return false } }
}

enum TranscribeStore {
    static let defaults = UserDefaults.standard
    static var modelsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LINE MR/models", isDirectory: true)
    }
    /// The engine used last: what the chooser offers next time. Apple's until something else was used.
    static var lastEngine: String {
        get { defaults.string(forKey: "transcribeEngine") ?? "apple" }
        set { defaults.set(newValue, forKey: "transcribeEngine") }
    }
    static var lastModelFile: String? {
        get { defaults.string(forKey: "transcribeModelFile") }
        set { defaults.set(newValue, forKey: "transcribeModelFile") }
    }
    static func lastLanguage(apple: Bool) -> String? { defaults.string(forKey: apple ? "transcribeLanguageApple" : "transcribeLanguageWhisper") }
    static func setLastLanguage(_ value: String, apple: Bool) { defaults.set(value, forKey: apple ? "transcribeLanguageApple" : "transcribeLanguageWhisper") }

    /// The list on GitHub (new models appear without an update), else the copy in the app.
    static func loadModels() -> [SpeechModel] {
        let decoder = JSONDecoder()
        var fetched: Data?
        var finished = false
        var request = URLRequest(url: URL(string: "https://raw.githubusercontent.com/Peetchy/line-mr-for-win/main/speech-models.json")!,
                                 timeoutInterval: 4)
        request.setValue("LINE-MR/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                if (response as? HTTPURLResponse)?.statusCode == 200 { fetched = data }
                finished = true
            }
        }.resume()
        wait(4.5) { finished }
        if let fetched, let list = try? decoder.decode(SpeechModelList.self, from: fetched), !list.models.isEmpty { return list.models }
        if let url = Bundle.main.url(forResource: "speech-models", withExtension: "json"), let data = try? Data(contentsOf: url),
           let list = try? decoder.decode(SpeechModelList.self, from: data) { return list.models }
        return []
    }
}

// MARK: - Sound

enum TranscribeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text } else { return nil } }
}

/// The file's sound as 16 kHz mono samples (a voice message's m4a, a video's mp4).
func loadSamples(_ url: URL) throws -> [Int16] {
    let asset = AVURLAsset(url: url)
    let reader = try AVAssetReader(asset: asset)
    let tracks = asset.tracks(withMediaType: .audio)
    guard let track = tracks.first else {
        throw TranscribeError.message(tr("This video has no sound.", "วิดีโอนี้ไม่มีเสียง"))
    }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else {
        throw TranscribeError.message(reader.error?.localizedDescription ?? tr("The file could not be read.", "อ่านไฟล์ไม่ได้"))
    }
    var samples: [Int16] = []
    while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
        let length = CMBlockBufferGetDataLength(block)
        let start = samples.count
        samples.append(contentsOf: repeatElement(0, count: length / 2))
        samples.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length & ~1, destination: raw.baseAddress! + start * 2)
        }
    }
    return samples
}

/// Pieces of at most 29.5 s, cut at their quietest moment: the recognisers hear about 30 s at a time and
/// repeat or drop words where hard cuts meet.
func cutAtPauses(_ samples: [Int16]) -> [ArraySlice<Int16>] {
    let rate = 16000, longest = rate * 59 / 2, searchFrom = rate * 20, window = rate / 10
    var pieces: [ArraySlice<Int16>] = []
    var start = 0
    while samples.count - start > longest {
        var best = start + longest, quietest = Int64.max
        var at = start + searchFrom
        while at + window <= start + longest {
            let energy = samples[at..<(at + window)].reduce(Int64(0)) { $0 + Int64(abs(Int32($1))) }
            if energy < quietest { quietest = energy; best = at + window / 2 }
            at += window
        }
        pieces.append(samples[start..<best])
        start = best
    }
    pieces.append(samples[start...])
    return pieces
}

func writeWAV(_ samples: ArraySlice<Int16>, to url: URL) throws {
    var data = Data(capacity: 44 + samples.count * 2)
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    data.append(contentsOf: Array("RIFF".utf8)); le32(36 + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); le32(16); le16(1); le16(1); le32(16000); le32(32000); le16(2); le16(16)
    data.append(contentsOf: Array("data".utf8)); le32(bytes)
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url)
}

// MARK: - Recognisers

func recognizeWithApple(_ url: URL, locale: String, keepTask: @escaping (SFSpeechRecognitionTask) -> Void) throws -> String {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
        throw TranscribeError.message(tr("Apple's speech recognition is not available for this language right now.",
                                         "ระบบรู้จำเสียงของ Apple ใช้กับภาษานี้ไม่ได้ในขณะนี้"))
    }
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = false
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    request.addsPunctuation = true
    let finished = DispatchSemaphore(value: 0)
    var text = ""
    var failure: Error?
    var done = false
    let task = recognizer.recognitionTask(with: request) { result, error in
        guard !done else { return }
        if let result, result.isFinal {
            text = result.bestTranscription.formattedString
            done = true
            finished.signal()
        } else if let error {
            failure = error
            done = true
            finished.signal()
        }
    }
    keepTask(task)
    finished.wait()
    if let failure = failure as NSError? {
        // "No speech detected" is an empty piece, not a failure.
        if failure.code == 1110 || failure.code == 301 { return "" }
        throw failure
    }
    return text
}

func recognizeWithWhisper(_ wav: URL, model: URL, language: String, keepProcess: @escaping (Process) -> Void) throws -> String {
    guard let program = Bundle.main.url(forResource: "whisper-cli", withExtension: nil) else {
        throw TranscribeError.message(tr("whisper.cpp is missing from LINE MR.", "ไม่พบ whisper.cpp ใน LINE MR"))
    }
    let process = Process()
    process.executableURL = program
    process.arguments = ["-m", model.path, "-l", language, "-np", "-nt", "-t", String(max(2, ProcessInfo.processInfo.activeProcessorCount - 2)), "-f", wav.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    keepProcess(process)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationReason == .uncaughtSignal { return "" } // cancelled
    guard process.terminationStatus == 0 else {
        throw TranscribeError.message(tr("whisper.cpp could not convert this recording (is the model file complete?).",
                                         "whisper.cpp แปลงเสียงนี้ไม่ได้ (ไฟล์โมเดลครบหรือไม่)"))
    }
    return String(decoding: data, as: UTF8.self).split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !($0.hasPrefix("[") && $0.hasSuffix("]")) && !($0.hasPrefix("(") && $0.hasSuffix(")")) }
        .joined(separator: "\n")
}

// MARK: - The chooser and the window

final class TranscribeTextWindow: NSWindow {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class TranscribeJob: NSObject, NSWindowDelegate, URLSessionDownloadDelegate {
    static var current: TranscribeJob?
    static var handledURL = false

    static func handleURL() {
        handledURL = true
        if let job = current {
            job.announce(tr("A transcription is running.", "กำลังแปลงเสียงอยู่"))
            job.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let request = readTranscribeRequest() else {
            if !anythingElseRunning { exit(0) }
            return
        }
        let job = TranscribeJob(request)
        current = job
        job.begin()
    }
    private static var anythingElseRunning: Bool { current != nil }

    private let request: TranscribeRequest
    private var engine: SpeechEngine = .apple
    private var language = ""
    private var window: TranscribeTextWindow?
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let textView = NSTextView()
    private let copyButton = NSButton(title: tr("Copy", "คัดลอก"), target: nil, action: nil)
    private let closeButton = NSButton(title: tr("Cancel", "ยกเลิก"), target: nil, action: nil)
    private var download: URLSessionDownloadTask?
    private var downloadModel: SpeechModel?
    private var cancelled = false
    private var appleTask: SFSpeechRecognitionTask?
    private var whisperProcess: Process?
    private var models: [SpeechModel] = []

    init(_ request: TranscribeRequest) { self.request = request }

    private var kindName: String { request.isVideo ? tr("Video", "วิดีโอ") : tr("Voice message", "ข้อความเสียง") }

    private func lengthText() -> String {
        guard request.seconds >= 0 else { return "" }
        let m = request.seconds / 60, s = request.seconds % 60
        return m > 0 ? tr("\(m) min \(s) s", "\(m) นาที \(s) วินาที") : tr("\(s) seconds", "\(s) วินาที")
    }

    private func announce(_ text: String) {
        statusLabel.stringValue = text
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Choosing

    private func begin() {
        NSApp.activate(ignoringOtherApps: true)
        models = TranscribeStore.loadModels()
        guard let choice = choose() else { return finishAndQuit() }
        engine = choice.engine
        language = choice.language
        TranscribeStore.lastEngine = engine.id
        if case .file(let url) = engine { TranscribeStore.lastModelFile = url.path }
        TranscribeStore.setLastLanguage(language, apple: engine.isApple)
        showWindow()
        if case .model(let model) = engine, !model.isDownloaded { startDownload(model) } else { start() }
    }

    private func languages(apple: Bool) -> [(String, String)] {
        let common = apple
            ? [("th-TH", tr("Thai", "ไทย")), ("en-US", tr("English", "อังกฤษ")), ("ja-JP", tr("Japanese", "ญี่ปุ่น")),
               ("zh-CN", tr("Chinese (Simplified)", "จีนตัวย่อ")), ("zh-TW", tr("Chinese (Traditional)", "จีนตัวเต็ม"))]
            : [("auto", tr("Detect automatically", "ตรวจหาอัตโนมัติ")), ("th", tr("Thai", "ไทย")), ("en", tr("English", "อังกฤษ")),
               ("ja", tr("Japanese", "ญี่ปุ่น")), ("zh", tr("Chinese", "จีน"))]
        return common
    }

    private func defaultLanguage(apple: Bool) -> String {
        if let last = TranscribeStore.lastLanguage(apple: apple) { return last }
        guard apple else { return "auto" }
        let preferred = Locale.preferredLanguages
        if preferred.contains(where: { $0.hasPrefix("th") }) { return "th-TH" }
        for (id, _) in languages(apple: true) where preferred.first?.hasPrefix(String(id.prefix(2))) == true { return id }
        return "en-US"
    }

    private func choose() -> (engine: SpeechEngine, language: String)? {
        var engines: [SpeechEngine] = [.apple]
        var titles = [tr("Apple's speech recognition (nothing to download)", "ระบบรู้จำเสียงของ Apple (ไม่ต้องดาวน์โหลด)")]
        for model in models {
            engines.append(.model(model))
            let size = ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)
            titles.append(model.isDownloaded ? "\(model.name) (whisper.cpp)"
                                             : "\(model.name) (whisper.cpp, " + tr("downloads \(size)", "ดาวน์โหลด \(size)") + ")")
        }
        if let path = TranscribeStore.lastModelFile, FileManager.default.fileExists(atPath: path) {
            engines.append(.file(URL(fileURLWithPath: path)))
            titles.append((path as NSString).lastPathComponent + " (whisper.cpp)")
        }
        let browseTitle = tr("Browse for a model file…", "เลือกไฟล์โมเดล…")

        let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        enginePopup.addItems(withTitles: titles + [browseTitle])
        enginePopup.setAccessibilityLabel(tr("Speech model", "โมเดลเสียง"))
        let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        languagePopup.setAccessibilityLabel(tr("Language of the message", "ภาษาของข้อความ"))
        let note = NSTextField(wrappingLabelWithString: "")
        note.preferredMaxLayoutWidth = 400

        var selected = engines.firstIndex { $0.id == TranscribeStore.lastEngine } ?? 0
        enginePopup.selectItem(at: selected)
        var shownLanguages: [(String, String)] = []
        func refreshLanguages(keep: String?) {
            let apple = engines[selected].isApple
            shownLanguages = languages(apple: apple)
            languagePopup.removeAllItems()
            languagePopup.addItems(withTitles: shownLanguages.map { $0.1 })
            let wanted = keep ?? defaultLanguage(apple: apple)
            languagePopup.selectItem(at: shownLanguages.firstIndex { $0.0 == wanted } ?? 0)
            refreshNote()
        }
        func refreshNote() {
            var text = ""
            if engines[selected].isApple {
                let id = shownLanguages[languagePopup.indexOfSelectedItem].0
                if SFSpeechRecognizer(locale: Locale(identifier: id))?.supportsOnDeviceRecognition == false {
                    text = tr("This language is recognised by Apple's servers: the recording is sent to Apple.",
                              "ภาษานี้ประมวลผลที่เซิร์ฟเวอร์ของ Apple เสียงจะถูกส่งไปยัง Apple")
                } else {
                    text = tr("Recognised on this Mac; nothing is sent to the internet.", "ประมวลผลในเครื่องนี้ ไม่มีการส่งข้อมูลออกอินเทอร์เน็ต")
                }
            } else {
                text = tr("Converted on this Mac; nothing is sent to the internet.", "แปลงในเครื่องนี้ ไม่มีการส่งข้อมูลออกอินเทอร์เน็ต")
            }
            if request.seconds > 300 && !engines[selected].isApple {
                text += " " + tr("A long recording may take a while.", "การบันทึกยาวอาจใช้เวลานาน")
            }
            note.stringValue = text
            note.setAccessibilityLabel(text)
        }
        let actions = TranscribeChooserActions()
        actions.onEngine = {
            let index = enginePopup.indexOfSelectedItem
            if index == engines.count { // Browse
                let panel = NSOpenPanel()
                panel.message = tr("Choose a whisper.cpp model file (ggml .bin)", "เลือกไฟล์โมเดลของ whisper.cpp (ggml .bin)")
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url, TranscribeJob.isWhisperModel(url) {
                    if engines.last.map({ if case .file = $0 { return true } else { return false } }) == true {
                        engines.removeLast(); enginePopup.removeItem(at: engines.count)
                    }
                    engines.append(.file(url))
                    enginePopup.insertItem(withTitle: url.lastPathComponent + " (whisper.cpp)", at: engines.count - 1)
                    selected = engines.count - 1
                } else if panel.url != nil {
                    alert(tr("Not a whisper.cpp model", "ไม่ใช่โมเดลของ whisper.cpp"),
                          tr("Choose a ggml .bin file made for whisper.cpp.", "กรุณาเลือกไฟล์ ggml .bin สำหรับ whisper.cpp"))
                }
                enginePopup.selectItem(at: selected)
            } else {
                selected = index
            }
            refreshLanguages(keep: nil)
        }
        actions.onLanguage = { refreshNote() }
        enginePopup.target = actions; enginePopup.action = #selector(TranscribeChooserActions.engineChanged)
        languagePopup.target = actions; languagePopup.action = #selector(TranscribeChooserActions.languageChanged)
        refreshLanguages(keep: nil)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: tr("Speech model:", "โมเดลเสียง:")), enginePopup],
            [NSTextField(labelWithString: tr("Language:", "ภาษา:")), languagePopup],
        ])
        grid.rowSpacing = 8
        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(origin: .zero, size: NSSize(width: 460, height: 110))

        let alertBox = NSAlert()
        alertBox.messageText = tr("Convert to text", "แปลงเสียงเป็นข้อความ")
        alertBox.informativeText = [kindName, lengthText(), request.title].filter { !$0.isEmpty }.joined(separator: ", ")
        alertBox.accessoryView = stack
        alertBox.addButton(withTitle: tr("Convert", "แปลง"))
        alertBox.addButton(withTitle: tr("Cancel", "ยกเลิก"))
        alertBox.layout()
        alertBox.window.initialFirstResponder = enginePopup
        NSApp.activate(ignoringOtherApps: true)
        guard alertBox.runModal() == .alertFirstButtonReturn else { return nil }
        withExtendedLifetime(actions) {}
        return (engines[selected], shownLanguages[languagePopup.indexOfSelectedItem].0)
    }

    static func isWhisperModel(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 4) else { return false }
        return head == Data([0x6c, 0x6d, 0x67, 0x67]) // "ggml" as a little-endian word
    }

    // MARK: The window

    private func showWindow() {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        let w = TranscribeTextWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = [kindName, request.title].filter { !$0.isEmpty }.joined(separator: ", ")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.onEscape = { [weak w] in w?.performClose(nil) }

        progress.style = .bar
        progress.isIndeterminate = true
        progress.setAccessibilityLabel(tr("Progress", "ความคืบหน้า"))
        progress.startAnimation(nil)

        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(tr("Text of the recording", "ข้อความจากเสียง"))
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        copyButton.target = self; copyButton.action = #selector(copyText)
        copyButton.isHidden = true
        closeButton.target = self; closeButton.action = #selector(closeWindow)
        closeButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [copyButton, closeButton])
        buttons.orientation = .horizontal

        let content = NSStackView(views: [statusLabel, progress, scroll, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = NSView(frame: frame)
        w.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            content.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            content.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            progress.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
        ])
        textView.frame = NSRect(x: 0, y: 0, width: 530, height: 280)
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        announce(tr("Copied.", "คัดลอกแล้ว"))
    }

    @objc private func closeWindow() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) { finishAndQuit() }

    private func cancelWork() {
        cancelled = true
        download?.cancel()
        appleTask?.cancel()
        if whisperProcess?.isRunning == true { whisperProcess?.terminate() }
    }

    private func finishAndQuit() {
        cancelWork()
        try? FileManager.default.removeItem(at: request.file)
        running(lineID)?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    // MARK: Download

    private func startDownload(_ model: SpeechModel) {
        guard let url = URL(string: model.url), url.scheme == "https" else {
            return fail(tr("The model's address is not valid.", "ที่อยู่ของโมเดลไม่ถูกต้อง"))
        }
        announce(tr("Downloading \(model.name)…", "กำลังดาวน์โหลด \(model.name)…"))
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        downloadModel = model
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        download = session.downloadTask(with: url)
        download?.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let model = downloadModel else { return }
        let percent = Double(totalBytesWritten) / Double(max(model.size, 1)) * 100
        progress.doubleValue = percent
        statusLabel.stringValue = tr("Downloading \(model.name): \(Int(percent))%", "กำลังดาวน์โหลด \(model.name): \(Int(percent))%")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = downloadModel else { return }
        // The temporary file disappears when this returns.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: kept) } catch { return fail(error.localizedDescription) }
        session.finishTasksAndInvalidate()
        statusLabel.stringValue = tr("Checking the download…", "กำลังตรวจสอบไฟล์ที่ดาวน์โหลด…")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let valid = Self.sha256(kept) == model.sha256.lowercased()
            DispatchQueue.main.async { [self] in
                guard valid else {
                    try? FileManager.default.removeItem(at: kept)
                    return fail(tr("The download was damaged. Try again.", "ไฟล์ที่ดาวน์โหลดเสียหาย กรุณาลองใหม่"))
                }
                do {
                    try FileManager.default.createDirectory(at: TranscribeStore.modelsFolder, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: model.localURL)
                    try FileManager.default.moveItem(at: kept, to: model.localURL)
                } catch { return fail(error.localizedDescription) }
                start()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, !cancelled { fail(error.localizedDescription) }
    }

    private static func sha256(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Converting

    private func start() {
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = 0
        announce(tr("Converting…", "กำลังแปลงเสียง…"))
        guard engine.isApple else { return convert() }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { [self] in
                guard status == .authorized else {
                    return fail(tr("LINE MR may not use speech recognition. Allow it in System Settings, Privacy & Security, Speech Recognition, or choose a whisper.cpp model.",
                                   "LINE MR ยังไม่ได้รับอนุญาตให้ใช้การรู้จำเสียง กรุณาอนุญาตที่ การตั้งค่าระบบ > ความเป็นส่วนตัวและความปลอดภัย > การรู้จำเสียง หรือเลือกโมเดล whisper.cpp"))
                }
                convert()
            }
        }
    }

    private func convert() {
        let file = request.file, engine = self.engine, language = self.language
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("linemr-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let pieces = cutAtPauses(try loadSamples(file))
                for (index, piece) in pieces.enumerated() where !cancelled {
                    let wav = folder.appendingPathComponent("\(index).wav")
                    try writeWAV(piece, to: wav)
                    let text: String
                    switch engine {
                    case .apple:
                        text = try recognizeWithApple(wav, locale: language) { task in DispatchQueue.main.async { self.appleTask = task } }
                    case .model(let model):
                        text = try recognizeWithWhisper(wav, model: model.localURL, language: language) { p in DispatchQueue.main.async { self.whisperProcess = p } }
                    case .file(let url):
                        text = try recognizeWithWhisper(wav, model: url, language: language) { p in DispatchQueue.main.async { self.whisperProcess = p } }
                    }
                    try? FileManager.default.removeItem(at: wav)
                    DispatchQueue.main.async { [self] in
                        append(text)
                        progress.doubleValue = Double(index + 1) / Double(pieces.count) * 100
                    }
                }
                DispatchQueue.main.async { [self] in if !cancelled { done() } }
            } catch {
                DispatchQueue.main.async { [self] in if !cancelled { fail(error.localizedDescription) } }
            }
        }
    }

    /// New lines go at the end; the caret, the selection and the user's edits stay as they are.
    private func append(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let storage = textView.textStorage else { return }
        let prefix = storage.length > 0 ? "\n" : ""
        let attributes: [NSAttributedString.Key: Any] = [.font: textView.font as Any, .foregroundColor: NSColor.textColor]
        storage.append(NSAttributedString(string: prefix + line, attributes: attributes))
    }

    private func done() {
        progress.isHidden = true
        copyButton.isHidden = false
        closeButton.title = tr("Close", "ปิด")
        if textView.string.isEmpty {
            announce(tr("No speech was found in this recording.", "ไม่พบเสียงพูดในไฟล์นี้"))
        } else {
            announce(tr("Done.", "แปลงเสร็จแล้ว"))
        }
        try? FileManager.default.removeItem(at: request.file)
    }

    private func fail(_ message: String) {
        progress.isHidden = true
        closeButton.title = tr("Close", "ปิด")
        log("transcribe failed: \(message)")
        announce(message)
    }
}

final class TranscribeChooserActions: NSObject {
    var onEngine: (() -> Void)?
    var onLanguage: (() -> Void)?
    @objc func engineChanged() { onEngine?() }
    @objc func languageChanged() { onLanguage?() }
}

/// An accessory app has no menu bar of its own: without these items Command+C / V / A do nothing.
func installEditMenu() {
    let main = NSMenu()
    let editItem = NSMenuItem()
    main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    editItem.submenu = edit
    NSApp.mainMenu = main
}

final class TranscribeURLHandler: NSObject {
    @objc func handle(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text), url.scheme == "linemr", url.host == "transcribe" else { return }
        TranscribeJob.handleURL()
    }
}
