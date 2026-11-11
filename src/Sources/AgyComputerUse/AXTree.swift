import AppKit
import ApplicationServices

struct NodeInfo {
    var role = ""
    var subrole: String?
    var roleDescription: String?
    var title: String?
    var value: CFTypeRef?
    var desc: String?
    var help: String?
    var placeholder: String?
    var identifier: String?
    var enabled = true
    var focused = false
    var selected = false
    var expanded: Bool?
    var frame: CGRect?

    var valueString: String? {
        guard let v = value else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let attr = v as? NSAttributedString { return attr.string }
        return nil
    }
}

struct TreeEntry {
    let key: String
    let depth: Int
    let element: AXUIElement
    let frame: CGRect?
    let role: String
    let body: String          // rendered line without the index
    let actions: [String]     // raw AX action names
    let parentKey: String?    // nearest emitted ancestor
    var index = -1
}

final class TreeBuilder {
    static let attrs: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute,
        kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXPlaceholderValue",
        kAXIdentifierAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute,
        kAXExpandedAttribute, kAXPositionAttribute, kAXSizeAttribute,
    ]

    static let alwaysEmit: Set<String> = [
        "AXWindow", "AXSheet", "AXDrawer", "AXPopover", "AXButton", "AXCheckBox", "AXRadioButton",
        "AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXMenuButton", "AXSlider",
        "AXIncrementor", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXMenuBar", "AXMenu", "AXTabGroup",
        "AXScrollArea", "AXTable", "AXOutline", "AXList", "AXBrowser", "AXWebArea", "AXDisclosureTriangle",
        "AXColorWell", "AXDateField", "AXTimeField", "AXRadioGroup", "AXToolbar", "AXProgressIndicator",
        "AXBusyIndicator", "AXLevelIndicator", "AXValueIndicator", "AXHeading", "AXRow", "AXSegmentedControl",
        "AXDockItem", "AXSwitch",
    ]
    static let skipRoles: Set<String> = ["AXScrollBar", "AXGrowArea", "AXColumn", "AXMatte", "AXRulerMarker", "AXRuler"]
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSlider", "AXIncrementor", "AXDateField", "AXTimeField", "AXColorWell"]
    static let quietActions: Set<String> = ["AXPress", "AXScrollToVisible"]

    let maxNodes: Int
    let maxDepth = 48
    var visited = 0
    var truncated = false
    var busy = false
    var entries: [TreeEntry] = []
    var offscreen: [String: Int] = [:]   // emitted container key -> hidden child count

    init(maxNodes: Int = 1600) { self.maxNodes = maxNodes }

    static func info(_ el: AXUIElement) -> NodeInfo {
        let m = AX.multiple(el, attrs)
        var n = NodeInfo()
        n.role = m[kAXRoleAttribute] as? String ?? ""
        n.subrole = m[kAXSubroleAttribute] as? String
        n.roleDescription = m[kAXRoleDescriptionAttribute] as? String
        n.title = (m[kAXTitleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
        n.value = m[kAXValueAttribute]
        n.desc = (m[kAXDescriptionAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
        n.help = (m[kAXHelpAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
        n.placeholder = (m["AXPlaceholderValue"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        n.identifier = (m[kAXIdentifierAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
        n.enabled = (m[kAXEnabledAttribute] as? NSNumber)?.boolValue ?? true
        n.focused = (m[kAXFocusedAttribute] as? NSNumber)?.boolValue ?? false
        n.selected = (m[kAXSelectedAttribute] as? NSNumber)?.boolValue ?? false
        n.expanded = (m[kAXExpandedAttribute] as? NSNumber)?.boolValue
        if let p = AX.point(m[kAXPositionAttribute]), let s = AX.size(m[kAXSizeAttribute]) {
            n.frame = CGRect(origin: p, size: s)
        }
        return n
    }

    static func signature(_ n: NodeInfo) -> String {
        var name = n.identifier ?? n.title ?? n.desc ?? ""
        if name.isEmpty, n.role == "AXStaticText" || n.role == "AXHeading" { name = String((n.valueString ?? "").prefix(40)) }
        name = String(name.prefix(60)).replacingOccurrences(of: "/", with: "∕")
        return n.role + (n.subrole.map { "." + $0 } ?? "") + ":" + name
    }

    // MARK: Build

    func build(app: AXUIElement) {
        var windows = AX.elements(app, kAXWindowsAttribute)
        if let focused = AX.element(app, kAXFocusedWindowAttribute) {
            if let i = windows.firstIndex(where: { CFEqual($0, focused) }) {
                windows.insert(windows.remove(at: i), at: 0)
            } else {
                windows.insert(focused, at: 0)
            }
        }
        var counts: [String: Int] = [:]
        for w in windows.prefix(6) {
            let wi = Self.info(w)
            if wi.role == "AXWindow", let f = wi.frame, f.width < 2 || f.height < 2 { continue }
            let sig = Self.signature(wi)
            let n = counts[sig, default: 0]; counts[sig] = n + 1
            walk(w, wi, key: "w/\(sig)#\(n)", depth: 0, clip: wi.frame, emittedParent: nil, level: 0, inMenu: false)
        }
        // Context menus and other top-level popups hang directly off the application element.
        for child in AX.elements(app, kAXChildrenAttribute) {
            let ci = Self.info(child)
            guard ci.role == "AXMenu" else { continue }
            let sig = Self.signature(ci)
            let n = counts[sig, default: 0]; counts[sig] = n + 1
            walk(child, ci, key: "m/\(sig)#\(n)", depth: 0, clip: nil, emittedParent: nil, level: 0, inMenu: true)
        }
        if let bar = AX.element(app, kAXMenuBarAttribute) {
            let bi = Self.info(bar)
            walk(bar, bi, key: "menubar", depth: 0, clip: nil, emittedParent: nil, level: 0, inMenu: true)
        }
    }

    private func children(of el: AXUIElement, _ n: NodeInfo) -> [AXUIElement] {
        if n.role == "AXMenuBarItem" && !n.selected { return [] }
        if n.role == "AXMenu", let f = n.frame, f.width < 1 || f.height < 1 { return [] }
        let total = AX.count(el, kAXChildrenAttribute)
        if total > 250 {
            let visible = AX.elements(el, kAXVisibleChildrenAttribute)
            if !visible.isEmpty { return visible }
            let rows = AX.elements(el, kAXVisibleRowsAttribute)
            if !rows.isEmpty { return rows }
            return Array(AX.elements(el, kAXChildrenAttribute).prefix(250))
        }
        return AX.elements(el, kAXChildrenAttribute)
    }

    private func walk(_ el: AXUIElement, _ n: NodeInfo, key: String, depth: Int, clip: CGRect?,
                      emittedParent: String?, level: Int, inMenu: Bool) {
        if visited >= maxNodes { truncated = true; return }
        if level > maxDepth { return }
        visited += 1
        if Self.skipRoles.contains(n.role) { return }
        let menuContext = inMenu || n.role == "AXMenu" || n.role == "AXMenuBar"

        if !menuContext, let f = n.frame, let c = clip, f.width > 0, f.height > 0, !f.intersects(c.insetBy(dx: -1, dy: -1)) {
            if let p = emittedParent { offscreen[p, default: 0] += 1 }
            return
        }
        if n.role == "AXProgressIndicator" || n.role == "AXBusyIndicator" { busy = true }
        if n.role == "AXWebArea", let loaded = AX.bool(el, "AXLoaded"), !loaded { busy = true }

        let actions = ["AXStaticText", "AXImage", "AXHeading"].contains(n.role) ? [] : AX.actions(el)
        var myParent = emittedParent
        var childDepth = depth
        if shouldEmit(n, actions) {
            let body = render(el, n, actions)
            entries.append(TreeEntry(key: key, depth: depth, element: el, frame: n.frame, role: n.role,
                                     body: body, actions: actions, parentKey: emittedParent))
            myParent = key
            childDepth = depth + 1
        }

        var childClip = clip
        if !menuContext, ["AXScrollArea", "AXWebArea", "AXWindow", "AXSheet"].contains(n.role), let f = n.frame, f.width > 0, f.height > 0 {
            childClip = clip.map { $0.intersection(f) } ?? f
            if childClip?.isNull == true { childClip = f }
        }

        var counts: [String: Int] = [:]
        for child in children(of: el, n) {
            if visited >= maxNodes { truncated = true; break }
            let ci = Self.info(child)
            let sig = Self.signature(ci)
            let k = counts[sig, default: 0]; counts[sig] = k + 1
            walk(child, ci, key: key + "/" + sig + "#\(k)", depth: childDepth, clip: childClip,
                 emittedParent: myParent, level: level + 1, inMenu: menuContext)
        }
    }

    private func shouldEmit(_ n: NodeInfo, _ actions: [String]) -> Bool {
        if n.role.isEmpty { return false }
        if n.role == "AXStaticText" { return !(n.valueString ?? n.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if n.role == "AXImage" { return n.title != nil || n.desc != nil }
        if Self.alwaysEmit.contains(n.role) { return true }
        if n.focused || n.selected { return true }
        if n.title != nil || n.desc != nil { return true }
        if let v = n.valueString, !v.isEmpty, n.role != "AXGroup" { return true }
        if actions.contains(where: { !Self.quietActions.contains($0) && $0 != "AXShowMenu" && $0 != "AXShowDefaultUI" && $0 != "AXShowAlternateUI" }) { return true }
        return false
    }

    private func render(_ el: AXUIElement, _ n: NodeInfo, _ actions: [String]) -> String {
        var roleText = n.roleDescription ?? ""
        if roleText.isEmpty { roleText = n.role.hasPrefix("AX") ? String(n.role.dropFirst(2)).lowercased() : n.role }

        let longValueRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea"]
        let valueLimit = longValueRoles.contains(n.role) ? 2000 : (n.role == "AXStaticText" ? 600 : 300)

        var name = n.title
        var valueUsedAsName = false
        if name == nil, Self.editableRoles.contains(n.role) || n.role == "AXCheckBox" || n.role == "AXRadioButton" || n.role == "AXPopUpButton" {
            if let label = AX.element(el, kAXTitleUIElementAttribute) {
                name = AX.string(label, kAXValueAttribute) ?? AX.string(label, kAXTitleAttribute)
            }
        }
        if name == nil, n.role == "AXStaticText" || n.role == "AXHeading" {
            name = n.valueString
            valueUsedAsName = true
        }
        if name == nil { name = n.desc }

        var s = roleText
        if let name, !name.isEmpty { s += " " + name.truncated(valueLimit).quotedForTree }

        var parts: [String] = []
        if !valueUsedAsName, let v = n.value {
            if n.role == "AXCheckBox" || n.role == "AXRadioButton" || n.role == "AXSwitch" || n.subrole == "AXToggle",
               let num = v as? NSNumber {
                parts.append(num.intValue == 1 ? "checked" : (num.intValue == 2 ? "mixed" : "unchecked"))
            } else if let str = v as? String {
                if !str.isEmpty { parts.append("Value: " + str.truncated(valueLimit).quotedForTree) }
            } else if let num = v as? NSNumber {
                parts.append("Value: \(num)")
            }
        }
        if let d = n.desc, d != name { parts.append("Description: " + d.truncated(300).quotedForTree) }
        if let p = n.placeholder, p != name { parts.append("Placeholder: " + p.truncated(120).quotedForTree) }
        if let h = n.help, h != name, h != n.desc, h.count <= 120 { parts.append("Help: " + h.quotedForTree) }
        if let id = n.identifier, name == nil || name!.isEmpty, id.count <= 60, !id.hasPrefix("_NS:") { parts.append("ID: \(id)") }
        if !n.enabled { parts.append("disabled") }
        if n.focused { parts.append("focused") }
        if n.selected { parts.append("selected") }
        if let e = n.expanded { parts.append(e ? "expanded" : "collapsed") }
        if Self.editableRoles.contains(n.role), AX.isSettable(el, kAXValueAttribute) { parts.append("settable") }
        let secondary = actions.filter { !Self.quietActions.contains($0) }.map(AX.prettyAction)
        if !secondary.isEmpty { parts.append("Secondary Actions: " + secondary.joined(separator: ", ")) }

        return parts.isEmpty ? s : s + ", " + parts.joined(separator: ", ")
    }
}

// MARK: - Snapshots, stable indexes and diffs

struct ShotMapping {
    let frame: CGRect      // global (top-left origin) points covered by the screenshot
    let pixelWidth: Int
    let pixelHeight: Int
    let windowTitle: String

    func toGlobal(x: Double, y: Double) -> CGPoint {
        CGPoint(x: frame.minX + x * frame.width / Double(pixelWidth),
                y: frame.minY + y * frame.height / Double(pixelHeight))
    }

    func toPixels(_ p: CGPoint) -> (Int, Int) {
        (Int(((p.x - frame.minX) * Double(pixelWidth) / frame.width).rounded()),
         Int(((p.y - frame.minY) * Double(pixelHeight) / frame.height).rounded()))
    }
}

final class AppSnapshot {
    let pid: pid_t
    var entries: [TreeEntry] = []
    var byIndex: [Int: TreeEntry] = [:]
    var keyToIndex: [String: Int] = [:]
    var bodies: [String: (Int, String)] = [:]
    var nextIndex = 0
    var shot: ShotMapping?

    init(pid: pid_t) { self.pid = pid }

    /// Applies stable indexes (reusing indexes of elements seen before) and returns the diff lines.
    func absorb(_ newEntries: [TreeEntry]) -> (entries: [TreeEntry], added: [TreeEntry], changed: [TreeEntry], removed: [(Int, String)]) {
        var assigned: [TreeEntry] = []
        var used = Set<Int>()
        for var e in newEntries {
            if let idx = keyToIndex[e.key], !used.contains(idx) {
                e.index = idx
            } else {
                e.index = nextIndex
                nextIndex += 1
                keyToIndex[e.key] = e.index
            }
            used.insert(e.index)
            assigned.append(e)
        }
        var added: [TreeEntry] = []
        var changed: [TreeEntry] = []
        var seen = Set<String>()
        for e in assigned {
            seen.insert(e.key)
            if let old = bodies[e.key] {
                if old.1 != e.body { changed.append(e) }
            } else {
                added.append(e)
            }
        }
        let removed = bodies.filter { !seen.contains($0.key) }.map { $0.value }.sorted { $0.0 < $1.0 }

        entries = assigned
        byIndex = Dictionary(assigned.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        bodies = Dictionary(assigned.map { ($0.key, ($0.index, $0.body)) }, uniquingKeysWith: { a, _ in a })
        if keyToIndex.count > 30000 { keyToIndex = Dictionary(assigned.map { ($0.key, $0.index) }, uniquingKeysWith: { a, _ in a }) }
        return (assigned, added, changed, removed)
    }
}
