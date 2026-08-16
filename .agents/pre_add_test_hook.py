#!/usr/bin/env python3
"""Block `git add` unless `flutter analyze` is clean.

Paths are derived from this file so the hook works in any clone. The full
unit suite is too slow for a PreToolUse hook (and the previous 60s timeout
could not finish it); AGENTS.md still requires `flutter test` before staging.
"""
import json
import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main() -> None:
    try:
        event = json.load(sys.stdin)
    except Exception:
        print(json.dumps({"allow_tool": True}))
        sys.exit(0)

    args = event.get("toolCall", {}).get("args", {})
    cmd_parts = str(args.get("CommandLine", "")).strip().split()
    is_git_add = len(cmd_parts) >= 2 and cmd_parts[0] == "git" and cmd_parts[1] == "add"
    if not is_git_add:
        print(json.dumps({"allow_tool": True}))
        sys.exit(0)

    cwd = args.get("Cwd") or REPO_ROOT
    try:
        res = subprocess.run(
            ["flutter", "analyze"],
            cwd=cwd,
            capture_output=True,
            text=True,
        )
    except Exception as exc:
        print(
            json.dumps(
                {
                    "allow_tool": False,
                    "deny_reason": f"Could not run flutter analyze: {exc}",
                }
            )
        )
        sys.exit(0)

    if res.returncode != 0:
        print(
            json.dumps(
                {
                    "allow_tool": False,
                    "deny_reason": (
                        "flutter analyze failed before git add; staging blocked.\n"
                        f"{res.stdout}\n{res.stderr}"
                    ),
                }
            )
        )
        sys.exit(0)

    print(json.dumps({"allow_tool": True}))
    sys.exit(0)


if __name__ == "__main__":
    main()
