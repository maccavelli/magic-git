import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/common/tool_icon_button.dart';
import 'package:remote_magic_git/features/viewer/file_content.dart';
import 'package:remote_magic_git/features/viewer/image_preview.dart';
import 'package:remote_magic_git/features/viewer/viewer_host.dart';
import 'package:remote_magic_git/features/viewer/viewer_providers.dart';
import 'package:remote_magic_git/features/viewer/viewer_window.dart';
import 'package:riverpod/misc.dart' show Override;

const _repo = '/repo';

// A 1x1 transparent PNG — enough for Image.memory to decode without error.
final _pngBytes = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8'
  'AAAAASUVORK5CYII=',
);

// Pin the connection's isLocal without a real connect (mirrors the status-view
// tests), so the "Open in Default App" affordance can be exercised both ways.
class _StubConnection extends ConnectionController {
  final ConnectionState _state;
  _StubConnection(this._state);
  @override
  ConnectionState build() => _state;
}

Override _connection({required bool isLocal}) => connectionProvider.overrideWith(
      () => _StubConnection(
        ConnectionState(
          backend: isLocal ? ConnectionBackend.local : ConnectionBackend.ssh,
        ),
      ),
    );

// A ToolIconButton (which paints its glyph via MacosIcon, not a Flutter Icon)
// identified by its tooltip.
Finder _toolButton(String tooltip) => find.byWidgetPredicate(
      (w) => w is ToolIconButton && w.tooltip == tooltip,
    );

Override _content(String path, String raw) =>
    fileContentProvider((_repo, path)).overrideWith(
      (ref) => FileContent.classify(raw),
    );

// A GitService whose reads always throw a given executor-level error, to
// exercise the viewer's read-error mapping end to end.
class _ThrowingGit extends GitService {
  _ThrowingGit(this._error) : super(SSHCommandExecutor(SSHClientManager()));
  final Object _error;
  @override
  Future<String> readFile(String repoPath, String path) async => throw _error;
  @override
  Future<String> readFileBase64(String repoPath, String path) async =>
      throw _error;

  // The viewer's content provider now follows the repo's status (to
  // live-update on external edits) — serve it from the fake rather than
  // letting it fall through to the real (unconfigured) executor, whose
  // read-retry would leave a pending backoff Timer at test teardown.
  @override
  Future<GitStatus> status(String repoPath) async =>
      GitStatus(branch: const GitBranchInfo(), files: const []);
}

Override _throwingGit(Object error) =>
    gitServiceProvider.overrideWithValue(_ThrowingGit(error));

// Concatenated text across RichText + selectable (EditableText) widgets.
String _allText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    buffer.write((rt.text).toPlainText());
  }
  for (final et in tester.widgetList<EditableText>(find.byType(EditableText))) {
    buffer.write(et.controller.text);
  }
  return buffer.toString();
}

Future<ProviderContainer> _pumpHost(
  WidgetTester tester, {
  required List<Override> overrides,
  // When set, an autofocused node underneath the viewer stack — mirrors the
  // real app shell, where the main window already holds focus when a viewer
  // opens (so a viewer relying on `autofocus` alone would never win it).
  FocusNode? mainAreaFocus,
}) async {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: MacosWindow(
          child: ContentArea(
            builder: (_, _) => Stack(
              children: [
                if (mainAreaFocus != null)
                  Focus(
                    focusNode: mainAreaFocus,
                    autofocus: true,
                    child: const SizedBox.expand(),
                  ),
                const Positioned.fill(child: ViewerHost()),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('opening a file shows a window with its name and source', (
    tester,
  ) async {
    final container = await _pumpHost(
      tester,
      overrides: [_content('lib/main.dart', 'void main() {}\n')],
    );
    expect(find.byType(FileViewerWindow), findsNothing);

    container.read(openFileViewersProvider.notifier).open(_repo, 'lib/main.dart');
    await tester.pumpAndSettle();

    expect(find.byType(FileViewerWindow), findsOneWidget);
    final text = _allText(tester);
    expect(text, contains('main.dart')); // title
    expect(text, contains('void main() {}')); // source
  });

  testWidgets('markdown opens in Preview by default and toggles to Source', (
    tester,
  ) async {
    final container = await _pumpHost(
      tester,
      overrides: [_content('README.md', '# Hello world\n')],
    );
    container.read(openFileViewersProvider.notifier).open(_repo, 'README.md');
    await tester.pumpAndSettle();

    // Rendered preview: the heading text is present, the raw '#' marker is not.
    expect(_allText(tester), contains('Hello world'));

    // Switch to Source — raw markdown now visible, with a line-number gutter.
    await tester.tap(_toolButton('Source'));
    await tester.pumpAndSettle();
    expect(_allText(tester), contains('# Hello world'));
    expect(find.text('1'), findsWidgets);
  });

  testWidgets('close button dismisses the window', (tester) async {
    final container = await _pumpHost(
      tester,
      overrides: [_content('a.txt', 'hi')],
    );
    container.read(openFileViewersProvider.notifier).open(_repo, 'a.txt');
    await tester.pumpAndSettle();
    expect(find.byType(FileViewerWindow), findsOneWidget);

    await tester.tap(_toolButton('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(FileViewerWindow), findsNothing);
  });

  testWidgets('binary content shows the binary notice, no code view', (
    tester,
  ) async {
    final container = await _pumpHost(
      tester,
      overrides: [_content('blob.bin', 'abc\x00def')],
    );
    container.read(openFileViewersProvider.notifier).open(_repo, 'blob.bin');
    await tester.pumpAndSettle();
    expect(find.text('Binary file'), findsOneWidget);
  });

  testWidgets('too-large content shows the size notice', (tester) async {
    final big = 'a' * (FileContent.maxRenderChars + 1);
    final container = await _pumpHost(
      tester,
      overrides: [_content('huge.log', big)],
    );
    container.read(openFileViewersProvider.notifier).open(_repo, 'huge.log');
    await tester.pumpAndSettle();
    expect(find.text('File too large to display'), findsOneWidget);
  });

  testWidgets('a raster image renders as an image (not the binary notice)', (
    tester,
  ) async {
    final container = await _pumpHost(
      tester,
      overrides: [
        fileBytesProvider((_repo, 'logo.png')).overrideWith((ref) => _pngBytes),
      ],
    );
    container.read(openFileViewersProvider.notifier).open(_repo, 'logo.png');
    await tester.pumpAndSettle();

    expect(find.byType(ImagePreview), findsOneWidget);
    expect(find.text('Binary file'), findsNothing);
  });

  testWidgets('an SVG opens as a rendered preview and toggles to source', (
    tester,
  ) async {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">'
        '<rect width="8" height="8" fill="red"/></svg>';
    final container = await _pumpHost(
      tester,
      overrides: [_content('icon.svg', svg)],
    );
    container.read(openFileViewersProvider.notifier).open(_repo, 'icon.svg');
    await tester.pumpAndSettle();

    // Default is the rendered vector preview.
    expect(find.byType(SvgPreview), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);

    // Switching to Source shows the XML.
    await tester.tap(_toolButton('Source'));
    await tester.pumpAndSettle();
    expect(find.byType(SvgPreview), findsNothing);
    expect(_allText(tester), contains('<svg'));
  });

  testWidgets(
    'the fallback notice offers "Open in Default App" only on a local repo',
    (tester) async {
      // Local: the button is offered.
      final local = await _pumpHost(
        tester,
        overrides: [
          _content('blob.bin', 'abc\x00def'),
          _connection(isLocal: true),
        ],
      );
      local.read(openFileViewersProvider.notifier).open(_repo, 'blob.bin');
      await tester.pumpAndSettle();
      expect(find.text('Binary file'), findsOneWidget);
      expect(find.text('Open in Default App'), findsOneWidget);
    },
  );

  testWidgets('an SSH (remote) repo hides the "Open in Default App" button', (
    tester,
  ) async {
    final remote = await _pumpHost(
      tester,
      overrides: [
        _content('blob.bin', 'abc\x00def'),
        _connection(isLocal: false),
      ],
    );
    remote.read(openFileViewersProvider.notifier).open(_repo, 'blob.bin');
    await tester.pumpAndSettle();
    expect(find.text('Binary file'), findsOneWidget);
    expect(find.text('Open in Default App'), findsNothing);
  });

  testWidgets(
    'opens without throwing when the host is smaller than the min window size',
    (tester) async {
      // A host (419x259) just below the 420x260 minimum used to make
      // initState's `value.clamp(_minWidth, bounds.width)` throw ArgumentError
      // (lower > upper) while building the window.
      final container = ProviderContainer(
        overrides: [_content('a.txt', 'hi')],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            home: MacosWindow(
              child: ContentArea(
                builder: (_, _) => Stack(
                  children: [
                    FileViewerWindow(
                      id: 1,
                      repoPath: _repo,
                      path: 'a.txt',
                      bounds: const Size(419, 259),
                      isFront: true,
                      onClose: () {},
                      onFocus: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(FileViewerWindow), findsOneWidget);
    },
  );

  testWidgets('a read timeout surfaces a clean message, not the raw error', (
    tester,
  ) async {
    final container = await _pumpHost(
      tester,
      overrides: [_throwingGit(const SSHCommandTimeout('cat -- f.txt'))],
    );
    container.read(openFileViewersProvider.notifier).open(_repo, 'f.txt');
    await tester.pumpAndSettle();

    final text = _allText(tester);
    expect(text, contains('Timed out'));
    // The raw transport string must not leak through.
    expect(text, isNot(contains('SSH command timed out')));
  });

  testWidgets('an over-cap read shows the size notice with open-externally', (
    tester,
  ) async {
    final container = await _pumpHost(
      tester,
      overrides: [
        _throwingGit(const SSHOutputExceeded('cat -- big.log')),
        _connection(isLocal: true),
      ],
    );
    container.read(openFileViewersProvider.notifier).open(_repo, 'big.log');
    await tester.pumpAndSettle();

    expect(find.text('File too large to display'), findsOneWidget);
    expect(find.text('Open in Default App'), findsOneWidget);
  });

  testWidgets('a too-large image shows the size notice, not a raw error', (
    tester,
  ) async {
    final container = await _pumpHost(
      tester,
      overrides: [_throwingGit(const SSHOutputExceeded('base64 < logo.png'))],
    );
    container.read(openFileViewersProvider.notifier).open(_repo, 'logo.png');
    await tester.pumpAndSettle();

    expect(find.text('File too large to display'), findsOneWidget);
  });

  testWidgets('Copy file contents copies the full source to the clipboard', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final container = await _pumpHost(
      tester,
      overrides: [_content('a.dart', 'void main() {}\n')],
    );
    container.read(openFileViewersProvider.notifier).open(_repo, 'a.dart');
    await tester.pumpAndSettle();

    await tester.tap(_toolButton('Copy file contents'));
    await tester.pumpAndSettle();
    expect(copied, ['void main() {}\n']);
  });

  testWidgets('two files open two windows; reopening one does not duplicate', (
    tester,
  ) async {
    final container = await _pumpHost(
      tester,
      overrides: [
        _content('a.txt', 'aaa'),
        _content('b.txt', 'bbb'),
      ],
    );
    final notifier = container.read(openFileViewersProvider.notifier);
    notifier.open(_repo, 'a.txt');
    notifier.open(_repo, 'b.txt');
    await tester.pumpAndSettle();
    expect(find.byType(FileViewerWindow), findsNWidgets(2));

    notifier.open(_repo, 'a.txt'); // already open → focus, not duplicate
    await tester.pumpAndSettle();
    expect(find.byType(FileViewerWindow), findsNWidgets(2));
  });

  testWidgets('Escape closes the front window; a second Escape closes the next', (
    tester,
  ) async {
    final container = await _pumpHost(
      tester,
      overrides: [_content('a.txt', 'aaa'), _content('b.txt', 'bbb')],
    );
    final notifier = container.read(openFileViewersProvider.notifier);
    notifier.open(_repo, 'a.txt');
    notifier.open(_repo, 'b.txt');
    await tester.pumpAndSettle();
    expect(find.byType(FileViewerWindow), findsNWidgets(2));

    // Focus the front window the way a user would — a click (onPointerDown
    // requests focus). The last window in the stack is front-most.
    await tester.tap(find.byType(FileViewerWindow).last);
    await tester.pumpAndSettle();

    // Escape closes the front (b.txt); after it closes the new front (a.txt)
    // must take focus so a second Escape isn't swallowed.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(FileViewerWindow), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(FileViewerWindow), findsNothing);
  });

  testWidgets(
    'a newly opened window takes keyboard focus — Escape closes it '
    'without clicking it first',
    (tester) async {
      final mainFocus = FocusNode();
      addTearDown(mainFocus.dispose);
      final container = await _pumpHost(
        tester,
        overrides: [_content('a.txt', 'aaa')],
        mainAreaFocus: mainFocus,
      );
      expect(mainFocus.hasFocus, isTrue, reason: 'main area holds focus');

      container.read(openFileViewersProvider.notifier).open(_repo, 'a.txt');
      await tester.pumpAndSettle();
      expect(find.byType(FileViewerWindow), findsOneWidget);

      // No tap: the fresh window must have grabbed focus on its own (the
      // main area held focus before it opened, so autofocus alone would
      // never win it).
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(FileViewerWindow), findsNothing);
    },
  );

  testWidgets('⌘F opens in-file find, counts matches, Enter steps through', (
    tester,
  ) async {
    final container = await _pumpHost(
      tester,
      overrides: [
        _content('a.txt', 'alpha\nbeta needle\ngamma\ndelta needle\nzeta\n'),
      ],
    );
    container.read(openFileViewersProvider.notifier).open(_repo, 'a.txt');
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FileViewerWindow));
    await tester.pumpAndSettle();

    // No find bar until ⌘F.
    final findField = find.byWidgetPredicate(
      (w) => w is MacosTextField && w.placeholder == 'Find in file',
    );
    expect(findField, findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(findField, findsOneWidget);

    await tester.enterText(findField, 'needle');
    await tester.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);

    // Enter advances to the next matching line.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
  });

  testWidgets(
    'Escape closes the find bar first (even while its field has focus), '
    'then the window',
    (tester) async {
      final container = await _pumpHost(
        tester,
        overrides: [_content('a.txt', 'alpha\nbeta\n')],
      );
      container.read(openFileViewersProvider.notifier).open(_repo, 'a.txt');
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      final findField = find.byWidgetPredicate(
        (w) => w is MacosTextField && w.placeholder == 'Find in file',
      );
      expect(findField, findsOneWidget);

      // The find field holds focus — exactly the state where a focus-routed
      // Escape used to get swallowed. One Escape closes only the bar.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(findField, findsNothing);
      expect(find.byType(FileViewerWindow), findsOneWidget);

      // Focus is back on the window, so the next Escape closes it.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(FileViewerWindow), findsNothing);
    },
  );

  testWidgets('⌘W closes the front viewer window', (tester) async {
    final container = await _pumpHost(
      tester,
      overrides: [_content('a.txt', 'aaa')],
    );
    container.read(openFileViewersProvider.notifier).open(_repo, 'a.txt');
    await tester.pumpAndSettle();
    expect(find.byType(FileViewerWindow), findsOneWidget);

    await tester.tap(find.byType(FileViewerWindow));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.byType(FileViewerWindow), findsNothing);
  });
}
