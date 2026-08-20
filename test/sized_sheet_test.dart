// SizedSheet: makes fixed sheet sizes real. showMacosSheet's route lays its
// page out with TIGHT full-screen constraints, and MacosSheet merely pads
// them (140 px horizontal by default) — so a SizedBox *inside* the sheet is
// force-expanded and its width silently ignored. That was the historical
// bug: every sheet rendered at window-minus-margins no matter what width the
// code asked for. These tests measure the RENDERED size through the real
// showMacosSheet route, not the declared one.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/sized_sheet.dart';

Future<void> _open(WidgetTester tester, WidgetBuilder builder) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (c) {
          ctx = c;
          return const SizedBox.expand();
        },
      ),
    ),
  );
  unawaited(showMacosSheet<void>(context: ctx, builder: builder));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('SizedSheet renders at exactly the requested size', (
    tester,
  ) async {
    await _open(
      tester,
      (_) => const SizedSheet(width: 300, height: 400, child: SizedBox()),
    );
    expect(tester.getSize(find.byType(MacosSheet)), const Size(300, 400));
  });

  testWidgets('height-less SizedSheet wraps content at the fixed width', (
    tester,
  ) async {
    await _open(
      tester,
      (_) => const SizedSheet(width: 300, child: SizedBox(height: 120)),
    );
    final size = tester.getSize(find.byType(MacosSheet));
    expect(size.width, 300);
    expect(size.height, lessThan(200), reason: 'wraps content, not screen');
  });

  testWidgets(
    'a bare MacosSheet force-expands an inner SizedBox — the bug SizedSheet '
    'exists to fix',
    (tester) async {
      await _open(
        tester,
        (_) => const MacosSheet(child: SizedBox(width: 300, height: 400)),
      );
      final size = tester.getSize(find.byType(MacosSheet));
      expect(
        size.width,
        isNot(300),
        reason:
            'tight route constraints override the inner SizedBox — any '
            'fixed-size sheet must go through SizedSheet instead',
      );
    },
  );
}
