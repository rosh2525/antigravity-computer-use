import AppKit
import ApplicationServices

/// Thin, forgiving wrappers over the AXUIElement C API.
enum AX {
    static func raw(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        guard let v = raw(el, attr) else { return nil }
        return v as? String
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        guard let v = raw(el, attr) else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        guard let v = raw(el, attr), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        let arr = v as! [AnyObject]
        return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    static func count(_ el: AXUIElement, _ attr: String) -> Int {
        var n: CFIndex = 0
        return AXUIElementGetAttributeValueCount(el, attr as CFString, &n) == .success ? n : 0
    }

    static func axValue(_ v: CFTypeRef?) -> AXValue? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    static func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let ax = axValue(v), AXValueGetType(ax) == .cgPoint else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(ax, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: CFTypeRef?) -> CGSize? {
        guard let ax = axValue(v), AXValueGetType(ax) == .cgSize else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(ax, .cgSize, &s) ? s : nil
    }

    static func range(_ v: CFTypeRef?) -> CFRange? {
        guard let ax = axValue(v), AXValueGetType(ax) == .cfRange else { return nil }
        var r = CFRange(location: 0, length: 0)
        return AXValueGetValue(ax, .cfRange, &r) ? r : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(raw(el, kAXPositionAttribute)), let s = size(raw(el, kAXSizeAttribute)) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let arr = names as? [String] else { return [] }
        return arr
    }

    static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(el, attr as CFString, value)
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(el, action as CFString)
    }

    static func pid(_ el: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(el, &p)
        return p
    }

    /// Fetch several attributes in one IPC round trip; missing ones are omitted.
    static func multiple(_ el: AXUIElement, _ attrs: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let arr = values as? [AnyObject] else { return [:] }
        var out: [String: CFTypeRef] = [:]
        for (i, v) in arr.enumerated() where i < attrs.count {
            if v is NSNull { continue }
            if let ax = axValue(v), AXValueGetType(ax) == .axError { continue }
            out[attrs[i]] = v
        }
        return out
    }

    /// "AXShowMenu" -> "Show Menu"; custom actions "Name:Copy\nTarget:..." -> "Copy".
    static func prettyAction(_ raw: String) -> String {
        if raw.hasPrefix("Name:") {
            let first = raw.split(separator: "\n").first.map(String.init) ?? raw
            return String(first.dropFirst(5))
        }
        var name = raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw
        if name.isEmpty { name = raw }
        var out = ""
        for (i, ch) in name.enumerated() {
            if i > 0, ch.isUppercase, let prev = out.last, !prev.isUppercase, prev != " " { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    static func normalizeActionName(_ s: String) -> String {
        var t = s.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
        if t.hasPrefix("ax") { t = String(t.dropFirst(2)) }
        return t
    }
}
