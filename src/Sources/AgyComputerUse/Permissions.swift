import AppKit
import ApplicationServices

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    static var status: [String: Any] {
        ["accessibility": accessibility, "screenRecording": screenRecording]
    }
}

/// Small onboarding window, the counterpart of Codex's Computer Use installer.
final class PermissionsWindow: NSObject {
    static let shared = PermissionsWindow()

    private var window: NSWindow?
    private var axLabel: NSTextField?
    private var srLabel: NSTextField?
    private var doneLabel: NSTextField?
    private var timer: Timer?

    func show() {
        DispatchQueue.main.async { [self] in
            if window == nil { build() }
            refresh()
            NSApp.activate(ignoringOtherApps: true)
            window?.center()
            window?.makeKeyAndOrderFront(nil)
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    private func row(_ title: String, _ detail: String, y: CGFloat, action: Selector, in view: NSView) -> NSTextField {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.frame = NSRect(x: 24, y: y + 22, width: 300, height: 18)
        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        d.frame = NSRect(x: 24, y: y - 8, width: 300, height: 30)
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.frame = NSRect(x: 336, y: y + 22, width: 140, height: 18)
        status.alignment = .right
        let button = NSButton(title: "Open Settings", target: self, action: action)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 356, y: y - 6, width: 120, height: 28)
        [t, d, status, button].forEach(view.addSubview)
        return status
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 280),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Antigravity Computer Use"
        w.isReleasedWhenClosed = false
        let v = w.contentView!
        let heading = NSTextField(labelWithString: "Let Antigravity use apps on this Mac")
        heading.font = .systemFont(ofSize: 17, weight: .bold)
        heading.frame = NSRect(x: 24, y: 232, width: 450, height: 24)
        let sub = NSTextField(wrappingLabelWithString: "Grant both permissions to “Antigravity Computer Use”. You will still be asked before it uses each app, and you can press Esc any time to stop it.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 24, y: 190, width: 452, height: 36)
        v.addSubview(heading)
        v.addSubview(sub)
        axLabel = row("Accessibility", "Read app interfaces and click, type and scroll in them.", y: 136, action: #selector(openAX), in: v)
        srLabel = row("Screen Recording", "Take screenshots of the app windows it works in.", y: 76, action: #selector(openSR), in: v)
        let done = NSTextField(labelWithString: "")
        done.font = .systemFont(ofSize: 12, weight: .medium)
        done.frame = NSRect(x: 24, y: 18, width: 452, height: 18)
        v.addSubview(done)
        doneLabel = done
        window = w
    }

    private func refresh() {
        let ax = Permissions.accessibility, sr = Permissions.screenRecording
        axLabel?.stringValue = ax ? "✓ Granted" : "Not granted"
        axLabel?.textColor = ax ? .systemGreen : .systemOrange
        srLabel?.stringValue = sr ? "✓ Granted" : "Not granted"
        srLabel?.textColor = sr ? .systemGreen : .systemOrange
        doneLabel?.stringValue = (ax && sr) ? "All set. You can close this window and go back to Antigravity."
            : (sr ? "" : "Screen Recording may need the service restarted after granting: run `agy-cu stop`.")
        if ax && sr { timer?.invalidate() }
    }

    @objc private func openAX() {
        Permissions.promptAccessibility()
        Permissions.open("Privacy_Accessibility")
    }

    @objc private func openSR() {
        CGRequestScreenCaptureAccess()
        Permissions.open("Privacy_ScreenCapture")
    }
}
