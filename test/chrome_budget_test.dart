// How much vertical space the repository chrome costs.
//
// MADR 0008's estimate for the deleted second toolbar band was a derived 54px;
// these are measured, and they are the numbers the decision record should
// carry. The bar's own height is density- and size-class-dependent, so all
// three size classes are measured at both densities.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/features/common/repository_context.dart';
import 'package:remote_magic_git/features/common/repository_context_bar.dart';
import 'package:remote_magic_git/features/common/repository_workspace_scaffold.dart';

const _snapshot = RepositoryContextSnapshot(
  repositoryPath: '/srv/magic-git',
  repositoryName: 'magic-git',
  branchLabel: 'main',
  changedCount: 3,
  conflictCount: 0,
  hasUpstream: true,
  hasConfiguredRemote: true,
  ahead: 1,
);

class _Density extends AppSettingsNotifier {
  _Density(this._density);
  final WorkspaceDensity _density;

  @override
  AppSettings build() => AppSettings(workspaceDensity: _density);
}

Future<double> _barHeight(
  WidgetTester tester, {
  required double width,
  required WorkspaceDensity density,
}) async {
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // A blank frame first: successive measurements would otherwise reuse the
  // element tree, and the appearance boundary would keep the previous
  // density — which silently made every reading equal to the first.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appSettingsProvider.overrideWith(() => _Density(density))],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 600,
            child: RepositoryWorkspaceScaffold(
              repositoryContext: RepositoryContextBar(
                snapshot: _snapshot,
                primaryAction: resolvePrimaryRepositoryAction(_snapshot),
                onPrimaryAction: (_) {},
                syncGroup: RepositorySyncGroup(onInvoke: (_) {}),
                onStash: () {},
                onRefresh: () {},
              ),
              canvas: const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.getSize(find.byType(RepositoryContextBar)).height;
}

void main() {
  group('the chrome budget', () {
    // 640 is the app's minimum window width; 900 is a typical laptop pane;
    // 1400 is the wide class where the sync group shows all four verbs.
    const widths = [640.0, 900.0, 1400.0];

    testWidgets('is one band, at every size class and density', (tester) async {
      final measured = <String, double>{};
      for (final density in WorkspaceDensity.values) {
        for (final width in widths) {
          final height = await _barHeight(
            tester,
            width: width,
            density: density,
          );
          measured['${density.name}@${width.toInt()}'] = height;

          // The whole point of MADR 0008: repository chrome is ONE band. The
          // Repository screen used to spend this much again on a second one.
          expect(
            height,
            lessThanOrEqualTo(52),
            reason: 'the context bar grew past its 52px comfortable ceiling '
                'at ${density.name}/${width.toInt()}',
          );
          expect(height, greaterThanOrEqualTo(40));
        }
      }

      // Recorded so a regression shows up as a number, not a feeling.
      expect(measured.length, widths.length * WorkspaceDensity.values.length);
      // ignore: avoid_print
      print('chrome budget (bar height): $measured');
    });

    testWidgets('compact density costs less than comfortable', (tester) async {
      final comfortable = await _barHeight(
        tester,
        width: 1400,
        density: WorkspaceDensity.comfortable,
      );
      final compact = await _barHeight(
        tester,
        width: 1400,
        density: WorkspaceDensity.compact,
      );

      expect(compact, lessThan(comfortable));
    });

    testWidgets('and the bar never wraps to a second line', (tester) async {
      // A bar that overflows its own height is a second band by accident.
      for (final width in widths) {
        await _barHeight(
          tester,
          width: width,
          density: WorkspaceDensity.comfortable,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'the context bar overflowed at ${width.toInt()}px',
        );
      }
    });
  });
}
