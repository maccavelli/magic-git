import 'dart:convert';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
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
            builder: (_, _) => const Stack(
              children: [Positioned.fill(child: ViewerHost())],
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
}
