import 'package:flutter/widgets.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/viewer/preview_view.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: MacosWindow(child: ContentArea(builder: (_, _) => child)),
    ),
  );
  await tester.pumpAndSettle();
}

// Concatenated text of everything rendered. Selectable text (used by the
// Markdown renderer) lives in EditableText, not RichText, so gather both.
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

void main() {
  group('MarkdownPreview', () {
    testWidgets('renders headings, body text and list items', (tester) async {
      await _pump(
        tester,
        const MarkdownPreview(
          source: '# Title\n\nSome **bold** body.\n\n- one\n- two\n',
        ),
      );
      final text = _allText(tester);
      expect(text, contains('Title'));
      expect(text, contains('body'));
      expect(text, contains('one'));
      expect(text, contains('two'));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'image is replaced by an inert placeholder (no network fetch)',
      (tester) async {
        await _pump(
          tester,
          const MarkdownPreview(
            source: '![the alt text](https://example.com/pic.png)',
          ),
        );
        // No real image widget is ever created — only our placeholder, labelled
        // with the alt text.
        expect(find.byType(Image), findsNothing);
        expect(find.text('the alt text'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a web link is wired to open externally; other schemes stay '
        'inert (0009 M34)', (tester) async {
      await _pump(
        tester,
        const MarkdownPreview(source: '[click me](https://example.com)'),
      );
      expect(_allText(tester), contains('click me'));
      // Verified by construction (an inline link span inside selectable rich
      // text isn't tap-targetable in a widget test): the handler exists, and
      // a non-web scheme passed through it launches nothing and throws
      // nothing.
      final markdown = tester.widget<Markdown>(find.byType(Markdown));
      expect(
        markdown.onTapLink,
        isNotNull,
        reason: 'a styled link that does nothing on click is a taught no-op',
      );
      markdown.onTapLink!('mail', 'mailto:x@example.com', '');
      markdown.onTapLink!('rel', 'docs/other.md', '');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('HtmlPreview', () {
    testWidgets('renders headings and paragraph text', (tester) async {
      await _pump(
        tester,
        const HtmlPreview(
          source: '<h1>Heading</h1><p>Paragraph body here.</p>',
        ),
      );
      final text = _allText(tester);
      expect(text, contains('Heading'));
      expect(text, contains('Paragraph body here.'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('img tag becomes an inert placeholder (no network fetch)', (
      tester,
    ) async {
      await _pump(
        tester,
        const HtmlPreview(
          source: '<img src="https://example.com/x.png" alt="logo alt">',
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('logo alt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('script content is not rendered', (tester) async {
      await _pump(
        tester,
        const HtmlPreview(
          source:
              '<p>visible</p><script>var secret = "should-not-render";'
              '</script>',
        ),
      );
      final text = _allText(tester);
      expect(text, contains('visible'));
      expect(text, isNot(contains('should-not-render')));
    });
  });
}
