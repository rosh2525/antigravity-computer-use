import AppKit
import ScreenCaptureKit

enum Capture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    struct Shot {
        let data: Data
        let mimeType: String
        let mapping: ShotMapping
    }

    private static func shareableContent() -> SCShareableContent? {
        let sem = DispatchSemaphore(value: 0)
        var result: SCShareableContent?
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            if let error { Log.info("SCShareableContent error: \(error.localizedDescription)") }
            result = content
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return result
    }

    /// Captures the app window that best matches `preferredFrame` (the AX focused window), else the
    /// largest on-screen window of the process.
    static func captureApp(pid: pid_t, preferredFrame: CGRect?, maxLongSide: CGFloat = 1280) -> Result<Shot, ToolError> {
        guard hasPermission else {
            return .failure(ToolError("Screen Recording permission is not granted to Antigravity Computer Use, so no screenshot was taken."))
        }
        guard let content = shareableContent() else {
            return .failure(ToolError("Could not enumerate windows for a screenshot."))
        }
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40
        }
        guard !candidates.isEmpty else {
            return .failure(ToolError("The app has no capturable window (it may be minimized, hidden, or windowless)."))
        }
        var chosen: SCWindow?
        if let pf = preferredFrame {
            let scored = candidates.map { w -> (SCWindow, CGFloat) in
                let f = w.frame
                return (w, abs(f.minX - pf.minX) + abs(f.minY - pf.minY) + abs(f.width - pf.width) + abs(f.height - pf.height))
            }.sorted { $0.1 < $1.1 }
            if let best = scored.first, best.1 < 60 { chosen = best.0 }
        }
        if chosen == nil {
            chosen = candidates.filter { $0.isOnScreen }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                ?? candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
        guard let window = chosen else { return .failure(ToolError("No window to capture.")) }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let pointScale = CGFloat(filter.pointPixelScale)
        let fit = maxLongSide / max(window.frame.width, window.frame.height)
        let scale = min(pointScale, fit)
        config.width = max(1, Int((window.frame.width * scale).rounded()))
        config.height = max(1, Int((window.frame.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true

        let sem = DispatchSemaphore(value: 0)
        var image: CGImage?
        var captureError: Error?
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { img, err in
            image = img
            captureError = err
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 8)
        guard let cg = image else {
            return .failure(ToolError("Screenshot failed: \(captureError?.localizedDescription ?? "timed out")."))
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        var data = rep.representation(using: .png, properties: [:]) ?? Data()
        var mime = "image/png"
        if data.count > 1_400_000, let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            data = jpeg
            mime = "image/jpeg"
        }
        let mapping = ShotMapping(frame: window.frame, pixelWidth: cg.width, pixelHeight: cg.height,
                                  windowTitle: window.title ?? "")
        return .success(Shot(data: data, mimeType: mime, mapping: mapping))
    }

    /// CGWindowID of the app's topmost window containing a global point (for routing background events).
    static func windowID(pid: pid_t, at point: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var fallback: CGWindowID?
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let num = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if fallback == nil { fallback = num }
            if bounds.contains(point) { return num }
        }
        return fallback
    }
}
