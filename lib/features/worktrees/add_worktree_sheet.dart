import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
import '../../core/local/security_scoped_bookmark.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/utils/host_path.dart';
import '../common/actions.dart';
import '../common/buttons.dart';
import '../common/field_styles.dart';
import '../common/labeled_controls.dart';
import '../common/labeled_text_field.dart';
import '../common/sized_sheet.dart';
import 'worktree_access.dart';
import 'worktree_paths.dart';
import 'worktree_tabs.dart';

/// How the new worktree's HEAD is chosen.
enum _Basis {
  /// Create a new branch (the common case — a worktree per piece of work).
  newBranch,

  /// Check out a branch that already exists and isn't checked out elsewhere.
  existingBranch,

  /// Detached HEAD at some revision — for reviewing or testing history without
  /// claiming a branch name.
  detached,
}

/// Creates a worktree.
///
/// Two things here exist in no other desktop Git GUI, and they are what make
/// worktrees actually usable rather than merely supported:
///
///  * **Copy ignored files.** `git worktree add` checks out *tracked* files
///    only. So a fresh worktree has no `.env`, and the project fails on first
///    run with a baffling error. This is the single most common complaint about
///    worktrees in practice; VS Code solved it (`git.worktreeIncludeFiles`) and
///    Tower, Fork and GitKraken have not.
///  * **A post-create command**, e.g. `pnpm install`, so the worktree is ready
///    to work in instead of ready to configure.
class AddWorktreeSheet extends ConsumerStatefulWidget {
  final String repoPath;

  /// Where the new worktree starts, as the opener means it. Null is the
  /// blank sheet: a new branch at HEAD.
  final WorktreeStart? start;

  const AddWorktreeSheet({super.key, required this.repoPath, this.start});

  @override
  ConsumerState<AddWorktreeSheet> createState() => _AddWorktreeSheetState();
}

/// Where a new worktree starts. Stated by the caller rather than read from
/// which of two strings is null: that encoding took a dropped commit for a
/// branch to check out, and the sheet then created a detached worktree
/// under an "Existing branch" label (0071).
sealed class WorktreeStart {
  const WorktreeStart();
}

/// Check out an existing local branch in the new worktree.
final class CheckOutBranch extends WorktreeStart {
  const CheckOutBranch(this.branch);

  /// The branch's short name, e.g. `feature/auth`.
  final String branch;
}

/// A new branch at [startPoint] — a commit, tag or branch; null is HEAD —
/// named [name], which is empty when the user is to type it.
final class NewBranchAt extends WorktreeStart {
  const NewBranchAt({this.startPoint, this.name = ''});

  final String? startPoint;
  final String name;
}

class _AddWorktreeSheetState extends ConsumerState<AddWorktreeSheet> {
  final _branch = TextEditingController();

  /// The folder the worktree will be created *inside*. This is the folder macOS
  /// authorizes — a sandbox grant covers a folder and its contents, and `git
  /// worktree add` has to create a new directory, so the permission has to be on
  /// the parent. Kept as its own field precisely so that is visible.
  final _parent = TextEditingController();

  /// The worktree's own directory name.
  final _folderName = TextEditingController();

  // Seeded from the persisted defaults in initState — the globs and the
  // post-create command are the same nearly every time, and retyping them per
  // worktree is exactly the friction that makes the feature feel like a chore.
  final _copyGlobs = TextEditingController();
  final _postCreate = TextEditingController();

  /// The revision for a detached checkout. Its own controller, deliberately NOT
  /// [_commitish]: that one is the start point handed in by the opener (a
  /// branch's "Checkout in New Worktree…", a commit's "Branch from here…") and
  /// stays fixed — typing a detached revision must not silently rewrite where a
  /// new branch would start from if the user then switches basis back.
  final _revision = TextEditingController();

  _Basis _basis = _Basis.newBranch;
  String? _existingBranch;

  /// The branches Existing branch offers, by short name — set each build
  /// from the same list the popup shows, so [_valid] and [_submit] can only
  /// accept a branch the user can see selected.
  Set<String> _offered = const {};
  String? _commitish;
  late bool _copyIgnored;
  late bool _runPostCreate;
  bool _openAfter = true;
  bool _submitting = false;

  /// True once the user has renamed the folder themselves, after which we stop
  /// re-deriving it from the branch name as they type.
  bool _nameEdited = false;

  /// The folder the user has actually granted through the picker. Until this
  /// matches [_parent], we hold no permission to create anything there.
  String? _grantedParent;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(appSettingsProvider);
    _copyGlobs.text = settings.worktreeCopyGlobs;
    _copyIgnored = settings.worktreeCopyEnabled;
    _postCreate.text = settings.worktreePostCreate;
    _runPostCreate = settings.worktreePostCreateEnabled;

    switch (widget.start) {
      case CheckOutBranch(:final branch):
        _basis = _Basis.existingBranch;
        _existingBranch = branch;
        // Also the start point should the user switch to New branch or
        // Detached: a branch's worktree starts from that branch.
        _commitish = branch;
        _revision.text = branch;
      case NewBranchAt(:final startPoint, :final name):
        _commitish = startPoint;
        _revision.text = startPoint ?? '';
        _branch.text = name;
      case null:
        break;
    }
    _parent.text = _defaultParent();
    _syncFolderName();
  }

  @override
  void dispose() {
    _branch.dispose();
    _parent.dispose();
    _folderName.dispose();
    _copyGlobs.dispose();
    _postCreate.dispose();
    _revision.dispose();
    super.dispose();
  }

  /// The full destination: the folder git will create and check the worktree
  /// into. Composed, never typed — see the two fields it is built from.
  String get _destination {
    final parent = _parent.text.trim();
    final name = _folderName.text.trim();
    if (parent.isEmpty || name.isEmpty) return '';
    return '${parent.endsWith('/') ? parent.substring(0, parent.length - 1) : parent}/$name';
  }

  /// Re-derives the folder name from the branch, until the user renames it.
  ///
  /// The conventional default is a sibling of the repo named after the branch:
  ///
  ///   ~/code/myapp             <- main worktree
  ///   ~/code/myapp-feat-auth   <- the worktree
  ///
  /// A sibling, never a subdirectory: a worktree nested inside the main repo
  /// pollutes its `git status` with a second checkout's files and confuses every
  /// tool that walks up looking for a repo root.
  void _syncFolderName() {
    if (_nameEdited) return;
    final slug = _slug(switch (_basis) {
      _Basis.newBranch => _branch.text,
      _Basis.existingBranch => _existingBranch ?? '',
      _Basis.detached =>
        _revision.text.trim().isEmpty ? 'detached' : _revision.text,
    });
    final repoName = HostPath.basename(widget.repoPath);
    _folderName.text = slug.isEmpty ? '' : '$repoName-$slug';
  }

  /// The repo's own parent — where a sibling worktree conventionally goes.
  String _defaultParent() {
    if (_style == HostPathStyle.windows) {
      return HostPath.dirname(widget.repoPath, _style);
    }
    final parts = widget.repoPath.split('/')..removeLast();
    return parts.join('/');
  }

  /// The session host's path style (0070.3).
  HostPathStyle get _style => ref.read(hostPathStyleProvider);

  /// `feature/auth` -> `feature-auth`. Slashes would create nested directories,
  /// and a branch name is otherwise a fine folder name.
  static String _slug(String branch) => branch
      .trim()
      .replaceAll(RegExp(r'[/\s]+'), '-')
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  bool get _valid {
    if (_destination.isEmpty) return false;
    return switch (_basis) {
      _Basis.newBranch => _branch.text.trim().isNotEmpty,
      _Basis.existingBranch => _offered.contains(_existingBranch),
      _Basis.detached => _revision.text.trim().isNotEmpty,
    };
  }

  /// The destination must not be inside the main worktree. git will happily do
  /// it and leave you with a nested checkout whose files show up as untracked
  /// noise in the parent's status.
  String? get _locationProblem {
    final path = _destination;
    if (path.isEmpty) return null;
    final repo = widget.repoPath;
    // Symlink-insensitive (isInsideRepo canonicalizes both sides): a /tmp
    // alias of the repo's real /private/tmp path must not slip past.
    final inside = _style == HostPathStyle.windows
        ? HostPath.isInside(path, repo, _style)
        : isInsideRepo(path, repo);
    if (inside) {
      return 'Choose a folder outside the repository — a worktree inside it '
          "would show up as untracked files in the repository's own status.";
    }
    if (!HostPath.isAbsolute(path, _style)) {
      return 'The folder to create in must be an absolute path.';
    }
    if (_folderName.text.contains('/') ||
        (_style == HostPathStyle.windows && _folderName.text.contains(r'\'))) {
      return 'The folder name cannot contain "/".';
    }
    return null;
  }

  /// Whether we hold a sandbox grant covering the folder we're about to create
  /// in. A grant covers a folder and everything under it, so an ancestor counts.
  bool get _parentGranted {
    final granted = _grantedParent;
    if (granted == null) return false;
    final parent = _parent.text.trim();
    return parent == granted || parent.startsWith('$granted/');
  }

  /// Asks macOS for permission to the "Create in" folder. The picker IS the
  /// grant — there is no other way for a sandboxed app to gain write access — so
  /// this is a required step, not a convenience, and whatever the user picks
  /// becomes the folder we create in.
  Future<bool> _grantParent() async {
    final picked = await getDirectoryPath(
      confirmButtonText: 'Grant Access',
      initialDirectory: _parent.text.trim().isEmpty
          ? _defaultParent()
          : _parent.text.trim(),
    );
    if (picked == null || !mounted) return false;
    setState(() {
      _grantedParent = picked;
      _parent.text = picked;
    });
    return true;
  }

  Future<void> _submit() async {
    if (!_valid || _submitting) return;
    final problem = _locationProblem;
    if (problem != null) {
      await showErrorDialog(context, problem);
      return;
    }

    // The pre-filled parent is a suggestion, not a permission. `git worktree
    // add` has to CREATE a directory there, and a sandboxed app can only write
    // inside folders the user has picked — the repo's own grant does NOT extend
    // to its parent. So get the grant before running git, rather than letting it
    // fail with a raw "permission denied".
    if (ref.read(connectionProvider).isLocal && !_parentGranted) {
      final granted = await _grantParent();
      if (!granted || !mounted) return;
      // The folder they picked may not be the one we suggested — re-check that
      // the worktree still isn't landing inside the repository.
      final finalProblem = _locationProblem;
      if (finalProblem != null) {
        await showErrorDialog(context, finalProblem);
        return;
      }
    }
    final path = _destination;
    setState(() => _submitting = true);

    // Remember what they actually used, so the next worktree starts from it
    // rather than from the factory default. Fire-and-forget: a failed
    // preferences write must not block creating the worktree.
    unawaited(
      ref
          .read(appSettingsProvider.notifier)
          .setWorktreeDefaults(
            copyGlobs: _copyGlobs.text,
            copyEnabled: _copyIgnored,
            postCreate: _postCreate.text,
            postCreateEnabled: _runPostCreate,
          ),
    );

    final git = ref.read(gitServiceProvider);
    final repoPath = widget.repoPath;

    // Phase 1: create the worktree. Only a failure HERE means nothing was
    // created and the sheet should stay open for another attempt.
    final created = await runAction(context, () async {
      await git.addWorktree(
        repoPath,
        path: path,
        newBranch: _basis == _Basis.newBranch ? _branch.text.trim() : null,
        commitish: switch (_basis) {
          _Basis.newBranch => _commitish,
          _Basis.existingBranch => _existingBranch,
          _Basis.detached => _revision.text.trim(),
        },
        detach: _basis == _Basis.detached,
      );
    });
    if (!mounted) return;
    if (!created) {
      setState(() => _submitting = false);
      return;
    }

    // Phase 2: the convenience steps. The worktree EXISTS from here on, so a
    // failed copy or install must NOT put the sheet back in its pre-create
    // state — resubmitting would just fail with "already exists". Each step
    // surfaces its own error dialog (with the full output in the Output
    // view), and the flow still proceeds to open the new worktree so the
    // user lands where the problem is fixable.

    // Only tracked files were checked out. Bring across the ignored ones the
    // project actually needs to run — without this the new worktree is a
    // checkout you still have to hand-configure before it will start.
    if (_copyIgnored && _copyGlobs.text.trim().isNotEmpty) {
      // Into the Output view like the post-create command below: the result
      // names every file copied (and any that failed), which is the only
      // place you can see that a glob quietly matched nothing.
      final label = 'Copy ignored files (${_copyGlobs.text.trim()})';
      final log = ref.read(outputLogProvider.notifier);
      await runAction(context, () async {
        try {
          log.logResult(
            label,
            await git.copyIgnoredFiles(
              from: repoPath,
              to: path,
              globs: _copyGlobs.text
                  .split(',')
                  .map((g) => g.trim())
                  .where((g) => g.isNotEmpty)
                  .toList(),
            ),
          );
        } on GitException catch (e) {
          log.logResult(label, e.result);
          rethrow;
        }
      });
    }

    if (mounted && _runPostCreate && _postCreate.text.trim().isNotEmpty) {
      final command = _postCreate.text.trim();
      // Into the Output view, like every other command whose output matters:
      // a `pnpm install` that fails is something you need to be able to READ,
      // not just be told about — and on success you still want the log.
      final log = ref.read(outputLogProvider.notifier);
      await runAction(context, () async {
        try {
          log.logResult(command, await git.runInWorktree(path, command));
        } on GitException catch (e) {
          log.logResult(command, e.result);
          rethrow;
        }
      });
    }
    if (!mounted) return;

    // Remember the grant, so opening this worktree later never prompts. The
    // parent-folder grant covers it; a bookmark on the worktree itself is what
    // survives a restart.
    if (ref.read(connectionProvider).isLocal) {
      final bookmark = await SecurityScopedBookmark.create(path);
      if (bookmark != null) {
        await ref.read(worktreeAccessProvider).remember(path, bookmark);
      }
    }
    if (!mounted) return;

    // The worktree list (and any new branch) changed: refresh before the tab
    // opens. The Worktrees panel judges a tab by that list, and one missing
    // from it is swept as dead — which, on a host with no file watcher to
    // refresh it first, was every tab this sheet opened (0070 D8).
    refreshAfterMutation(ref, repoPath);
    if (_openAfter) ref.read(worktreeTabsProvider.notifier).open(path);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final refs = ref.watch(refsProvider(widget.repoPath)).value ?? const [];
    final locals = refs.where((r) => r.isLocalBranch).toList();
    _offered = {for (final b in _offerable(locals)) b.shortName};
    final problem = _locationProblem;

    return SizedSheet(
      width: 520,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The fields scroll; Cancel and Create Worktree do not. As one
            // unscrolled column the sheet needed ~610 px of window, and the
            // app allows 480: below that the buttons were simply not
            // visible (0071; the same fix as local_repo_form.dart).
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Add Worktree', style: typography.title2),
                    const SheetDescription(
                      'A worktree is another checkout of this repository in its own '
                      'folder, with its own branch — so you can work on two things at '
                      'once without stashing.',
                    ),
                    const SizedBox(height: 16),

                    _basisPicker(context, locals),
                    const SizedBox(height: 12),

                    if (_basis == _Basis.newBranch)
                      LabeledTextField(
                        label: 'New branch name',
                        controller: _branch,
                        placeholder: 'feature/auth',
                        onChanged: () => setState(_syncFolderName),
                      ),
                    if (_basis == _Basis.detached)
                      LabeledTextField(
                        label: 'Revision',
                        controller: _revision,
                        placeholder: 'a commit, tag, or branch',
                        onChanged: () => setState(_syncFolderName),
                      ),

                    const SizedBox(height: 12),
                    _locationField(context, problem),

                    const SizedBox(height: 14),
                    Container(height: 1, color: MacosColors.separatorColor),
                    const SizedBox(height: 12),

                    _copyIgnoredField(context),
                    const SizedBox(height: 10),
                    _postCreateField(context),

                    const SizedBox(height: 12),
                    LabeledCheckbox(
                      label: 'Open it when done',
                      value: _openAfter,
                      onChanged: (v) => setState(() => _openAfter = v),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AppPushButton(
                  controlSize: ControlSize.large,
                  secondary: true,
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                AppPushButton(
                  controlSize: ControlSize.large,
                  onPressed: _valid && problem == null && !_submitting
                      ? _submit
                      : null,
                  child: Text(_submitting ? 'Creating…' : 'Create Worktree'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Local branches a new worktree can check out: those no worktree holds.
  static List<GitRef> _offerable(List<GitRef> locals) =>
      locals.where((b) => b.worktreePath == null).toList();

  Widget _basisPicker(BuildContext context, List<GitRef> locals) {
    // A branch already checked out somewhere cannot be checked out again — git
    // refuses, and there is no override. Rather than let the user pick it and
    // then hand them git's error, take it off the menu and say why.
    final available = _offerable(locals);
    final taken = locals.where((b) => b.worktreePath != null).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Based on',
          style: MacosTheme.of(
            context,
          ).typography.caption1.copyWith(color: MacosColors.systemGrayColor),
        ),
        const SizedBox(height: 4),
        // Wrap, not Row: the three labels are wider than the sheet at this size
        // and a Row overflows them off the right edge. Wrapping is also the
        // right behaviour if a label is ever localised into something longer.
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (basis, label) in const [
              (_Basis.newBranch, 'New branch'),
              (_Basis.existingBranch, 'Existing branch'),
              (_Basis.detached, 'Detached'),
            ])
              AppPushButton(
                controlSize: ControlSize.regular,
                secondary: _basis != basis,
                onPressed: () => setState(() {
                  _basis = basis;
                  _syncFolderName();
                }),
                child: Text(label),
              ),
          ],
        ),
        if (_basis == _Basis.existingBranch) ...[
          const SizedBox(height: 8),
          MacosPopupButton<String>(
            // Guarded against the offered list: the value can arrive from a
            // caller ("Checkout in New Worktree…") or survive a refs refresh
            // while the sheet is open, and a value the popup no longer
            // offers trips its exactly-one-item assertion.
            value: available.any((b) => b.shortName == _existingBranch)
                ? _existingBranch
                : null,
            hint: const Text('Choose a branch'),
            items: [
              for (final b in available)
                MacosPopupMenuItem(
                  value: b.shortName,
                  child: Text(b.shortName),
                ),
            ],
            onChanged: (v) => setState(() {
              _existingBranch = v;
              _syncFolderName();
            }),
          ),
          if (taken > 0)
            FieldHint(
              '$taken branch${taken == 1 ? ' is' : 'es are'} already checked '
              'out in another worktree and cannot be used here.',
            ),
        ],
      ],
    );
  }

  Widget _locationField(BuildContext context, String? problem) {
    final typography = MacosTheme.of(context).typography;
    final isLocal = ref.read(connectionProvider).isLocal;
    final label = typography.caption1.copyWith(
      color: MacosColors.systemGrayColor,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The folder that gets AUTHORIZED, kept as its own field so it is the
        // thing you look at and pick. A macOS grant covers a folder and its
        // contents; `git worktree add` creates a NEW directory, so the
        // permission has to sit on the parent — which is invisible if the only
        // field is a full destination path.
        Text('Create in', style: label),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: MacosTextField(
                controller: _parent,
                placeholder: '/Users/you/code',
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
                placeholderStyle: kAppPlaceholderStyle,
                onChanged: (_) => setState(() {}),
              ),
            ),
            // The picker browses the LOCAL filesystem and doubles as the
            // sandbox grant — both meaningless for a repo on a remote host,
            // where the path names a directory on the remote and there is
            // no sandbox. Plain text entry is the whole flow there (same as
            // the Move/Repair prompts).
            if (isLocal) ...[
              const SizedBox(width: 6),
              AppPushButton(
                controlSize: ControlSize.regular,
                secondary: true,
                onPressed: _grantParent,
                child: const Text('Choose…'),
              ),
            ],
          ],
        ),
        if (isLocal)
          FieldHint(
            _parentGranted
                ? '✓ macOS access granted to this folder.'
                : 'macOS will ask you to authorize this folder — it is the only '
                      'way the app can create the worktree inside it.',
          ),

        const SizedBox(height: 8),
        Text('Folder name', style: label),
        const SizedBox(height: 4),
        MacosTextField(
          controller: _folderName,
          placeholder: 'myapp-feature',
          decoration: kAppTextFieldDecoration,
          focusedDecoration: kAppTextFieldFocusedDecoration,
          placeholderStyle: kAppPlaceholderStyle,
          onChanged: (_) => setState(() => _nameEdited = true),
        ),

        const SizedBox(height: 6),
        if (problem != null)
          Text(
            problem,
            style: typography.caption1.copyWith(
              color: MacosColors.systemRedColor,
            ),
          )
        else if (_destination.isNotEmpty)
          // The composed result, so there is never any doubt where it lands.
          Text(
            '→ $_destination',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }

  Widget _copyIgnoredField(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LabeledCheckbox(
          label: 'Copy ignored files',
          value: _copyIgnored,
          onChanged: (v) => setState(() => _copyIgnored = v),
        ),
        if (_copyIgnored) ...[
          const SizedBox(height: 6),
          MacosTextField(
            controller: _copyGlobs,
            placeholder: '.env*, .env.local',
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
            placeholderStyle: kAppPlaceholderStyle,
          ),
          const FieldHint(
            'git checks out tracked files only, so a new worktree has no .env '
            'and the project fails on first run. These patterns are copied '
            'across. Comma-separated, and remembered for next time.',
          ),
        ],
      ],
    );
  }

  Widget _postCreateField(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LabeledCheckbox(
          label: 'Run a command after creating',
          value: _runPostCreate,
          onChanged: (v) => setState(() => _runPostCreate = v),
        ),
        if (_runPostCreate) ...[
          const SizedBox(height: 6),
          MacosTextField(
            controller: _postCreate,
            placeholder: 'pnpm install',
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
            placeholderStyle: kAppPlaceholderStyle,
          ),
          const FieldHint(
            'Runs inside the new worktree, and is remembered for next time. '
            'Output appears in the Output view.',
          ),
        ],
      ],
    );
  }
}
