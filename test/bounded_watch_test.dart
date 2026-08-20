// Bounded watch surface for a scoped work-tree (dotfiles) repo: instead of a
// recursive watch of the whole work tree ($HOME — measured 257k dirs on a real
// bastion), watch only the git-dir signal points and the parent directory of
// each tracked file, non-recursively. This proves the surface computation, the
// absolute→repo-relative event remap (which lets the shared filter and
// touchesGitState work unchanged), and that the emitted watcher command is
// genuinely non-recursive.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/git/watch_path_filter.dart';

void main() {
  const gitDir = '/home/u/.home.git';
  const workTree = '/home/u';

  // A representative slice of a real dotfiles working set: a top-level file,
  // two files sharing one dir (must dedupe), and a nested dir.
  const tracked = [
    '.bashrc',
    '.config/bash/aliases.sh',
    '.config/bash/env.sh',
    '.claude/CLAUDE.md',
  ];

  group('computeBoundedWatchSpec', () {
    test('collapses to git-dir points + unique tracked-file dirs', () {
      final spec = computeBoundedWatchSpec(
        gitDir: gitDir,
        workTree: workTree,
        trackedFiles: tracked,
      );
      expect(spec.gitDir, gitDir);
      expect(spec.workTree, workTree);
      expect(spec.watchDirs, [
        '/home/u', // from .bashrc (dirname is the work-tree root)
        '/home/u/.claude',
        '/home/u/.config/bash', // aliases.sh + env.sh deduped to one dir
        '/home/u/.home.git', // git-dir root
        '/home/u/.home.git/refs/heads', // branch-ref writes
        '/home/u/.home.git/refs/tags', // tag-ref writes
      ]);
      // Four tracked files across three dirs + three git-dir points = six —
      // versus a recursive watch of every directory under $HOME.
      expect(spec.watchDirs.length, 6);
    });

    test('trailing slashes stripped; empty tracked list still watches git', () {
      final spec = computeBoundedWatchSpec(
        gitDir: '$gitDir/',
        workTree: '$workTree/',
        trackedFiles: const [],
      );
      expect(spec.gitDir, gitDir);
      expect(spec.workTree, workTree);
      expect(spec.watchDirs, [
        '/home/u/.home.git',
        '/home/u/.home.git/refs/heads',
        '/home/u/.home.git/refs/tags',
      ]);
    });
  });

  group('relativizeBoundedEvent', () {
    late BoundedWatchSpec spec;
    setUp(() {
      spec = computeBoundedWatchSpec(
        gitDir: gitDir,
        workTree: workTree,
        trackedFiles: tracked,
      );
    });

    test(
      'git-dir events become .git/… (checked before the work-tree prefix)',
      () {
        // The git-dir lives INSIDE the work tree, so precedence matters.
        expect(relativizeBoundedEvent('$gitDir/index', spec), '.git/index');
        expect(
          relativizeBoundedEvent('$gitDir/refs/heads/main', spec),
          '.git/refs/heads/main',
        );
        expect(relativizeBoundedEvent(gitDir, spec), '.git');
      },
    );

    test('work-tree events become repo-relative', () {
      expect(
        relativizeBoundedEvent('$workTree/.config/bash/aliases.sh', spec),
        '.config/bash/aliases.sh',
      );
      expect(relativizeBoundedEvent('$workTree/.bashrc', spec), '.bashrc');
      expect(relativizeBoundedEvent(workTree, spec), '');
    });

    test('paths outside the spec are dropped', () {
      expect(relativizeBoundedEvent('/etc/passwd', spec), isNull);
      expect(relativizeBoundedEvent('/home/other/.bashrc', spec), isNull);
    });

    test('remapped paths flow through the shared filter correctly', () {
      // Index/ref writes trigger and read as git state; object/log churn is
      // dropped exactly as in an ordinary repo — the whole point of the remap.
      final index = relativizeBoundedEvent('$gitDir/index', spec)!;
      expect(shouldTriggerWatch(index), isTrue);
      expect(index.startsWith('.git/'), isTrue); // sets touchesGitState

      final edit = relativizeBoundedEvent(
        '$workTree/.config/bash/env.sh',
        spec,
      )!;
      expect(shouldTriggerWatch(edit), isTrue);

      expect(
        shouldTriggerWatch(
          relativizeBoundedEvent('$gitDir/objects/aa/bb', spec)!,
        ),
        isFalse,
      );
      expect(
        shouldTriggerWatch(relativizeBoundedEvent('$gitDir/logs/HEAD', spec)!),
        isFalse,
      );
    });
  });

  group('boundedInotifyScript', () {
    test('is non-recursive and watches the explicit dir list', () {
      final spec = computeBoundedWatchSpec(
        gitDir: gitDir,
        workTree: workTree,
        trackedFiles: tracked,
      );
      final script = boundedInotifyScript(spec.watchDirs);

      // The core claim: NO recursive flag anywhere. A recursive watch of $HOME
      // is exactly what this mode exists to avoid.
      expect(script.contains('-r'), isFalse);

      expect(script.contains('inotifywait'), isTrue);
      expect(script.contains('--format %w%f'), isTrue);
      expect(script.contains('stdbuf -oL'), isTrue); // line-buffered flush
      // Every watch dir is present (shell-escaped).
      for (final d in spec.watchDirs) {
        expect(script.contains("'$d'"), isTrue, reason: 'missing $d');
      }
    });

    test('escapes paths with shell metacharacters', () {
      final script = boundedInotifyScript(["/home/u/it's a dir"]);
      expect(script.contains(r"'/home/u/it'\''s a dir'"), isTrue);
    });
  });
}
