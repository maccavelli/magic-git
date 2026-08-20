// Smoke coverage for the GitHub run-jobs pane. GitLab's equivalent has
// pipeline_jobs_view_test.dart; this side had nothing, so a broken provider
// key or a null job list would only have shown up in the app.
//
// Three paths: jobs listed, the empty run, and the error run (which routes
// through PaneError — the same widget the connect-time auth spinner uses).

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/github/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/github/run_jobs_view.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_scope.dart';

const _repo = '/srv/repo';
const _runId = 77;

Future<void> _pump(WidgetTester tester, List<Override> overrides) async {
  SharedPreferences.setMockInitialValues(const {});
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    appProviderScope(
      // Not a bare ProviderScope: without the app's retry policy a failed
      // fetch never emits AsyncError and the error test below is unreachable.
      overrides: overrides,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox.expand(
          child: RunJobsView(repoPath: _repo, runId: _runId),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('lists the run\'s jobs', (tester) async {
    await _pump(tester, [
      runJobsProvider((_repo, _runId)).overrideWith(
        (ref) => Stream.value(const [
          GhJob(
            id: 1,
            name: 'build',
            status: 'completed',
            conclusion: 'success',
          ),
          GhJob(id: 2, name: 'test', status: 'in_progress'),
        ]),
      ),
    ]);

    expect(find.text('Jobs'), findsOneWidget);
    expect(find.text('build'), findsOneWidget);
    expect(find.text('test'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty run says so instead of rendering a blank pane', (
    tester,
  ) async {
    await _pump(tester, [
      runJobsProvider((
        _repo,
        _runId,
      )).overrideWith((ref) => Stream.value(const <GhJob>[])),
    ]);

    expect(find.text('No jobs'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed jobs fetch surfaces the error, not an empty list', (
    tester,
  ) async {
    await _pump(tester, [
      runJobsProvider((_repo, _runId)).overrideWith(
        (ref) => Stream<List<GhJob>>.error(Exception('gh api: HTTP 404')),
      ),
    ]);
    expect(find.textContaining('HTTP 404'), findsOneWidget);
    expect(find.text('No jobs'), findsNothing);
  });

  testWidgets('selecting a completed job shows its log', (tester) async {
    await _pump(tester, [
      runJobsProvider((_repo, _runId)).overrideWith(
        (ref) => Stream.value(const [
          GhJob(
            id: 1,
            name: 'build',
            status: 'completed',
            conclusion: 'success',
          ),
        ]),
      ),
      runJobLogProvider((_repo, 1)).overrideWith((ref) async => 'compiled ok'),
    ]);

    await tester.tap(find.text('build'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('compiled ok'), findsOneWidget);
  });
}
