import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
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

/// Whether [layout] is a scoped/dotfiles repo shape: the git-dir lives *outside*
/// the work tree — a bare repo, a `--separate-git-dir`, or a `~/.home.git`-style
/// gitfile redirect — as opposed to an ordinary `<toplevel>/.git` subdirectory.
///
/// This is git's own resolved view (from `git rev-parse`, which follows the
/// `.git` gitfile and honors `core.worktree`), so no env injection is needed to
/// obtain it. Linked worktrees and submodules also carry an out-of-tree common
/// dir but are NOT dotfiles repos — excluded explicitly. Drives the add sheet's
/// auto-detection; the paths compared are both absolute and symlink-resolved
/// (`--path-format=absolute`), so the string compare is reliable.
bool isScopedRepoLayout(RepoLayout layout) =>
    !layout.isLinkedWorktree &&
    !layout.isSubmodule &&
    layout.gitCommonDir != '${layout.toplevel}/.git';

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
  /// Pre-seeds the picked folder, as if the user had already chosen it — used
  /// by tests (the native picker can't run under `flutter test`) and callers
  /// that already know the target folder. Does NOT trigger auto-detection;
  /// only an actual pick (or the scoped toggle) probes.
  final String? initialPickedPath;

  const AddExistingRepoSheet({super.key, this.initialPickedPath});

  @override
  ConsumerState<AddExistingRepoSheet> createState() =>
      _AddExistingRepoSheetState();
}

class _AddExistingRepoSheetState extends ConsumerState<AddExistingRepoSheet> {
  final _label = TextEditingController();
  final _gitDir = TextEditingController();

  /// Location: null = this Mac (local), else a saved SSH connection's id.
  String? _connectionId;

  late String? _pickedPath = widget.initialPickedPath;
  bool _save = true;
  bool _fsmonitor = false;

  /// Scoped work-tree (dotfiles) repo: the picked folder is the work tree and
  /// [_gitDir] the external git-dir (e.g. a `~/.home.git` nested inside `$HOME`).
  /// Available for both a local pick and a remote one — the primary target is a
  /// dotfiles repo on a saved SSH host. Normally set by [_autoDetectScope]; the
  /// user can still flip it (which sets [_scopedManual] and stops auto-detect
  /// from touching it) for the pure-bare case git can't discover from the tree.
  bool _scoped = false;

  /// True once the user has operated the scoped toggle themselves — from then
  /// on [_autoDetectScope] leaves the toggle and git-dir alone.
  bool _scopedManual = false;
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
      // Scope state is per-host: a git-dir detected (or typed) for one
      // location is meaningless on another, and a manual override there
      // shouldn't suppress auto-detection here.
      _scoped = false;
      _scopedManual = false;
      _gitDir.clear();
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
    // Capture the notifier BEFORE the (seconds-long) dial so the guard below can
    // still tear the session down if the widget is disposed mid-dial — `ref` is
    // unusable after dispose, but the controller outlives the sheet.
    final notifier = ref.read(connectionProvider.notifier);
    final token = await notifier.beginProvisioning(conn);
    if (!mounted || _connectionId != conn.id) {
      // The sheet closed, or the Location switched to a different host, while
      // this host was still dialing. Don't adopt the session: adopting it under
      // a now-different `_connectionId` would finalize this host's repo into the
      // OTHER connection, and leaving it un-adopted strands a live client at
      // phase:connecting (a buttonless "Connecting…" tab). Abort it instead.
      if (token != null) await notifier.abortProvisioning(token);
      if (mounted) setState(() => _provisioning = false);
      return false;
    }
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
      if (!mounted || path == null) return;
      setState(() => _pickedPath = path);
      await _autoDetectScope(path);
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
      if (picked == null || !mounted) return;
      setState(() => _pickedPath = picked);
      await _autoDetectScope(picked);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Reads [path]'s actual git layout — git's own discovery, which follows a
  /// `.git` gitfile redirect and honors `core.worktree` with no env injection —
  /// and turns the scoped toggle on (pre-filling the git-dir) when the git-dir
  /// lives outside the work tree: a bare repo, `--separate-git-dir`, or a
  /// dotfiles redirect like `~/.home.git`. Runs while the picker is busy so the
  /// Open button never lights up mid-detection.
  ///
  /// When native discovery fails, one shape still identifies itself: a `.git`
  /// gitfile redirect to a **bare** git-dir (`git init --bare ~/.home.git` +
  /// `gitdir: ~/.home.git`) — bare has no work tree, so `--show-toplevel`
  /// dies unscoped, but the redirect file names the git-dir. That candidate is
  /// validated with [GitService.scopedRepoLayout], the same env overlay the
  /// eventual scope registration injects, before anything is pre-filled.
  ///
  /// Best-effort and silent: a folder neither path can resolve (a bare git-dir
  /// with no redirect at all, or not a repo) simply leaves the toggle to the
  /// user. A user who has already touched the toggle ([_scopedManual]) is
  /// never overridden.
  Future<void> _autoDetectScope(String path) async {
    if (_scopedManual) return;
    bool external = false;
    var gitDir = '';
    try {
      final git = await _probeService();
      final layout = await git.detectRepoLayout(path);
      if (layout != null) {
        external = isScopedRepoLayout(layout);
        if (external) gitDir = layout.gitCommonDir;
      }
    } catch (_) {
      // Not a discoverable repo (redirect-less bare, empty folder, probe
      // failure) — the manual toggle stays available.
      external = false;
    }
    if (!mounted || _scopedManual) return;
    setState(() {
      _scoped = external;
      // The fsmonitor daemon is never valid on a scoped repo — see
      // [_fsmonitorSection].
      if (external) _fsmonitor = false;
      _gitDir.text = gitDir;
    });
  }

  /// The GitService the detection probes run through: a fresh local-executor
  /// service for a local pick (which can run before any connect — the shared
  /// executor's augmented PATH is ensured first so a bare `git` resolves), or
  /// the live service for a provisioned remote browse.
  Future<GitService> _probeService() async {
    if (_isLocal) {
      await ref.read(localEnvironmentProvider).ensure();
      return GitService(ref.read(localExecutorProvider));
    }
    return ref.read(gitServiceProvider);
  }

  /// Fill-only companion to [_autoDetectScope] for the manual path: the user
  /// just switched the scoped toggle on themselves — from that moment
  /// [_scopedManual] stops auto-detect from ever flipping the toggle, but an
  /// empty git-dir field is still worth probing for them. Never changes the
  /// toggle; fills the field only if it is still empty (and the sheet still
  /// scoped) when the probe lands, so anything the user typed meanwhile wins.
  Future<void> _prefillGitDir() async {
    final path = _pickedPath;
    if (path == null || _gitDir.text.trim().isNotEmpty) return;
    final String gitDir;
    try {
      final git = await _probeService();
      final layout = await git.detectRepoLayout(path);
      if (layout == null || !isScopedRepoLayout(layout)) return;
      gitDir = layout.gitCommonDir;
    } catch (_) {
      return;
    }
    if (!mounted || !_scoped || _gitDir.text.trim().isNotEmpty) return;
    setState(() => _gitDir.text = gitDir);
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
            gitDir: _scoped ? _gitDir.text.trim() : '',
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

  /// Whether Open can fire. Both modes need a folder (and a git-dir when
  /// scoped); remote additionally needs its connection dialed and ready.
  bool get _canSubmit {
    if (_pickedPath == null || _submitting) return false;
    if (_scoped && _gitDir.text.trim().isEmpty) return false;
    if (_isLocal) return true;
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
                // Disabled while a host is still dialing: switching mid-dial
                // otherwise adopts the in-flight session under the newly
                // selected connection. The post-await guard in
                // [_ensureProvisioned] is the backstop; this removes the race
                // at the UI level so it can't be triggered at all.
                onChanged: (_submitting || _provisioning)
                    ? null
                    : _onLocationChanged,
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
    ..._fsmonitorSection(typography),
    const SizedBox(height: 12),
    ..._scopedSection(typography),
  ];

  /// Remote-pick options: a label field (the repo is always registered into the
  /// chosen connection), fsmonitor, and the scoped work-tree toggle — the same
  /// dotfiles support as local (its primary target is a ~/.home.git on a host).
  /// No save toggle: registration is inherent to finalize.
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
    ..._fsmonitorSection(typography),
    const SizedBox(height: 12),
    ..._scopedSection(typography),
  ];

  /// The scoped work-tree (dotfiles) toggle and its git-dir field, shared by
  /// both the local and remote option blocks.
  List<Widget> _scopedSection(MacosTypography typography) => [
    Row(
      children: [
        MacosSwitch(
          value: _scoped,
          onChanged: (v) {
            setState(() {
              _scoped = v;
              // The user has taken control; stop auto-detect from flipping
              // the toggle back.
              _scopedManual = true;
              // fsmonitor is never valid on a scoped repo — see
              // [_fsmonitorSection], which is also disabled while scoped.
              if (v) _fsmonitor = false;
            });
            // Toggled on with a folder already picked: probe it for the
            // git-dir so the user isn't left typing a path detection can find.
            if (v) unawaited(_prefillGitDir());
          },
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Scoped work-tree repo (dotfiles)',
            style: typography.body,
          ),
        ),
        // Auto-detect set this from the folder's real git layout; the toggle and
        // git-dir stay editable so the user can correct or override.
        if (_scoped && !_scopedManual)
          Text(
            'auto-detected',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
      ],
    ),
    const FieldHint(
      'For a bare / separate-git-dir repo whose work tree is the folder '
      'above — e.g. a ~/.home.git dotfiles repo with \$HOME as its work tree. '
      'Detected automatically from the folder; targets the external git-dir and '
      'watches only tracked files, never the whole tree.',
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

  /// The fsmonitor toggle + hint, shared by both option blocks. Disabled (and
  /// forced off) while the scoped toggle is on: the daemon would index the
  /// entire work tree — for a dotfiles repo that is all of `$HOME`, the exact
  /// cost the bounded tracked-file watch exists to avoid — and git refuses to
  /// run it against a bare git-dir anyway.
  List<Widget> _fsmonitorSection(MacosTypography typography) => [
    Row(
      children: [
        MacosSwitch(
          value: _fsmonitor,
          onChanged: _scoped ? null : (v) => setState(() => _fsmonitor = v),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Enable filesystem monitor (faster status on large repos)',
            style: typography.body.copyWith(
              color: _scoped ? MacosColors.systemGrayColor : null,
            ),
          ),
        ),
      ],
    ),
    FieldHint(
      _scoped
          ? 'Not available for a scoped work-tree repo — the monitor would '
                'index the entire work tree (e.g. all of your home folder). '
                'Scoped repos watch only tracked files instead.'
          : 'Turns on git\'s filesystem monitor daemon in this repository — '
                'speeds up status on big working trees.',
    ),
  ];
}
