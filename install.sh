#!/bin/bash
# Installer for cmux-claude-queue.
#
# Symlinks the queue script into ~/.local/bin (the repo stays the source of
# truth), builds the hotkey daemon with swiftc, and (re)loads its LaunchAgent.
# Prints the cmux.json and Claude Code settings.json snippets you still need
# to add yourself — the installer never edits your configs.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${CMUX_CLAUDE_QUEUE_BIN_DIR:-$HOME/.local/bin}"
LABEL="com.cmux-claude-queue.hotkeyd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/.claude/prompt-queue"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — install the Xcode Command Line Tools first (xcode-select --install)" >&2
  exit 1
}

mkdir -p "$BIN_DIR" "$STATE_DIR" "$HOME/Library/LaunchAgents"

echo "==> linking $BIN_DIR/cmux-claude-queue"
ln -sf "$REPO/bin/cmux-claude-queue" "$BIN_DIR/cmux-claude-queue"

echo "==> building $BIN_DIR/cmux-claude-queue-hotkeyd"
swiftc -O "$REPO/hotkeyd/main.swift" -o "$BIN_DIR/cmux-claude-queue-hotkeyd"

echo "==> (re)loading LaunchAgent $LABEL"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN_DIR/cmux-claude-queue-hotkeyd</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>$STATE_DIR/hotkeyd.err.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "Installed. Two config snippets are still needed (see README.md):"
echo
echo "1) ~/.config/cmux/cmux.json — socket password mode + delivery hook:"
echo '   "automation": {'
echo '     "socketControlMode": "password",'
echo "     \"socketPassword\": \"$(openssl rand -hex 24)\""
echo '   },'
echo '   "notifications": {'
echo '     "hooks": ['
echo "       { \"id\": \"cmux-claude-queue\", \"command\": \"$BIN_DIR/cmux-claude-queue notifyhook\", \"timeoutSeconds\": 30 }"
echo '     ]'
echo '   }'
echo '   ...then run: cmux reload-config'
echo
echo "2) ~/.claude/settings.json — queue display + delivery pump:"
echo '   "statusLine": {'
echo '     "type": "command",'
echo "     \"command\": \"$BIN_DIR/cmux-claude-queue statusline\","
echo '     "padding": 0,'
echo '     "refreshInterval": 5'
echo '   }'
echo
echo "If you already had a statusLine command, save it as a shell script at"
echo "~/.config/cmux-claude-queue/statusline-chain — it will keep running,"
echo "with the queue row appended below its output."
