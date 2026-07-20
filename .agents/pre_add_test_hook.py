#!/usr/bin/env python3
import sys
import json
import subprocess

def main():
    try:
        # Read the event JSON from stdin
        event = json.load(sys.stdin)
    except Exception as e:
        # Fail open if we cannot parse stdin
        print(json.dumps({"allow_tool": True}))
        sys.exit(0)

    # Extract command details
    tool_call = event.get("toolCall", {})
    args = tool_call.get("args", {})
    cmd_line = args.get("CommandLine", "")

    # Normalize whitespace and split cmd_line
    cmd_parts = cmd_line.strip().split()

    # Detect if the command is "git add"
    is_git_add = False
    if len(cmd_parts) >= 2 and cmd_parts[0] == "git" and cmd_parts[1] == "add":
        is_git_add = True

    if is_git_add:
        cwd = args.get("Cwd", "/Users/saxsmith/gitrepos/magic-git")
        try:
            # Run flutter test
            res = subprocess.run(["flutter", "test"], cwd=cwd, capture_output=True, text=True)
            if res.returncode != 0:
                # Tests failed! Prevent the staging command
                print(json.dumps({
                    "allow_tool": False,
                    "deny_reason": f"Unit tests failed before git add! Staging blocked. Output:\n{res.stdout}\n{res.stderr}"
                }))
                sys.exit(0)
        except Exception as e:
            # If we fail to execute flutter test, block the git add for safety
            print(json.dumps({
                "allow_tool": False,
                "deny_reason": f"Could not run unit tests for validation: {str(e)}"
            }))
            sys.exit(0)

    # Allow the tool execution
    print(json.dumps({"allow_tool": True}))
    sys.exit(0)

if __name__ == "__main__":
    main()
