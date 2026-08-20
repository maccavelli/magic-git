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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/provider_retry_policy.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;

import 'helpers/app_scope.dart';

/// No `retry:` — the pre-0017 shape, kept as the contrast case above.
final _unannotated = FutureProvider.autoDispose<int>((ref) async => 1);

/// Renders which `when` branch a provider resolved to, so a widget test can
/// assert the branch rather than the AsyncValue's internals.
class _StatusProbe extends ConsumerWidget {
  const _StatusProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Text(
    ref
        .watch(statusProvider('/repo'))
        .when(
          data: (_) => 'data',
          error: (_, _) => 'error',
          loading: () => 'loading',
        ),
    textDirection: TextDirection.ltr,
  );
}

class _UnannotatedProbe extends ConsumerWidget {
  const _UnannotatedProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Text(
    ref
        .watch(_unannotated)
        .when(
          data: (_) => 'data',
          error: (_, _) => 'error',
          loading: () => 'loading',
        ),
    textDirection: TextDirection.ltr,
  );
}

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

  testWidgets('a bare scope reaches the error branch for an annotated '
      'provider', (tester) async {
    // The decision's whole claim, asserted directly. Deliberately NOT
    // appProviderScope: the point is that a scope built by someone who never
    // read AGENTS.md behaves like the app anyway, because the policy rides
    // the provider and survives overrideWith.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          statusProvider('/repo').overrideWith(
            (ref) async => throw const GitException(
              'git status failed',
              SSHCommandResult(exitCode: 128, stdout: '', stderr: 'boom'),
            ),
          ),
        ],
        child: const MaterialApp(home: _StatusProbe()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('error'), findsOneWidget);
    expect(find.text('loading'), findsNothing);
  });

  testWidgets('the contrast case: an unannotated provider still stalls', (
    tester,
  ) async {
    // Same bare scope, same thrown Exception — but this provider declares no
    // policy, so it inherits the container's (absent) one and sits in
    // AsyncLoading while Riverpod retries. This is what every annotated
    // provider looked like before, and it is why the scan in this file
    // exists.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _unannotated.overrideWith((ref) async => throw Exception('boom')),
        ],
        child: const MaterialApp(home: _UnannotatedProbe()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('loading'), findsOneWidget);
    expect(find.text('error'), findsNothing);
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

  test('every async provider declares the retry policy', () {
    // The container policy is a backstop; the provider's own is what makes a
    // test scope behave like the app (origin.retry wins, and it survives
    // overrideWith). A provider without it inherits whatever the enclosing
    // scope chose — which is not the same thing in a test as in production.
    //
    // A provider with genuinely no async failure mode goes here with a
    // reason, the way _bareTapAllowance documents its entries.
    const allowed = <String, int>{};

    final offenders = <String, List<int>>{};
    final declaration = RegExp(
      r'^final [A-Za-z0-9_]+Provider = '
      r'(FutureProvider|StreamProvider|AsyncNotifierProvider)',
    );

    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      final lines = source.split('\n');
      var offset = 0;
      for (var i = 0; i < lines.length; i++) {
        final lineStart = offset;
        offset += lines[i].length + 1;
        if (!declaration.hasMatch(lines[i])) continue;
        final end = _declarationEnd(source, lineStart);
        if (!source.substring(lineStart, end).contains('retry:')) {
          (offenders[file.path] ??= []).add(i + 1);
        }
      }
    }

    final failures = <String>[];
    for (final entry in offenders.entries) {
      final budget = allowed[entry.key] ?? 0;
      if (entry.value.length > budget) {
        failures.add(
          '${entry.key}: lines ${entry.value.join(', ')} '
          '(${entry.value.length} bare, $budget allowed)',
        );
      }
    }

    expect(
      failures,
      isEmpty,
      reason:
          'Pass `retry: noProviderRetry` '
          '(core/providers/provider_retry_policy.dart) so this provider '
          'surfaces failures identically in the app and in a test, whatever '
          'scope reads it. Unannotated declarations found:\n'
          '${failures.join('\n')}',
    );
  });
}

/// Offset just past the `)` closing a provider declaration's argument list.
///
/// Needs to understand Dart lexically, not just count parens: this codebase
/// embeds shell scripts full of unbalanced parens in string literals, and
/// record types in type arguments (`family<T, ({String repoPath})>`) open a
/// paren before the argument list does.
int _declarationEnd(String source, int start) {
  var i = _argumentListOpen(source, start);
  var depth = 0;
  while (i < source.length) {
    final c = source[i];
    if (_startsLineComment(source, i)) {
      final nl = source.indexOf('\n', i);
      i = nl < 0 ? source.length : nl + 1;
      continue;
    }
    if (c == "'" || c == '"') {
      i = _skipString(source, i);
      continue;
    }
    if (c == 'r' &&
        i + 1 < source.length &&
        (source[i + 1] == "'" || source[i + 1] == '"')) {
      i = _skipString(source, i + 1);
      continue;
    }
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i + 1;
    }
    i++;
  }
  fail('unterminated provider declaration at offset $start');
}

/// Offset of the `(` opening the argument list, skipping type arguments.
int _argumentListOpen(String source, int start) {
  var i = start;
  var angle = 0;
  while (i < source.length) {
    final c = source[i];
    if (c == "'" || c == '"') {
      i = _skipString(source, i);
      continue;
    }
    if (c == '<') {
      angle++;
    } else if (c == '>') {
      if (angle > 0) angle--;
    } else if (c == '(' && angle == 0) {
      return i;
    }
    i++;
  }
  fail('no argument list at offset $start');
}

bool _startsLineComment(String source, int i) =>
    source[i] == '/' && i + 1 < source.length && source[i + 1] == '/';

/// Offset just past the closing quote of the string literal starting at [i].
int _skipString(String source, int i) {
  final quote = source[i];
  final triple = source.startsWith(quote * 3, i);
  final terminator = triple ? quote * 3 : quote;
  i += terminator.length;
  while (i < source.length) {
    if (source[i] == r'\') {
      i += 2;
      continue;
    }
    if (!triple && source[i] == '\n') return i;
    if (source.startsWith(terminator, i)) return i + terminator.length;
    i++;
  }
  return source.length;
}
