import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';

void main() {
  group('GlabService.projectPathFromRemote', () {
    test('parses scp-like origin', () {
      expect(
        GlabService.projectPathFromRemote('git@gitlab.com:group/sub/repo.git'),
        'group/sub/repo',
      );
    });

    test('parses https origin', () {
      expect(
        GlabService.projectPathFromRemote(
          'https://gitlab.com/group/sub/repo.git',
        ),
        'group/sub/repo',
      );
    });
  });
}
