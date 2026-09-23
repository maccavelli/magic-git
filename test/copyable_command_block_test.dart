// The copyable command block (MADR 0070, 0070-PLAN Phase 4): what the user
// copies is byte-for-byte what they were shown, and the text can be selected.

import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/copyable_command_block.dart';

void main() {
  // Every character a shell or PowerShell treats specially, the apostrophe
  // doubling, and a trailing space a trim would lose.
  const command =
      r"New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell "
      r"-Value 'D:\Bob''s Tools\Git\bin\bash.exe' -PropertyType String -Force ";

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    const MacosApp(
      home: MacosWindow(
        child: CopyableCommandBlock(label: 'Run this', command: command),
      ),
    ),
  );

  testWidgets('Copy puts the exact command on the clipboard', (tester) async {
    String? copied;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pump(tester);

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Copy command',
      ),
    );
    await tester.pump();

    expect(copied, command);
  });

  testWidgets('shows the label and the command, selectable', (tester) async {
    await pump(tester);

    expect(find.text('Run this'), findsOneWidget);
    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(text.data, command);
  });
}
