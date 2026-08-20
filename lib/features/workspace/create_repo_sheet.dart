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
import '../../core/utils/display_error.dart';
import '../common/buttons.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';
import 'remote_directory_browser.dart';
import 'wizard.dart';
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
///  * GitHub     — API-only `gh repo create <name>` (no `--source`/`--remote`/
///    `--push`), then Magic Git wires `origin` via
///    [GhService.resolveOriginUrl] (the create's own printed URL first, API
///    lookup as fallback) and pushes with PATH-hardened `git` when a commit
///    exists. HTTPS pushes authenticate via `gh auth git-credential` for that
///    one command (see [forgeGitAuthConfigArgs]) — plain `git` does not use
///    the `gh` store on its own.
///  * GitLab     — API-only `glab repo create <name> --skipGitInit`, then the
///    same hardened origin + push ownership as GitHub via
///    [GlabService.resolveOriginUrl] (with `glab auth git-credential` for
///    HTTPS).
///  * Custom URL — `git remote add origin &lt;url&gt;` (no forge CLI — for
///    repos already created on a web UI, bare repos on an SSH host, or any
///    other pre-existing remote), then `git push -u` when a commit exists
///    (host credentials as-is).
///
/// Once `git init` has succeeded, the repo is always kept and registered: a
/// failure in any later step (commit, forge publish, push, verification)
/// keeps the sheet open with a warning instead — never deleted over a remote
/// hiccup. Every mode that promises a remote is verified after the fact:
/// `git remote get-url origin` must print a URL from inside the new repo.
/// Forge origin ensure runs even when create exits non-zero (partial success:
/// project may exist on the forge while local `origin` was never set).
class CreateRepositorySheet extends ConsumerStatefulWidget {
  final bool landing;
  const CreateRepositorySheet.connected({super.key}) : landing = false;
  const CreateRepositorySheet.landing({super.key}) : landing = true;

  /// How long the finished (green) progress bar stays visible before the
  /// sheet pops on success. Overridable so tests don't wait it out.
  @visibleForTesting
  static Duration successPopDelay = const Duration(milliseconds: 600);

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

  /// True once the user has typed a (non-empty) host themselves. The prefill
  /// and the submit-time host resolution only ever touch an *un-edited* field
  /// — inferring "still the default" from the field's value can't distinguish
  /// a deliberately typed `github.com`/`gitlab.com` from the stock text, and
  /// silently redirecting a typed host to the CLI's enterprise instance would
  /// publish to a destination the Review step never showed. Clearing the
  /// field hands control back to the prefill.
  bool _hostEdited = false;

  // Existing-folder source options.
  final _folder = TextEditingController();
  String? _pickedFolder;
  bool _commitAll = false;
  bool _replaceOrigin = false;

  // SSH destination options.
  bool _createParents = false;
  bool _fsmonitor = false;
  final _remoteLabel = TextEditingController();

  // Local destination options.
  String? _pickedParent;
  bool _saveLocal = true;
  final _localLabel = TextEditingController();
  bool _picking = false;

  // Landing destination selection: null id = "This Mac", else a connection id.
  String? _destConnectionId;

  bool _submitting = false;
  String? _error;

  /// Set once the repo was created and registered cleanly — the bottom
  /// progress bar turns green for [CreateRepositorySheet.successPopDelay]
  /// before the sheet pops.
  bool _finished = false;

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
  late final List<WizardStep> _steps = [
    WizardStep(
      id: 'destination',
      title: 'Destination',
      intro:
          'Choose where the repository will live: on this Mac, or on one of '
          'your saved SSH hosts. Picking a host connects to it on demand — '
          'the repository stays on the host, nothing is copied to this Mac.',
      applicable: () => widget.landing,
      valid: () => !_provisioning,
      body: _destinationSection,
    ),
    WizardStep(
      id: 'source',
      title: 'Source',
      intro:
          'Start from a brand-new empty folder, or turn a folder you '
          'already have into a repository, in place, keeping its contents.',
      valid: _sourceValid,
      body: _sourceStep,
    ),
    WizardStep(
      id: 'remote',
      title: 'Remote',
      intro:
          'Decide what the repository\'s "origin" remote points at. GitHub '
          'and GitLab also create the project on the forge for you; Custom '
          'URL connects a remote that already exists; None sets up no '
          'remote at all.',
      valid: _remoteValid,
      body: _remoteSection,
    ),
    WizardStep(
      id: 'details',
      title: 'Details',
      intro:
          'Name the repository, choose its initial branch, and pick the '
          'first-commit and workspace options.',
      valid: _detailsValid,
      body: _detailsStep,
    ),
    WizardStep(
      id: 'review',
      title: 'Review',
      intro:
          'Nothing has been created yet — check the summary below, then '
          'press Create to run these steps. If anything goes wrong along '
          'the way, the repository is kept and the failing step is '
          'reported here.',
      valid: WizardStep.always,
      body: _reviewStep,
    ),
  ];
  int _stepIndex = 0;

  List<WizardStep> get _activeSteps => [
    for (final s in _steps)
      if (s.applicable()) s,
  ];

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
    // A barrier-dismiss / route teardown skips _requestClose — hang up any
    // still-provisioned session instead of leaking it (0009 M29; same
    // fire-and-forget pattern as AddExistingRepoSheet's dispose).
    _resetProvisioning();
    _unregisterEscape?.call();
    _name.dispose();
    _branch.dispose();
    _parent.dispose();
    _host.dispose();
    _description.dispose();
    _remoteUrl.dispose();
    _folder.dispose();
    _localLabel.dispose();
    _remoteLabel.dispose();
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
    if (!mounted) {
      // Torn down while dialing — hang up rather than leak the session
      // (0009 M29); the token was never stored, so dispose can't reach it.
      if (token != null) {
        ref.read(connectionProvider.notifier).abortProvisioning(token).ignore();
      }
      return false;
    }
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
    if (_submitting || _finished || _completedWarning != null) return false;
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
      var host = _host.text.trim().isEmpty ? _defaultHost : _host.text.trim();

      // For a This-Mac forge create, check the Mac's gh/glab sign-in and fail
      // fast when it's definitively unusable (signed out, expired token) —
      // otherwise the forge `repo create` fails with a cryptic 401 after a
      // local repo was already created. Goes through [forgeAuthProvider]: the
      // same strict judgment (an expired token does NOT pass) and the same
      // cached probe the host prefill already ran, logged to the output log.
      // An SSH target instead relies on ensureForgeHostLogin below, which
      // pushes the connection's token before the remote CLI is queried.
      if (_onForge && _isLocalTarget) {
        final auth = await ref.read(forgeAuthProvider((_forge, true)).future);
        if (!mounted) return;
        if (!auth.authenticated && !auth.checkFailed) {
          // Definitive: signed out, expired, or the CLI is missing. (A check
          // that merely timed out proceeds best-effort — blocking a create on
          // a slow probe would be worse than the failure it guards against.)
          setState(() => _error = auth.detail);
          return;
        }
        // Trust the real signed-in host over a default the user never
        // touched; a host the user typed themselves is used verbatim — the
        // Review step displayed it, so it must never be silently replaced.
        if (!_hostEdited && auth.authenticated && auth.host != null) {
          host = auth.host!;
          _host.text = auth.host!;
        }
      }

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
      // Forge modes: API-only create, then ALWAYS ensure origin (even when
      // create exits non-zero — the project may already exist on the forge).
      switch (_remote) {
        case _RemoteMode.none:
          break;
        case _RemoteMode.github:
          final label = 'gh repo create $name';
          final gh = GhService(executor);
          SSHCommandResult? created;
          String? createFailure;
          try {
            created = await gh.createRepoInExisting(
              repoPath: dest,
              name: name,
              private: _private,
              description: _description.text.trim(),
              host: host,
            );
            log.logResult(label, created);
          } on GhException catch (e) {
            log.logResult(label, e.result);
            createFailure = e.result.stderr.trim().isEmpty
                ? displayError(e)
                : e.result.stderr.trim();
          }
          // Always attempt origin wiring — partial create success is common.
          // The create's own output is the primary URL source (gh prints the
          // new repo's URL); the API lookup chain is the fallback.
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
              name: name,
              host: host,
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
        case _RemoteMode.gitlab:
          final label = 'glab repo create $name';
          final glab = GlabService(executor);
          SSHCommandResult? created;
          String? createFailure;
          try {
            created = await glab.createRepoInExisting(
              repoPath: dest,
              name: name,
              private: _private,
              description: _description.text.trim(),
              host: host,
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
              name: name,
              host: host,
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
      // Every mode that promised an origin must show one. Forge modes already
      // ran _ensureForgeOrigin; this catch-all covers custom-URL and any
      // forge edge case that left origin unset without a prior warning.
      if (_remote != _RemoteMode.none) {
        final failure = await _verifyOrigin(executor, log, dest);
        if (!mounted) return;
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
      final warning = warnings.isEmpty ? null : warnings.join('\n\n');

      // --- Register + activate (shared matrix) --------------------------
      final registered = await _register(dest);
      if (!mounted) return;
      if (!registered) {
        // Created on disk/forge but never became the live workspace — the
        // green Complete state would be a lie (0009 H19). Provisioning (if
        // any) stays alive for a retry.
        setState(() {
          _error = 'The repository was created but could not be opened.';
        });
        return;
      }
      _provisionToken = null; // finalized (or not provisioning) — don't abort
      if (warning != null) {
        setState(() => _completedWarning = warning);
        return; // stay open so the warning is seen; footer becomes Close
      }
      // Let the finished (green) progress bar register before the sheet
      // pops — success otherwise vanishes the very frame it happens.
      setState(() => _finished = true);
      await Future<void>.delayed(CreateRepositorySheet.successPopDelay);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = displayError(e));
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

  /// Pushes the initial commit and sets upstream with PATH-hardened `git`.
  /// When [forge] is GitHub/GitLab, HTTPS auth rides that CLI's credential
  /// helper for this one command (see [forgeGitAuthConfigArgs]) — matching
  /// the store that just created the project. Best-effort: failures append
  /// to [warnings]; local repo + origin stay.
  Future<void> _pushInitial(
    CommandExecutor executor,
    OutputLogNotifier log,
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

  /// Guarantees a usable `origin` in [dest] after a forge create attempt,
  /// using PATH-hardened `git` only — never forge-nested git. Always owns
  /// push when [hasCommit]. Idempotent and best-effort:
  ///  * origin already resolves → push if needed
  ///  * origin missing → [lookupUrl] + `git remote add origin`, then push
  /// Returns whether origin is present after this call. A failed resolution
  /// carries its diagnostic trail ([OriginUrlResolution.detail]) into both
  /// the warning banner and the output log, so a live failure names its
  /// cause instead of a bare "could not be determined".
  Future<bool> _ensureForgeOrigin(
    CommandExecutor executor,
    OutputLogNotifier log,
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
      return displayError(e);
    }
  }

  /// Returns whether the new repo actually became the live workspace
  /// (0009 H19) — a silent failure must not paint the green Complete state.
  Future<bool> _register(String dest) async {
    switch (_target) {
      case WorkspaceTarget.localMac:
        return registerAndActivateLocal(
          ref,
          dest: dest,
          label: _localLabel.text.trim(),
          save: _saveLocal,
        );
      case WorkspaceTarget.sshActive:
        return registerAndActivateSshActive(
          ref,
          dest: dest,
          fsmonitor: _fsmonitor,
          label: _remoteLabel.text.trim(),
        );
      case WorkspaceTarget.sshProvision:
        final conn = await _connectionById(_destConnectionId);
        final token = _provisionToken;
        if (conn == null || token == null) return false;
        return ref
            .read(connectionProvider.notifier)
            .finalizeProvisioned(
              token: token,
              conn: conn,
              repoPath: dest,
              enableFsmonitor: _fsmonitor,
              label: _remoteLabel.text.trim(),
            );
    }
  }

  Future<void> _requestClose() async {
    // Escape / title-X while `git init` / forge publish is running must not
    // tear the SSH session down under the in-flight command — the footer
    // Cancel is already disabled for the same reason (0009 H20).
    if (_submitting) return;
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
    if (_onForge) {
      // Prefill the host with the instance the target's gh/glab is actually
      // signed in to (e.g. a self-hosted GitLab) the moment it resolves —
      // but never overwrite a host the user typed themselves. Registered
      // here (not in the step body) because ref.listen must run in this
      // ConsumerState's own build, and resolving as soon as a forge is
      // chosen means the field is ready before the user reaches the step.
      ref.listen(forgeAuthHostProvider((_forge, _isLocalTarget)), (
        previous,
        next,
      ) {
        final host = next.value;
        if (host != null && host.isNotEmpty && !_hostEdited) {
          setState(() => _host.text = host);
        }
      });
    }
    return SizedSheet(
      width: kSheetWidth,
      // Narrower sheet + per-step guidance text → a little more vertical
      // room; each step scrolls when it doesn't fit.
      height: (MediaQuery.sizeOf(context).height - 60).clamp(460.0, 680.0),
      child: SizedBox(
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
              WizardStepIndicator(steps: _activeSteps, current: _stepIndex),
              const SizedBox(height: 14),
              Expanded(
                child: Builder(
                  builder: (context) {
                    final step =
                        _activeSteps[_stepIndex.clamp(
                          0,
                          _activeSteps.length - 1,
                        )];
                    return SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          WizardStepIntro(step.intro),
                          const SizedBox(height: 14),
                          step.body(typography),
                        ],
                      ),
                    );
                  },
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
              WizardProgressBar(
                steps: _activeSteps,
                current: _stepIndex.clamp(0, _activeSteps.length - 1),
                complete: _finished || _completedWarning != null,
              ),
              const SizedBox(height: 10),
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
        WizardHint(
          _destConnectionId == null
              ? 'The repository is created on this Mac\'s own filesystem.'
              : 'The repository is created on the selected host over SSH.',
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
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _sourceButton('New folder', _SourceMode.newFolder),
            _sourceButton('Existing folder', _SourceMode.existingFolder),
          ],
        ),
        WizardHint(
          _source == _SourceMode.newFolder
              ? 'A new, empty folder is created inside the parent folder '
                    'you choose below.'
              : 'The folder you pick becomes the repository, in place. If '
                    'it already is one, it is published as-is.',
        ),
      ],
    );
  }

  Widget _sourceButton(String label, _SourceMode mode) {
    final active = _source == mode;
    return AppPushButton(
      controlSize: ControlSize.regular,
      secondary: !active,
      onPressed: () => setState(() {
        _source = mode;
        _error = null;
      }),
      child: Text(label),
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
            placeholderStyle: kAppPlaceholderStyle,
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
            onChanged: (_) => setState(() {}),
          ),
          WizardHint(
            existing
                ? 'Names the project created on the forge — prefilled from '
                      'the folder when picked with Browse/Choose.'
                : 'Also the name of the folder created inside the parent. '
                      'Letters, digits, dot, dash and underscore.',
          ),
          const SizedBox(height: 10),
        ],
        Text('Initial branch', style: typography.caption1),
        const SizedBox(height: 4),
        MacosTextField(
          controller: _branch,
          placeholder: 'main',
          placeholderStyle: kAppPlaceholderStyle,
          decoration: kAppTextFieldDecoration,
          focusedDecoration: kAppTextFieldFocusedDecoration,
          onChanged: (_) => setState(() {}),
        ),
        WizardHint(
          existing
              ? 'Used only if the folder isn\'t already a repository — an '
                    'existing repository keeps its current branch.'
              : 'The branch the repository starts on — "main" is the '
                    'common default.',
        ),
        const SizedBox(height: 10),
        if (existing) ...[
          _commitAllToggle(),
          const WizardHint(
            'Stages and commits everything already in the folder, and '
            'pushes it when a remote is set up. Leave off to commit '
            'manually later.',
          ),
        ] else ...[
          WorkspaceToggleRow(
            on: _addReadme,
            onTap: () => setState(() => _addReadme = !_addReadme),
            onIcon: CupertinoIcons.doc_text_fill,
            offIcon: CupertinoIcons.doc_text,
            label: 'Add a README (creates the initial commit)',
          ),
          const WizardHint(
            'Writes a README.md, commits it, and pushes it when a remote '
            'is set up — so the repository (and the forge) isn\'t empty.',
          ),
        ],
        const SizedBox(height: 8),
        if (_isLocalTarget) ...[
          WorkspaceToggleRow(
            on: _saveLocal,
            onTap: () => setState(() => _saveLocal = !_saveLocal),
            onIcon: CupertinoIcons.tray_arrow_down_fill,
            offIcon: CupertinoIcons.tray_arrow_down,
            label: 'Save to Local Repositories',
          ),
          const WizardHint(
            'Remembers this repository so it appears in the Connections '
            'list for quick reopening.',
          ),
          if (_saveLocal) ...[
            const SizedBox(height: 8),
            MacosTextField(
              controller: _localLabel,
              placeholder: 'Label (optional)',
              placeholderStyle: kAppPlaceholderStyle,
              decoration: kAppTextFieldDecoration,
              focusedDecoration: kAppTextFieldFocusedDecoration,
            ),
            const WizardHint(
              'Display name in the Connections list — defaults to the '
              'folder name.',
            ),
          ],
        ] else ...[
          WorkspaceToggleRow(
            on: _fsmonitor,
            onTap: () => setState(() => _fsmonitor = !_fsmonitor),
            onIcon: CupertinoIcons.bolt_fill,
            offIcon: CupertinoIcons.bolt,
            label: 'Enable git fsmonitor (faster status on large repos)',
          ),
          const WizardHint(
            'Turns on git\'s filesystem monitor daemon in the new '
            'repository — speeds up status on big working trees.',
          ),
          const SizedBox(height: 8),
          MacosTextField(
            controller: _remoteLabel,
            placeholder: 'Label (optional)',
            placeholderStyle: kAppPlaceholderStyle,
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
          ),
          const WizardHint(
            'Display name in the Connections list — defaults to '
            'the folder name.',
          ),
        ],
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
            AppPushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _picking ? null : _pickLocalFolder,
              child: const Text('Choose…'),
            ),
          ],
        ),
        const WizardHint(
          'If this folder is not yet a Git repository it is initialized in '
          'place; a folder nested in another repository is refused.',
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
                placeholderStyle: kAppPlaceholderStyle,
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            AppPushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _browseRemoteFolder,
              child: const Text('Browse…'),
            ),
          ],
        ),
        const WizardHint(
          'Absolute path on the host. If the folder is not yet a Git '
          'repository it is initialized in place; a folder nested in '
          'another repository is refused.',
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
            AppPushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _picking ? null : _pickLocalParent,
              child: const Text('Choose…'),
            ),
          ],
        ),
        const WizardHint(
          'The new repository folder (named on the Details step) is '
          'created inside this folder.',
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
                placeholderStyle: kAppPlaceholderStyle,
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            AppPushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _browseRemote,
              child: const Text('Browse…'),
            ),
          ],
        ),
        const WizardHint(
          'Absolute path on the host (e.g. /srv/git). The new repository '
          'folder is created inside it.',
        ),
        const SizedBox(height: 10),
        WorkspaceToggleRow(
          on: _createParents,
          onTap: () => setState(() => _createParents = !_createParents),
          onIcon: CupertinoIcons.folder_badge_plus,
          offIcon: CupertinoIcons.folder,
          label: 'Create parent folders if missing',
        ),
        const WizardHint(
          'When off, a missing parent folder stops the create instead of '
          'being silently created.',
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
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _remoteButton('None', _RemoteMode.none),
            _remoteButton('GitHub', _RemoteMode.github),
            _remoteButton('GitLab', _RemoteMode.gitlab),
            _remoteButton('Custom URL', _RemoteMode.customUrl),
          ],
        ),
        WizardHint(switch (_remote) {
          _RemoteMode.none =>
            'No remote is set up — you can add one later from the command '
                'line or by re-publishing.',
          _RemoteMode.github =>
            'Creates the project on GitHub with the gh CLI (it must be '
                'installed and signed in on the target machine) and wires '
                'it as "origin".',
          _RemoteMode.gitlab =>
            'Creates the project on GitLab with the glab CLI (it must be '
                'installed and signed in on the target machine) and wires '
                'it as "origin".',
          _RemoteMode.customUrl =>
            'Points "origin" at a remote that already exists — created on '
                'a web UI, a bare repo on a server, or any other Git URL. '
                'No forge CLI needed.',
        }),
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
          const WizardHint(
            'When off, a folder whose repository already points at an '
            'origin is left untouched and the create stops safely.',
          ),
        ],
        if (_remote == _RemoteMode.customUrl) ...[
          const SizedBox(height: 8),
          Text('Existing remote to wire as origin', style: typography.caption1),
          const SizedBox(height: 4),
          MacosTextField(
            controller: _remoteUrl,
            placeholder: 'git@host:owner/repo.git or https://…',
            placeholderStyle: kAppPlaceholderStyle,
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
            onChanged: (_) => setState(() {}),
          ),
          const WizardHint(
            'SSH (git@host:owner/repo.git) or HTTPS '
            '(https://host/owner/repo.git). The remote itself is not '
            'created — it must already exist.',
          ),
        ],
        if (_onForge) ...[
          const SizedBox(height: 10),
          Text('Visibility', style: typography.caption1),
          const SizedBox(height: 4),
          Row(
            children: [
              MacosPopupButton<bool>(
                value: _private,
                onChanged: (v) => setState(() => _private = v ?? true),
                items: const [
                  MacosPopupMenuItem<bool>(value: true, child: Text('Private')),
                  MacosPopupMenuItem<bool>(value: false, child: Text('Public')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Forge host', style: typography.caption1),
          const SizedBox(height: 4),
          MacosTextField(
            controller: _host,
            placeholder: _defaultHost,
            placeholderStyle: kAppPlaceholderStyle,
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
            // An empty field hands control back to the prefill; anything
            // typed pins the host (see _hostEdited).
            onChanged: (v) => setState(() => _hostEdited = v.trim().isNotEmpty),
          ),
          const WizardHint(
            'Prefilled with the instance the CLI is signed in to on the '
            'target — type a different host to publish there instead (the '
            'CLI must be signed in there too). Clear the field to go back '
            'to the signed-in host.',
          ),
          const SizedBox(height: 8),
          Text('Project description', style: typography.caption1),
          const SizedBox(height: 4),
          MacosTextField(
            controller: _description,
            placeholder: 'Description (optional)',
            placeholderStyle: kAppPlaceholderStyle,
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
          ),
          const WizardHint(
            'Shown on the forge project page (and used in the generated '
            'README when one is added).',
          ),
        ],
      ],
    );
  }

  Widget _remoteButton(String label, _RemoteMode mode) {
    final active = _remote == mode;
    return AppPushButton(
      controlSize: ControlSize.regular,
      secondary: !active,
      onPressed: () => setState(() {
        _remote = mode;
        // Switching forges resets an untouched host to the new forge's
        // default (the prefill listener then fills in the signed-in host);
        // a user-typed host is kept.
        if (!_hostEdited) {
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
        if (!_isLocalTarget && _remoteLabel.text.trim().isNotEmpty)
          _reviewRow(typography, 'Label', _remoteLabel.text.trim()),
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
          AppPushButton(
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
        AppPushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: _submitting ? null : _requestClose,
          child: const Text('Cancel'),
        ),
        if (_stepIndex > 0) ...[
          const SizedBox(width: 8),
          AppPushButton(
            controlSize: ControlSize.large,
            secondary: true,
            onPressed: _submitting ? null : _goBack,
            child: const Text('Back'),
          ),
        ],
        const SizedBox(width: 8),
        if (last)
          AppPushButton(
            controlSize: ControlSize.large,
            onPressed: _canSubmit ? _submit : null,
            child: const Text('Create'),
          )
        else
          AppPushButton(
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
