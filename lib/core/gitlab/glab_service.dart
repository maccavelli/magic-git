import 'dart:async';
import 'dart:convert';
import '../ssh/ssh_command_executor.dart';
import '../utils/bounded_tail.dart';
import 'models.dart';

/// Thrown when a `glab` invocation fails. Because glab exit codes are known to
/// be unreliable (e.g. `glab auth status` has returned 0 on a 401), callers
/// should treat this as "could not obtain data" and surface [result.stderr]
/// rather than guessing the cause.
class GlabException implements Exception {
  final String message;
  final SSHCommandResult result;

  const GlabException(this.message, this.result);

  @override
  String toString() =>
      'GlabException: $message (exit ${result.exitCode})\n${result.stderr}';
}

/// Drives the remote `glab` CLI through the shared [SSHCommandExecutor].
///
/// The primary interface is [api] — the generic `glab api` passthrough — which
/// returns real JSON (a stable contract) instead of human-formatted CLI text,
/// and inherits the remote host's `glab auth` credentials and host resolution
/// from the repo's working directory.
///
/// Authentication is **the remote's own `glab auth` store**. No token ever
/// appears in a command line or environment prelude (which would leak it via
/// `ps`/`/proc/<pid>/cmdline` on a shared host). When the user supplies a token
/// for a connection, [loginWithToken] pipes it once over stdin into
/// `glab auth login --stdin`; every later call just uses the stored credential.
class GlabService {
  final CommandExecutor _executor;

  GlabService(this._executor);

  /// Non-fatal warning from the most recent [graphql] call, or null when that
  /// call had none. Set when GitLab's GraphQL response carried a non-empty
  /// `errors[]` array *alongside* usable `data` (e.g. no permission on one
  /// field of a multi-field query) — a partial failure that used to blank the
  /// entire result (see [graphql]'s doc). Mirrors `ConnectionState.warning`'s
  /// style: a short, human-readable string that rides along with an otherwise
  /// successful result rather than blocking it. Instance-scoped (not
  /// per-call), so a caller that cares should read it immediately after
  /// awaiting [graphql]/[projectDashboard] — a later concurrent call would
  /// overwrite it first.
  String? lastGraphqlWarning;

  /// Authenticates the remote's `glab` against the repo's GitLab host by piping
  /// [token] over stdin to `glab auth login --stdin`. The token is written to
  /// the process's standard input — never to argv, the command string, or an
  /// environment assignment — so it cannot leak through the remote process
  /// table. glab persists it to its own credential store, and all subsequent
  /// calls authenticate from there.
  ///
  /// The GitLab host is resolved from the repo's `origin` remote so the token is
  /// stored against the correct instance. Throws [GlabException] if the host
  /// can't be determined, [token] is blank, or the login fails.
  Future<void> loginWithToken(String repoPath, String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      // `glab auth login --stdin` does not reject a blank/whitespace-only
      // stdin — it silently falls into an interactive OAuth device-flow
      // (prints an authorize URL, opens a local HTTP listener) that just
      // hangs until the executor's own timeout eventually kills it. Reject
      // here, at the service boundary, rather than relying on every caller to
      // pre-trim (today only the UI layer happens to).
      throw const GlabException(
        'glab auth login: refusing a blank token',
        SSHCommandResult(exitCode: -1, stdout: '', stderr: ''),
      );
    }
    final remote = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['git', 'remote', 'get-url', 'origin'],
      timeout: const Duration(seconds: 20),
    );
    final host = _hostFromRemote(remote.stdout.trim());
    if (host == null) {
      throw GlabException(
        'could not resolve a GitLab host from the origin remote',
        remote,
      );
    }
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['glab', 'auth', 'login', '--hostname', host, '--stdin'],
      stdin: trimmed,
      timeout: const Duration(seconds: 30),
    );
    if (!result.isSuccess) {
      throw GlabException('glab auth login failed', result);
    }
  }

  /// Extracts the host from a git remote URL. Handles scp-like
  /// (`git@host:group/repo.git`), `ssh://`, and `https://`/`http://` forms.
  /// Returns null when no host can be parsed.
  static String? _hostFromRemote(String url) {
    if (url.isEmpty) return null;
    if (!url.contains('://')) {
      // scp-like syntax: [user@]host:path
      final m = RegExp(r'^(?:[^@/]+@)?([^/:]+):').firstMatch(url);
      return m?.group(1);
    }
    final host = Uri.tryParse(url)?.host;
    return (host != null && host.isNotEmpty) ? host : null;
  }

  /// Calls a REST v4 endpoint, e.g. `projects/:id/merge_requests`.
  ///
  /// [fields] are `key=value` pairs sent via `-f` (`--field`); when any are
  /// present and [method] is GET, glab still issues a GET with query params.
  /// [paginate] walks all pages in one invocation.
  Future<dynamic> api(
    String repoPath,
    String endpoint, {
    List<String> fields = const [],
    bool paginate = false,
    String method = 'GET',
  }) async {
    // Always pass --method explicitly. glab treats a request with any `-f`
    // field as a POST unless the method is stated, so an implicit GET with
    // query params (per_page, state, …) would POST to a read endpoint and 400.
    final args = <String>['glab', 'api', endpoint, '--method', method];
    if (paginate) {
      args.add('--paginate');
    }
    for (final field in fields) {
      args.addAll(['-f', field]);
    }
    // `-i` includes HTTP status lines so we can detect auth/4xx failures even
    // when glab returns a misleading exit code (see glab #911). But it is
    // fundamentally incompatible with `--paginate`: glab emits a *fresh* header
    // block per page and concatenates the results, so the single leading-header
    // strip ([bodyAfterHeaders]) plus first-status-line read ([parseHttpStatus])
    // only ever see page 1 — later pages' header blocks stay embedded in the
    // "body" (JSON parse fails) and a 4xx/5xx on page 2+ goes undetected. For
    // paginated calls we therefore omit `-i` and rely on `glab api --paginate`'s
    // own non-zero exit on an HTTP error (surfaced as a [GlabException] by
    // [_runJson]); the merged pages then come back as one clean JSON document.
    if (!paginate) {
      args.add('-i');
    }
    return _runJson(
      repoPath,
      args,
      'glab api $endpoint',
      expectHeaders: !paginate,
    );
  }

  /// Safety bound on the manual page walks ([mergeRequests], [jobs]) — far
  /// beyond any realistic project's open-MR or pipeline-job count, but a hard
  /// stop so a bug (or a pathological project) can't loop fetching forever.
  static const int _maxListPages = 20;

  /// Parses the HTTP status from `glab api -i` output. Returns null when no
  /// status line is present (non `-i` invocations).
  static int? parseHttpStatus(String output) {
    for (final line in output.split('\n')) {
      final m = RegExp(r'^HTTP/\S+\s+(\d{3})').firstMatch(line.trim());
      if (m != null) return int.tryParse(m.group(1)!);
    }
    return null;
  }

  /// Strips `glab api -i` response headers, returning the body (JSON).
  static String bodyAfterHeaders(String output) {
    final parts = output.split(RegExp(r'\r?\n\r?\n'));
    if (parts.length < 2) return output;
    return parts.sublist(1).join('\n\n').trim();
  }

  /// Open merge requests for the current project. Uses the subcommand's
  /// `--output json` contract (not human text).
  ///
  /// Paginated with a bounded page walk (`--page`): a project with more than one
  /// page ([perPage], 30) of open MRs used to silently show only the first page.
  /// `glab mr list` has no `--paginate` (that flag belongs to the `glab api`
  /// passthrough), so we walk pages until a short (< [perPage]) page marks the
  /// end, capped at [_maxListPages].
  Future<List<MergeRequest>> mergeRequests(
    String repoPath, {
    int perPage = 30,
  }) async {
    final all = <MergeRequest>[];
    for (var page = 1; page <= _maxListPages; page++) {
      final decoded = await _runJson(repoPath, [
        'glab',
        'mr',
        'list',
        '--output',
        'json',
        '--per-page',
        '$perPage',
        '--page',
        '$page',
      ], 'glab mr list');
      final batch = _mapList(decoded, MergeRequest.fromJson, label: 'glab mr list');
      all.addAll(batch);
      if (batch.length < perPage) break; // last (short) page reached
    }
    return all;
  }

  /// Recent CI/CD pipelines via the REST passthrough (`:id` is resolved from the
  /// repo's working directory by glab).
  Future<List<Pipeline>> pipelines(String repoPath, {int perPage = 20}) async {
    final decoded = await api(
      repoPath,
      'projects/:id/pipelines',
      fields: ['per_page=$perPage'],
    );
    return _mapList(decoded, Pipeline.fromJson, label: 'projects/:id/pipelines');
  }

  /// Open issues for the project. Paginated — a project can easily have more
  /// open issues than fit on one page, and unlike [pipelines]/[jobs] (a
  /// naturally bounded, most-recent-first activity feed), the open-issues list
  /// is reference data a user expects to see *all* of, not just the first page.
  Future<List<Issue>> issues(String repoPath, {int perPage = 30}) async {
    final decoded = await api(
      repoPath,
      'projects/:id/issues',
      fields: ['state=opened', 'per_page=$perPage'],
      paginate: true,
    );
    return _mapList(decoded, Issue.fromJson, label: 'projects/:id/issues');
  }

  /// Project path (`group/sub/project`) from a git remote URL, for GraphQL
  /// `fullPath`. Returns null when the URL cannot be parsed.
  static String? projectPathFromRemote(String url) {
    if (url.isEmpty) return null;
    var path = url.trim();
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
    return path.isEmpty ? null : path;
  }

  /// GraphQL document for [projectDashboard].
  static const projectDashboardQuery = r'''
query($path: ID!) {
  project(fullPath: $path) {
    issues(state: opened, first: 30) {
      nodes { iid title state author { username } labels { nodes { title } } }
    }
    labels(first: 100) { nodes { title color description } }
    milestones(state: active, first: 50) { nodes { iid title state dueDate } }
    releases(first: 20) { nodes { tagName name releasedAt } }
  }
}
''';

  /// Builds the argv for a `glab api graphql` call.
  ///
  /// Each variable is passed as its **own** `-f name=value` field so glab binds
  /// it to the like-named `$name` declared in the query. Passing a single
  /// `-f variables={...}` JSON blob does **not** work: glab creates one variable
  /// literally named `variables` and leaves the query's declared variables
  /// unbound, which GitLab rejects with
  /// `variable $path of type ID! was provided invalid value`.
  static List<String> graphqlArgs(
    String query, {
    Map<String, String> variables = const {},
  }) {
    final args = <String>['glab', 'api', 'graphql', '-f', 'query=$query'];
    variables.forEach((name, value) => args.addAll(['-f', '$name=$value']));
    return args;
  }

  /// Extracts a joined message from a GraphQL response's `errors` array, or null
  /// when there are none. GraphQL reports query failures **in the body with HTTP
  /// 200**, so callers must inspect this rather than trusting the HTTP status or
  /// glab's (unreliable) exit code.
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
  /// Because a failed GraphQL query returns HTTP 200 with an `errors` array
  /// (not a 4xx), this inspects the decoded body via [graphqlErrorMessage].
  /// A GraphQL response can report `errors` for just *some* fields while still
  /// returning usable `data` for the rest (e.g. no permission on one field of
  /// a multi-field query, or a resolver failing behind an otherwise-successful
  /// query) — GitLab does not fail the whole request over that. Throwing here
  /// unconditionally used to discard the entire (perfectly good) partial
  /// payload over one bad field, which made the project panel look "broken"
  /// wholesale. So: only a null/absent `data` — a truly total failure, nothing
  /// usable at all — throws [GlabException]. When `data` is present alongside
  /// `errors`, the partial `data` is returned and the error text is instead
  /// recorded non-fatally in [lastGraphqlWarning] for the caller to surface.
  ///
  /// Also requests `-i` and cross-checks the real HTTP status, same as [api] —
  /// a transport-level failure (expired auth, a 5xx) can arrive with glab's
  /// own exit code misleadingly 0 (see glab #911). Without that check here, a
  /// genuine 401/5xx either surfaced as a confusing "non-JSON output" error
  /// (if the error page wasn't valid JSON) or, worse, could be swallowed as
  /// empty project data if it happened to parse as *some* JSON shape without
  /// a GraphQL `errors` array — masking a real auth/permission failure as
  /// "this project has no issues/labels/milestones/releases".
  Future<Map<String, dynamic>> graphql(
    String repoPath,
    String query, {
    Map<String, String> variables = const {},
    String label = 'glab api graphql',
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [...graphqlArgs(query, variables: variables), '-i'],
    );
    if (!result.isSuccess) {
      throw GlabException('$label failed', result);
    }
    final status = parseHttpStatus(result.stdout);
    if (status != null && status >= 400) {
      throw GlabException('$label failed with HTTP $status', result);
    }
    final body = bodyAfterHeaders(result.stdout).trim();
    if (body.isEmpty) return const {};
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw GlabException(
        '$label returned non-JSON output: ${e.message}',
        result,
      );
    }
    if (decoded is! Map<String, dynamic>) return const {};
    final data = decoded['data'];
    final gqlError = graphqlErrorMessage(decoded);
    if (data is! Map<String, dynamic>) {
      // No usable data at all — the only case that's a genuine, total
      // failure. A partial `data` alongside `errors` is handled below.
      throw GlabException(
        gqlError == null ? '$label returned no data' : '$label: $gqlError',
        result,
      );
    }
    lastGraphqlWarning = gqlError == null ? null : '$label: $gqlError';
    return data;
  }

  /// Fetches issues, labels, milestones, and releases in **one** GraphQL query
  /// (one SSH round-trip) instead of four separate REST calls.
  Future<ProjectDashboard> projectDashboard(String repoPath) async {
    final remote = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['git', 'remote', 'get-url', 'origin'],
      timeout: const Duration(seconds: 20),
    );
    final fullPath = projectPathFromRemote(remote.stdout.trim());
    if (fullPath == null) {
      throw GlabException(
        'could not resolve a GitLab project path from origin',
        remote,
      );
    }
    final data = await graphql(
      repoPath,
      projectDashboardQuery,
      variables: {'path': fullPath},
      label: 'glab api graphql dashboard',
    );
    final project = data['project'];
    if (project is! Map<String, dynamic>) return const ProjectDashboard();
    return _parseProjectDashboard(project);
  }

  ProjectDashboard _parseProjectDashboard(Map<String, dynamic> project) {
    List<T> nodes<T>(String key, T Function(Map<String, dynamic>) from) {
      final conn = project[key];
      if (conn is! Map<String, dynamic>) return const [];
      final list = conn['nodes'];
      if (list is! List) return const [];
      return list.whereType<Map<String, dynamic>>().map(from).toList();
    }

    Issue issueFromGql(Map<String, dynamic> n) {
      final labelsConn = n['labels'];
      final labelNodes = labelsConn is Map ? labelsConn['nodes'] : null;
      final labels = labelNodes is List
          ? labelNodes
                .whereType<Map<String, dynamic>>()
                .map((l) => l['title'] as String? ?? '')
                .where((s) => s.isNotEmpty)
                .toList()
          : const <String>[];
      final author = n['author'];
      return Issue(
        iid: (n['iid'] as num?)?.toInt() ?? 0,
        title: n['title'] as String? ?? '',
        state: (n['state'] as String? ?? 'opened').toLowerCase(),
        authorUsername: author is Map ? author['username'] as String? : null,
        labels: labels,
      );
    }

    Label labelFromGql(Map<String, dynamic> n) => Label(
      name: n['title'] as String? ?? '',
      color: n['color'] as String? ?? '#888888',
      description: n['description'] as String?,
    );

    Milestone milestoneFromGql(Map<String, dynamic> n) => Milestone(
      iid: (n['iid'] as num?)?.toInt() ?? 0,
      title: n['title'] as String? ?? '',
      state: (n['state'] as String? ?? 'active').toLowerCase(),
      dueDate: n['dueDate'] as String?,
    );

    Release releaseFromGql(Map<String, dynamic> n) => Release(
      tagName: n['tagName'] as String? ?? '',
      name: n['name'] as String? ?? '',
      createdAt: n['releasedAt'] as String?,
    );

    return ProjectDashboard(
      issues: nodes('issues', issueFromGql),
      labels: nodes('labels', labelFromGql),
      milestones: nodes('milestones', milestoneFromGql),
      releases: nodes('releases', releaseFromGql),
    );
  }

  /// Project releases. Paginated — see [issues].
  Future<List<Release>> releases(String repoPath, {int perPage = 20}) async {
    final decoded = await api(
      repoPath,
      'projects/:id/releases',
      fields: ['per_page=$perPage'],
      paginate: true,
    );
    return _mapList(decoded, Release.fromJson, label: 'projects/:id/releases');
  }

  /// Maps a decoded JSON list response through [from]. A genuinely empty
  /// list (`[]`, `decoded is List` with zero elements) and a malformed,
  /// non-array response (`decoded` is a `Map`, `null`, a string, ...) used to
  /// look identical here — both silently became `[]`, so callers couldn't
  /// tell "this project really has no open MRs" from "the response wasn't
  /// even a list, something is broken". Only the former is a valid empty
  /// result; the latter throws so it surfaces the same as any other malformed
  /// response from this service.
  List<T> _mapList<T>(
    dynamic decoded,
    T Function(Map<String, dynamic>) from, {
    String label = 'glab response',
  }) {
    if (decoded == null) return const [];
    if (decoded is! List) {
      throw GlabException(
        '$label: expected a JSON array, got ${decoded.runtimeType}',
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
    }
    return decoded.whereType<Map<String, dynamic>>().map(from).toList();
  }

  /// Jobs belonging to a pipeline.
  ///
  /// Paginated with a bounded page walk: a pipeline can have more than one page
  /// (100) of jobs, and silently dropping the rest meant a failed job past #100
  /// couldn't be selected/opened. We walk pages until a short (< perPage) page
  /// marks the end, capped at [_maxListPages]. (A manual `--page` walk rather
  /// than `glab api --paginate` so the total fetched stays bounded — a pipeline
  /// with a runaway job count can't drag in thousands of rows on one selection.)
  Future<List<Job>> jobs(String repoPath, int pipelineId) async {
    const perPage = 100;
    final all = <Job>[];
    for (var page = 1; page <= _maxListPages; page++) {
      final decoded = await api(
        repoPath,
        'projects/:id/pipelines/$pipelineId/jobs',
        fields: ['per_page=$perPage', 'page=$page'],
      );
      final batch = _mapList(
        decoded,
        Job.fromJson,
        label: 'projects/:id/pipelines/$pipelineId/jobs',
      );
      all.addAll(batch);
      if (batch.length < perPage) break; // last (short) page reached
    }
    return all;
  }

  /// Live-tails a job's log via `glab ci trace <jobId>`, emitting the
  /// accumulated log text on each update. The trace process is started on first
  /// listen and terminated on cancel — a long-lived streaming channel that
  /// coexists with request/response commands.
  /// Emits **incremental** chunks (not the whole accumulated log), so the UI can
  /// append to a lazily-laid-out view instead of re-rendering the full buffer on
  /// every update — avoiding O(n²) string copying + re-layout on a chatty job.
  Stream<String> traceStream(String repoPath, int jobId) {
    late final StreamController<String> controller;
    SSHStreamHandle? handle;
    StreamSubscription<String>? outSub;
    StreamSubscription<String>? errSub;
    // Set on cancel; re-checked after the executeStream await so a trace process
    // spawned during teardown is killed instead of leaked (#7).
    var cancelled = false;

    void append(String chunk) {
      if (!controller.isClosed) controller.add(chunk);
    }

    Future<void> start() async {
      final newHandle = await _executor.executeStream(
        repoPath: repoPath,
        gitArgs: ['glab', 'ci', 'trace', '$jobId'],
      );
      if (cancelled) {
        await newHandle.cancel();
        return;
      }
      handle = newHandle;

      // We infer a failed trace (bad/expired job id, unauthenticated, glab
      // missing) from the output shape: glab writes the real log to stdout
      // and its progress *and* any fatal error to stderr, then closes both.
      // A run that produced no stdout at all but did write to stderr is that
      // failure — surface it via [controller.addError] so `_TraceLog` renders
      // its error state, instead of closing cleanly (which read as a short,
      // successful log). Decide only once *both* streams have finished, since
      // stderr can still be draining when stdout closes.
      //
      // That zero-stdout heuristic alone misses the case where the trace
      // streamed real output for a while and *then* the remote process died
      // (non-zero exit) — stdout/stderr closing cleanly there looks identical
      // to a normal finish. So once both streams are done, also check the
      // process's actual exit status ([SSHStreamHandle.exitCode]) regardless
      // of whether stdout ever arrived, and surface a non-zero exit as an
      // error too.
      var sawStdout = false;
      var outDone = false;
      var errDone = false;
      // Retains only the last [_kTraceStderrTailChars] of stderr, not the whole
      // stream: `finish` needs merely a short tail (to tell a stdout-less
      // failure apart and quote a one-line error), and a long-running job that
      // streams progress to stderr for hours would otherwise grow this without
      // bound.
      final errBuf = BoundedTail(_kTraceStderrTailChars);

      void finish() {
        if (!outDone || !errDone || controller.isClosed) return;
        final err = errBuf.toString().trim();
        Future<void> checkFailure() async {
          if (!sawStdout && err.isNotEmpty) {
            // Already-fixed case, decided immediately — no need to wait on
            // the exit status when this heuristic alone is conclusive.
            controller.addError(
              GlabException(
                'glab ci trace failed',
                SSHCommandResult(exitCode: -1, stdout: '', stderr: err),
              ),
            );
            return;
          }
          final code = await newHandle.exitCode;
          if (code != null && code != 0 && !controller.isClosed) {
            controller.addError(
              GlabException(
                'glab ci trace failed (exit $code)',
                SSHCommandResult(exitCode: code, stdout: '', stderr: err),
              ),
            );
          }
        }

        checkFailure()
            .catchError((Object e) {
              if (!controller.isClosed) controller.addError(e);
            })
            .whenComplete(() {
              if (!controller.isClosed) controller.close();
            });
      }

      outSub = newHandle.stdout.listen(
        (chunk) {
          sawStdout = true;
          append(chunk);
        },
        onError: (Object e) {
          if (!controller.isClosed) controller.addError(e);
        },
        onDone: () {
          outDone = true;
          finish();
        },
      );
      // glab emits progress/status lines (and, on failure, its error message) to
      // stderr — fold them into the log, and retain them so [finish] can tell a
      // stdout-less failure apart from a normal completion.
      errSub = newHandle.stderr.listen(
        (chunk) {
          errBuf.write(chunk);
          append(chunk);
        },
        onDone: () {
          errDone = true;
          finish();
        },
      );
    }

    Future<void> stop() async {
      cancelled = true;
      await outSub?.cancel();
      await errSub?.cancel();
      await handle?.cancel();
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<String>(
      onListen: () => start().catchError((Object e) {
        if (!controller.isClosed) controller.addError(e);
      }),
      onCancel: stop,
    );
    return controller.stream;
  }

  // ---- Mutations (outward-facing) ------------------------------------------

  /// Approves a merge request via the REST passthrough (POST).
  Future<void> approveMergeRequest(String repoPath, int iid) async {
    await api(
      repoPath,
      'projects/:id/merge_requests/$iid/approve',
      method: 'POST',
    );
  }

  /// Retries a pipeline (all failed/canceled jobs) via the REST passthrough.
  Future<void> retryPipeline(String repoPath, int pipelineId) async {
    await api(
      repoPath,
      'projects/:id/pipelines/$pipelineId/retry',
      method: 'POST',
    );
  }

  /// Creates a merge request via the `glab mr create` subcommand so each value
  /// is a discrete argv token (shell-escaped) rather than a fragile `key=value`
  /// `-f` field that breaks on embedded `=` or newlines.
  ///
  /// Unlike [api]/[graphql], this can't add `-i` and cross-check an HTTP
  /// status — that flag belongs to `glab api`'s REST/GraphQL passthrough, and
  /// `mr create` is a CLI subcommand with no equivalent. Rewriting this to go
  /// through `api()` instead (to get that check) would reintroduce exactly the
  /// `-f key=value` fragility this method exists to avoid, for a subcommand
  /// with no documented exit-code reliability bug (unlike `auth status`,
  /// glab #911). `result.isSuccess` is the correct and only signal available
  /// here.
  ///
  /// Deliberately does **not** add a git-style `--end-of-options` (or bare
  /// `--`) guard before [sourceBranch]/[targetBranch]/[title]/[description]/
  /// [milestone], even though every ref-taking method in `git_service.dart`
  /// does exactly that. That convention is specific to git's own argument
  /// parser; `glab` is a cobra/pflag CLI, and pflag's flag parser always
  /// consumes the token immediately after a value-taking flag (`--title`,
  /// `--source-branch`, ...) as that flag's literal value, never re-parsing it
  /// as another flag — verified directly against the installed `glab` binary:
  /// `--source-branch --description` (a real flag name) and `--source-branch
  /// -y` (a real short flag) both bind correctly as the literal branch value
  /// with no misinterpretation. Conversely, inserting `--end-of-options` (not
  /// a marker pflag recognizes — that's a git-specific convention) or a bare
  /// `--` here actively breaks the command: `mr create` takes no positional
  /// arguments, so pflag consumes the marker itself as the *previous* flag's
  /// value and then rejects whatever token follows it with `Accepts 0 arg(s),
  /// received 1`. So there is no injection risk here to guard against, and no
  /// equivalent guard to add.
  Future<void> createMergeRequest(
    String repoPath, {
    required String sourceBranch,
    required String targetBranch,
    required String title,
    String description = '',
    bool draft = false,
    List<String> reviewers = const [],
    List<String> assignees = const [],
    List<String> labels = const [],
    String? milestone,
    bool squash = false,
    bool removeSourceBranch = false,
  }) async {
    final args = <String>[
      'glab',
      'mr',
      'create',
      '--source-branch',
      sourceBranch,
      '--target-branch',
      targetBranch,
      '--title',
      title,
      if (description.isNotEmpty) ...['--description', description],
      if (draft) '--draft',
      if (reviewers.isNotEmpty) ...['--reviewer', reviewers.join(',')],
      if (assignees.isNotEmpty) ...['--assignee', assignees.join(',')],
      if (labels.isNotEmpty) ...['--label', labels.join(',')],
      if (milestone != null && milestone.isNotEmpty) ...[
        '--milestone',
        milestone,
      ],
      if (squash) '--squash-before-merge',
      if (removeSourceBranch) '--remove-source-branch',
    ];
    final result = await _executor.execute(repoPath: repoPath, gitArgs: args);
    if (!result.isSuccess) {
      throw GlabException('glab mr create failed', result);
    }
  }

  /// Checks out an MR's source branch locally via `glab mr checkout <iid>`, so
  /// a reviewer can pull it down and test without the manual fetch/branch dance.
  /// Switches the working tree to the MR branch — callers should guard against a
  /// dirty tree and refresh status/refs/log afterwards.
  ///
  /// Like [createMergeRequest], this is a CLI subcommand (fetch + local branch
  /// creation) with no REST equivalent to route through [api], so there's no
  /// `-i`/HTTP-status check available — `result.isSuccess` is the only signal.
  Future<void> checkoutMergeRequest(String repoPath, int iid) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['glab', 'mr', 'checkout', '$iid'],
    );
    if (!result.isSuccess) {
      throw GlabException('glab mr checkout failed', result);
    }
  }

  /// Merges a merge request (PUT .../merge).
  Future<void> mergeMergeRequest(String repoPath, int iid) async {
    await api(
      repoPath,
      'projects/:id/merge_requests/$iid/merge',
      method: 'PUT',
    );
  }

  Future<dynamic> _runJson(
    String repoPath,
    List<String> args,
    String label, {
    bool expectHeaders = false,
  }) async {
    final result = await _executor.execute(repoPath: repoPath, gitArgs: args);
    if (!result.isSuccess) {
      throw GlabException('$label failed', result);
    }
    if (expectHeaders) {
      final status = parseHttpStatus(result.stdout);
      if (status != null && status >= 400) {
        throw GlabException('$label failed with HTTP $status', result);
      }
    }
    final body = expectHeaders
        ? bodyAfterHeaders(result.stdout)
        : result.stdout;
    if (body.trim().isEmpty) {
      return null;
    }
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw GlabException(
        '$label returned non-JSON output: ${e.message}',
        result,
      );
    }
  }
}

/// How much of a job trace's stderr to retain — enough for the failure
/// heuristic and a quoted one-line error, far short of an entire chatty job.
const int _kTraceStderrTailChars = 16 * 1024;
