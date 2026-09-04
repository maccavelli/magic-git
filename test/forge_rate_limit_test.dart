// Recognizing a forge rate limit rather than reporting it as a generic
// failure (0022 M9). The asymmetry that matters: GitLab answers 429, GitHub
// answers 403 for its primary limit and explains in the text — so a 403 alone
// must NOT be read as a rate limit, or a genuine permission error sends the
// user off to wait for something waiting cannot fix.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge_rate_limit.dart';

void main() {
  group('isForgeRateLimited', () {
    test('429 is unambiguous, with or without text', () {
      expect(isForgeRateLimited(status: 429), isTrue);
      expect(isForgeRateLimited(status: 429, output: 'whatever'), isTrue);
    });

    test('403 counts only when the text says rate limit', () {
      expect(
        isForgeRateLimited(
          status: 403,
          output: 'API rate limit exceeded for user ID 1.',
        ),
        isTrue,
      );
      expect(
        isForgeRateLimited(
          status: 403,
          output: 'Resource not accessible by personal access token',
        ),
        isFalse,
        reason: 'a missing scope is not something waiting fixes',
      );
    });

    test('an ordinary failure is not a rate limit', () {
      expect(isForgeRateLimited(status: 404, output: 'Not Found'), isFalse);
      expect(isForgeRateLimited(status: 500, output: 'server error'), isFalse);
      expect(
        isForgeRateLimited(output: 'fatal: repository not found'),
        isFalse,
      );
    });

    test('text alone is enough when no status was parsed', () {
      // A CLI that printed only to stderr gives no status to go on.
      expect(
        isForgeRateLimited(output: 'You have exceeded a secondary rate limit'),
        isTrue,
      );
    });
  });

  group('message', () {
    test('carries the wait when Retry-After is present', () {
      final msg = forgeRateLimitMessage(
        'gh pr list',
        output: 'HTTP/2 429\nRetry-After: 90\n',
      );
      expect(msg, contains('rate limited'));
      expect(msg, contains('2 minutes'));
    });

    test('says nothing about waiting when no hint was given', () {
      final msg = forgeRateLimitMessage('glab mr list', output: 'HTTP/2 429');
      expect(msg, contains('rate limited'));
      expect(msg, isNot(contains('Try again')));
    });

    test('an HTTP-date Retry-After is ignored, not guessed at', () {
      // Parsing it approximately would put a wrong number in front of the user,
      // which is worse than no number.
      expect(
        retryAfterSeconds('Retry-After: Wed, 21 Oct 2026 07:28:00 GMT'),
        isNull,
      );
    });
  });
}
