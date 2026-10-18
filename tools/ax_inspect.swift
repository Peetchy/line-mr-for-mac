// ax_inspect: dump the live AXUIElement tree of LINE.app and optionally press an element.
//
// Usage:
//   ax_inspect [--pid PID] [--bundle-id ID] [--depth N] [--wait SECONDS] [--press TITLE [--nth N] [--prefix]]
//
// Each element is printed on one line:
//   <indent>role=AXButton subrole=- title="Log in" desc="" val="" actions=[AXPress]
// The AXMenuBar subtree is skipped. --press performs kAXPressAction on the first element whose
// title, description or value equals TITLE (or the N-th such element, 1-based, with --nth) and
// exits 0 on success. With --prefix, TITLE only has to be a prefix of the title, description or value.

import AppKit
import ApplicationServices
import Foundation

struct Options {
    var pid: pid_t?
    var bundleId = "jp.naver.line.mac"
    var maxDepth = 60
    var waitSeconds = 0.0
    var pressTitle: String?
    var pressNth = 1
    var pressPrefix = false
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func parseOptions() -> Options {
    var opts = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        func value() -> String {
            guard let v = args.next() else { fail("missing value for \(arg)", code: 64) }
            return v
        }
        switch arg {
        case "--pid":
            guard let p = Int32(value()) else { fail("--pid expects a number", code: 64) }
            opts.pid = p
        case "--bundle-id": opts.bundleId = value()
        case "--depth":
            guard let d = Int(value()) else { fail("--depth expects a number", code: 64) }
            opts.maxDepth = d
        case "--wait":
            guard let w = Double(value()) else { fail("--wait expects seconds", code: 64) }
            opts.waitSeconds = w
        case "--press": opts.pressTitle = value()
        case "--nth":
            guard let n = Int(value()), n >= 1 else { fail("--nth expects a number >= 1", code: 64) }
            opts.pressNth = n
        case "--prefix": opts.pressPrefix = true
        case "-h", "--help":
            print("usage: ax_inspect [--pid PID] [--bundle-id ID] [--depth N] [--wait SECONDS] [--press TITLE [--nth N] [--prefix]]")
            exit(0)
        default: fail("unknown argument: \(arg)", code: 64)
        }
    }
    return opts
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func describe(_ value: AnyObject?) -> String {
    guard let value = value else { return "" }
    if let s = value as? String { return s }
    if CFGetTypeID(value) == CFBooleanGetTypeID() { return (value as! Bool) ? "true" : "false" }
    if let n = value as? NSNumber { return n.stringValue }
    if let url = value as? URL { return url.absoluteString }
    if CFGetTypeID(value) == AXValueGetTypeID() {
        let axValue = value as! AXValue
        switch AXValueGetType(axValue) {
        case .cgPoint:
            var p = CGPoint.zero
            AXValueGetValue(axValue, .cgPoint, &p)
            return "(\(Int(p.x)),\(Int(p.y)))"
        case .cgSize:
            var s = CGSize.zero
            AXValueGetValue(axValue, .cgSize, &s)
            return "\(Int(s.width))x\(Int(s.height))"
        case .cfRange:
            var r = CFRange()
            AXValueGetValue(axValue, .cfRange, &r)
            return "{\(r.location),\(r.length)}"
        default:
            return "<AXValue>"
        }
    }
    return String(describing: value)
}

func quoted(_ s: String, limit: Int = 200) -> String {
    var t = s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    if t.count > limit { t = String(t.prefix(limit)) + "…" }
    return "\"\(t)\""
}

func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
    return list
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    guard let value = attribute(element, kAXChildrenAttribute as String) else { return [] }
    return (value as? [AXUIElement]) ?? []
}

struct Node {
    let element: AXUIElement
    let role, subrole, title, desc, val: String
    let actions: [String]
}

func node(_ element: AXUIElement) -> Node {
    Node(element: element,
         role: describe(attribute(element, kAXRoleAttribute as String)),
         subrole: describe(attribute(element, kAXSubroleAttribute as String)),
         title: describe(attribute(element, kAXTitleAttribute as String)),
         desc: describe(attribute(element, kAXDescriptionAttribute as String)),
         val: describe(attribute(element, kAXValueAttribute as String)),
         actions: actions(element))
}

// Depth-first walk; `visit` returns false to stop the walk.
func walk(_ element: AXUIElement, depth: Int, maxDepth: Int, seen: inout Set<UInt>,
          visit: (Node, Int) -> Bool) -> Bool {
    // CFHash collisions are possible, so only use it to break genuine cycles along a path.
    let key: UInt = CFHash(element)
    if seen.contains(key) { return true }
    seen.insert(key)
    defer { seen.remove(key) }
    let n = node(element)
    if n.role == (kAXMenuBarRole as String) { return true }
    if !visit(n, depth) { return false }
    guard depth < maxDepth else { return true }
    for child in children(element) {
        if !walk(child, depth: depth + 1, maxDepth: maxDepth, seen: &seen, visit: visit) { return false }
    }
    return true
}

let opts = parseOptions()

if !AXIsProcessTrusted() {
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(prompt)
    fail("""
         error: this process is not trusted for accessibility.
         Grant access in System Settings > Privacy & Security > Accessibility for the app running
         ax_inspect (e.g. Terminal), then run again.
         """, code: 2)
}

func findPid() -> pid_t? {
    if let pid = opts.pid { return pid }
    return NSRunningApplication.runningApplications(withBundleIdentifier: opts.bundleId).first?.processIdentifier
}

let deadline = Date().addingTimeInterval(opts.waitSeconds)
var pidFound = findPid()
while pidFound == nil && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.5)
    pidFound = findPid()
}
guard let pid = pidFound else { fail("error: \(opts.bundleId) is not running", code: 3) }

let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3.0)

// Qt's Cocoa accessibility initialises lazily on the first kAXChildrenAttribute query, so poll
// the application's children until some AXWindow has a populated subtree.
func hasPopulatedWindow() -> Bool {
    children(app).contains { element in
        describe(attribute(element, kAXRoleAttribute as String)) == (kAXWindowRole as String)
            && !children(element).isEmpty
    }
}
if opts.waitSeconds > 0 {
    while !hasPopulatedWindow() && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.5)
    }
} else if !hasPopulatedWindow() {
    // Warm-up: the query above woke Qt's AX bridge; give it a moment before walking.
    Thread.sleep(forTimeInterval: 0.2)
}

var seen = Set<UInt>()

if let target = opts.pressTitle {
    var found: Node?
    var matches = 0
    _ = walk(app, depth: 0, maxDepth: opts.maxDepth, seen: &seen) { n, _ in
        let fields = [n.title, n.desc, n.val]
        if opts.pressPrefix ? fields.contains(where: { !$0.isEmpty && $0.hasPrefix(target) }) : fields.contains(target) {
            matches += 1
            if matches == opts.pressNth {
                found = n
                return false
            }
        }
        return true
    }
    guard let n = found else { fail("error: no element titled \(quoted(target))", code: 4) }
    let result = AXUIElementPerformAction(n.element, kAXPressAction as CFString)
    if result == .success {
        print("pressed role=\(n.role) title=\(quoted(n.title)) desc=\(quoted(n.desc))")
        exit(0)
    }
    fail("error: AXPress on \(quoted(target)) failed with AXError \(result.rawValue)", code: 5)
}

var count = 0
_ = walk(app, depth: 0, maxDepth: opts.maxDepth, seen: &seen) { n, depth in
    count += 1
    let indent = String(repeating: "  ", count: depth)
    print("\(indent)role=\(n.role.isEmpty ? "-" : n.role) subrole=\(n.subrole.isEmpty ? "-" : n.subrole) "
        + "title=\(quoted(n.title)) desc=\(quoted(n.desc)) val=\(quoted(n.val)) "
        + "actions=[\(n.actions.joined(separator: ","))]")
    return true
}
FileHandle.standardError.write("\(count) elements (pid \(pid))\n".data(using: .utf8)!)
