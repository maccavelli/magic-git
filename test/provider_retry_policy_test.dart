// Pins the app's provider retry policy and — more importantly — the
// framework behaviour that makes it load-bearing.
//
// Asserting only that `noProviderRetry` returns null would be a tautology.
// What matters is that WITHOUT it a failed provider never reaches its error
// branch at all, so any test that builds a bare scope cannot assert error UI.
// That trap cost a real debugging session; the negative test below is the
// documentation of it. Do not delete it as "testing the framework" — it is
// the reason `helpers/app_scope.dart` exists, and it will fail loudly if a
// Riverpod upgrade changes the default.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/provider_retry_policy.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;

import 'helpers/app_scope.dart';

final _throwingFuture = FutureProvider.autoDispose<int>(
  (ref) async => throw Exception('boom'),
);
final _throwingStream = StreamProvider.autoDispose<int>(
  (ref) => Stream<int>.error(Exception('boom')),
);

/// Every state the provider passed through, sampled over enough real time for
/// the default policy's first backoff (~200ms) to fire more than once.
Future<List<AsyncValue<int>>> _observe(
  ProviderContainer container,
  ProviderListenable<AsyncValue<int>> provider,
) async {
  final seen = <AsyncValue<int>>[];
  container.listen<AsyncValue<int>>(
    provider,
    (_, next) => seen.add(next),
    fireImmediately: true,
  );
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  return seen;
}

String _branch(AsyncValue<int> value) => value.when(
  data: (_) => 'data',
  error: (_, _) => 'error',
  loading: () => 'loading',
);

void main() {
  test('the policy never retries, whatever the attempt or error', () {
    expect(noProviderRetry(0, Exception('x')), isNull);
    expect(noProviderRetry(5, const SocketException('x')), isNull);
  });

  test('under the app policy a throwing provider reaches AsyncError', () async {
    for (final provider in [_throwingFuture, _throwingStream]) {
      final container = appProviderContainer();
      addTearDown(container.dispose);

      final seen = await _observe(container, provider);

      expect(seen.first, isA<AsyncLoading<int>>());
      expect(seen.last, isA<AsyncError<int>>());
      expect(_branch(seen.last), 'error');
      // It settles: no retry churn behind the error.
      expect(seen, hasLength(2));
    }
  });

  test('without the policy the provider never emits AsyncError', () async {
    for (final provider in [_throwingFuture, _throwingStream]) {
      // Deliberately NOT appProviderContainer: this is the trap being pinned.
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final seen = await _observe(container, provider);

      expect(
        seen.any((v) => v is AsyncError),
        isFalse,
        reason: 'the default policy never surfaces AsyncError',
      );
      expect(seen.every((v) => v.isLoading), isTrue);

      // The post-failure state carries the error but is an AsyncLoading, so
      // isReloading is true and `when` (skipLoadingOnReload: false) shows the
      // loading branch — forever, while it keeps retrying.
      final afterFailure = seen[1];
      expect(afterFailure.hasError, isTrue);
      expect(afterFailure.isReloading, isTrue);
      expect(_branch(afterFailure), 'loading');
      expect(seen.length, greaterThan(2), reason: 'it is still retrying');
    }
  });

  test('every production provider scope uses the policy', () {
    // Source scan, in the style of button_cursor_canon_test.dart: a scope
    // built without the policy is a piece of the app running Riverpod
    // differently from the rest of it.
    //
    // UncontrolledProviderScope is exempt — it adopts a container someone
    // else configured.
    const allowed = <String>{};
    final offenders = <String>[];

    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    for (final file in files) {
      if (allowed.contains(file.path)) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        final constructs = RegExp(
          r'(?<![A-Za-z_$])Provider(Scope|Container)\(',
        ).hasMatch(line);
        if (!constructs) continue;
        final window = lines.skip(i).take(8).join('\n');
        if (!window.contains('retry:')) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Pass `retry: noProviderRetry` (core/providers/provider_retry_policy.dart) '
          'so this scope surfaces provider failures like the rest of the app. '
          'Unconfigured scopes found at:\n${offenders.join('\n')}',
    );
  });
}
