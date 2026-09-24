// HostPath: one canonical form per host (MADR 0070, Amendment 0070.3). The
// Windows cases are the spellings measured on a Git Bash host: `/c/…` from
// `pwd` and `$HOME`, `C:\…` and `C:/…` typed, and git's own `C:/…`. Under
// POSIX every function must match the helpers it replaces, byte for byte.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/host_fs_service.dart';
import 'package:remote_magic_git/core/utils/host_path.dart';
import 'package:remote_magic_git/core/utils/posix_path.dart' as posix;

const _win = HostPathStyle.windows;
const _posix = HostPathStyle.posix;

/// Inputs every property below runs over, POSIX and Windows shapes mixed.
const _samples = [
  '/c/Users/u/r',
  '/C/Users/u/r/',
  r'C:\Users\u\r',
  'c:/Users/u/r/',
  'C:/Users/u/r',
  'C:/',
  'C:',
  '/c',
  r'\\srv\share\dir',
  '//srv/share/dir/',
  '/tmp',
  '/usr/bin',
  '/srv/git/repo',
  '/srv/git/repo/',
  '/',
  'relative/dir',
  '',
  'C://Users//u',
];

void main() {
  group('canonical', () {
    test('Windows spellings of one folder meet at git\'s form', () {
      for (final p in [
        '/c/Users/u/r',
        '/C/Users/u/r/',
        r'C:\Users\u\r',
        'c:/Users/u/r/',
        'C:/Users/u/r',
        'C://Users//u//r',
      ]) {
        expect(HostPath.canonical(p, _win), 'C:/Users/u/r', reason: p);
      }
    });

    test('drive roots, UNC, and what only the host can map', () {
      expect(HostPath.canonical('/c', _win), 'C:/');
      expect(HostPath.canonical('C:', _win), 'C:/');
      expect(HostPath.canonical('d:/', _win), 'D:/');
      expect(HostPath.canonical(r'\\srv\share\dir\', _win), '//srv/share/dir');
      // An MSYS mount other than a drive letter keeps its text.
      expect(HostPath.canonical('/tmp', _win), '/tmp');
      expect(HostPath.canonical('/usr/bin', _win), '/usr/bin');
      // Two letters is a directory, not a drive.
      expect(HostPath.canonical('/cd/x', _win), '/cd/x');
      expect(HostPath.canonical(r'rel\dir', _win), 'rel/dir');
    });

    test('POSIX is the identity, including a folder named /c', () {
      for (final p in _samples) {
        expect(HostPath.canonical(p, _posix), p, reason: p);
      }
    });

    test('is idempotent', () {
      for (final p in _samples) {
        final once = HostPath.canonical(p, _win);
        expect(HostPath.canonical(once, _win), once, reason: p);
      }
    });
  });

  group('isAbsolute and looksAbsolute', () {
    test('Windows: drive roots and UNC; not MSYS mounts or relative', () {
      for (final p in [
        'C:/',
        'C:/x',
        r'C:\x',
        '/c/x',
        '//srv/share',
        r'\\srv\s',
      ]) {
        expect(HostPath.isAbsolute(p, _win), isTrue, reason: p);
      }
      for (final p in ['/tmp', 'rel', '', 'C:rel']) {
        expect(HostPath.isAbsolute(p, _win), isFalse, reason: p);
      }
    });

    test('POSIX: exactly startsWith("/")', () {
      for (final p in _samples) {
        expect(HostPath.isAbsolute(p, _posix), p.startsWith('/'), reason: p);
      }
    });

    test('looksAbsolute accepts every host\'s absolute form, and nothing '
        'the old startsWith("/") check rejected for a reason', () {
      for (final p in [
        '/srv/x',
        'C:/x',
        r'C:\x',
        'd:/',
        '//srv/s',
        r'\\srv\s',
      ]) {
        expect(HostPath.looksAbsolute(p), isTrue, reason: p);
      }
      // An old git echoes the format atom back; it must stay "no path".
      for (final p in ['%(worktreepath)', '', 'rel/x', 'C:rel']) {
        expect(HostPath.looksAbsolute(p), isFalse, reason: p);
      }
    });
  });

  group('same and isInside', () {
    test('Windows: any spelling, any case', () {
      expect(HostPath.same('/c/Users/u/r', 'C:/Users/u/r', _win), isTrue);
      expect(HostPath.same(r'c:\users\U\R\', 'C:/Users/u/r', _win), isTrue);
      expect(HostPath.same('C:/Users/u/r', 'C:/Users/u/r2', _win), isFalse);
      expect(
        HostPath.isInside('C:/Users/u/r/sub', '/c/Users/u/r', _win),
        isTrue,
      );
      expect(HostPath.isInside('C:/Users/u/r', 'c:/users/u/r', _win), isTrue);
      expect(HostPath.isInside('C:/Users/u/r2', 'C:/Users/u/r', _win), isFalse);
      expect(HostPath.isInside('C:/x', 'C:/', _win), isTrue);
    });

    test('POSIX: exact, case-sensitive', () {
      expect(HostPath.same('/srv/R', '/srv/r', _posix), isFalse);
      expect(HostPath.same('/c/x', 'C:/x', _posix), isFalse);
      expect(HostPath.isInside('/srv/r/a', '/srv/r', _posix), isTrue);
      expect(HostPath.isInside('/srv/r2', '/srv/r', _posix), isFalse);
      expect(HostPath.isInside('/x', '/', _posix), isTrue);
    });

    test('same(p, canonical(p)) for every sample', () {
      for (final p in _samples) {
        expect(
          HostPath.same(p, HostPath.canonical(p, _win), _win),
          isTrue,
          reason: p,
        );
      }
    });
  });

  group('basename, dirname, join', () {
    test('labels: a legacy C:\\ entry names its folder, with no style', () {
      expect(
        HostPath.basename(r'C:\Users\u\magic-cli-remote'),
        'magic-cli-remote',
      );
      expect(HostPath.basename('C:/Users/u/r/'), 'r');
      expect(HostPath.basename(r'\\srv\share\dir'), 'dir');
      expect(HostPath.basename('C:/'), 'C:/');
    });

    test('a POSIX-shaped path labels exactly as posix_path.basename', () {
      // Drive and UNC shapes differ on purpose (the test above); every other
      // path, a backslash inside a POSIX name included, must not change.
      final posixShaped = [
        for (final p in [..._samples, r'/srv/odd\name'])
          if (!RegExp(r'^[A-Za-z]:[/\\]').hasMatch(p) && !p.startsWith(r'\\'))
            p,
      ];
      expect(posixShaped, hasLength(greaterThan(10)));
      for (final p in posixShaped) {
        expect(HostPath.basename(p), posix.basename(p), reason: p);
      }
    });

    test('Windows dirname stops at the drive root', () {
      expect(HostPath.dirname('/c/Users/u/r', _win), 'C:/Users/u');
      expect(HostPath.dirname('C:/Users', _win), 'C:/');
      expect(HostPath.dirname('C:/', _win), 'C:/');
      expect(HostPath.dirname('//srv/share/dir', _win), '//srv/share');
    });

    test('POSIX dirname and join match the helpers they replace', () {
      for (final p in _samples) {
        expect(HostPath.dirname(p, _posix), posix.dirname(p), reason: p);
        expect(
          HostPath.join(p, 'n', _posix),
          HostFsService.joinPath(p, 'n'),
          reason: p,
        );
      }
    });

    test('Windows join is canonical', () {
      expect(HostPath.join('/c/Users/u', 'r', _win), 'C:/Users/u/r');
      expect(HostPath.join('C:/', 'r', _win), 'C:/r');
      expect(HostPath.join(r'C:\Users\u', r'a\b', _win), 'C:/Users/u/a/b');
    });
  });
}
