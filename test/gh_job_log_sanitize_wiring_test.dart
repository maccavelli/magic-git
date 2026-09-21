// Pins where the GitHub job log is cleaned (MADR 0064, F4-A): in
// GhService.runJobLog, so every consumer gets clean text. Both tests feed the
// raw stdout of `gh run view --job <id> --log` through a mock executor and
// never override runJobLogProvider, so they pass only if the service cleans.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/github/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/github/run_jobs_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_scope.dart';
import 'helpers/mock_executor.dart';

const _repo = '/srv/repo';
const _runId = 77;
const _jobId = 104212484924;

// Verbatim from percona/percona-postgresql-operator job 104212484924 (gh
// 2.99.0), with gh's trailing newline.
const _rawStdout =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1856861Z ^[[36;1mmkdir -p  ./dependabot-job-1576676050-1789434129^[[0m\n';
const _cleanLog =
    '2026-09-15T01:02:17.1856861Z mkdir -p  ./dependabot-job-1576676050-1789434129\n';

GhService _serviceWithRawLog() => GhService(
  MockExecutor(
    onExecute: (call) => call.gitArgs.contains('--log')
        ? const SSHCommandResult(exitCode: 0, stdout: _rawStdout, stderr: '')
        : null,
  ),
);

void main() {
  test('runJobLog returns the cleaned log, not gh\'s raw stdout', () async {
    final log = await _serviceWithRawLog().runJobLog(_repo, _jobId);
    expect(log, _cleanLog);
  });

  testWidgets('the run jobs view shows no caret escape text', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      appProviderScope(
        overrides: [
          ghServiceProvider.overrideWithValue(_serviceWithRawLog()),
          runJobsProvider((_repo, _runId)).overrideWith(
            (ref) => Stream.value(const [
              GhJob(
                id: _jobId,
                name: 'Dependabot',
                status: 'completed',
                conclusion: 'success',
              ),
            ]),
          ),
        ],
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

    await tester.tap(find.text('Dependabot'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('mkdir -p  ./dependabot-job'), findsOneWidget);
    expect(find.textContaining('^['), findsNothing);
    expect(find.textContaining('UNKNOWN STEP'), findsNothing);
  });
}
