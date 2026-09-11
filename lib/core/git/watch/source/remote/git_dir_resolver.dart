import '../../../../ssh/ssh_command_executor.dart';
import '../../../git_service.dart';

/// Resolves a repository's own git dir — the directory the host script locks.
///
/// A function type rather than a class because it is one question with one
/// answer, and tests answer it with a closure.
typedef GitDirResolver = Future<String> Function(String repoPath);

/// The production resolver: git's own answer, on the command host.
///
/// `'$repoPath/.git'` is a FILE in a linked worktree, so the host's `mkdir`
/// lock under it fails and every linked worktree was refused with exit 98 — as
/// though another watcher held it (MADR 0045 F10, reproduced). `--git-dir`
/// names the worktree's own admin directory, which is a directory in every
/// layout git supports.
GitDirResolver gitDirResolverFor(CommandExecutor executor) =>
    (repoPath) async => (await resolveRepoLayout(executor, repoPath)).gitDir;
