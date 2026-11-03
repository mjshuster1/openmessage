#!/bin/bash
# Fork addition (mjshuster1). Run once on the Mac mini:
#   ~/openmessage/scripts/mac-autorun/install.sh
# Installs two launchd agents for the logged-in user:
#   com.mjshuster.openmessage.serve   keeps `openmessage serve` running
#   com.mjshuster.openmessage.update  runs update.sh every 30 minutes
# Undo with uninstall.sh. Logs: ~/Library/Logs/openmessage/
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/openmessage"
SERVE_LABEL="com.mjshuster.openmessage.serve"
UPDATE_LABEL="com.mjshuster.openmessage.update"
DOMAIN="gui/$(id -u)"

GO_BIN="$(command -v go || true)"
GIT_BIN="$(command -v git || true)"
if [ -z "$GO_BIN" ] || [ -z "$GIT_BIN" ]; then
  echo "Could not find go or git on this Mac. Nothing was installed." >&2
  exit 1
fi
if [ ! -x "$REPO/openmessage" ]; then
  echo "No built openmessage in $REPO. Run: cd $REPO && go build -o openmessage ." >&2
  exit 1
fi
if pgrep -x OpenMessage >/dev/null 2>&1; then
  echo "The OpenMessage app is open. Quit it (and remove it from Login Items) first:" >&2
  echo "it starts its own server, and two servers sharing the pairing log each other out." >&2
  exit 1
fi
if ! launchctl print "$DOMAIN/$SERVE_LABEL" >/dev/null 2>&1 && lsof -nP -iTCP:7007 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Something is already running on port 7007." >&2
  echo "Stop the OpenMessage Terminal window first (Control+C), then run this again." >&2
  exit 1
fi

STATE_DIR="$HOME/Library/Application Support/openmessage-autorun"
mkdir -p "$AGENTS" "$LOGS" "$STATE_DIR"
TOOL_PATH="$(dirname "$GO_BIN"):$(dirname "$GIT_BIN"):/usr/bin:/bin:/usr/sbin:/sbin"

cat > "$AGENTS/$SERVE_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$SERVE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$REPO/openmessage</string>
    <string>serve</string>
    <string>--web</string>
    <string>--mcp-sse</string>
    <string>--mcp-read-only</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOGS/serve.log</string>
  <key>StandardErrorPath</key><string>$LOGS/serve.log</string>
</dict>
</plist>
PLIST

cat > "$AGENTS/$UPDATE_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$UPDATE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$REPO/scripts/mac-autorun/update.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$TOOL_PATH</string>
  </dict>
  <key>WorkingDirectory</key><string>$REPO</string>
  <key>StartInterval</key><integer>1800</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOGS/update.log</string>
  <key>StandardErrorPath</key><string>$LOGS/update.log</string>
</dict>
</plist>
PLIST

for label in "$SERVE_LABEL" "$UPDATE_LABEL"; do
  launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist"
done

# The binary running now came from the current commit.
"$GIT_BIN" -C "$REPO" rev-parse HEAD > "$STATE_DIR/built-commit" 2>/dev/null || true

sleep 5
if curl -fsS --max-time 5 http://127.0.0.1:7007/api/status >/dev/null 2>&1; then
  echo "Installed. OpenMessage is running in the background and updates itself every 30 minutes."
else
  echo "Installed, but OpenMessage did not answer yet. Wait a minute, then open http://127.0.0.1:7007"
  echo "If it still fails, show Claude the end of $LOGS/serve.log"
fi
echo
echo "Note: these agents start when you log in. If the Mac restarts and sits at the"
echo "login screen, OpenMessage stays off until you log in. Automatic login fixes that"
echo "(System Settings > Users & Groups), but macOS only allows it with FileVault off."
