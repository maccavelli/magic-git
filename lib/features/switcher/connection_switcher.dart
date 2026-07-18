import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/local/scoped_access.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/storage/saved_connection.dart';
import '../../core/storage/saved_local_repo.dart';
import '../common/actions.dart';
import '../common/buttons.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/hover_pop.dart';
import '../common/label_chip.dart';
import '../common/sized_sheet.dart';
import '../common/tappable.dart';
import '../common/tool_icon_button.dart';
import '../connection/local_repo_form.dart';
import '../tabs/tabs_controller.dart';
import '../workspace/clone_sheet.dart';
import '../workspace/create_repo_sheet.dart';
import 'edit_entry_sheets.dart';

String _basename(String path) {
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

/// Bottom-of-sidebar control: a single Connections button that opens the
/// consolidated connections + repositories management panel.
class ConnectionSwitcher extends ConsumerWidget {
  const ConnectionSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (isConnected, isLocal, host, connectionLabel) = ref.watch(
      connectionProvider.select(
        (c) => (c.isConnected, c.isLocal, c.host, c.connectionLabel),
      ),
    );
    final saved = ref.watch(savedConnectionsProvider).value ?? const [];
    final savedLocal = ref.watch(savedLocalReposProvider).value ?? const [];
    if (!isConnected && saved.isEmpty && savedLocal.isEmpty) {
      return const SizedBox.shrink();
    }

    // For a remote session show the server (`host`). For a local one, show
    // "Local" rather than the connection label — the label is the repo name,
    // which is already displayed above this button (in CurrentRepoIndicator), so
    // repeating it here is redundant.
    final label = !isConnected
        ? 'Connections'
        : isLocal
        ? 'Local'
        : (host ?? connectionLabel ?? 'Connected');

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: MacosColors.separatorColor)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      // Same pop-on-hover / press-in microinteraction as the landing screen's
      // buttons — the two bottom-of-sidebar controls share that prominence.
      child: HoverPop(
        child: AppPushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => showMacosSheet<void>(
            context: context,
            builder: (_) => const EscapeDismissible(child: ConnectionsPanel()),
          ),
          child: Row(
            children: [
              // White reads far more clearly than the default accent-blue tint
              // against this button's fill.
              const MacosIcon(
                CupertinoIcons.rectangle_stack,
                size: 15,
                color: MacosColors.white,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MacosTheme.of(context).typography.body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sidebar button directly beneath [ConnectionSwitcher] that ends the current
/// session and returns to the connection card. Styled identically to the
/// connections-manager button (same large secondary [PushButton] in a top-
/// bordered, padded container) so the two read as one bottom nav stack.
class LogoutButton extends ConsumerWidget {
  const LogoutButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: MacosColors.separatorColor)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      // Same pop-on-hover / press-in microinteraction as the landing screen's
      // buttons (and the connections button above) — one bottom nav stack,
      // one motion language.
      child: HoverPop(
        child: AppPushButton(
          controlSize: ControlSize.large,
          secondary: true,
          // Returns to ConnectionLanding: disconnect() drops the session, which
          // flips `connected` false in the shell and pins content to the card.
          onPressed: () => ref.read(connectionProvider.notifier).disconnect(),
          child: Row(
            children: [
              // White for parity with the connections-manager button's icon,
              // which reads more clearly than the default accent tint here.
              const MacosIcon(
                CupertinoIcons.square_arrow_right,
                size: 15,
                color: MacosColors.white,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Logout',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MacosTheme.of(context).typography.body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One pane of glass for connections and their repositories: each connection is
/// a group with its repos nested beneath it. Tap a repo to connect/switch there;
/// add/delete connections and repos inline.
class ConnectionsPanel extends ConsumerStatefulWidget {
  const ConnectionsPanel({super.key});

  @override
  ConsumerState<ConnectionsPanel> createState() => _ConnectionsPanelState();
}

class _ConnectionsPanelState extends ConsumerState<ConnectionsPanel> {
  // Accent for the active connection/repo.
  static const _accent = MacosColors.systemBlueColor;

  /// Connection ids whose repository list is expanded. A connection row is a
  /// disclosure toggle — connecting happens by clicking a *repository* inside
  /// the expanded group, never the connection itself.
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    // Start with the active connection's repositories visible — that's the
    // group the user is most likely here to switch within.
    final activeId = ref.read(connectionProvider).connectionId;
    if (activeId != null) _expanded.add(activeId);
  }

  void _toggleExpanded(String id) {
    setState(() {
      if (!_expanded.add(id)) _expanded.remove(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(savedConnectionsProvider).value ?? const [];
    final savedLocal = ref.watch(savedLocalReposProvider).value ?? const [];
    final connection = ref.watch(connectionProvider);
    final typography = MacosTheme.of(context).typography;
    final showAdhoc =
        connection.isConnected && !connection.isLocal && connection.connectionId == null;
    final showAdhocLocal =
        connection.isConnected && connection.isLocal && connection.connectionId == null;
    final empty =
        saved.isEmpty && savedLocal.isEmpty && !showAdhoc && !showAdhocLocal;

    return SizedSheet(
      width: kSheetWidth,
      // Capped to the viewport so the footer stays reachable at the app's
      // minimum window size — the connection list scrolls instead.
      height: (MediaQuery.sizeOf(context).height - 80).clamp(320.0, 500.0),
      child: SizedBox(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
              child: Row(
                children: [
                  Text('Connections', style: typography.title2),
                  const Spacer(),
                  ToolIconButton(
                    icon: CupertinoIcons.add,
                    tooltip: 'Add connection',
                    size: 16,
                    onPressed: () => _newConnection(context, ref),
                  ),
                  const SizedBox(width: 4),
                  ToolIconButton(
                    icon: CupertinoIcons.folder_badge_plus,
                    tooltip: 'Add local repository',
                    size: 16,
                    onPressed: () => _newLocalRepo(context),
                  ),
                  const SizedBox(width: 4),
                  ToolIconButton(
                    icon: CupertinoIcons.cloud_download,
                    tooltip: 'Clone repository',
                    size: 16,
                    onPressed: () => _cloneRepository(context, ref),
                  ),
                  const SizedBox(width: 4),
                  ToolIconButton(
                    icon: CupertinoIcons.plus_rectangle_on_rectangle,
                    tooltip: 'Create repository',
                    size: 16,
                    onPressed: () => _createRepository(context, ref),
                  ),
                  const SizedBox(width: 4),
                  ToolIconButton(
                    icon: CupertinoIcons.xmark,
                    tooltip: 'Close',
                    size: 16,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: SheetDescription(
                'Your local repositories and saved SSH hosts. Click a host '
                'to show its repositories, then click a repository to '
                'connect. The toolbar above adds a connection or local '
                'repo, or clones/creates a repository.',
              ),
            ),
            Container(height: 1, color: MacosColors.separatorColor),
            Expanded(
              child: empty
                  ? _empty(context, ref)
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      children: [
                        if (showAdhocLocal || savedLocal.isNotEmpty) ...[
                          _localReposHeader(context),
                          if (showAdhocLocal)
                            _adhocLocalGroup(context, ref, connection),
                          for (final repo in savedLocal)
                            _localRepoTile(context, ref, repo, connection),
                        ],
                        if (showAdhoc || saved.isNotEmpty)
                          _remoteReposHeader(context),
                        if (showAdhoc) _adhocGroup(context, ref, connection),
                        for (final c in saved)
                          _connectionGroup(context, ref, c, connection),
                        const SizedBox(height: 6),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _localReposHeader(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      // First section: flush with the list top (the remote header below gets
      // the taller inset that separates the second section from the first).
      padding: const EdgeInsets.fromLTRB(16, 8, 10, 4),
      child: Text(
        'Local Repositories',
        style: typography.caption1.copyWith(
          fontWeight: FontWeight.bold,
          color: MacosColors.systemGrayColor,
        ),
      ),
    );
  }

  Widget _remoteReposHeader(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 4),
      child: Text(
        'Remote Repositories',
        style: typography.caption1.copyWith(
          fontWeight: FontWeight.bold,
          color: MacosColors.systemGrayColor,
        ),
      ),
    );
  }

  Widget _empty(BuildContext context, WidgetRef ref) {
    final typography = MacosTheme.of(context).typography;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('No saved connections', style: typography.body),
          const SizedBox(height: 12),
          AppPushButton(
            controlSize: ControlSize.large,
            onPressed: () => _newConnection(context, ref),
            child: const Text('New connection'),
          ),
        ],
      ),
    );
  }

  // ---- Connection group ----------------------------------------------------

  Widget _connectionGroup(
    BuildContext context,
    WidgetRef ref,
    SavedConnection conn,
    ConnectionState connection,
  ) {
    final typography = MacosTheme.of(context).typography;
    final isActive = conn.id == connection.connectionId;
    final repos = conn.allRepoPaths;
    final expanded = _expanded.contains(conn.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The connection row is a disclosure toggle, not a connect action —
        // it reveals the server's repositories; clicking one of those is
        // what actually connects.
        Tappable(
          behavior: HitTestBehavior.opaque,
          onTap: () => _toggleExpanded(conn.id),
          child: Container(
            color: isActive ? _accent.withValues(alpha: 0.10) : null,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Row(
              children: [
                MacosIcon(
                  expanded
                      ? CupertinoIcons.chevron_down
                      : CupertinoIcons.chevron_right,
                  size: 12,
                  color: MacosColors.systemGrayColor,
                ),
                const SizedBox(width: 6),
                MacosIcon(
                  CupertinoIcons.desktopcomputer,
                  size: 17,
                  color: isActive ? _accent : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conn.displayName,
                        style: typography.body.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${conn.username}@${conn.host}',
                        style: typography.caption1.copyWith(
                          color: MacosColors.systemGrayColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!expanded)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      '${repos.length} '
                      'repo${repos.length == 1 ? '' : 's'}',
                      style: typography.caption1.copyWith(
                        color: MacosColors.systemGrayColor,
                      ),
                    ),
                  ),
                ToolIconButton(
                  icon: CupertinoIcons.pencil,
                  tooltip: 'Edit connection',
                  size: 15,
                  onPressed: () => _editConnection(context, ref, conn),
                ),
                ToolIconButton(
                  icon: CupertinoIcons.trash,
                  tooltip: 'Delete connection',
                  size: 15,
                  color: MacosColors.systemRedColor,
                  onPressed: () => _deleteConnection(context, ref, conn),
                ),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          for (final repo in repos)
            _repoTile(context, ref, conn, repo, connection, repos.length),
          _addRepoRow(context, ref, conn),
        ],
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _repoTile(
    BuildContext context,
    WidgetRef ref,
    SavedConnection conn,
    String repo,
    ConnectionState connection,
    int repoCount,
  ) {
    final typography = MacosTheme.of(context).typography;
    final isActive =
        conn.id == connection.connectionId && repo == connection.repoPath;

    return MacosTooltip(
      message: repo,
      child: Tappable(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openRepo(context, ref, conn, repo),
        child: Container(
          color: isActive ? _accent.withValues(alpha: 0.16) : null,
          padding: const EdgeInsets.fromLTRB(40, 5, 10, 5),
          child: Row(
            children: [
              MacosIcon(
                isActive ? CupertinoIcons.folder_fill : CupertinoIcons.folder,
                size: 14,
                color: isActive ? _accent : MacosColors.systemGrayColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  conn.repoDisplayName(repo),
                  style: typography.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isActive)
                const MacosIcon(
                  CupertinoIcons.checkmark_alt,
                  size: 13,
                  color: _accent,
                ),
              ToolIconButton(
                icon: CupertinoIcons.pencil,
                tooltip: 'Edit repository',
                size: 14,
                onPressed: () => _editRepo(context, ref, conn, repo),
              ),
              ToolIconButton(
                icon: conn.fsmonitorEnabledFor(repo)
                    ? CupertinoIcons.bolt_fill
                    : CupertinoIcons.bolt,
                tooltip: conn.fsmonitorEnabledFor(repo)
                    ? 'Git fsmonitor on — faster status on large repos '
                          '(click to disable)'
                    : 'Git fsmonitor off (click to enable)',
                size: 14,
                color: conn.fsmonitorEnabledFor(repo)
                    ? _accent
                    : MacosColors.systemGrayColor,
                onPressed: () => _toggleFsmonitor(
                  context,
                  ref,
                  conn,
                  repo,
                  !conn.fsmonitorEnabledFor(repo),
                ),
              ),
              ToolIconButton(
                icon: CupertinoIcons.trash,
                tooltip: repoCount > 1
                    ? 'Remove repository'
                    : 'A connection needs at least one repository',
                size: 13,
                color: MacosColors.systemRedColor,
                onPressed: repoCount > 1
                    ? () => _deleteRepo(context, ref, conn, repo)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addRepoRow(
    BuildContext context,
    WidgetRef ref,
    SavedConnection conn,
  ) {
    final typography = MacosTheme.of(context).typography;
    return Tappable(
      behavior: HitTestBehavior.opaque,
      onTap: () => _addRepo(context, ref, conn),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 4, 10, 6),
        child: Row(
          children: [
            const MacosIcon(
              CupertinoIcons.add_circled,
              size: 13,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(width: 8),
            Text(
              'Add repository',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Active ad-hoc (unsaved) connection — read-only listing of its session repos.
  Widget _adhocGroup(
    BuildContext context,
    WidgetRef ref,
    ConnectionState connection,
  ) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
          child: Row(
            children: [
              const MacosIcon(
                CupertinoIcons.desktopcomputer,
                size: 17,
                color: _accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${connection.connectionLabel ?? 'Current'} (unsaved)',
                  style: typography.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        for (final repo in connection.repoPaths)
          MacosTooltip(
            message: repo,
            child: Container(
              color: repo == connection.repoPath
                  ? _accent.withValues(alpha: 0.16)
                  : null,
              padding: const EdgeInsets.fromLTRB(40, 5, 10, 5),
              child: Row(
                children: [
                  MacosIcon(
                    repo == connection.repoPath
                        ? CupertinoIcons.folder_fill
                        : CupertinoIcons.folder,
                    size: 14,
                    color: repo == connection.repoPath
                        ? _accent
                        : MacosColors.systemGrayColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_basename(repo), style: typography.body),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 6),
      ],
    );
  }

  // ---- Local repositories ----------------------------------------------------

  // Active ad-hoc (unsaved) local session — read-only, single entry (a local
  // session is one folder, not a host with a switchable repo list).
  Widget _adhocLocalGroup(
    BuildContext context,
    WidgetRef ref,
    ConnectionState connection,
  ) {
    final typography = MacosTheme.of(context).typography;
    final repo = connection.repoPath;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 5, 10, 5),
      child: Row(
        children: [
          const MacosIcon(
            CupertinoIcons.folder_fill,
            size: 14,
            color: _accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${connection.connectionLabel ?? (repo == null ? 'Current' : _basename(repo))} (unsaved)',
              style: typography.body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _localRepoTile(
    BuildContext context,
    WidgetRef ref,
    SavedLocalRepo repo,
    ConnectionState connection,
  ) {
    final typography = MacosTheme.of(context).typography;
    final isActive = connection.isLocal && connection.connectionId == repo.id;

    return MacosTooltip(
      message: repo.repoPath,
      child: Tappable(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openLocalRepo(context, ref, repo),
        child: Container(
          color: isActive ? _accent.withValues(alpha: 0.16) : null,
          padding: const EdgeInsets.fromLTRB(16, 5, 10, 5),
          child: Row(
            children: [
              MacosIcon(
                isActive ? CupertinoIcons.folder_fill : CupertinoIcons.folder,
                size: 14,
                color: isActive ? _accent : MacosColors.systemGrayColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  repo.displayName,
                  style: typography.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // A grant record minted by the Worktrees panel, not a repo the
              // user saved — openable as a repo, but say what it is.
              if (repo.isLinkedWorktree) ...[
                const LabelChip('worktree', color: MacosColors.systemBlueColor),
                const SizedBox(width: 4),
              ],
              if (isActive)
                const MacosIcon(
                  CupertinoIcons.checkmark_alt,
                  size: 13,
                  color: _accent,
                ),
              ToolIconButton(
                icon: CupertinoIcons.pencil,
                tooltip: 'Edit repository',
                size: 14,
                onPressed: () => _editLocalRepo(context, ref, repo),
              ),
              ToolIconButton(
                icon: repo.fsmonitorEnabled
                    ? CupertinoIcons.bolt_fill
                    : CupertinoIcons.bolt,
                tooltip: repo.fsmonitorEnabled
                    ? 'Git fsmonitor on — faster status on large repos '
                          '(click to disable)'
                    : 'Git fsmonitor off (click to enable)',
                size: 14,
                color: repo.fsmonitorEnabled
                    ? _accent
                    : MacosColors.systemGrayColor,
                onPressed: () => _toggleLocalFsmonitor(
                  context,
                  ref,
                  repo,
                  !repo.fsmonitorEnabled,
                ),
              ),
              ToolIconButton(
                icon: CupertinoIcons.trash,
                tooltip: 'Remove repository',
                size: 13,
                color: MacosColors.systemRedColor,
                onPressed: () => _deleteLocalRepo(context, ref, repo),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Actions -------------------------------------------------------------

  void _openRepo(
    BuildContext context,
    WidgetRef ref,
    SavedConnection conn,
    String repo,
  ) {
    final tabs = TabsController.current;
    if (tabs == null) {
      // No tab host (widget tests / non-main contexts): connect in place.
      final notifier = ref.read(connectionProvider.notifier);
      final connection = ref.read(connectionProvider);
      Navigator.of(context).pop();
      if (conn.id == connection.connectionId) {
        if (repo != connection.repoPath) notifier.setRepoPath(repo);
      } else {
        notifier.connectToSaved(conn, repoPath: repo);
      }
      return;
    }
    // Open (or focus) this repo in its own tab, connecting in that tab's
    // container. A repo already open on this connection is focused, not
    // re-connected; the first repo picked from a blank landing tab fills it.
    Navigator.of(context).pop();
    tabs.openOrFocus(
      connectionId: conn.id,
      repoPath: repo,
      connect: (container) => container
          .read(connectionProvider.notifier)
          .connectToSaved(conn, repoPath: repo),
    );
  }

  Future<void> _deleteConnection(
    BuildContext context,
    WidgetRef ref,
    SavedConnection conn,
  ) async {
    final ok = await confirmAction(
      context,
      title: 'Delete connection',
      message: 'Delete "${conn.displayName}" and its stored credentials?',
      confirmLabel: 'Delete',
    );
    if (!ok || !context.mounted) return;
    final notifier = ref.read(connectionProvider.notifier);
    final deleted = await runAction(context, () async {
      await ref.read(connectionStoreProvider).delete(conn.id);
      ref.invalidate(savedConnectionsProvider);
    });
    if (!deleted) return;
    // Re-read now, not the pre-await snapshot: the user may have switched to
    // a *different* connection while this delete was in flight, in which
    // case disconnecting here would tear down that unrelated, newly-active
    // session instead of the one actually being deleted.
    final isStillActive = ref.read(connectionProvider).connectionId == conn.id;
    if (isStillActive) await notifier.disconnect();
  }

  Future<void> _deleteRepo(
    BuildContext context,
    WidgetRef ref,
    SavedConnection conn,
    String repo,
  ) async {
    final remaining = conn.allRepoPaths.where((p) => p != repo).toList();
    if (remaining.isEmpty) return;
    final newDefault = conn.repoPath == repo ? remaining.first : conn.repoPath;
    final notifier = ref.read(connectionProvider.notifier);
    final saved = await runAction(context, () async {
      await ref
          .read(connectionStoreProvider)
          .updateMetadata(
            // Also drop the removed repo's per-repo metadata (fsmonitor +
            // label) — otherwise the persisted profile keeps stale entries
            // pointing at a path no longer in repoPaths.
            conn
                .copyWith(repoPath: newDefault, repoPaths: remaining)
                .withFsmonitor(repo, false)
                .withRepoLabel(repo, ''),
          );
      ref.invalidate(savedConnectionsProvider);
    });
    if (!saved) return;
    // Re-read now — the active connection/repo may have changed while the
    // metadata write was in flight.
    final current = ref.read(connectionProvider);
    if (current.connectionId == conn.id && current.repoPath == repo) {
      notifier.setRepoPath(newDefault);
    }
  }

  /// Opens the edit card for a saved connection and persists the result.
  /// Secrets the user left blank are re-supplied from the store — `save()`
  /// treats a null/empty secret as "delete", so "untouched" has to mean
  /// re-writing whatever is already stored (the same dance the connection
  /// form does when re-saving an existing profile).
  Future<void> _editConnection(
    BuildContext context,
    WidgetRef ref,
    SavedConnection conn,
  ) async {
    final result = await showMacosSheet<EditConnectionResult>(
      context: context,
      builder: (_) => EscapeDismissible(child: EditConnectionSheet(conn: conn)),
    );
    if (result == null || !context.mounted) return;
    await runAction(context, () async {
      final store = ref.read(connectionStoreProvider);
      await store.save(
        result.conn,
        secret: result.password ?? await store.secretFor(conn.id),
        privateKey: result.privateKey ?? await store.privateKeyFor(conn.id),
        passphrase: result.passphrase ?? await store.passphraseFor(conn.id),
        gitlabToken: result.gitlabToken ?? await store.gitlabTokenFor(conn.id),
        githubToken: result.githubToken ?? await store.githubTokenFor(conn.id),
      );
      ref.invalidate(savedConnectionsProvider);
    });
  }

  /// Opens the edit card for one repository entry of a connection — its
  /// friendly label, its path on the host, and its fsmonitor preference are all
  /// editable. Repointing the path (the repo moved or was renamed there)
  /// carries the label and fsmonitor across to the new path; nothing is touched
  /// on the host itself, and an active session on the old path keeps running
  /// until reconnect. An fsmonitor change with no path change is applied live
  /// (like the inline toggle); across a repoint it applies on the next connect.
  Future<void> _editRepo(
    BuildContext context,
    WidgetRef ref,
    SavedConnection conn,
    String repo,
  ) async {
    final result = await showMacosSheet<(String, String, bool)?>(
      context: context,
      builder: (_) =>
          EscapeDismissible(child: EditRemoteRepoSheet(conn: conn, repo: repo)),
    );
    if (result == null || !context.mounted) return;
    final (label, newPath, fsmonitor) = result;
    final pathChanged = newPath != repo;
    final labelChanged = label != conn.repoLabelFor(repo);
    final fsmonitorChanged = fsmonitor != conn.fsmonitorEnabledFor(repo);
    if (!pathChanged && !labelChanged && !fsmonitorChanged) return;

    var updated = conn;
    if (pathChanged) {
      // Repoint the entry and clear the old path's per-repo metadata — it no
      // longer exists in repoPaths, so a stale label/fsmonitor entry pointing
      // at it must not survive.
      updated = updated
          .copyWith(
            repoPath: conn.repoPath == repo ? newPath : conn.repoPath,
            repoPaths: [
              for (final p in conn.allRepoPaths) p == repo ? newPath : p,
            ],
          )
          .withFsmonitor(repo, false)
          .withRepoLabel(repo, '');
    }
    // Apply the (possibly edited) label + fsmonitor onto the effective path.
    final target = pathChanged ? newPath : repo;
    updated = updated.withRepoLabel(target, label).withFsmonitor(target, fsmonitor);

    final saved = await runAction(context, () async {
      await ref.read(connectionStoreProvider).updateMetadata(updated);
      ref.invalidate(savedConnectionsProvider);
    });
    if (!saved) return;
    // Apply an fsmonitor change live only when the path itself did not move —
    // same contract as _toggleFsmonitor (each git command carries its own repo
    // path). Across a repoint the new path may not be a live checkout yet, so
    // the saved preference applies on the next connect instead. Re-read the
    // connection now (not before the await): it may have switched mid-write.
    if (fsmonitorChanged &&
        !pathChanged &&
        ref.read(connectionProvider).connectionId == conn.id) {
      try {
        await ref.read(gitServiceProvider).setFsmonitor(repo, enabled: fsmonitor);
      } catch (e) {
        ref
            .read(outputLogProvider.notifier)
            .logError('fsmonitor setup ($repo)', e.toString());
      }
    }
  }

  Future<void> _toggleFsmonitor(
    BuildContext context,
    WidgetRef ref,
    SavedConnection conn,
    String repo,
    bool enabled,
  ) async {
    final saved = await runAction(context, () async {
      await ref
          .read(connectionStoreProvider)
          .updateMetadata(conn.withFsmonitor(repo, enabled));
      ref.invalidate(savedConnectionsProvider);
    });
    if (!saved) return;
    // Apply live when connected to this host — each git command carries its own
    // repo path, so fsmonitor can be (un)set on this repo even if a different
    // repo of the same connection is currently active. Best-effort: on failure
    // the saved preference still applies on the next connect. Re-read the
    // connection now (not before the await) — the active connection may have
    // changed while the metadata write was in flight, and applying this
    // command against a since-switched-to connection would tune the wrong
    // host's repo.
    if (ref.read(connectionProvider).connectionId == conn.id) {
      try {
        await ref.read(gitServiceProvider).setFsmonitor(repo, enabled: enabled);
      } catch (e) {
        ref
            .read(outputLogProvider.notifier)
            .logError('fsmonitor setup ($repo)', e.toString());
      }
    }
  }

  Future<void> _addRepo(
    BuildContext context,
    WidgetRef ref,
    SavedConnection conn,
  ) async {
    final result = await showMacosSheet<(String, String, bool)>(
      context: context,
      builder: (_) => const EscapeDismissible(child: AddRepositorySheet()),
    );
    if (result == null || !context.mounted) return;
    final (path, label, fsmonitor) = result;
    if (path.isEmpty) return;
    final updated = conn
        .copyWith(repoPaths: {...conn.allRepoPaths, path}.toList())
        .withRepoLabel(path, label)
        .withFsmonitor(path, fsmonitor);
    final saved = await runAction(context, () async {
      await ref.read(connectionStoreProvider).updateMetadata(updated);
      ref.invalidate(savedConnectionsProvider);
    });
    // Apply fsmonitor live if it was enabled at add-time and we're connected to
    // this host. Best-effort — the saved preference applies on the next
    // connect. Re-read the connection now (not before the await) — it may
    // have changed while the metadata write was in flight.
    if (saved && fsmonitor && ref.read(connectionProvider).connectionId == conn.id) {
      try {
        await ref.read(gitServiceProvider).setFsmonitor(path, enabled: true);
      } catch (e) {
        ref
            .read(outputLogProvider.notifier)
            .logError('fsmonitor setup ($path)', e.toString());
      }
    }
  }

  void _newConnection(BuildContext context, WidgetRef ref) {
    final tabs = TabsController.current;
    if (tabs == null) {
      final notifier = ref.read(connectionProvider.notifier);
      Navigator.of(context).pop();
      notifier.disconnect(); // reveals the connection form in place
      return;
    }
    // Open a fresh landing tab (the connection form) without disturbing the
    // sessions already open in other tabs.
    Navigator.of(context).pop();
    tabs.newTab();
  }

  void _newLocalRepo(BuildContext context) {
    Navigator.of(context).pop();
    showMacosSheet<void>(
      context: context,
      builder: (_) => const EscapeDismissible(child: NewLocalRepoSheet()),
    );
  }

  /// Clone/create open in connected mode when a workspace is active (they
  /// target it) and landing mode otherwise (they offer the destination
  /// picker). Not EscapeDismissible-wrapped: the sheets own their Escape
  /// handling (a running job must be cancelled first).
  void _cloneRepository(BuildContext context, WidgetRef ref) {
    final connected = ref.read(connectionProvider).isConnected;
    Navigator.of(context).pop();
    showMacosSheet<void>(
      context: context,
      builder: (_) => connected
          ? const CloneRepositorySheet.connected()
          : const CloneRepositorySheet.landing(),
    );
  }

  void _createRepository(BuildContext context, WidgetRef ref) {
    final connected = ref.read(connectionProvider).isConnected;
    Navigator.of(context).pop();
    showMacosSheet<void>(
      context: context,
      builder: (_) => connected
          ? const CreateRepositorySheet.connected()
          : const CreateRepositorySheet.landing(),
    );
  }

  Future<void> _openLocalRepo(
    BuildContext context,
    WidgetRef ref,
    SavedLocalRepo repo,
  ) async {
    final tabs = TabsController.current;
    // A tab for this saved repo is already open — focus it without re-resolving
    // the bookmark (a saved local repo's id is unique, so it identifies the
    // tab). Avoids a redundant security-scoped access on an already-open repo.
    if (tabs != null) {
      for (final t in tabs.tabs) {
        if (t.connectionId == repo.id) {
          Navigator.of(context).pop();
          tabs.activate(t.id);
          // If that tab's earlier open FAILED (or its session later dropped), a
          // retap should retry the connection, not just refocus a dead tab —
          // matching the non-tab fallback's `isConnected` guard below. Its
          // security-scoped access was already acquired and is still held (only
          // the git validation failed), and `t.repoPath` is the resolved path,
          // so reconnect on that WITHOUT re-acquiring — a second acquire here
          // would leave the refcount permanently one high.
          final conn = t.container.read(connectionProvider);
          final resolved = t.repoPath;
          if (resolved != null &&
              (conn.phase == ConnectionPhase.error ||
                  conn.phase == ConnectionPhase.lost ||
                  conn.phase == ConnectionPhase.disconnected)) {
            await t.container
                .read(connectionProvider.notifier)
                .connectLocal(
                  resolved,
                  label: repo.label.isEmpty ? null : repo.label,
                  id: repo.id,
                );
          }
          return;
        }
      }
    } else {
      final connection = ref.read(connectionProvider);
      // Already *connected* to this exact repo — just close the panel. Gated on
      // isConnected (not merely a matching id): after a failed open the state
      // still carries this repo's id in the `error` phase, and without the
      // phase check a retap would no-op instead of retrying.
      if (connection.isConnected &&
          connection.isLocal &&
          connection.connectionId == repo.id) {
        Navigator.of(context).pop();
        return;
      }
    }
    // Keep the panel OPEN across resolution (don't pop first): a failed resolve
    // shows an error dialog, which needs this context still mounted.
    final grants = await resolveSavedLocalRepo(context, repo);
    if (grants == null) return; // access could not be restored; dialog shown
    final path = grants.repoPath;
    // Resolution succeeded — now dismiss the panel and open the repo.
    if (context.mounted) Navigator.of(context).pop();
    final label = repo.label.isEmpty ? null : repo.label;
    if (tabs == null) {
      await ref
          .read(connectionProvider.notifier)
          .connectLocal(
            path,
            label: label,
            id: repo.id,
            mainRepoPath: grants.mainRepoPath,
          );
      return;
    }
    var connected = false;
    tabs.openOrFocus(
      connectionId: repo.id,
      repoPath: path,
      connect: (container) {
        connected = true;
        container
            .read(connectionProvider.notifier)
            .connectLocal(
              path,
              label: label,
              id: repo.id,
              mainRepoPath: grants.mainRepoPath,
            );
      },
    );
    if (!connected) {
      // openOrFocus did NOT start a new session: it either focused a tab a
      // racing double-open just created (its `connect` runs there, not here) or
      // declined at the tab cap. Either way the access acquired above by
      // resolveSavedLocalRepo isn't backing a session, so release it —
      // otherwise the native security-scoped grant leaks for the app's lifetime.
      // A linked worktree acquired TWO grants; both leak if only one is freed.
      await ScopedAccess.instance.release(path);
      final main = grants.mainRepoPath;
      if (main != null) await ScopedAccess.instance.release(main);
    }
  }

  Future<void> _deleteLocalRepo(
    BuildContext context,
    WidgetRef ref,
    SavedLocalRepo repo,
  ) async {
    final ok = await confirmAction(
      context,
      title: 'Remove local repository',
      message: 'Remove "${repo.displayName}" from Local Repositories?',
      confirmLabel: 'Remove',
    );
    if (!ok || !context.mounted) return;
    final notifier = ref.read(connectionProvider.notifier);
    final deleted = await runAction(context, () async {
      await ref.read(localRepoStoreProvider).delete(repo.id);
      ref.invalidate(savedLocalReposProvider);
    });
    if (!deleted) return;
    // Re-read now, not the pre-await snapshot — same reasoning as
    // _deleteConnection: the user may have switched to a different repo
    // while this delete was in flight.
    final isStillActive =
        ref.read(connectionProvider).isLocal &&
        ref.read(connectionProvider).connectionId == repo.id;
    if (isStillActive) await notifier.disconnect();
  }

  Future<void> _toggleLocalFsmonitor(
    BuildContext context,
    WidgetRef ref,
    SavedLocalRepo repo,
    bool enabled,
  ) async {
    final saved = await runAction(context, () async {
      await ref
          .read(localRepoStoreProvider)
          .updateMetadata(repo.copyWith(fsmonitorEnabled: enabled));
      ref.invalidate(savedLocalReposProvider);
    });
    if (!saved) return;
    await _applyLocalFsmonitorLive(ref, repo, enabled);
  }

  /// Opens the edit card for a saved local repo and persists the result;
  /// an fsmonitor change made in the card gets the same live application a
  /// direct toggle does.
  Future<void> _editLocalRepo(
    BuildContext context,
    WidgetRef ref,
    SavedLocalRepo repo,
  ) async {
    final result = await showMacosSheet<(String, bool)?>(
      context: context,
      builder: (_) => EscapeDismissible(child: EditLocalRepoSheet(repo: repo)),
    );
    if (result == null || !context.mounted) return;
    final (label, fsmonitor) = result;
    if (label == repo.label && fsmonitor == repo.fsmonitorEnabled) return;
    final saved = await runAction(context, () async {
      await ref
          .read(localRepoStoreProvider)
          .updateMetadata(
            repo.copyWith(label: label, fsmonitorEnabled: fsmonitor),
          );
      ref.invalidate(savedLocalReposProvider);
    });
    if (!saved || fsmonitor == repo.fsmonitorEnabled) return;
    await _applyLocalFsmonitorLive(ref, repo, fsmonitor);
  }

  /// Applies an fsmonitor change to the running git session, when this repo
  /// is the active one. Best-effort — on failure the saved preference still
  /// applies on the next open. Reads the connection *now* (not before the
  /// caller's awaits) so a session switched mid-write is never mis-targeted.
  Future<void> _applyLocalFsmonitorLive(
    WidgetRef ref,
    SavedLocalRepo repo,
    bool enabled,
  ) async {
    final connection = ref.read(connectionProvider);
    if (connection.isLocal && connection.connectionId == repo.id) {
      try {
        await ref
            .read(gitServiceProvider)
            .setFsmonitor(repo.repoPath, enabled: enabled);
      } catch (e) {
        ref
            .read(outputLogProvider.notifier)
            .logError('fsmonitor setup (${repo.repoPath})', e.toString());
      }
    }
  }
}

/// Small sheet to enter a new repository path.
class AddRepositorySheet extends StatefulWidget {
  const AddRepositorySheet({super.key});

  @override
  State<AddRepositorySheet> createState() => _AddRepositorySheetState();
}

class _AddRepositorySheetState extends State<AddRepositorySheet> {
  final _path = TextEditingController();
  final _label = TextEditingController();
  bool _fsmonitor = false;

  @override
  void dispose() {
    _path.dispose();
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return SizedSheet(
      width: kSheetWidth,
      child: SizedBox(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Add repository', style: typography.title2),
              const SheetDescription(
                'Registers another repository that already exists on the '
                'connected host, so you can switch to it from the '
                'Connections list.',
              ),
              const SizedBox(height: 12),
              Text(
                'Absolute path on the connected host',
                style: typography.caption1,
              ),
              const SizedBox(height: 4),
              MacosTextField(
                controller: _path,
                placeholder: '/srv/git/another-project',
                placeholderStyle: kAppPlaceholderStyle,
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
                onChanged: (_) => setState(() {}),
              ),
              const FieldHint(
                'The repository\'s root folder on the host (the one '
                'containing .git).',
              ),
              const SizedBox(height: 12),
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
                'Shown in the Connections list; falls back to the folder '
                'name when empty.',
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  ToolIconButton(
                    icon: _fsmonitor
                        ? CupertinoIcons.bolt_fill
                        : CupertinoIcons.bolt,
                    tooltip: _fsmonitor
                        ? 'Git fsmonitor on (click to disable)'
                        : 'Git fsmonitor off (click to enable)',
                    size: 15,
                    color: _fsmonitor
                        ? MacosColors.systemBlueColor
                        : MacosColors.systemGrayColor,
                    onPressed: () => setState(() => _fsmonitor = !_fsmonitor),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Enable git fsmonitor (faster status on large repos)',
                      style: typography.caption1,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AppPushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  AppPushButton(
                    controlSize: ControlSize.large,
                    onPressed: _path.text.trim().isEmpty
                        ? null
                        : () => Navigator.of(context).pop((
                            _path.text.trim(),
                            _label.text.trim(),
                            _fsmonitor,
                          )),
                    child: const Text('Add'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
