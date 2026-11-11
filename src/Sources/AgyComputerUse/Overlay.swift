import AppKit
import QuartzCore

/// "Antigravity is using your computer · Esc to cancel" pill plus click ripples, and the global Esc
/// monitor that cancels computer use for the rest of the turn.
final class Overlay {
    static let shared = Overlay()

    static let accent = NSColor(srgbRed: 0.27, green: 0.52, blue: 0.96, alpha: 1)

    private var pill: NSPanel?
    private var titleLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var idleTimer: Timer?
    private var escMonitor: Any?
    var onEscape: (() -> Void)?
    private(set) var visible = false

    private static var overlayLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
    }

    private static func makePanel(_ rect: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.level = overlayLevel
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = .none
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        return p
    }

    private static var primaryScreen: NSScreen? { NSScreen.screens.first }

    /// Converts a global CoreGraphics point (top-left origin) to Cocoa screen coordinates.
    static func cocoaPoint(_ p: CGPoint) -> NSPoint {
        let h = primaryScreen?.frame.height ?? 0
        return NSPoint(x: p.x, y: h - p.y)
    }

    private func buildPill() -> NSPanel {
        let panel = Self.makePanel(NSRect(x: 0, y: 0, width: 360, height: 36))
        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = Self.accent.withAlphaComponent(0.55).cgColor
        effect.autoresizingMask = [.width, .height]

        let dot = NSView(frame: NSRect(x: 16, y: 13, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Self.accent.cgColor
        dot.layer?.cornerRadius = 5
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.25
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        let title = NSTextField(labelWithString: "Antigravity is using your computer")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        let hint = NSTextField(labelWithString: "Esc to cancel")
        hint.font = .systemFont(ofSize: 12, weight: .regular)
        hint.textColor = .secondaryLabelColor

        effect.addSubview(dot)
        effect.addSubview(title)
        effect.addSubview(hint)
        panel.contentView = effect
        titleLabel = title
        hintLabel = hint
        layoutPill(panel)
        return panel
    }

    private func layoutPill(_ panel: NSPanel) {
        guard let title = titleLabel, let hint = hintLabel else { return }
        title.sizeToFit()
        hint.sizeToFit()
        let width = 16 + 10 + 10 + title.frame.width + 12 + hint.frame.width + 18
        let height: CGFloat = 36
        title.setFrameOrigin(NSPoint(x: 36, y: (height - title.frame.height) / 2))
        hint.setFrameOrigin(NSPoint(x: 36 + title.frame.width + 12, y: (height - hint.frame.height) / 2))
        let screen = Self.primaryScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: screen.midX - width / 2, y: screen.maxY - height - 10, width: width, height: height), display: true)
    }

    /// Show the pill (idempotent) and push back the idle auto-hide.
    func touch() {
        DispatchQueue.main.async { [self] in
            if pill == nil { pill = buildPill() }
            if !visible {
                titleLabel?.stringValue = "Antigravity is using your computer"
                hintLabel?.stringValue = "Esc to cancel"
                layoutPill(pill!)
                pill?.alphaValue = 1
                pill?.orderFrontRegardless()
                visible = true
                installEscMonitor()
            }
            idleTimer?.invalidate()
            idleTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
                self?.hide()
                Service.shared.idleReset()
            }
        }
    }

    func hide() {
        DispatchQueue.main.async { [self] in
            idleTimer?.invalidate()
            idleTimer = nil
            pill?.orderOut(nil)
            visible = false
            removeEscMonitor()
        }
    }

    func flash(_ message: String, hint: String = "", then hideAfter: Double = 1.6) {
        DispatchQueue.main.async { [self] in
            if pill == nil { pill = buildPill() }
            titleLabel?.stringValue = message
            hintLabel?.stringValue = hint
            layoutPill(pill!)
            pill?.orderFrontRegardless()
            idleTimer?.invalidate()
            idleTimer = Timer.scheduledTimer(withTimeInterval: hideAfter, repeats: false) { [weak self] _ in self?.hide() }
        }
    }

    /// Ripple at a global (top-left origin) point.
    func pulse(at point: CGPoint) {
        DispatchQueue.main.async {
            let size: CGFloat = 72
            let c = Self.cocoaPoint(point)
            let panel = Self.makePanel(NSRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size))
            let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            view.wantsLayer = true
            panel.contentView = view

            let ring = CAShapeLayer()
            ring.frame = view.bounds
            ring.path = CGPath(ellipseIn: view.bounds.insetBy(dx: 6, dy: 6), transform: nil)
            ring.fillColor = Self.accent.withAlphaComponent(0.12).cgColor
            ring.strokeColor = Self.accent.cgColor
            ring.lineWidth = 3
            view.layer?.addSublayer(ring)

            let dot = CAShapeLayer()
            dot.frame = view.bounds
            dot.path = CGPath(ellipseIn: CGRect(x: size / 2 - 5, y: size / 2 - 5, width: 10, height: 10), transform: nil)
            dot.fillColor = Self.accent.cgColor
            view.layer?.addSublayer(dot)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.25
            scale.toValue = 1.0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 0.55
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "ripple")
            let dotFade = CABasicAnimation(keyPath: "opacity")
            dotFade.fromValue = 1.0
            dotFade.toValue = 0.0
            dotFade.duration = 0.7
            dotFade.fillMode = .forwards
            dotFade.isRemovedOnCompletion = false
            dot.add(dotFade, forKey: "fade")

            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { panel.orderOut(nil) }
        }
    }

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            if Date().timeIntervalSince(Events.lastEscapePosted) < 0.5 { return }
            if let src = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID), src == Int64(getpid()) { return }
            self?.onEscape?()
        }
    }

    private func removeEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m) }
        escMonitor = nil
    }
}
