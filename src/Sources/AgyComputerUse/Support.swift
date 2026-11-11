import AppKit
import Foundation

enum Paths {
    static let bundleID = "dev.agy.computer-use"

    static var dataDir: URL {
        if let custom = ProcessInfo.processInfo.environment["AGY_CU_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/plugin_data/computer-use", isDirectory: true)
    }

    /// Unix socket paths are limited to 104 bytes; fall back to a short per-user path in /tmp.
    static var socketPath: String {
        let preferred = dataDir.appendingPathComponent("service.sock").path
        if preferred.utf8.count < 100 { return preferred }
        var hash: UInt64 = 1469598103934665603
        for b in dataDir.path.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        return "/tmp/agy-cu-\(getuid())-\(String(hash, radix: 36)).sock"
    }
    static var approvalsFile: URL { dataDir.appendingPathComponent("approvals.json") }
    static var settingsFile: URL { dataDir.appendingPathComponent("settings.json") }
    static var logFile: URL { dataDir.appendingPathComponent("service.log") }

    static func ensureDataDir() {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// The enclosing AgyComputerUse.app, when this binary runs from inside the bundle.
    static var appBundleURL: URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var url = exe
        for _ in 0..<4 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" { return url }
        }
        let main = Bundle.main.bundleURL
        return main.pathExtension == "app" ? main : nil
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "agy-cu.log")
    static var toFile = false

    static func info(_ message: @autoclosure () -> String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message())\n"
        queue.async {
            if toFile {
                Paths.ensureDataDir()
                let url = Paths.logFile
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(line.data(using: .utf8)!)
                    try? handle.close()
                } else {
                    try? line.data(using: .utf8)!.write(to: url)
                }
            } else {
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
        }
    }
}

struct ToolError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// MCP-shaped tool output: list of content blocks.
struct ToolResult {
    var content: [[String: Any]] = []
    var isError = false

    static func text(_ s: String) -> ToolResult {
        ToolResult(content: [["type": "text", "text": s]])
    }

    static func error(_ s: String) -> ToolResult {
        ToolResult(content: [["type": "text", "text": s]], isError: true)
    }

    mutating func addText(_ s: String) { content.append(["type": "text", "text": s]) }

    mutating func addImage(_ data: Data, mimeType: String) {
        content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType])
    }

    var json: [String: Any] { ["content": content, "isError": isError] }
}

// MARK: - Argument helpers

extension Dictionary where Key == String, Value == Any {
    func string(_ k: String) -> String? {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }

    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func double(_ k: String) -> Double? {
        if let n = self[k] as? NSNumber { return n.doubleValue }
        if let s = self[k] as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func bool(_ k: String) -> Bool? {
        if let b = self[k] as? Bool { return b }
        if let n = self[k] as? NSNumber { return n.boolValue }
        if let s = self[k] as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return nil
    }

    func requireString(_ k: String) throws -> String {
        guard let s = string(k), !s.isEmpty else { throw ToolError("Missing required argument `\(k)`.") }
        return s
    }

    func requireInt(_ k: String) throws -> Int {
        guard let i = int(k) else { throw ToolError("Missing or invalid integer argument `\(k)`.") }
        return i
    }
}

func jsonData(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data("{}".utf8)
}

/// Removes invisible bidi marks some apps put in their names (e.g. "\u{200E}WhatsApp").
func cleanName(_ s: String) -> String {
    s.unicodeScalars.filter { !["\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"].contains($0) }
        .reduce(into: "") { $0.unicodeScalars.append($1) }
        .trimmingCharacters(in: .whitespaces)
}

func jsonLine(_ obj: Any) -> Data {
    var d = jsonData(obj)
    d.append(0x0A)
    return d
}

func runOnMain<T>(_ block: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try block() }
    return try DispatchQueue.main.sync(execute: block)
}

extension String {
    func truncated(_ max: Int) -> String {
        if count <= max { return self }
        return String(prefix(max)) + "…(+\(count - max) chars)"
    }

    var quotedForTree: String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
