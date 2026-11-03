#!/bin/bash
# Fork addition (mjshuster1). Stops and removes the two autorun agents.
# OpenMessage then runs only when started by hand again.
set -u
DOMAIN="gui/$(id -u)"
for label in com.mjshuster.openmessage.serve com.mjshuster.openmessage.update; do
  launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
rm -rf "$HOME/Library/Application Support/openmessage-autorun"
echo "Removed. Start OpenMessage by hand with: cd ~/openmessage && ./openmessage serve --web --mcp-sse --mcp-read-only"
