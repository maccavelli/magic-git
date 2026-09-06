/// The create-repository pipeline: everything between "the wizard's answers
/// are final" and "the new repo is registered as the workspace".
///
/// Extracted from a single 424-line `_submit()` in `create_repo_sheet.dart`
/// (MADR 0033 Phase 4). That method already named its own seams in banner
/// comments — pre-checks, existing-origin guard, init, identity, initial
/// commit, wire origin, verification — and those banners are the functions
/// below.
///
/// **Nothing here knows it is being driven by a widget.** No `BuildContext`,
/// no `setState`, no `ref`: the sequencing is reachable from a plain unit test
/// over a fake [CommandExecutor], which is exactly the seam-shaped gap MADR
/// 0030 catalogued. The two things that genuinely need the widget layer are
/// injected as callbacks — [CreateRepoDeps.ensureForgeLogin] (which pushes the
/// connection's token) and [CreateRepoDeps.isActive] (the host's `mounted`).
///
/// The pipeline never throws for an expected failure and never deletes
/// anything: a step that fails past the point of no return records a warning
/// and the local repository is kept. Only [CreateRepoOutcome.error] stops it.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/forge/forge.dart';
import '../../core/git/host_fs_service.dart';
import '../../core/github/gh_service.dart';
import '../../core/gitlab/glab_service.dart';
import '../../core/ssh/ssh_command_executor.dart';
import '../../core/utils/display_error.dart';
import '../../core/utils/posix_path.dart';

/// What `origin` should point at when the repo is created.
///
/// Public, and living here rather than in the sheet, because it is part of the
/// pipeline's contract: the sheet chooses it, the pipeline acts on it.
enum CreateRemoteMode { none, github, gitlab, customUrl }

/// What the pipeline needs from the output log — two methods, so a test can
/// supply a list-backed fake without pulling in Riverpod.
abstract interface class CreateRepoLog {
  void logResult(String label, SSHCommandResult result);
  void logError(String label, String detail);
}

/// The wizard's answers, **resolved**: plain values, never controllers.
///
/// A record of `TextEditingController`s would be the form state a second time
/// rather than a boundary — the point of this type is that the pipeline cannot
/// reach back into the widget for anything it forgot to ask for.
class CreateRepoRequest {
  /// True when turning a folder that already exists into a repository.
  final bool existing;

  /// The local directory name (and, without a namespace, the forge project
  /// name too).
  final String name;

  /// What the forge is asked to create, and what origin is resolved against —
  /// `name` prefixed by the namespace when one was given. Differs from [name]
  /// only then.
  final String forgePath;

  /// Resolved parent directory for a new folder. Ignored when [existing].
  final String parentDir;

  /// Resolved path of the folder being adopted. Ignored unless [existing].
  final String existingFolder;

  final String branch;
  final String host;
  final CreateRemoteMode remote;
  final bool private;
  final String description;
  final String remoteUrl;
  final bool addReadme;
  final bool commitAll;
  final bool replaceOrigin;
  final bool createParents;
  final bool isLocalTarget;
  final bool identityValid;
  final String authorName;
  final String authorEmail;

  const CreateRepoRequest({
    required this.existing,
    required this.name,
    required this.forgePath,
    required this.parentDir,
    required this.existingFolder,
    required this.branch,
    required this.host,
    required this.remote,
    required this.private,
    required this.description,
    required this.remoteUrl,
    required this.addReadme,
    required this.commitAll,
    required this.replaceOrigin,
    required this.createParents,
    required this.isLocalTarget,
    required this.identityValid,
    required this.authorName,
    required this.authorEmail,
  });

  bool get onForge =>
      remote == CreateRemoteMode.github || remote == CreateRemoteMode.gitlab;

  Forge get forge => switch (remote) {
    CreateRemoteMode.github => Forge.github,
    CreateRemoteMode.gitlab => Forge.gitlab,
    _ => Forge.none,
  };

  /// `-c user.name=… -c user.email=…` for a commit that must carry an author
  /// even when the repo's own config could not be written.
  List<String> get identityArgs => [
    if (authorName.isNotEmpty) ...['-c', 'user.name=$authorName'],
    if (authorEmail.isNotEmpty) ...['-c', 'user.email=$authorEmail'],
  ];

  /// Where the repository ends up.
  String get dest => existing
      ? stripTrailingSlashesKeepRoot(existingFolder)
      : HostFsService.joinPath(parentDir, name);
}

/// The widget-layer capabilities the pipeline borrows, injected so the
/// pipeline itself stays free of Riverpod and Flutter.
class CreateRepoDeps {
  /// Pushes the connection's forge token to the host before its CLI is
  /// queried. Called only for a forge create on an SSH target.
  final Future<void> Function() ensureForgeLogin;

  /// The host's `mounted`. Checked at exactly the points the original
  /// `_submit()` checked it, so a torn-down sheet stops the same work it
  /// always did.
  final bool Function() isActive;

  const CreateRepoDeps({
    required this.ensureForgeLogin,
    required this.isActive,
  });
}

/// The result of a run. Exactly one of three shapes:
///
/// * [aborted] — the host went away mid-run; the caller does nothing.
/// * [error] non-null — the run stopped before or at a point where nothing
///   irreversible had happened, and the message belongs in the sheet's error
///   slot.
/// * otherwise — the repository exists at [dest]; [warnings] may still list
///   things that went wrong afterwards and are worth showing.
class CreateRepoOutcome {
  final String dest;
  final List<String> warnings;
  final String? error;
  final bool aborted;

  const CreateRepoOutcome({
    required this.dest,
    this.warnings = const [],
    this.error,
    this.aborted = false,
  });

  const CreateRepoOutcome.abandoned(this.dest)
    : warnings = const [],
      error = null,
      aborted = true;

  const CreateRepoOutcome.failure(this.dest, this.error)
    : warnings = const [],
      aborted = false;

  /// Warnings joined for the sheet's completed-warning banner, or null when
  /// the run was clean.
  String? get warningText => warnings.isEmpty ? null : warnings.join('\n\n');
}

/// Runs the create pipeline. See the library comment for what is and is not
/// this function's business.
Future<CreateRepoOutcome> runCreateRepo({
  required CommandExecutor executor,
  required CreateRepoLog log,
  required CreateRepoRequest request,
  required CreateRepoDeps deps,
}) async {
  final fs = HostFsService(executor);
  final dest = request.dest;
  final warnings = <String>[];

  // --- Pre-checks ---------------------------------------------------------
  // Returns the "already a repo" classification alongside any failure: the
  // original ran ONE `rev-parse --show-toplevel` and used its result for both,
  // so re-probing here would add an executor call the sheet never made.
  final pre = await _preChecks(executor, fs, request, dest);
  if (pre.failure != null) return pre.failure!;
  if (!deps.isActive()) return CreateRepoOutcome.abandoned(dest);
  final alreadyRepo = pre.alreadyRepo;

  // Host-explicit login before a forge create on the connected host; a
  // This-Mac target relies on the Mac's own CLI auth (no managed token).
  if (request.onForge && !request.isLocalTarget) {
    await deps.ensureForgeLogin();
    if (!deps.isActive()) return CreateRepoOutcome.abandoned(dest);
  }

  // --- Existing-origin guard ----------------------------------------------
  // Before any mutation: a repo that already has an origin is only rewired
  // when the user explicitly opted into replacing it.
  if (alreadyRepo && request.remote != CreateRemoteMode.none) {
    final guard = await _existingOriginGuard(executor, log, request, dest);
    if (guard != null) return guard;
    if (!deps.isActive()) return CreateRepoOutcome.abandoned(dest);
  }

  // --- Step 1: init (skipped when the folder is already a repo) -----------
  // Init-first even for GitHub, so the user's chosen initial branch is always
  // authoritative — never a CLI fallback's `init.defaultBranch`.
  if (!alreadyRepo) {
    final failure = await _init(executor, log, request, dest);
    if (failure != null) return failure;
    if (!deps.isActive()) return CreateRepoOutcome.abandoned(dest);
  }

  // --- Identity: local user.name / user.email ------------------------------
  // A brand-new repo (or an in-place init) gets the identity written into its
  // own config so later commits — including ones not made through Magic Git —
  // have an author. An existing repo is only rewritten when the user opted
  // into commit-all (they confirmed the fields). Failures are warnings; the
  // commit still carries `-c`.
  if (request.identityValid && (!alreadyRepo || request.commitAll)) {
    await _writeIdentityConfig(executor, log, request, dest, warnings);
    if (!deps.isActive()) return CreateRepoOutcome.abandoned(dest);
  }

  // --- Step 2: optional initial commit ------------------------------------
  // Before the forge publish, so GitHub's --push (and the git push below) has
  // something to push and the branch is born on the forge too.
  var hasCommit = false;
  if (request.existing) {
    if (request.commitAll) {
      hasCommit = await _commitAllContents(
        executor,
        log,
        request,
        dest,
        warnings,
      );
      if (!deps.isActive()) return CreateRepoOutcome.abandoned(dest);
    }
    if (!hasCommit) {
      // The folder may already carry history (or a clean tree) — any
      // resolvable HEAD is pushable.
      final head = await executor.execute(
        repoPath: dest,
        gitArgs: ['git', 'rev-parse', '--verify', '--quiet', 'HEAD'],
        lane: ExecLane.read,
        retries: 0,
      );
      hasCommit = head.isSuccess;
    }
  } else if (request.addReadme) {
    hasCommit = await _writeReadmeAndCommit(
      executor,
      log,
      request,
      dest,
      warnings,
    );
    if (!deps.isActive()) return CreateRepoOutcome.abandoned(dest);
  }
  // For an existing folder push the resolved current branch (HEAD): when init
  // was skipped, the branch field never applied to this repo.
  final pushRef = request.existing ? 'HEAD' : request.branch;

  // --- Step 3: wire origin (mode-specific) --------------------------------
  // Every failure past this point keeps the local repo — registered by the
  // caller with a warning, never deleted over a remote hiccup.
  await _wireOrigin(executor, log, request, dest, hasCommit, pushRef, warnings);
  if (!deps.isActive()) return CreateRepoOutcome.abandoned(dest);

  // --- Step 4: post-create verification ------------------------------------
  // Every mode that promised an origin must show one. Forge modes already ran
  // _ensureForgeOrigin; this catch-all covers custom-URL and any forge edge
  // case that left origin unset without a prior warning.
  if (request.remote != CreateRemoteMode.none) {
    final failure = await _verifyOrigin(executor, log, dest);
    if (!deps.isActive()) return CreateRepoOutcome.abandoned(dest);
    if (failure != null) {
      final already = warnings.any(
        (w) =>
            w.contains('origin') ||
            w.contains('"origin"') ||
            w.contains('clone URL'),
      );
      if (!already) {
        warnings.add(
          'The repository was created, but no "origin" remote is '
          'configured — add one manually (git remote add origin <url>). '
          '($failure)',
        );
      }
    }
  }
  return CreateRepoOutcome(dest: dest, warnings: warnings);
}

/// Classifies the destination before anything is mutated. Returns a failure
/// outcome to stop on, or null to continue.
Future<({CreateRepoOutcome? failure, bool alreadyRepo})> _preChecks(
  CommandExecutor executor,
  HostFsService fs,
  CreateRepoRequest request,
  String dest,
) async {
  if (request.existing) {
    // Classify the picked folder: its own repo root (skip init), not a repo
    // yet (init in place), or nested inside another repo (refuse — publishing
    // a subfolder of someone's repo is never what they meant).
    final probe = await executor.execute(
      repoPath: dest,
      gitArgs: ['git', 'rev-parse', '--show-toplevel'],
      lane: ExecLane.read,
      retries: 0,
    );
    var alreadyRepo = false;
    if (probe.isSuccess) {
      final top = stripTrailingSlashesKeepRoot(probe.stdout.trim());
      if (top != dest) {
        return (
          failure: CreateRepoOutcome.failure(
            dest,
            'The folder is inside another Git repository ($top) — '
            "pick that repository's root instead.",
          ),
          alreadyRepo: false,
        );
      }
      alreadyRepo = true;
    } else if (!probe.stderr.toLowerCase().contains('not a git repository')) {
      // A plain non-repo folder is the expected miss; anything else (missing
      // folder, permissions) is a real error.
      return (
        failure: CreateRepoOutcome.failure(
          dest,
          probe.stderr.trim().isEmpty
              ? 'Could not inspect the folder (exit code ${probe.exitCode}).'
              : probe.stderr.trim(),
        ),
        alreadyRepo: false,
      );
    }
    return (failure: null, alreadyRepo: alreadyRepo);
  }
  switch (await fs.probePath(dest)) {
    case PathProbe.exists:
      return (
        failure: CreateRepoOutcome.failure(
          dest,
          'The destination already exists: $dest',
        ),
        alreadyRepo: false,
      );
    case PathProbe.noParent:
      if (!request.isLocalTarget && request.createParents) {
        await fs.makeDirs(request.parentDir);
        return (failure: null, alreadyRepo: false);
      }
      return (
        failure: CreateRepoOutcome.failure(
          dest,
          "The parent folder doesn't exist: ${request.parentDir}",
        ),
        alreadyRepo: false,
      );
    case PathProbe.absent:
      return (failure: null, alreadyRepo: false);
  }
}

Future<CreateRepoOutcome?> _existingOriginGuard(
  CommandExecutor executor,
  CreateRepoLog log,
  CreateRepoRequest request,
  String dest,
) async {
  final current = await executor.execute(
    repoPath: dest,
    gitArgs: ['git', 'remote', 'get-url', 'origin'],
    lane: ExecLane.read,
    retries: 0,
  );
  if (!current.isSuccess || current.stdout.trim().isEmpty) return null;
  if (!request.replaceOrigin) {
    return CreateRepoOutcome.failure(
      dest,
      'This repository already has an origin remote '
      '(${current.stdout.trim()}). Turn on "Replace existing '
      'origin remote" to overwrite it.',
    );
  }
  final removed = await executor.execute(
    repoPath: dest,
    gitArgs: ['git', 'remote', 'remove', 'origin'],
    lane: ExecLane.exclusive,
    retries: 0,
  );
  log.logResult('git remote remove origin', removed);
  if (!removed.isSuccess) {
    return CreateRepoOutcome.failure(
      dest,
      removed.stderr.trim().isEmpty
          ? 'git remote remove origin exited with code ${removed.exitCode}'
          : removed.stderr.trim(),
    );
  }
  return null;
}

Future<CreateRepoOutcome?> _init(
  CommandExecutor executor,
  CreateRepoLog log,
  CreateRepoRequest request,
  String dest,
) async {
  final initArgs = request.existing
      ? ['git', 'init', '-b', request.branch]
      : ['git', 'init', '-b', request.branch, '--', request.name];
  final initResult = await executor.execute(
    repoPath: request.existing ? dest : request.parentDir,
    gitArgs: initArgs,
    lane: ExecLane.exclusive,
    retries: 0,
  );
  log.logResult(initArgs.join(' '), initResult);
  if (initResult.isSuccess) return null;
  return CreateRepoOutcome.failure(
    dest,
    initResult.stderr.trim().isEmpty
        ? 'git init exited with code ${initResult.exitCode}'
        : initResult.stderr.trim(),
  );
}

/// Writes `user.name` / `user.email` into [dest]'s local git config.
/// Failures append to [warnings]; the repo is kept. Caller only invokes this
/// when both fields are valid.
Future<void> _writeIdentityConfig(
  CommandExecutor executor,
  CreateRepoLog log,
  CreateRepoRequest request,
  String dest,
  List<String> warnings,
) async {
  for (final argv in [
    ['git', 'config', '--local', 'user.name', request.authorName],
    ['git', 'config', '--local', 'user.email', request.authorEmail],
  ]) {
    final result = await executor.execute(
      repoPath: dest,
      gitArgs: argv,
      lane: ExecLane.exclusive,
      retries: 0,
    );
    log.logResult(argv.join(' '), result);
    if (!result.isSuccess) {
      warnings.add(
        'Could not write git identity into the new repository '
        '(${argv.join(' ')}). '
        '(${result.stderr.trim().isEmpty ? 'exited with code ${result.exitCode}' : result.stderr.trim()})',
      );
      return;
    }
  }
}

/// Writes a README.md into [dest] and creates the initial commit, so the new
/// repo (and, after the push, the forge) isn't empty and the initial branch is
/// actually born. Returns true when the commit exists; failures append to
/// [warnings] and the repo is kept.
Future<bool> _writeReadmeAndCommit(
  CommandExecutor executor,
  CreateRepoLog log,
  CreateRepoRequest request,
  String dest,
  List<String> warnings,
) async {
  final desc = request.description;
  final content = desc.isEmpty
      ? '# ${request.name}\n'
      : '# ${request.name}\n\n$desc\n';
  try {
    await executor.uploadBytes(
      HostFsService.joinPath(dest, 'README.md'),
      Uint8List.fromList(utf8.encode(content)),
    );
    for (final argv in [
      ['git', 'add', '--', 'README.md'],
      [
        'git',
        ...request.identityArgs,
        'commit',
        '--no-gpg-sign',
        '-m',
        'Initial commit',
      ],
    ]) {
      final result = await executor.execute(
        repoPath: dest,
        gitArgs: argv,
        lane: ExecLane.exclusive,
        retries: 0,
      );
      log.logResult(argv.join(' '), result);
      if (!result.isSuccess) {
        warnings.add(
          'The README initial commit failed — commit manually. '
          '(${result.stderr.trim().isEmpty ? '${argv.join(' ')} exited with code ${result.exitCode}' : result.stderr.trim()})',
        );
        return false;
      }
    }
    return true;
  } catch (e) {
    warnings.add('The README initial commit failed. ($e)');
    return false;
  }
}

/// Stages and commits everything in [dest] — the existing-folder analogue of
/// [_writeReadmeAndCommit]. Returns true when a commit was created. A clean
/// tree ("nothing to commit") is not an error — the caller falls back to
/// checking whether HEAD already resolves; real failures append to [warnings]
/// and the repo is kept.
Future<bool> _commitAllContents(
  CommandExecutor executor,
  CreateRepoLog log,
  CreateRepoRequest request,
  String dest,
  List<String> warnings,
) async {
  for (final argv in [
    ['git', 'add', '--all'],
    [
      'git',
      ...request.identityArgs,
      'commit',
      '--no-gpg-sign',
      '-m',
      'Initial commit',
    ],
  ]) {
    final result = await executor.execute(
      repoPath: dest,
      gitArgs: argv,
      lane: ExecLane.exclusive,
      retries: 0,
    );
    log.logResult(argv.join(' '), result);
    if (!result.isSuccess) {
      if ('${result.stdout}\n${result.stderr}'.contains('nothing to commit')) {
        return false;
      }
      warnings.add(
        'Committing the folder contents failed — commit manually. '
        '(${result.stderr.trim().isEmpty ? '${argv.join(' ')} exited with code ${result.exitCode}' : result.stderr.trim()})',
      );
      return false;
    }
  }
  return true;
}

/// Wires `origin` for the chosen mode. Forge modes create the project through
/// the CLI's API and then **always** attempt origin wiring — even when create
/// exits non-zero, because the project may already exist on the forge.
Future<void> _wireOrigin(
  CommandExecutor executor,
  CreateRepoLog log,
  CreateRepoRequest request,
  String dest,
  bool hasCommit,
  String pushRef,
  List<String> warnings,
) async {
  switch (request.remote) {
    case CreateRemoteMode.none:
      return;
    case CreateRemoteMode.github:
      final label = 'gh repo create ${request.forgePath}';
      final gh = GhService(executor);
      SSHCommandResult? created;
      String? createFailure;
      try {
        created = await gh.createRepoInExisting(
          repoPath: dest,
          name: request.forgePath,
          private: request.private,
          description: request.description,
          host: request.host,
        );
        log.logResult(label, created);
      } on GhException catch (e) {
        log.logResult(label, e.result);
        createFailure = e.result.stderr.trim().isEmpty
            ? displayError(e)
            : e.result.stderr.trim();
      }
      // Always attempt origin wiring — partial create success is common. The
      // create's own output is the primary URL source (gh prints the new
      // repo's URL); the API lookup chain is the fallback.
      final before = warnings.length;
      await _ensureForgeOrigin(
        executor,
        log,
        dest,
        hasCommit,
        pushRef,
        warnings,
        forge: Forge.github,
        lookupUrl: () => gh.resolveOriginUrl(
          repoPath: dest,
          name: request.forgePath,
          host: request.host,
          createOutput: created?.stdout,
        ),
      );
      if (createFailure != null) {
        // If origin was wired, the forge project exists — drop the create
        // error so a partial-success path can still finish cleanly.
        final originOk = await _verifyOrigin(executor, log, dest) == null;
        if (!originOk) {
          warnings.insert(
            before,
            'The repository was created locally, but publishing to '
            'GitHub failed — you can retry from the forge later. '
            '($createFailure)',
          );
        }
      }
    case CreateRemoteMode.gitlab:
      final label = 'glab repo create ${request.forgePath}';
      final glab = GlabService(executor);
      SSHCommandResult? created;
      String? createFailure;
      try {
        created = await glab.createRepoInExisting(
          repoPath: dest,
          name: request.forgePath,
          private: request.private,
          description: request.description,
          host: request.host,
        );
        log.logResult(label, created);
      } on GlabException catch (e) {
        log.logResult(label, e.result);
        createFailure = e.result.stderr.trim().isEmpty
            ? displayError(e)
            : e.result.stderr.trim();
      }
      final before = warnings.length;
      await _ensureForgeOrigin(
        executor,
        log,
        dest,
        hasCommit,
        pushRef,
        warnings,
        forge: Forge.gitlab,
        lookupUrl: () => glab.resolveOriginUrl(
          repoPath: dest,
          name: request.forgePath,
          host: request.host,
          createOutput: created?.stdout,
        ),
      );
      if (createFailure != null) {
        final originOk = await _verifyOrigin(executor, log, dest) == null;
        if (!originOk) {
          warnings.insert(
            before,
            'The repository was created locally, but publishing to '
            'GitLab failed — you can retry from the forge later. '
            '($createFailure)',
          );
        }
      }
    case CreateRemoteMode.customUrl:
      // Plain git, no forge CLI — for a remote that already exists.
      final url = request.remoteUrl;
      final label = 'git remote add origin $url';
      final result = await executor.execute(
        repoPath: dest,
        gitArgs: ['git', 'remote', 'add', 'origin', url],
        lane: ExecLane.exclusive,
        retries: 0,
      );
      log.logResult(label, result);
      if (!result.isSuccess) {
        warnings.add(
          'The repository was created locally, but configuring the '
          '"origin" remote failed. '
          '(${result.stderr.trim().isEmpty ? 'git remote add exited with code ${result.exitCode}' : result.stderr.trim()})',
        );
      } else if (hasCommit) {
        await _pushInitial(executor, log, dest, pushRef, warnings);
      }
  }
}

/// Pushes the initial commit and sets upstream with PATH-hardened `git`.
/// When [forge] is GitHub/GitLab, HTTPS auth rides that CLI's credential
/// helper for this one command (see [forgeGitAuthConfigArgs]) — matching the
/// store that just created the project. Best-effort: failures append to
/// [warnings]; local repo + origin stay.
Future<void> _pushInitial(
  CommandExecutor executor,
  CreateRepoLog log,
  String dest,
  String branch,
  List<String> warnings, {
  Forge forge = Forge.none,
}) async {
  final auth = forgeGitAuthConfigArgs(
    forge,
    ghPath: executor.resolvedBinaryPath('gh'),
    glabPath: executor.resolvedBinaryPath('glab'),
  );
  final label = 'git push -u origin $branch';
  try {
    final result = await executor.execute(
      repoPath: dest,
      gitArgs: ['git', ...auth, 'push', '-u', 'origin', branch],
      lane: ExecLane.sync,
      retries: 0,
    );
    log.logResult(label, result);
    if (!result.isSuccess) {
      warnings.add(
        'The initial commit could not be pushed — push manually once the '
        'remote is reachable. '
        '(${result.stderr.trim().isEmpty ? '$label exited with code ${result.exitCode}' : result.stderr.trim()})',
      );
    }
  } catch (e) {
    warnings.add('The initial commit could not be pushed. ($e)');
  }
}

/// Guarantees a usable `origin` in [dest] after a forge create attempt, using
/// PATH-hardened `git` only — never forge-nested git. Always owns push when
/// [hasCommit]. Idempotent and best-effort:
///  * origin already resolves → push if needed
///  * origin missing → [lookupUrl] + `git remote add origin`, then push
///
/// Returns whether origin is present after this call. A failed resolution
/// carries its diagnostic trail ([OriginUrlResolution.detail]) into both the
/// warning banner and the output log, so a live failure names its cause
/// instead of a bare "could not be determined".
Future<bool> _ensureForgeOrigin(
  CommandExecutor executor,
  CreateRepoLog log,
  String dest,
  bool hasCommit,
  String pushRef,
  List<String> warnings, {
  required Forge forge,
  required Future<OriginUrlResolution> Function() lookupUrl,
}) async {
  final existing = await executor.execute(
    repoPath: dest,
    gitArgs: ['git', 'remote', 'get-url', 'origin'],
    lane: ExecLane.read,
    retries: 0,
  );
  var hasOrigin = existing.isSuccess && existing.stdout.trim().isNotEmpty;
  if (!hasOrigin) {
    final resolved = await lookupUrl();
    final url = resolved.url?.trim();
    if (url == null || url.isEmpty) {
      log.logError('origin clone-URL resolution', resolved.detail);
      warnings.add(
        'The repository was created on the forge, but no "origin" remote '
        'could be configured locally — its clone URL could not be '
        'determined. Add one manually: git remote add origin <url>. '
        '(${resolved.detail})',
      );
      return false;
    }
    final add = await executor.execute(
      repoPath: dest,
      gitArgs: ['git', 'remote', 'add', 'origin', url],
      lane: ExecLane.exclusive,
      retries: 0,
    );
    log.logResult('git remote add origin $url', add);
    if (!add.isSuccess) {
      warnings.add(
        'The repository was created on the forge, but wiring the "origin" '
        'remote failed. '
        '(${add.stderr.trim().isEmpty ? 'git remote add exited with code ${add.exitCode}' : add.stderr.trim()})',
      );
      return false;
    }
    hasOrigin = true;
  }
  // We own push entirely (forge create is API-only).
  if (hasCommit && hasOrigin) {
    await _pushInitial(executor, log, dest, pushRef, warnings, forge: forge);
  }
  return hasOrigin;
}

/// Confirms `origin` resolves inside [dest] — `git remote get-url origin`
/// exits 0 and prints a URL. Returns null on success, else a short
/// human-readable failure detail. Never throws (verification must not turn a
/// created repo into an error).
Future<String?> _verifyOrigin(
  CommandExecutor executor,
  CreateRepoLog log,
  String dest,
) async {
  const label = 'git remote get-url origin';
  try {
    final result = await executor.execute(
      repoPath: dest,
      gitArgs: ['git', 'remote', 'get-url', 'origin'],
      lane: ExecLane.read,
      retries: 0,
    );
    log.logResult(label, result);
    if (result.isSuccess && result.stdout.trim().isNotEmpty) return null;
    final err = result.stderr.trim();
    return err.isEmpty ? '$label exited with code ${result.exitCode}' : err;
  } catch (e) {
    return displayError(e);
  }
}
