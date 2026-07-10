import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/forge/forge.dart';
import '../../core/forge/forge_repo_summary.dart';
import '../../core/git/host_fs_service.dart';
import '../../core/providers/app_providers.dart';
import '../../core/storage/saved_connection.dart';
import '../../core/workspace/clone_controller.dart';
import '../common/async_views.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';
import 'remote_directory_browser.dart';
import 'wizard.dart';
import 'workspace_registration.dart';
import 'workspace_targets.dart';
import 'workspace_widgets.dart';

/// Clone a repository — from a browsed GitHub/GitLab account or a plain URL —
/// onto the connected SSH host or this Mac.
///
/// Two modes: [CloneRepositorySheet.connected] targets the active workspace;
/// [CloneRepositorySheet.landing] adds a destination picker (This Mac, or a
/// saved SSH connection, which is provisioned on demand).
///
/// Presented as a data-driven wizard (same framework as the create sheet —
/// see wizard.dart): Destination → Source → Location → Review, with a
/// breadcrumb indicator, per-step Continue gating, an instructional intro on
/// every step, and a bottom progress bar that fills per step and turns green
/// once the clone has completed. The Destination step only participates on
/// the landing variant.
class CloneRepositorySheet extends ConsumerStatefulWidget {
  final bool landing;
  const CloneRepositorySheet.connected({super.key}) : landing = false;
  const CloneRepositorySheet.landing({super.key}) : landing = true;

  /// How long the finished (green) progress bar stays visible before the
  /// sheet pops on success. Overridable so tests don't wait it out.
  @visibleForTesting
  static Duration successPopDelay = const Duration(milliseconds: 600);

  @override
  ConsumerState<CloneRepositorySheet> createState() =>
      _CloneRepositorySheetState();
}

enum _SourceTab { github, gitlab, url }

class _CloneRepositorySheetState extends ConsumerState<CloneRepositorySheet> {
  _SourceTab _tab = _SourceTab.github;
  final _host = TextEditingController(text: 'github.com');
  final _filter = TextEditingController();
  final _url = TextEditingController();
  final _name = TextEditingController();
  final _parent = TextEditingController();
  ForgeRepoSummary? _selected;

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

  /// Set once the clone completed and the repo was registered — the bottom
  /// progress bar turns green for [CloneRepositorySheet.successPopDelay]
  /// before the sheet pops.
  bool _finished = false;

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
          'Choose where the clone will live: on this Mac, or on one of your '
          'saved SSH hosts. Picking a host connects to it on demand — the '
          'clone runs there and nothing is copied to this Mac.',
      applicable: () => widget.landing,
      valid: () => !_provisioning,
      body: _destinationSection,
    ),
    WizardStep(
      id: 'source',
      title: 'Source',
      intro:
          'Pick what to clone: browse the GitHub or GitLab repositories '
          'your account owns (using the destination\'s own gh/glab '
          'sign-in), or paste any Git URL — including repositories owned '
          'by an organization or another user.',
      valid: _sourceValid,
      body: _sourceStep,
    ),
    WizardStep(
      id: 'location',
      title: 'Location',
      intro:
          'Name the new folder and choose the parent folder it is cloned '
          'into, plus how the finished clone is registered in this app.',
      valid: _locationValid,
      body: _locationStep,
    ),
    WizardStep(
      id: 'review',
      title: 'Review',
      intro:
          'Nothing has been cloned yet — check the summary below, then '
          'press Clone. Progress streams live at the bottom; a failed or '
          'cancelled clone cleans up its partial folder automatically.',
      valid: WizardStep.always,
      body: _reviewStep,
    ),
  ];
  int _stepIndex = 0;

  List<WizardStep> get _activeSteps => [
    for (final s in _steps)
      if (s.applicable()) s,
  ];

  bool _sourceValid() => _tab == _SourceTab.url
      ? _url.text.trim().isNotEmpty
      : _selected != null;

  bool _locationValid() {
    if (!HostFsService.isValidRepoDirName(_name.text.trim())) return false;
    if (_isLocalTarget) return _pickedParent != null;
    return _parent.text.trim().startsWith('/');
  }

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
    // Start each open from a clean job state (a prior run may have left a
    // terminal phase behind).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(cloneJobProvider.notifier).reset();
    });
    _recomputeTarget();
  }

  @override
  void dispose() {
    _unregisterEscape?.call();
    _host.dispose();
    _filter.dispose();
    _url.dispose();
    _name.dispose();
    _parent.dispose();
    _localLabel.dispose();
    super.dispose();
  }

  Forge? get _forge => switch (_tab) {
    _SourceTab.github => Forge.github,
    _SourceTab.gitlab => Forge.gitlab,
    _SourceTab.url => null,
  };

  /// Recomputes the destination target from the current mode + selection, and
  /// prefills the SSH parent path when connected.
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
        _parent.text = _dirOf(conn.repoPath!);
      }
    } else {
      target = _destConnectionId == null
          ? WorkspaceTarget.localMac
          : WorkspaceTarget.sshProvision;
    }
    _target = target;
  }

  bool get _isLocalTarget => _target == WorkspaceTarget.localMac;

  /// Whether the forge browse list can query yet: immediate for local and the
  /// active SSH session; for a landing connection, only once provisioned.
  bool get _forgeBrowseReady =>
      _target != WorkspaceTarget.sshProvision || _provisionToken != null;

  Future<void> _onDestChanged(String? connectionId) async {
    // Switching destination abandons any in-flight provisioning.
    await _resetProvisioning();
    setState(() {
      _destConnectionId = connectionId;
      _error = null;
      _recomputeTarget();
    });
    if (_target == WorkspaceTarget.sshProvision) {
      await _ensureProvisioned();
    }
  }

  Future<void> _resetProvisioning() async {
    final token = _provisionToken;
    _provisionToken = null;
    if (token != null) {
      await ref.read(connectionProvider.notifier).abortProvisioning(token);
    }
  }

  /// Dials the chosen saved connection (once) so the browse/clone can run on
  /// its host. Returns whether the session is ready.
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

  /// Resolves a saved connection by id through the provider *future* — the
  /// sync `.value` is null unless something else happens to be watching the
  /// provider (true on the landing, not in connected mode).
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
    if (_submitting || _finished) return false;
    return _activeSteps.every((s) => s.valid());
  }

  Future<void> _submit() async {
    if (_submitting || !_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      // Ensure the destination session is live (landing → connection).
      if (!await _ensureProvisioned()) {
        return; // _error already set by _ensureProvisioned
      }

      final name = _name.text.trim();
      final parentDir = _isLocalTarget
          ? _pickedParent!
          : _parent.text.trim();
      final host = _host.text.trim();
      final source = _tab == _SourceTab.url
          ? UrlCloneSource(_url.text.trim())
          : ForgeCloneSource(
              forge: _forge!,
              host: host.isEmpty ? _defaultHost : host,
              slug: _selected!.slug,
            );
      final request = CloneRequest(
        source: source,
        parentDir: parentDir,
        name: name,
        createParents: !_isLocalTarget && _createParents,
        local: _isLocalTarget,
      );

      final ok = await ref.read(cloneJobProvider.notifier).run(request);
      if (!mounted) return;
      if (!ok) {
        // Clone failed/cancelled — surface it; keep any provisioning alive so
        // the user can fix the input and retry without re-handshaking.
        setState(() {
          _error =
              ref.read(cloneJobProvider).error ?? 'The clone did not complete.';
        });
        return;
      }

      final dest = HostFsService.joinPath(parentDir, name);
      await _register(dest);
      if (!mounted) return;
      // Provisioning (if any) has been finalized by _register; don't abort it.
      _provisionToken = null;
      // Let the finished (green) progress bar register before the sheet
      // pops — success otherwise vanishes the very frame it happens.
      setState(() => _finished = true);
      await Future<void>.delayed(CloneRepositorySheet.successPopDelay);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Registers and activates the freshly-cloned repo for the current target
  /// (shared matrix — see workspace_registration.dart).
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
    final job = ref.read(cloneJobProvider);
    if (job.isRunning) {
      await ref.read(cloneJobProvider.notifier).cancel();
    }
    ref.read(cloneJobProvider.notifier).reset();
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

  String get _defaultHost =>
      _tab == _SourceTab.gitlab ? 'gitlab.com' : 'github.com';

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final job = ref.watch(cloneJobProvider);
    final running = job.isRunning || _submitting;
    final steps = _activeSteps;
    final stepIndex = _stepIndex.clamp(0, steps.length - 1);

    return SizedSheet(
      width: 392,
      height: (MediaQuery.sizeOf(context).height - 60).clamp(460.0, 680.0),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const MacosIcon(CupertinoIcons.cloud_download, size: 18),
                const SizedBox(width: 8),
                Text('Clone repository', style: typography.title2),
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
            WizardStepIndicator(steps: steps, current: stepIndex),
            const SizedBox(height: 14),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    WizardStepIntro(steps[stepIndex].intro),
                    const SizedBox(height: 14),
                    steps[stepIndex].body(typography),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null) ...[
              WorkspaceBanner(_error!, error: true),
              const SizedBox(height: 10),
            ],
            WizardProgressBar(
              steps: steps,
              current: stepIndex,
              complete: _finished,
            ),
            const SizedBox(height: 10),
            _footer(typography, job, running),
          ],
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
              ? 'The repository is cloned onto this Mac\'s own filesystem.'
              : 'The repository is cloned on the selected host over SSH — '
                    'its own git and forge sign-ins are used.',
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

  Widget _sourceStep(MacosTypography typography) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Source', style: typography.caption1),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _tabButton('GitHub', _SourceTab.github),
            _tabButton('GitLab', _SourceTab.gitlab),
            _tabButton('URL', _SourceTab.url),
          ],
        ),
        WizardHint(
          _tab == _SourceTab.url
              ? 'Any URL git clone accepts — HTTPS or SSH. Private '
                    'repositories use the destination\'s own credentials.'
              : 'Lists the repositories your signed-in account owns — pick '
                    'one below. For an organization\'s repo, use URL.',
        ),
        const SizedBox(height: 10),
        if (_tab == _SourceTab.url) ...[
          Text('Repository URL', style: typography.caption1),
          const SizedBox(height: 4),
          MacosTextField(
            controller: _url,
            placeholder: 'https://github.com/owner/repo.git',
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
            onChanged: (v) {
              final derived = _repoNameFromUrl(v);
              if (derived != null && _name.text.trim().isEmpty) {
                _name.text = derived;
              }
              setState(() {});
            },
          ),
          const WizardHint(
            'The folder name on the Location step is prefilled from the '
            'URL\'s last path segment.',
          ),
        ] else
          _forgeBrowse(typography),
      ],
    );
  }

  Widget _forgeBrowse(MacosTypography typography) {
    if (!_forgeBrowseReady) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'Pick a destination connection to browse its repositories.',
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
      );
    }
    final host = _host.text.trim().isEmpty ? _defaultHost : _host.text.trim();
    final key = (_forge!, host, _isLocalTarget);
    final async = ref.watch(forgeRepoListProvider(key));
    final query = _filter.text.trim().toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Forge host', style: typography.caption1),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: MacosTextField(
                controller: _host,
                placeholder: _defaultHost,
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
                onSubmitted: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 6),
            ToolIconButton(
              icon: CupertinoIcons.arrow_clockwise,
              tooltip: 'Reload',
              size: 15,
              onPressed: () {
                ref.invalidate(forgeRepoListProvider(key));
                setState(() {});
              },
            ),
          ],
        ),
        WizardHint(
          'Leave as $_defaultHost, or a self-hosted instance the '
          'destination\'s CLI is signed in to. Press Return to reload.',
        ),
        const SizedBox(height: 6),
        MacosTextField(
          controller: _filter,
          placeholder: 'Filter…',
          decoration: kAppTextFieldDecoration,
          focusedDecoration: kAppTextFieldFocusedDecoration,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 180,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: MacosColors.separatorColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: async.when(
              loading: () => const Center(child: ProgressCircle()),
              error: (err, _) => SectionError(err),
              data: (repos) {
                final shown = query.isEmpty
                    ? repos
                    : [
                        for (final r in repos)
                          if (r.slug.toLowerCase().contains(query)) r,
                      ];
                if (shown.isEmpty) {
                  return const SectionEmpty('No repositories');
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: shown.length,
                  itemBuilder: (context, i) => _RepoRow(
                    repo: shown[i],
                    selected: identical(_selected, shown[i]),
                    onTap: () => setState(() {
                      _selected = shown[i];
                      _name.text = shown[i].name;
                    }),
                  ),
                );
              },
            ),
          ),
        ),
        const WizardHint(
          'Selecting a repository prefills the folder name on the '
          'Location step.',
        ),
      ],
    );
  }

  Widget _locationStep(MacosTypography typography) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Folder name', style: typography.caption1),
        const SizedBox(height: 4),
        MacosTextField(
          controller: _name,
          placeholder: 'my-repo',
          decoration: kAppTextFieldDecoration,
          focusedDecoration: kAppTextFieldFocusedDecoration,
          onChanged: (_) => setState(() {}),
        ),
        const WizardHint(
          'The new folder created inside the parent — prefilled from the '
          'source. Letters, digits, dot, dash and underscore.',
        ),
        const SizedBox(height: 12),
        if (_isLocalTarget)
          _localDestination(typography)
        else
          _sshDestination(typography),
      ],
    );
  }

  Widget _localDestination(MacosTypography typography) {
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
        const WizardHint(
          'The repository folder is created inside this folder.',
        ),
        const SizedBox(height: 10),
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
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
          ),
          const WizardHint(
            'Display name in the Connections list — defaults to the '
            'folder name.',
          ),
        ],
      ],
    );
  }

  Widget _sshDestination(MacosTypography typography) {
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
        const WizardHint(
          'Absolute path on the host (e.g. /srv/git). The repository '
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
          'When off, a missing parent folder stops the clone instead of '
          'being silently created.',
        ),
        const SizedBox(height: 8),
        WorkspaceToggleRow(
          on: _fsmonitor,
          onTap: () => setState(() => _fsmonitor = !_fsmonitor),
          onIcon: CupertinoIcons.bolt_fill,
          offIcon: CupertinoIcons.bolt,
          label: 'Enable git fsmonitor (faster status on large repos)',
        ),
        const WizardHint(
          'Turns on git\'s filesystem monitor in the cloned repository — '
          'speeds up status on big working trees.',
        ),
      ],
    );
  }

  /// Everything the wizard collected, as label/value rows — what Clone will
  /// actually do, derived live from the same state the steps edited.
  Widget _reviewStep(MacosTypography typography) {
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
    final host = _host.text.trim().isEmpty ? _defaultHost : _host.text.trim();
    final sourceText = _tab == _SourceTab.url
        ? _url.text.trim()
        : '${_selected?.slug ?? '—'} on $host';
    final parentText = _isLocalTarget
        ? (_pickedParent ?? '—')
        : _parent.text.trim();
    final options = <String>[
      if (!_isLocalTarget && _createParents) 'Create parent folders if missing',
      if (!_isLocalTarget && _fsmonitor) 'Enable git fsmonitor',
      if (_isLocalTarget && _saveLocal) 'Save to Local Repositories',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WizardReviewRow('Destination', destText),
        WizardReviewRow('Source', sourceText),
        WizardReviewRow('Folder', '${_name.text.trim()} in $parentText'),
        if (options.isNotEmpty) WizardReviewRow('Options', options.join('\n')),
      ],
    );
  }

  Widget _footer(MacosTypography typography, CloneJobState job, bool running) {
    final steps = _activeSteps;
    final last = _stepIndex >= steps.length - 1;
    return Row(
      children: [
        if (running)
          Expanded(
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: ProgressCircle(radius: 7),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    job.progressLine.isEmpty ? 'Cloning…' : job.progressLine,
                    style: typography.caption1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          )
        else
          const Spacer(),
        const SizedBox(width: 12),
        if (job.isRunning)
          PushButton(
            controlSize: ControlSize.large,
            secondary: true,
            onPressed: () => ref.read(cloneJobProvider.notifier).cancel(),
            child: const Text('Cancel'),
          )
        else ...[
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
              onPressed: _submitting || _finished ? null : _goBack,
              child: const Text('Back'),
            ),
          ],
          const SizedBox(width: 8),
          if (last)
            PushButton(
              controlSize: ControlSize.large,
              onPressed: _canSubmit ? _submit : null,
              child: const Text('Clone'),
            )
          else
            PushButton(
              controlSize: ControlSize.large,
              onPressed:
                  !_submitting && steps[_stepIndex.clamp(0, steps.length - 1)].valid()
                  ? _goNext
                  : null,
              child: const Text('Continue'),
            ),
        ],
      ],
    );
  }

  Widget _tabButton(String label, _SourceTab tab) {
    final active = _tab == tab;
    return PushButton(
      controlSize: ControlSize.regular,
      secondary: !active,
      onPressed: () => setState(() {
        _tab = tab;
        _selected = null;
        if (tab != _SourceTab.url) {
          final h = _host.text.trim();
          if (h.isEmpty || h == 'github.com' || h == 'gitlab.com') {
            _host.text = _defaultHost;
          }
        }
      }),
      child: Text(label),
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

  static String? _repoNameFromUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return null;
    if (u.endsWith('.git')) u = u.substring(0, u.length - 4);
    u = u.replaceAll(RegExp(r'[/:]+$'), '');
    final sep = u.lastIndexOf(RegExp(r'[/:]'));
    final name = sep < 0 ? u : u.substring(sep + 1);
    return name.isEmpty ? null : name;
  }
}

class _RepoRow extends StatelessWidget {
  final ForgeRepoSummary repo;
  final bool selected;
  final VoidCallback onTap;
  const _RepoRow({
    required this.repo,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        color: selected
            ? MacosColors.systemBlueColor.withValues(alpha: 0.18)
            : const Color(0x00000000),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            MacosIcon(
              repo.isPrivate ? CupertinoIcons.lock_fill : CupertinoIcons.book,
              size: 13,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    repo.slug,
                    style: typography.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (repo.description.isNotEmpty)
                    Text(
                      repo.description,
                      style: typography.caption1.copyWith(
                        color: MacosColors.systemGrayColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
