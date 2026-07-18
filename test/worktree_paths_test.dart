// The symlink-insensitive path guards: a symlinked alias of the repository
// (macOS /tmp → /private/tmp being the canonical case) must neither dodge the
// "no worktree inside the repo" rule nor make the grant picker reject the
// correct folder.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/worktrees/worktree_paths.dart';

void main() {
  late Directory base;

  setUp(() {
    base = Directory.systemTemp.createTempSync('wt_paths_');
  });

  tearDown(() => base.deleteSync(recursive: true));

  test('canonicalPath resolves an existing symlink', () {
    final real = Directory('${base.path}/real')..createSync();
    Link('${base.path}/alias').createSync(real.path);

    expect(
      canonicalPath('${base.path}/alias'),
      canonicalPath(real.path),
    );
  });

  test('canonicalPath passes a nonexistent (e.g. remote) path through', () {
    expect(canonicalPath('/no/such/dir'), '/no/such/dir');
  });

  test('a symlinked alias cannot dodge the inside-repo guard', () {
    final repo = Directory('${base.path}/repo')..createSync();
    Link('${base.path}/alias').createSync(repo.path);

    // A destination spelled through the alias is still inside the repo.
    expect(isInsideRepo('${base.path}/alias/nested', repo.path), isTrue);
    expect(isInsideRepo('${base.path}/alias', repo.path), isTrue);
    // And an honest sibling is not.
    expect(isInsideRepo('${base.path}/elsewhere', repo.path), isFalse);
  });

  test('macOS: /tmp spellings match their /private forms', () {
    // Directory.systemTemp lives under /var (→ /private/var) on macOS; on
    // other platforms this collapses to equality trivially.
    expect(
      isInsideRepo('${base.path}/sub', canonicalPath(base.path)),
      isTrue,
      reason: 'the unresolved spelling must count as inside the resolved repo',
    );
  });

  test('nonexistent paths degrade to the plain string comparison', () {
    expect(isInsideRepo('/no/such/repo/sub', '/no/such/repo'), isTrue);
    expect(isInsideRepo('/no/such/other', '/no/such/repo'), isFalse);
  });
}
