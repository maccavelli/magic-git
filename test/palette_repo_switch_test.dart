// The command palette's fuzzy repo quick-switch: it lists every saved repo
// except the active one, and running an entry routes like the connection
// switcher — a sibling repo on the current connection is a cheap setRepoPath,
// another connection reconnects.

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/common/command_palette.dart';
import 'package:remote_magic_git/features/common/escape_dismissible.dart';

const _repo = '/srv/a';

class _SwitchRecorder {
  final setRepoPathCalls = <String>[];
  final connectToSavedCalls = <(String, String?)>[];
}

class _StubConnection extends ConnectionController {
  _StubConnection(this._state, this.rec);
  final ConnectionState _state;
  final _SwitchRecorder rec;

  @override
  ConnectionState build() => _state;

  @override
  void setRepoPath(String path) => rec.setRepoPathCalls.add(path);

  @override
  Future<void> connectToSaved(SavedConnection conn, {String? repoPath}) async {
    rec.connectToSavedCalls.add((conn.id, repoPath));
  }
}

SavedConnection _conn(String id, String repoPath, List<String> more) =>
    SavedConnection(
      id: id,
      label: id.toUpperCase(),
      host: 'h',
      port: 22,
      username: 'u',
      repoPath: repoPath,
      repoPaths: more,
    );

Future<_SwitchRecorder> _open(WidgetTester tester) async {
  final rec = _SwitchRecorder();
  const state = ConnectionState(
    phase: ConnectionPhase.connected,
    connectionId: 'c1',
    repoPath: _repo,
    repoPaths: [_repo],
    connectionLabel: 'C1',
    host: 'h',
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(() => _StubConnection(state, rec)),
        savedConnectionsProvider.overrideWith(
          (ref) async => [
            _conn('c1', '/srv/a', ['/srv/b']),
            _conn('c2', '/srv/c', const []),
          ],
        ),
        refsProvider(_repo).overrideWith((ref) async => const <GitRef>[]),
        gitWorktreesProvider(
          _repo,
        ).overrideWith((ref) async => const <GitWorktree>[]),
        forgeProvider(_repo).overrideWith((ref) async => Forge.none),
      ],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Builder(
          builder: (context) => Center(
            child: AppPushButton(
              controlSize: ControlSize.large,
              onPressed: () => showMacosSheet<void>(
                context: context,
                builder: (_) => const EscapeDismissible(
                  child: CommandPalette(
                    repoPath: _repo,
                    onGoToPanel: _noopInt,
                    onRefresh: _noop,
                    onOpenSettings: _noop,
                    onOpenShortcuts: _noop,
                    onOpenConnections: _noop,
                    onCloneRepository: _noop,
                    onCreateRepository: _noop,
                    onOpenHistoryWindow: _noop,
                    onUndo: _noop,
                    onDispatchAction: _noopDispatch,
                    onCheckoutBranch: _noopStr,
                    onOpenWorktree: _noopStr,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return rec;
}

void _noop() {}
void _noopInt(int _) {}
void _noopStr(String _) {}
void _noopDispatch(String _, int _) {}

void main() {
  testWidgets('lists saved repos except the active one', (tester) async {
    await _open(tester);
    // Filter to the switch commands so they're built (the palette's ListView is
    // lazy and these sit at the end of a long catalog).
    await tester.enterText(find.byType(MacosTextField), 'Switch to');
    await tester.pumpAndSettle();
    // Sibling on the current connection + a repo on another connection.
    expect(find.text('Switch to b · C1'), findsOneWidget);
    expect(find.text('Switch to c · C2'), findsOneWidget);
    // The active repo (/srv/a on c1) is not offered.
    expect(find.text('Switch to a · C1'), findsNothing);
  });

  testWidgets('switching to a sibling repo calls setRepoPath', (tester) async {
    final rec = await _open(tester);
    await tester.enterText(find.byType(MacosTextField), 'Switch to b');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch to b · C1'));
    await tester.pumpAndSettle();
    expect(rec.setRepoPathCalls, ['/srv/b']);
    expect(rec.connectToSavedCalls, isEmpty);
  });

  testWidgets('switching to another connection reconnects', (tester) async {
    final rec = await _open(tester);
    await tester.enterText(find.byType(MacosTextField), 'Switch to c');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch to c · C2'));
    await tester.pumpAndSettle();
    expect(rec.connectToSavedCalls, [('c2', '/srv/c')]);
    expect(rec.setRepoPathCalls, isEmpty);
  });
}
