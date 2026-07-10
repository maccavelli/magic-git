import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/forge/forge.dart';
import '../../core/git/host_fs_service.dart';
import '../../core/github/gh_service.dart';
import '../../core/gitlab/glab_service.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/ssh/ssh_command_executor.dart';
import '../../core/storage/saved_connection.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/tool_icon_button.dart';
import 'remote_directory_browser.dart';
import 'workspace_registration.dart';
import 'workspace_targets.dart';
import 'workspace_widgets.dart';

/// What `origin` should point at when the repo is created — a first-class,
/// always-visible choice (not an opt-in extra), because a repo without a
/// remote is rarely what the user wants.
enum _RemoteMode { none, github, gitlab, customUrl }

/// Where the repository's working tree comes from: a brand-new folder
/// (name + parent), or an existing folder that gets initialized/published
/// in place.
enum _SourceMode { newFolder, existingFolder }

/// One page of the create wizard, described as data: the engine (indicator,
/// Back/Continue gating, review) is generic over this list, so adding or
/// reordering a step is a single entry in [_CreateRepositorySheetState._steps]
/// — no navigation code changes.
class _WizardStep {
  final String id;
  final String title;

  /// Whether the step participates at all (e.g. Destination exists only on
  /// the landing variant). Evaluated live, so steps may come and go with
  /// earlier answers.
  final bool Function() applicable;

  /// Gates the Continue button (and, composed across all steps, Create).
  final bool Function() valid;

  final Widget Function(MacosTypography) body;

  const _WizardStep({
    required this.id,
    required this.title,
    this.applicable = _always,
    required this.valid,
    required this.body,
  });

  static bool _always() => true;
}

/// Create a new repository — plain `git init`, forge-backed (created on
/// GitHub/GitLab with `origin` wired), or pointed at an existing remote URL —
/// on the connected SSH host or this Mac.
///
/// Same two modes as the clone sheet: [CreateRepositorySheet.connected]
/// targets the active workspace; [CreateRepositorySheet.landing] adds the
/// destination picker (This Mac, or a saved SSH connection provisioned on
/// demand).
///
/// Presented as a data-driven wizard: an ordered list of [_WizardStep]s
/// (Destination → Source → Remote → Details → Review) that the build method
/// renders generically — breadcrumb indicator, per-step Continue gating,
/// Back navigation, and a final review summary derived from the collected
/// state. The Destination step only participates on the landing variant.
///
/// Two sources ([_SourceMode]): a brand-new folder (name + parent), or an
/// existing folder published in place — classified at submit as not-a-repo
/// (init in place), its own repo root (init skipped, existing history
/// pushed; an existing `origin` is only replaced after an explicit opt-in),
/// or nested inside another repo (refused).
///
/// Every mode is init-first — `git init -b <branch> -- <name>` in the parent,
/// so the user's chosen initial branch is always authoritative — followed by
/// an optional README + initial commit, then mode-specific origin wiring:
///  * None       — nothing further.
///  * GitHub     — `gh repo create <name> --source . --remote origin` run
///    inside the new repo (gh's documented "push an existing local repo"
///    path), with `--push` when the README commit exists.
///  * GitLab     — `glab repo create` inside the new repo (its documented
///    origin-wiring path), then `git push -u` when a commit exists.
///  * Custom URL — `git remote add origin &lt;url&gt;` (no forge CLI — for
///    repos already created on a web UI, bare repos on an SSH host, or any
///    other pre-existing remote), then `git push -u` when a commit exists.
///
/// Once `git init` has succeeded, the repo is always kept and registered: a
/// failure in any later step (commit, forge publish, push, verification)
/// keeps the sheet open with a warning instead — never deleted over a remote
/// hiccup. Every mode that promises a remote is verified after the fact:
/// `git remote get-url origin` must print a URL from inside the new repo.
class CreateRepositorySheet extends ConsumerStatefulWidget {
  final bool landing;
  const CreateRepositorySheet.connected({super.key}) : landing = false;
  const CreateRepositorySheet.landing({super.key}) : landing = true;

  @override
  ConsumerState<CreateRepositorySheet> createState() =>
      _CreateRepositorySheetState();
}

class _CreateRepositorySheetState extends ConsumerState<CreateRepositorySheet> {
  final _name = TextEditingController();
  final _branch = TextEditingController(text: 'main');
  final _parent = TextEditingController();
  final _host = TextEditingController(text: 'github.com');
  final _description = TextEditingController();
  final _remoteUrl = TextEditingController();

  _RemoteMode _remote = _RemoteMode.none;
  _SourceMode _source = _SourceMode.newFolder;
  bool _private = true;
  bool _addReadme = false;

  // Existing-folder source options.
  final _folder = TextEditingController();
  String? _pickedFolder;
  bool _commitAll = false;
  bool _replaceOrigin = false;

  // SSH destination options.
  bool _createParents = false;
  bool _fsmonitor = false;

  // Local destination options.
  String? _pickedParent;
  bool _saveLocal = true;
  final _localLabel = TextEditingController();
  bool _picking = false;

  // Landing destination selection: null id = "This Mac", else a connection id.
  String? _destConnectionId;

  bool _submitting = false;
  String? _error;

  /// Set when the repo was created and registered but a non-fatal step failed
  /// (the GitLab forge publish) — the footer becomes a single Close button.
  String? _completedWarning;

  // Provisioning (landing → saved SSH connection).
  int? _provisionToken;
  bool _provisioning = false;

  WorkspaceTarget _target = WorkspaceTarget.sshActive;
  VoidCallback? _unregisterEscape;

  // --- Wizard engine ---------------------------------------------------
  // The steps, in order, as data — the build method renders whatever this
  // list says. Bodies/predicates close over the sheet's state fields.
  late final List<_WizardStep> _steps = [
    _WizardStep(
      id: 'destination',
      title: 'Destination',
      applicable: () => widget.landing,
      valid: () => !_provisioning,
      body: _destinationSection,
    ),
    _WizardStep(
      id: 'source',
      title: 'Source',
      valid: _sourceValid,
      body: _sourceStep,
    ),
    _WizardStep(
      id: 'remote',
      title: 'Remote',
      valid: _remoteValid,
      body: _remoteSection,
    ),
    _WizardStep(
      id: 'details',
      title: 'Details',
      valid: _detailsValid,
      body: _detailsStep,
    ),
    _WizardStep(
      id: 'review',
      title: 'Review',
      valid: _WizardStep._always,
      body: _reviewStep,
    ),
  ];
  int _stepIndex = 0;

  List<_WizardStep> get _activeSteps =>
      [for (final s in _steps) if (s.applicable()) s];

  bool _sourceValid() {
    if (_source == _SourceMode.existingFolder) {
      if (_isLocalTarget) return _pickedFolder != null;
      return _folder.text.trim().startsWith('/');
    }
    if (_isLocalTarget) return _pickedParent != null;
    return _parent.text.trim().startsWith('/');
  }

  bool _remoteValid() =>
      _remote != _RemoteMode.customUrl || _remoteUrl.text.trim().isNotEmpty;

  bool _detailsValid() {
    if (_branch.text.trim().isEmpty) return false;
    final needName = _source == _SourceMode.newFolder || _onForge;
    return !needName || HostFsService.isValidRepoDirName(_name.text.trim());
  }

  void _goBack() {
    if (_stepIndex == 0 || _submitting) return;
    setState(() {
      _stepIndex--;
      _error = null;
    });
  }

  void _goNext() {
    final steps = _activeSteps;
    if (_stepIndex >= steps.length - 1) return;
    if (!steps[_stepIndex].valid()) return;
    setState(() {
      _stepIndex++;
      _error = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _unregisterEscape = EscapeDismissRegistry.register(() {
      _requestClose();
      return true;
    });
    _recomputeTarget();
  }

  @override
  void dispose() {
    _unregisterEscape?.call();
    _name.dispose();
    _branch.dispose();
    _parent.dispose();
    _host.dispose();
    _description.dispose();
    _remoteUrl.dispose();
    _folder.dispose();
    _localLabel.dispose();
    super.dispose();
  }

  void _recomputeTarget() {
    final conn = ref.read(connectionProvider);
    if (!widget.landing) {
      _target = conn.isLocal
          ? WorkspaceTarget.localMac
          : WorkspaceTarget.sshActive;
      if (_target == WorkspaceTarget.sshActive &&
          _parent.text.isEmpty &&
          conn.repoPath != null) {
        _parent.text = _dirOf(conn.repoPath!);
      }
    } else {
      _target = _destConnectionId == null
          ? WorkspaceTarget.localMac
          : WorkspaceTarget.sshProvision;
    }
  }

  bool get _isLocalTarget => _target == WorkspaceTarget.localMac;

  bool get _onForge =>
      _remote == _RemoteMode.github || _remote == _RemoteMode.gitlab;

  Forge get _forge =>
      _remote == _RemoteMode.gitlab ? Forge.gitlab : Forge.github;

  String get _defaultHost =>
      _remote == _RemoteMode.gitlab ? 'gitlab.com' : 'github.com';

  Future<void> _onDestChanged(String? connectionId) async {
    await _resetProvisioning();
    setState(() {
      _destConnectionId = connectionId;
      _error = null;
      _recomputeTarget();
    });
  }

  Future<void> _resetProvisioning() async {
    final token = _provisionToken;
    _provisionToken = null;
    if (token != null) {
      await ref.read(connectionProvider.notifier).abortProvisioning(token);
    }
  }

  Future<bool> _ensureProvisioned() async {
    if (_target != WorkspaceTarget.sshProvision) return true;
    if (_provisionToken != null) return true;
    if (_provisioning) return false;
    final conn = await _connectionById(_destConnectionId);
    if (conn == null) return false;
    setState(() {
      _provisioning = true;
      _error = null;
    });
    final token = await ref
        .read(connectionProvider.notifier)
        .beginProvisioning(conn);
    if (!mounted) return false;
    setState(() {
      _provisioning = false;
      _provisionToken = token;
      if (token == null) {
        _error =
            ref.read(connectionProvider).error ?? 'Could not connect to host.';
      }
    });
    return token != null;
  }

  Future<SavedConnection?> _connectionById(String? id) async {
    if (id == null) return null;
    final List<SavedConnection> list;
    try {
      list = await ref.read(savedConnectionsProvider.future);
    } catch (_) {
      return null;
    }
    for (final c in list) {
      if (c.id == id) return c;
    }
    return null;
  }

  bool get _canSubmit {
    if (_submitting || _completedWarning != null) return false;
    return _activeSteps.every((s) => s.valid());
  }

  CommandExecutor get _executor => _isLocalTarget
      ? ref.read(localExecutorProvider)
      : ref.read(activeExecutorProvider);

  Future<void> _submit() async {
    if (_submitting || !_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (!await _ensureProvisioned()) return;
      if (_isLocalTarget) {
        // Outside a local session (landing → This Mac) the local executor
        // has never been environment-probed; without this, gh/glab in a
        // Homebrew bin dir are invisible to the GUI app's inherited PATH.
        await ref.read(localEnvironmentProvider).ensure();
        if (!mounted) return;
      }

      final executor = _executor;
      final fs = HostFsService(executor);
      final log = ref.read(outputLogProvider.notifier);
      final name = _name.text.trim();
      final existing = _source == _SourceMode.existingFolder;
      final String? parentDir;
      final String dest;
      if (existing) {
        parentDir = null;
        dest = _stripTrailingSlashes(
          _isLocalTarget ? _pickedFolder! : _folder.text.trim(),
        );
      } else {
        parentDir = _isLocalTarget ? _pickedParent! : _parent.text.trim();
        dest = HostFsService.joinPath(parentDir, name);
      }
      final host = _host.text.trim().isEmpty ? _defaultHost : _host.text.trim();

      // --- Pre-checks ---------------------------------------------------
      var alreadyRepo = false;
      if (existing) {
        // Classify the picked folder: its own repo root (skip init), not a
        // repo yet (init in place), or nested inside another repo (refuse —
        // publishing a subfolder of someone's repo is never what they meant).
        final probe = await executor.execute(
          repoPath: dest,
          gitArgs: ['git', 'rev-parse', '--show-toplevel'],
          lane: ExecLane.read,
          retries: 0,
        );
        if (probe.isSuccess) {
          final top = _stripTrailingSlashes(probe.stdout.trim());
          if (top != dest) {
            setState(
              () => _error =
                  'The folder is inside another Git repository ($top) — '
                  "pick that repository's root instead.",
            );
            return;
          }
          alreadyRepo = true;
        } else if (!probe.stderr.toLowerCase().contains(
          'not a git repository',
        )) {
          // A plain non-repo folder is the expected miss; anything else
          // (missing folder, permissions) is a real error.
          setState(
            () => _error = probe.stderr.trim().isEmpty
                ? 'Could not inspect the folder (exit code ${probe.exitCode}).'
                : probe.stderr.trim(),
          );
          return;
        }
      } else {
        switch (await fs.probePath(dest)) {
          case PathProbe.exists:
            setState(() => _error = 'The destination already exists: $dest');
            return;
          case PathProbe.noParent:
            if (!_isLocalTarget && _createParents) {
              await fs.makeDirs(parentDir!);
            } else {
              setState(
                () => _error = "The parent folder doesn't exist: $parentDir",
              );
              return;
            }
          case PathProbe.absent:
            break;
        }
      }
      if (!mounted) return;

      // Host-explicit login before a forge create on the connected host; a
      // This-Mac target relies on the Mac's own CLI auth (no managed token).
      if (_onForge && !_isLocalTarget) {
        await ref
            .read(connectionProvider.notifier)
            .ensureForgeHostLogin(_forge, host);
        if (!mounted) return;
      }

      // --- Existing-origin guard ------------------------------------------
      // Before any mutation: a repo that already has an origin is only
      // rewired when the user explicitly opted into replacing it.
      if (alreadyRepo && _remote != _RemoteMode.none) {
        final current = await executor.execute(
          repoPath: dest,
          gitArgs: ['git', 'remote', 'get-url', 'origin'],
          lane: ExecLane.read,
          retries: 0,
        );
        if (current.isSuccess && current.stdout.trim().isNotEmpty) {
          if (!_replaceOrigin) {
            setState(
              () => _error =
                  'This repository already has an origin remote '
                  '(${current.stdout.trim()}). Turn on "Replace existing '
                  'origin remote" to overwrite it.',
            );
            return;
          }
          final removed = await executor.execute(
            repoPath: dest,
            gitArgs: ['git', 'remote', 'remove', 'origin'],
            lane: ExecLane.exclusive,
            retries: 0,
          );
          log.logResult('git remote remove origin', removed);
          if (!removed.isSuccess) {
            setState(
              () => _error = removed.stderr.trim().isEmpty
                  ? 'git remote remove origin exited with code '
                        '${removed.exitCode}'
                  : removed.stderr.trim(),
            );
            return;
          }
        }
        if (!mounted) return;
      }

      final warnings = <String>[];

      // --- Step 1: init (skipped when the folder is already a repo) --------
      // Init-first even for GitHub, so the user's chosen initial branch is
      // always authoritative — never a CLI fallback's `init.defaultBranch`.
      final branch = _branch.text.trim();
      if (!alreadyRepo) {
        final initArgs = existing
            ? ['git', 'init', '-b', branch]
            : ['git', 'init', '-b', branch, '--', name];
        final initResult = await executor.execute(
          repoPath: existing ? dest : parentDir!,
          gitArgs: initArgs,
          lane: ExecLane.exclusive,
          retries: 0,
        );
        log.logResult(initArgs.join(' '), initResult);
        if (!initResult.isSuccess) {
          setState(
            () => _error = initResult.stderr.trim().isEmpty
                ? 'git init exited with code ${initResult.exitCode}'
                : initResult.stderr.trim(),
          );
          return;
        }
        if (!mounted) return;
      }

      // --- Step 2: optional initial commit --------------------------------
      // Before the forge publish, so GitHub's --push (and the git push below)
      // has something to push and the branch is born on the forge too.
      var hasCommit = false;
      if (existing) {
        if (_commitAll) {
          hasCommit = await _commitAllContents(executor, log, dest, warnings);
          if (!mounted) return;
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
      } else if (_addReadme) {
        hasCommit = await _writeReadmeAndCommit(executor, log, dest, warnings);
        if (!mounted) return;
      }
      // For an existing folder push the resolved current branch (HEAD): when
      // init was skipped, the branch field never applied to this repo.
      final pushRef = existing ? 'HEAD' : branch;

      // --- Step 3: wire origin (mode-specific) ----------------------------
      // Every failure past this point keeps the local repo — registered
      // below with a warning, never deleted over a remote hiccup.
      switch (_remote) {
        case _RemoteMode.none:
          break;
        case _RemoteMode.github:
          final label = 'gh repo create $name';
          try {
            final result = await GhService(executor).createRepoInExisting(
              repoPath: dest,
              name: name,
              private: _private,
              description: _description.text.trim(),
              host: host,
              push: hasCommit,
            );
            log.logResult(label, result);
          } on GhException catch (e) {
            log.logResult(label, e.result);
            warnings.add(
              'The repository was created locally, but publishing to '
              'GitHub failed — you can retry from the forge later. '
              '(${e.result.stderr.trim().isEmpty ? e : e.result.stderr.trim()})',
            );
          }
        case _RemoteMode.gitlab:
          final label = 'glab repo create $name';
          try {
            await GlabService(executor).createRepoInExisting(
              repoPath: dest,
              name: name,
              private: _private,
              description: _description.text.trim(),
              host: host,
            );
            if (hasCommit) {
              await _pushInitial(executor, log, dest, pushRef, warnings);
            }
          } on GlabException catch (e) {
            log.logResult(label, e.result);
            warnings.add(
              'The repository was created locally, but publishing to '
              'GitLab failed — you can retry from the forge later. '
              '(${e.result.stderr.trim().isEmpty ? e : e.result.stderr.trim()})',
            );
          }
        case _RemoteMode.customUrl:
          // Plain git, no forge CLI — for a remote that already exists.
          final url = _remoteUrl.text.trim();
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
      if (!mounted) return;

      // --- Step 4: post-create verification -------------------------------
      // Every mode that promises an origin must actually show one: don't
      // trust the forge CLI's (or our own) remote wiring blindly.
      if (warnings.isEmpty && _remote != _RemoteMode.none) {
        final failure = await _verifyOrigin(executor, log, dest);
        if (!mounted) return;
        if (failure != null) {
          warnings.add(
            'The repository was created, but no "origin" remote is '
            'configured — add one manually (git remote add origin <url>). '
            '($failure)',
          );
        }
      }
      final warning = warnings.isEmpty ? null : warnings.join('\n\n');

      // --- Register + activate (shared matrix) --------------------------
      await _register(dest);
      if (!mounted) return;
      _provisionToken = null; // finalized (or not provisioning) — don't abort
      if (warning != null) {
        setState(() => _completedWarning = warning);
        return; // stay open so the warning is seen; footer becomes Close
      }
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Writes a README.md into [dest] and creates the initial commit, so the
  /// new repo (and, after the push, the forge) isn't empty and the initial
  /// branch is actually born. Returns true when the commit exists; failures
  /// append to [warnings] and the repo is kept.
  Future<bool> _writeReadmeAndCommit(
    CommandExecutor executor,
    OutputLogNotifier log,
    String dest,
    List<String> warnings,
  ) async {
    final name = _name.text.trim();
    final desc = _description.text.trim();
    final content = desc.isEmpty ? '# $name\n' : '# $name\n\n$desc\n';
    try {
      await executor.uploadBytes(
        HostFsService.joinPath(dest, 'README.md'),
        Uint8List.fromList(utf8.encode(content)),
      );
      for (final argv in [
        ['git', 'add', '--', 'README.md'],
        ['git', 'commit', '-m', 'Initial commit'],
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
            'The README initial commit failed — commit manually (is '
            'user.name / user.email configured on the target?). '
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

  /// Stages and commits everything in [dest] — the existing-folder analogue
  /// of [_writeReadmeAndCommit]. Returns true when a commit was created. A
  /// clean tree ("nothing to commit") is not an error — the caller falls back
  /// to checking whether HEAD already resolves; real failures append to
  /// [warnings] and the repo is kept.
  Future<bool> _commitAllContents(
    CommandExecutor executor,
    OutputLogNotifier log,
    String dest,
    List<String> warnings,
  ) async {
    for (final argv in [
      ['git', 'add', '--all'],
      ['git', 'commit', '-m', 'Initial commit'],
    ]) {
      final result = await executor.execute(
        repoPath: dest,
        gitArgs: argv,
        lane: ExecLane.exclusive,
        retries: 0,
      );
      log.logResult(argv.join(' '), result);
      if (!result.isSuccess) {
        if ('${result.stdout}\n${result.stderr}'.contains(
          'nothing to commit',
        )) {
          return false;
        }
        warnings.add(
          'Committing the folder contents failed — commit manually (is '
          'user.name / user.email configured on the target?). '
          '(${result.stderr.trim().isEmpty ? '${argv.join(' ')} exited with code ${result.exitCode}' : result.stderr.trim()})',
        );
        return false;
      }
    }
    return true;
  }

  /// Pushes the just-created initial commit and sets its upstream — the
  /// GitLab and custom-URL counterpart of gh's `--push`. Best-effort: a
  /// failure (auth, remote not empty, …) appends to [warnings]; the local
  /// repo and its wired origin stay intact.
  Future<void> _pushInitial(
    CommandExecutor executor,
    OutputLogNotifier log,
    String dest,
    String branch,
    List<String> warnings,
  ) async {
    final label = 'git push -u origin $branch';
    try {
      final result = await executor.execute(
        repoPath: dest,
        gitArgs: ['git', 'push', '-u', 'origin', branch],
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

  /// Confirms `origin` resolves inside [dest] — `git remote get-url origin`
  /// exits 0 and prints a URL. Returns null on success, else a short
  /// human-readable failure detail. Never throws (verification must not turn
  /// a created repo into an error).
  Future<String?> _verifyOrigin(
    CommandExecutor executor,
    OutputLogNotifier log,
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
      return '$e';
    }
  }

  Future<void> _register(String dest) async {
    switch (_target) {
      case WorkspaceTarget.localMac:
        await registerAndActivateLocal(
          ref,
          dest: dest,
          label: _localLabel.text.trim(),
          save: _saveLocal,
        );
      case WorkspaceTarget.sshActive:
        await registerAndActivateSshActive(
          ref,
          dest: dest,
          fsmonitor: _fsmonitor,
        );
      case WorkspaceTarget.sshProvision:
        final conn = await _connectionById(_destConnectionId);
        final token = _provisionToken;
        if (conn != null && token != null) {
          await ref.read(connectionProvider.notifier).finalizeProvisioned(
            token: token,
            conn: conn,
            repoPath: dest,
            enableFsmonitor: _fsmonitor,
          );
        }
    }
  }

  Future<void> _requestClose() async {
    await _resetProvisioning();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickLocalParent() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final path = await getDirectoryPath(confirmButtonText: 'Choose');
      if (!mounted) return;
      if (path != null) setState(() => _pickedParent = path);
    } catch (_) {
      // No native picker (e.g. under flutter test) — leave the state as is.
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _pickLocalFolder() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final path = await getDirectoryPath(confirmButtonText: 'Choose');
      if (!mounted) return;
      if (path != null) {
        setState(() {
          _pickedFolder = path;
          _name.text = _basenameOf(path);
        });
      }
    } catch (_) {
      // No native picker (e.g. under flutter test) — leave the state as is.
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _browseRemoteFolder() async {
    if (!await _ensureProvisioned()) return;
    if (!mounted) return;
    final start = _folder.text.trim();
    final picked = await showMacosSheet<String>(
      context: context,
      builder: (_) => EscapeDismissible(
        child: RemoteDirectoryBrowserSheet(
          initialPath: start.isEmpty ? null : start,
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _folder.text = picked;
        _name.text = _basenameOf(picked);
      });
    }
  }

  Future<void> _browseRemote() async {
    if (!await _ensureProvisioned()) return;
    if (!mounted) return;
    final start = _parent.text.trim();
    final picked = await showMacosSheet<String>(
      context: context,
      builder: (_) => EscapeDismissible(
        child: RemoteDirectoryBrowserSheet(
          initialPath: start.isEmpty ? null : start,
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() => _parent.text = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return MacosSheet(
      child: SizedBox(
        width: 560,
        height: (MediaQuery.sizeOf(context).height - 60).clamp(420.0, 620.0),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const MacosIcon(
                    CupertinoIcons.plus_rectangle_on_rectangle,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text('Create repository', style: typography.title2),
                  const Spacer(),
                  ToolIconButton(
                    icon: CupertinoIcons.xmark,
                    tooltip: 'Close',
                    size: 15,
                    onPressed: _requestClose,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _stepIndicator(typography),
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(
                  child: _activeSteps[_stepIndex.clamp(
                    0,
                    _activeSteps.length - 1,
                  )].body(typography),
                ),
              ),
              const SizedBox(height: 12),
              if (_error != null) ...[
                WorkspaceBanner(_error!, error: true),
                const SizedBox(height: 10),
              ],
              if (_completedWarning != null) ...[
                WorkspaceBanner(_completedWarning!),
                const SizedBox(height: 10),
              ],
              _footer(typography),
            ],
          ),
        ),
      ),
    );
  }

  Widget _destinationSection(MacosTypography typography) {
    final conns = ref.watch(savedConnectionsProvider).value ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Destination', style: typography.caption1),
        const SizedBox(height: 4),
        MacosPopupButton<String?>(
          value: _destConnectionId,
          onChanged: _submitting ? null : _onDestChanged,
          items: [
            const MacosPopupMenuItem<String?>(
              value: null,
              child: Text('This Mac'),
            ),
            for (final c in conns)
              MacosPopupMenuItem<String?>(
                value: c.id,
                child: Text(c.displayName),
              ),
          ],
        ),
        if (_provisioning)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: ProgressCircle(radius: 6),
                ),
                const SizedBox(width: 8),
                Text('Connecting…', style: typography.caption1),
              ],
            ),
          ),
      ],
    );
  }

  Widget _sourceSection(MacosTypography typography) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Source', style: typography.caption1),
        const SizedBox(height: 4),
        Row(
          children: [
            _sourceButton('New folder', _SourceMode.newFolder),
            const SizedBox(width: 6),
            _sourceButton('Existing folder', _SourceMode.existingFolder),
          ],
        ),
      ],
    );
  }

  Widget _sourceButton(String label, _SourceMode mode) {
    final active = _source == mode;
    return PushButton(
      controlSize: ControlSize.regular,
      secondary: !active,
      onPressed: () => setState(() {
        _source = mode;
        _error = null;
      }),
      child: Text(label),
    );
  }

  /// Breadcrumb of the active steps with the current one highlighted.
  Widget _stepIndicator(MacosTypography typography) {
    final steps = _activeSteps;
    return Row(
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '›',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ),
          Text(
            steps[i].title,
            style: typography.caption1.copyWith(
              color: i == _stepIndex
                  ? MacosColors.systemBlueColor
                  : MacosColors.systemGrayColor,
              fontWeight: i == _stepIndex ? FontWeight.w600 : null,
            ),
          ),
        ],
      ],
    );
  }

  Widget _sourceStep(MacosTypography typography) {
    final existing = _source == _SourceMode.existingFolder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sourceSection(typography),
        const SizedBox(height: 14),
        if (existing)
          (_isLocalTarget
              ? _localFolderPicker(typography)
              : _sshFolderField(typography))
        else if (_isLocalTarget)
          _localParentPicker(typography)
        else
          _sshParentField(typography),
      ],
    );
  }

  Widget _detailsStep(MacosTypography typography) {
    final existing = _source == _SourceMode.existingFolder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // For an existing folder the name only names the forge project (it's
        // prefilled from the folder); without a forge there is nothing to
        // name, so the field is hidden.
        if (!existing || _onForge) ...[
          Text(
            existing ? 'Repository name (on the forge)' : 'Repository name',
            style: typography.caption1,
          ),
          const SizedBox(height: 4),
          MacosTextField(
            controller: _name,
            placeholder: 'my-project',
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
        ],
        Text(
          existing
              ? "Initial branch (used only if the folder isn't already a "
                    'repository)'
              : 'Initial branch',
          style: typography.caption1,
        ),
        const SizedBox(height: 4),
        MacosTextField(
          controller: _branch,
          placeholder: 'main',
          decoration: kAppTextFieldDecoration,
          focusedDecoration: kAppTextFieldFocusedDecoration,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        if (existing)
          _commitAllToggle()
        else
          WorkspaceToggleRow(
            on: _addReadme,
            onTap: () => setState(() => _addReadme = !_addReadme),
            onIcon: CupertinoIcons.doc_text_fill,
            offIcon: CupertinoIcons.doc_text,
            label: 'Add a README (creates the initial commit)',
          ),
        const SizedBox(height: 8),
        if (_isLocalTarget) ...[
          WorkspaceToggleRow(
            on: _saveLocal,
            onTap: () => setState(() => _saveLocal = !_saveLocal),
            onIcon: CupertinoIcons.tray_arrow_down_fill,
            offIcon: CupertinoIcons.tray_arrow_down,
            label: 'Save to Local Repositories',
          ),
          if (_saveLocal) ...[
            const SizedBox(height: 8),
            MacosTextField(
              controller: _localLabel,
              placeholder: 'Label (optional)',
              decoration: kAppTextFieldDecoration,
              focusedDecoration: kAppTextFieldFocusedDecoration,
            ),
          ],
        ] else
          WorkspaceToggleRow(
            on: _fsmonitor,
            onTap: () => setState(() => _fsmonitor = !_fsmonitor),
            onIcon: CupertinoIcons.bolt_fill,
            offIcon: CupertinoIcons.bolt,
            label: 'Enable git fsmonitor (faster status on large repos)',
          ),
      ],
    );
  }

  Widget _localFolderPicker(MacosTypography typography) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Folder on this Mac', style: typography.caption1),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                _pickedFolder ?? 'No folder chosen',
                style: typography.body.copyWith(
                  color: _pickedFolder == null
                      ? MacosColors.systemGrayColor
                      : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _picking ? null : _pickLocalFolder,
              child: const Text('Choose…'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _sshFolderField(MacosTypography typography) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Folder on the host', style: typography.caption1),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: MacosTextField(
                controller: _folder,
                placeholder: '/srv/app',
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _browseRemoteFolder,
              child: const Text('Browse…'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _commitAllToggle() {
    return WorkspaceToggleRow(
      on: _commitAll,
      onTap: () => setState(() => _commitAll = !_commitAll),
      onIcon: CupertinoIcons.doc_on_doc_fill,
      offIcon: CupertinoIcons.doc_on_doc,
      label: 'Commit all existing contents (initial commit)',
    );
  }

  Widget _localParentPicker(MacosTypography typography) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Parent folder on this Mac', style: typography.caption1),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                _pickedParent ?? 'No folder chosen',
                style: typography.body.copyWith(
                  color: _pickedParent == null
                      ? MacosColors.systemGrayColor
                      : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _picking ? null : _pickLocalParent,
              child: const Text('Choose…'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _sshParentField(MacosTypography typography) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Parent folder on the host', style: typography.caption1),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: MacosTextField(
                controller: _parent,
                placeholder: '/srv/git',
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _browseRemote,
              child: const Text('Browse…'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        WorkspaceToggleRow(
          on: _createParents,
          onTap: () => setState(() => _createParents = !_createParents),
          onIcon: CupertinoIcons.folder_badge_plus,
          offIcon: CupertinoIcons.folder,
          label: 'Create parent folders if missing',
        ),
      ],
    );
  }

  Widget _remoteSection(MacosTypography typography) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Remote', style: typography.caption1),
        const SizedBox(height: 4),
        Row(
          children: [
            _remoteButton('None', _RemoteMode.none),
            const SizedBox(width: 6),
            _remoteButton('GitHub', _RemoteMode.github),
            const SizedBox(width: 6),
            _remoteButton('GitLab', _RemoteMode.gitlab),
            const SizedBox(width: 6),
            _remoteButton('Custom URL', _RemoteMode.customUrl),
          ],
        ),
        if (_source == _SourceMode.existingFolder &&
            _remote != _RemoteMode.none) ...[
          const SizedBox(height: 8),
          WorkspaceToggleRow(
            on: _replaceOrigin,
            onTap: () => setState(() => _replaceOrigin = !_replaceOrigin),
            onIcon: CupertinoIcons.arrow_2_circlepath_circle_fill,
            offIcon: CupertinoIcons.arrow_2_circlepath_circle,
            label: 'Replace existing origin remote (if any)',
          ),
        ],
        if (_remote == _RemoteMode.customUrl) ...[
          const SizedBox(height: 8),
          Text(
            'Existing remote to wire as origin',
            style: typography.caption1,
          ),
          const SizedBox(height: 4),
          MacosTextField(
            controller: _remoteUrl,
            placeholder: 'git@host:owner/repo.git or https://…',
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
            onChanged: (_) => setState(() {}),
          ),
        ],
        if (_onForge) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              MacosPopupButton<bool>(
                value: _private,
                onChanged: (v) => setState(() => _private = v ?? true),
                items: const [
                  MacosPopupMenuItem<bool>(
                    value: true,
                    child: Text('Private'),
                  ),
                  MacosPopupMenuItem<bool>(value: false, child: Text('Public')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          MacosTextField(
            controller: _host,
            placeholder: _defaultHost,
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
          ),
          const SizedBox(height: 8),
          MacosTextField(
            controller: _description,
            placeholder: 'Description (optional)',
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
          ),
        ],
      ],
    );
  }

  Widget _remoteButton(String label, _RemoteMode mode) {
    final active = _remote == mode;
    return PushButton(
      controlSize: ControlSize.regular,
      secondary: !active,
      onPressed: () => setState(() {
        _remote = mode;
        final h = _host.text.trim();
        if (h.isEmpty || h == 'github.com' || h == 'gitlab.com') {
          _host.text = _defaultHost;
        }
      }),
      child: Text(label),
    );
  }

  /// Everything the wizard collected, as label/value rows — what Create will
  /// actually do, derived live from the same state the steps edited.
  Widget _reviewStep(MacosTypography typography) {
    final existing = _source == _SourceMode.existingFolder;
    final host = _host.text.trim().isEmpty ? _defaultHost : _host.text.trim();
    final destText = switch (_target) {
      WorkspaceTarget.localMac => 'This Mac',
      WorkspaceTarget.sshActive => 'Connected host (active session)',
      WorkspaceTarget.sshProvision => () {
        final conns = ref.watch(savedConnectionsProvider).value ?? const [];
        for (final c in conns) {
          if (c.id == _destConnectionId) return c.displayName;
        }
        return 'Saved connection';
      }(),
    };
    final sourceText = existing
        ? (_isLocalTarget ? (_pickedFolder ?? '—') : _folder.text.trim())
        : '${_name.text.trim()} in '
              '${_isLocalTarget ? (_pickedParent ?? '—') : _parent.text.trim()}';
    final visibility = _private ? 'private' : 'public';
    final remoteText = switch (_remote) {
      _RemoteMode.none => 'None — no origin remote',
      _RemoteMode.github => 'GitHub ($host) — $visibility',
      _RemoteMode.gitlab => 'GitLab ($host) — $visibility',
      _RemoteMode.customUrl => _remoteUrl.text.trim(),
    };
    final options = <String>[
      if (!existing && _addReadme) 'Add a README (initial commit)',
      if (existing && _commitAll) 'Commit all existing contents',
      if (existing && _replaceOrigin && _remote != _RemoteMode.none)
        'Replace existing origin remote',
      if (!_isLocalTarget && !existing && _createParents)
        'Create parent folders if missing',
      if (!_isLocalTarget && _fsmonitor) 'Enable git fsmonitor',
      if (_isLocalTarget && _saveLocal) 'Save to Local Repositories',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _reviewRow(typography, 'Destination', destText),
        _reviewRow(
          typography,
          existing ? 'Existing folder' : 'New folder',
          sourceText,
        ),
        _reviewRow(typography, 'Initial branch', _branch.text.trim()),
        _reviewRow(typography, 'Remote', remoteText),
        if (options.isNotEmpty)
          _reviewRow(typography, 'Options', options.join('\n')),
      ],
    );
  }

  Widget _reviewRow(MacosTypography typography, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
          Expanded(child: Text(value, style: typography.body)),
        ],
      ),
    );
  }

  Widget _footer(MacosTypography typography) {
    if (_completedWarning != null) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          PushButton(
            controlSize: ControlSize.large,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }
    final steps = _activeSteps;
    final last = _stepIndex >= steps.length - 1;
    return Row(
      children: [
        if (_submitting)
          Expanded(
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: ProgressCircle(radius: 7),
                ),
                const SizedBox(width: 8),
                Text('Creating…', style: typography.caption1),
              ],
            ),
          )
        else
          const Spacer(),
        const SizedBox(width: 12),
        PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: _submitting ? null : _requestClose,
          child: const Text('Cancel'),
        ),
        if (_stepIndex > 0) ...[
          const SizedBox(width: 8),
          PushButton(
            controlSize: ControlSize.large,
            secondary: true,
            onPressed: _submitting ? null : _goBack,
            child: const Text('Back'),
          ),
        ],
        const SizedBox(width: 8),
        if (last)
          PushButton(
            controlSize: ControlSize.large,
            onPressed: _canSubmit ? _submit : null,
            child: const Text('Create'),
          )
        else
          PushButton(
            controlSize: ControlSize.large,
            onPressed: !_submitting && steps[_stepIndex].valid()
                ? _goNext
                : null,
            child: const Text('Continue'),
          ),
      ],
    );
  }

  static String _dirOf(String path) {
    var end = path.length;
    while (end > 0 && path[end - 1] == '/') {
      end--;
    }
    final trimmed = path.substring(0, end);
    final slash = trimmed.lastIndexOf('/');
    if (slash <= 0) return '/';
    return trimmed.substring(0, slash);
  }

  static String _basenameOf(String path) {
    final trimmed = _stripTrailingSlashes(path);
    final slash = trimmed.lastIndexOf('/');
    return slash < 0 ? trimmed : trimmed.substring(slash + 1);
  }

  static String _stripTrailingSlashes(String path) {
    var end = path.length;
    while (end > 1 && path[end - 1] == '/') {
      end--;
    }
    return path.substring(0, end);
  }
}
