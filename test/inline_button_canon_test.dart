// Pins the canonical small-button policy: a compact labelled action embedded
// in content (banner buttons, per-row actions, form helpers) is an
// InlineActionButton (common/inline_action_button.dart) — the capsule born as
// the diff views' Stage/Unstage/Discard button — never a small PushButton.
// AppPushButton at regular/large remains for a sheet's primary Cancel/Save
// row. The source scan makes the standard enforceable: a small push button
// can't slip back in.

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/inline_action_button.dart';

// 'ControlSize' + '.small' spliced so this file's own scan can't match its
// source (same trick as button_cursor_canon_test.dart).
final _smallControl = RegExp('${'ControlSize'}\\.(small|mini)\\b');

Iterable<File> _dartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  test('no small/mini push buttons anywhere — inline actions use '
      'InlineActionButton', () {
    final offenders = <String>[];
    for (final f in _dartFiles()) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (_smallControl.hasMatch(line)) {
          offenders.add('${f.path}:${i + 1}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Small push buttons are off-standard. Use InlineActionButton '
          '(common/inline_action_button.dart) for compact inline actions; '
          'ControlSize.regular/large AppPushButtons are for sheet footers. '
          'Found at:\n${offenders.join('\n')}',
    );
  });

  testWidgets('a disabled InlineActionButton is inert; enabled one fires', (
    tester,
  ) async {
    var fired = 0;
    Widget host(VoidCallback? onPressed) => MacosApp(
      debugShowCheckedModeBanner: false,
      home: Center(
        child: InlineActionButton(
          label: 'Do it',
          icon: CupertinoIcons.play,
          onPressed: onPressed,
        ),
      ),
    );

    await tester.pumpWidget(host(null));
    await tester.tap(find.text('Do it'));
    await tester.pump();
    expect(fired, 0);

    await tester.pumpWidget(host(() => fired++));
    await tester.tap(find.text('Do it'));
    await tester.pump();
    expect(fired, 1);
  });
}
