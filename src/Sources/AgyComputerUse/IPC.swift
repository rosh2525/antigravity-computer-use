import Darwin
import Foundation

// Newline-delimited JSON over a Unix domain socket in the plugin's data directory.

private func makeAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString).map { UInt8(bitPattern: $0) }
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count <= capacity else { throw ToolError("Socket path too long: \(path)") }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
    }
    return addr
}

private func setNoSigPipe(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

private func setTimeouts(_ fd: Int32, seconds: Double) {
    var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

final class LineChannel {
    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    func readLine() -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(chunk, count: n)
        }
    }

    func write(_ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < data.count {
                let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    func close() { Darwin.close(fd) }
}

final class SocketServer {
    let path: String
    let handler: ([String: Any]) -> [String: Any]
    private var listenFD: Int32 = -1

    init(path: String, handler: @escaping ([String: Any]) -> [String: Any]) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        Paths.ensureDataDir()
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ToolError("socket() failed: \(errno)") }
        var addr = try makeAddress(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard rc == 0 else { close(fd); throw ToolError("bind(\(path)) failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw ToolError("listen failed: \(errno)") }
        listenFD = fd

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "agy-cu.accept"
        thread.start()
    }

    private func acceptLoop() {
        while true {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 {
                if errno == EINTR { continue }
                Log.info("accept failed: \(errno)")
                return
            }
            var uid: uid_t = 0, gid: gid_t = 0
            if getpeereid(conn, &uid, &gid) != 0 || uid != getuid() {
                Log.info("rejected connection from uid \(uid)")
                close(conn)
                continue
            }
            setNoSigPipe(conn)
            let thread = Thread { [handler] in
                let channel = LineChannel(fd: conn)
                defer { channel.close() }
                while let line = channel.readLine() {
                    guard !line.isEmpty else { continue }
                    let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                    var response = handler(request)
                    if let id = request["id"] { response["id"] = id }
                    if !channel.write(jsonLine(response)) { break }
                }
            }
            thread.name = "agy-cu.conn"
            thread.start()
        }
    }
}

enum ServiceClient {
    static func connectOnce() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard var addr = try? makeAddress(Paths.socketPath) else { close(fd); return nil }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if rc != 0 { close(fd); return nil }
        setNoSigPipe(fd)
        return fd
    }

    static func launchService() throws {
        guard let app = Paths.appBundleURL else {
            throw ToolError("Cannot locate AgyComputerUse.app next to this binary; run scripts/install.sh.")
        }
        let env = ProcessInfo.processInfo.environment
        if env["AGY_CU_NO_AUTOLAUNCH"] == "1" {
            throw ToolError("The Computer Use service is not running (auto-launch disabled by AGY_CU_NO_AUTOLAUNCH).")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var openArgs = ["-g"]
        if let dir = env["AGY_CU_DATA_DIR"], !dir.isEmpty { openArgs += ["--env", "AGY_CU_DATA_DIR=\(dir)"] }
        proc.arguments = openArgs + ["-a", app.path]
        try proc.run()
        proc.waitUntilExit()
    }

    /// Sends one request and waits for its response. Launches the service when it is not running.
    static func request(_ body: [String: Any], timeout: Double = 600, launchIfNeeded: Bool = true) throws -> [String: Any] {
        var fd = connectOnce()
        if fd == nil && launchIfNeeded {
            try launchService()
            let deadline = Date().addingTimeInterval(15)
            while fd == nil && Date() < deadline {
                usleep(100_000)
                fd = connectOnce()
            }
        }
        guard let socketFD = fd else {
            throw ToolError(launchIfNeeded
                ? "The Computer Use service did not start. Open AgyComputerUse.app once (scripts/install.sh) and check its log at \(Paths.logFile.path)."
                : "The Computer Use service is not running.")
        }
        setTimeouts(socketFD, seconds: timeout)
        let channel = LineChannel(fd: socketFD)
        defer { channel.close() }
        guard channel.write(jsonLine(body)) else { throw ToolError("Lost connection to the Computer Use service.") }
        guard let line = channel.readLine(),
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw ToolError("No response from the Computer Use service (timed out or it crashed; see \(Paths.logFile.path)).")
        }
        return obj
    }
}
