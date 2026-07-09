// Regression coverage for the live trace log's scrollback cap. A long/chatty
// job must retain a bounded amount of scrollback (not grow unbounded) — the
// eviction itself used to shift the whole remaining chunk list on every
// single `removeAt(0)` call once past the cap, a repeated O(n) cost for the
// rest of a long job's life. Verified via the ListView's own item count
// (bounded regardless of scroll position) rather than visible text, since a
// lazily-built ListView only renders whatever's on-screen.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/gitlab/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/gitlab/pipeline_jobs_view.dart';

const _repo = '/repo';
const _pipelineId = 1;
const _jobId = 900;

/// The trace log's own ListView — the *last* one in the tree once a job is
/// selected (the job list on the left has its own ListView too).
int _traceItemCount(WidgetTester tester) {
  final listView = tester.widget<ListView>(find.byType(ListView).last);
  final delegate = listView.childrenDelegate as SliverChildBuilderDelegate;
  return delegate.estimatedChildCount!;
}

void main() {
  testWidgets(
    'a long chatty job caps retained scrollback instead of growing unbounded',
    (tester) async {
      final controller = StreamController<String>();
      addTearDown(controller.close);
      final container = ProviderContainer(
        overrides: [
          jobsProvider((_repo, _pipelineId)).overrideWith(
            (ref) async => const [
              Job(id: _jobId, name: 'build', stage: 'build', status: 'running'),
            ],
          ),
          jobTraceProvider((
            _repo,
            _jobId,
          )).overrideWith((ref) => controller.stream),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: SizedBox(
              width: 800,
              height: 600,
              child: PipelineJobsView(repoPath: _repo, pipelineId: _pipelineId),
            ),
          ),
        ),
      );
      // Explicit pumps, not pumpAndSettle — the trace log's scroll physics
      // (overscroll glow / jumpTo springback) don't settle on their own.
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('build'));
      await tester.pump();
      await tester.pump();

      // Stream well past the 256KB cap: 4000 chunks of ~100 bytes = ~400KB.
      const chunkSize = 100;
      const chunkCount = 4000;
      for (var i = 0; i < chunkCount; i++) {
        controller.add('chunk-$i-'.padRight(chunkSize, '.'));
      }
      await tester.pump();
      await tester.pump();

      final retained = _traceItemCount(tester);
      expect(
        retained,
        lessThan(chunkCount),
        reason: 'scrollback must be evicted, not retained in full',
      );
      // Bounded near the cap (256KB / ~100 bytes per chunk ≈ 2600), not just
      // "somewhat less than 4000" — catches a broken cap as well as a broken
      // eviction.
      expect(retained, lessThan(3500));
      expect(retained, greaterThan(100));
    },
  );

  testWidgets(
    'the Refresh jobs control invalidates (re-fetches) the jobs provider',
    (tester) async {
      var builds = 0;
      final container = ProviderContainer(
        overrides: [
          jobsProvider((_repo, _pipelineId)).overrideWith((ref) async {
            builds++;
            return const [
              Job(id: _jobId, name: 'build', stage: 'build', status: 'running'),
            ];
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: SizedBox(
              width: 800,
              height: 600,
              child: PipelineJobsView(repoPath: _repo, pipelineId: _pipelineId),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(builds, 1);

      // The refresh affordance — a running pipeline otherwise stays frozen.
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is MacosIcon && w.icon == CupertinoIcons.refresh,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        builds,
        2,
        reason: 'tapping Refresh jobs must re-run the jobs provider',
      );
    },
  );

  testWidgets(
    'a failed job trace renders an error state (not a blank/short log)',
    (tester) async {
      // A failed `glab ci trace` surfaces as a stream error (traceStream now
      // addError's on a non-zero/empty-output trace); the log view must render
      // that error rather than a blank/short "successful" log.
      final container = ProviderContainer(
        // Disable Riverpod's auto-retry so the errored trace provider settles at
        // a clean AsyncError (no perpetual 400ms retry timer that pumpAndSettle
        // would hang on). The live app keeps retries — the widget's hasError
        // handler is what keeps the error visible across those reload cycles.
        retry: (_, _) => null,
        overrides: [
          jobsProvider((_repo, _pipelineId)).overrideWith(
            (ref) async => const [
              Job(id: _jobId, name: 'build', stage: 'build', status: 'failed'),
            ],
          ),
          jobTraceProvider((_repo, _jobId)).overrideWith(
            (ref) => Stream<String>.error(
              const GlabException(
                'glab ci trace failed',
                SSHCommandResult(
                  exitCode: -1,
                  stdout: '',
                  stderr: 'job not found',
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: SizedBox(
              width: 800,
              height: 600,
              child: PipelineJobsView(repoPath: _repo, pipelineId: _pipelineId),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('build'));
      await tester.pumpAndSettle();

      // The trace log renders plain Text chunks under one SelectionArea
      // (cross-chunk copy), so the error is a directly findable Text.
      expect(
        find.textContaining('glab ci trace failed'),
        findsOneWidget,
      );
    },
  );
}
