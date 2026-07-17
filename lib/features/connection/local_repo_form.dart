import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/local/linked_worktree_probe.dart';
import '../../core/local/scoped_access.dart';
import '../../core/local/security_scoped_bookmark.dart';
import '../../core/providers/app_providers.dart';
import '../../core/storage/saved_local_repo.dart';
import '../common/actions.dart';
import '../common/buttons.dart';
import '../common/field_styles.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';

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

/// Sheet for opening a repo on this machine's own filesystem. Much simpler
/// than [ConnectionForm]: no host/auth fields — a folder is picked through
/// the native Finder panel (the only way to gain a sandbox access grant for
/// it at all, not just a UX nicety) and validation is whatever
/// [ConnectionController.connectLocal]'s own `validateRepoPath` call already
/// surfaces as a connect error, reusing the same error-display convention.
class NewLocalRepoSheet extends ConsumerStatefulWidget {
  const NewLocalRepoSheet({super.key});

  @override
  ConsumerState<NewLocalRepoSheet> createState() => _NewLocalRepoSheetState();
}

class _NewLocalRepoSheetState extends ConsumerState<NewLocalRepoSheet> {
  final _label = TextEditingController();
  String? _pickedPath;
  bool _save = true;
  bool _fsmonitor = false;
  bool _picking = false;
  bool _submitting = false;
  String? _saveWarning;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
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

  Future<void> _open() async {
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

  @override
  Widget build(BuildContext context) {
    final (phase, error) = ref.watch(
      connectionProvider.select((c) => (c.phase, c.error)),
    );
    final typography = MacosTheme.of(context).typography;

    return SizedSheet(
      width: kSheetWidth,
      child: SizedBox(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Add Local Repository', style: typography.title2),
                  const Spacer(),
                  ToolIconButton(
                    icon: CupertinoIcons.xmark,
                    tooltip: 'Close',
                    size: 16,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SheetDescription(
                'Opens a Git repository that already exists on this Mac and '
                'makes it the active workspace — nothing is copied or '
                'changed.',
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
                    onPressed: _picking ? null : _pickFolder,
                    child: const Text('Choose…'),
                  ),
                ],
              ),
              const FieldHint(
                'Pick the repository\'s root folder (the one containing '
                '.git).',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  MacosSwitch(
                    value: _save,
                    onChanged: (v) => setState(() => _save = v),
                  ),
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
                'Remembers this repository in the Connections list for '
                'quick reopening — the label is its display name there.',
              ),
              const SizedBox(height: 12),
              Row(
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
              ),
              const FieldHint(
                'Turns on git\'s filesystem monitor daemon in this '
                'repository — speeds up status on big working trees.',
              ),
              const SizedBox(height: 20),
              if (phase == ConnectionPhase.connecting)
                const Center(child: ProgressCircle())
              else
                AppPushButton(
                  controlSize: ControlSize.large,
                  onPressed: (_pickedPath != null && !_submitting)
                      ? _open
                      : null,
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
}
