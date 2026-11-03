#!/bin/zsh
# Removes Claude Kitten: the app, the login item, its data, and its Claude Code hooks.
set -uo pipefail
cd "${0:A:h}"

LABEL=dev.claudekitten.app
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x ClaudeKitten 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"

settings=()
for f in "$HOME"/.claude*/settings.json(N); do settings+=("$f"); done
(( ${#settings} )) && python3 scripts/hooks.py remove "${settings[@]}"

rm -rf "$HOME/Applications/ClaudeKitten.app" "$HOME/Library/Application Support/ClaudeKitten"
[[ -L /usr/local/bin/meow ]] && rm -f /usr/local/bin/meow
echo "👋 Claude Kitten removed. Bye bye~"
