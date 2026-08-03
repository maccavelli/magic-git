# Forge wire fixtures (MADR/PLAN 0002 Phase 0)

Anonymized JSON shapes captured for parser and service tests. Headers in each
file note the CLI/API source. Field names follow live `gh` GraphQL JSON and
GitLab REST / `glab` output as of 2026-08.

| File | Source |
| --- | --- |
| `gh_pr_list_item.json` | `gh pr list --json …` item |
| `gh_pr_view_mergeable.json` | `gh pr view N --json …` ready |
| `gh_pr_view_blocked.json` | `gh pr view N --json …` blocked |
| `glab_mr_list_item.json` | `glab mr list --output json` item |
| `glab_mr_view_mergeable.json` | `glab mr view IID --output json` ready |
| `glab_mr_view_conflict.json` | `glab mr view IID --output json` conflict |
| `gh_repo_merge_policy.json` | `gh api repos/{owner}/{repo}` subset |
| `glab_project_merge_policy.json` | `glab api projects/:id` subset |

**GitLab skew:** older self-hosted instances may omit `detailed_merge_status`.
Parsers should fall back to `merge_status` / `has_conflicts`.
