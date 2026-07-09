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

/// Create a new repository — plain `git init`, or forge-backed (created on
/// GitHub/GitLab with `origin` wired) — on the connected SSH host or this Mac.
///
/// Same two modes as the clone sheet: [CreateRepositorySheet.connected]
/// targets the active workspace; [CreateRepositorySheet.landing] adds the
/// destination picker (This Mac, or a saved SSH connection provisioned on
/// demand).
///
/// Mechanisms (one per forge):
///  * none    — one-shot `git init -b <branch> -- <name>` in the parent.
///  * GitHub  — forge-first `gh repo create … --clone`: creates the repo on
///    the forge, clones it into the parent, and wires `origin` in a single
///    non-interactive command. The forge's default branch governs, so the
///    initial-branch field is disabled in this mode.
///  * GitLab  — init-then-create: `git init` first, then `glab repo create`
///    run *inside* the new repo (its documented origin-wiring path), keeping
///    the user's chosen initial branch authoritative. If the forge step
///    fails, the local repo is kept and registered with a warning — never
///    deleted over a forge hiccup.
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

  bool _onForge = false;
  Forge _forge = Forge.github;
  bool _private = true;
  bool _addReadme = false;

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

  bool get _branchEditable => !(_onForge && _forge == Forge.github);

  String get _defaultHost =>
      _forge == Forge.gitlab ? 'gitlab.com' : 'github.com';

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
    if (!HostFsService.isValidRepoDirName(_name.text.trim())) return false;
    if (_branchEditable && _branch.text.trim().isEmpty) return false;
    if (_isLocalTarget) return _pickedParent != null;
    return _parent.text.trim().startsWith('/');
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

      final executor = _executor;
      final fs = HostFsService(executor);
      final log = ref.read(outputLogProvider.notifier);
      final name = _name.text.trim();
      final parentDir = _isLocalTarget ? _pickedParent! : _parent.text.trim();
      final dest = HostFsService.joinPath(parentDir, name);
      final host = _host.text.trim().isEmpty ? _defaultHost : _host.text.trim();

      // --- Pre-checks ---------------------------------------------------
      switch (await fs.probePath(dest)) {
        case PathProbe.exists:
          setState(() => _error = 'The destination already exists: $dest');
          return;
        case PathProbe.noParent:
          if (!_isLocalTarget && _createParents) {
            await fs.makeDirs(parentDir);
          } else {
            setState(
              () => _error = "The parent folder doesn't exist: $parentDir",
            );
            return;
          }
        case PathProbe.absent:
          break;
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

      String? warning;
      if (_onForge && _forge == Forge.github) {
        // Forge-first: one command creates + clones + wires origin.
        final label = 'gh repo create $name';
        try {
          final result = await GhService(executor).createRepo(
            cwd: parentDir,
            name: name,
            private: _private,
            description: _description.text.trim(),
            host: host,
            addReadme: _addReadme,
          );
          log.logResult(label, result);
        } on GhException catch (e) {
          log.logResult(label, e.result);
          setState(() => _error = '$e\n${e.result.stderr}'.trim());
          return;
        }
      } else {
        // Plain init (also step 1 of the GitLab mechanism).
        final branch = _branch.text.trim();
        final initLabel = 'git init -b $branch $name';
        final result = await executor.execute(
          repoPath: parentDir,
          gitArgs: ['git', 'init', '-b', branch, '--', name],
          lane: ExecLane.exclusive,
          retries: 0,
        );
        log.logResult(initLabel, result);
        if (!result.isSuccess) {
          setState(
            () => _error = result.stderr.trim().isEmpty
                ? 'git init exited with code ${result.exitCode}'
                : result.stderr.trim(),
          );
          return;
        }
        if (!mounted) return;

        if (_onForge && _forge == Forge.gitlab) {
          // Step 2: create on GitLab from inside the new repo (wires origin).
          // A failure keeps the local repo — registered below with a warning.
          final label = 'glab repo create $name';
          try {
            await GlabService(executor).createRepoInExisting(
              repoPath: dest,
              name: name,
              private: _private,
              description: _description.text.trim(),
              host: host,
            );
          } on GlabException catch (e) {
            log.logResult(label, e.result);
            warning =
                'The repository was created locally, but publishing to '
                'GitLab failed — you can retry from the forge later. '
                '(${e.result.stderr.trim().isEmpty ? e : e.result.stderr.trim()})';
          }
          if (!mounted) return;
        }
      }

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
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.landing) ...[
                        _destinationSection(typography),
                        const SizedBox(height: 14),
                      ],
                      _nameSection(typography),
                      const SizedBox(height: 14),
                      if (_isLocalTarget)
                        _localDestination(typography)
                      else
                        _sshDestination(typography),
                      const SizedBox(height: 14),
                      _forgeSection(typography),
                    ],
                  ),
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

  Widget _nameSection(MacosTypography typography) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Repository name', style: typography.caption1),
        const SizedBox(height: 4),
        MacosTextField(
          controller: _name,
          placeholder: 'my-project',
          decoration: kAppTextFieldDecoration,
          focusedDecoration: kAppTextFieldFocusedDecoration,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        Text(
          _branchEditable
              ? 'Initial branch'
              : 'Initial branch (set by GitHub for a forge-created repo)',
          style: typography.caption1,
        ),
        const SizedBox(height: 4),
        MacosTextField(
          controller: _branch,
          placeholder: 'main',
          enabled: _branchEditable,
          decoration: kAppTextFieldDecoration,
          focusedDecoration: kAppTextFieldFocusedDecoration,
          onChanged: (_) => setState(() {}),
        ),
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
        const SizedBox(height: 10),
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
        const SizedBox(height: 10),
        WorkspaceToggleRow(
          on: _createParents,
          onTap: () => setState(() => _createParents = !_createParents),
          onIcon: CupertinoIcons.folder_badge_plus,
          offIcon: CupertinoIcons.folder,
          label: 'Create parent folders if missing',
        ),
        const SizedBox(height: 8),
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

  Widget _forgeSection(MacosTypography typography) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkspaceToggleRow(
          on: _onForge,
          onTap: () => setState(() => _onForge = !_onForge),
          onIcon: CupertinoIcons.cloud_upload_fill,
          offIcon: CupertinoIcons.cloud_upload,
          label: 'Also create on GitHub / GitLab (wires origin)',
        ),
        if (_onForge) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              _forgeButton('GitHub', Forge.github),
              const SizedBox(width: 6),
              _forgeButton('GitLab', Forge.gitlab),
              const SizedBox(width: 12),
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
          if (_forge == Forge.github) ...[
            const SizedBox(height: 8),
            WorkspaceToggleRow(
              on: _addReadme,
              onTap: () => setState(() => _addReadme = !_addReadme),
              onIcon: CupertinoIcons.doc_text_fill,
              offIcon: CupertinoIcons.doc_text,
              label: 'Add a README',
            ),
          ],
        ],
      ],
    );
  }

  Widget _forgeButton(String label, Forge forge) {
    final active = _forge == forge;
    return PushButton(
      controlSize: ControlSize.regular,
      secondary: !active,
      onPressed: () => setState(() {
        _forge = forge;
        final h = _host.text.trim();
        if (h.isEmpty || h == 'github.com' || h == 'gitlab.com') {
          _host.text = _defaultHost;
        }
      }),
      child: Text(label),
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
        const SizedBox(width: 8),
        PushButton(
          controlSize: ControlSize.large,
          onPressed: _canSubmit ? _submit : null,
          child: const Text('Create'),
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
}
