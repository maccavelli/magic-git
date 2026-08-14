/// Human labels for forge mutations, for the Activity centre.
///
/// Every non-read forge command used to report as the single generic
/// "Update forge", so a stalled merge and a stalled comment were
/// indistinguishable in the activity list.
///
/// Derived centrally from argv rather than curated at each of the ~41 mutating
/// service methods. That is a deliberate departure from the GitService pattern
/// (which labels at its one `_run` chokepoint) and it earns its keep here:
/// forge argv is rigidly structured — `gh <noun> <verb>`, `glab <noun> <verb>`,
/// or `<cli> api <endpoint> --method <VERB>` — so one tested table covers the
/// CLI and REST paths alike, including the ten mutations that route through
/// `api()` and would otherwise need a label threaded through two more layers.
/// Anything unrecognized falls back to the generic label, exactly as before.
library;

/// Maps a forge command line to a human label, or null when it is not a
/// recognized mutation (the caller then uses its generic fallback).
///
/// [argv] is the full command, e.g. `['gh', 'pr', 'merge', '42']`.
String? forgeOperationLabel(List<String> argv) {
  if (argv.length < 2) return null;
  final cli = argv.first;
  final isGitLab = cli == 'glab';
  if (cli != 'gh' && !isGitLab) return null;

  // `gh api …` / `glab api …` — the REST-routed mutations.
  if (argv[1] == 'api') return _restLabel(argv, isGitLab: isGitLab);

  if (argv.length < 3) return null;
  final noun = argv[1];
  final verb = argv[2];
  final request = isGitLab ? 'merge request' : 'pull request';

  return switch ((noun, verb)) {
    ('auth', 'login') => isGitLab ? 'Sign in to GitLab' : 'Sign in to GitHub',
    ('repo', 'create') =>
      isGitLab ? 'Create GitLab project' : 'Create GitHub repository',

    ('issue', 'create') => 'Create issue',
    ('issue', 'close') => 'Close issue',
    ('issue', 'reopen') => 'Reopen issue',
    ('issue', 'comment') => 'Comment on issue',
    ('issue', 'edit') => 'Edit issue',
    ('issue', 'develop') => 'Start work on issue',

    ('pr' || 'mr', 'create') => 'Create $request',
    ('pr' || 'mr', 'merge') => 'Merge $request',
    ('pr' || 'mr', 'close') => 'Close $request',
    ('pr' || 'mr', 'reopen') => 'Reopen $request',
    ('pr' || 'mr', 'comment') => 'Comment on $request',
    ('pr' || 'mr', 'edit') => 'Edit $request',
    ('pr' || 'mr', 'checkout') => 'Check out $request',
    ('pr' || 'mr', 'approve') => 'Approve $request',
    ('pr' || 'mr', 'ready') => 'Change $request draft state',
    ('pr' || 'mr', 'review') => 'Review $request',

    ('run', 'rerun') => 'Re-run failed jobs',
    ('ci', 'retry') => 'Retry pipeline',
    _ => null,
  };
}

/// Labels a REST mutation from its endpoint and method.
///
/// Reads are not labelled at all: the caller only asks for a descriptor on a
/// non-read lane, and a GET that slips through would produce a misleading
/// "changed something" entry.
String? _restLabel(List<String> argv, {required bool isGitLab}) {
  final methodIndex = argv.indexOf('--method');
  final method = methodIndex >= 0 && methodIndex + 1 < argv.length
      ? argv[methodIndex + 1].toUpperCase()
      : 'GET';
  if (method == 'GET' || method == 'HEAD') return null;

  final endpoint = argv.length > 2 ? argv[2] : '';
  final request = isGitLab ? 'merge request' : 'pull request';

  // Endpoint tails are stable across both forges' REST surfaces.
  if (endpoint.endsWith('/merge')) {
    // GitLab's PUT …/merge doubles as "enable auto-merge" when it carries
    // merge_when_pipeline_succeeds; the field is the only thing separating
    // the two, so check for it rather than guessing from the path.
    final auto = argv.any((a) => a.startsWith('merge_when_pipeline_succeeds='));
    return auto ? 'Enable auto-merge' : 'Merge $request';
  }
  if (endpoint.endsWith('/cancel_merge_when_pipeline_succeeds')) {
    return 'Cancel auto-merge';
  }
  if (endpoint.endsWith('/rebase')) return 'Rebase $request';
  if (endpoint.endsWith('/approve')) return 'Approve $request';
  if (endpoint.endsWith('/unapprove')) return 'Revoke approval';
  if (endpoint.endsWith('/retry')) return 'Retry pipeline';
  if (endpoint.endsWith('/update-branch')) return 'Update $request branch';
  if (endpoint.contains('/pulls/') || endpoint.contains('/merge_requests/')) {
    return 'Update $request';
  }
  if (endpoint.contains('/issues/')) return 'Update issue';
  return null;
}
