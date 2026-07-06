import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/storage/saved_connection.dart';
import '../../core/storage/saved_local_repo.dart';
import '../common/actions.dart';
import '../common/field_styles.dart';
import '../common/tool_icon_button.dart';
import '../connection/local_repo_form.dart';

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
    final (isConnected, host, connectionLabel) = ref.watch(
      connectionProvider.select((c) => (c.isConnected, c.host, c.connectionLabel)),
    );
    final saved = ref.watch(savedConnectionsProvider).value ?? const [];
    final savedLocal = ref.watch(savedLocalReposProvider).value ?? const [];
    if (!isConnected && saved.isEmpty && savedLocal.isEmpty) {
      return const SizedBox.shrink();
    }

    // `host` is SSH-only (null for a local session) — fall back to the
    // connection's label (set for both backends) before the generic default.
    final label = isConnected ? (host ?? connectionLabel ?? 'Connected') : 'Connections';

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: MacosColors.separatorColor)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      child: PushButton(
        controlSize: ControlSize.large,
        secondary: true,
        onPressed: () => showMacosSheet<void>(
          context: context,
          builder: (_) => const ConnectionsPanel(),
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
      child: PushButton(
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
    );
  }
}

/// One pane of glass for connections and their repositories: each connection is
/// a group with its repos nested beneath it. Tap a repo to connect/switch there;
/// add/delete connections and repos inline.
class ConnectionsPanel extends ConsumerWidget {
  const ConnectionsPanel({super.key});

  // Accent for the active connection/repo.
  static const _accent = MacosColors.systemBlueColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    return MacosSheet(
      child: SizedBox(
        width: 540,
        height: 500,
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
                    icon: CupertinoIcons.xmark,
                    tooltip: 'Close',
                    size: 16,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: MacosColors.separatorColor),
            Expanded(
              child: empty
                  ? _empty(context, ref)
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      children: [
                        if (showAdhoc) _adhocGroup(context, ref, connection),
                        for (final c in saved)
                          _connectionGroup(context, ref, c, connection),
                        if (showAdhocLocal || savedLocal.isNotEmpty) ...[
                          _localReposHeader(context),
                          if (showAdhocLocal)
                            _adhocLocalGroup(context, ref, connection),
                          for (final repo in savedLocal)
                            _localRepoTile(context, ref, repo, connection),
                        ],
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
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 4),
      child: Text(
        'Local Repositories',
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
          PushButton(
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openRepo(context, ref, conn, conn.repoPath),
          child: Container(
            color: isActive ? _accent.withValues(alpha: 0.10) : null,
            padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
            child: Row(
              children: [
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
        for (final repo in repos)
          _repoTile(context, ref, conn, repo, connection, repos.length),
        _addRepoRow(context, ref, conn),
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
      child: GestureDetector(
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
                  _basename(repo),
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
    return GestureDetector(
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
      child: GestureDetector(
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
              if (isActive)
                const MacosIcon(
                  CupertinoIcons.checkmark_alt,
                  size: 13,
                  color: _accent,
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
    final notifier = ref.read(connectionProvider.notifier);
    final connection = ref.read(connectionProvider);
    Navigator.of(context).pop();
    if (conn.id == connection.connectionId) {
      if (repo != connection.repoPath) notifier.setRepoPath(repo);
    } else {
      notifier.connectToSaved(conn, repoPath: repo);
    }
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
            // Also drop the removed repo from fsmonitorPaths — otherwise the
            // persisted profile keeps a stale fsmonitor entry pointing at a
            // path no longer in repoPaths.
            conn
                .copyWith(repoPath: newDefault, repoPaths: remaining)
                .withFsmonitor(repo, false),
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
    final result = await showMacosSheet<(String, bool)>(
      context: context,
      builder: (_) => const AddRepositorySheet(),
    );
    if (result == null || !context.mounted) return;
    final (path, fsmonitor) = result;
    if (path.isEmpty) return;
    final updated = conn
        .copyWith(repoPaths: {...conn.allRepoPaths, path}.toList())
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
    final notifier = ref.read(connectionProvider.notifier);
    Navigator.of(context).pop();
    notifier.disconnect(); // reveals the connection form
  }

  void _newLocalRepo(BuildContext context) {
    Navigator.of(context).pop();
    showMacosSheet<void>(
      context: context,
      builder: (_) => const NewLocalRepoSheet(),
    );
  }

  Future<void> _openLocalRepo(
    BuildContext context,
    WidgetRef ref,
    SavedLocalRepo repo,
  ) async {
    final notifier = ref.read(connectionProvider.notifier);
    final connection = ref.read(connectionProvider);
    // Already *connected* to this exact repo — just close the panel. Gated on
    // isConnected (not merely a matching id): after a failed open the state
    // still carries this repo's id in the `error` phase, and without the phase
    // check a retap would no-op instead of retrying.
    if (connection.isConnected &&
        connection.isLocal &&
        connection.connectionId == repo.id) {
      Navigator.of(context).pop();
      return;
    }
    // Keep the panel OPEN across resolution (don't pop first): a failed resolve
    // shows an error dialog, which needs this context still mounted.
    final path = await resolveSavedLocalRepoPath(context, repo);
    if (path == null) return; // access could not be restored; dialog shown
    // Resolution succeeded — now dismiss the panel and open the repo.
    if (context.mounted) Navigator.of(context).pop();
    await notifier.connectLocal(
      path,
      label: repo.label.isEmpty ? null : repo.label,
      id: repo.id,
    );
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
    // Apply live only when this repo is the active session — re-read now,
    // not before the await, since the active session may have changed while
    // the metadata write was in flight.
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
  bool _fsmonitor = false;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return MacosSheet(
      child: SizedBox(
        width: 480,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Add repository', style: typography.title2),
              const SizedBox(height: 12),
              Text(
                'Absolute path on the connected host',
                style: typography.caption1,
              ),
              const SizedBox(height: 4),
              MacosTextField(
                controller: _path,
                placeholder: '/srv/git/another-project',
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
                onChanged: (_) => setState(() {}),
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
                  PushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  PushButton(
                    controlSize: ControlSize.large,
                    onPressed: _path.text.trim().isEmpty
                        ? null
                        : () => Navigator.of(
                            context,
                          ).pop((_path.text.trim(), _fsmonitor)),
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
