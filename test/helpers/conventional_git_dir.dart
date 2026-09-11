/// The conventional git dir, `<repoPath>/.git`, as a `GitDirResolver`.
///
/// For tests whose repositories are ordinary checkouts. Production resolves the
/// git dir with git itself (`gitDirResolverFor`), because `<repo>/.git` is a
/// FILE in a linked worktree and locking under it refused every worktree (MADR
/// 0045 F10). The resolver is a required parameter with no default, so a test
/// passes this explicitly and nothing can reintroduce the assumption silently
/// (plan decision (d)).
Future<String> conventionalGitDir(String repoPath) async => '$repoPath/.git';
