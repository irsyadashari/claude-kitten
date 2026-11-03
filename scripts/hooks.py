#!/usr/bin/env python3
"""Add or remove the Claude Kitten hooks in Claude Code settings.json files.

usage: hooks.py install <hook-binary> <settings.json>...
       hooks.py remove <settings.json>...
Leaves every other setting and hook untouched, and keeps a backup next to each file.
"""
import json
import os
import shutil
import sys
import time

MARK = "ClaudeKitten.app"
# event -> (is a tool event, run async)
EVENTS = {
    "SessionStart": (False, False),
    "UserPromptSubmit": (False, False),
    "PreToolUse": (True, True),
    "PostToolUse": (True, True),
    "PostToolUseFailure": (True, True),
    "PermissionRequest": (True, False),
    "Notification": (False, False),
    "Stop": (False, False),
    "StopFailure": (False, False),
    "SessionEnd": (False, False),
}


def ours(group):
    return any(MARK in (h.get("command") or "") for h in group.get("hooks", []))


def update(path, hook_bin):
    data = {}
    if os.path.exists(path):
        with open(path) as f:
            text = f.read().strip()
        data = json.loads(text) if text else {}
        backup = f"{path}.bak-claudekitten-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(path, backup)
        print(f"  backup: {backup}")
    hooks = data.get("hooks", {})
    for event, (is_tool, run_async) in EVENTS.items():
        groups = [g for g in hooks.get(event, []) if not ours(g)]
        if hook_bin:
            h = {"type": "command", "command": hook_bin, "timeout": 5}
            if run_async:
                h["async"] = True
            group = {"matcher": "*", "hooks": [h]} if is_tool else {"hooks": [h]}
            groups.append(group)
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)
    if hooks:
        data["hooks"] = hooks
    else:
        data.pop("hooks", None)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"  {'installed in' if hook_bin else 'removed from'} {path}")


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "install":
        for p in sys.argv[3:]:
            update(p, sys.argv[2])
    elif len(sys.argv) >= 3 and sys.argv[1] == "remove":
        for p in sys.argv[2:]:
            update(p, None)
    else:
        print(__doc__)
        sys.exit(1)


main()
