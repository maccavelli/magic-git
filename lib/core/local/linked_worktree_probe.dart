import 'dart:io';

/// What a linked worktree's `.git` file points at.
class LinkedWorktreeInfo {
  /// This worktree's private git dir — `<common>/worktrees/<id>`, absolute.
  /// Holds this checkout's own HEAD, index, ORIG_HEAD and in-progress-op state.
  final String gitDir;

  /// The shared git dir — `<main>/.git` for an ordinary main repo, or the git
  /// dir itself when the main repo is bare (`<repo>.git`) or uses
  /// `--separate-git-dir`. Holds the objects, the shared refs and
  /// `packed-refs`, and every worktree's admin directory.
  ///
  /// Note [gitDir] is *inside* this, which is what lets a single recursive watch
  /// of it observe this worktree's HEAD and index as well as the shared refs.
  final String gitCommonDir;

  /// The folder that needs the second security-scoped grant: the main
  /// repository's working-tree root when there is one, otherwise (bare or
  /// separate git dir) [gitCommonDir] itself.
  final String mainRepoPath;

  const LinkedWorktreeInfo({
    required this.gitDir,
    required this.gitCommonDir,
    required this.mainRepoPath,
  });
}

/// Why a folder can't be opened as a local repo, when we can tell without git.
enum LocalRepoKind {
  /// `.git` is a directory — an ordinary repo, everything is inside the grant.
  ordinary,

  /// `.git` is a file pointing into `<main>/.git/worktrees/<id>` — a linked
  /// worktree. Usable, but needs the main repo granted too.
  linkedWorktree,

  /// `.git` is a file pointing into `<super>/.git/modules/<name>` — a submodule.
  /// Its git data has no separately-openable main repo, so we can't help.
  submodule,

  /// No `.git` at all, or it's unreadable//unrecognisable.
  unknown,
}

/// The result of [probeLocalRepo].
class LocalRepoProbe {
  final LocalRepoKind kind;

  /// Set only when [kind] is [LocalRepoKind.linkedWorktree].
  final LinkedWorktreeInfo? worktree;

  const LocalRepoProbe(this.kind, [this.worktree]);
}

/// Classifies a local folder by reading its `.git` entry directly — **without
/// running git**.
///
/// This exists to break a macOS sandbox chicken-and-egg. Running `git rev-parse`
/// inside a linked worktree makes git read the *main* repository's git dir, so
/// it needs a security-scoped grant on the main repo. But we cannot know we need
/// that grant until we have classified the folder — and classifying it with git
/// is the very thing that needs it. Every read here stays inside the folder the
/// user already granted through the picker, so it always succeeds, and the
/// caller learns which second grant to ask for before any git runs.
///
/// (`GitService.repoLayout` remains the authority once both grants are held, and
/// is the only thing used on the SSH backend, where no sandbox exists. This is
/// strictly the bootstrap.)
LocalRepoProbe probeLocalRepo(String repoPath) {
  final dotGit = '$repoPath/.git';

  // An ordinary repo: `.git` is a directory, wholly inside the grant.
  if (FileSystemEntity.isDirectorySync(dotGit)) {
    return const LocalRepoProbe(LocalRepoKind.ordinary);
  }
  if (!FileSystemEntity.isFileSync(dotGit)) {
    return const LocalRepoProbe(LocalRepoKind.unknown);
  }

  final String content;
  try {
    content = File(dotGit).readAsStringSync();
  } catch (_) {
    return const LocalRepoProbe(LocalRepoKind.unknown);
  }

  // Format is a single line: `gitdir: <path>`.
  final line = content
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.startsWith('gitdir:'), orElse: () => '');
  if (line.isEmpty) return const LocalRepoProbe(LocalRepoKind.unknown);

  var gitDir = line.substring('gitdir:'.length).trim();
  if (gitDir.isEmpty) return const LocalRepoProbe(LocalRepoKind.unknown);

  // The path may be relative to the worktree (git 2.48's `--relative-paths` /
  // `worktree.useRelativePaths`, and the default for submodules). Resolve it
  // against the worktree before any string matching, or `../../main/.git/…`
  // would never match the patterns below.
  if (!gitDir.startsWith('/')) {
    gitDir = _normalize('$repoPath/$gitDir');
  }

  // A submodule's git dir lives under the superproject's `.git/modules/`. It
  // uses a gitfile exactly like a worktree does, which is why "is `.git` a
  // file" is NOT a valid test for a worktree.
  if (gitDir.contains('/.git/modules/')) {
    return const LocalRepoProbe(LocalRepoKind.submodule);
  }

  // A linked worktree's git dir is `<common>/worktrees/<id>` — that shape is
  // what git guarantees, NOT that the common dir is named `.git`: a worktree of
  // a bare repo points into `<repo>.git/worktrees/<id>`, and one of a
  // `--separate-git-dir` repo into `<gitdir>/worktrees/<id>`. So classify by
  // the penultimate path segment, then derive the two folders from it. (In
  // principle a `--separate-git-dir` target could itself sit inside a folder a
  // user named `worktrees` and land here wrongly — the sandbox forbids
  // stat'ing outside the grant, so the shape is all we have. `GitService.
  // repoLayout` remains the authority once granted, and a wrong guess costs a
  // redundant watch root, not correctness.)
  final segments = gitDir.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.length >= 3 && segments[segments.length - 2] == 'worktrees') {
    final commonDir = '/${segments.sublist(0, segments.length - 2).join('/')}';
    return LocalRepoProbe(
      LocalRepoKind.linkedWorktree,
      LinkedWorktreeInfo(
        gitDir: gitDir,
        gitCommonDir: commonDir,
        // `<main>/.git` means there is a main working tree to grant; a bare or
        // separate git dir has no working tree, so the git dir itself is the
        // folder the grant must cover.
        mainRepoPath: commonDir.endsWith('/.git')
            ? commonDir.substring(0, commonDir.length - '/.git'.length)
            : commonDir,
      ),
    );
  }

  // A gitfile pointing somewhere else entirely — the `--separate-git-dir`
  // layout of the repo ITSELF (its gitdir has no `worktrees/<id>` tail). Not
  // something we can bootstrap a grant for.
  return const LocalRepoProbe(LocalRepoKind.unknown);
}

/// Collapses `.` and `..` segments in an absolute path. Deliberately pure string
/// math and NOT `resolveSymbolicLinksSync`: the target may sit outside the
/// current sandbox grant (that's the whole point — we're computing what to ask
/// for), and stat'ing it would throw.
String _normalize(String path) {
  final out = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(part);
  }
  return '/${out.join('/')}';
}
