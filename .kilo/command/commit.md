---
description: Commit staged changes with no edit flag
---
Stage all changes and commit, letting the prepare-commit-msg hook generate the message:

1. Run `git add -A`.
2. Run `git commit --no-edit` — never `-m`, `-F`, or a heredoc; the hook writes the message from the staged diff.
3. Do not push unless the user asks.
