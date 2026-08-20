import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/forge/forge_urls.dart';

void main() {
  group('forgeProjectWebUrl', () {
    test('builds https URL from an scp-like remote', () {
      expect(
        forgeProjectWebUrl('git@github.com:owner/repo.git'),
        'https://github.com/owner/repo',
      );
    });

    test('builds https URL from an https remote', () {
      expect(
        forgeProjectWebUrl('https://gitlab.com/group/sub/repo.git'),
        'https://gitlab.com/group/sub/repo',
      );
    });

    test('self-hosted GitLab instance', () {
      expect(
        forgeProjectWebUrl('git@gitlab.example.com:saxsmith/proj.git'),
        'https://gitlab.example.com/saxsmith/proj',
      );
    });

    test('null for an unparseable remote', () {
      expect(forgeProjectWebUrl(''), isNull);
      expect(forgeProjectWebUrl('   '), isNull);
    });
  });

  group('forgeIssueWebUrl', () {
    const remote = 'git@github.com:owner/repo.git';
    const glRemote = 'git@gitlab.com:group/proj.git';

    test('GitHub issue URL', () {
      expect(
        forgeIssueWebUrl(remote, Forge.github, 42),
        'https://github.com/owner/repo/issues/42',
      );
    });

    test('GitLab issue URL with /-/ namespace', () {
      expect(
        forgeIssueWebUrl(glRemote, Forge.gitlab, 7),
        'https://gitlab.com/group/proj/-/issues/7',
      );
    });

    test('none/unknown forge returns null', () {
      expect(forgeIssueWebUrl(remote, Forge.none, 1), isNull);
      expect(forgeIssueWebUrl(remote, Forge.unknown, 1), isNull);
    });

    test('null when remote URL is unparseable', () {
      expect(forgeIssueWebUrl('', Forge.github, 1), isNull);
    });
  });

  group('forgeMilestoneWebUrl', () {
    const remote = 'git@github.com:owner/repo.git';
    const glRemote = 'git@gitlab.com:group/proj.git';

    test('GitHub milestone URL', () {
      expect(
        forgeMilestoneWebUrl(remote, Forge.github, 3),
        'https://github.com/owner/repo/milestone/3',
      );
    });

    test('GitLab milestone URL', () {
      expect(
        forgeMilestoneWebUrl(glRemote, Forge.gitlab, 5),
        'https://gitlab.com/group/proj/-/milestones/5',
      );
    });

    test('none/unknown forge returns null', () {
      expect(forgeMilestoneWebUrl(remote, Forge.none, 1), isNull);
      expect(forgeMilestoneWebUrl(remote, Forge.unknown, 1), isNull);
    });
  });

  group('forgeReleaseWebUrl', () {
    const remote = 'git@github.com:owner/repo.git';
    const glRemote = 'git@gitlab.com:group/proj.git';

    test('GitHub release URL', () {
      expect(
        forgeReleaseWebUrl(remote, Forge.github, 'v1.0.0'),
        'https://github.com/owner/repo/releases/tag/v1.0.0',
      );
    });

    test('GitLab release URL', () {
      expect(
        forgeReleaseWebUrl(glRemote, Forge.gitlab, 'v2.0'),
        'https://gitlab.com/group/proj/-/releases/v2.0',
      );
    });

    test('tag with special characters is URI-encoded', () {
      expect(
        forgeReleaseWebUrl(remote, Forge.github, 'v 1.0'),
        'https://github.com/owner/repo/releases/tag/v%201.0',
      );
    });

    test('none/unknown forge returns null', () {
      expect(forgeReleaseWebUrl(remote, Forge.none, 'v1'), isNull);
      expect(forgeReleaseWebUrl(remote, Forge.unknown, 'v1'), isNull);
    });

    test('null when tag name is empty', () {
      expect(forgeReleaseWebUrl(remote, Forge.github, ''), isNull);
    });
  });
}
