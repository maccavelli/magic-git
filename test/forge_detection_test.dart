import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge.dart';

void main() {
  group('forgeHostFromRemoteUrl', () {
    test('parses scp-like origin', () {
      expect(
        forgeHostFromRemoteUrl('git@github.com:owner/repo.git'),
        'github.com',
      );
    });

    test('parses ssh:// origin', () {
      expect(
        forgeHostFromRemoteUrl('ssh://git@ghe.mycorp.com:22/owner/repo.git'),
        'ghe.mycorp.com',
      );
    });

    test('parses https origin', () {
      expect(
        forgeHostFromRemoteUrl('https://gitlab.com/group/sub/repo.git'),
        'gitlab.com',
      );
    });

    test('returns null for a blank url', () {
      expect(forgeHostFromRemoteUrl('   '), isNull);
    });
  });

  group('classifyForgeHost', () {
    test('github.com and subdomains', () {
      expect(classifyForgeHost('github.com'), Forge.github);
      expect(classifyForgeHost('api.github.com'), Forge.github);
    });

    test('gitlab.com and subdomains', () {
      expect(classifyForgeHost('gitlab.com'), Forge.gitlab);
      expect(classifyForgeHost('registry.gitlab.com'), Forge.gitlab);
    });

    test('self-hosted with a telltale substring', () {
      expect(classifyForgeHost('github.mycorp.com'), Forge.github);
      expect(classifyForgeHost('gitlab.internal'), Forge.gitlab);
    });

    test('is case-insensitive', () {
      expect(classifyForgeHost('GitHub.com'), Forge.github);
    });

    test('custom-domain enterprise host is unknown', () {
      expect(classifyForgeHost('git.mycorp.com'), Forge.unknown);
      expect(classifyForgeHost('code.example.org'), Forge.unknown);
    });

    test('blank host is unknown', () {
      expect(classifyForgeHost(''), Forge.unknown);
    });
  });

  group('forgeFromRemoteUrl', () {
    test('classifies github and gitlab from full urls', () {
      expect(
        forgeFromRemoteUrl('git@github.com:owner/repo.git'),
        Forge.github,
      );
      expect(
        forgeFromRemoteUrl('https://gitlab.com/group/repo.git'),
        Forge.gitlab,
      );
    });

    test('blank url is none', () {
      expect(forgeFromRemoteUrl(''), Forge.none);
    });

    test('unrecognized host is unknown', () {
      expect(
        forgeFromRemoteUrl('git@git.mycorp.com:owner/repo.git'),
        Forge.unknown,
      );
    });
  });

  group('forgeUrlFromCreateOutput', () {
    test('gh output: a bare URL line, normalized to .git', () {
      expect(
        forgeUrlFromCreateOutput(
          'https://github.com/mac/newrepo\n',
          name: 'newrepo',
        ),
        'https://github.com/mac/newrepo.git',
      );
    });

    test('glab output: the ✓-line with the URL embedded (verified live '
        'against glab 1.107)', () {
      expect(
        forgeUrlFromCreateOutput(
          '✓ Created project on GitLab: Samuel Smith / newrepo - '
          'https://gitlab.corp.example/sax/newrepo\n',
          name: 'newrepo',
        ),
        'https://gitlab.corp.example/sax/newrepo.git',
      );
    });

    test('an existing .git suffix is not doubled', () {
      expect(
        forgeUrlFromCreateOutput(
          'https://gitlab.com/g/r.git',
          name: 'r',
        ),
        'https://gitlab.com/g/r.git',
      );
    });

    test('trailing sentence punctuation is stripped', () {
      expect(
        forgeUrlFromCreateOutput(
          'Created https://github.com/mac/proj.',
          name: 'proj',
        ),
        'https://github.com/mac/proj.git',
      );
    });

    test('a URL whose last segment is NOT the project is never taken', () {
      // e.g. a docs/release-notes link in the output must not become origin.
      expect(
        forgeUrlFromCreateOutput(
          'See https://gitlab.com/help/user/project for details',
          name: 'newrepo',
        ),
        isNull,
      );
    });

    test('case differences between name and URL segment still match', () {
      expect(
        forgeUrlFromCreateOutput(
          'https://github.com/mac/MyRepo',
          name: 'myrepo',
        ),
        'https://github.com/mac/MyRepo.git',
      );
    });

    test('empty output or name yields null', () {
      expect(forgeUrlFromCreateOutput('', name: 'r'), isNull);
      expect(forgeUrlFromCreateOutput('https://x.com/r', name: ''), isNull);
    });
  });
}
