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

    test('a telltale only as a substring of a larger label is NOT a match', () {
      // The unanchored contains() this replaced would have called these github.
      // Deferring to unknown routes them through the CLI-auth fallback instead.
      expect(classifyForgeHost('mygithub-mirror.example'), Forge.unknown);
      expect(classifyForgeHost('notgitlab.example.com'), Forge.unknown);
    });

    test('a host carrying both telltales is ambiguous (unknown)', () {
      expect(classifyForgeHost('github.gitlab.com'), Forge.unknown);
    });

    test('the telltale as a whole middle/leading label still matches', () {
      expect(classifyForgeHost('git.github.io'), Forge.github);
      expect(classifyForgeHost('gitlab.mycorp.com'), Forge.gitlab);
    });
  });

  group('authStatusListsHost', () {
    const glabStatus =
        'gitlab.lkqdev.com\n'
        '  ✓ Logged in to gitlab.lkqdev.com as saxsmith (config.yml)\n'
        '  ✓ API calls for gitlab.lkqdev.com are made over https protocol.';
    const ghStatus =
        'github.com\n'
        '  ✓ Logged in to github.com account maccavelli (keyring)';

    test('matches a column-0 host header', () {
      expect(authStatusListsHost(glabStatus, 'gitlab.lkqdev.com'), isTrue);
    });

    test('matches a "Logged in to <host>" line (gh "account" phrasing too)', () {
      expect(authStatusListsHost(ghStatus, 'github.com'), isTrue);
    });

    test('an incidental substring mention is NOT a match', () {
      // The raw contains() scan this replaced would have wrongly matched here.
      expect(
        authStatusListsHost('See https://docs for git.acme.io tips', 'git.acme.io'),
        isFalse,
      );
    });

    test('a longer host that merely contains the target is NOT a match', () {
      expect(
        authStatusListsHost('deploy.git.acme.io\n  ✓ Logged in', 'git.acme.io'),
        isFalse,
      );
    });

    test('a blank host never matches', () {
      expect(authStatusListsHost(glabStatus, ''), isFalse);
    });
  });

  group('remotePathFromUrl', () {
    test('https path, .git stripped', () {
      expect(remotePathFromUrl('https://host/owner/repo.git'), 'owner/repo');
    });

    test('scp-like path', () {
      expect(remotePathFromUrl('git@host:group/repo.git'), 'group/repo');
    });

    test('a trailing slash is trimmed (would otherwise 404 the project)', () {
      expect(remotePathFromUrl('https://gitlab.acme.com/group/repo/'), 'group/repo');
    });

    test('a leading slash after the scp colon is trimmed', () {
      expect(remotePathFromUrl('git@host:/group/repo'), 'group/repo');
    });

    test('nested (subgroup) paths are preserved', () {
      expect(
        remotePathFromUrl('https://gitlab.com/group/sub/repo.git'),
        'group/sub/repo',
      );
    });

    test('blank / hostless urls yield null', () {
      expect(remotePathFromUrl('   '), isNull);
      expect(remotePathFromUrl('git@host'), isNull);
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

  group('forgeGitAuthConfigArgs', () {
    test('github clears ambient helpers and installs gh', () {
      expect(
        forgeGitAuthConfigArgs(Forge.github),
        [
          '-c',
          'credential.helper=',
          '-c',
          'credential.helper=!gh auth git-credential',
        ],
      );
    });

    test('gitlab installs glab', () {
      expect(
        forgeGitAuthConfigArgs(Forge.gitlab),
        [
          '-c',
          'credential.helper=',
          '-c',
          'credential.helper=!glab auth git-credential',
        ],
      );
    });

    test('none/unknown leave host credentials alone', () {
      expect(forgeGitAuthConfigArgs(Forge.none), isEmpty);
      expect(forgeGitAuthConfigArgs(Forge.unknown), isEmpty);
    });

    test('all installs both forge CLIs after a clear', () {
      expect(
        forgeGitAuthConfigArgsAll(),
        [
          '-c',
          'credential.helper=',
          '-c',
          'credential.helper=!gh auth git-credential',
          '-c',
          'credential.helper=!glab auth git-credential',
        ],
      );
    });

    // Pinning the resolved absolute path stops git's credential subprocess
    // from re-resolving `glab`/`gh` on PATH and picking up a shadowing system
    // shim — the failure that broke HTTPS fetch/push with "could not read
    // Username".
    test('a resolved path pins the helper to the absolute binary', () {
      expect(
        forgeGitAuthConfigArgs(Forge.gitlab, glabPath: '/home/u/.local/bin/glab'),
        [
          '-c',
          'credential.helper=',
          '-c',
          'credential.helper=!/home/u/.local/bin/glab auth git-credential',
        ],
      );
      expect(
        forgeGitAuthConfigArgs(Forge.github, ghPath: '/opt/homebrew/bin/gh'),
        [
          '-c',
          'credential.helper=',
          '-c',
          'credential.helper=!/opt/homebrew/bin/gh auth git-credential',
        ],
      );
    });

    test('the matching forge ignores the other CLI\'s resolved path', () {
      // A GitLab remote pins glab; a stray ghPath must not leak in.
      expect(
        forgeGitAuthConfigArgs(
          Forge.gitlab,
          ghPath: '/x/gh',
          glabPath: '/x/glab',
        ),
        contains('credential.helper=!/x/glab auth git-credential'),
      );
    });

    test('all pins both resolved paths', () {
      expect(
        forgeGitAuthConfigArgsAll(ghPath: '/x/gh', glabPath: '/x/glab'),
        [
          '-c',
          'credential.helper=',
          '-c',
          'credential.helper=!/x/gh auth git-credential',
          '-c',
          'credential.helper=!/x/glab auth git-credential',
        ],
      );
    });

    test('an unknown (null/empty) path falls back to the bare CLI name', () {
      expect(
        forgeGitAuthConfigArgs(Forge.gitlab, glabPath: null),
        contains('credential.helper=!glab auth git-credential'),
      );
      expect(
        forgeGitAuthConfigArgs(Forge.gitlab, glabPath: ''),
        contains('credential.helper=!glab auth git-credential'),
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

    test('GitLab slugifies the name into the path — the slug still matches', () {
      // `glab repo create --name "My Repo"` creates `.../my-repo`; a strict
      // name-equality check missed it and lost the round-trip-free URL read.
      expect(
        forgeUrlFromCreateOutput(
          '✓ Created project on GitLab: Group / My Repo - '
          'https://gitlab.corp.example/group/my-repo\n',
          name: 'My Repo',
        ),
        'https://gitlab.corp.example/group/my-repo.git',
      );
    });

    test('the slug match still rejects an unrelated URL in the output', () {
      expect(
        forgeUrlFromCreateOutput(
          'See https://gitlab.com/help/user/project for details',
          name: 'My Repo',
        ),
        isNull,
      );
    });
  });
}
