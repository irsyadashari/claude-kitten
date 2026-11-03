#!/bin/zsh
# Builds Claude Kitten, installs it to ~/Applications, starts it at login, and adds the Claude Code hooks.
set -euo pipefail
cd "${0:A:h}"

LABEL=dev.claudekitten.app
DEST="$HOME/Applications/ClaudeKitten.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
HOOK="$DEST/Contents/MacOS/kitten-hook"

./build.sh

echo "🐾 installing to $DEST…"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeKitten 2>/dev/null || true
sleep 0.5
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/ClaudeKitten.app "$DEST"

echo "🐾 adding Claude Code hooks…"
settings=()
for dir in "$HOME"/.claude*(N/); do
  [[ -d "$dir/sessions" || -f "$dir/settings.json" ]] && settings+=("$dir/settings.json")
done
python3 scripts/hooks.py install "$HOOK" "${settings[@]}"

echo "🐾 starting at login (and restarting if it ever crashes)…"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/ClaudeKitten</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo ""
echo "✅ Claude Kitten is running — look for the little cat in your menu bar."
echo "   Optional: make a 'meow' command for nudges from any shell:"
echo "   ln -s \"$HOOK\" /usr/local/bin/meow   # then: long-command; meow"
