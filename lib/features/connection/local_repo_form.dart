import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/local/linked_worktree_probe.dart';
import '../../core/local/scoped_access.dart';
import '../../core/local/security_scoped_bookmark.dart';
import '../../core/providers/app_providers.dart';
import '../../core/storage/saved_connection.dart';
import '../../core/storage/saved_local_repo.dart';
import '../common/actions.dart';
import '../common/buttons.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';
import '../workspace/remote_directory_browser.dart';

/// The sandbox grants needed to open one local repo.
///
/// [mainRepoPath] is non-null only for a **linked worktree**, whose git data
/// lives in the main repository — so it needs that folder granted too, and both
/// grants held for the whole session. Hand this straight to
/// `ConnectionController.connectLocal`, which takes ownership of releasing them.
class LocalOpenGrants {
  final String repoPath;
  final String? mainRepoPath;

  /// A freshly-minted bookmark for the main repo, when one had to be granted
  /// through the picker just now. Persist it on [SavedLocalRepo] so reopening
  /// doesn't prompt again. Null when it came from an already-saved bookmark.
  final String? newMainRepoBookmark;

  const LocalOpenGrants(
    this.repoPath, {
    this.mainRepoPath,
    this.newMainRepoBookmark,
  });
}

/// Ensures every sandbox grant needed to open [repoPath] is held, prompting for
/// the main repository if [repoPath] turns out to be a linked worktree we don't
/// already have access to. Returns null if the user cancels or access fails.
///
/// Why this is necessary, and why it reads the `.git` file rather than asking
/// git: a linked worktree's HEAD, index and every object/ref live in the MAIN
/// repository's `.git`. Under the App Sandbox we may only read folders the user
/// picked, so without a second grant even `git status` fails. But we can't learn
/// that we need the grant by running git — running git is the thing that needs
/// it. [probeLocalRepo] breaks the cycle by reading the worktree's own `.git`
/// file, which is inside the grant we already have.
Future<LocalOpenGrants?> ensureLocalRepoGrants(
  BuildContext context,
  String repoPath, {
  String savedMainRepoBookmark = '',
}) async {
  final probe = probeLocalRepo(repoPath);
  if (probe.kind != LocalRepoKind.linkedWorktree) {
    // Ordinary repo (or something connectLocal's own validation will reject
    // with a clear message) — the one grant we hold is enough.
    return LocalOpenGrants(repoPath);
  }

  final mainRepoPath = probe.worktree!.mainRepoPath;

  // Reopening a saved worktree: we persisted the main repo's bookmark, so no
  // prompt.
  if (savedMainRepoBookmark.isNotEmpty) {
    final resolved = await ScopedAccess.instance.acquire(savedMainRepoBookmark);
    if (resolved != null) {
      return LocalOpenGrants(repoPath, mainRepoPath: resolved);
    }
    // Bookmark went stale (main repo moved/deleted) — fall through and re-ask.
  }

  if (!context.mounted) return null;
  final proceed = await confirmAction(
    context,
    title: 'Grant access to the main repository',
    message:
        'This is a linked worktree. Its branches, commits and history are '
        'stored in the main repository at:\n\n$mainRepoPath\n\n'
        'macOS requires you to select that folder before this app can read it.',
    confirmLabel: 'Choose Folder…',
  );
  if (!proceed || !context.mounted) return null;

  final picked = await getDirectoryPath(initialDirectory: mainRepoPath);
  if (picked == null || !context.mounted) return null;

  // The picker grants whatever the user actually chose, which may not be the
  // folder we asked for. Anything git needs lives under the main repo, so a
  // grant on an ancestor works too — but a sibling or an unrelated folder does
  // not, and would fail later with a raw permission error. Check now.
  if (!_grants(picked, mainRepoPath)) {
    await showErrorDialog(
      context,
      'That folder does not contain the main repository.\n\n'
      'Please choose:\n$mainRepoPath',
    );
    return null;
  }

  final bookmark = await SecurityScopedBookmark.create(picked);
  return LocalOpenGrants(
    repoPath,
    mainRepoPath: picked,
    newMainRepoBookmark: bookmark,
  );
}

/// Whether a sandbox grant on [granted] covers [needed] — true when it IS the
/// folder, or an ancestor of it (a grant extends to the whole subtree).
bool _grants(String granted, String needed) =>
    needed == granted || needed.startsWith('$granted/');

/// Resolves [repo]'s macOS security-scoped bookmark to a path this process can
/// currently read, or shows an error dialog and returns null when access can't
/// be restored (the folder was moved/deleted, or the sandbox grant revoked).
/// Returns the stored path unchanged for a repo saved without a bookmark.
///
/// For a linked worktree this also re-acquires the **main repository's** grant,
/// which is equally required — see [ensureLocalRepoGrants]. The result carries
/// it through to `connectLocal`.
///
/// Shared by the landing card's Recent Workspaces menu and the connection
/// switcher so a stale bookmark is handled identically in both. Does not
/// connect or dismiss any UI — the caller opens via `connectLocal` and manages
/// its own panel/sheet, and must NOT dismiss before calling this (the error
/// dialog needs a still-mounted context).
Future<LocalOpenGrants?> resolveSavedLocalRepo(
  BuildContext context,
  SavedLocalRepo repo,
) async {
  var path = repo.repoPath;
  if (repo.bookmarkData.isNotEmpty) {
    // Refcounted so concurrent tabs on the same folder don't pull the shared
    // native grant out from under each other on the first one's disconnect.
    final resolved = await ScopedAccess.instance.acquire(repo.bookmarkData);
    if (resolved == null) {
      if (context.mounted) {
        await showErrorDialog(
          context,
          "Can't access this repository anymore — it may have been moved, "
          'deleted, or its access permission revoked. Remove it and add it '
          'again via the folder picker.',
        );
      }
      return null;
    }
    path = resolved;
  }
  if (!context.mounted) return null;
  return ensureLocalRepoGrants(
    context,
    path,
    savedMainRepoBookmark: repo.mainRepoBookmarkData,
  );
}

/// Single pane of glass for adding a repository that **already exists** — on
/// this Mac's own filesystem, or on any of your saved SSH connections.
///
/// The Location dropdown defaults to Local (a native Finder pick, the only way
/// to gain a sandbox access grant for it at all) and lists every saved SSH
/// host. Choosing one dials it on demand (the connection controller's
/// provisioning flow — see [ConnectionController.beginProvisioning]) and swaps
/// the folder picker to a browser of that host's filesystem. Submitting opens
/// the repo as the active workspace and registers it — into Local Repositories
/// for a local pick, or into the chosen connection's repo list (via
/// [ConnectionController.finalizeProvisioned]) for a remote one. Either way
/// validation is whatever the connect/finalize call surfaces, reusing the same
/// error-display convention as [ConnectionForm].
class AddExistingRepoSheet extends ConsumerStatefulWidget {
  const AddExistingRepoSheet({super.key});

  @override
  ConsumerState<AddExistingRepoSheet> createState() =>
      _AddExistingRepoSheetState();
}

class _AddExistingRepoSheetState extends ConsumerState<AddExistingRepoSheet> {
  final _label = TextEditingController();
  final _gitDir = TextEditingController();

  /// Location: null = this Mac (local), else a saved SSH connection's id.
  String? _connectionId;

  String? _pickedPath;
  bool _save = true;
  bool _fsmonitor = false;
  /// Scoped work-tree (dotfiles) repo: the picked folder is the work tree and
  /// [_gitDir] the external git-dir (e.g. a `~/.home.git` nested inside `$HOME`).
  /// Local-only — the remote branch mirrors the old per-connection add, which
  /// had no scoping (a scoped remote repo is configured on the connection form).
  bool _scoped = false;
  bool _picking = false;
  bool _submitting = false;
  String? _saveWarning;

  // Provisioning lifecycle for a chosen SSH connection: dialed on demand so its
  // filesystem can be browsed and the repo opened on it. Mirrors the clone /
  // create landing sheets. Torn down in [dispose] if the sheet closes before a
  // successful finalize (which nulls the token so the now-live session stays).
  int? _provisionToken;
  bool _provisioning = false;

  bool get _isLocal => _connectionId == null;

  @override
  void dispose() {
    // Hang up a connection we dialed only to browse, unless a finalize already
    // promoted it to the live session (token nulled). Fire-and-forget: dispose
    // can't await, and the token capture inside is synchronous.
    _resetProvisioning();
    _label.dispose();
    _gitDir.dispose();
    super.dispose();
  }

  Future<void> _resetProvisioning() async {
    final token = _provisionToken;
    _provisionToken = null;
    if (token != null) {
      await ref.read(connectionProvider.notifier).abortProvisioning(token);
    }
  }

  /// Resolves the chosen saved connection through the provider *future* — the
  /// sync `.value` is null unless something is already watching it.
  Future<SavedConnection?> _connectionById(String? id) async {
    if (id == null) return null;
    try {
      for (final c in await ref.read(savedConnectionsProvider.future)) {
        if (c.id == id) return c;
      }
    } catch (_) {
      // Store unreadable — treat as "no such connection".
    }
    return null;
  }

  Future<void> _onLocationChanged(String? id) async {
    if (id == _connectionId || _submitting) return;
    // Switching location abandons any in-flight provisioning, and a path picked
    // on one host is meaningless on another.
    await _resetProvisioning();
    if (!mounted) return;
    setState(() {
      _connectionId = id;
      _pickedPath = null;
      _saveWarning = null;
    });
    if (!_isLocal) await _ensureProvisioned();
  }

  /// Dials the chosen saved connection (once) so its filesystem can be browsed
  /// and the repo opened on it. Returns whether the session is ready; a failure
  /// lands `phase: error` on the connection state, shown by [build].
  Future<bool> _ensureProvisioned() async {
    if (_isLocal) return true;
    if (_provisionToken != null) return true;
    if (_provisioning) return false;
    final conn = await _connectionById(_connectionId);
    if (conn == null || !mounted) return false;
    setState(() => _provisioning = true);
    final token = await ref
        .read(connectionProvider.notifier)
        .beginProvisioning(conn);
    if (!mounted) return false;
    setState(() {
      _provisioning = false;
      _provisionToken = token;
    });
    return token != null;
  }

  Future<void> _pickFolder() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final path = await getDirectoryPath(confirmButtonText: 'Choose');
      if (!mounted) return;
      if (path != null) setState(() => _pickedPath = path);
    } catch (_) {
      // No native picker implementation available (e.g. running under
      // `flutter test`, or a transient platform failure) — leave the
      // "no folder chosen" state rather than crashing.
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Browses the provisioned host's filesystem and takes the chosen folder as
  /// the repository root.
  Future<void> _browseRemote() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      if (!await _ensureProvisioned() || !mounted) return;
      final picked = await showMacosSheet<String>(
        context: context,
        builder: (_) => EscapeDismissible(
          child: RemoteDirectoryBrowserSheet(initialPath: _pickedPath),
        ),
      );
      if (picked != null && mounted) setState(() => _pickedPath = picked);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _submit() {
    if (_isLocal) {
      _openLocal();
    } else {
      _openRemote();
    }
  }

  /// Opens the picked remote folder as the active session and registers it into
  /// the chosen connection's repo list (both via [finalizeProvisioned]). A repo
  /// that fails validation throws — surfaced inline, provisioning kept alive so
  /// the user can pick another folder and retry without re-handshaking.
  Future<void> _openRemote() async {
    final path = _pickedPath;
    if (path == null || _submitting) return;
    setState(() {
      _submitting = true;
      _saveWarning = null;
    });
    try {
      if (!await _ensureProvisioned() || !mounted) return;
      final conn = await _connectionById(_connectionId);
      final token = _provisionToken;
      if (conn == null || token == null || !mounted) return;
      final ok = await ref
          .read(connectionProvider.notifier)
          .finalizeProvisioned(
            token: token,
            conn: conn,
            repoPath: path,
            enableFsmonitor: _fsmonitor,
            label: _label.text.trim(),
          );
      if (!mounted) return;
      if (!ok) return; // superseded by a concurrent connect/disconnect
      _provisionToken = null; // finalized — the session is live; don't abort it
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.pop();
    } catch (e) {
      if (mounted) {
        setState(
          () => _saveWarning =
              "Couldn't open this folder as a repository on the host — make "
              'sure it contains a Git repository. ($e)',
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _openLocal() async {
    final path = _pickedPath;
    if (path == null || _submitting) return;
    setState(() => _submitting = true);
    try {
      // Generated upfront (not after saving) so `connectLocal`'s `id` matches
      // the `SavedLocalRepo.id` persisted below — otherwise the just-opened
      // session wouldn't read as "active" against its own freshly-saved
      // entry in the switcher panel.
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final label = _label.text.trim();
      final gitDir = _scoped ? _gitDir.text.trim() : '';
      // The picked folder may be a linked worktree, whose git data lives in the
      // main repository — a second grant, without which no git command works.
      // Ask for it BEFORE connecting, since connectLocal's own validation runs
      // git and would otherwise fail with a raw permission error.
      final grants = await ensureLocalRepoGrants(context, path);
      if (!mounted || grants == null) return;
      await ref
          .read(connectionProvider.notifier)
          .connectLocal(
            path,
            label: label.isEmpty ? null : label,
            id: _save ? id : null,
            mainRepoPath: grants.mainRepoPath,
            gitDir: gitDir.isEmpty ? null : gitDir,
          );
      if (!mounted) return;
      // connectLocal surfaced an error (not a git repo, permission denied,
      // …) — stay open so the user sees it rather than silently no-op-ing.
      if (!ref.read(connectionProvider).isConnected) return;

      // Apply git fsmonitor live now that the open is confirmed. Persisted
      // below when saving so a later reopen re-applies it (connectLocal reads
      // it back from the store). Best-effort — status still works without it.
      if (_fsmonitor) {
        try {
          await ref.read(gitServiceProvider).setFsmonitor(path, enabled: true);
        } catch (_) {}
        if (!mounted) return;
      }

      if (_save) {
        // Bookmark/persist only now that the open is confirmed to actually
        // work — never save a folder that turned out not to be a valid repo.
        final bookmark = await SecurityScopedBookmark.create(path);
        if (!mounted) return;
        try {
          await ref
              .read(localRepoStoreProvider)
              .save(
                SavedLocalRepo(
                  id: id,
                  label: label,
                  repoPath: path,
                  bookmarkData: bookmark ?? '',
                  // Both empty for an ordinary repo. For a linked worktree these
                  // persist the main repository's grant, so reopening it later
                  // doesn't prompt for the folder a second time.
                  mainRepoPath: grants.mainRepoPath ?? '',
                  mainRepoBookmarkData: grants.newMainRepoBookmark ?? '',
                  fsmonitorEnabled: _fsmonitor,
                  // Empty for an ordinary repo; the external git-dir for a
                  // scoped (dotfiles) repo, so reopening re-registers the scope.
                  gitDir: gitDir,
                ),
              );
          if (!mounted) return;
          ref.invalidate(savedLocalReposProvider);
        } catch (e) {
          if (mounted) {
            setState(() {
              _saveWarning =
                  'Could not save this repository — it stays open for this '
                  "session, but won't appear in Local Repositories. ($e)";
            });
          }
        }
      }
      if (!mounted) return;
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.pop();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Whether Open can fire. Local needs a folder (and a git-dir when scoped);
  /// remote additionally needs its connection dialed and ready.
  bool get _canSubmit {
    if (_pickedPath == null || _submitting) return false;
    if (_isLocal) return !_scoped || _gitDir.text.trim().isNotEmpty;
    return !_provisioning && _provisionToken != null;
  }

  @override
  Widget build(BuildContext context) {
    final (phase, error) = ref.watch(
      connectionProvider.select((c) => (c.phase, c.error)),
    );
    final conns = ref.watch(savedConnectionsProvider).value ?? const [];
    final typography = MacosTheme.of(context).typography;
    // Only the local open drives a `connecting` phase we should replace the
    // button with a spinner for. A provisioned remote session also sits at
    // `connecting` for its whole lifetime — its inline "Connecting…" row and
    // the disabled Open button cover that instead.
    final localConnecting = _isLocal && phase == ConnectionPhase.connecting;

    return SizedSheet(
      width: kSheetWidth,
      // Scroll when the content exceeds the sheet's max height (SizedSheet caps
      // it near the window height) — the location list + scoped-repo git-dir
      // field can push a short window over. Mirrors the SSH form's body.
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Add Existing Repository',
                      style: typography.title2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ToolIconButton(
                    icon: CupertinoIcons.xmark,
                    tooltip: 'Close',
                    size: 16,
                    // Popping disposes this State, which aborts any connection
                    // dialed only to browse (see [dispose]).
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SheetDescription(
                'Adds a Git repository that already exists — on this Mac or on '
                'a saved SSH host — and makes it the active workspace. Nothing '
                'is copied or changed.',
              ),
              const SizedBox(height: 16),
              Text('Location', style: typography.caption1),
              const SizedBox(height: 4),
              MacosPopupButton<String?>(
                value: _connectionId,
                onChanged: _submitting ? null : _onLocationChanged,
                items: [
                  const MacosPopupMenuItem<String?>(
                    value: null,
                    child: Text('Local (this Mac)'),
                  ),
                  for (final c in conns)
                    MacosPopupMenuItem<String?>(
                      value: c.id,
                      child: Text(c.displayName),
                    ),
                ],
              ),
              FieldHint(
                _isLocal
                    ? 'The repository already exists on this Mac\'s own '
                          'filesystem.'
                    : 'The repository already exists on the selected SSH host — '
                          'browse its filesystem to pick it.',
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
              const SizedBox(height: 16),
              Text('Folder', style: typography.caption1),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: MacosColors.separatorColor),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _pickedPath ?? 'No folder chosen',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typography.body.copyWith(
                          color: _pickedPath == null
                              ? MacosColors.systemGrayColor
                              : null,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AppPushButton(
                    controlSize: ControlSize.regular,
                    secondary: true,
                    onPressed: (_picking || (!_isLocal && _provisioning))
                        ? null
                        : (_isLocal ? _pickFolder : _browseRemote),
                    child: Text(_isLocal ? 'Choose…' : 'Browse…'),
                  ),
                ],
              ),
              FieldHint(
                _isLocal
                    ? 'Pick the repository\'s root folder (the one containing '
                          '.git).'
                    : 'Browse the host and pick the repository\'s root folder '
                          '(the one containing .git).',
              ),
              const SizedBox(height: 16),
              if (_isLocal)
                ..._localOptions(typography)
              else
                ..._remoteOptions(typography),
              const SizedBox(height: 20),
              if (localConnecting)
                const Center(child: ProgressCircle())
              else
                AppPushButton(
                  controlSize: ControlSize.large,
                  onPressed: _canSubmit ? _submit : null,
                  child: const Text('Open'),
                ),
              if (_saveWarning != null) ...[
                const SizedBox(height: 12),
                Text(
                  _saveWarning!,
                  style: typography.body.copyWith(
                    color: MacosColors.systemOrangeColor,
                  ),
                ),
              ],
              if (phase == ConnectionPhase.error && error != null) ...[
                const SizedBox(height: 16),
                Text(
                  error,
                  style: typography.body.copyWith(
                    color: MacosColors.systemRedColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Local-pick options: save toggle (+ inline label), fsmonitor, and the
  /// scoped work-tree (dotfiles) toggle with its git-dir field.
  List<Widget> _localOptions(MacosTypography typography) => [
    Row(
      children: [
        MacosSwitch(value: _save, onChanged: (v) => setState(() => _save = v)),
        const SizedBox(width: 8),
        Text('Save repository', style: typography.body),
        if (_save) ...[
          const SizedBox(width: 12),
          Expanded(
            child: MacosTextField(
              controller: _label,
              placeholder: 'Label (optional)',
              placeholderStyle: kAppPlaceholderStyle,
              decoration: kAppTextFieldDecoration,
              focusedDecoration: kAppTextFieldFocusedDecoration,
            ),
          ),
        ],
      ],
    ),
    const FieldHint(
      'Remembers this repository in the Connections list for quick '
      'reopening — the label is its display name there.',
    ),
    const SizedBox(height: 12),
    _fsmonitorRow(typography),
    const FieldHint(
      'Turns on git\'s filesystem monitor daemon in this repository — speeds '
      'up status on big working trees.',
    ),
    const SizedBox(height: 12),
    Row(
      children: [
        MacosSwitch(
          value: _scoped,
          onChanged: (v) => setState(() => _scoped = v),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Scoped work-tree repo (dotfiles)',
            style: typography.body,
          ),
        ),
      ],
    ),
    const FieldHint(
      'For a bare / separate-git-dir repo whose work tree is the folder '
      'above — e.g. a ~/.home.git dotfiles repo with \$HOME as its work tree. '
      'Targets the external git-dir and watches only tracked files, never the '
      'whole tree.',
    ),
    if (_scoped) ...[
      const SizedBox(height: 8),
      MacosTextField(
        controller: _gitDir,
        placeholder: 'Git directory — e.g. /Users/you/.home.git',
        placeholderStyle: kAppPlaceholderStyle,
        decoration: kAppTextFieldDecoration,
        focusedDecoration: kAppTextFieldFocusedDecoration,
        // Re-evaluate the Open button as the git-dir is typed.
        onChanged: (_) => setState(() {}),
      ),
    ],
  ];

  /// Remote-pick options: a label field (the repo is always registered into the
  /// chosen connection) and fsmonitor. No save toggle (registration is inherent
  /// to finalize) and no scoped toggle (that lives on the connection form).
  List<Widget> _remoteOptions(MacosTypography typography) => [
    Text('Label (optional)', style: typography.caption1),
    const SizedBox(height: 4),
    MacosTextField(
      controller: _label,
      placeholder: 'Friendly name',
      placeholderStyle: kAppPlaceholderStyle,
      decoration: kAppTextFieldDecoration,
      focusedDecoration: kAppTextFieldFocusedDecoration,
    ),
    const FieldHint(
      'Shown in the Connections list; falls back to the folder name when '
      'empty.',
    ),
    const SizedBox(height: 12),
    _fsmonitorRow(typography),
    const FieldHint(
      'Turns on git\'s filesystem monitor daemon in this repository — speeds '
      'up status on big working trees.',
    ),
  ];

  Widget _fsmonitorRow(MacosTypography typography) => Row(
    children: [
      MacosSwitch(
        value: _fsmonitor,
        onChanged: (v) => setState(() => _fsmonitor = v),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          'Enable filesystem monitor (faster status on large repos)',
          style: typography.body,
        ),
      ),
    ],
  );
}
