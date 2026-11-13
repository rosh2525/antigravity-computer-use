import Foundation

/// Stdio MCP server (JSON-RPC 2.0, newline-delimited). Antigravity spawns this; every tool call is
/// forwarded to the long-running service, which owns all macOS permissions and state.
final class MCPServer {
    static let serverVersion = "1.0.1"

    static let instructions = """
    Computer Use for macOS, modeled on Codex Computer Use. Work app by app: call get_app_state with an app \
    name or bundle id to get its accessibility tree (indexed elements) and a screenshot, act on elements by \
    element_index, then call get_app_state again before deciding the next step. Prefer dedicated tools, \
    APIs, or CLIs when they can do the job. Load the computer-use skill before your first computer-use action.
    """

    func run() {
        signal(SIGPIPE, SIG_IGN)
        setvbuf(stdout, nil, _IOFBF, 1 << 16)
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            handle(msg)
        }
    }

    private func send(_ obj: [String: Any]) {
        let d = jsonLine(obj)
        d.withUnsafeBytes { raw in
            _ = fwrite(raw.baseAddress, 1, d.count, stdout)
        }
        fflush(stdout)
    }

    private func reply(_ id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func replyError(_ id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        guard let id = msg["id"], !(id is NSNull) else {
            return // notification (e.g. notifications/initialized, notifications/cancelled)
        }
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2025-06-18"
            reply(id, result: [
                "protocolVersion": requested,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "computer-use", "title": "Computer Use", "version": Self.serverVersion],
                "instructions": Self.instructions,
            ])
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": ToolCatalog.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard ToolCatalog.names.contains(name) else {
                replyError(id, code: -32602, message: "Unknown tool: \(name)")
                return
            }
            let result: ToolResult
            do {
                let response = try ServiceClient.request([
                    "kind": "tool", "tool": name, "args": args, "client": Int(getpid()),
                ])
                if let content = response["content"] as? [[String: Any]] {
                    result = ToolResult(content: content, isError: response["isError"] as? Bool ?? false)
                } else {
                    result = .error(response["error"] as? String ?? "Unknown service error.")
                }
            } catch {
                result = .error("\(error)")
            }
            reply(id, result: result.json)
        case "resources/list":
            reply(id, result: ["resources": []])
        case "prompts/list":
            reply(id, result: ["prompts": []])
        default:
            replyError(id, code: -32601, message: "Method not found: \(method)")
        }
    }
}

enum ToolCatalog {
    private static let appProp: [String: Any] = [
        "type": "string",
        "description": "Target app: display name (\"Safari\"), bundle identifier (\"com.apple.Safari\"), or full .app path.",
    ]
    private static let indexProp: [String: Any] = [
        "type": "integer",
        "description": "Element index from the latest get_app_state output for this app.",
    ]

    private static func tool(_ name: String, _ title: String, _ description: String,
                             _ props: [String: Any], required: [String], readOnly: Bool = false) -> [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false],
            "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": !readOnly, "openWorldHint": true],
        ]
    }

    static let tools: [[String: Any]] = [
        tool("list_apps", "List apps",
             "List apps on this Mac (running ones first) with bundle id, display name, running state, last-used date and use count. Do not call this just to resolve an app you can name; call get_app_state with the name first.",
             [:], required: [], readOnly: true),
        tool("get_app_state", "Get app state",
             "Return the app's accessibility tree (each element prefixed with its element_index, plus secondary actions it exposes) and a screenshot of its focused window. Launches the app in the background if needed, without stealing focus. After the first call for an app the tree is returned as a diff (+ added, - removed, ~ changed) against the previous call; element indexes stay stable across calls. Pass disableDiff=true when you need the full tree again (for example after you ignored a previous tree). Waits automatically for the UI to settle after recent actions. Call this after every action or batch of actions before deciding the next step.",
             ["app": appProp,
              "disableDiff": ["type": "boolean", "description": "Return the full tree instead of a diff against the previous call."]],
             required: ["app"], readOnly: true),
        tool("click", "Click",
             "Click an element (preferred: element_index) or a point (x, y in pixels of the latest get_app_state screenshot). Works in the background without moving your pointer when possible.",
             ["app": appProp, "element_index": indexProp,
              "x": ["type": "number", "description": "X in screenshot pixels (used when element_index is omitted)."],
              "y": ["type": "number", "description": "Y in screenshot pixels (used when element_index is omitted)."],
              "mouse_button": ["type": "string", "enum": ["left", "right", "middle", "l", "r", "m"], "description": "Default left."],
              "click_count": ["type": "integer", "description": "1 = single (default), 2 = double, 3 = triple."],
              "key": ["type": "string", "description": "Modifier keys held during the click, xdotool style, e.g. \"super\", \"shift\", \"ctrl+alt\"."],
              "duration": ["type": "number", "description": "Seconds to hold the button down (long press)."]],
             required: ["app"]),
        tool("drag", "Drag",
             "Press at (from_x, from_y) and release at (to_x, to_y), in pixels of the latest get_app_state screenshot.",
             ["app": appProp,
              "from_x": ["type": "number"], "from_y": ["type": "number"],
              "to_x": ["type": "number"], "to_y": ["type": "number"]],
             required: ["app", "from_x", "from_y", "to_x", "to_y"]),
        tool("paste", "Paste",
             "Paste text into the app's focused element through the system pasteboard, then restore the user's previous clipboard. Prefer this for multiline or formatted content. format must be text, md (Markdown, pasted as rich text) or html.",
             ["app": appProp,
              "text": ["type": "string"],
              "format": ["type": "string", "enum": ["text", "md", "html"]]],
             required: ["app", "text", "format"]),
        tool("perform_secondary_action", "Perform secondary action",
             "Invoke an accessibility action an element exposes besides a normal click (e.g. \"Show Menu\", \"Increment\", \"Cancel\", \"Raise\"). Only use action names listed for that element in get_app_state; do not guess.",
             ["app": appProp, "element_index": indexProp,
              "action": ["type": "string", "description": "Action name exactly as listed in the element's Secondary Actions."]],
             required: ["app", "element_index", "action"]),
        tool("press_key", "Press key",
             "Press a key or key combination in the target app, xdotool syntax: \"a\", \"Return\", \"Tab\", \"Escape\", \"super+c\", \"ctrl+shift+Tab\", \"Up\", \"Page_Down\", \"F5\", \"KP_0\". Targets the app, so it cannot trigger global shortcuts.",
             ["app": appProp,
              "key": ["type": "string"],
              "duration": ["type": "number", "description": "Seconds to hold the key."]],
             required: ["app", "key"]),
        tool("scroll", "Scroll",
             "Scroll inside an element (element_index) or at a point (x, y in screenshot pixels) by a number of pages.",
             ["app": appProp, "element_index": indexProp,
              "x": ["type": "number"], "y": ["type": "number"],
              "direction": ["type": "string", "enum": ["up", "down", "left", "right", "u", "d", "l", "r"]],
              "pages": ["type": "number", "description": "Pages to scroll (default 1, fractions allowed)."]],
             required: ["app", "direction"]),
        tool("select_text", "Select text",
             "Select matching text inside an editable element, or place the caret before/after it. Use prefix/suffix (text immediately around the match) to disambiguate repeated matches.",
             ["app": appProp, "element_index": indexProp,
              "text": ["type": "string"],
              "prefix": ["type": "string"], "suffix": ["type": "string"],
              "selection_type": ["type": "string", "enum": ["text", "cursor_before", "cursor_after"], "description": "Default text."]],
             required: ["app", "element_index", "text"]),
        tool("set_value", "Set value",
             "Set an element's value directly through accessibility (text fields, search fields, sliders, steppers). Replaces the whole value.",
             ["app": appProp, "element_index": indexProp, "value": ["type": "string"]],
             required: ["app", "element_index", "value"]),
        tool("type_text", "Type text",
             "Type text into the app's focused element as keystrokes. A \\n or \\r presses Return, which often sends a message or submits a form; use paste for multiline text.",
             ["app": appProp, "text": ["type": "string"]],
             required: ["app", "text"]),
    ]

    static let names: Set<String> = Set(tools.compactMap { $0["name"] as? String })
}

enum CLI {
    static func usage() {
        let text = """
        agy-cu — Antigravity Computer Use helper
          agy-cu                      run the service (normally launched automatically)
          agy-cu mcp                  stdio MCP server (used by Antigravity)
          agy-cu notify turn-ended    hide the overlay and reset per-turn state (Stop hook)
          agy-cu status               show service and permission status
          agy-cu permissions          open the permission setup window
          agy-cu reset-approvals      forget all app approvals
          agy-cu stop                 quit the service
          agy-cu call <tool> '<json>' call a tool directly (debugging)
        """
        print(text)
    }

    static func simple(_ kind: String) {
        do {
            let launch = kind == "status"
            let response = try ServiceClient.request(["kind": kind], timeout: 10, launchIfNeeded: launch)
            print(String(data: jsonData(response), encoding: .utf8) ?? "{}")
        } catch {
            print("\(error)")
            exit(kind == "shutdown" ? 0 : 1)
        }
    }

    static func permissions() {
        do {
            let response = try ServiceClient.request(["kind": "show_permissions"], timeout: 10)
            print(String(data: jsonData(response), encoding: .utf8) ?? "{}")
        } catch {
            print("\(error)")
            exit(1)
        }
    }

    static func call(_ args: [String]) {
        guard let tool = args.first else { usage(); exit(2) }
        var toolArgs: [String: Any] = [:]
        if args.count > 1, let d = args[1].data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            toolArgs = obj
        }
        do {
            let response = try ServiceClient.request(["kind": "tool", "tool": tool, "args": toolArgs, "client": Int(getpid())])
            for block in response["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "text" {
                    print(block["text"] as? String ?? "")
                } else if block["type"] as? String == "image", let b64 = block["data"] as? String,
                          let data = Data(base64Encoded: b64) {
                    let ext = (block["mimeType"] as? String) == "image/jpeg" ? "jpg" : "png"
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("agy-cu-\(Int(Date().timeIntervalSince1970)).\(ext)")
                    try? data.write(to: url)
                    print("[image saved to \(url.path)]")
                }
            }
            if let err = response["error"] as? String { print("error: \(err)") }
            if response["isError"] as? Bool == true { exit(1) }
        } catch {
            print("\(error)")
            exit(1)
        }
    }

    /// Stop-hook entry point. Reads the hook JSON from stdin (when piped), tells a running service the
    /// turn ended, and always prints a decision that lets the agent stop.
    static func notify(_ args: [String]) {
        var conversation = ""
        if let i = args.firstIndex(of: "--conversation"), i + 1 < args.count { conversation = args[i + 1] }
        if isatty(STDIN_FILENO) == 0 {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let id = obj["conversationId"] as? String {
                conversation = id
            }
        }
        if args.first == "turn-ended" {
            _ = try? ServiceClient.request(["kind": "turn_ended", "conversation": conversation], timeout: 3, launchIfNeeded: false)
        }
        print("{\"decision\":\"stop\"}")
    }
}
