import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import '../ssh/shell_escaper.dart';
import '../ssh/ssh_command_executor.dart';
import '../utils/git_porcelain_parser.dart';
import 'repo_tree.dart';

/// How `git pull` integrates upstream work.
enum PullMode { ffOnly, rebase, merge }

/// How aggressively `git push` overwrites the remote.
enum PushForce { none, withLease, force }

/// The scope a `git reset` moves: HEAD only, HEAD + index, or everything.
enum ResetMode { soft, mixed, hard }

/// How `git merge` integrates a branch into the current one.
enum MergeMode { normal, noFf, ffOnly, squash }

/// A git operation left mid-flight — waiting for the user to continue (resolve +
/// commit) or abort — detected from the state files under the git dir.
enum PendingOp { none, merge, cherryPick, revert, rebase }

/// One step in an interactive rebase's todo list.
///
/// No `reword`: [rebaseInteractive] runs headlessly with `GIT_EDITOR=true` (to
/// accept squashed-commit messages non-interactively), which also forces
/// `reword` to accept the message unchanged — there is no way to actually
/// prompt for a new one over this transport, so it would silently do nothing.
enum RebaseAction { pick, squash, fixup, drop }

/// A single line of an interactive-rebase plan: what to do with [hash].
class RebaseStep {
  final RebaseAction action;
  final String hash;
  const RebaseStep(this.action, this.hash);
}

/// One line of `git blame` output: the commit that last touched a source line.
class BlameLine {
  final String hash; // Commit that introduced/last-changed this line
  final String author;
  final String date; // Author date (ISO 8601)
  final String summary; // Commit subject
  final int lineNumber; // 1-based line number in the final file
  final String content; // The source line text
  const BlameLine({
    required this.hash,
    required this.author,
    required this.date,
    required this.summary,
    required this.lineNumber,
    required this.content,
  });
}

/// Thrown when a remote git command exits non-zero. Carries the raw result so
/// callers can distinguish failure modes (stderr text, exit code) rather than
/// collapsing everything into one opaque error.
class GitException implements Exception {
  final String message;
  final SSHCommandResult result;

  const GitException(this.message, this.result);

  @override
  String toString() =>
      'GitException: $message (exit ${result.exitCode})\n${result.stderr}';
}

/// A branch, remote-tracking ref, or tag, from `git for-each-ref`.
class GitRef {
  final String name; // Full refname, e.g. refs/heads/main
  final String oid; // Object the ref points at (tag object for annotated tags)
  final bool isHead; // True for the currently checked-out branch
  final String? upstream; // Short upstream name, if tracking
  final String subject; // Tip commit / tag subject
  final String? peeledOid; // For annotated tags: the underlying commit

  const GitRef({
    required this.name,
    required this.oid,
    required this.isHead,
    this.upstream,
    required this.subject,
    this.peeledOid,
  });

  bool get isRemote => name.startsWith('refs/remotes/');
  bool get isTag => name.startsWith('refs/tags/');
  bool get isLocalBranch => name.startsWith('refs/heads/');

  /// The commit this ref decorates — the peeled commit for annotated tags,
  /// otherwise the object itself.
  String get commitOid => peeledOid ?? oid;

  String get shortName => name
      .replaceFirst('refs/heads/', '')
      .replaceFirst('refs/remotes/', '')
      .replaceFirst('refs/tags/', '');
}

/// An entry from `git stash list`.
class GitStash {
  final int index;
  final String branch; // Branch the stash was made on
  final String message;
  final String relativeDate; // e.g. "2 hours ago"; '' when unknown

  const GitStash({
    required this.index,
    required this.branch,
    required this.message,
    this.relativeDate = '',
  });

  String get ref => 'stash@{$index}';

  /// The human note without git's `WIP on <branch>: <sha>` / `On <branch>:`
  /// boilerplate — the part worth reading at a glance.
  String get subject {
    // 7..64 hex, not 7..40: a SHA-256 repo's abbreviated stash oid can run up
    // to 64 chars, and a {7,40} bound would stop consuming mid-hash and leak
    // the hash's tail into the displayed subject.
    final m = RegExp(
      r'^(?:WIP on|On) [^:]+:\s*(?:[0-9a-f]{7,64}\s+)?(.*)$',
    ).firstMatch(message);
    final s = m?.group(1)?.trim();
    return (s == null || s.isEmpty) ? message : s;
  }
}

/// Strips any stray ASCII Unit/Record Separator bytes (0x1F/0x1E) from a
/// parsed field's value.
///
/// [GitService.fieldSep]/[recordSep] are ordinary bytes, so a commit subject
/// containing one literally (adversarial or otherwise) can already cause a
/// record/field to be mis-split before this ever runs — that residual risk
/// isn't something a post-hoc string clean can undo, and a fully robust fix
/// (e.g. a length-prefixed format) would be a much larger change than this
/// bug warrants. What this *does* guard is display: it keeps any such stray
/// separator byte that survives into a field's value from leaking further
/// into the UI as a raw, invisible control character.
String _stripSeps(String s) =>
    s.contains('\u001e') || s.contains('\u001f')
    ? s.replaceAll('\u001e', '').replaceAll('\u001f', '')
    : s;

/// Parses `git log` output (field/record separated). Top-level so it can run in
/// a background isolate via `Isolate.run`.
List<GitCommit> parseGitLog(String raw) {
  final commits = <GitCommit>[];
  for (final record in raw.split(GitService.recordSep)) {
    final trimmed = record.replaceFirst(RegExp(r'^\n'), '');
    if (trimmed.trim().isEmpty) continue;
    final f = trimmed.split(GitService.fieldSep);
    // A record with fewer than 7 fields is truncated/malformed (e.g. a
    // transport hiccup mid-stream). Deliberately skip it and keep parsing the
    // rest of the log rather than aborting the whole history render; this is a
    // fire-and-forget top-level parse with no warnings channel to surface it.
    if (f.length < 7) continue;
    commits.add(
      GitCommit(
        hash: f[0],
        shortHash: f[1],
        authorName: f[2],
        authorEmail: f[3],
        date: f[4],
        parents: f[5].isEmpty ? const [] : f[5].split(' '),
        subject: _stripSeps(f[6]),
      ),
    );
  }
  return commits;
}

/// Parses `git blame --line-porcelain` output into one [BlameLine] per source
/// line. Top-level so it can run in a background isolate for large files. Each
/// line block is a header row (`<sha> <orig> <final> [<num>]`) followed by
/// key/value headers and a tab-prefixed content line.
List<BlameLine> parseBlame(String raw) {
  final lines = <BlameLine>[];
  // 40 hex for SHA-1 repos, 64 for SHA-256 — anchored on the trailing space so
  // a SHA-256 header still matches (otherwise every blame line parses as empty).
  final headerRe = RegExp(r'^([0-9a-f]{40,64}) \d+ (\d+)');
  String hash = '';
  int lineNumber = 0;
  String author = '';
  String summary = '';
  int authorTime = 0;

  for (final line in raw.split('\n')) {
    final m = headerRe.firstMatch(line);
    if (m != null) {
      hash = m.group(1)!;
      lineNumber = int.tryParse(m.group(2)!) ?? 0;
      continue;
    }
    if (line.startsWith('author ')) {
      author = line.substring(7);
    } else if (line.startsWith('author-time ')) {
      authorTime = int.tryParse(line.substring(12).trim()) ?? 0;
    } else if (line.startsWith('summary ')) {
      summary = line.substring(8);
    } else if (line.startsWith('\t')) {
      // The content line closes the current block.
      final date = authorTime == 0
          ? ''
          : DateTime.fromMillisecondsSinceEpoch(
              authorTime * 1000,
              isUtc: true,
            ).toIso8601String().substring(0, 10);
      lines.add(
        BlameLine(
          hash: hash,
          author: author,
          date: date,
          summary: summary,
          lineNumber: lineNumber,
          content: line.substring(1),
        ),
      );
    }
  }
  return lines;
}

/// Splits NUL-delimited `ls-files -z` output into non-empty path entries.
/// Top-level so it can run in a background isolate for very large repos.
List<String> splitNulPaths(String raw) =>
    raw.split('\u0000').where((s) => s.isNotEmpty).toList();

/// Groups refs by the commit they decorate (peeled for annotated tags), so a
/// history view can look up all labels for a commit hash in O(1). Within each
/// commit, order is deterministic: HEAD, local branches, remote branches, tags.
Map<String, List<GitRef>> refsByCommit(List<GitRef> refs) {
  final map = <String, List<GitRef>>{};
  for (final ref in refs) {
    (map[ref.commitOid] ??= []).add(ref);
  }
  int rank(GitRef r) {
    if (r.isHead) return 0;
    if (r.isLocalBranch) return 1;
    if (r.isRemote) return 2;
    return 3; // tag
  }

  for (final list in map.values) {
    list.sort((a, b) => rank(a).compareTo(rank(b)));
  }
  return map;
}

/// A single commit, from `git log`.
class GitCommit {
  final String hash;
  final String shortHash;
  final String authorName;
  final String authorEmail;
  final String date; // ISO 8601 (author date)
  final List<String> parents;
  final String subject;

  const GitCommit({
    required this.hash,
    required this.shortHash,
    required this.authorName,
    required this.authorEmail,
    required this.date,
    required this.parents,
    required this.subject,
  });

  bool get isMerge => parents.length > 1;
}

/// The combined result of [GitService.status], [GitService.refs], and
/// [GitService.pendingOp] — see [GitService._snapshot] for why these three are
/// fetched together in one round trip.
class RepoSnapshot {
  final GitStatus status;
  final List<GitRef> refs;
  final PendingOp pendingOp;

  const RepoSnapshot({
    required this.status,
    required this.refs,
    required this.pendingOp,
  });
}

/// Parses `git for-each-ref`'s `fieldSep`-delimited output (see
/// [GitService.refs]) into [GitRef]s. Top-level so [GitService._fetchSnapshot]
/// and [GitService.refs] share one implementation.
List<GitRef> parseRefs(String raw, String fieldSep) {
  final refs = <GitRef>[];
  for (final line in raw.split('\n')) {
    if (line.trim().isEmpty) continue;
    final f = line.split(fieldSep);
    if (f.length < 5) continue;
    final peeled = f.length >= 6 ? f[5] : '';
    refs.add(
      GitRef(
        isHead: f[0] == '*',
        name: f[1],
        oid: f[2],
        upstream: f[3].isEmpty ? null : f[3],
        subject: _stripSeps(f[4]),
        peeledOid: peeled.isEmpty ? null : peeled,
      ),
    );
  }
  return refs;
}

/// Drives remote `git` through the shared [SSHCommandExecutor], returning typed
/// domain objects. All read commands use plumbing/machine formats with stable
/// delimiters; parsing of large output is pushed to a background isolate.
class GitService {
  final CommandExecutor _executor;

  // Field/record separators for log output: ASCII Unit/Record Separators, which
  // cannot appear in commit metadata, so they parse unambiguously without the
  // NUL collision that `-z` + `%00` would cause.
  static const String fieldSep = '\u001f';
  static const String recordSep = '\u001e';

  static const Duration defaultCommitTimeout = Duration(minutes: 5);
  static const Duration defaultNetworkTimeout = Duration(minutes: 3);

  /// A commit may fire a slow prepare-commit-msg (AI) hook; network ops cross a
  /// possibly-slow link. These get generous per-command timeouts so the executor
  /// doesn't kill a legitimately slow operation as if it had hung. Short reads
  /// (status, log, refs) keep the tighter [SSHCommandExecutor.defaultTimeout].
  /// Both are user-configurable via settings, so a genuinely long push isn't
  /// killed — hence instance fields rather than constants.
  final Duration commitTimeout;
  final Duration networkTimeout;

  /// Committer identity applied to every commit-creating command (commit,
  /// amend, merge, cherry-pick, revert, rebase) via `-c user.name/-c
  /// user.email`, so commits are authored correctly regardless of the remote
  /// host's own git config. Null/empty when unset — git then uses its own
  /// config as before. See [_idArgs].
  final String? committerName;
  final String? committerEmail;

  /// One automatic retry for idempotent reads, so a sub-second transport blip
  /// (e.g. mid-reconnect) doesn't surface as an error before auto-reconnect
  /// kicks in. Never applied to mutations — see [SSHCommandExecutor.execute].
  static const int _readRetries = 1;

  /// Parse in a background isolate only when output exceeds this size.
  static const int _isolateThreshold = 32 * 1024;

  GitService(
    this._executor, {
    this.commitTimeout = defaultCommitTimeout,
    this.networkTimeout = defaultNetworkTimeout,
    this.committerName,
    this.committerEmail,
  });

  /// `-c user.name=… -c user.email=…` overrides to inject right after `git` on
  /// any commit-creating command, or empty when no identity is configured.
  List<String> get _idArgs => [
    if (committerName != null && committerName!.trim().isNotEmpty) ...[
      '-c',
      'user.name=${committerName!.trim()}',
    ],
    if (committerEmail != null && committerEmail!.trim().isNotEmpty) ...[
      '-c',
      'user.email=${committerEmail!.trim()}',
    ],
  ];

  /// Verifies [repoPath] is a git working tree on the remote host. Called at
  /// connect time so the session fails fast instead of surfacing errors on the
  /// first provider fetch.
  Future<void> validateRepoPath(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['git', 'rev-parse', '--is-inside-work-tree'],
      timeout: const Duration(seconds: 20),
      retries: _readRetries,
      lane: ExecLane.read,
    );
    // A missing `git` comes back as 127 (the shell's "command not found", or
    // the local backend's ProcessException mapped to the same). Surface that
    // honestly instead of the misleading "not a git repository" — the repo
    // path may be perfectly valid; git simply isn't on the host's PATH.
    if (result.exitCode == 127) {
      throw GitException(_gitNotFoundMessage, result);
    }
    if (!result.isSuccess || result.stdout.trim() != 'true') {
      throw GitException('not a git repository: $repoPath', result);
    }
  }

  /// Shown when a `git` invocation exits 127 (binary not found). Points the
  /// user at the two ways to fix it.
  static const String _gitNotFoundMessage =
      'git was not found on the host. Install git, or set its path in '
      'Settings → External tools.';

  /// Extra validation for the **local** backend only (never the SSH path, where
  /// opening a subdirectory of a repo is perfectly valid): confirms the picked
  /// folder is the repository's own working-tree root AND that git's real git
  /// directory lives inside it.
  ///
  /// Under the macOS App Sandbox the app may read only the exact folder the user
  /// granted through the picker. A picked subdirectory, a linked worktree (git
  /// dir under `<main>/.git/worktrees/…`), or a submodule (git dir under
  /// `<super>/.git/modules/…`) all pass [validateRepoPath]'s plain
  /// `--is-inside-work-tree` check and would then fail every real read with a
  /// raw, confusing permission error. Detect it up front and fail with a clear,
  /// actionable message instead. Fails *open* on anything it can't determine
  /// (e.g. a git too old for `--path-format`), since [validateRepoPath] already
  /// confirmed a work tree and a genuine permission error would still surface.
  Future<void> validateLocalRepoRoot(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      // --path-format=absolute forces --git-dir/--git-common-dir to absolute,
      // normalized paths (no `..`, no relative form) so the containment checks
      // below are pure string math.
      gitArgs: [
        'git',
        'rev-parse',
        '--path-format=absolute',
        '--show-toplevel',
        '--git-dir',
        '--git-common-dir',
      ],
      timeout: const Duration(seconds: 20),
      retries: _readRetries,
      lane: ExecLane.read,
    );
    if (!result.isSuccess) return;
    final lines = const LineSplitter()
        .convert(result.stdout)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 3) return;

    // Resolve symlinks on both sides so a granted `/tmp/x` (→ `/private/tmp/x`)
    // can't false-mismatch git's canonical output. On failure (e.g. a git dir
    // outside the sandbox grant that can't even be stat'd) keep git's already-
    // absolute path — the check then correctly fails closed.
    String canonical(String path) {
      try {
        return Directory(path).resolveSymbolicLinksSync();
      } catch (_) {
        return path;
      }
    }

    bool within(String parent, String child) =>
        child == parent || child.startsWith('$parent/');

    final repoRoot = canonical(repoPath);
    if (canonical(lines[0]) != repoRoot) {
      throw GitException(
        'The selected folder is inside a larger repository — its root is '
        "elsewhere. Pick the repository's top-level folder instead.",
        result,
      );
    }
    for (final gitDir in [lines[1], lines[2]]) {
      if (!within(repoRoot, canonical(gitDir))) {
        throw GitException(
          "This looks like a linked worktree or submodule whose git data lives "
          "outside the selected folder — the app sandbox can't reach it. Open "
          "the main repository's top-level folder instead.",
          result,
        );
      }
    }
  }

  /// Working-tree + branch status via porcelain v2. `--no-optional-locks` (also
  /// enforced via the env prelude) keeps this read from ever taking index.lock.
  /// Bundled with [refs] and [pendingOp] into one round trip — see [_snapshot].
  Future<GitStatus> status(String repoPath) async =>
      (await _snapshot(repoPath)).status;

  /// Local branches, remote-tracking refs, and tags. Bundled with [status] and
  /// [pendingOp] into one round trip — see [_snapshot].
  Future<List<GitRef>> refs(String repoPath) async =>
      (await _snapshot(repoPath)).refs;

  /// Which git operation, if any, is mid-flight — a merge, cherry-pick, revert,
  /// or (interactive) rebase — so the UI can show the right "in progress,
  /// resolve & commit or abort" banner. Bundled with [status] and [refs] into
  /// one round trip — see [_snapshot].
  Future<PendingOp> pendingOp(String repoPath) async =>
      (await _snapshot(repoPath)).pendingOp;

  static const List<String> _refsFormat = [
    '%(HEAD)',
    '%(refname)',
    '%(objectname)',
    '%(upstream:short)',
    '%(contents:subject)',
    '%(*objectname)', // peeled commit for annotated tags (empty otherwise)
  ];

  // A plain `git am` and an am-based rebase both create `$d/rebase-apply`, so
  // testing that dir alone mislabels an in-progress mailbox apply as a rebase.
  // They differ by a marker file: `git am` writes `rebase-apply/applying`,
  // while `git rebase` does not — so an `applying` file present means `am`, not
  // rebase. `am` has no PendingOp variant (adding one would break the
  // exhaustive PendingOp switches in the UI), so it falls through to
  // PendingOp.none below — the important thing is that it is no longer
  // reported as a rebase.
  static const String _pendingOpScript =
      'd=\$(git rev-parse --git-dir 2>/dev/null || echo .git); '
      'if [ -f "\$d/rebase-apply/applying" ]; then echo am; '
      'elif [ -d "\$d/rebase-merge" ] || [ -d "\$d/rebase-apply" ]; then echo rebase; '
      'elif [ -f "\$d/MERGE_HEAD" ]; then echo merge; '
      'elif [ -f "\$d/CHERRY_PICK_HEAD" ]; then echo cherry-pick; '
      'elif [ -f "\$d/REVERT_HEAD" ]; then echo revert; '
      'else echo none; fi';

  /// Separates each section's raw stdout in [_fetchSnapshot]'s combined
  /// script. STX (0x02) never appears in porcelain status's NUL-delimited
  /// (`-z`) records, the refs format's unit-separator (`fieldSep`)-delimited
  /// fields, or plain ref/path text, so splitting the combined stdout on it
  /// unambiguously recovers each section (and, bracketing an exit code, each
  /// section's own success/failure — the combined script's own exit code is
  /// just the last command's, which can't distinguish an earlier failure).
  static const String _snapshotSep = '\u0002RMGSNAP\u0002';

  /// In-flight combined fetch per repo, so concurrent callers within the same
  /// tick (e.g. [pendingOp]'s provider `ref.watch`ing [status] and then
  /// immediately calling this itself) share one round trip instead of two.
  final _snapshotInFlight = <String, Future<RepoSnapshot>>{};

  /// Fetches [status], [refs], and [pendingOp] together in a single round
  /// trip. These three are invalidated together on nearly every refresh
  /// trigger (watcher ticks, post-mutation refreshes across the app) — this
  /// exists purely to turn what would be three serialized SSH round trips
  /// into one.
  Future<RepoSnapshot> _snapshot(String repoPath) {
    final existing = _snapshotInFlight[repoPath];
    if (existing != null) return existing;
    final future = _fetchSnapshot(repoPath);
    _snapshotInFlight[repoPath] = future;
    // `.ignore()`: `whenComplete` yields a *derived* future that re-propagates
    // a fetch failure, and nothing awaits that derivative — without ignoring
    // it, every failed snapshot also surfaced as a spurious unhandled async
    // error in the zone (the real error still reaches the caller through the
    // returned `future` itself).
    future.whenComplete(() => _snapshotInFlight.remove(repoPath)).ignore();
    return future;
  }

  Future<RepoSnapshot> _fetchSnapshot(String repoPath) async {
    final format = _refsFormat.join(fieldSep);
    final script =
        'git --no-optional-locks status --porcelain=v2 --branch -z; s1=\$?; '
        "printf '$_snapshotSep%d$_snapshotSep' \"\$s1\"; "
        // `-c i18n.logOutputEncoding=UTF-8`: re-encodes `%(contents:subject)`
        // to UTF-8 for output regardless of the remote's stored commit
        // encoding, so a repo with a legacy `i18n.commitEncoding` (Latin-1,
        // Shift-JIS, …) still yields clean UTF-8 here instead of bytes this
        // app's `Utf8Decoder(allowMalformed: true)` would silently mangle into
        // U+FFFD. Deliberately not `i18n.commitEncoding` — that config tells
        // git what the *stored* bytes actually are, and forcing it to UTF-8
        // would make git misinterpret a genuinely non-UTF-8 commit rather than
        // transcode it.
        "git -c i18n.logOutputEncoding=UTF-8 for-each-ref --format='$format' refs/heads refs/remotes refs/tags; s2=\$?; "
        "printf '$_snapshotSep%d$_snapshotSep' \"\$s2\"; "
        '$_pendingOpScript';

    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['sh', '-c', script],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );

    final parts = result.stdout.split(_snapshotSep);
    if (parts.length < 5) {
      throw GitException('malformed combined status/refs/pending-op output', result);
    }
    final statusStdout = parts[0];
    final statusExit = int.tryParse(parts[1].trim()) ?? 1;
    final refsStdout = parts[2];
    final refsExit = int.tryParse(parts[3].trim()) ?? 1;
    final pendingStdout = parts[4];

    if (statusExit != 0) {
      throw GitException(
        'git status failed',
        SSHCommandResult(
          exitCode: statusExit,
          stdout: statusStdout,
          stderr: result.stderr,
        ),
      );
    }
    if (refsExit != 0) {
      throw GitException(
        'git for-each-ref failed',
        SSHCommandResult(
          exitCode: refsExit,
          stdout: refsStdout,
          stderr: result.stderr,
        ),
      );
    }

    final status = statusStdout.length > _isolateThreshold
        ? await Isolate.run(() => GitPorcelainParser.parseV2(statusStdout))
        : GitPorcelainParser.parseV2(statusStdout);
    final refs = parseRefs(refsStdout, fieldSep);
    final pendingOp = switch (pendingStdout.trim()) {
      'rebase' => PendingOp.rebase,
      'merge' => PendingOp.merge,
      'cherry-pick' => PendingOp.cherryPick,
      'revert' => PendingOp.revert,
      _ => PendingOp.none,
    };

    return RepoSnapshot(status: status, refs: refs, pendingOp: pendingOp);
  }

  /// Opt-in per-repo tuning for large working trees (mutates git config).
  /// Enabling turns on fsmonitor plus the complementary untracked cache and
  /// index v4; disabling turns fsmonitor back off (the caches are harmless and
  /// left in place). One combined round trip rather than one `git config` call
  /// per setting.
  Future<void> setFsmonitor(String repoPath, {required bool enabled}) async {
    await _runVoid(repoPath, [
      'sh',
      '-c',
      _fsmonitorScript(enabled: enabled),
    ], 'git config fsmonitor');
  }

  static String _fsmonitorScript({required bool enabled}) {
    if (!enabled) return 'git config core.fsmonitor false';
    // `core.fsmonitor=true` is only honored where git's fsmonitor daemon can
    // actually run — many server builds/platforms reject it outright
    // (`fatal: fsmonitor--daemon not supported on this platform`). Probe
    // first and set `false` on such hosts (also repairing repos where an
    // earlier version of this script enabled it unconditionally), so every
    // subsequent `git status` isn't paying for — or warning about — a
    // monitor that can never exist. untrackedCache/manyFiles are beneficial
    // independently of the daemon and apply either way.
    return "if git fsmonitor--daemon status 2>&1 "
        "| grep -qi 'not supported'; then "
        'git config core.fsmonitor false; '
        'else git config core.fsmonitor true; fi'
        ' && git config core.untrackedCache true'
        ' && git config feature.manyFiles true';
  }

  /// Applies [setFsmonitor] to every repo in [repoPaths] with a **single**
  /// round trip — used at connect time, where each opted-in repo used to cost
  /// its own SSH round trip before the session became usable. Best-effort per
  /// repo: one repo failing (moved, permissions) doesn't stop the others; each
  /// failure is reported on stderr as `fsmonitor setup failed: <path>` and the
  /// command itself always exits 0. Returns the raw result so the caller can
  /// log any reported failures.
  Future<SSHCommandResult> setFsmonitorMany(
    List<String> repoPaths, {
    required bool enabled,
  }) {
    final inner = _fsmonitorScript(enabled: enabled);
    final dirs = repoPaths.map(ShellEscaper.escape).join(' ');
    // Subshell per repo so each `cd` is isolated; `|| printf … >&2` keeps the
    // sweep going and surfaces the failed path. Trailing `true` pins exit 0.
    final script =
        'for d in $dirs; do '
        '(cd "\$d" && $inner) '
        "|| printf 'fsmonitor setup failed: %s\\n' \"\$d\" >&2; "
        'done; true';
    return _run(repoPaths.first, ['sh', '-c', script], 'git config fsmonitor');
  }

  /// Commit history for [revision] (default HEAD), most recent first, with
  /// optional filters: [grep] (subject/body, case-insensitive), [author],
  /// [since]/[until] (any git date expression), and a [path] to limit to commits
  /// touching it. [all] walks every ref instead of [revision]; [follow] tracks a
  /// single [path] across renames (file history).
  ///
  /// Always requests `--topo-order`: [CommitGraph.build]'s lane algorithm
  /// requires that a commit never appears before any of its parents. Git's
  /// default is date order, which usually coincides with topological order for
  /// ordinary linear history but can diverge with clock skew, rewritten
  /// cherry-pick dates, or — especially — the multi-branch `--all` view, where
  /// commits from different branches interleave by date rather than ancestry.
  /// Without this, a parent can be emitted before some of its children, which
  /// the lane algorithm has no way to detect; it just falls back to a fresh
  /// lane, producing a visibly wrong graph (broken merge lines, spurious
  /// lanes) for exactly the histories this view exists to visualize.
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    bool all = false,
    bool follow = false,
  }) async {
    final format = ['%H', '%h', '%an', '%ae', '%aI', '%P', '%s'].join(fieldSep);

    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'git',
        // Re-encodes commit subjects to UTF-8 for output regardless of the
        // remote's stored `i18n.commitEncoding` — see the longer explanation
        // on the `for-each-ref` call in [_fetchSnapshot].
        '-c',
        'i18n.logOutputEncoding=UTF-8',
        'log',
        '--topo-order',
        // Suppress any interleaved `gpg:`/signature lines a remote-side
        // `log.showSignature=true` would otherwise inject into the machine-read
        // output and corrupt hash/parent/date parsing.
        '--no-show-signature',
        '--pretty=format:$format$recordSep',
        '--max-count=$maxCount',
        if (grep != null && grep.trim().isNotEmpty) ...[
          '--grep=${grep.trim()}',
          '-i',
        ],
        if (author != null && author.trim().isNotEmpty)
          '--author=${author.trim()}',
        if (since != null && since.trim().isNotEmpty) '--since=${since.trim()}',
        if (until != null && until.trim().isNotEmpty) '--until=${until.trim()}',
        // `--follow` is only valid with exactly one pathspec; git errors out
        // otherwise (and it also rejects `--follow --all`).
        if (follow && !all && path != null && path.isNotEmpty) '--follow',
        if (all) '--all',
        // Everything after this is a revision/pathspec, never an option — so a
        // branch literally named `-p` (or any leading-dash ref) can't be parsed
        // as a git flag.
        '--end-of-options',
        if (!all) revision,
        if (path != null && path.isNotEmpty) ...['--', path],
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      // An unborn HEAD (a freshly initialized repo with no commits yet) makes
      // `git log` fail fatally — exit 128, `fatal: your current branch 'main'
      // does not have any commits yet` — rather than succeeding with zero
      // rows the way a filtered log with no matches does. Recognize
      // specifically that message (not every exit-128 failure — plenty of
      // other legitimate errors, e.g. an unknown revision, also exit 128) and
      // return an empty history instead of throwing, so the History view's
      // existing "no commits" empty state (rendered for `data([])`) applies
      // automatically with no UI-side special-casing.
      if (result.exitCode == 128 &&
          result.stderr.contains('does not have any commits yet')) {
        return const [];
      }
      throw GitException('git log failed', result);
    }
    final stdout = result.stdout;
    if (stdout.length > _isolateThreshold) {
      return Isolate.run(() => parseGitLog(stdout));
    }
    return parseGitLog(stdout);
  }

  /// Unified diff for a single file. [staged] selects the index-vs-HEAD diff
  /// (`--cached`) rather than the worktree-vs-index diff. [ignoreWhitespace]
  /// adds `-w` (hide whitespace-only changes); [context] overrides the number of
  /// surrounding context lines (`-U<n>`) for the diff viewer's expand-context.
  Future<String> diffFile(
    String repoPath, {
    required String path,
    required bool staged,
    bool ignoreWhitespace = false,
    int? context,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'git',
        'diff',
        '--no-color',
        if (staged) '--cached',
        if (ignoreWhitespace) '-w',
        if (context != null) '-U$context',
        '--',
        path,
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('git diff failed', result);
    }
    return result.stdout;
  }

  /// Diff across a ref range for a merge-request preview — typically
  /// `target...source` (what the source branch adds since it forked from the
  /// target). [ignoreWhitespace]/[context] mirror [diffFile].
  Future<String> diffRange(
    String repoPath,
    String range, {
    bool ignoreWhitespace = false,
    int? context,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'git',
        'diff',
        '--no-color',
        if (ignoreWhitespace) '-w',
        if (context != null) '-U$context',
        '--end-of-options',
        range,
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('git diff (range) failed', result);
    }
    return result.stdout;
  }

  /// Shows a new (untracked) file's contents as an all-additions diff against
  /// an empty file. `git diff --no-index` exits 1 when the inputs differ (which
  /// is always, here) — that is success, so only a higher code is a real error.
  Future<String> diffUntracked(String repoPath, String path) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'git',
        'diff',
        '--no-index',
        '--no-color',
        '--',
        '/dev/null',
        path,
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    // `--no-index` exits 1 when the inputs differ (always, here) — that's
    // success. Any other code, including the executor's -1 sentinel for a
    // killed/unresolved channel, is a real failure and must not be presented
    // as a diff.
    if (result.exitCode != 0 && result.exitCode != 1) {
      throw GitException('git diff (untracked) failed', result);
    }
    return result.stdout;
  }

  /// Full patch for a single commit (`git show`). When [path] is given, scopes
  /// the diff to that file only — used by the file-history view, where
  /// otherwise selecting a commit would fetch (and show) every file it
  /// touched, not just the one file whose history is being inspected.
  Future<String> showCommit(
    String repoPath,
    String hash, {
    String? path,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'git',
        // See the `for-each-ref` call in [_fetchSnapshot] for why only
        // `logOutputEncoding` (not `commitEncoding`) is forced to UTF-8.
        '-c',
        'i18n.logOutputEncoding=UTF-8',
        'show',
        '--no-color',
        '--no-show-signature',
        '--end-of-options',
        hash,
        if (path != null && path.isNotEmpty) ...['--', path],
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('git show failed', result);
    }
    return result.stdout;
  }

  /// Line-by-line authorship for [path] (`git blame`) at [rev] (default the
  /// working copy). Uses `--line-porcelain` for a stable, easily-parsed format;
  /// large files are parsed in a background isolate.
  Future<List<BlameLine>> blame(
    String repoPath,
    String path, {
    String? rev,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'git',
        // See the `for-each-ref` call in [_fetchSnapshot] for why only
        // `logOutputEncoding` (not `commitEncoding`) is forced to UTF-8; blame's
        // `summary` header re-encodes the same way `log`/`show` do.
        '-c',
        'i18n.logOutputEncoding=UTF-8',
        'blame',
        '--line-porcelain',
        '--end-of-options',
        ?rev,
        '--',
        path,
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('git blame failed', result);
    }
    final stdout = result.stdout;
    if (stdout.length > _isolateThreshold) {
      return Isolate.run(() => parseBlame(stdout));
    }
    return parseBlame(stdout);
  }

  /// The full working-tree contents of [path], read straight off disk (`cat`)
  /// rather than through a git object — so it reflects exactly what is on disk
  /// right now (tracked or not, staged or not), which is what a file viewer
  /// wants to show. Works identically local and over SSH: the executor runs
  /// `cat` in the repo and decodes stdout as UTF-8 with malformed bytes
  /// replaced, so a *binary* file comes back as mangled text — callers are
  /// expected to classify the result and refuse to render non-text (see
  /// `FileContent.classify`). Output past the executor's hard cap surfaces as
  /// a failure instead of ballooning memory. The `--` guards a [path] that
  /// begins with `-` from being read as a `cat` flag. (Sibling of
  /// [conflictFile], which reads the same way but is scoped to a conflicted
  /// file.)
  Future<String> readFile(String repoPath, String path) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['cat', '--', path],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('reading file failed', result);
    }
    return result.stdout;
  }

  /// The raw bytes of [path], base64-encoded, for content that isn't text —
  /// images the viewer renders (`Image.memory` after decoding). Piped through
  /// `base64` (reading the file via a shell redirection, which works the same
  /// with GNU and BSD `base64`) so binary bytes survive the executor's UTF-8
  /// stdout decoding intact. The wrapping newlines GNU `base64` inserts are
  /// stripped **remote-side** with `tr -d '\r\n'`, so the caller can
  /// `base64.decode` the result directly instead of allocating a second
  /// full-size whitespace-stripped copy of the (already ~1.37×-inflated) string
  /// on the client. Oversized output trips the executor's hard cap and surfaces
  /// as a failure rather than spiking memory.
  Future<String> readFileBase64(String repoPath, String path) async {
    final script = "base64 < ${ShellEscaper.escape(path)} | tr -d '\\r\\n'";
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['sh', '-c', script],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('reading file bytes failed', result);
    }
    return result.stdout;
  }

  // ---- File tree -----------------------------------------------------------

  /// Lists the working tree for the file-view pane. Returns the non-ignored
  /// files (tracked + untracked, one `ls-files` round trip) and the ignored
  /// entries — the latter collapsing wholly-ignored directories to a single
  /// `dir/` path (via `--directory`) so a huge ignored tree never loads
  /// eagerly. Large output is split in a background isolate.
  Future<({List<String> files, List<String> ignored})> listWorkingTree(
    String repoPath,
  ) async {
    // One round trip instead of two: `&&` so a failure of the first ls-files
    // (rare — repoPath is validated at connect time) short-circuits before
    // the marker or the second call, which `_run` then reports correctly via
    // the combined script's own (now meaningful) exit code.
    const script =
        'git ls-files -z --cached --others --exclude-standard && '
        "printf '$_snapshotSep' && "
        'git ls-files -z --others --ignored --exclude-standard --directory';
    final result = await _run(
      repoPath,
      ['sh', '-c', script],
      'git ls-files',
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    final parts = result.stdout.split(_snapshotSep);
    final files = await _splitPaths(parts.isNotEmpty ? parts[0] : '');
    final ignored = await _splitPaths(parts.length > 1 ? parts[1] : '');
    return (files: files, ignored: ignored);
  }

  Future<List<String>> _splitPaths(String stdout) {
    if (stdout.length > _isolateThreshold) {
      return Isolate.run(() => splitNulPaths(stdout));
    }
    return Future.value(splitNulPaths(stdout));
  }

  /// Lists the immediate children of a collapsed ignored directory for lazy
  /// expansion. Uses a one-level filesystem listing (`ls -Ap`, dirs suffixed
  /// with `/`) since ignored content isn't in git's index; every child is
  /// itself ignored, and subdirectories stay lazily expandable.
  Future<List<RepoNode>> listIgnoredChildren(
    String repoPath,
    String dir,
  ) async {
    final res = await _run(
      repoPath,
      ['ls', '-Ap', '--', dir],
      'ls',
      retries: _readRetries,
      lane: ExecLane.read,
    );
    final nodes = <RepoNode>[];
    for (final line in res.stdout.split('\n')) {
      if (line.isEmpty) continue;
      final isDir = line.endsWith('/');
      final name = isDir ? line.substring(0, line.length - 1) : line;
      if (name.isEmpty || name == '.' || name == '..') continue;
      nodes.add(
        RepoNode(
          name: name,
          path: '$dir/$name',
          isDir: isDir,
          ignored: true,
          lazy: isDir,
        ),
      );
    }
    nodes.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return nodes;
  }

  // ---- Mutations -----------------------------------------------------------
  // All run through the serialized queue, so an index-touching write never
  // races a concurrent read. Each throws [GitException] on non-zero exit.

  /// Stages a path (`git add`).
  Future<void> stage(String repoPath, String path) =>
      _runVoid(repoPath, ['git', 'add', '--', path], 'git add');

  /// Stages every path in [paths] with a single `git add` invocation —
  /// the multi-select bulk equivalent of [stage].
  Future<void> stageMany(String repoPath, List<String> paths) =>
      _runVoid(repoPath, ['git', 'add', '--', ...paths], 'git add');

  /// Applies a unified-diff [patch] via `git apply`, reading it from stdin (so it
  /// never touches argv). [cached] targets the index (staging); [reverse] applies
  /// it backwards (unstaging, or discarding a worktree hunk). Used for hunk-level
  /// staging — never retried, since applying twice would corrupt the tree.
  Future<void> applyPatch(
    String repoPath,
    String patch, {
    required bool cached,
    required bool reverse,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'git',
        'apply',
        if (cached) '--cached',
        if (reverse) '-R',
        '--recount',
        '--whitespace=nowarn',
        '-',
      ],
      stdin: patch,
    );
    if (!result.isSuccess) {
      throw GitException('git apply failed', result);
    }
  }

  /// Stages everything (`git add -A`).
  Future<void> stageAll(String repoPath) =>
      _runVoid(repoPath, ['git', 'add', '-A'], 'git add -A');

  /// Unstages a path, leaving the working-tree change intact
  /// (`git restore --staged`).
  Future<void> unstage(String repoPath, String path) => _runVoid(repoPath, [
    'git',
    'restore',
    '--staged',
    '--',
    path,
  ], 'git restore');

  /// Unstages every path in [paths] with a single invocation — the
  /// multi-select bulk equivalent of [unstage].
  Future<void> unstageMany(String repoPath, List<String> paths) => _runVoid(
    repoPath,
    ['git', 'restore', '--staged', '--', ...paths],
    'git restore',
  );

  /// Commits the staged changes.
  ///
  /// If [message] is non-empty it is committed with `-m`. If it is null/empty,
  /// git runs with no message and `GIT_EDITOR=true`, so a `prepare-commit-msg`
  /// hook (e.g. an AI generator) writes the message and the empty "editor"
  /// accepts it non-interactively. `--no-gpg-sign` avoids a failure on repos
  /// with `commit.gpgsign=true` (no GPG agent over the SSH exec channel).
  Future<void> commit(String repoPath, {String? message}) {
    final args = ['git', ..._idArgs, 'commit', '--no-gpg-sign'];
    if (message != null && message.trim().isNotEmpty) {
      args.addAll(['-m', message]);
    }
    // A prepare-commit-msg hook may invoke a slow AI generator — allow generous
    // headroom so a legitimately slow commit isn't killed as if it hung.
    return _runVoid(repoPath, args, 'git commit', timeout: commitTimeout);
  }

  /// Whether a `prepare-commit-msg` hook is installed (respecting
  /// `core.hooksPath`). When true, a commit message is optional — the hook
  /// supplies it.
  Future<bool> hasPrepareCommitMsgHook(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'sh',
        '-c',
        // Prefer core.hooksPath; otherwise resolve the hooks dir via
        // `git rev-parse --git-path hooks` rather than hardcoding `.git/hooks`.
        // In a linked worktree or submodule `.git` is a FILE, not a dir, so a
        // literal `.git/hooks` never exists and the hook would never be found.
        'hp=\$(git config --get core.hooksPath 2>/dev/null); '
            '[ -n "\$hp" ] || hp=\$(git rev-parse --git-path hooks 2>/dev/null || echo .git/hooks); '
            '[ -x "\$hp/prepare-commit-msg" ] && echo yes || echo no',
      ],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    return result.stdout.trim() == 'yes';
  }

  /// Runs the `prepare-commit-msg` hook against a scratch message file and
  /// returns the message it produces, so the UI can preview (and let the user
  /// edit or accept) an auto-generated message *before* committing. Returns null
  /// when no hook is installed or it wrote nothing.
  ///
  /// Uses a throwaway file under the git dir — never `COMMIT_EDITMSG` — so it
  /// can't disturb an in-progress commit. `mktemp` gives it a unique,
  /// unpredictable name created atomically with owner-only permissions: a
  /// fixed filename here would let another local user (or a second, racing
  /// invocation of this same call) pre-plant a symlink or a file at that path
  /// before the hook writes to it. The hook may invoke a slow AI generator, so
  /// this gets the commit timeout.
  Future<String?> generateCommitMessage(String repoPath) async {
    // Exit 3 signals "no hook" so we can fall back to manual entry. The hook's
    // own stdout/stderr are discarded; only the message file content is emitted.
    const script =
        // See hasPrepareCommitMsgHook: resolve the hooks dir via
        // `git rev-parse --git-path hooks` (respecting core.hooksPath first) so
        // a linked worktree/submodule — where `.git` is a file — still finds it.
        'hp=\$(git config --get core.hooksPath 2>/dev/null); '
        '[ -n "\$hp" ] || hp=\$(git rev-parse --git-path hooks 2>/dev/null || echo .git/hooks); '
        'hook="\$hp/prepare-commit-msg"; '
        '[ -x "\$hook" ] || exit 3; '
        'dir=\$(git rev-parse --git-dir 2>/dev/null || echo .git); '
        'tmp=\$(mktemp "\$dir/MAGICGIT_MSG_PREVIEW.XXXXXX") || exit 1; '
        '"\$hook" "\$tmp" </dev/null >/dev/null 2>&1 || true; '
        'sed -e /^#/d "\$tmp"; '
        'rm -f "\$tmp"';
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['sh', '-c', script],
      timeout: commitTimeout,
    );
    if (result.exitCode == 3) return null; // no prepare-commit-msg hook
    if (!result.isSuccess) {
      throw GitException('generating commit message failed', result);
    }
    final msg = result.stdout.trim();
    return msg.isEmpty ? null : msg;
  }

  /// Checks out a branch or ref (`git checkout`). `--end-of-options` stops a
  /// [ref] that happens to start with `-` (a branch named e.g. `-d`) from
  /// being parsed as a flag — plain `--` isn't safe here since checkout gives
  /// it pathspec-separator meaning, not just "end of options".
  Future<void> checkout(String repoPath, String ref) => _runVoid(repoPath, [
    'git',
    'checkout',
    '--end-of-options',
    ref,
  ], 'git checkout');

  /// Creates a branch, optionally checking it out. `--end-of-options` guards
  /// [name] the same way [checkout] guards its ref.
  Future<void> createBranch(
    String repoPath,
    String name, {
    bool checkout = true,
  }) => _runVoid(
    repoPath,
    checkout
        ? ['git', 'checkout', '-b', '--end-of-options', name]
        : ['git', 'branch', '--end-of-options', name],
    'git branch',
  );

  /// Deletes a local branch. [force] uses `-D` (discard unmerged commits).
  Future<void> deleteBranch(
    String repoPath,
    String name, {
    bool force = false,
  }) => _runVoid(repoPath, [
    'git',
    'branch',
    force ? '-D' : '-d',
    '--end-of-options',
    name,
  ], 'git branch -d');

  /// Discards working-tree changes to a path (`git restore`). Irreversible.
  Future<void> discard(String repoPath, String path) =>
      _runVoid(repoPath, ['git', 'restore', '--', path], 'git restore');

  /// Discards working-tree changes to every path in [paths] with a single
  /// invocation — the multi-select bulk equivalent of [discard]. Irreversible.
  Future<void> discardMany(String repoPath, List<String> paths) => _runVoid(
    repoPath,
    ['git', 'restore', '--', ...paths],
    'git restore',
  );

  /// Removes a single untracked file from the working tree. Deliberately
  /// scoped to exactly [path] (`git clean -f --`, not a blanket `-fd` sweep):
  /// `git clean` already refuses to touch anything git tracks, so this can
  /// only ever delete the one untracked file the caller asked for. `--`
  /// (rather than `--end-of-options`) matches how every other path argument
  /// in this file is hardened against a leading `-` — see [discard]/[stage].
  /// Irreversible.
  Future<void> removeUntrackedFile(String repoPath, String path) =>
      _runVoid(repoPath, ['git', 'clean', '-f', '--', path], 'git clean');

  /// Removes every untracked path in [paths] with a single invocation — the
  /// multi-select bulk equivalent of [removeUntrackedFile]. Same scoping
  /// rationale: `git clean` still refuses to touch anything tracked, so this
  /// can only ever delete the untracked files the caller named. Irreversible.
  Future<void> removeUntrackedFilesMany(String repoPath, List<String> paths) =>
      _runVoid(repoPath, ['git', 'clean', '-f', '--', ...paths], 'git clean');

  /// Permanently deletes [path] from the working tree with `rm -f`, regardless
  /// of whether git tracks it. Unlike [removeUntrackedFile] (`git clean`, which
  /// refuses to touch anything tracked), this is the file-tree pane's generic
  /// delete: that pane lists every file — tracked, untracked, and ignored — so
  /// its delete has to work on all of them. For a tracked file this removes the
  /// working-tree copy (git then reports it as deleted; the committed history
  /// still holds it, recoverable via `git restore`); for an untracked or
  /// ignored file it is gone for good. `-f` so a read-only or already-missing
  /// file doesn't error out. `--` guards a leading-`-` path, matching how every
  /// other path argument in this file is hardened.
  Future<void> deleteFile(String repoPath, String path) =>
      _runVoid(repoPath, ['rm', '-f', '--', path], 'rm');

  /// Discards a staged path's changes entirely — both the index and working
  /// tree are reset to HEAD's content for [path]. For a path with no HEAD
  /// counterpart (a newly `git add`ed file that was never committed),
  /// `--source=HEAD` has nothing to restore *to*, so git instead removes it
  /// from both the index and the working tree — exactly "undo the staged
  /// add" for that case, with no special-casing needed here. Irreversible.
  Future<void> discardStaged(String repoPath, String path) => _runVoid(repoPath, [
    'git',
    'restore',
    '--staged',
    '--worktree',
    '--source=HEAD',
    '--',
    path,
  ], 'git restore');

  /// Discards staged changes to every path in [paths] with a single
  /// invocation — the multi-select bulk equivalent of [discardStaged]. Same
  /// "no HEAD counterpart" handling applies per-path. Irreversible.
  Future<void> discardStagedMany(String repoPath, List<String> paths) =>
      _runVoid(repoPath, [
        'git',
        'restore',
        '--staged',
        '--worktree',
        '--source=HEAD',
        '--',
        ...paths,
      ], 'git restore');

  /// Appends [path] as a new ignore pattern to the repo root's `.gitignore`,
  /// creating the file if it doesn't exist. Not a git subcommand — this app
  /// has no separate remote-vs-local file-editing path, so it's a small shell
  /// script run through the same executor as every other command here, which
  /// keeps it working identically for a local repo and an SSH one (whose
  /// `.gitignore` lives on the remote host, not this machine). A no-op if
  /// [path] (exact line match) is already present, so ignoring the same file
  /// twice doesn't duplicate the line.
  Future<void> addToGitignore(String repoPath, String path) =>
      _runVoid(repoPath, [
        'sh',
        '-c',
        _gitignoreAppendScript([path]),
      ], 'git ignore');

  /// Appends every path in [paths] to `.gitignore` with a single invocation —
  /// the multi-select bulk equivalent of [addToGitignore]. Each path is still
  /// deduped independently, same as the single-file version.
  Future<void> addToGitignoreMany(String repoPath, List<String> paths) =>
      _runVoid(repoPath, [
        'sh',
        '-c',
        _gitignoreAppendScript(paths),
      ], 'git ignore');

  static String _gitignoreAppendScript(List<String> paths) {
    final lines = paths
        .map(ShellEscaper.escape)
        .map((q) => 'grep -qxF -- $q "\$f" || printf \'%s\\n\' $q >> "\$f"')
        .join('; ');
    return 'f=.gitignore; touch "\$f"; $lines';
  }

  // ---- History actions -----------------------------------------------------

  /// Applies [hash] onto the current branch. For a merge commit, [mainline]
  /// selects which parent's changes to keep (1-based).
  Future<SSHCommandResult> cherryPick(
    String repoPath,
    String hash, {
    int? mainline,
  }) => _run(repoPath, [
    'git',
    ..._idArgs,
    'cherry-pick',
    if (mainline != null) ...['-m', '$mainline'],
    '--end-of-options',
    hash,
  ], 'git cherry-pick');

  /// Aborts an in-progress cherry-pick, restoring the pre-pick state.
  Future<void> cherryPickAbort(String repoPath) => _runVoid(repoPath, [
    'git',
    'cherry-pick',
    '--abort',
  ], 'git cherry-pick --abort');

  /// Creates a commit that undoes [hash]. For a merge commit, [mainline]
  /// selects the parent to revert against (1-based).
  Future<SSHCommandResult> revert(
    String repoPath,
    String hash, {
    int? mainline,
  }) => _run(repoPath, [
    'git',
    ..._idArgs,
    'revert',
    '--no-edit',
    if (mainline != null) ...['-m', '$mainline'],
    '--end-of-options',
    hash,
  ], 'git revert');

  /// Aborts an in-progress revert.
  Future<void> revertAbort(String repoPath) =>
      _runVoid(repoPath, ['git', 'revert', '--abort'], 'git revert --abort');

  /// Moves HEAD (and, per [mode], the index/worktree) to [hash].
  Future<void> reset(String repoPath, String hash, {required ResetMode mode}) =>
      _runVoid(repoPath, [
        'git',
        'reset',
        switch (mode) {
          ResetMode.soft => '--soft',
          ResetMode.mixed => '--mixed',
          ResetMode.hard => '--hard',
        },
        '--end-of-options',
        hash,
      ], 'git reset');

  /// Creates a branch named [name] rooted at [startPoint], optionally checking
  /// it out.
  Future<void> branchFrom(
    String repoPath,
    String name,
    String startPoint, {
    bool checkout = true,
  }) => _runVoid(
    repoPath,
    checkout
        ? ['git', 'checkout', '-b', '--end-of-options', name, startPoint]
        : ['git', 'branch', '--end-of-options', name, startPoint],
    'git branch',
  );

  /// Amends the current HEAD commit. With a [message] it rewrites the subject
  /// (`-m`); without one it keeps the existing message (`--no-edit`). Picks up
  /// whatever is currently staged.
  Future<void> amendCommit(String repoPath, {String? message}) {
    final hasMsg = message != null && message.trim().isNotEmpty;
    return _runVoid(
      repoPath,
      [
        'git',
        ..._idArgs,
        'commit',
        '--amend',
        '--no-gpg-sign',
        if (hasMsg) ...['-m', message] else '--no-edit',
      ],
      'git commit --amend',
      timeout: commitTimeout,
    );
  }

  // ---- Conflict resolution -------------------------------------------------

  /// The conflicted working-tree file, with merge markers. Read directly (not
  /// through git) since the marked-up file is not a git object.
  Future<String> conflictFile(String repoPath, String path) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['cat', '--', path],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('reading conflicted file failed', result);
    }
    return result.stdout;
  }

  /// Resolves a conflict by taking one side wholesale, then staging it.
  /// [useOurs] selects `--ours` (the current branch) vs `--theirs` (incoming).
  Future<void> resolveConflict(
    String repoPath,
    String path, {
    required bool useOurs,
  }) async {
    await _runVoid(repoPath, [
      'git',
      'checkout',
      useOurs ? '--ours' : '--theirs',
      '--',
      path,
    ], 'git checkout --ours/--theirs');
    await _runVoid(repoPath, ['git', 'add', '--', path], 'git add');
  }

  /// Resolves every conflicted path in [paths] the same way as
  /// [resolveConflict], but with 2 invocations total (one `checkout`, one
  /// `add` covering every path) instead of 2 per file — the multi-select
  /// bulk equivalent.
  Future<void> resolveConflictMany(
    String repoPath,
    List<String> paths, {
    required bool useOurs,
  }) async {
    await _runVoid(repoPath, [
      'git',
      'checkout',
      useOurs ? '--ours' : '--theirs',
      '--',
      ...paths,
    ], 'git checkout --ours/--theirs');
    await _runVoid(repoPath, ['git', 'add', '--', ...paths], 'git add');
  }

  /// Aborts an in-progress merge (`git merge --abort`).
  Future<void> mergeAbort(String repoPath) =>
      _runVoid(repoPath, ['git', 'merge', '--abort'], 'git merge --abort');

  /// Merges [branch] into the current branch. [mode] picks the strategy
  /// ([MergeMode.noFf] always creates a merge commit; [MergeMode.ffOnly] refuses
  /// anything but a fast-forward; [MergeMode.squash] stages the combined change
  /// without committing). Throws on conflicts — the working tree is left with
  /// markers and [pendingOp] reports [PendingOp.merge] so the UI can offer abort.
  Future<SSHCommandResult> merge(
    String repoPath,
    String branch, {
    MergeMode mode = MergeMode.normal,
  }) => _run(repoPath, [
    'git',
    ..._idArgs,
    'merge',
    '--no-edit',
    if (mode == MergeMode.noFf) '--no-ff',
    if (mode == MergeMode.ffOnly) '--ff-only',
    if (mode == MergeMode.squash) '--squash',
    '--end-of-options',
    branch,
  ], 'git merge');

  // ---- Rebase --------------------------------------------------------------

  /// Runs an interactive rebase of the commits after [onto] (an ancestor commit
  /// or ref) on the current branch, applying [steps] as the todo list. Driven
  /// headlessly: the plan is piped in on stdin and `GIT_SEQUENCE_EDITOR` swaps
  /// it in for git's generated todo, while `GIT_EDITOR=true` accepts squashed
  /// commit messages non-interactively. Dropped commits are simply omitted from
  /// [steps]. Throws on conflicts (working tree left with markers; [pendingOp]
  /// reports [PendingOp.rebase]).
  Future<SSHCommandResult> rebaseInteractive(
    String repoPath,
    String onto,
    List<RebaseStep> steps,
  ) async {
    final todo = steps
        .where((s) => s.action != RebaseAction.drop)
        .map((s) => '${_rebaseWord(s.action)} ${s.hash}')
        .join('\n');
    // Write our plan (piped in on stdin) to a temp file, then point the sequence
    // editor at a `cp` of that file over git's generated todo. The outer shell
    // expands $tmp into the env value so git's editor subshell sees the literal
    // path. No `set -e` — we capture git's exit code even on a conflict, clean
    // up, then propagate it. One shell invocation.
    final idFlags = _idFlagsForShell;
    final ontoQ = ShellEscaper.escape(onto);
    // `--end-of-options` stops an [onto] value that starts with `-` from
    // being parsed as a flag to `rebase -i`, same reasoning as [checkout].
    final script =
        'tmp=\$(mktemp) || exit 1; cat > "\$tmp"; '
        'GIT_SEQUENCE_EDITOR="cp \\"\$tmp\\"" GIT_EDITOR=true '
        'git${idFlags.isEmpty ? '' : ' $idFlags'} rebase -i --end-of-options $ontoQ; '
        'rc=\$?; rm -f "\$tmp"; exit \$rc';
    return _run(
      repoPath,
      ['sh', '-c', script],
      'git rebase -i',
      stdin: todo,
      timeout: commitTimeout,
    );
  }

  /// Continues a paused rebase after conflicts are resolved and staged. Uses a
  /// no-op editor so any squashed-message prompt is accepted non-interactively.
  Future<SSHCommandResult> rebaseContinue(String repoPath) => _run(
    repoPath,
    ['git', '-c', 'core.editor=true', ..._idArgs, 'rebase', '--continue'],
    'git rebase --continue',
    timeout: commitTimeout,
  );

  /// Aborts an in-progress rebase, restoring the pre-rebase branch state.
  Future<void> rebaseAbort(String repoPath) =>
      _runVoid(repoPath, ['git', 'rebase', '--abort'], 'git rebase --abort');

  static String _rebaseWord(RebaseAction a) => switch (a) {
    RebaseAction.pick => 'pick',
    RebaseAction.squash => 'squash',
    RebaseAction.fixup => 'fixup',
    RebaseAction.drop => 'drop', // never emitted (filtered out)
  };

  /// Identity `-c` overrides rendered for embedding in a shell command string
  /// (each token shell-quoted). Empty when no identity is configured.
  String get _idFlagsForShell => _idArgs.map(ShellEscaper.escape).join(' ');

  // ---- Remote sync ---------------------------------------------------------

  /// Fetches all remotes and prunes deleted refs. Returns the command result so
  /// callers can surface its output. Sync lane: a fetch touches refs and the
  /// network but never the index/worktree, so reads keep flowing while a slow
  /// fetch (up to [networkTimeout]) runs — but only one sync op at a time, so
  /// an auto-fetch can never race a manual fetch on ref locks.
  Future<SSHCommandResult> fetch(String repoPath) => _run(
    repoPath,
    ['git', 'fetch', '--all', '--prune'],
    'git fetch',
    timeout: networkTimeout,
    lane: ExecLane.sync,
  );

  /// Pulls upstream work. Defaults to fast-forward-only (never creates a
  /// surprise merge commit); [mode] can request a rebase or an explicit merge,
  /// and [remote]/[branch] override the tracked upstream.
  Future<SSHCommandResult> pull(
    String repoPath, {
    PullMode mode = PullMode.ffOnly,
    String? remote,
    String? branch,
  }) => _run(
    repoPath,
    [
      'git',
      'pull',
      switch (mode) {
        PullMode.ffOnly => '--ff-only',
        PullMode.rebase => '--rebase',
        PullMode.merge => '--no-rebase',
      },
      if (remote != null) '--end-of-options',
      ?remote,
      if (remote != null && branch != null) branch,
    ],
    'git pull',
    timeout: networkTimeout,
  );

  /// Pushes the current branch. Uses the remote host's own git credentials.
  /// [force] selects `--force-with-lease` or the blunt `--force`; [setUpstream]
  /// adds `-u`; [followTags] pushes annotated tags reachable from the pushed
  /// commits. [remote]/[branch] target a specific ref.
  Future<SSHCommandResult> push(
    String repoPath, {
    String? remote,
    String? branch,
    bool setUpstream = false,
    PushForce force = PushForce.none,
    bool followTags = false,
  }) => _run(
    repoPath,
    [
      'git',
      'push',
      if (force == PushForce.withLease) '--force-with-lease',
      if (force == PushForce.force) '--force',
      if (setUpstream) '-u',
      if (followTags) '--follow-tags',
      if (remote != null) '--end-of-options',
      ?remote,
      if (remote != null && branch != null) branch,
    ],
    'git push',
    timeout: networkTimeout,
    // Sync lane: push updates the remote (and local tracking refs) but never
    // the index/worktree — safe alongside reads, exclusive among sync ops.
    lane: ExecLane.sync,
  );

  // ---- Tags ----------------------------------------------------------------

  /// Creates a tag at [ref] (default HEAD). When [message] is non-empty the tag
  /// is annotated (`-a -m`), otherwise it's lightweight. An annotated tag is a
  /// real git object requiring an author identity, so it gets [_idArgs] like
  /// every other object-creating command; a lightweight tag is just a ref and
  /// doesn't need one, but including it unconditionally is harmless.
  Future<void> createTag(
    String repoPath,
    String name, {
    String? message,
    String ref = 'HEAD',
  }) => _runVoid(repoPath, [
    'git',
    ..._idArgs,
    'tag',
    if (message != null && message.isNotEmpty) ...['-a', '-m', message],
    '--end-of-options',
    name,
    ref,
  ], 'git tag');

  /// Deletes a local tag.
  Future<void> deleteTag(String repoPath, String name) => _runVoid(repoPath, [
    'git',
    'tag',
    '-d',
    '--end-of-options',
    name,
  ], 'git tag -d');

  /// Pushes a single tag to [remote].
  Future<SSHCommandResult> pushTag(
    String repoPath,
    String name, {
    String remote = 'origin',
  }) => _run(
    repoPath,
    ['git', 'push', '--end-of-options', remote, 'refs/tags/$name'],
    'git push tag',
    timeout: networkTimeout,
    lane: ExecLane.sync,
  );

  /// The SHA [rev] resolves to, or null if it doesn't exist (e.g. no upstream
  /// is configured, or HEAD is detached). Never throws for a missing rev, so
  /// callers can probe `@{upstream}` safely.
  Future<String?> revParse(String repoPath, String rev) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['git', 'rev-parse', '--verify', '--quiet', rev],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    final out = result.stdout.trim();
    return out.isEmpty ? null : out;
  }

  /// The name-status of every file changed across [range] (e.g. `old..new`),
  /// one `git diff --name-status` line per file — used to report what a
  /// push/pull/sync moved.
  Future<List<String>> changedFiles(String repoPath, String range) async {
    final result = await _run(
      repoPath,
      [
        'git',
        // Print non-ASCII paths literally (UTF-8) rather than C-quoting them, so
        // the display list isn't cluttered with `\NNN` octal escapes.
        '-c',
        'core.quotepath=false',
        'diff',
        '--name-status',
        '--end-of-options',
        range,
      ],
      'git diff --name-status',
      retries: _readRetries,
      lane: ExecLane.read,
    );
    return result.stdout.split('\n').where((l) => l.trim().isNotEmpty).toList();
  }

  // ---- Stash ---------------------------------------------------------------

  /// Stashes the working tree. [includeUntracked] adds `--include-untracked`
  /// so new (unadded) files are stashed too. `git stash push` creates real
  /// commit objects under the hood, so it needs [_idArgs] like every other
  /// object-creating command — without it, a host with no git identity
  /// configured fails to stash even though ordinary commits succeed.
  Future<SSHCommandResult> stashPush(
    String repoPath, {
    String? message,
    bool includeUntracked = false,
  }) => _run(repoPath, [
    'git',
    ..._idArgs,
    'stash',
    'push',
    if (includeUntracked) '--include-untracked',
    if (message != null && message.isNotEmpty) ...['-m', message],
  ], 'git stash push');

  Future<SSHCommandResult> stashPop(String repoPath, int index) => _run(
    repoPath,
    ['git', 'stash', 'pop', 'stash@{$index}'],
    'git stash pop',
  );

  Future<SSHCommandResult> stashApply(String repoPath, int index) => _run(
    repoPath,
    ['git', 'stash', 'apply', 'stash@{$index}'],
    'git stash apply',
  );

  Future<SSHCommandResult> stashDrop(String repoPath, int index) => _run(
    repoPath,
    ['git', 'stash', 'drop', 'stash@{$index}'],
    'git stash drop',
  );

  /// Drops every stash (`git stash clear`). Irreversible.
  Future<SSHCommandResult> stashClear(String repoPath) =>
      _run(repoPath, ['git', 'stash', 'clear'], 'git stash clear');

  /// The full patch a stash holds (`git stash show -p`), for previewing its
  /// contents. Read-only.
  Future<String> stashShow(String repoPath, int index) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['git', 'stash', 'show', '-p', '--no-color', 'stash@{$index}'],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('git stash show failed', result);
    }
    return result.stdout;
  }

  /// Lists stashes (`git stash list`), carrying each stash's relative age.
  Future<List<GitStash>> stashList(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['git', 'stash', 'list', '--format=%gd$fieldSep%gs$fieldSep%cr'],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    if (!result.isSuccess) {
      throw GitException('git stash list failed', result);
    }
    final stashes = <GitStash>[];
    for (final line in result.stdout.split('\n')) {
      if (line.trim().isEmpty) continue;
      final f = line.split(fieldSep);
      if (f.length < 2) continue;
      // %gd is like "stash@{0}"; extract the index.
      final match = RegExp(r'stash@\{(\d+)\}').firstMatch(f[0]);
      final index = match != null ? int.parse(match.group(1)!) : stashes.length;
      // %gs is like "WIP on main: <subject>" or "On main: <message>".
      final desc = f[1];
      final branchMatch = RegExp(r'(?:WIP on|On) ([^:]+):').firstMatch(desc);
      stashes.add(
        GitStash(
          index: index,
          branch: branchMatch?.group(1) ?? '',
          message: desc,
          relativeDate: f.length >= 3 ? f[2].trim() : '',
        ),
      );
    }
    return stashes;
  }

  /// Runs a command through the executor's lane scheduler and returns its
  /// result, throwing [GitException] on a non-zero exit. [lane] defaults to
  /// exclusive — the safe choice for a mutation; read-only callers pass
  /// [ExecLane.read] (and fetch/push pass [ExecLane.sync]) so they overlap.
  Future<SSHCommandResult> _run(
    String repoPath,
    List<String> gitArgs,
    String label, {
    Duration? timeout,
    String? stdin,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: gitArgs,
      timeout: timeout ?? SSHCommandExecutor.defaultTimeout,
      stdin: stdin,
      retries: retries,
      lane: lane,
      compress: compress,
    );
    if (!result.isSuccess) {
      // 127 means git itself wasn't found (argv[0] is always `git` here), not
      // that this particular command failed — say so clearly.
      if (result.exitCode == 127) {
        throw GitException(_gitNotFoundMessage, result);
      }
      throw GitException('$label failed', result);
    }
    return result;
  }

  Future<void> _runVoid(
    String repoPath,
    List<String> gitArgs,
    String label, {
    Duration? timeout,
  }) async {
    await _run(repoPath, gitArgs, label, timeout: timeout);
  }
}
