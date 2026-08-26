// auth_status: parsing gh/glab/git tool output into structured sign-in state
// for the Dashboard's Authentication section. Real CLI output shapes (gh
// 2.96, glab 1.107) are pinned here so a format drift is caught by a test
// rather than by a user's create silently failing.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/auth_status.dart';

void main() {
  group('parseGhAuthStatus', () {
    test('signed in — host, account, level ok', () {
      const out = '''
github.com
  ✓ Logged in to github.com account maccavelli (keyring)
  - Active account: true
  - Git operations protocol: https
''';
      final a = parseGhAuthStatus(out, present: true);
      expect(a.present, isTrue);
      expect(a.authenticated, isTrue);
      expect(a.host, 'github.com');
      expect(a.account, 'maccavelli');
      expect(a.level, ToolAuthLevel.ok);
      expect(a.detail, contains('maccavelli'));
    });

    test('multiple hosts — the active account wins', () {
      const out = '''
github.com
  ✓ Logged in to github.com account personal (keyring)
  - Active account: false

ghe.corp.example
  ✓ Logged in to ghe.corp.example account work (keyring)
  - Active account: true
''';
      final a = parseGhAuthStatus(out, present: true);
      expect(a.host, 'ghe.corp.example');
      expect(a.authenticated, isTrue);
    });

    test('multi-host: the account comes from the ACTIVE block, not the '
        'first match in the output', () {
      const out = '''
github.com
  ✓ Logged in to github.com account personal (keyring)
  - Active account: false

ghe.corp.example
  ✓ Logged in to ghe.corp.example account work (keyring)
  - Active account: true
''';
      final a = parseGhAuthStatus(out, present: true);
      expect(a.host, 'ghe.corp.example');
      expect(
        a.account,
        'work',
        reason: 'the account must belong to the shown host',
      );
      expect(a.detail, contains('ghe.corp.example as work'));
    });

    test('an expired token on the active host is NOT authenticated', () {
      // gh exits 1 with this shape — the host and Active marker are still
      // printed, so a host-only parse would wrongly pass.
      const out = '''
github.com
  X github.com: Failed to log in to github.com account user (keyring)
  - Active account: true
''';
      final a = parseGhAuthStatus(out, present: true);
      expect(a.authenticated, isFalse);
      expect(a.level, ToolAuthLevel.warn);
      expect(a.detail, contains('expired or invalid'));
      expect(a.detail, contains('github.com'));
    });

    test('signed out — warn level, no host', () {
      const out =
          'You are not logged into any GitHub hosts. '
          'To log in, run: gh auth login';
      final a = parseGhAuthStatus(out, present: true);
      expect(a.authenticated, isFalse);
      expect(a.host, isNull);
      expect(a.level, ToolAuthLevel.warn);
    });

    test('trailing-colon and :port host lines are handled', () {
      const out = '''
ghe.internal:8443:
  ✓ Logged in to ghe.internal:8443 account ops (keyring)
  - Active account: true
''';
      final a = parseGhAuthStatus(out, present: true);
      expect(a.host, 'ghe.internal:8443');
      expect(a.authenticated, isTrue);
    });

    test('missing binary — bad level', () {
      final a = parseGhAuthStatus('', present: false);
      expect(a.present, isFalse);
      expect(a.authenticated, isFalse);
      expect(a.level, ToolAuthLevel.bad);
    });
  });

  group('parseGlabAuthStatus', () {
    test('signed in to a self-hosted instance', () {
      const out = '''
gitlab.example.com
  ✓ Logged in to gitlab.example.com as saxsmith (/Users/x/config.yml)
  ✓ Git operations for gitlab.example.com configured to use https protocol.
  ✓ Token found: **************************
''';
      final a = parseGlabAuthStatus(out, present: true);
      expect(a.authenticated, isTrue);
      expect(a.host, 'gitlab.example.com');
      expect(a.account, 'saxsmith');
      expect(a.level, ToolAuthLevel.ok);
    });

    test('a 401 on the configured host is NOT authenticated', () {
      const out = '''
gitlab.com
  x gitlab.com: API call failed: GET https://gitlab.com/api/v4/user: 401 {message: 401 Unauthorized}
  ✓ Git operations for gitlab.com configured to use ssh protocol.
''';
      final a = parseGlabAuthStatus(out, present: true);
      expect(a.authenticated, isFalse);
      expect(a.level, ToolAuthLevel.warn);
      expect(a.detail, contains('expired or invalid'));
    });

    test('a stale secondary host does not mask a working login', () {
      // Judgment is per host block: the gitlab.com 401 must not mark the
      // whole tool signed out when gitlab.example.com is validly logged in.
      const out = '''
gitlab.com
  x gitlab.com: API call failed: GET https://gitlab.com/api/v4/user: 401 {message: 401 Unauthorized}

gitlab.example.com
  ✓ Logged in to gitlab.example.com as saxsmith (/Users/x/config.yml)
  ✓ Token found: **************************
''';
      final a = parseGlabAuthStatus(out, present: true);
      expect(a.authenticated, isTrue);
      expect(a.host, 'gitlab.example.com');
      expect(a.account, 'saxsmith');
      expect(a.level, ToolAuthLevel.ok);
    });

    test('a port-like 401 in a hostname is not read as a failure', () {
      const out = '''
gitlab.example.com:8401
  ✓ Logged in to gitlab.example.com:8401 as ops (config.yml)
''';
      final a = parseGlabAuthStatus(out, present: true);
      expect(a.authenticated, isTrue);
      expect(a.host, 'gitlab.example.com:8401');
    });

    test('single-label internal hostnames are accepted', () {
      const out = '''
gitbox
  ✓ Logged in to gitbox as dev (config.yml)
''';
      final a = parseGlabAuthStatus(out, present: true);
      expect(a.authenticated, isTrue);
      expect(a.host, 'gitbox');
    });

    test('missing binary — bad level', () {
      final a = parseGlabAuthStatus('', present: false);
      expect(a.present, isFalse);
      expect(a.level, ToolAuthLevel.bad);
    });

    test('Logged in to line before bare hostname (alternate glab output)', () {
      const out = '''
✓ Logged in to gitlab.example.com as saxsmith
  ✓ Git operations for gitlab.example.com configured to use https protocol.
  ✓ Token found: **************************
''';
      final a = parseGlabAuthStatus(out, present: true);
      expect(a.authenticated, isTrue);
      expect(a.host, 'gitlab.example.com');
      expect(a.account, 'saxsmith');
      expect(a.level, ToolAuthLevel.ok);
    });

    test('no bare hostname line at all — falls back to Logged in to', () {
      const out = '''
✓ Logged in to gitlab.internal as dev
  ✓ Token found: **************************
  ✓ Git operations configured to use https protocol.
''';
      final a = parseGlabAuthStatus(out, present: true);
      expect(a.authenticated, isTrue);
      expect(a.host, 'gitlab.internal');
      expect(a.account, 'dev');
      expect(a.level, ToolAuthLevel.ok);
    });
  });

  group('parseGlabAuthStatusForHost', () {
    const mixed = '''
gitlab.com
  x gitlab.com: API call failed: GET https://gitlab.com/api/v4/user: 401 {message: 401 Unauthorized}

gitlab.example.com
  ✓ Logged in to gitlab.example.com as saxsmith (/Users/x/config.yml)
  ✓ Token found: **************************
''';

    test('mixed dump + gitlab.example.com is authenticated to that host', () {
      final a = parseGlabAuthStatusForHost(
        mixed,
        present: true,
        host: 'gitlab.example.com',
      );
      expect(a.authenticated, isTrue);
      expect(a.host, 'gitlab.example.com');
      expect(a.account, 'saxsmith');
    });

    test('mixed dump + gitlab.com is not authenticated (expired detail)', () {
      final a = parseGlabAuthStatusForHost(
        mixed,
        present: true,
        host: 'gitlab.com',
      );
      expect(a.authenticated, isFalse);
      expect(a.host, 'gitlab.com');
      expect(a.detail, contains('expired or invalid'));
    });

    test('dump without that host is not authenticated', () {
      final a = parseGlabAuthStatusForHost(
        mixed,
        present: true,
        host: 'gitlab.other.example',
      );
      expect(a.authenticated, isFalse);
      expect(a.host, 'gitlab.other.example');
      expect(a.detail, contains('Not authenticated to'));
    });

    test('present: false is missing', () {
      final a = parseGlabAuthStatusForHost(
        mixed,
        present: false,
        host: 'gitlab.example.com',
      );
      expect(a.present, isFalse);
      expect(a.level, ToolAuthLevel.bad);
    });

    test('1.109 single-block dump matching host is authenticated', () {
      const out = '''
gitlab.example.com
  ✓ Logged in to gitlab.example.com as saxsmith (/home/x/.config/glab-cli/config.yml)
  ✓ Git operations for gitlab.example.com configured to use https protocol.
  ✓ API calls for gitlab.example.com are made over https protocol
  ✓ Token found: **************************
''';
      final a = parseGlabAuthStatusForHost(
        out,
        present: true,
        host: 'gitlab.example.com',
      );
      expect(a.authenticated, isTrue);
      expect(a.host, 'gitlab.example.com');
      expect(a.account, 'saxsmith');
    });
  });

  group('ToolAuth.unknown', () {
    test('a timed-out check is unknown — never signed-out or missing', () {
      final a = ToolAuth.unknown('gh');
      expect(a.level, ToolAuthLevel.unknown);
      expect(a.present, isTrue);
      expect(a.authenticated, isFalse);
      expect(a.detail, contains('Could not check'));
    });

    test('git output with no version token is unknown, not "Installed"', () {
      final a = parseGitVersion('', present: true);
      expect(a.level, ToolAuthLevel.unknown);
    });
  });

  group('parseGitVersion', () {
    test('present — always authenticated (git has no login)', () {
      final a = parseGitVersion('git version 2.48.1', present: true);
      expect(a.present, isTrue);
      expect(a.authenticated, isTrue);
      expect(a.detail, contains('2.48.1'));
      expect(a.level, ToolAuthLevel.ok);
    });

    test('missing — bad', () {
      final a = parseGitVersion('', present: false);
      expect(a.level, ToolAuthLevel.bad);
    });
  });

  group('TargetAuth', () {
    test('anyForgeAuthenticated reflects gh OR glab', () {
      final t = TargetAuth(
        label: 'This Mac',
        isLocal: true,
        git: parseGitVersion('git version 2.48.1', present: true),
        gh: parseGhAuthStatus('signed out', present: true),
        glab: parseGlabAuthStatus(
          'gitlab.example.com\n  ✓ Logged in to gitlab.example.com as x (c)',
          present: true,
        ),
      );
      expect(t.anyForgeAuthenticated, isTrue);
      expect(t.tools.length, 3);
    });
  });
}
