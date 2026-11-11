import AppKit
import Foundation

// One executable, three roles (mirrors Codex's SkyComputerUseService / SkyComputerUseClient split):
//   agy-cu                 -> the long-running service (launched through LaunchServices so macOS
//                             attributes Accessibility + Screen Recording to this app bundle)
//   agy-cu mcp             -> stdio MCP server spawned by Antigravity; forwards tool calls to the service
//   agy-cu notify turn-ended | status | stop | reset-approvals | permissions

let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }

switch arguments.first {
case nil, "service":
    ServiceMain.run()
case "mcp":
    MCPServer().run()
case "notify":
    CLI.notify(Array(arguments.dropFirst()))
case "status":
    CLI.simple("status")
case "stop":
    CLI.simple("shutdown")
case "reset-approvals":
    CLI.simple("reset_approvals")
case "permissions":
    CLI.permissions()
case "call":
    CLI.call(Array(arguments.dropFirst()))
case "-h", "--help", "help":
    CLI.usage()
default:
    CLI.usage()
    exit(2)
}
