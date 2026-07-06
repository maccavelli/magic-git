import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/viewer/code_view.dart';
import 'package:remote_magic_git/features/viewer/file_content.dart';

Future<void> _pump(
  WidgetTester tester, {
  required String text,
  String? languageId,
  bool wrap = false,
}) async {
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: MacosWindow(
        child: ContentArea(
          builder: (_, _) => CodeView(
            content: FileContent.classify(text),
            languageId: languageId,
            wrap: wrap,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// The concatenated text of every RichText the CodeView rendered — the source
// lines plus the gutter numbers.
String _renderedText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final e in tester.widgetList<RichText>(find.byType(RichText))) {
    buffer.write((e.text as TextSpan).toPlainText());
  }
  return buffer.toString();
}

void main() {
  testWidgets('renders line-number gutter and source content', (tester) async {
    await _pump(tester, text: 'class Foo {}\nvoid main() {}\n', languageId: 'dart');
    // Gutter numbers for the three lines (two + trailing empty).
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    final rendered = _renderedText(tester);
    expect(rendered, contains('class Foo {}'));
    expect(rendered, contains('void main() {}'));
  });

  testWidgets('plain (unknown language) still renders content and gutter', (
    tester,
  ) async {
    await _pump(tester, text: 'just some text', languageId: null);
    expect(find.text('1'), findsOneWidget);
    expect(_renderedText(tester), contains('just some text'));
  });

  testWidgets('word-wrap mode renders without horizontal scroll affordance', (
    tester,
  ) async {
    await _pump(tester, text: 'a\nb\nc', languageId: null, wrap: true);
    // In wrap mode there is no horizontal SingleChildScrollView wrapper.
    final horizontalScrollables = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((s) => s.scrollDirection == Axis.horizontal);
    expect(horizontalScrollables, isEmpty);
    expect(_renderedText(tester), contains('a'));
  });

  testWidgets('no-wrap mode provides a horizontal scroll view', (tester) async {
    await _pump(tester, text: 'a\nb\nc', languageId: null, wrap: false);
    final horizontalScrollables = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((s) => s.scrollDirection == Axis.horizontal);
    expect(horizontalScrollables, isNotEmpty);
  });

  testWidgets('empty file renders a single gutter line and no error', (
    tester,
  ) async {
    await _pump(tester, text: '', languageId: 'dart');
    expect(find.text('1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
