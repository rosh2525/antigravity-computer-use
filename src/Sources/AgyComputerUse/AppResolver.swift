import AppKit
import CoreServices

struct ResolvedApp {
    let bundleID: String
    let name: String
    let url: URL?
    var pid: pid_t
    var running: NSRunningApplication?
}

enum AppResolver {
    struct Installed {
        let name: String
        let fileName: String
        let url: URL
        let bundleID: String
    }

    private static let lock = NSLock()
    private static var cache: [Installed]?
    private static var cacheTime = Date.distantPast

    static let searchRoots: [String] = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
    ]

    static func installed() -> [Installed] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, Date().timeIntervalSince(cacheTime) < 300 { return c }
        var seen = Set<String>()
        var out: [Installed] = []
        let fm = FileManager.default
        func add(_ url: URL) {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !seen.contains(id) else { return }
            seen.insert(id)
            let display = cleanName(fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            out.append(Installed(name: display, fileName: url.deletingPathExtension().lastPathComponent, url: url, bundleID: id))
        }
        for root in searchRoots {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          let nested = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    nested.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        cache = out
        cacheTime = Date()
        return out
    }

    private static func fromRunning(_ r: NSRunningApplication) -> ResolvedApp {
        ResolvedApp(bundleID: r.bundleIdentifier ?? "pid.\(r.processIdentifier)",
                    name: cleanName(r.localizedName ?? r.bundleIdentifier ?? "App"),
                    url: r.bundleURL, pid: r.processIdentifier, running: r)
    }

    private static func fromURL(_ url: URL) -> ResolvedApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        if let r = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) {
            return fromRunning(r)
        }
        let name = cleanName(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        return ResolvedApp(bundleID: id, name: name, url: url, pid: 0, running: nil)
    }

    /// Finds the app without launching it.
    static func locate(_ query: String) throws -> ResolvedApp {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lq = q.lowercased()
        let fm = FileManager.default

        if q.contains("/") {
            let path = (q as NSString).expandingTildeInPath
            if fm.fileExists(atPath: path), let app = fromURL(URL(fileURLWithPath: path)) { return app }
            throw ToolError("No app bundle at \(q).")
        }
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.bundleURL != nil }
        if let r = running.first(where: { $0.bundleIdentifier?.lowercased() == lq }) { return fromRunning(r) }
        if let r = running.first(where: { $0.activationPolicy == .regular && cleanName($0.localizedName ?? "").lowercased() == lq }) { return fromRunning(r) }

        let all = installed()
        if let i = all.first(where: { $0.bundleID.lowercased() == lq }) ?? all.first(where: { $0.name.lowercased() == lq })
            ?? all.first(where: { $0.fileName.lowercased() == lq }), let app = fromURL(i.url) {
            return app
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: q), let app = fromURL(url) { return app }
        if let r = running.first(where: { cleanName($0.localizedName ?? "").lowercased() == lq }) { return fromRunning(r) }

        let stripped = lq.hasSuffix(".app") ? String(lq.dropLast(4)) : lq
        let fuzzy = all.filter { $0.name.lowercased().hasPrefix(stripped) || $0.fileName.lowercased().hasPrefix(stripped) }
        if fuzzy.count == 1, let app = fromURL(fuzzy[0].url) { return app }
        let suggestions = all.filter { $0.name.lowercased().contains(stripped) }.prefix(5).map { "\($0.name) (\($0.bundleID))" }
        throw ToolError("Could not find an app named \"\(q)\"." +
                        (suggestions.isEmpty ? " Call list_apps to see available apps." : " Did you mean: \(suggestions.joined(separator: ", "))?"))
    }

    /// Launches the app in the background (no activation) if it is not running.
    static func ensureRunning(_ app: inout ResolvedApp) throws {
        if let r = app.running, !r.isTerminated { app.pid = r.processIdentifier; return }
        if let r = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first(where: { !$0.isTerminated }) {
            app.running = r; app.pid = r.processIdentifier; return
        }
        guard let url = app.url else { throw ToolError("\(app.name) is not running and its location is unknown.") }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        cfg.promptsUserIfNeeded = false
        let sem = DispatchSemaphore(value: 0)
        var launched: NSRunningApplication?
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { r, err in
            launched = r
            launchError = err
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 20)
        guard let r = launched else {
            throw ToolError("Could not launch \(app.name): \(launchError?.localizedDescription ?? "timed out").")
        }
        let deadline = Date().addingTimeInterval(8)
        while !r.isFinishedLaunching && Date() < deadline { usleep(100_000) }
        let el = AXUIElementCreateApplication(r.processIdentifier)
        while AX.count(el, kAXWindowsAttribute) == 0 && Date() < deadline { usleep(150_000) }
        app.running = r
        app.pid = r.processIdentifier
    }

    static func listApps() -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen = Set<String>()
        let iso = ISO8601DateFormatter()
        func meta(_ url: URL?) -> (String?, Int?) {
            guard let url, let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else { return (nil, nil) }
            let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            let count = (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue
            return (date.map { iso.string(from: $0) }, count)
        }
        for r in NSWorkspace.shared.runningApplications where r.activationPolicy == .regular && !r.isTerminated {
            guard let id = r.bundleIdentifier, !seen.contains(id) else { continue }
            seen.insert(id)
            let (last, count) = meta(r.bundleURL)
            var d: [String: Any] = ["id": id, "displayName": cleanName(r.localizedName ?? id), "isRunning": true]
            if let last { d["lastUsedDate"] = last }
            if let count { d["useCount"] = count }
            out.append(d)
        }
        var installedRows: [[String: Any]] = []
        for i in installed() where !seen.contains(i.bundleID) {
            seen.insert(i.bundleID)
            let (last, count) = meta(i.url)
            var d: [String: Any] = ["id": i.bundleID, "displayName": i.name, "isRunning": false]
            if let last { d["lastUsedDate"] = last }
            if let count { d["useCount"] = count }
            installedRows.append(d)
        }
        installedRows.sort { ($0["lastUsedDate"] as? String ?? "") > ($1["lastUsedDate"] as? String ?? "") }
        return out + installedRows
    }
}
