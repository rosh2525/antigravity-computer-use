import AppKit
import CoreGraphics

/// Synthetic input delivered straight to a target process (CGEvent.postToPid), so the user's own
/// pointer and keyboard focus are left alone wherever the app allows it.
enum Events {
    static let source = CGEventSource(stateID: .privateState)
    static var lastEscapePosted = Date.distantPast

    private static func route(_ e: CGEvent, windowID: CGWindowID?) {
        guard let w = windowID else { return }
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w))
    }

    private static func sleep(_ seconds: Double) {
        if seconds > 0 { usleep(useconds_t(seconds * 1_000_000)) }
    }

    enum Button: String {
        case left, right, middle

        init(_ raw: String?) throws {
            switch (raw ?? "left").lowercased() {
            case "left", "l": self = .left
            case "right", "r": self = .right
            case "middle", "m", "center": self = .middle
            default: throw ToolError("mouse_button must be left, right or middle.")
            }
        }

        var types: (CGEventType, CGEventType, CGEventType, CGMouseButton) {
            switch self {
            case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
            case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
            case .middle: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center)
            }
        }
    }

    static func move(pid: pid_t, to point: CGPoint, windowID: CGWindowID?) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        route(e, windowID: windowID)
        e.postToPid(pid)
    }

    static func click(pid: pid_t, at point: CGPoint, button: Button, count: Int, flags: CGEventFlags, hold: Double?) {
        let windowID = Capture.windowID(pid: pid, at: point)
        let (downType, upType, _, cgButton) = button.types
        move(pid: pid, to: point, windowID: windowID)
        sleep(0.02)
        for i in 1...max(1, min(count, 3)) {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton) else { continue }
            for e in [down, up] {
                e.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e.flags = flags
                route(e, windowID: windowID)
            }
            down.postToPid(pid)
            sleep(hold ?? 0.03)
            up.postToPid(pid)
            if i < count { sleep(0.06) }
        }
    }

    static func drag(pid: pid_t, from: CGPoint, to: CGPoint, button: Button = .left) {
        let windowID = Capture.windowID(pid: pid, at: from)
        let (downType, upType, dragType, cgButton) = button.types
        move(pid: pid, to: from, windowID: windowID)
        sleep(0.03)
        guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: from, mouseButton: cgButton) else { return }
        route(down, windowID: windowID)
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        down.postToPid(pid)
        sleep(0.08)
        let steps = 20
        for s in 1...steps {
            let t = Double(s) / Double(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            if let e = CGEvent(mouseEventSource: source, mouseType: dragType, mouseCursorPosition: p, mouseButton: cgButton) {
                route(e, windowID: windowID)
                e.postToPid(pid)
            }
            sleep(0.012)
        }
        sleep(0.05)
        if let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: to, mouseButton: cgButton) {
            route(up, windowID: windowID)
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.postToPid(pid)
        }
    }

    static func scroll(pid: pid_t, at point: CGPoint, dx: Double, dy: Double) {
        let windowID = Capture.windowID(pid: pid, at: point)
        move(pid: pid, to: point, windowID: windowID)
        let chunks = max(1, Int((max(abs(dx), abs(dy)) / 80).rounded(.up)))
        let stepX = dx / Double(chunks), stepY = dy / Double(chunks)
        for _ in 0..<chunks {
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(stepY.rounded()), wheel2: Int32(stepX.rounded()), wheel3: 0) else { continue }
            e.location = point
            route(e, windowID: windowID)
            e.postToPid(pid)
            sleep(0.012)
        }
    }

    private static func keyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, flagsChanged: Bool = false) -> CGEvent? {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return nil }
        if flagsChanged { e.type = .flagsChanged }
        e.flags = flags
        return e
    }

    static func press(pid: pid_t, _ combo: KeyCombo, hold: Double? = nil) {
        if combo.keyCode == 53 { lastEscapePosted = Date() }
        var current: CGEventFlags = []
        for (code, flag) in combo.modifierKeyCodes {
            current.insert(flag)
            keyEvent(code, down: true, flags: current, flagsChanged: true)?.postToPid(pid)
            sleep(0.008)
        }
        keyEvent(combo.keyCode, down: true, flags: combo.flags)?.postToPid(pid)
        sleep(hold ?? 0.02)
        keyEvent(combo.keyCode, down: false, flags: combo.flags)?.postToPid(pid)
        for (code, flag) in combo.modifierKeyCodes.reversed() {
            current.remove(flag)
            sleep(0.008)
            keyEvent(code, down: false, flags: current, flagsChanged: true)?.postToPid(pid)
        }
    }

    static func type(pid: pid_t, _ text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for ch in normalized {
            if Service.shared.isCancelled { break }
            if ch == "\n" || ch == "\r" {
                press(pid: pid, KeyCombo(keyCode: 36, flags: [], modifierKeyCodes: []))
            } else if ch == "\t" {
                press(pid: pid, KeyCombo(keyCode: 48, flags: [], modifierKeyCodes: []))
            } else {
                var code: CGKeyCode = 0
                var flags: CGEventFlags = []
                if let c = KeySyntax.chars[ch] {
                    code = c
                } else if ch.isUppercase, ch.isASCII, let c = KeySyntax.chars[Character(ch.lowercased())] {
                    code = c; flags = .maskShift
                } else if let base = KeySyntax.shiftedChars[ch], let c = KeySyntax.chars[base] {
                    code = c; flags = .maskShift
                }
                let units = Array(String(ch).utf16)
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
                    e.flags = flags
                    e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    e.postToPid(pid)
                }
            }
            sleep(0.006)
        }
    }
}

// MARK: - Clipboard with restore

enum Clipboard {
    typealias Saved = [[NSPasteboard.PasteboardType: Data]]

    static func save() -> Saved {
        let pb = NSPasteboard.general
        return (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { dict[t] = d } }
            return dict
        }
    }

    static func restore(_ saved: Saved) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = saved.map { dict in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Writes text as plain, Markdown (rendered to rich text) or HTML.
    static func write(_ text: String, format: String) throws {
        let pb = NSPasteboard.general
        switch format.lowercased() {
        case "text", "plain", "txt":
            pb.clearContents()
            pb.setString(text, forType: .string)
        case "md", "markdown", "html":
            let html = format.lowercased() == "html" ? text : Markdown.toHTML(text)
            let wrapped = "<meta charset=\"utf-8\"><div style=\"font-family: -apple-system, Helvetica; font-size: 13px\">\(html)</div>"
            let (plain, rtf): (String, Data?) = runOnMain {
                guard let data = wrapped.data(using: .utf8),
                      let parsed = try? NSMutableAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                                        .characterEncoding: String.Encoding.utf8.rawValue],
                                                                  documentAttributes: nil) else { return (text, nil) }
                while parsed.length > 0, parsed.string.hasSuffix("\n") {
                    parsed.deleteCharacters(in: NSRange(location: parsed.length - 1, length: 1))
                }
                let attr: NSAttributedString = parsed
                let rtf = try? attr.data(from: NSRange(location: 0, length: attr.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                var plain = attr.string
                while plain.hasSuffix("\n") { plain.removeLast() }
                return (format.lowercased() == "md" ? text : plain, rtf)
            }
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString(wrapped, forType: .html)
            if let rtf { item.setData(rtf, forType: .rtf) }
            item.setString(plain, forType: .string)
            pb.writeObjects([item])
        default:
            throw ToolError("format must be one of: text, md, html.")
        }
    }
}

// MARK: - Minimal Markdown -> HTML (headings, lists, quotes, code, emphasis, links)

enum Markdown {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ s: String) -> String {
        var out = escape(s)
        func sub(_ pattern: String, _ template: String) {
            if let re = try? NSRegularExpression(pattern: pattern) {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
            }
        }
        sub("`([^`]+)`", "<code>$1</code>")
        sub("\\*\\*(.+?)\\*\\*", "<strong>$1</strong>")
        sub("__(.+?)__", "<strong>$1</strong>")
        sub("(?<![\\w*])\\*(?!\\s)(.+?)(?<!\\s)\\*(?!\\w)", "<em>$1</em>")
        sub("(?<![\\w_])_(?!\\s)(.+?)(?<!\\s)_(?!\\w)", "<em>$1</em>")
        sub("~~(.+?)~~", "<del>$1</del>")
        sub("!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)", "<img alt=\"$1\" src=\"$2\">")
        sub("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>")
        return out
    }

    static func toHTML(_ md: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var listType: String?
        var inCode = false
        var code: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { html.append("<p>" + paragraph.map(inline).joined(separator: "<br>") + "</p>") }
            paragraph = []
        }
        func closeList() {
            if let t = listType { html.append("</\(t)>"); listType = nil }
        }

        for raw in md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    html.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>")
                    code = []
                    inCode = false
                } else {
                    flushParagraph(); closeList()
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line); continue }
            if trimmed.isEmpty { flushParagraph(); closeList(); continue }

            if let m = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flushParagraph(); closeList()
                let level = trimmed[m].filter { $0 == "#" }.count
                html.append("<h\(level)>" + inline(String(trimmed[m.upperBound...])) + "</h\(level)>")
            } else if let m = trimmed.range(of: "^[-*+]\\s+", options: .regularExpression) {
                flushParagraph()
                if listType != "ul" { closeList(); html.append("<ul>"); listType = "ul" }
                html.append("<li>" + inline(String(trimmed[m.upperBound...])) + "</li>")
            } else if let m = trimmed.range(of: "^\\d+[.)]\\s+", options: .regularExpression) {
                flushParagraph()
                if listType != "ol" { closeList(); html.append("<ol>"); listType = "ol" }
                html.append("<li>" + inline(String(trimmed[m.upperBound...])) + "</li>")
            } else if trimmed.hasPrefix(">") {
                flushParagraph(); closeList()
                html.append("<blockquote>" + inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)) + "</blockquote>")
            } else if trimmed.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil {
                flushParagraph(); closeList()
                html.append("<hr>")
            } else {
                closeList()
                paragraph.append(trimmed)
            }
        }
        if inCode { html.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>") }
        flushParagraph(); closeList()
        return html.joined(separator: "\n")
    }
}
