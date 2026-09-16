#!/bin/bash
# Installer for cmux-claude-queue.
#
# Copies the queue script into ~/.local/bin (re-run after a git pull to
# upgrade; pass --dev to symlink instead so the repo stays live), builds the
# hotkey daemon with swiftc, and (re)loads its LaunchAgent. Prints the
# cmux.json and Claude Code settings.json snippets you still need to add
# yourself — the installer never edits your configs.
set -euo pipefail

# Resolve $0 through symlinks. Installed from npm this script is reached via a
# symlink in npm's bin directory, where dirname $0 points at that directory
# rather than at the package. macOS has no readlink -f, hence the loop.
SELF="$0"
while [ -L "$SELF" ]; do
  target="$(readlink "$SELF")"
  case "$target" in
    /*) SELF="$target" ;;
    *)  SELF="$(dirname "$SELF")/$target" ;;
  esac
done
REPO="$(cd "$(dirname "$SELF")" && pwd)"

# A clone is copied out so it survives the clone moving; an npm install is
# linked so `npm update -g` takes effect without re-running this.
MODE="copy"
case "$REPO" in */node_modules/*) MODE="link" ;; esac
case "${1:-}" in
  --dev|--link) MODE="link" ;;
  --copy)       MODE="copy" ;;
esac
BIN_DIR="${CMUX_CLAUDE_QUEUE_BIN_DIR:-$HOME/.local/bin}"
LABEL="com.cmux-claude-queue.hotkeyd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/.claude/prompt-queue"

# /usr/bin/swiftc always exists — it is Apple's xcode-select shim, the same inode as
# /usr/bin/git. Only xcrun can tell us whether the real toolchain is behind it.
xcrun --find swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — install the Xcode Command Line Tools first (xcode-select --install)" >&2
  exit 1
}

mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents"
# drafts, screen dumps and the prompt log live here — keep them to this account
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"

if [ "$MODE" = "link" ]; then
  echo "==> linking $BIN_DIR/cmux-claude-queue (edits to $REPO go live)"
  ln -sf "$REPO/bin/cmux-claude-queue" "$BIN_DIR/cmux-claude-queue"
else
  # a copy survives the clone being moved or deleted; --dev symlinks instead
  echo "==> installing $BIN_DIR/cmux-claude-queue"
  install -m 755 "$REPO/bin/cmux-claude-queue" "$BIN_DIR/cmux-claude-queue"
fi

# v1 installed an $EDITOR shim for the external-editor capture. That path is
# gone; leaving the file behind means Ctrl+G execs a command that no longer
# has an `editor` subcommand, and an npm upgrade leaves it dangling anyway.
if [ -e "$BIN_DIR/cmux-claude-queue-editor" ] || [ -L "$BIN_DIR/cmux-claude-queue-editor" ]; then
  rm -f "$BIN_DIR/cmux-claude-queue-editor"
  echo "==> removed the old editor shim (external-editor capture was dropped)"
  if grep -q 'cmux-claude-queue-editor' "$HOME/.claude/settings.json" 2>/dev/null; then
    echo "    NOTE: ~/.claude/settings.json still sets EDITOR to it — remove that entry" >&2
  fi
fi

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
		<string>$BIN_DIR/cmux-claude-queue</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
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
echo '   (the password above is a fresh suggestion — on a re-install keep the'
echo '   one already in your cmux.json instead of rotating it)'
echo '   ...then run: cmux reload-config'
echo
echo "2) ~/.claude/settings.json — queue display + delivery pump:"
echo '   "statusLine": {'
echo '     "type": "command",'
echo "     \"command\": \"$BIN_DIR/cmux-claude-queue statusline\","
echo '     "padding": 0,'
echo '     "refreshInterval": 1'
echo '   }'
echo
echo "If you already had a statusLine command, save it as a shell script at"
echo "~/.config/cmux-claude-queue/statusline-chain — it will keep running,"
echo "with the queue row appended below its output."
