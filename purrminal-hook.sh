#!/bin/bash
# Claude Code hook: writes one status file per agent to ~/.purrminal/sessions/<session_id>[-<agent_id>]
# (line 1: idle|working|waiting|done|error, line 2: caption, line 3: session label). The app merges them by priority.
# Usage in settings.json: "command": "~/.purrminal/hook.sh <EventName>" (install.sh wires this up).
# Always exits 0 so it never blocks the agent.
dir="$HOME/.purrminal/sessions"
mkdir -p "$dir"

# /usr/bin/jq ships with macOS 15+; older systems need Homebrew's. No jq: stay silent, never block the agent.
JQ=/usr/bin/jq
[ -x "$JQ" ] || JQ=$(PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" command -v jq) || exit 0

# One jq call; fields are joined with \x1f because read collapses empty tab-separated fields.
IFS=$'\x1f' read -r sid agent tool title cwd live < <("$JQ" -r '[
  .session_id // "", .agent_id // "", .tool_name // "", .session_title // "", .cwd // "",
  ((.background_tasks // []) | map(select(.status == "running" and .type != "shell")) | length)
] | map(tostring) | join("\u001f")' 2>/dev/null)

sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9_-')
agent=$(printf '%s' "$agent" | tr -cd 'A-Za-z0-9_-')
[ -n "$sid" ] || sid=unknown
file="$dir/$sid${agent:+-$agent}"

case "$1" in
  SessionEnd) rm -f "$dir/$sid" "$dir/$sid"-*; exit 0 ;;
  SubagentStop) rm -f "$file"; exit 0 ;;
  UserPromptSubmit) state=working; detail="thinking" ;;
  PreToolUse|PostToolUse) state=working; detail="$tool" ;;
  PostToolUseFailure) state=error; detail="${tool:-tool} failed" ;;
  PermissionRequest) state=waiting; detail="allow ${tool:-this}?" ;;
  Notification) state=waiting; detail="needs you" ;;
  # Stop while background subagents still run is not the end of the turn (background shells don't count).
  Stop) if [ "${live:-0}" -gt 0 ] 2>/dev/null; then state=working; detail="subagents"; else state=done; detail=""; fi ;;
  *) exit 0 ;;
esac

# Label: the session title when Claude Code sends one, else the previous label, else the project folder.
label="$title"
[ -n "$label" ] || label=$(sed -n 3p "$dir/$sid" 2>/dev/null)
[ -n "$label" ] || label=$(basename "${cwd:-?}")

printf '%s\n%s\n%s\n' "$state" "$detail" "$label" > "$file.tmp" && mv -f "$file.tmp" "$file"
exit 0
