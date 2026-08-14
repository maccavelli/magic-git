import 'dart:convert';
import '../forge/forge.dart';
import '../forge/forge_dashboard.dart';
import '../forge/forge_json.dart';
import '../forge/forge_repo_summary.dart';
import '../forge/merge_plan.dart';
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
  /// Ceiling for [workflowRuns]'s full-history mode: 2000 = the GitLab side's
  /// own hard stop (20 pages × 100 — `GlabService._maxListPages`), so neither
  /// forge's "Show more" fetches deeper than the other. A bound, not a page
  /// walk, because `gh run list --limit` paginates internally.
  static const int fullHistoryLimit = 2000;

  /// Safety bound on manual REST page walks ([listMilestones]) — matches
  /// `GlabService._maxListPages` so both forges stop at the same depth.
  static const int _maxListPages = 20;

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

  /// Creates [name] on [host] as an empty forge project — API only.
  ///
  /// Does **not** pass `--source` / `--remote` / `--push`: those make `gh`
  /// nest an unhardened `git` that can fail (or exit non-zero after the API
  /// project already exists) under a Finder-launched GUI or bare SSH exec
  /// channel. The create-repo wizard inits locally first, then wires
  /// `origin` and pushes with PATH-hardened `git` via [cloneUrl].
  Future<SSHCommandResult> createRepoInExisting({
    required String repoPath,
    required String name,
    required bool private,
    String description = '',
    String host = 'github.com',
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

  /// Resolves the clone URL for `origin` after [createRepoInExisting] —
  /// layered sources, never throws, and always says what it tried
  /// ([OriginUrlResolution.detail]) so a live wiring failure is diagnosable
  /// from the sheet's warning instead of a bare "could not be determined".
  ///
  /// Source order:
  ///  1. [createOutput] — `gh repo create` prints the new repo's URL on
  ///     stdout (verified live against gh 2.96); parsing it back costs zero
  ///     round trips and cannot race post-create eventual consistency. Taken
  ///     directly for https users; SSH users still get the lookup first
  ///     (create prints only the https form) with this as the fallback.
  ///  2. `gh repo view <name> --json url,sshUrl` — the bare name resolves
  ///     against the authenticated account exactly as create did (verified
  ///     live). Retried briefly for eventual consistency; picks the URL
  ///     matching the user's `git_protocol`.
  Future<OriginUrlResolution> resolveOriginUrl({
    required String repoPath,
    required String name,
    String host = 'github.com',
    String? createOutput,
    int retries = 2,
  }) async {
    final notes = <String>[];
    final protocol = await _gitProtocol(repoPath, host);
    final fromCreate = createOutput == null
        ? null
        : forgeUrlFromCreateOutput(createOutput, name: name);
    if (fromCreate != null && protocol != 'ssh') {
      return (url: fromCreate, detail: 'from gh repo create output');
    }
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
      try {
        final decoded = await _runJson(
          repoPath,
          ['gh', 'repo', 'view', name, '--json', 'url,sshUrl'],
          'gh repo view',
          extraEnv: hostEnv(host),
        );
        if (decoded is! Map) {
          notes.add('gh repo view returned no object');
          continue;
        }
        final https = decoded['url'];
        final ssh = decoded['sshUrl'];
        if (protocol == 'ssh' && ssh is String && ssh.isNotEmpty) {
          return (url: ssh, detail: 'from gh repo view (ssh)');
        }
        if (https is String && https.isNotEmpty) {
          final url = https.endsWith('.git') ? https : '$https.git';
          return (url: url, detail: 'from gh repo view');
        }
        if (ssh is String && ssh.isNotEmpty) {
          return (url: ssh, detail: 'from gh repo view (ssh only)');
        }
        notes.add('gh repo view carried neither url nor sshUrl');
      } on GhException catch (e) {
        notes.add(
          _firstLine(
            e.result.stderr,
            fallback:
                'gh repo view failed '
                '(exit ${e.result.exitCode})',
          ),
        );
      } catch (e) {
        notes.add('$e');
      }
    }
    if (fromCreate != null) {
      // SSH-protocol user whose lookup never resolved: a working https origin
      // beats none (git auth still works; the user can rewrite it to SSH).
      return (
        url: fromCreate,
        detail:
            'from gh repo create output (ssh lookup unavailable: '
            '${notes.join('; ')})',
      );
    }
    return (
      url: null,
      detail: notes.isEmpty
          ? 'no URL source produced output'
          : notes.join('; '),
    );
  }

  /// First non-empty line of [text], or [fallback] — keeps CLI stderr
  /// readable inside a one-line diagnostic trail.
  static String _firstLine(String text, {required String fallback}) {
    for (final line in const LineSplitter().convert(text)) {
      final t = line.trim();
      if (t.isNotEmpty) return t;
    }
    return fallback;
  }

  /// The user's configured clone protocol for [host] (`gh config get
  /// git_protocol`) — `ssh` or `https`; defaults to `https` (gh's own default)
  /// on any error, so a failed probe never blocks remote repair.
  Future<String> _gitProtocol(String repoPath, String host) async {
    try {
      final result = await _executor.execute(
        repoPath: repoPath,
        gitArgs: ['gh', 'config', 'get', 'git_protocol', '-h', host],
        lane: ExecLane.read,
        extraEnv: hostEnv(host),
      );
      return result.stdout.trim().toLowerCase() == 'ssh' ? 'ssh' : 'https';
    } catch (_) {
      return 'https';
    }
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
    final path = remotePathFromUrl(url);
    if (path == null) return null;
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.length < 2) return null;
    return (owner: segs[0], name: segs[1]);
  }

  /// Calls a REST endpoint through `gh api`, e.g.
  /// `repos/{owner}/{repo}/actions/runs/:id/jobs`. `gh` substitutes the
  /// `{owner}`/`{repo}` placeholders from the repo's remote. [fields] are
  /// `key=value` pairs sent via `-f` (query params on GET, body otherwise).
  ///
  /// Deliberately no `--paginate` option: for a REST endpoint that returns an
  /// array, `gh api --paginate` emits one JSON array **per page** back-to-back
  /// (`[…][…]`) — not a single document — which [jsonDecode] rejects. (glab's
  /// `--paginate` merges pages into one array; gh's does not.) Callers that
  /// need more than a page hand-walk with `per_page`/`page` fields instead,
  /// like [listMilestones].
  Future<dynamic> api(
    String repoPath,
    String endpoint, {
    List<String> fields = const [],
    String method = 'GET',
  }) async {
    final args = <String>['gh', 'api', endpoint, '--method', method];
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
  ///
  /// [limit] matches the GitLab side's paginated ceiling (20 pages × 30 —
  /// see `GlabService.mergeRequests`), so neither forge silently shows a
  /// shorter list than the other. It was 50 by accident of history, which
  /// silently truncated busy repos.
  Future<List<PullRequest>> pullRequests(
    String repoPath, {
    int limit = 600,
  }) async {
    final decoded = await _runJson(repoPath, [
      'gh',
      'pr',
      'list',
      '--state',
      'open',
      '--json',
      'number,title,state,isDraft,headRefName,baseRefName,author,url,'
          'labels,assignees,reviewDecision,milestone',
      '--limit',
      '$limit',
    ], 'gh pr list');
    return _mapList(decoded, PullRequest.fromJson, label: 'gh pr list');
  }

  /// JSON fields requested for [pullRequestDetail] / edit form. Includes list
  /// identity plus mergeability, head SHA, body, and auto-merge state.
  static const String _prDetailJsonFields =
      'number,title,state,isDraft,headRefName,baseRefName,author,url,'
      'labels,assignees,reviewDecision,milestone,body,headRefOid,baseRefOid,'
      'mergeable,mergeStateStatus,autoMergeRequest,additions,deletions,'
      'changedFiles,maintainerCanModify,isCrossRepository';

  /// A single open/closed PR including mergeability and head SHA, via
  /// `gh pr view <number> --json …`. Powers the detail pane and merge plan;
  /// list queries stay light and omit expensive fields.
  Future<PullRequest> pullRequestDetail(String repoPath, int number) async {
    final decoded = await _runJson(repoPath, [
      'gh',
      'pr',
      'view',
      '$number',
      '--json',
      _prDetailJsonFields,
    ], 'gh pr view');
    if (decoded is Map<String, dynamic>) {
      return PullRequest.fromJson(decoded);
    }
    throw const GhException(
      'gh pr view: expected a JSON object',
      SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
  }

  /// Repo-level merge method / auto-merge policy via
  /// `gh api repos/{owner}/{repo}`. Cached by the provider; failures should
  /// be treated as "unknown policy" by callers.
  Future<GhRepoMergePolicy> repoMergePolicy(String repoPath) async {
    final decoded = await api(repoPath, 'repos/{owner}/{repo}');
    if (decoded is Map<String, dynamic>) {
      return GhRepoMergePolicy.fromJson(decoded);
    }
    throw const GhException(
      'gh api repos/{owner}/{repo}: expected a JSON object',
      SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
  }

  /// Updates a PR branch with the base branch tip via
  /// `PUT repos/{owner}/{repo}/pulls/{number}/update-branch`.
  /// Optional [expectedHeadSha] is sent as `expected_head_sha` when known.
  Future<void> updatePullRequestBranch(
    String repoPath,
    int number, {
    String? expectedHeadSha,
  }) async {
    await api(
      repoPath,
      'repos/{owner}/{repo}/pulls/$number/update-branch',
      method: 'PUT',
      fields: [
        if (expectedHeadSha != null && expectedHeadSha.isNotEmpty)
          'expected_head_sha=$expectedHeadSha',
      ],
    );
  }

  /// Recent GitHub Actions workflow runs, via `gh run list --json`. [limit]
  /// matches the GitLab side's pipeline page size — see
  /// `GlabService.pipelines`. [allHistory] (the Forge panel's "Show more")
  /// raises it to [fullHistoryLimit] instead; gh pages the API internally,
  /// so a single big `--limit` is the whole mechanism.
  Future<List<WorkflowRun>> workflowRuns(
    String repoPath, {
    int limit = 30,
    bool allHistory = false,
  }) async {
    if (allHistory) limit = fullHistoryLimit;
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
  /// `jobs` array).
  ///
  /// Page-walked, bounded by [_maxListPages] — mirrors [GlabService.jobs]. A
  /// single `per_page=100` page silently truncated a matrix run wider than 100
  /// jobs (OS × version × shard exceeds it readily): jobs 101+ were invisible,
  /// a failure past #100 couldn't be selected, and — worse — [runJobsStream]'s
  /// `every(completed)` on that partial page could end the poll while the run
  /// was still going. Walk until a short (< perPage) page marks the end. The
  /// response's `total_count` bounds each page's `jobs` array, so a short page
  /// is an honest terminator.
  Future<List<GhJob>> runJobs(String repoPath, int runId) async {
    const perPage = 100;
    final all = <GhJob>[];
    for (var page = 1; page <= _maxListPages; page++) {
      final decoded = await api(
        repoPath,
        'repos/{owner}/{repo}/actions/runs/$runId/jobs',
        fields: ['per_page=$perPage', 'page=$page'],
      );
      if (decoded is! Map<String, dynamic>) break;
      final batch = _mapList(
        decoded['jobs'],
        GhJob.fromJson,
        label: 'actions/runs/$runId/jobs',
      );
      all.addAll(batch);
      if (batch.length < perPage) break; // last (short) page reached
    }
    return all;
  }

  /// Polls [runJobs] until every job has completed, emitting the full jobs list
  /// on each poll. GitHub Actions exposes no live per-line log stream (unlike
  /// GitLab's `glab ci trace`), so this drives a *live status* view: statuses
  /// update as the run progresses, and completed-job logs are fetched
  /// separately via [runJobLog]. Stops once all jobs report `completed`; the
  /// caller's `autoDispose` provider cancels it when the view closes.
  ///
  /// A run that has genuinely finished but reports no jobs (deleted mid-queue, a
  /// workflow that produces none, an API hiccup that keeps answering `[]`) must
  /// not poll forever: after [maxEmptyPolls] such empty answers the stream ends
  /// — the view's manual refresh restarts it if the user still cares. Crucially,
  /// an empty answer from a run that is still *queued* (waiting on a runner)
  /// does NOT count toward that cap: a busy or slow-runner queue legitimately
  /// reports zero jobs for minutes, and abandoning the view then is exactly when
  /// it's needed most.
  ///
  /// A transient failure on any single poll — the SSH session being superseded
  /// by a reconnect, a timeout, a one-off 5xx — is skipped rather than fatal:
  /// the view keeps polling and recovers when the link does. Only
  /// [maxConsecutiveErrors] failures in a row (a durable problem: auth lost, run
  /// deleted) end the stream with the error surfaced.
  Stream<List<GhJob>> runJobsStream(
    String repoPath,
    int runId, {
    Duration pollInterval = const Duration(seconds: 3),
    int maxEmptyPolls = 40,
    int maxConsecutiveErrors = 10,
  }) async* {
    var emptyPolls = 0;
    var errorStreak = 0;
    while (true) {
      final List<GhJob> jobs;
      final bool runFinished;
      try {
        jobs = await runJobs(repoPath, runId);
        // The run's own status is only needed to adjudicate an empty jobs list;
        // skip the extra call whenever there are jobs to show.
        runFinished = jobs.isEmpty
            ? await _runReportsFinished(repoPath, runId)
            : false;
        errorStreak = 0;
      } catch (e) {
        errorStreak++;
        if (errorStreak >= maxConsecutiveErrors) rethrow;
        await Future<void>.delayed(pollInterval);
        continue;
      }
      yield jobs;
      if (jobs.isEmpty) {
        if (runFinished) {
          emptyPolls++;
          if (emptyPolls >= maxEmptyPolls) break;
        } else {
          emptyPolls = 0; // still queued — a jobless answer here is expected.
        }
      } else {
        emptyPolls = 0;
        if (jobs.every((j) => j.status == 'completed')) break;
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Whether the run reports a terminal top-level status — used only to
  /// adjudicate an empty jobs list (queued-but-jobless vs. finished-with-no-
  /// jobs). On any ambiguity (status unreadable or an unexpected shape) it
  /// returns true, so the empty-poll give-up safety net still applies to a
  /// genuinely dead run rather than polling it forever.
  Future<bool> _runReportsFinished(String repoPath, int runId) async {
    final decoded = await api(
      repoPath,
      'repos/{owner}/{repo}/actions/runs/$runId',
    );
    if (decoded is Map<String, dynamic>) {
      // GitHub run status: queued | in_progress | completed (+ newer
      // waiting/requested/pending, all non-terminal). Only 'completed' means no
      // more jobs are coming.
      final status = decoded['status'];
      if (status is String) return status == 'completed';
    }
    return true;
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
      compress: true,
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
      if (milestone != null && milestone.isNotEmpty) ...[
        '--milestone',
        milestone,
      ],
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

  // ---- Issues & milestones -------------------------------------------------

  /// Open issues for the current repo via `gh issue list --json`. Like
  /// [pullRequests], `gh` paginates internally, so a single [limit] is the
  /// whole mechanism — [allHistory] (the panel's "Show more") raises it to
  /// [fullHistoryLimit].
  Future<List<ForgeIssue>> listIssues(
    String repoPath, {
    int limit = 30,
    bool allHistory = false,
  }) async {
    if (allHistory) limit = fullHistoryLimit;
    final decoded = await _runJson(repoPath, [
      'gh',
      'issue',
      'list',
      '--state',
      'open',
      '--json',
      'number,title,state,author,labels',
      '--limit',
      '$limit',
    ], 'gh issue list');
    return _mapList(decoded, ForgeIssue.fromGhCli, label: 'gh issue list');
  }

  /// A single issue including its body, via `gh issue view <number> --json`.
  /// Powers the detail pane (the list query omits `body` to stay light).
  Future<ForgeIssue> issueDetail(String repoPath, int number) async {
    final decoded = await _runJson(repoPath, [
      'gh',
      'issue',
      'view',
      '$number',
      '--json',
      'number,title,state,author,labels,body',
    ], 'gh issue view');
    if (decoded is Map<String, dynamic>) return ForgeIssue.fromGhCli(decoded);
    throw const GhException(
      'gh issue view: expected a JSON object',
      SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
  }

  /// Open milestones for the current repo via the REST passthrough. GitHub has
  /// no `gh milestone` command, so this uses `gh api …/milestones`; the payload
  /// already carries each milestone's description. Hand page-walked like the
  /// GitLab side (`GlabService.listMilestones`) because `gh api --paginate`
  /// concatenates per-page arrays into invalid JSON (see [api]): [allHistory]
  /// walks until a short page (capped at [_maxListPages]); otherwise just the
  /// newest [perPage].
  Future<List<ForgeMilestone>> listMilestones(
    String repoPath, {
    int perPage = 30,
    bool allHistory = false,
  }) async {
    final all = <ForgeMilestone>[];
    for (var page = 1; page <= _maxListPages; page++) {
      final decoded = await api(
        repoPath,
        'repos/{owner}/{repo}/milestones',
        fields: ['state=open', 'per_page=$perPage', 'page=$page'],
      );
      final batch = _mapList(
        decoded,
        ForgeMilestone.fromGhRest,
        label: 'repos/{owner}/{repo}/milestones',
      );
      all.addAll(batch);
      if (!allHistory || batch.length < perPage) break;
    }
    return all;
  }

  /// Protected branch names via `repos/{owner}/{repo}/branches?protected=true`.
  ///
  /// The LIST endpoint, deliberately — not per-branch `/protection`, which is
  /// one round trip per branch and 403s for non-admins, so ordinary
  /// collaborators would see "unknown" on a repo whose protection is plainly
  /// visible. This one needs only read access.
  ///
  /// Caveat worth keeping in mind: the `protected` flag covers classic branch
  /// protection and the rulesets GitHub surfaces through it, but a repo
  /// *ruleset* the branches API cannot represent stays invisible here. That is
  /// why the caller reports unknown-protection rather than implying certainty.
  Future<List<String>> protectedBranchNames(
    String repoPath, {
    int perPage = 100,
  }) async {
    final all = <String>[];
    for (var page = 1; page <= _maxListPages; page++) {
      final decoded = await api(
        repoPath,
        'repos/{owner}/{repo}/branches',
        fields: ['protected=true', 'per_page=$perPage', 'page=$page'],
      );
      if (decoded is! List) {
        throw GhException(
          'repos/{owner}/{repo}/branches: expected a JSON array, got '
          '${decoded.runtimeType}',
          const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
        );
      }
      final batch = <String>[
        for (final e in decoded.whereType<Map<String, dynamic>>())
          if (e['name'] case final String n) n,
      ];
      all.addAll(batch);
      if (decoded.length < perPage) break; // last (short) page reached
    }
    return all;
  }

  /// Creates an issue via `gh issue create`. Like [createPullRequest], `--body`
  /// is always passed (empty when none) so `gh` never drops into an interactive
  /// editor, and no `--end-of-options` guard is added (cobra/pflag binds the
  /// token after a value-taking flag as its literal value).
  Future<void> createIssue(
    String repoPath, {
    required String title,
    String body = '',
    List<String> labels = const [],
    List<String> assignees = const [],
    String? milestone,
  }) async {
    final args = <String>[
      'gh',
      'issue',
      'create',
      '--title',
      title,
      '--body',
      body,
      for (final l in labels) ...['--label', l],
      for (final a in assignees) ...['--assignee', a],
      if (milestone != null && milestone.isNotEmpty) ...[
        '--milestone',
        milestone,
      ],
    ];
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: args,
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh issue create failed', result);
    }
  }

  /// Closes an issue via `gh issue close` (reversible — see [reopenIssue]).
  Future<void> closeIssue(String repoPath, int number) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'issue', 'close', '$number'],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh issue close failed', result);
    }
  }

  /// Reopens a closed issue via `gh issue reopen`.
  Future<void> reopenIssue(String repoPath, int number) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'issue', 'reopen', '$number'],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh issue reopen failed', result);
    }
  }

  /// Lists issue conversation comments (`gh api …/issues/{n}/comments`).
  Future<List<ForgeComment>> listIssueComments(
    String repoPath,
    int number,
  ) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'gh',
        'api',
        'repos/{owner}/{repo}/issues/$number/comments',
        '--paginate',
      ],
      lane: ExecLane.read,
    );
    if (!result.isSuccess) {
      throw GhException('gh api issue comments failed', result);
    }
    return _parseIssueComments(result.stdout);
  }

  /// Conversation comments on a pull request. GitHub stores these on the
  /// shared issue-comments API (`/issues/{n}/comments`), not review threads.
  Future<List<ForgeComment>> listPullRequestComments(
    String repoPath,
    int number,
  ) => listIssueComments(repoPath, number);

  List<ForgeComment> _parseIssueComments(String stdout) {
    final raw = stdout.trim();
    if (raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    final List<dynamic> list = decoded is List
        ? decoded
        : decoded is Map && decoded['items'] is List
        ? decoded['items'] as List<dynamic>
        : const <dynamic>[];
    return [
      for (final item in list)
        if (item is Map)
          ForgeComment(
            id: '${item['id'] ?? ''}',
            author: item['user'] is Map
                ? (item['user'] as Map)['login'] as String? ?? ''
                : '',
            body: item['body'] as String? ?? '',
            createdAt: item['created_at'] as String?,
          ),
    ];
  }

  /// Adds a comment to an issue via `gh issue comment --body` (a discrete argv
  /// token, so newlines/`=`/markdown survive).
  Future<void> commentOnIssue(String repoPath, int number, String body) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'issue', 'comment', '$number', '--body', body],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh issue comment failed', result);
    }
  }

  /// Edits an issue's title (and/or body) via `gh issue edit`. Only the
  /// provided fields are sent.
  Future<void> editIssue(
    String repoPath,
    int number, {
    String? title,
    String? body,
  }) async {
    final args = <String>[
      'gh',
      'issue',
      'edit',
      '$number',
      if (title != null) ...['--title', title],
      if (body != null) ...['--body', body],
    ];
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: args,
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh issue edit failed', result);
    }
  }

  /// Assigns the authenticated user to an issue via
  /// `gh issue edit --add-assignee @me` (`@me` is gh's own current-user token).
  Future<void> assignIssueToMe(String repoPath, int number) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'issue', 'edit', '$number', '--add-assignee', '@me'],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh issue edit --add-assignee failed', result);
    }
  }

  /// "Start work": creates a branch linked to the issue and checks it out, via
  /// `gh issue develop <number> --checkout`. Switches the working tree (fetch +
  /// branch + checkout), so it rides the exclusive lane — callers guard a dirty
  /// tree and refresh status/refs/log afterwards, exactly like
  /// [checkoutPullRequest].
  Future<void> developIssueBranch(String repoPath, int number) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'issue', 'develop', '$number', '--checkout'],
      lane: ExecLane.exclusive,
    );
    if (!result.isSuccess) {
      throw GhException('gh issue develop failed', result);
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
  /// non-interactively. [deleteBranch] adds `--delete-branch`, which removes
  /// the (now-merged) head branch on the remote and locally — the web UI's
  /// "delete branch after merge" checkbox.
  ///
  /// [matchHeadCommit] pins the merge to the reviewed tip
  /// (`--match-head-commit`) so a push between view and merge cannot land
  /// unreviewed commits. Prefer always passing the detail [PullRequest.headOid]
  /// when known.
  ///
  /// [auto] enables GitHub auto-merge (`--auto`); [disableAuto] cancels it
  /// (`--disable-auto`). [admin] is a privileged bypass (`--admin`) — use only
  /// from an explicit secondary UI path. [subject]/[body] set squash/merge
  /// commit title and body (`-t` / `-b`).
  Future<void> mergePullRequest(
    String repoPath,
    int number, {
    String method = 'merge',
    bool deleteBranch = false,
    String? matchHeadCommit,
    bool auto = false,
    bool disableAuto = false,
    bool admin = false,
    String? subject,
    String? body,
  }) async {
    final flag = switch (method) {
      'squash' => '--squash',
      'rebase' => '--rebase',
      _ => '--merge',
    };
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'gh',
        'pr',
        'merge',
        '$number',
        flag,
        if (deleteBranch) '--delete-branch',
        if (matchHeadCommit != null && matchHeadCommit.isNotEmpty) ...[
          '--match-head-commit',
          matchHeadCommit,
        ],
        if (auto) '--auto',
        if (disableAuto) '--disable-auto',
        if (admin) '--admin',
        if (subject != null) ...['-t', subject],
        if (body != null) ...['-b', body],
      ],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh pr merge failed', result);
    }
  }

  /// Closes an open pull request via `gh pr close` (reversible — see
  /// [reopenPullRequest]).
  Future<void> closePullRequest(String repoPath, int number) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'pr', 'close', '$number'],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh pr close failed', result);
    }
  }

  /// Reopens a closed pull request via `gh pr reopen`.
  Future<void> reopenPullRequest(String repoPath, int number) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'pr', 'reopen', '$number'],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh pr reopen failed', result);
    }
  }

  /// Marks a PR ready for review, or converts it back to a draft, via
  /// `gh pr ready [<number>] [--undo]`. [draft] true converts a ready PR back
  /// to draft (`--undo`); false marks a draft ready.
  Future<void> setPullRequestDraft(
    String repoPath,
    int number, {
    required bool draft,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'pr', 'ready', '$number', if (draft) '--undo'],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh pr ready failed', result);
    }
  }

  /// Adds a comment to a PR via `gh pr comment --body`. The body is a discrete
  /// argv token (shell-escaped), so it carries newlines/`=`/markdown intact.
  Future<void> commentOnPullRequest(
    String repoPath,
    int number,
    String body,
  ) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['gh', 'pr', 'comment', '$number', '--body', body],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh pr comment failed', result);
    }
  }

  /// Submits a "request changes" review via `gh pr review --request-changes`.
  /// GitHub requires a non-empty body for this review type (and rejects
  /// requesting changes on your own PR — both surface as a [GhException]).
  Future<void> requestChangesOnPullRequest(
    String repoPath,
    int number,
    String body,
  ) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'gh',
        'pr',
        'review',
        '$number',
        '--request-changes',
        '--body',
        body,
      ],
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh pr review --request-changes failed', result);
    }
  }

  /// Edits a PR's title and/or description via `gh pr edit`. Only the provided
  /// fields are sent, so a title-only edit leaves the body untouched.
  Future<void> editPullRequest(
    String repoPath,
    int number, {
    String? title,
    String? body,
  }) async {
    final args = <String>[
      'gh',
      'pr',
      'edit',
      '$number',
      if (title != null) ...['--title', title],
      if (body != null) ...['--body', body],
    ];
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: args,
      lane: ExecLane.sync,
    );
    if (!result.isSuccess) {
      throw GhException('gh pr edit failed', result);
    }
  }

  /// Fetches a pull request's editable fields (title + body) for the edit
  /// form. `gh pr view --json` is the machine contract; the list query omits
  /// `body` to stay light, so this is the on-demand fetch behind "Edit…".
  /// Editable title + body for the edit form. Implemented via
  /// [pullRequestDetail] so selection and edit share one fetch shape.
  Future<({String title, String body})> pullRequestFields(
    String repoPath,
    int number,
  ) async {
    final d = await pullRequestDetail(repoPath, number);
    return (title: d.title, body: d.body ?? '');
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
      totalCount
      nodes { number title state author { login } labels(first: 10) { nodes { name } } }
    }
    labels(first: 100) { totalCount nodes { name color description } }
    milestones(states: OPEN, first: 50) { totalCount nodes { number title state dueOn } }
    releases(first: 20, orderBy: {field: CREATED_AT, direction: DESC}) { totalCount nodes { tagName name publishedAt description author { login } } }
  }
}
''';

  /// Extracts a joined message from a GraphQL response's `errors` array, or
  /// null when there are none — see [joinedGraphqlErrors].
  static String? graphqlErrorMessage(Map<String, dynamic> decoded) =>
      joinedGraphqlErrors(decoded);

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
    // Reset up front so no return/throw path can leak the previous call's
    // warning into this one — the field is only meaningful immediately after
    // this call returns.
    lastGraphqlWarning = null;
    final args = <String>['gh', 'api', 'graphql', '-f', 'query=$query'];
    variables.forEach((name, value) => args.addAll(['-f', '$name=$value']));
    // Every GraphQL call this app issues is a query (the dashboard read).
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: args,
      lane: ExecLane.read,
      compress: true,
    );

    final body = result.stdout.trim();
    Map<String, dynamic>? decoded;
    if (body.isNotEmpty) {
      try {
        final d = await decodeJsonMaybeOffThread(body);
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
    throw GhException(
      err == null ? '$label returned no data' : '$label: $err',
      result,
    );
  }

  /// Fetches issues, labels, milestones, and releases in one GraphQL round-trip.
  Future<ForgeProjectDashboard> projectDashboard(String repoPath) async {
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
    // Per [lastGraphqlWarning]'s contract: capture immediately after the
    // await, then carry it on the result so the UI never has to read the
    // racy service field at widget-build time.
    final warning = lastGraphqlWarning;
    final repo = data['repository'];
    if (repo is! Map<String, dynamic>) {
      // GitHub resolves a missing or inaccessible repository to
      // `repository: null` plus a NOT_FOUND entry in `errors[]` — `data` is
      // present, so graphql() rightly treats it as partial success. For the
      // dashboard a null repository IS total failure; rendering it as an
      // empty project hid bad slugs and missing access behind "No open
      // issues".
      throw GhException(
        warning ?? 'GitHub reports no repository at ${slug.owner}/${slug.name}',
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
    }
    return _parseProjectDashboard(repo, warning: warning);
  }

  ForgeProjectDashboard _parseProjectDashboard(
    Map<String, dynamic> repo, {
    String? warning,
  }) => ForgeProjectDashboard(
    issues: graphqlNodes(repo['issues'], ForgeIssue.fromGhGql),
    labels: graphqlNodes(repo['labels'], ForgeLabel.fromGhGql),
    milestones: graphqlNodes(repo['milestones'], ForgeMilestone.fromGhGql),
    releases: graphqlNodes(repo['releases'], ForgeRelease.fromGhGql),
    issuesTotal: graphqlConnectionCount(repo['issues']),
    labelsTotal: graphqlConnectionCount(repo['labels']),
    milestonesTotal: graphqlConnectionCount(repo['milestones']),
    releasesTotal: graphqlConnectionCount(repo['releases']),
    warning: warning,
  );

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
      // Large JSON list/api payloads compress well; only on reads — mutations
      // are small and must not pay the shell+gzip pipeline cost.
      compress: lane == ExecLane.read,
      extraEnv: extraEnv,
    );
    if (!result.isSuccess) {
      throw GhException('$label failed', result);
    }
    final body = result.stdout.trim();
    if (body.isEmpty) return null;
    try {
      return await decodeJsonMaybeOffThread(body);
    } on FormatException catch (e) {
      throw GhException(
        '$label returned non-JSON output: ${e.message}',
        result,
      );
    }
  }

  /// Shared list mapping (see [mapJsonList]) throwing this service's typed
  /// exception on a malformed response.
  List<T> _mapList<T>(
    dynamic decoded,
    T Function(Map<String, dynamic>) from, {
    String label = 'gh response',
  }) => mapJsonList(
    decoded,
    from,
    onMalformed: (m) => throw GhException(
      '$label: $m',
      const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
    ),
  );
}
