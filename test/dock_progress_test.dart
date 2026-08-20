// DockProgress: the one place the macOS Dock bar is driven from. The state
// machine (overlapping tracked ops, the determinate override, dedupe of
// repeated sends, swallowed draw failures) and the clone-frame → fraction
// mapping.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/local/dock_progress.dart';
import 'package:remote_magic_git/core/workspace/clone_controller.dart';

void main() {
  final dock = DockProgress.instance;
  late List<double> sent;

  setUp(() {
    dock.reset();
    sent = [];
    dock.sendOverride = (v) async => sent.add(v);
  });

  tearDown(dock.reset);

  test('a tracked op shows the indeterminate bar and hides it after', () async {
    await dock.track(() async {
      expect(sent, [DockProgress.indeterminate]);
    });
    expect(sent, [DockProgress.indeterminate, DockProgress.hidden]);
  });

  test('the bar hides only when the LAST overlapping op finishes', () async {
    late Future<void> inner;
    await dock.track(() async {
      inner = dock.track(() async {});
      await inner;
      // The inner op ended, but this one is still running — no hide between.
      expect(sent, [DockProgress.indeterminate]);
    });
    expect(sent, [DockProgress.indeterminate, DockProgress.hidden]);
  });

  test('a failing op still releases the bar', () async {
    await expectLater(
      dock.track(() async => throw StateError('push rejected')),
      throwsStateError,
    );
    expect(sent, [DockProgress.indeterminate, DockProgress.hidden]);
  });

  test(
    'setFraction overrides indeterminate; ending the op clears it',
    () async {
      await dock.track(() async {
        dock.setFraction(0.25);
        dock.setFraction(0.5);
      });
      expect(sent, [
        DockProgress.indeterminate,
        0.25,
        0.5,
        DockProgress.hidden,
      ]);
    },
  );

  test('fractions are clamped to 0..1', () {
    dock.setFraction(3.7);
    dock.setFraction(-2);
    expect(sent, [1.0, 0.0]);
  });

  test('identical consecutive values are sent once', () async {
    await dock.track(() async {
      dock.setFraction(0.5);
      dock.setFraction(0.5);
      dock.clearFraction(); // back to indeterminate — a genuine change
      dock.clearFraction(); // no-op
    });
    expect(sent, [
      DockProgress.indeterminate,
      0.5,
      DockProgress.indeterminate,
      DockProgress.hidden,
    ]);
  });

  test('a throwing sender is cosmetic — tracking is unaffected', () async {
    dock.sendOverride = (_) async => throw MissingPluginException();
    final result = await dock.track(() async => 42);
    expect(result, 42);
  });

  group('cloneFractionFor', () {
    test('maps the transfer to the first 90% of the bar', () {
      expect(
        CloneJobController.cloneFractionFor('Receiving objects:   0% (1/2000)'),
        0.0,
      );
      expect(
        CloneJobController.cloneFractionFor(
          'Receiving objects:  50% (1000/2000), 1.2 MiB | 800 KiB/s',
        ),
        closeTo(0.45, 1e-9),
      );
      expect(
        CloneJobController.cloneFractionFor('Receiving objects: 100% (2/2)'),
        closeTo(0.9, 1e-9),
      );
    });

    test('maps delta resolution to the last 10%', () {
      expect(
        CloneJobController.cloneFractionFor('Resolving deltas:   0% (0/50)'),
        closeTo(0.9, 1e-9),
      );
      expect(
        CloneJobController.cloneFractionFor(
          'Resolving deltas: 100% (50/50), done.',
        ),
        closeTo(1.0, 1e-9),
      );
    });

    test('remote-side and banner frames stay indeterminate (null)', () {
      expect(
        CloneJobController.cloneFractionFor(
          'remote: Counting objects:  40% (4/10)',
        ),
        isNull,
      );
      expect(
        CloneJobController.cloneFractionFor(
          'remote: Compressing objects:  10% (1/10)',
        ),
        isNull,
      );
      expect(
        CloneJobController.cloneFractionFor("Cloning into 'repo'..."),
        isNull,
      );
      expect(CloneJobController.cloneFractionFor(''), isNull);
    });
  });
}
