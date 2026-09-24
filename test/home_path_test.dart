// A leading `~` in a repository path, expanded against the host's $HOME: a
// quoted `~` is never expanded by the shell, so the app must do it.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/home_path.dart';

void main() {
  test('expands ~ and ~/…, and nothing else', () {
    expect(expandHomePath('~', '/home/u'), '/home/u');
    expect(expandHomePath('~/', '/home/u'), '/home/u/');
    expect(expandHomePath('~/src/repo', '/home/u'), '/home/u/src/repo');
    // Git Bash on Windows reports an MSYS-style home.
    expect(
      expandHomePath('~/gitrepos/app', '/c/Users/u'),
      '/c/Users/u/gitrepos/app',
    );
    // Another account's home is not guessed.
    expect(expandHomePath('~other/repo', '/home/u'), '~other/repo');
    expect(expandHomePath('/srv/~/repo', '/home/u'), '/srv/~/repo');
    expect(expandHomePath('/srv/repo', '/home/u'), '/srv/repo');
    expect(expandHomePath(r'C:\Users\u\repo', '/home/u'), r'C:\Users\u\repo');
  });

  test('a home with a trailing slash does not double it', () {
    expect(expandHomePath('~/repo', '/home/u/'), '/home/u/repo');
    expect(expandHomePath('~/repo', '/'), '/repo');
  });

  test('hasHomePrefix', () {
    expect(hasHomePrefix('~'), isTrue);
    expect(hasHomePrefix('~/repo'), isTrue);
    expect(hasHomePrefix('~other/repo'), isFalse);
    expect(hasHomePrefix('/home/u'), isFalse);
  });
}
