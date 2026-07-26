import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/local/dock_progress.dart';
import 'package:remote_magic_git/features/common/actions.dart';

class _Host extends StatelessWidget {
  final bool throwOnAction;
  final String? errorMessage;
  const _Host({this.throwOnAction = false, this.errorMessage});

  @override
  Widget build(BuildContext context) {
    return MacosApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            await runAction(
              context,
              () async {
                if (throwOnAction) {
                  throw Exception(errorMessage ?? 'op failed');
                }
              },
              dock: false,
            );
          },
          child: const Text('Run'),
        ),
      ),
    );
  }
}

void main() {
  group('runAction', () {
    testWidgets('returns true on success', (tester) async {
      var actionRan = false;
      await tester.pumpWidget(
        MacosApp(
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final ok = await runAction(context, () async {
                  actionRan = true;
                });
                expect(ok, isTrue);
              },
              child: const Text('Run'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Run'));
      await tester.pump();
      expect(actionRan, isTrue);
    });

    testWidgets('shows error dialog and returns false on failure', (
      tester,
    ) async {
      await tester.pumpWidget(
        MacosApp(
          debugShowCheckedModeBanner: false,
          home: const _Host(throwOnAction: true, errorMessage: 'something broke'),
        ),
      );
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(find.textContaining('something broke'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.textContaining('something broke'), findsNothing);
    });

    testWidgets('shows humanized error for non-Exception throws', (
      tester,
    ) async {
      await tester.pumpWidget(
        MacosApp(
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await runAction(context, () async => throw 'string error');
              },
              child: const Text('Run'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      // displayError('string error') → humanizeSshError → strips "Exception:"
      expect(find.textContaining('string error'), findsOneWidget);
    });

    testWidgets('tracks action through DockProgress when dock flag is set', (
      tester,
    ) async {
      final dockCalls = <double>[];
      DockProgress.instance.sendOverride = (v) async {
        dockCalls.add(v);
      };
      addTearDown(() => DockProgress.instance.sendOverride = null);

      await tester.pumpWidget(
        MacosApp(
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final ok = await runAction(
                  context,
                  () async {},
                  dock: true,
                );
                expect(ok, isTrue);
              },
              child: const Text('Run'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pump();
      expect(dockCalls.length, 2);
      expect(dockCalls[0], DockProgress.indeterminate);
      expect(dockCalls[1], DockProgress.hidden);
    });
  });

  group('confirmAction', () {
    testWidgets('confirm returns true', (tester) async {
      var result = false;
      await tester.pumpWidget(
        MacosApp(
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await confirmAction(
                  context,
                  title: 'Proceed?',
                  message: 'Are you sure?',
                );
              },
              child: const Text('Show'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(find.text('Proceed?'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('cancel returns false', (tester) async {
      var result = true;
      await tester.pumpWidget(
        MacosApp(
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await confirmAction(
                  context,
                  title: 'Proceed?',
                  message: 'Are you sure?',
                );
              },
              child: const Text('Show'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });
  });
}
