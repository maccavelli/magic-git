// MADR 0034 F1: a failed provider must leave a trace.
//
// Retry is off (`noProviderRetry`), and most UI reads through
// `.value ?? const []`, so without an observer a failure produced no retry, no
// log line and no UI — everywhere except the pop-out window, which was the only
// scope in the app that had one.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/providers/provider_failure_observer.dart';
import 'package:remote_magic_git/core/providers/provider_retry_policy.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';

final _boom = FutureProvider<int>(
  name: 'boom',
  (ref) async => throw StateError('kaboom'),
  retry: noProviderRetry,
);

/// Throws synchronously, so `providerDidFail` fires during `read` and the
/// deferred write can be raced against `dispose()`.
final _boomSync = Provider<int>(
  name: 'boomSync',
  (ref) => throw StateError('kaboom'),
);

final _boomFamily = FutureProvider.family<int, String>(
  name: 'boomFamily',
  (ref, key) async => throw StateError('kaboom'),
  retry: noProviderRetry,
);

/// Drains the microtask the observer defers its write onto.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

List<String> _errorLines(ProviderContainer c) => [
  for (final line in c.read(outputLogProvider).lines)
    if (line.kind == OutputLineKind.error) line.text,
];

void main() {
  test(
    'a failed provider is logged, naming the provider and the error',
    () async {
      final container = ProviderContainer(
        retry: noProviderRetry,
        observers: const [ProviderFailureObserver()],
      );
      addTearDown(container.dispose);

      await expectLater(container.read(_boom.future), throwsStateError);
      await _settle();

      expect(_errorLines(container).join('\n'), contains('boom'));
      expect(_errorLines(container).join('\n'), contains('kaboom'));
    },
  );

  test(
    'a family failure names its argument, so two keys are distinguishable',
    () async {
      final container = ProviderContainer(
        retry: noProviderRetry,
        observers: const [ProviderFailureObserver()],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(_boomFamily('/srv/one').future),
        throwsStateError,
      );
      await _settle();

      expect(
        _errorLines(container).join('\n'),
        contains('/srv/one'),
        reason: 'a bare provider name cannot tell two repos apart',
      );
    },
  );

  test('the observer contains a failure in its own write', () async {
    // The write is deferred onto a microtask, so the container can be gone by
    // the time it runs — and reading a disposed container throws. Without the
    // observer's catch that lands as an UNHANDLED async error, which a plain
    // `test()` does NOT fail on. The zone below is what makes this assertion
    // real rather than decorative.
    //
    // Two things had to be right for this test to mean anything, and neither
    // was obvious:
    //  * the container must be disposed BEFORE any `await`, or the microtask
    //    drains while it is still alive and the path under test never runs;
    //  * `read` rethrows a wrapped, riverpod-internal error type — asserting
    //    `throwsStateError` here silently failed the body, the zone swallowed
    //    the TestFailure, and the test hung for 30s instead of failing.
    final escaped = <Object>[];
    final done = Completer<void>();
    runZonedGuarded(() {
      final container = ProviderContainer(
        retry: noProviderRetry,
        observers: const [ProviderFailureObserver()],
      );
      try {
        container.read(_boomSync);
      } catch (_) {
        // `read` rethrows the provider's failure wrapped in a riverpod-
        // internal type that is not exported, so there is nothing useful
        // to pin here. This test's assertion is `escaped`, below.
      }
      container.dispose();
      done.complete();
    }, (error, _) => escaped.add(error));
    await done.future;
    await _settle();

    expect(
      escaped,
      isEmpty,
      reason:
          'a logger that throws while handling a failure turns one problem '
          'into two, and the second has no observer',
    );
  });

  test('the tab container factory attaches the observer', () async {
    // Every tab is its own container; the root scope's observer does not reach
    // them, so this is a separate wiring point and a separate regression.
    final controller = TabsController();
    addTearDown(controller.dispose);
    controller.ensureInitialTab();
    final container = controller.tabs.single.container;

    await expectLater(container.read(_boom.future), throwsStateError);
    await _settle();

    expect(_errorLines(container).join('\n'), contains('kaboom'));
  });

  test('every production provider scope attaches a failure observer', () {
    // Source scan, in the style of provider_retry_policy_test.dart's
    // "every production provider scope uses the policy". A scope without an
    // observer is a piece of the app where a provider can fail in silence —
    // which is exactly the state MADR 0034 F1 found the main window in, while
    // the pop-out window had one.
    //
    // UncontrolledProviderScope is exempt: it adopts a container someone else
    // configured.
    final offenders = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (!RegExp(
          r'(?<![A-Za-z_$])Provider(Scope|Container)\(',
        ).hasMatch(line)) {
          continue;
        }
        final window = lines.skip(i).take(10).join('\n');
        if (!window.contains('observers:')) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Pass `observers: [ProviderFailureObserver()]` so a failed provider '
          'in this scope leaves a trace — retry is off and most UI reads '
          'through `.value ?? const []`, so nothing else will report it. '
          'Unobserved scopes found at:\n${offenders.join('\n')}',
    );
  });
}
