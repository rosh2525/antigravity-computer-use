import AppKit

/// Per-app consent, like Codex's "you choose which apps ChatGPT can use".
///   Allow        -> allowed until the service quits
///   Always Allow -> persisted in approvals.json
///   Don't Allow  -> refused for the rest of the turn
final class Approvals {
    static let shared = Approvals()

    private let lock = NSLock()
    private var always: Set<String> = []
    private var session: Set<String> = []
    private var deniedThisTurn: Set<String> = []
    private(set) var askForNewApps = true

    static let blocked: Set<String> = ["com.google.antigravity", Paths.bundleID]

    init() { load() }

    private func load() {
        if let data = try? Data(contentsOf: Paths.approvalsFile),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            always = Set(obj["always"] as? [String] ?? [])
        }
        if let data = try? Data(contentsOf: Paths.settingsFile),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let ask = obj["askBeforeUsingNewApps"] as? Bool {
            askForNewApps = ask
        } else if !FileManager.default.fileExists(atPath: Paths.settingsFile.path) {
            Paths.ensureDataDir()
            let defaults: [String: Any] = ["askBeforeUsingNewApps": true]
            try? JSONSerialization.data(withJSONObject: defaults, options: [.prettyPrinted]).write(to: Paths.settingsFile)
        }
    }

    private func persist() {
        Paths.ensureDataDir()
        let obj: [String: Any] = ["always": always.sorted()]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.approvalsFile, options: .atomic)
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        always = []; session = []; deniedThisTurn = []
        persist()
    }

    func turnEnded() {
        lock.lock(); deniedThisTurn = []; lock.unlock()
    }

    var summary: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["always": always.sorted(), "session": session.sorted(), "askBeforeUsingNewApps": askForNewApps]
    }

    func check(_ app: ResolvedApp) throws {
        if Self.blocked.contains(app.bundleID) {
            throw ToolError("Computer Use is not allowed to control \(app.name) (it would be operating its own agent UI).")
        }
        lock.lock()
        let key = app.bundleID
        if always.contains(key) || session.contains(key) || !askForNewApps { lock.unlock(); return }
        if deniedThisTurn.contains(key) {
            lock.unlock()
            throw ToolError("The user did not allow Computer Use to control \(app.name). Ask the user before trying again or find another way.")
        }
        lock.unlock()

        let choice: NSApplication.ModalResponse = runOnMain {
            let previous = NSWorkspace.shared.frontmostApplication
            let alert = NSAlert()
            alert.messageText = "Allow Antigravity to use “\(app.name)”?"
            alert.informativeText = "The Antigravity agent wants to see \(app.name)'s windows and click, type and scroll in it. It may take screenshots while it works. Press Esc at any time to stop it."
            alert.icon = NSWorkspace.shared.icon(forFile: app.url?.path ?? "")
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Always Allow")
            alert.addButton(withTitle: "Don't Allow")
            NSApp.activate(ignoringOtherApps: true)
            alert.window.level = .floating
            let response = alert.runModal()
            if let prev = previous, prev.processIdentifier != getpid() {
                prev.activate()
            }
            return response
        }

        lock.lock(); defer { lock.unlock() }
        switch choice {
        case .alertFirstButtonReturn:
            session.insert(key)
        case .alertSecondButtonReturn:
            always.insert(key)
            persist()
        default:
            deniedThisTurn.insert(key)
            throw ToolError("The user did not allow Computer Use to control \(app.name). Ask the user before trying again or find another way.")
        }
    }
}
