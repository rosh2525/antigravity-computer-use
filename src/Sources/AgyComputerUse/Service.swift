import AppKit
import ApplicationServices

enum ServiceMain {
    static func run() {
        if let fd = ServiceClient.connectOnce() {
            close(fd)
            FileHandle.standardError.write("Computer Use service is already running.\n".data(using: .utf8)!)
            exit(0)
        }
        Log.toFile = true
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ServiceAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class ServiceAppDelegate: NSObject, NSApplicationDelegate {
    private var server: SocketServer?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Antigravity Computer Use service")
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.5)
        Overlay.shared.onEscape = { Service.shared.cancelByUser() }
        let server = SocketServer(path: Paths.socketPath) { Service.shared.handle($0) }
        do {
            try server.start()
            self.server = server
            Log.info("service started pid=\(getpid()) ax=\(Permissions.accessibility) screen=\(Permissions.screenRecording)")
        } catch {
            Log.info("could not start socket server: \(error)")
            NSApp.terminate(nil)
        }
        if !Permissions.accessibility || !Permissions.screenRecording {
            // Registers this exact build with TCC (adds it to the Accessibility list) and shows the system prompt.
            if !Permissions.accessibility { Permissions.promptAccessibility() }
            if !Permissions.screenRecording { CGRequestScreenCaptureAccess() }
            PermissionsWindow.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PermissionsWindow.shared.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        unlink(Paths.socketPath)
    }
}

final class Service {
    static let shared = Service()

    private let toolLock = NSLock()
    private let stateLock = NSLock()
    private var snapshots: [pid_t: AppSnapshot] = [:]
    private var lastAction: [pid_t: Date] = [:]
    private var accessibilityEnabled: Set<pid_t> = []
    private var cancelled = false

    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "com.brave.Browser",
        "com.microsoft.edgemac", "org.chromium.Chromium", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
        "com.operasoftware.Opera",
    ]
    /// Firefox-family apps only build their accessibility tree once an assistive client sets
    /// AXEnhancedUserInterface; without it the window shows nothing but its title-bar buttons.
    static let gecko: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "org.mozilla.thunderbird", "io.gitlab.librewolf-community", "app.zen-browser.zen", "net.waterfox.waterfox",
    ]

    var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelled
    }

    // MARK: Requests

    func handle(_ req: [String: Any]) -> [String: Any] {
        switch req["kind"] as? String ?? "" {
        case "tool":
            let name = req["tool"] as? String ?? ""
            let args = req["args"] as? [String: Any] ?? [:]
            return runTool(name, args).json
        case "turn_ended":
            turnEnded()
            return ["ok": true]
        case "status":
            return status()
        case "show_permissions":
            PermissionsWindow.shared.show()
            return status()
        case "reset_approvals":
            Approvals.shared.reset()
            return ["ok": true, "approvals": Approvals.shared.summary]
        case "shutdown":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return ["ok": true]
        default:
            return ["error": "Unknown request."]
        }
    }

    func status() -> [String: Any] {
        stateLock.lock(); defer { stateLock.unlock() }
        return [
            "running": true, "pid": Int(getpid()), "version": MCPServer.serverVersion,
            "permissions": Permissions.status, "approvals": Approvals.shared.summary,
            "cancelled": cancelled, "screenLocked": Self.screenLocked, "trackedApps": snapshots.count,
            "dataDir": Paths.dataDir.path,
        ]
    }

    func turnEnded() {
        stateLock.lock()
        cancelled = false
        snapshots.removeAll()
        stateLock.unlock()
        Approvals.shared.turnEnded()
        Overlay.shared.hide()
    }

    func idleReset() {
        stateLock.lock(); cancelled = false; stateLock.unlock()
    }

    func cancelByUser() {
        stateLock.lock(); cancelled = true; stateLock.unlock()
        Log.info("cancelled by Esc")
        Overlay.shared.flash("Computer use stopped", hint: "Esc pressed")
    }

    static var screenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true { return true }
        if let onConsole = d["kCGSSessionOnConsoleKey"] as? NSNumber, !onConsole.boolValue { return true }
        return false
    }

    private func preflight() throws {
        if Self.screenLocked {
            throw ToolError("The screen is locked, so Computer Use is paused. Ask the user to unlock their Mac, then retry.")
        }
        if isCancelled {
            throw ToolError("The user pressed Esc to stop Computer Use. Do not use the computer again this turn; tell the user where you stopped and wait for their instructions.")
        }
        if !Permissions.accessibility {
            PermissionsWindow.shared.show()
            throw ToolError("Accessibility permission is missing. A setup window is open: ask the user to allow “Antigravity Computer Use” in System Settings → Privacy & Security → Accessibility, then retry.")
        }
        Overlay.shared.touch()
    }

    private func runTool(_ name: String, _ args: [String: Any]) -> ToolResult {
        toolLock.lock(); defer { toolLock.unlock() }
        let started = Date()
        do {
            if name != "list_apps" { try preflight() }
            let result = try dispatch(name, args)
            Log.info("\(name) ok in \(Int(Date().timeIntervalSince(started) * 1000))ms")
            return result
        } catch let e as ToolError {
            Log.info("\(name) error: \(e.message)")
            return .error(e.message)
        } catch {
            Log.info("\(name) error: \(error)")
            return .error("\(error)")
        }
    }

    private func dispatch(_ name: String, _ args: [String: Any]) throws -> ToolResult {
        switch name {
        case "list_apps": return listApps()
        case "get_app_state": return try getAppState(args)
        case "click": return try click(args)
        case "drag": return try drag(args)
        case "paste": return try paste(args)
        case "perform_secondary_action": return try secondaryAction(args)
        case "press_key": return try pressKey(args)
        case "scroll": return try scroll(args)
        case "select_text": return try selectText(args)
        case "set_value": return try setValue(args)
        case "type_text": return try typeText(args)
        case "_debug_dump": return try debugDump(args)
        default: throw ToolError("Unknown tool \(name).")
        }
    }

    // MARK: Helpers

    private func target(_ args: [String: Any]) throws -> ResolvedApp {
        var app = try AppResolver.locate(try args.requireString("app"))
        try Approvals.shared.check(app)
        try AppResolver.ensureRunning(&app)
        return app
    }

    private func snapshot(_ pid: pid_t) -> AppSnapshot? {
        stateLock.lock(); defer { stateLock.unlock() }
        return snapshots[pid]
    }

    private func snapshotCreating(_ pid: pid_t) -> AppSnapshot {
        stateLock.lock(); defer { stateLock.unlock() }
        if let s = snapshots[pid] { return s }
        let s = AppSnapshot(pid: pid)
        snapshots[pid] = s
        return s
    }

    private func entry(_ app: ResolvedApp, _ index: Int) throws -> TreeEntry {
        guard let snap = snapshot(app.pid), !snap.entries.isEmpty else {
            throw ToolError("No state for \(app.name) yet. Call get_app_state for it first.")
        }
        guard let e = snap.byIndex[index] else {
            throw ToolError("Element \(index) is not in the latest get_app_state output for \(app.name). Call get_app_state and use a current index.")
        }
        if AX.raw(e.element, kAXRoleAttribute) == nil {
            throw ToolError("Element \(index) no longer exists (the UI changed). Call get_app_state again.")
        }
        return e
    }

    private func shotPoint(_ app: ResolvedApp, _ x: Double, _ y: Double) throws -> CGPoint {
        guard let shot = snapshot(app.pid)?.shot else {
            throw ToolError("No screenshot for \(app.name) yet. Call get_app_state first; x/y are pixels in that screenshot.")
        }
        guard x >= -1, y >= -1, x <= Double(shot.pixelWidth) + 1, y <= Double(shot.pixelHeight) + 1 else {
            throw ToolError("(\(x), \(y)) is outside the \(shot.pixelWidth)×\(shot.pixelHeight) screenshot.")
        }
        return shot.toGlobal(x: x, y: y)
    }

    private func center(of e: TreeEntry) throws -> CGPoint {
        guard var f = AX.frame(e.element) ?? e.frame, f.width > 0 || f.height > 0 else {
            throw ToolError("Element has no on-screen position; try perform_secondary_action or keyboard navigation.")
        }
        if let w = AX.element(e.element, kAXWindowAttribute).flatMap(AX.frame) {
            let visible = f.intersection(w)
            if !visible.isNull && visible.width > 0 && visible.height > 0 { f = visible }
        }
        return CGPoint(x: f.midX, y: f.midY)
    }

    private func acted(_ pid: pid_t, at point: CGPoint? = nil) {
        stateLock.lock(); lastAction[pid] = Date(); stateLock.unlock()
        if let p = point { Overlay.shared.pulse(at: p) }
    }

    private func enableAccessibility(_ app: ResolvedApp, _ el: AXUIElement) {
        stateLock.lock()
        let first = !accessibilityEnabled.contains(app.pid)
        accessibilityEnabled.insert(app.pid)
        stateLock.unlock()
        guard first else { return }
        var changed = AX.set(el, "AXManualAccessibility", kCFBooleanTrue) == .success
        let gecko = Self.gecko.contains(app.bundleID) || app.bundleID.hasPrefix("org.mozilla.")
        if Self.chromium.contains(app.bundleID) || gecko {
            changed = AX.set(el, "AXEnhancedUserInterface", kCFBooleanTrue) == .success || changed
        }
        guard changed else { return }
        // Gecko builds its tree lazily after the switch; wait until the window has real content.
        let deadline = Date().addingTimeInterval(gecko ? 4 : 0.8)
        repeat {
            usleep(200_000)
            let w = AX.element(el, kAXFocusedWindowAttribute) ?? AX.elements(el, kAXWindowsAttribute).first
            if !gecko || w.map({ AX.count($0, kAXChildrenAttribute) > 4 }) ?? true { break }
        } while Date() < deadline
    }

    // MARK: Tools

    /// Unfiltered raw AX dump for diagnosing apps whose tree comes back empty (not exposed over MCP).
    private func debugDump(_ args: [String: Any]) throws -> ToolResult {
        let app = try target(args)
        let appEl = AXUIElementCreateApplication(app.pid)
        enableAccessibility(app, appEl)
        let maxDepth = args.int("depth") ?? 6
        var lines: [String] = []
        func dump(_ el: AXUIElement, _ d: Int) {
            if lines.count > 400 { return }
            let n = TreeBuilder.info(el)
            let kids = AX.elements(el, kAXChildrenAttribute)
            lines.append(String(repeating: "  ", count: d) + "\(n.role)\(n.subrole.map { "/" + $0 } ?? "") title=\(n.title ?? "-") desc=\(n.desc ?? "-") frame=\(n.frame.map { "\($0)" } ?? "-") kids=\(kids.count) attrsCount=\(AX.count(el, kAXChildrenAttribute))")
            if d < maxDepth { for k in kids { dump(k, d + 1) } }
        }
        var names: CFArray?
        AXUIElementCopyAttributeNames(appEl, &names)
        lines.append("app attrs: \((names as? [String])?.joined(separator: ",") ?? "-")")
        for w in AX.elements(appEl, kAXWindowsAttribute) {
            var wn: CFArray?
            AXUIElementCopyAttributeNames(w, &wn)
            lines.append("window attrs: \((wn as? [String])?.joined(separator: ",") ?? "-")")
            dump(w, 0)
        }
        return .text(lines.joined(separator: "\n"))
    }

    private func listApps() -> ToolResult {
        let rows = AppResolver.listApps()
        let lines = rows.map { String(data: jsonData($0), encoding: .utf8) ?? "{}" }
        return .text("[\n" + lines.joined(separator: ",\n") + "\n]")
    }

    private func getAppState(_ args: [String: Any]) throws -> ToolResult {
        let app = try target(args)
        let disableDiff = args.bool("disableDiff") ?? args.bool("disable_diff") ?? false
        let appEl = AXUIElementCreateApplication(app.pid)
        enableAccessibility(app, appEl)

        stateLock.lock()
        let last = lastAction[app.pid]
        stateLock.unlock()
        var sinceAction = last.map { Date().timeIntervalSince($0) } ?? 999
        if sinceAction < 1.0 {
            usleep(useconds_t((1.0 - sinceAction) * 1_000_000))
            sinceAction = 1.0
        }

        var builder = TreeBuilder()
        builder.build(app: appEl)
        if sinceAction < 6 {
            let deadline = Date().addingTimeInterval(4)
            while builder.busy && Date() < deadline {
                usleep(500_000)
                let next = TreeBuilder()
                next.build(app: appEl)
                let same = next.entries.map(\.body) == builder.entries.map(\.body)
                builder = next
                if same && !builder.busy { break }
            }
        }

        let snap = snapshotCreating(app.pid)
        let hadBaseline = !snap.bodies.isEmpty
        let (entries, added, changed, removed) = snap.absorb(builder.entries)

        // Header
        var header: [String] = []
        var flags: [String] = []
        if app.running?.isActive == true { flags.append("frontmost") }
        if app.running?.isHidden == true { flags.append("hidden") }
        header.append("App: \(app.name) — \(app.bundleID) (pid \(app.pid))" + (flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"))

        let focusedWindow = AX.element(appEl, kAXFocusedWindowAttribute)
        let windows = AX.elements(appEl, kAXWindowsAttribute)
        if windows.isEmpty {
            header.append("Windows: none open. Use the menu bar items below or a shortcut like super+n to open one.")
        } else {
            let desc = windows.prefix(6).map { w -> String in
                var d = (AX.string(w, kAXTitleAttribute)).map { $0.isEmpty ? "untitled" : "\"\($0)\"" } ?? "untitled"
                var f: [String] = []
                if let fw = focusedWindow, CFEqual(fw, w) { f.append("focused") }
                if AX.bool(w, kAXMinimizedAttribute) == true { f.append("minimized") }
                if !f.isEmpty { d += " (\(f.joined(separator: ", ")))" }
                return d
            }
            header.append("Windows: " + desc.joined(separator: "; "))
        }
        if let focused = AX.element(appEl, kAXFocusedUIElementAttribute),
           let match = entries.first(where: { CFEqual($0.element, focused) }) {
            header.append("Focused element: \(match.index)")
        }

        var result = ToolResult()
        let shotResult = Capture.captureApp(pid: app.pid, preferredFrame: focusedWindow.flatMap(AX.frame))
        switch shotResult {
        case .success(let shot):
            snap.shot = shot.mapping
            let title = shot.mapping.windowTitle.isEmpty ? "" : " of \"\(shot.mapping.windowTitle)\""
            header.append("Screenshot: \(shot.mapping.pixelWidth)×\(shot.mapping.pixelHeight) px\(title). Coordinate arguments (x, y) are pixels in this image.")
        case .failure(let err):
            snap.shot = nil
            header.append("Screenshot: unavailable — \(err.message)")
        }

        // Body
        var body: [String] = []
        let changes = added.count + changed.count + removed.count
        if !hadBaseline || disableDiff || changes > max(80, entries.count * 6 / 10) {
            if hadBaseline && !disableDiff { body.append("(Full tree: too many changes for a diff.)") }
            for e in entries {
                var line = String(repeating: "\t", count: e.depth) + "\(e.index) \(e.body)"
                if let hidden = builder.offscreen[e.key], hidden > 0 { line += " (+\(hidden) more outside the visible area; scroll to reveal)" }
                body.append(line)
            }
            if entries.isEmpty {
                body.append("(No accessibility elements found. The app may not expose accessibility info; rely on the screenshot and coordinate actions.)")
            }
        } else if changes == 0 {
            body.append("No changes in the accessibility tree since the last get_app_state call; all indexes are unchanged.")
        } else {
            body.append("Changes since the last get_app_state call (+ added, ~ changed, - removed; unchanged elements keep their indexes):")
            let addedKeys = Set(added.map(\.key)), changedKeys = Set(changed.map(\.key))
            let indexByKey = Dictionary(entries.map { ($0.key, $0.index) }, uniquingKeysWith: { a, _ in a })
            for e in entries where addedKeys.contains(e.key) || changedKeys.contains(e.key) {
                var line = (addedKeys.contains(e.key) ? "+ " : "~ ") + "\(e.index) \(e.body)"
                if addedKeys.contains(e.key), let p = e.parentKey, let pi = indexByKey[p] { line += "  (in \(pi))" }
                body.append(line)
            }
            for r in removed { body.append("- \(r.0) \(r.1)") }
        }
        if builder.truncated {
            body.append("(Tree truncated after \(builder.maxNodes) nodes. Scroll, close panels, or use the screenshot for the rest.)")
        }

        result.addText(header.joined(separator: "\n") + "\n\n" + body.joined(separator: "\n"))
        if case .success(let shot) = shotResult { result.addImage(shot.data, mimeType: shot.mimeType) }
        return result
    }

    private func click(_ args: [String: Any]) throws -> ToolResult {
        let app = try target(args)
        let button = try Events.Button(args.string("mouse_button"))
        let count = max(1, min(args.int("click_count") ?? 1, 3))
        let flags = try KeySyntax.modifierFlags(args.string("key"))
        let hold = args.double("duration")

        if let index = args.int("element_index") {
            let e = try entry(app, index)
            let plain = button == .left && count == 1 && flags.isEmpty && hold == nil
            if plain {
                if e.actions.contains("AXPress") {
                    let err = AX.perform(e.element, "AXPress")
                    if err == .success || err == .cannotComplete {
                        acted(app.pid, at: try? center(of: e))
                        return .text("Clicked element \(index) (AXPress).")
                    }
                }
                if ["AXRow", "AXCell", "AXOutlineRow"].contains(e.role), AX.isSettable(e.element, kAXSelectedAttribute),
                   AX.set(e.element, kAXSelectedAttribute, kCFBooleanTrue) == .success {
                    acted(app.pid, at: try? center(of: e))
                    return .text("Selected element \(index).")
                }
                if ["AXTextField", "AXTextArea", "AXComboBox"].contains(e.role), AX.isSettable(e.element, kAXFocusedAttribute),
                   AX.set(e.element, kAXFocusedAttribute, kCFBooleanTrue) == .success {
                    acted(app.pid, at: try? center(of: e))
                    return .text("Focused element \(index) (text input).")
                }
            }
            if button == .right && count == 1 && flags.isEmpty && e.actions.contains("AXShowMenu") {
                let err = AX.perform(e.element, "AXShowMenu")
                if err == .success || err == .cannotComplete {
                    acted(app.pid, at: try? center(of: e))
                    return .text("Opened the context menu of element \(index). Call get_app_state to see it.")
                }
            }
            let p = try center(of: e)
            Events.click(pid: app.pid, at: p, button: button, count: count, flags: flags, hold: hold)
            acted(app.pid, at: p)
            return .text("Clicked element \(index) at its center (\(button.rawValue), \(count)×).")
        }
        guard let x = args.double("x"), let y = args.double("y") else {
            throw ToolError("Provide element_index, or both x and y (screenshot pixels).")
        }
        let p = try shotPoint(app, x, y)
        if button == .left && flags.isEmpty && hold == nil, let how = axClick(app.pid, at: p, count: count) {
            acted(app.pid, at: p)
            return .text("Clicked (\(Int(x)), \(Int(y))): \(how).")
        }
        Events.click(pid: app.pid, at: p, button: button, count: count, flags: flags, hold: hold)
        acted(app.pid, at: p)
        return .text("Clicked (\(Int(x)), \(Int(y))) (\(button.rawValue), \(count)×) with raw mouse events. Some apps ignore those while in the background; check get_app_state.")
    }

    // MARK: Accessibility hit-testing for coordinate actions (background-safe)

    private func element(at p: CGPoint, _ pid: pid_t) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(p.x), Float(p.y), &hit) == .success else { return nil }
        return hit
    }

    private func textIndex(_ el: AXUIElement, at p: CGPoint) -> Int? {
        var point = p
        guard let pv = AXValueCreate(.cgPoint, &point) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXRangeForPositionParameterizedAttribute as CFString, pv, &out) == .success,
              let r = AX.range(out) else { return nil }
        return r.location
    }

    private func setSelection(_ el: AXUIElement, _ loc: Int, _ len: Int) -> Bool {
        var r = CFRange(location: loc, length: len)
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        AX.set(el, kAXFocusedAttribute, kCFBooleanTrue)
        return AX.set(el, kAXSelectedTextRangeAttribute, v) == .success
    }

    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    /// Handles a plain left click at a global point without mouse events. Returns a description, or nil.
    private func axClick(_ pid: pid_t, at p: CGPoint, count: Int) -> String? {
        guard var el = element(at: p, pid) else { return nil }
        let role = AX.string(el, kAXRoleAttribute) ?? ""
        if Self.textRoles.contains(role), let idx = textIndex(el, at: p) {
            let text = (AX.string(el, kAXValueAttribute) ?? "") as NSString
            switch count {
            case 2:
                var start = idx, end = idx
                let word = CharacterSet.alphanumerics
                func isWord(_ i: Int) -> Bool { i >= 0 && i < text.length && UnicodeScalar(text.character(at: i)).map { word.contains($0) } == true }
                while isWord(start - 1) { start -= 1 }
                while isWord(end) { end += 1 }
                return setSelection(el, start, end - start) ? "selected the word \"\(text.substring(with: NSRange(location: start, length: end - start)))\"" : nil
            case 3:
                let line = text.lineRange(for: NSRange(location: min(idx, max(0, text.length - 1)), length: 0))
                return setSelection(el, line.location, line.length) ? "selected the line" : nil
            default:
                return setSelection(el, idx, 0) ? "placed the caret at character \(idx)" : nil
            }
        }
        guard count == 1 else { return nil }
        for _ in 0..<4 {
            if AX.actions(el).contains(kAXPressAction) {
                let err = AX.perform(el, kAXPressAction)
                if err == .success || err == .cannotComplete {
                    return "pressed the \(AX.string(el, kAXRoleDescriptionAttribute) ?? "element")" + (AX.string(el, kAXTitleAttribute).map { " \"\($0)\"" } ?? AX.string(el, kAXDescriptionAttribute).map { " \"\($0)\"" } ?? "")
                }
                return nil
            }
            guard let parent = AX.element(el, kAXParentAttribute),
                  ["AXStaticText", "AXImage", "AXGroup"].contains(AX.string(el, kAXRoleAttribute) ?? "") else { return nil }
            el = parent
        }
        return nil
    }

    private func drag(_ args: [String: Any]) throws -> ToolResult {
        let app = try target(args)
        guard let fx = args.double("from_x"), let fy = args.double("from_y"),
              let tx = args.double("to_x"), let ty = args.double("to_y") else {
            throw ToolError("drag needs from_x, from_y, to_x and to_y (screenshot pixels).")
        }
        let from = try shotPoint(app, fx, fy), to = try shotPoint(app, tx, ty)
        Overlay.shared.pulse(at: from)
        // Text selection drags are done through accessibility so they work in the background.
        if let el = element(at: from, app.pid), Self.textRoles.contains(AX.string(el, kAXRoleAttribute) ?? ""),
           let a = textIndex(el, at: from), let b = textIndex(el, at: to), setSelection(el, min(a, b), abs(b - a)) {
            acted(app.pid, at: to)
            return .text("Dragged from (\(Int(fx)), \(Int(fy))) to (\(Int(tx)), \(Int(ty))): selected \(abs(b - a)) characters.")
        }
        Events.drag(pid: app.pid, from: from, to: to)
        acted(app.pid, at: to)
        return .text("Dragged from (\(Int(fx)), \(Int(fy))) to (\(Int(tx)), \(Int(ty))).")
    }

    private func paste(_ args: [String: Any]) throws -> ToolResult {
        let app = try target(args)
        guard let text = args.string("text") else { throw ToolError("Missing `text`.") }
        let format = args.string("format") ?? "text"
        let focused = focusedElement(app.pid)
        let before = focused.flatMap { AX.string($0, kAXValueAttribute) }
        let saved = Clipboard.save()
        defer { Clipboard.restore(saved) }
        try Clipboard.write(text, format: format)
        let pasteCombo = KeyCombo(keyCode: 9, flags: .maskCommand, modifierKeyCodes: [(55, .maskCommand)])
        if pressMenuShortcut(app.pid, pasteCombo) == nil {
            Events.press(pid: app.pid, pasteCombo)
        }
        usleep(300_000)
        acted(app.pid)
        if let f = focused, let b = before, unchanged(f, from: b) {
            let plain = NSPasteboard.general.string(forType: .string) ?? text
            // Rich formats need a real paste: bring the app forward for a moment, paste, hand focus back.
            if format.lowercased() != "text", let running = app.running {
                let previous = NSWorkspace.shared.frontmostApplication
                running.activate()
                let deadline = Date().addingTimeInterval(1.5)
                while !running.isActive && Date() < deadline { usleep(50_000) }
                if pressMenuShortcut(app.pid, pasteCombo) == nil { Events.press(pid: app.pid, pasteCombo) }
                usleep(400_000)
                if let prev = previous, prev.processIdentifier != app.pid {
                    // A background app can't call activate() on another app (cooperative activation), but
                    // LaunchServices can bring an already-running app back to the front.
                    if let url = prev.bundleURL {
                        let cfg = NSWorkspace.OpenConfiguration()
                        cfg.activates = true
                        cfg.addsToRecentItems = false
                        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
                    }
                    let until = Date().addingTimeInterval(1.5)
                    while !prev.isActive && Date() < until { usleep(50_000) }
                }
                if AX.string(f, kAXValueAttribute) != b {
                    return .text("Pasted \(text.count) characters as \(format) (\(app.name) was brought forward for a moment because it ignores background pastes); the previous clipboard was restored.")
                }
            }
            if insertViaAccessibility(f, plain) {
                return .text("Pasted \(text.count) characters as plain text through accessibility (\(app.name) ignored the background paste shortcut); the previous clipboard was restored.")
            }
        }
        return .text("Pasted \(text.count) characters as \(format); the previous clipboard was restored.")
    }

    private func secondaryAction(_ args: [String: Any]) throws -> ToolResult {
        let app = try target(args)
        let e = try entry(app, try args.requireInt("element_index"))
        let wanted = AX.normalizeActionName(try args.requireString("action"))
        let live = AX.actions(e.element)
        guard let raw = live.first(where: { AX.normalizeActionName($0) == wanted || AX.normalizeActionName(AX.prettyAction($0)) == wanted }) else {
            let available = live.filter { !TreeBuilder.quietActions.contains($0) }.map(AX.prettyAction)
            throw ToolError("Element \(e.index) does not expose that action. Available: \(available.isEmpty ? "none" : available.joined(separator: ", ")).")
        }
        let err = AX.perform(e.element, raw)
        guard err == .success || err == .cannotComplete else {
            throw ToolError("The app rejected \(AX.prettyAction(raw)) on element \(e.index) (AX error \(err.rawValue)).")
        }
        acted(app.pid, at: try? center(of: e))
        return .text("Performed \(AX.prettyAction(raw)) on element \(e.index).")
    }

    private func pressKey(_ args: [String: Any]) throws -> ToolResult {
        let app = try target(args)
        let spec = try args.requireString("key")
        let combo = try KeySyntax.parse(spec)
        if args.double("duration") == nil, let title = pressMenuShortcut(app.pid, combo) {
            acted(app.pid)
            return .text("Pressed \(spec) (menu item \"\(title)\").")
        }
        Events.press(pid: app.pid, combo, hold: args.double("duration"))
        acted(app.pid)
        return .text("Pressed \(spec).")
    }

    private func scroll(_ args: [String: Any]) throws -> ToolResult {
        let app = try target(args)
        let dir = (try args.requireString("direction")).lowercased()
        let pages = max(0.05, min(args.double("pages") ?? 1, 25))
        var point: CGPoint
        var area: CGRect?
        if let index = args.int("element_index") {
            let e = try entry(app, index)
            point = try center(of: e)
            area = AX.frame(e.element) ?? e.frame
        } else if let x = args.double("x"), let y = args.double("y") {
            point = try shotPoint(app, x, y)
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(app.pid), Float(point.x), Float(point.y), &hit) == .success, var el = hit {
                for _ in 0..<12 {
                    if AX.string(el, kAXRoleAttribute) == "AXScrollArea" { area = AX.frame(el); break }
                    guard let parent = AX.element(el, kAXParentAttribute) else { break }
                    el = parent
                }
            }
            if area == nil { area = snapshot(app.pid)?.shot?.frame }
        } else {
            throw ToolError("Provide element_index, or both x and y (screenshot pixels).")
        }
        let h = max(80, (area?.height ?? 600) * 0.85), w = max(80, (area?.width ?? 800) * 0.85)
        var dx = 0.0, dy = 0.0
        switch dir {
        case "down", "d": dy = -h * pages
        case "up", "u": dy = h * pages
        case "right", "r": dx = -w * pages
        case "left", "l": dx = w * pages
        default: throw ToolError("direction must be up, down, left or right.")
        }
        Events.scroll(pid: app.pid, at: point, dx: dx, dy: dy)
        acted(app.pid, at: point)
        return .text("Scrolled \(dir) \(pages == 1 ? "1 page" : "\(pages) pages").")
    }

    private func selectText(_ args: [String: Any]) throws -> ToolResult {
        let app = try target(args)
        let e = try entry(app, try args.requireInt("element_index"))
        let needle = try args.requireString("text")
        let prefix = args.string("prefix") ?? "", suffix = args.string("suffix") ?? ""
        let mode = (args.string("selection_type") ?? "text").lowercased()
        guard let value = AX.string(e.element, kAXValueAttribute) else {
            throw ToolError("Element \(e.index) has no text value to select in.")
        }
        let ns = value as NSString
        func find(_ options: NSString.CompareOptions) -> [NSRange] {
            var out: [NSRange] = []
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let r = ns.range(of: needle, options: options, range: search)
                if r.location == NSNotFound { break }
                let before = ns.substring(to: r.location), after = ns.substring(from: r.location + r.length)
                if (prefix.isEmpty || before.hasSuffix(prefix)) && (suffix.isEmpty || after.hasPrefix(suffix)) { out.append(r) }
                let next = r.location + 1
                search = NSRange(location: next, length: ns.length - next)
            }
            return out
        }
        var matches = find([])
        if matches.isEmpty { matches = find([.caseInsensitive]) }
        guard let r = matches.first else {
            throw ToolError("\"\(needle)\" was not found in element \(e.index)" + (prefix.isEmpty && suffix.isEmpty ? "." : " with that prefix/suffix."))
        }
        var range: CFRange
        switch mode {
        case "cursor_before": range = CFRange(location: r.location, length: 0)
        case "cursor_after": range = CFRange(location: r.location + r.length, length: 0)
        default: range = CFRange(location: r.location, length: r.length)
        }
        AX.set(e.element, kAXFocusedAttribute, kCFBooleanTrue)
        guard let axRange = AXValueCreate(.cfRange, &range),
              AX.set(e.element, kAXSelectedTextRangeAttribute, axRange) == .success else {
            throw ToolError("Element \(e.index) does not support setting a text selection.")
        }
        acted(app.pid)
        let note = matches.count > 1 ? " (\(matches.count) matches; used the first — pass prefix/suffix to pick another)" : ""
        return .text((mode == "text" ? "Selected \"\(needle)\"" : "Placed the caret \(mode == "cursor_before" ? "before" : "after") \"\(needle)\"") + " in element \(e.index)\(note).")
    }

    private func setValue(_ args: [String: Any]) throws -> ToolResult {
        let app = try target(args)
        let e = try entry(app, try args.requireInt("element_index"))
        guard let value = args.string("value") else { throw ToolError("Missing `value`.") }
        guard AX.isSettable(e.element, kAXValueAttribute) else {
            throw ToolError("Element \(e.index)'s value is not settable. Click it to focus it, then use type_text or paste.")
        }
        let current = AX.raw(e.element, kAXValueAttribute)
        let newValue: CFTypeRef
        if current is NSNumber, let d = Double(value) {
            newValue = NSNumber(value: d)
        } else {
            newValue = value as CFString
        }
        let err = AX.set(e.element, kAXValueAttribute, newValue)
        guard err == .success else { throw ToolError("The app rejected the new value (AX error \(err.rawValue)).") }
        acted(app.pid, at: try? center(of: e))
        return .text("Set the value of element \(e.index).")
    }

    /// Finds the enabled menu item whose keyboard shortcut matches `combo` and presses it through
    /// accessibility. Works while the app is in the background, unlike ⌘-keystrokes in many apps.
    private func pressMenuShortcut(_ pid: pid_t, _ combo: KeyCombo) -> String? {
        guard combo.flags.contains(.maskCommand) else { return nil }
        var wantedMods = 0
        if combo.flags.contains(.maskShift) { wantedMods |= 1 }
        if combo.flags.contains(.maskAlternate) { wantedMods |= 2 }
        if combo.flags.contains(.maskControl) { wantedMods |= 4 }
        guard let ch = KeySyntax.chars.first(where: { $0.value == combo.keyCode })?.key else { return nil }
        let wantedChar = String(ch).uppercased()
        guard let bar = AX.element(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else { return nil }
        func search(_ el: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 4 { return nil }
            for child in AX.elements(el, kAXChildrenAttribute) {
                if AX.string(child, kAXRoleAttribute) == "AXMenuItem",
                   let c = AX.string(child, kAXMenuItemCmdCharAttribute), c.uppercased() == wantedChar,
                   ((AX.raw(child, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0) == wantedMods {
                    return child
                }
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        guard let item = search(bar, depth: 0) else { return nil }
        let err = AX.perform(item, kAXPressAction)
        guard err == .success || err == .cannotComplete else { return nil }
        return AX.string(item, kAXTitleAttribute) ?? "menu item"
    }

    private func focusedElement(_ pid: pid_t) -> AXUIElement? {
        AX.element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
    }

    /// True when the element's value is still `before` after giving the app up to ~0.9 s to react.
    private func unchanged(_ el: AXUIElement, from before: String) -> Bool {
        for wait in [150_000, 300_000, 450_000] as [useconds_t] {
            usleep(wait)
            if AX.string(el, kAXValueAttribute) != before { return false }
        }
        return true
    }

    /// Inserts text at the caret through accessibility (used when an app ignores background keystrokes).
    private func insertViaAccessibility(_ el: AXUIElement, _ text: String) -> Bool {
        AX.isSettable(el, kAXSelectedTextAttribute) && AX.set(el, kAXSelectedTextAttribute, text as CFString) == .success
    }

    private func typeText(_ args: [String: Any]) throws -> ToolResult {
        let app = try target(args)
        guard let text = args.string("text"), !text.isEmpty else { throw ToolError("Missing `text`.") }
        let focused = focusedElement(app.pid)
        let before = focused.flatMap { AX.string($0, kAXValueAttribute) }
        Events.type(pid: app.pid, text)
        acted(app.pid)
        if isCancelled { throw ToolError("Typing stopped because the user pressed Esc.") }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var body = normalized
        var trailingReturns = 0
        while body.hasSuffix("\n") { body.removeLast(); trailingReturns += 1 }
        if let f = focused, let b = before, !body.isEmpty, unchanged(f, from: b) {
            let role = AX.string(f, kAXRoleAttribute) ?? ""
            let insert = role == "AXTextArea" ? body : body.replacingOccurrences(of: "\n", with: " ")
            if insertViaAccessibility(f, insert) {
                var note = "Typed \(text.count) characters (inserted through accessibility because \(app.name) ignored background keystrokes)."
                if trailingReturns > 0 {
                    let confirmed = AX.actions(f).contains("AXConfirm") && AX.perform(f, "AXConfirm") == .success
                    note += confirmed ? " Confirmed the field for the trailing newline." : " The trailing newline could not be delivered; click the submit button instead."
                }
                return .text(note)
            }
            return .text("Sent \(text.count) characters, but the focused element's value did not change. \(app.name) may ignore background keystrokes; try set_value or click the field first, then check get_app_state.")
        }
        return .text("Typed \(text.count) characters.")
    }
}
