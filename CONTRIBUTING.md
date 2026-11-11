# Contributing

Issues and pull requests are welcome.

- **Bugs:** use the bug report template; include `bin/agy-cu status` and the relevant lines of
  `~/.gemini/antigravity/plugin_data/computer-use/service.log` (scrub anything private).
- **Build:** `scripts/build.sh` (needs the Xcode Command Line Tools). Try a tool without Antigravity:
  `bin/agy-cu call get_app_state '{"app":"TextEdit"}'`.
- **Code layout:** `src/Sources/AgyComputerUse/` — `MCPServer.swift` (tool schemas), `Service.swift`
  (tool logic), `AXTree.swift` (tree, indexes, diffs), `Events.swift` (input, clipboard),
  `Capture.swift`, `Overlay.swift`, `Approvals.swift`.
- Keep tool names and parameters compatible; agents depend on them.
