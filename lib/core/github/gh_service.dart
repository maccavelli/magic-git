import 'dart:convert';
import '../forge/forge.dart';
import '../forge/forge_repo_summary.dart';
import '../ssh/ssh_command_executor.dart';
import 'models.dart';

/// Thrown when a `gh` invocation fails. Carries the failing [result] so callers
/// can surface [SSHCommandResult.stderr] rather than guessing the cause.
class GhException implements Exception {
  final String message;
  final SSHCommandResult result;

  const GhException(this.message, this.result);

  @override
  String toString() =>
      'GhException: $message (exit ${result.exitCode})\n${result.stderr}';
}

/// Drives the remote `gh` (GitHub CLI) through the shared [CommandExecutor] —
/// the GitHub counterpart to [GlabService], kept deliberately parallel so the
/// two forge panels behave identically.
///
/// Two things make this simpler than the GitLab service:
///   * `gh` returns reliable non-zero exit codes on HTTP failures (unlike
///     `glab`, whose exit codes are unreliable — glab #911), so there is no
///     need to request response headers (`-i`) and scrape the HTTP status.
///     `!result.isSuccess` is the failure signal.
///   * `gh pr list --json …` / `gh run list --json …` emit a JSON array
///     directly with a `--limit`, so there is no manual page walk.
///
/// Authentication is **the remote's own `gh auth` store**. No token ever
/// appears in a command line or environment (which would leak it via `ps` /
/// `/proc/<pid>/cmdline` on a shared host, and via which `command_formatter`
/// actively unsets ambient `GH_TOKEN`/`GITHUB_TOKEN`). When the user supplies a
/// token for a connection, [loginWithToken] pipes it once over stdin into
/// `gh auth login --with-token`; every later call uses the stored credential.
/// `gh` infers the owner/repo and (Enterprise) host from the repo's `origin`
/// remote, since every command runs with the working directory set to the repo.
class GhService {
  final CommandExecutor _executor;

  GhService(this._executor);

  /// Non-fatal warning from the most recent [graphql] call (a GraphQL response
  /// that carried `errors[]` alongside usable `data`), or null. Mirrors
  /// `GlabService.lastGraphqlWarning`; read it immediately after awaiting
  /// [projectDashboard].
  String? lastGraphqlWarning;

  /// Authenticates the remote's `gh` against the repo's GitHub host by piping
  /// [token] over stdin to `gh auth login --hostname <host> --with-token`. The
  /// token goes to standard input — never argv, the command string, or an env
  /// assignment — so it can't leak through the remote process table. The host
  /// is resolved from the repo's `origin` remote (so an Enterprise instance is
  /// targeted correctly). Throws [GhException] on a blank token, an
  /// unresolvable host, or a failed login.
  Future<void> loginWithToken(String repoPath, String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      throw const GhException(
        'gh auth login: refusing a blank token',
        SSHCommandResult(exitCode: -1, stdout: '', stderr: ''),
      );
    }
    final remote = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['git', 'remote', 'get-url', 'origin'],
      timeout: const Duration(seconds: 20),
      lane: ExecLane.read,
    );
    final host = forgeHostFromRemoteUrl(remote.stdout.trim());
    if (host == null) {
      throw GhException(
        'could not resolve a GitHub host from the origin remote',
        remote,
      );
    }
    await loginWithTokenHost(cwd: repoPath, host: host, token: trimmed);
  }

  /// [loginWithToken] against an explicit [host] — the repo-less variant used
  /// by the clone/create flows, where there is no origin remote to derive the
  /// host from yet. Same security contract: the token travels over stdin only.
  Future<void> loginWithTokenHost({
    String cwd = '.',
    required String host,
    required String token,
  }) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      throw const GhException(
        'gh auth login: refusing a blank token',
        SSHCommandResult(exitCode: -1, stdout: '', stderr: ''),
      );
    }
    final result = await _executor.execute(
      repoPath: cwd,
      gitArgs: ['gh', 'auth', 'login', '--hostname', host, '--with-token'],
      stdin: trimmed,
      timeout: const Duration(seconds: 30),
      // Sync lane: writes gh's credential store on the host — not a repo
      // mutation, but ordered against other sync ops.
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh auth login failed', result);
    }
  }

  /// The authenticated user's repositories on [host], newest activity first —
  /// the clone sheet's browse list. Runs from [cwd] (an existing directory;
  /// no repo needed). Non-default hosts are selected via `GH_HOST`, gh's
  /// documented host env var (`gh repo list` has no `--hostname` flag).
  Future<List<ForgeRepoSummary>> listRepos({
    String cwd = '.',
    String host = 'github.com',
    int limit = 100,
  }) async {
    final decoded = await _runJson(
      cwd,
      [
        'gh',
        'repo',
        'list',
        '--json',
        'nameWithOwner,description,isPrivate,url,sshUrl,updatedAt',
        '--limit',
        '$limit',
      ],
      'gh repo list',
      extraEnv: hostEnv(host),
    );
    return _mapList(
      decoded,
      ForgeRepoSummary.fromGhJson,
      label: 'gh repo list',
    );
  }

  /// Creates [name] on [host] from *inside* a freshly-`git init`-ed repo at
  /// [repoPath] — `gh repo create --source . --remote origin`, gh's documented
  /// "push an existing local repository" path. Init-first keeps the user's
  /// chosen initial branch authoritative; the `--clone` form was abandoned
  /// because its empty-repo fallback quietly does a local `git init` on the
  /// host's own `init.defaultBranch` (often `master`) and pushes nothing.
  /// [push] adds `--push` — the current branch is pushed and set as upstream;
  /// only pass it when a commit exists (an unborn branch can't be pushed).
  Future<SSHCommandResult> createRepoInExisting({
    required String repoPath,
    required String name,
    required bool private,
    String description = '',
    String host = 'github.com',
    bool push = false,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'gh',
        'repo',
        'create',
        name,
        private ? '--private' : '--public',
        if (description.isNotEmpty) ...['--description', description],
        '--source',
        '.',
        '--remote',
        'origin',
        if (push) '--push',
      ],
      lane: ExecLane.sync,
      timeout: timeout,
      extraEnv: hostEnv(host),
    );
    if (!result.isSuccess) {
      throw GhException('gh repo create failed', result);
    }
    return result;
  }

  /// argv for a streamed clone of [slug] into [dirName] (run with the parent
  /// directory as the working dir). `-- --progress` forces git's progress
  /// output, which is otherwise suppressed off-tty.
  static List<String> cloneArgv({
    required String slug,
    required String dirName,
  }) => ['gh', 'repo', 'clone', slug, dirName, '--', '--progress'];

  /// `GH_HOST` selector for non-default hosts; null (no extra env) for
  /// github.com so the common case matches gh's own defaults exactly.
  static Map<String, String>? hostEnv(String host) =>
      host == 'github.com' ? null : {'GH_HOST': host};

  /// Owner/repo (`owner`, `name`) from a git remote URL — GitHub paths are
  /// always `owner/repo`. Returns null when the URL can't be parsed. Used for
  /// the GraphQL dashboard (which needs explicit `owner`/`name` variables;
  /// unlike REST, `gh api graphql` does not substitute `{owner}`/`{repo}`).
  static ({String owner, String name})? ownerRepoFromRemote(String url) {
    var path = url.trim();
    if (path.isEmpty) return null;
    if (path.endsWith('.git')) path = path.substring(0, path.length - 4);
    if (path.contains('://')) {
      final uri = Uri.tryParse(path);
      if (uri == null) return null;
      path = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
    } else {
      final colon = path.indexOf(':');
      if (colon < 0) return null;
      path = path.substring(colon + 1);
    }
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.length < 2) return null;
    return (owner: segs[0], name: segs[1]);
  }

  /// Calls a REST endpoint through `gh api`, e.g.
  /// `repos/{owner}/{repo}/actions/runs/:id/jobs`. `gh` substitutes the
  /// `{owner}`/`{repo}` placeholders from the repo's remote. [fields] are
  /// `key=value` pairs sent via `-f` (query params on GET, body otherwise).
  Future<dynamic> api(
    String repoPath,
    String endpoint, {
    List<String> fields = const [],
    bool paginate = false,
    String method = 'GET',
  }) async {
    final args = <String>['gh', 'api', endpoint, '--method', method];
    if (paginate) args.add('--paginate');
    for (final field in fields) {
      args.addAll(['-f', field]);
    }
    return _runJson(
      repoPath,
      args,
      'gh api $endpoint',
      // A GET is a pure read; anything else mutates forge-side state and
      // rides the single-width sync lane (never exclusive — no `gh api`
      // call touches the index/worktree).
      lane: method == 'GET' ? ExecLane.read : ExecLane.sync,
    );
  }

  /// Open pull requests for the current repo, via `gh pr list --json`.
  Future<List<PullRequest>> pullRequests(String repoPath, {int limit = 50}) async {
    final decoded = await _runJson(repoPath, [
      'gh',
      'pr',
      'list',
      '--state',
      'open',
      '--json',
      'number,title,state,isDraft,headRefName,baseRefName,author,url',
      '--limit',
      '$limit',
    ], 'gh pr list');
    return _mapList(decoded, PullRequest.fromJson, label: 'gh pr list');
  }

  /// Recent GitHub Actions workflow runs, via `gh run list --json`.
  Future<List<WorkflowRun>> workflowRuns(String repoPath, {int limit = 30}) async {
    final decoded = await _runJson(repoPath, [
      'gh',
      'run',
      'list',
      '--json',
      'databaseId,status,conclusion,headBranch,headSha,event,workflowName,url',
      '--limit',
      '$limit',
    ], 'gh run list');
    return _mapList(decoded, WorkflowRun.fromJson, label: 'gh run list');
  }

  /// Jobs of a workflow run, via the REST passthrough (returns an object with a
  /// `jobs` array). `per_page=100` covers any realistic run in one call.
  Future<List<GhJob>> runJobs(String repoPath, int runId) async {
    final decoded = await api(
      repoPath,
      'repos/{owner}/{repo}/actions/runs/$runId/jobs',
      fields: ['per_page=100'],
    );
    if (decoded is Map<String, dynamic>) {
      return _mapList(
        decoded['jobs'],
        GhJob.fromJson,
        label: 'actions/runs/$runId/jobs',
      );
    }
    return const [];
  }

  /// Polls [runJobs] until every job has completed, emitting the full jobs list
  /// on each poll. GitHub Actions exposes no live per-line log stream (unlike
  /// GitLab's `glab ci trace`), so this drives a *live status* view: statuses
  /// update as the run progresses, and completed-job logs are fetched
  /// separately via [runJobLog]. Stops once all jobs report `completed`; the
  /// caller's `autoDispose` provider cancels it when the view closes.
  Stream<List<GhJob>> runJobsStream(
    String repoPath,
    int runId, {
    Duration pollInterval = const Duration(seconds: 3),
  }) async* {
    while (true) {
      final jobs = await runJobs(repoPath, runId);
      yield jobs;
      final allDone =
          jobs.isNotEmpty && jobs.every((j) => j.status == 'completed');
      if (allDone) break;
      await Future<void>.delayed(pollInterval);
    }
  }

  /// A completed job's log via `gh run view --job <id> --log`. GitHub only
  /// serves logs once the job finishes; for an in-progress job `gh` exits
  /// non-zero and this throws [GhException] (the view shows a "logs available
  /// when the job completes" placeholder rather than calling this).
  Future<String> runJobLog(String repoPath, int jobId) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'run', 'view', '--job', '$jobId', '--log'],
      lane: ExecLane.read,
    );
    if (!result.isSuccess) {
      throw GhException('gh run view --log failed', result);
    }
    return result.stdout;
  }

  // ---- Mutations (outward-facing) ------------------------------------------

  /// Creates a pull request via `gh pr create`. Each value is a discrete argv
  /// token (shell-escaped by the formatter). `--body` is always passed (empty
  /// when none) so `gh` never falls back to an interactive editor. Like
  /// `GlabService.createMergeRequest`, no `--end-of-options`/`--` guard is added
  /// — `gh` is a cobra/pflag CLI whose parser binds the token after a
  /// value-taking flag as that flag's literal value.
  Future<void> createPullRequest(
    String repoPath, {
    required String title,
    required String head,
    required String base,
    String body = '',
    bool draft = false,
    List<String> reviewers = const [],
    List<String> assignees = const [],
    List<String> labels = const [],
    String? milestone,
  }) async {
    final args = <String>[
      'gh',
      'pr',
      'create',
      '--title',
      title,
      '--base',
      base,
      '--head',
      head,
      '--body',
      body,
      if (draft) '--draft',
      for (final r in reviewers) ...['--reviewer', r],
      for (final a in assignees) ...['--assignee', a],
      for (final l in labels) ...['--label', l],
      if (milestone != null && milestone.isNotEmpty) ...['--milestone', milestone],
    ];
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: args,
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh pr create failed', result);
    }
  }

  /// Approves a pull request via `gh pr review --approve`. (GitHub rejects
  /// approving your own PR; that surfaces as a [GhException] the UI shows.)
  Future<void> approvePullRequest(String repoPath, int number) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'pr', 'review', '$number', '--approve'],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh pr review --approve failed', result);
    }
  }

  /// Merges a pull request via `gh pr merge`. [method] is `merge` (default),
  /// `squash`, or `rebase`; passing a method flag makes `gh` run
  /// non-interactively.
  Future<void> mergePullRequest(
    String repoPath,
    int number, {
    String method = 'merge',
  }) async {
    final flag = switch (method) {
      'squash' => '--squash',
      'rebase' => '--rebase',
      _ => '--merge',
    };
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'pr', 'merge', '$number', flag],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh pr merge failed', result);
    }
  }

  /// Checks out a PR's branch locally via `gh pr checkout`. Switches the
  /// working tree — callers should guard against a dirty tree and refresh
  /// status/refs/log afterwards.
  Future<void> checkoutPullRequest(String repoPath, int number) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'pr', 'checkout', '$number'],
      // Exclusive: switches the working tree (fetch + checkout), so it must
      // never overlap a concurrent read or another mutation.
      lane: ExecLane.exclusive,
    );
    if (!result.isSuccess) {
      throw GhException('gh pr checkout failed', result);
    }
  }

  /// Re-runs the failed jobs of a workflow run via `gh run rerun --failed`
  /// (the GitHub analogue of GitLab's pipeline retry).
  Future<void> rerunFailedJobs(String repoPath, int runId) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'run', 'rerun', '$runId', '--failed'],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh run rerun failed', result);
    }
  }

  // ---- Project dashboard (GraphQL) -----------------------------------------

  /// GraphQL document for [projectDashboard].
  static const projectDashboardQuery = r'''
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, first: 30, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes { number title state author { login } labels(first: 10) { nodes { name } } }
    }
    labels(first: 100) { nodes { name color description } }
    milestones(states: OPEN, first: 50) { nodes { number title state dueOn } }
    releases(first: 20, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { tagName name publishedAt } }
  }
}
''';

  /// Extracts a joined message from a GraphQL response's `errors` array, or null
  /// when there are none.
  static String? graphqlErrorMessage(Map<String, dynamic> decoded) {
    final errors = decoded['errors'];
    if (errors is! List || errors.isEmpty) return null;
    final joined = errors
        .map((e) => e is Map ? e['message']?.toString() : e?.toString())
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .join('; ');
    return joined.isEmpty ? 'unknown GraphQL error' : joined;
  }

  /// Runs a GraphQL [query] with [variables] and returns its `data` object.
  ///
  /// Robust to `gh`'s exit-code behavior on GraphQL errors: a GraphQL query can
  /// return HTTP 200 with usable `data` *and* an `errors[]` array for some
  /// fields (a partial failure), and `gh` may still exit non-zero. So this does
  /// not gate on the exit code alone — it parses stdout first. If a non-null
  /// `data` is present it is returned (recording any `errors` non-fatally in
  /// [lastGraphqlWarning]); only when there is no usable `data` does it throw.
  Future<Map<String, dynamic>> graphql(
    String repoPath,
    String query, {
    Map<String, String> variables = const {},
    String label = 'gh api graphql',
  }) async {
    final args = <String>['gh', 'api', 'graphql', '-f', 'query=$query'];
    variables.forEach((name, value) => args.addAll(['-f', '$name=$value']));
    // Every GraphQL call this app issues is a query (the dashboard read).
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: args,
      lane: ExecLane.read,
    );

    final body = result.stdout.trim();
    Map<String, dynamic>? decoded;
    if (body.isNotEmpty) {
      try {
        final d = jsonDecode(body);
        if (d is Map<String, dynamic>) decoded = d;
      } on FormatException {
        // Fall through to the failure handling below.
      }
    }

    final data = decoded?['data'];
    if (data is Map<String, dynamic>) {
      final err = decoded == null ? null : graphqlErrorMessage(decoded);
      lastGraphqlWarning = err == null ? null : '$label: $err';
      return data;
    }

    // No usable data at all — a genuine, total failure.
    if (!result.isSuccess) {
      throw GhException('$label failed', result);
    }
    final err = decoded == null ? null : graphqlErrorMessage(decoded);
    throw GhException(err == null ? '$label returned no data' : '$label: $err', result);
  }

  /// Fetches issues, labels, milestones, and releases in one GraphQL round-trip.
  Future<GhProjectDashboard> projectDashboard(String repoPath) async {
    final remote = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['git', 'remote', 'get-url', 'origin'],
      timeout: const Duration(seconds: 20),
      lane: ExecLane.read,
    );
    final slug = ownerRepoFromRemote(remote.stdout.trim());
    if (slug == null) {
      throw GhException(
        'could not resolve a GitHub owner/repo from the origin remote',
        remote,
      );
    }
    final data = await graphql(
      repoPath,
      projectDashboardQuery,
      variables: {'owner': slug.owner, 'name': slug.name},
      label: 'gh api graphql dashboard',
    );
    final repo = data['repository'];
    if (repo is! Map<String, dynamic>) return const GhProjectDashboard();
    return _parseProjectDashboard(repo);
  }

  GhProjectDashboard _parseProjectDashboard(Map<String, dynamic> repo) {
    List<T> nodes<T>(String key, T Function(Map<String, dynamic>) from) {
      final conn = repo[key];
      if (conn is! Map<String, dynamic>) return const [];
      final list = conn['nodes'];
      if (list is! List) return const [];
      return list.whereType<Map<String, dynamic>>().map(from).toList();
    }

    GhIssue issueFromGql(Map<String, dynamic> n) {
      final labelsConn = n['labels'];
      final labelNodes = labelsConn is Map ? labelsConn['nodes'] : null;
      final labels = labelNodes is List
          ? labelNodes
                .whereType<Map<String, dynamic>>()
                .map((l) => l['name'] as String? ?? '')
                .where((s) => s.isNotEmpty)
                .toList()
          : const <String>[];
      final author = n['author'];
      return GhIssue(
        number: (n['number'] as num?)?.toInt() ?? 0,
        title: n['title'] as String? ?? '',
        state: (n['state'] as String? ?? 'open').toLowerCase(),
        authorLogin: author is Map ? author['login'] as String? : null,
        labels: labels,
      );
    }

    GhLabel labelFromGql(Map<String, dynamic> n) => GhLabel(
      name: n['name'] as String? ?? '',
      color: normalizeGhLabelColor(n['color'] as String?),
      description: n['description'] as String?,
    );

    GhMilestone milestoneFromGql(Map<String, dynamic> n) => GhMilestone(
      number: (n['number'] as num?)?.toInt() ?? 0,
      title: n['title'] as String? ?? '',
      state: (n['state'] as String? ?? 'open').toLowerCase(),
      dueOn: n['dueOn'] as String?,
    );

    GhRelease releaseFromGql(Map<String, dynamic> n) => GhRelease(
      tagName: n['tagName'] as String? ?? '',
      name: n['name'] as String? ?? '',
      publishedAt: n['publishedAt'] as String?,
    );

    return GhProjectDashboard(
      issues: nodes('issues', issueFromGql),
      labels: nodes('labels', labelFromGql),
      milestones: nodes('milestones', milestoneFromGql),
      releases: nodes('releases', releaseFromGql),
    );
  }

  Future<dynamic> _runJson(
    String repoPath,
    List<String> args,
    String label, {
    ExecLane lane = ExecLane.read,
    Map<String, String>? extraEnv,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: args,
      lane: lane,
      extraEnv: extraEnv,
    );
    if (!result.isSuccess) {
      throw GhException('$label failed', result);
    }
    final body = result.stdout.trim();
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw GhException('$label returned non-JSON output: ${e.message}', result);
    }
  }

  /// Maps a decoded JSON list through [from]. A `null` decode is an empty
  /// result; a non-list (a malformed response) throws, so "no rows" is
  /// distinguishable from "something is broken" — mirrors `GlabService`.
  List<T> _mapList<T>(
    dynamic decoded,
    T Function(Map<String, dynamic>) from, {
    String label = 'gh response',
  }) {
    if (decoded == null) return const [];
    if (decoded is! List) {
      throw GhException(
        '$label: expected a JSON array, got ${decoded.runtimeType}',
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
    }
    return decoded.whereType<Map<String, dynamic>>().map(from).toList();
  }
}
