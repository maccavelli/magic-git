import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/forge.dart';
import '../../core/git/host_fs_service.dart';
import '../../core/github/gh_service.dart';
import '../../core/gitlab/glab_service.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/ssh/ssh_command_executor.dart';
import '../../core/utils/display_error.dart';
import '../../core/utils/posix_path.dart';
import '../common/buttons.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/labeled_text_field.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';
import 'create_repo_pipeline.dart';
import 'create_repo_steps/folder_fields.dart';
import 'create_repo_steps/namespace_field.dart';
import 'create_repo_steps/segmented_choice.dart';
import 'wizard.dart';
import 'workspace_destination.dart';
import 'workspace_pickers.dart';
import 'workspace_provisioning.dart';
import 'workspace_registration.dart';
import 'workspace_targets.dart';
import 'workspace_widgets.dart';

/// What `origin` should point at when the repo is created — a first-class,
/// always-visible choice (not an opt-in extra), because a repo without a
/// remote is rarely what the user wants.
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
/// writing local `user.name` / `user.email` when the wizard collected a git
/// identity (required for an initial commit; otherwise optional, prefilled
/// from Settings), an optional README + initial commit authored with that
/// identity (`-c user.name/-c user.email` and `--no-gpg-sign`, matching
/// every other Magic Git commit), then mode-specific origin wiring:
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

class _CreateRepositorySheetState extends ConsumerState<CreateRepositorySheet>
    with WorkspaceProvisioning<CreateRepositorySheet> {
  final _name = TextEditingController();
  final _namespace = TextEditingController();
  final _branch = TextEditingController(text: 'main');
  final _parent = TextEditingController();
  final _host = TextEditingController(text: 'github.com');
  final _description = TextEditingController();
  final _remoteUrl = TextEditingController();
  final _authorName = TextEditingController();
  final _authorEmail = TextEditingController();

  CreateRemoteMode _remote = CreateRemoteMode.none;
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

  /// True once the user has typed in that identity field. Prefill from
  /// Settings only ever fills an un-edited field — a value they cleared
  /// or replaced must not snap back when Settings finishes loading.
  bool _authorNameEdited = false;
  bool _authorEmailEdited = false;

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

  // Provisioning state lives in WorkspaceProvisioning.

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
      valid: () => !provisioning,
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
          'Name the repository, choose its initial branch, set the git '
          'identity for commits in this repository, and pick the '
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
      _remote != CreateRemoteMode.customUrl ||
      _remoteUrl.text.trim().isNotEmpty;

  bool _detailsValid() {
    if (_branch.text.trim().isEmpty) return false;
    final needName = _source == _SourceMode.newFolder || _onForge;
    if (needName && !HostFsService.isValidRepoDirName(_name.text.trim())) {
      return false;
    }
    // The namespace is the only field that may contain `/`. The name stays a
    // single segment in both modes — in newFolder mode it is also the
    // directory name, and on the forge it is the project's last segment.
    if (_onForge && !_isValidNamespace(_namespaceText)) return false;
    // An initial commit (README or commit-all) needs a real identity —
    // git refuses `commit` without user.name / user.email, and that used
    // to leave the forge project created with nothing to push.
    if (_needsIdentity && !_identityValid) return false;
    return true;
  }

  String get _namespaceText => _namespace.text.trim();

  /// The forge path a create should use: `namespace/name`, or just `name`
  /// when no namespace was given (the account's default — today's behaviour).
  ///
  /// Passed as the CLI's **positional argument**, never as `--group`. Both
  /// `glab repo create foo --group team/sub` and the positional
  /// `team/sub/foo` create the same project, but only the positional form is
  /// what [GlabService.resolveOriginUrl] then looks up: given a bare `foo` it
  /// searches `<login>/foo`, misses, and reports "origin could not be
  /// determined" for a project that was created correctly (MADR 0031).
  String get _forgePath {
    final ns = _namespaceText;
    final name = _name.text.trim();
    return ns.isEmpty ? name : '$ns/$name';
  }

  /// An empty namespace is legal and means "my default namespace".
  static bool _isValidNamespace(String ns) {
    if (ns.isEmpty) return true;
    if (ns != ns.trim()) return false;
    if (ns.startsWith('/') || ns.endsWith('/')) return false;
    if (ns.contains(RegExp(r'\s'))) return false;
    return ns
        .split('/')
        .every((seg) => seg.isNotEmpty && seg != '.' && seg != '..');
  }

  bool get _needsIdentity => _addReadme || _commitAll;

  String get _authorNameText => _authorName.text.trim();

  String get _authorEmailText => _authorEmail.text.trim();

  bool get _identityValid =>
      _authorNameText.isNotEmpty && _looksLikeEmail(_authorEmailText);

  /// Git is lenient, but it does require an `@` with something on both
  /// sides. Spaces never appear in a usable email.
  static bool _looksLikeEmail(String email) {
    final at = email.indexOf('@');
    return at > 0 && at < email.length - 1 && !email.contains(' ');
  }

  /// `-c user.name=… -c user.email=…` for the initial commit, so it is
  /// authored even if writing the local config failed.
  void _goBack() {
    if (_stepIndex == 0 || _submitting || _finished) return;
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
    _applyIdentityPrefill(ref.read(appSettingsProvider));
  }

  /// Copies non-empty Settings identity into un-edited fields. Empty
  /// Settings values are ignored — empty there is intentional and must
  /// not wipe a typed (or still-empty) field. Returns whether a
  /// controller changed, so a listener can `setState`.
  bool _applyIdentityPrefill(AppSettings settings) {
    var changed = false;
    final name = settings.committerName.trim();
    final email = settings.committerEmail.trim();
    if (!_authorNameEdited && name.isNotEmpty && _authorName.text != name) {
      _authorName.text = name;
      changed = true;
    }
    if (!_authorEmailEdited && email.isNotEmpty && _authorEmail.text != email) {
      _authorEmail.text = email;
      changed = true;
    }
    return changed;
  }

  @override
  void dispose() {
    // A barrier-dismiss / route teardown skips _requestClose — hang up any
    // still-provisioned session instead of leaking it (0009 M29; same
    // fire-and-forget pattern as AddExistingRepoSheet's dispose).
    resetProvisioning();
    _unregisterEscape?.call();
    _name.dispose();
    _namespace.dispose();
    _branch.dispose();
    _parent.dispose();
    _host.dispose();
    _description.dispose();
    _remoteUrl.dispose();
    _authorName.dispose();
    _authorEmail.dispose();
    _folder.dispose();
    _localLabel.dispose();
    _remoteLabel.dispose();
    super.dispose();
  }

  void _recomputeTarget() {
    final conn = ref.read(connectionProvider);
    final WorkspaceTarget target;
    if (!widget.landing) {
      target = conn.isLocal
          ? WorkspaceTarget.localMac
          : WorkspaceTarget.sshActive;
      if (target == WorkspaceTarget.sshActive &&
          _parent.text.isEmpty &&
          conn.repoPath != null) {
        _parent.text = dirname(conn.repoPath!);
      }
    } else {
      target = _destConnectionId == null
          ? WorkspaceTarget.localMac
          : WorkspaceTarget.sshProvision;
    }
    _target = target;
  }

  bool get _isLocalTarget => _target == WorkspaceTarget.localMac;

  @override
  String? get destConnectionId => _destConnectionId;

  @override
  bool get needsProvisioning => _target == WorkspaceTarget.sshProvision;

  @override
  void onProvisioningError(String? message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  bool get _onForge =>
      _remote == CreateRemoteMode.github || _remote == CreateRemoteMode.gitlab;

  Forge get _forge =>
      _remote == CreateRemoteMode.gitlab ? Forge.gitlab : Forge.github;

  String get _defaultHost =>
      _remote == CreateRemoteMode.gitlab ? 'gitlab.com' : 'github.com';

  Future<void> _onDestChanged(String? connectionId) async {
    // Switching destination abandons any in-flight provisioning.
    await resetProvisioning();
    // The hang-up above is a real network round trip once a session has been
    // adopted, and the sheet can be dismissed inside that window (MADR 0034
    // F4) — so `mounted` is re-checked on THIS side of the await, not only
    // before it.
    if (!mounted) return;
    setState(() {
      _destConnectionId = connectionId;
      _error = null;
      _recomputeTarget();
    });
    if (_target == WorkspaceTarget.sshProvision) {
      await ensureProvisioned();
    }
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
      if (!await ensureProvisioned()) return;
      if (_isLocalTarget) {
        // Outside a local session (landing → This Mac) the local executor has
        // never been environment-probed; without this, gh/glab in a Homebrew
        // bin dir are invisible to the GUI app's inherited PATH.
        await ref.read(localEnvironmentProvider).ensure();
        if (!mounted) return;
      }

      final resolved = await _resolveForgeHost();
      if (!mounted) return;
      if (resolved.error != null) {
        setState(() => _error = resolved.error);
        return;
      }
      final host = resolved.host;

      final outcome = await runCreateRepo(
        executor: _executor,
        log: _OutputLogSink(ref.read(outputLogProvider.notifier)),
        request: _request(host),
        deps: CreateRepoDeps(
          ensureForgeLogin: () => ref
              .read(connectionProvider.notifier)
              .ensureForgeHostLogin(_forge, host),
          isActive: () => mounted,
        ),
      );
      if (!mounted || outcome.aborted) return;
      if (outcome.error != null) {
        setState(() => _error = outcome.error);
        return;
      }
      // The repository exists — remember the namespace it went into, so the
      // next create offers it first (MADR 0032 Phase 3b; wired here per the
      // Phase 5 deviation of 2026-09-07, which found the writer had no caller).
      //
      // Only on a forge create, and only after success: a namespace that was
      // never created in is not a namespace the user works in. Awaited rather
      // than fire-and-forget so a test can observe it, but the writer swallows
      // its own failures — a create that succeeded must never be reported as
      // failed because *remembering* it did not work.
      await _rememberNamespace(host, outcome);
      if (!mounted) return;

      // --- Register + activate (shared matrix) ------------------------------
      final registered = await _register(outcome.dest);
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
      provisionToken = null; // finalized (or not provisioning) — don't abort
      final warning = outcome.warningText;
      if (warning != null) {
        setState(() => _completedWarning = warning);
        return; // stay open so the warning is seen; footer becomes Close
      }
      // Let the finished (green) progress bar register before the sheet pops —
      // success otherwise vanishes the very frame it happens.
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

  /// The forge host to publish to, and the fail-fast auth judgment that goes
  /// with it.
  ///
  /// For a This-Mac forge create, check the Mac's gh/glab sign-in and refuse
  /// when it is definitively unusable (signed out, expired token) — otherwise
  /// the forge `repo create` fails with a cryptic 401 after a local repo was
  /// already created. Goes through [forgeAuthProvider]: the same strict
  /// judgment (an expired token does NOT pass) and the same cached probe the
  /// host prefill already ran, logged to the output log. An SSH target instead
  /// relies on the pipeline's `ensureForgeLogin` hook, which pushes the
  /// connection's token before the remote CLI is queried.
  Future<({String host, String? error})> _resolveForgeHost() async {
    var host = _host.text.trim().isEmpty ? _defaultHost : _host.text.trim();
    if (!_onForge || !_isLocalTarget) return (host: host, error: null);
    final auth = await ref.read(forgeAuthProvider((_forge, true)).future);
    if (!mounted) return (host: host, error: null);
    if (!auth.authenticated && !auth.checkFailed) {
      // Definitive: signed out, expired, or the CLI is missing. (A check that
      // merely timed out proceeds best-effort — blocking a create on a slow
      // probe would be worse than the failure it guards against.)
      return (host: host, error: auth.detail);
    }
    // Trust the real signed-in host over a default the user never touched; a
    // host the user typed themselves is used verbatim — the Review step
    // displayed it, so it must never be silently replaced.
    if (!_hostEdited && auth.authenticated && auth.host != null) {
      host = auth.host!;
      _host.text = auth.host!;
    }
    return (host: host, error: null);
  }

  /// The wizard's answers as plain values — the pipeline's whole view of this
  /// form. Resolved here so the pipeline cannot reach back into a controller.
  CreateRepoRequest _request(String host) => CreateRepoRequest(
    existing: _source == _SourceMode.existingFolder,
    name: _name.text.trim(),
    forgePath: _forgePath,
    parentDir: _isLocalTarget ? (_pickedParent ?? '') : _parent.text.trim(),
    existingFolder: _isLocalTarget
        ? (_pickedFolder ?? '')
        : _folder.text.trim(),
    branch: _branch.text.trim(),
    host: host,
    remote: _remote,
    private: _private,
    description: _description.text.trim(),
    remoteUrl: _remoteUrl.text.trim(),
    addReadme: _addReadme,
    commitAll: _commitAll,
    replaceOrigin: _replaceOrigin,
    createParents: _createParents,
    isLocalTarget: _isLocalTarget,
    identityValid: _identityValid,
    authorName: _authorNameText,
    authorEmail: _authorEmailText,
  );

  Future<bool> _register(String dest) => registerAndActivate(
    ref,
    target: _target,
    dest: dest,
    localLabel: _localLabel.text.trim(),
    saveLocal: _saveLocal,
    remoteLabel: _remoteLabel.text.trim(),
    fsmonitor: _fsmonitor,
    connection: () => connectionById(_destConnectionId),
    provisionToken: provisionToken,
  );

  Future<void> _requestClose() async {
    // Escape / title-X while `git init` / forge publish is running must not
    // tear the SSH session down under the in-flight command — the footer
    // Cancel is already disabled for the same reason (0009 H20).
    if (_submitting) return;
    await resetProvisioning();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickLocalParent() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final path = await pickLocalDirectory();
      if (!mounted) return;
      if (path != null) setState(() => _pickedParent = path);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _pickLocalFolder() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final path = await pickLocalDirectory();
      if (!mounted) return;
      if (path != null) {
        setState(() {
          _pickedFolder = path;
          _name.text = basename(path);
        });
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _browseRemoteFolder() async {
    if (!await ensureProvisioned()) return;
    if (!mounted) return;
    final picked = await browseRemoteDirectory(
      context,
      initialPath: _folder.text,
    );
    if (picked != null && mounted) {
      setState(() {
        _folder.text = picked;
        _name.text = basename(picked);
      });
    }
  }

  Future<void> _browseRemote() async {
    if (!await ensureProvisioned()) return;
    if (!mounted) return;
    final picked = await browseRemoteDirectory(
      context,
      initialPath: _parent.text,
    );
    if (picked != null && mounted) {
      setState(() => _parent.text = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    // Settings load asynchronously (defaults first, then disk). Prefill
    // here so a stored identity lands before README/commit-all marks the
    // fields required — initState only sees the empty default.
    ref.listen(appSettingsProvider, (previous, next) {
      if (_applyIdentityPrefill(next)) setState(() {});
    });
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
    return WorkspaceDestinationSection(
      selectedConnectionId: _destConnectionId,
      onChanged: (_submitting || provisioning) ? null : _onDestChanged,
      provisioning: provisioning,
      localHint: 'The repository is created on this Mac\'s own filesystem.',
      remoteHint: 'The repository is created on the selected host over SSH.',
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

  Widget _sourceButton(String label, _SourceMode mode) => SegmentedChoice(
    label: label,
    value: mode,
    selected: _source,
    onSelected: (m) => setState(() {
      _source = m;
      _error = null;
    }),
  );

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

  /// The saved connection a create actually targets, or null for This Mac and
  /// for a session with nothing to persist into.
  ///
  /// **Not simply [_destConnectionId].** In connected mode the destination
  /// defaults to *this* session (`sshActive`) and the picker never sets an id,
  /// so reading the raw field would send an SSH create to the This-Mac store —
  /// the wrong half of the two-store split `NamespaceHistory` documents.
  String? _effectiveConnectionId(String? activeId) =>
      _isLocalTarget ? null : (_destConnectionId ?? activeId);

  /// Records the namespace a successful forge create used, for the next
  /// create's suggestions. Best-effort by contract — see [NamespaceHistory].
  ///
  /// **Only on a clean run.** A [CreateRepoOutcome] with no `error` still
  /// covers "the repository was created locally, but publishing to the forge
  /// failed" — reported as a warning, because the local repository is real.
  /// The namespace was never created in on that path, so remembering it would
  /// seed the suggestion list with somewhere the user has not been. Erring the
  /// other way (a clean forge create whose origin could not be wired is also a
  /// warning, and is not recorded) costs only a missing suggestion.
  Future<void> _rememberNamespace(
    String host,
    CreateRepoOutcome outcome,
  ) async {
    if (!_onForge || outcome.warnings.isNotEmpty) return;
    final namespace = _namespaceText;
    if (namespace.isEmpty) return;
    await ref
        .read(namespaceHistoryProvider)
        .record(
          forge: _forge,
          host: host,
          namespace: namespace,
          connection: await connectionById(
            _effectiveConnectionId(ref.read(connectionProvider).connectionId),
          ),
        );
  }

  /// The host the forge lookups are keyed by: whatever is typed, else the
  /// forge's default. The field is editable, so this is read fresh each build.
  String get _resolvedHost =>
      _host.text.trim().isEmpty ? _defaultHost : _host.text.trim();

  Widget _detailsStep(MacosTypography typography) {
    final existing = _source == _SourceMode.existingFolder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // For an existing folder the name only names the forge project (it's
        // prefilled from the folder); without a forge there is nothing to
        // name, so the field is hidden.
        if (!existing || _onForge)
          LabeledTextField(
            label: existing
                ? 'Repository name (on the forge)'
                : 'Repository name',
            controller: _name,
            placeholder: 'my-project',
            onChanged: () => setState(() {}),
            padding: const EdgeInsets.only(bottom: 10),
            hint: WizardHint(
              existing
                  ? 'Names the project created on the forge — prefilled from '
                        'the folder when picked with Browse/Choose.'
                  : 'Also the name of the folder created inside the parent. '
                        'Letters, digits, dot, dash and underscore.',
            ),
          ),
        // Only a forge has namespaces. Free text on purpose: a group the API
        // did not return — a fresh grant, a paginated tail, an unreachable
        // API — must stay typeable.
        if (_onForge) ...[
          NamespaceField(
            forge: _forge,
            host: _resolvedHost,
            isLocalTarget: _isLocalTarget,
            connectionId: _effectiveConnectionId(
              ref.watch(connectionProvider.select((c) => c.connectionId)),
            ),
            controller: _namespace,
            onChanged: () => setState(() {}),
            hint: WizardHint(
              _namespaceText.isEmpty
                  ? 'Leave empty to create under your own account. A group or '
                        'subgroup path creates it there instead.'
                  : 'Creates ${_forgePath.isEmpty ? '—' : _forgePath} on the '
                        'forge.',
            ),
          ),
          const SizedBox(height: 10),
        ],
        LabeledTextField(
          label: 'Initial branch',
          controller: _branch,
          placeholder: 'main',
          onChanged: () => setState(() {}),
          padding: const EdgeInsets.only(bottom: 10),
          hint: WizardHint(
            existing
                ? 'Used only if the folder isn\'t already a repository — an '
                      'existing repository keeps its current branch.'
                : 'The branch the repository starts on — "main" is the '
                      'common default.',
          ),
        ),
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
        const SizedBox(height: 10),
        LabeledTextField(
          label: 'Git identity',
          controller: _authorName,
          placeholder: 'Your name',
          showError: _needsIdentity && _authorNameText.isEmpty,
          padding: EdgeInsets.zero,
          onChanged: () {
            _authorNameEdited = true;
            setState(() {});
          },
        ),
        const SizedBox(height: 8),
        MacosTextField(
          controller: _authorEmail,
          placeholder: 'you@example.com',
          placeholderStyle: kAppPlaceholderStyle,
          decoration: _needsIdentity && !_looksLikeEmail(_authorEmailText)
              ? kAppTextFieldErrorDecoration
              : kAppTextFieldDecoration,
          focusedDecoration:
              _needsIdentity && !_looksLikeEmail(_authorEmailText)
              ? kAppTextFieldErrorFocusedDecoration
              : kAppTextFieldFocusedDecoration,
          onChanged: (_) {
            _authorEmailEdited = true;
            setState(() {});
          },
        ),
        WizardHint(
          _needsIdentity
              ? 'Written into this repository as user.name / user.email, '
                    'and used for the initial commit. Prefills from Settings '
                    'when set there.'
              : 'Written into this repository as user.name / user.email so '
                    'later commits have an author. Optional until you create '
                    'an initial commit. Prefills from Settings when set '
                    'there.',
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

  Widget _localFolderPicker(MacosTypography typography) => LocalFolderRow(
    label: 'Folder on this Mac',
    path: _pickedFolder,
    onChoose: _picking ? null : _pickLocalFolder,
    hint:
        'If this folder is not yet a Git repository it is initialized in '
        'place; a folder nested in another repository is refused.',
  );

  Widget _sshFolderField(MacosTypography typography) => RemotePathRow(
    label: 'Folder on the host',
    controller: _folder,
    placeholder: '/srv/app',
    onBrowse: _browseRemoteFolder,
    onChanged: () => setState(() {}),
    hint:
        'Absolute path on the host. If the folder is not yet a Git '
        'repository it is initialized in place; a folder nested in '
        'another repository is refused.',
  );

  Widget _commitAllToggle() => CommitAllToggle(
    on: _commitAll,
    onTap: () => setState(() => _commitAll = !_commitAll),
  );

  Widget _localParentPicker(MacosTypography typography) => LocalFolderRow(
    label: 'Parent folder on this Mac',
    path: _pickedParent,
    onChoose: _picking ? null : _pickLocalParent,
    hint:
        'The new repository folder (named on the Details step) is '
        'created inside this folder.',
  );

  Widget _sshParentField(MacosTypography typography) => RemotePathRow(
    label: 'Parent folder on the host',
    controller: _parent,
    placeholder: '/srv/git',
    onBrowse: _browseRemote,
    onChanged: () => setState(() {}),
    hint:
        'Absolute path on the host (e.g. /srv/git). The new repository '
        'folder is created inside it.',
    trailing: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
    ),
  );

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
            _remoteButton('None', CreateRemoteMode.none),
            _remoteButton('GitHub', CreateRemoteMode.github),
            _remoteButton('GitLab', CreateRemoteMode.gitlab),
            _remoteButton('Custom URL', CreateRemoteMode.customUrl),
          ],
        ),
        WizardHint(switch (_remote) {
          CreateRemoteMode.none =>
            'No remote is set up — you can add one later from the command '
                'line or by re-publishing.',
          CreateRemoteMode.github =>
            'Creates the project on GitHub with the gh CLI (it must be '
                'installed and signed in on the target machine) and wires '
                'it as "origin".',
          CreateRemoteMode.gitlab =>
            'Creates the project on GitLab with the glab CLI (it must be '
                'installed and signed in on the target machine) and wires '
                'it as "origin".',
          CreateRemoteMode.customUrl =>
            'Points "origin" at a remote that already exists — created on '
                'a web UI, a bare repo on a server, or any other Git URL. '
                'No forge CLI needed.',
        }),
        if (_source == _SourceMode.existingFolder &&
            _remote != CreateRemoteMode.none) ...[
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
        if (_remote == CreateRemoteMode.customUrl) ...[
          const SizedBox(height: 8),
          LabeledTextField(
            label: 'Existing remote to wire as origin',
            controller: _remoteUrl,
            placeholder: 'git@host:owner/repo.git or https://…',
            onChanged: () => setState(() {}),
            padding: EdgeInsets.zero,
            hint: const WizardHint(
              'SSH (git@host:owner/repo.git) or HTTPS '
              '(https://host/owner/repo.git). The remote itself is not '
              'created — it must already exist.',
            ),
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
          LabeledTextField(
            label: 'Forge host',
            controller: _host,
            placeholder: _defaultHost,
            padding: EdgeInsets.zero,
            // An empty field hands control back to the prefill; anything
            // typed pins the host (see _hostEdited).
            onChanged: () =>
                setState(() => _hostEdited = _host.text.trim().isNotEmpty),
            hint: const WizardHint(
              'Prefilled with the instance the CLI is signed in to on the '
              'target — type a different host to publish there instead (the '
              'CLI must be signed in there too). Clear the field to go back '
              'to the signed-in host.',
            ),
          ),
          const SizedBox(height: 8),
          LabeledTextField(
            label: 'Project description',
            controller: _description,
            placeholder: 'Description (optional)',
            padding: EdgeInsets.zero,
            hint: const WizardHint(
              'Shown on the forge project page (and used in the generated '
              'README when one is added).',
            ),
          ),
        ],
      ],
    );
  }

  Widget _remoteButton(String label, CreateRemoteMode mode) => SegmentedChoice(
    label: label,
    value: mode,
    selected: _remote,
    onSelected: (m) => setState(() {
      _remote = m;
      // Switching forges resets an untouched host to the new forge's
      // default (the prefill listener then fills in the signed-in host);
      // a user-typed host is kept.
      if (!_hostEdited) {
        _host.text = _defaultHost;
      }
    }),
  );

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
      CreateRemoteMode.none => 'None — no origin remote',
      CreateRemoteMode.github => 'GitHub ($host) — $visibility',
      CreateRemoteMode.gitlab => 'GitLab ($host) — $visibility',
      CreateRemoteMode.customUrl => _remoteUrl.text.trim(),
    };
    final options = <String>[
      if (!existing && _addReadme) 'Add a README (initial commit)',
      if (existing && _commitAll) 'Commit all existing contents',
      if (existing && _replaceOrigin && _remote != CreateRemoteMode.none)
        'Replace existing origin remote',
      if (!_isLocalTarget && !existing && _createParents)
        'Create parent folders if missing',
      if (!_isLocalTarget && _fsmonitor) 'Enable git fsmonitor',
      if (_isLocalTarget && _saveLocal) 'Save to Local Repositories',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WizardReviewRow('Destination', destText),
        WizardReviewRow(
          existing ? 'Existing folder' : 'New folder',
          sourceText,
        ),
        WizardReviewRow('Initial branch', _branch.text.trim()),
        if (_authorNameText.isNotEmpty || _authorEmailText.isNotEmpty)
          WizardReviewRow(
            'Git identity',
            [
              if (_authorNameText.isNotEmpty) _authorNameText,
              if (_authorEmailText.isNotEmpty) _authorEmailText,
            ].join(' · '),
          ),
        WizardReviewRow('Remote', remoteText),
        if (!_isLocalTarget && _remoteLabel.text.trim().isNotEmpty)
          WizardReviewRow('Label', _remoteLabel.text.trim()),
        if (options.isNotEmpty) WizardReviewRow('Options', options.join('\n')),
      ],
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
            onPressed: _submitting || _finished ? null : _goBack,
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
}

/// Adapts the app's output log to the pipeline's two-method sink, so
/// `create_repo_pipeline.dart` needs no Riverpod import.
class _OutputLogSink implements CreateRepoLog {
  const _OutputLogSink(this._log);
  final OutputLogNotifier _log;

  @override
  void logResult(String label, SSHCommandResult result) =>
      _log.logResult(label, result);

  @override
  void logError(String label, String detail) => _log.logError(label, detail);
}
