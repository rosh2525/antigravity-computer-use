#!/bin/bash
# Builds the helper app, points the plugin's MCP config at it, and opens the permission setup window.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if command -v swift >/dev/null 2>&1 && [ -d "$ROOT/src" ] && [ "${AGY_CU_PREBUILT:-0}" != "1" ]; then
  "$ROOT/scripts/build.sh"
elif [ -d "$ROOT/AgyComputerUse.app" ]; then
  echo "Using the prebuilt AgyComputerUse.app (install the Xcode Command Line Tools to build from source)."
  xattr -dr com.apple.quarantine "$ROOT/AgyComputerUse.app" 2>/dev/null || true
else
  echo "Swift is not installed and there is no prebuilt app. Run: xcode-select --install" >&2
  exit 1
fi

BIN="$ROOT/AgyComputerUse.app/Contents/MacOS/agy-cu"
cat > "$ROOT/mcp_config.json" <<EOF
{
  "mcpServers": {
    "computer-use": {
      "command": "$BIN",
      "args": ["mcp"]
    }
  }
}
EOF
chmod +x "$ROOT/bin/agy-cu"

# Register the bundle with LaunchServices and start the service (it opens the setup window when a
# permission is missing).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$ROOT/AgyComputerUse.app" || true
open -a "$ROOT/AgyComputerUse.app"
sleep 1
"$BIN" permissions >/dev/null || true

cat <<EOF

Installed Computer Use for Antigravity.
  1. In the window that opened, allow "Antigravity Computer Use" under Accessibility and Screen Recording.
  2. Restart Antigravity so it picks up the plugin.
Status any time:  $ROOT/bin/agy-cu status
EOF
