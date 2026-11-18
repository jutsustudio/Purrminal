#!/bin/bash
# Installs Purrminal: copies the app to ~/Applications, the hook to ~/.purrminal/hook.sh,
# and merges the hook into ~/.claude/settings.json (a backup is saved next to it).
# ./install.sh --uninstall removes the hooks and the app; other settings are left untouched.
# ./install.sh --hooks only installs the hook (the app runs this copy from its Resources folder).
set -euo pipefail
cd "$(dirname "$0")"

SETTINGS="$HOME/.claude/settings.json"
HOOK="$HOME/.purrminal/hook.sh"
EVENTS=(UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest Notification Stop SubagentStop SessionEnd)
command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }

mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.purrminal-backup"

# Drop every hook entry that calls our script, then drop events left empty.
strip='
  if .hooks then
    .hooks |= (with_entries(.value |= map(select(([.hooks[]?.command] | any(contains(".purrminal/hook.sh"))) | not)))
               | with_entries(select(.value | length > 0)))
    | if .hooks == {} then del(.hooks) else . end
  else . end'

if [ "${1:-}" = "--uninstall" ]; then
  pkill -x Purrminal || true
  jq "$strip" "$SETTINGS.purrminal-backup" > "$SETTINGS"
  rm -rf "$HOME/Applications/Purrminal.app"
  echo "Purrminal removed (settings backup: $SETTINGS.purrminal-backup)"
  exit 0
fi

mkdir -p "$HOME/.purrminal"
cp purrminal-hook.sh "$HOOK"
rm -f "$HOME/.purrminal/state"  # written by the pre-0.2 hook; sessions/ replaces it
chmod +x "$HOOK"

events_json=$(printf '%s\n' "${EVENTS[@]}" | jq -R . | jq -s .)
jq --argjson events "$events_json" --arg hook "$HOOK" "$strip"'
  | reduce $events[] as $e (.;
      .hooks[$e] = ((.hooks[$e] // []) + [{"matcher": "*", "hooks": [{"type": "command", "command": "\($hook) \($e)"}]}]))
' "$SETTINGS.purrminal-backup" > "$SETTINGS"

if [ "${1:-}" = "--hooks" ]; then
  echo "Purrminal hooks installed for ${#EVENTS[@]} events in $SETTINGS (backup: $SETTINGS.purrminal-backup)"
  exit 0
fi

[ -d Purrminal.app ] || ./build.sh
mkdir -p "$HOME/Applications"
pkill -x Purrminal || true
rm -rf "$HOME/Applications/Purrminal.app"
cp -R Purrminal.app "$HOME/Applications/"
open "$HOME/Applications/Purrminal.app"
echo "Purrminal installed: hooks for ${#EVENTS[@]} events in $SETTINGS (backup: $SETTINGS.purrminal-backup)"
