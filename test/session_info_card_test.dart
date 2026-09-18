// MADR 0052: the sidebar info card — the Repository row (the shared name: the
// tab alias when set, else the directory) over the Location row (the SSH host,
// or This Mac), in one bordered card. Repository labels stay out of it.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/switcher/current_repo_indicator.dart';
import 'package:remote_magic_git/features/tabs/tab_ui_providers.dart';

class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;
  @override
  ConnectionState build() => _state;
}

const _sshState = ConnectionState(
  phase: ConnectionPhase.connected,
  backend: ConnectionBackend.ssh,
  host: 'build01.example.com',
  connectionId: 'c1',
  connectionLabel: 'Build box',
  repoPath: '/srv/repo',
  repoPaths: ['/srv/repo'],
);

const _saved = SavedConnection(
  id: 'c1',
  label: 'Build box',
  host: 'build01.example.com',
  port: 2222,
  username: 'deploy',
  repoPath: '/srv/repo',
);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  ConnectionState state, {
  List<SavedConnection> saved = const [],
  List<SavedLocalRepo> savedLocal = const [],
}) async {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      connectionProvider.overrideWith(() => _StubConnection(state)),
      statusProvider.overrideWith(
        (ref, repo) async => GitStatus(
          branch: const GitBranchInfo(head: 'main'),
          files: const [],
        ),
      ),
      savedConnectionsProvider.overrideWith((ref) async => saved),
      savedLocalReposProvider.overrideWith((ref) async => savedLocal),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        home: MacosWindow(child: ContentArea(builder: _builder)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Widget _builder(BuildContext context, ScrollController _) =>
    const Align(alignment: Alignment.bottomCenter, child: SessionInfoCard());

Finder _tooltip(String message) =>
    find.byWidgetPredicate((w) => w is MacosTooltip && w.message == message);

Finder _icon(IconData icon) =>
    find.byWidgetPredicate((w) => w is MacosIcon && w.icon == icon);

void main() {
  testWidgets('L1 a saved SSH connection shows its host, not its label', (
    tester,
  ) async {
    await _pump(tester, _sshState, saved: const [_saved]);

    expect(find.text('Location'), findsOneWidget);
    expect(find.text('build01.example.com'), findsOneWidget);
    expect(find.text('Build box'), findsNothing);
    expect(_tooltip('deploy@build01.example.com:2222'), findsOneWidget);
    expect(_icon(CupertinoIcons.globe), findsOneWidget);
  });

  testWidgets('L2 an ad-hoc SSH connection shows its host', (tester) async {
    await _pump(
      tester,
      const ConnectionState(
        phase: ConnectionPhase.connected,
        backend: ConnectionBackend.ssh,
        host: 'adhoc.example.com',
        connectionLabel: 'adhoc.example.com',
        repoPath: '/srv/repo',
        repoPaths: ['/srv/repo'],
      ),
    );

    expect(find.text('adhoc.example.com'), findsOneWidget);
    expect(_tooltip('adhoc.example.com'), findsOneWidget);
  });

  testWidgets('L3 a local session shows This Mac', (tester) async {
    await _pump(
      tester,
      const ConnectionState(
        phase: ConnectionPhase.connected,
        backend: ConnectionBackend.local,
        connectionLabel: 'my-local-repo',
        repoPath: '/Users/u/code/proj',
        repoPaths: ['/Users/u/code/proj'],
      ),
    );

    expect(find.text('This Mac'), findsOneWidget);
    expect(_tooltip('On this Mac'), findsOneWidget);
    // The local glyph matches the tab and status bar (amendment 0052.1).
    expect(_icon(CupertinoIcons.folder), findsOneWidget);
    expect(_icon(CupertinoIcons.desktopcomputer), findsNothing);
    expect(find.text('Local'), findsNothing);
    expect(find.text('my-local-repo'), findsNothing);
  });

  testWidgets('C1 one bordered card, Repository above Location', (
    tester,
  ) async {
    await _pump(tester, _sshState, saved: const [_saved]);

    expect(
      tester.getTopLeft(find.text('Repository')).dy,
      lessThan(tester.getTopLeft(find.text('Location')).dy),
    );
    final bordered = find.descendant(
      of: find.byType(SessionInfoCard),
      matching: find.byWidgetPredicate((w) {
        if (w is! Container) return false;
        final d = w.decoration;
        return d is BoxDecoration &&
            d.border is Border &&
            (d.border! as Border).top.color == MacosColors.separatorColor;
      }),
    );
    expect(bordered, findsOneWidget);
  });

  testWidgets('R1 the Repository row follows the tab alias', (tester) async {
    final container = await _pump(tester, _sshState, saved: const [_saved]);
    expect(find.text('repo'), findsOneWidget);

    container.read(tabAliasProvider.notifier).set('Backend');
    await tester.pumpAndSettle();

    expect(find.text('Backend'), findsOneWidget);
    expect(find.text('repo'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message.startsWith('/srv/repo'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('R2 a saved repository label does not rename the row', (
    tester,
  ) async {
    await _pump(
      tester,
      _sshState,
      saved: const [
        SavedConnection(
          id: 'c1',
          label: 'Build box',
          host: 'build01.example.com',
          port: 2222,
          username: 'deploy',
          repoPath: '/srv/repo',
          repoLabels: {'/srv/repo': 'Website'},
        ),
      ],
    );

    expect(find.text('Website'), findsNothing);
    expect(find.text('repo'), findsOneWidget);
  });
}
