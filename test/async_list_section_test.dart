// asyncListSection must keep the last good rows through a *transient* reload
// error (a flaky refresh / failed "show all"), surfacing the error inline
// above them — collapsing a populated section to a lone red line loses what the
// user was looking at. A pure error with no prior value still shows just the
// error.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/async_views.dart';

final _listProvider = FutureProvider.autoDispose<List<String>>(
  (ref) => throw UnimplementedError('overridden per test'),
);

/// Pumps a real Consumer that watches [_listProvider] through asyncListSection —
/// the same shape the forge panels use.
Future<void> _pumpWatching(WidgetTester tester, ProviderContainer c) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: MacosWindow(
          child: MacosScaffold(
            children: [
              ContentArea(
                builder: (_, _) => Consumer(
                  builder: (_, ref, _) => SingleChildScrollView(
                    child: asyncListSection<String>(
                      ref.watch(_listProvider),
                      'nothing here',
                      (s) => Text(s),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('keeps prior rows and shows the error inline on a reload error', (
    tester,
  ) async {
    var fail = false;
    // retry:null — an errored provider otherwise schedules a perpetual backoff
    // retry timer that pumpAndSettle would hang on.
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        _listProvider.overrideWith((ref) async {
          if (fail) throw 'boom';
          return ['alpha', 'beta'];
        }),
      ],
    );
    addTearDown(container.dispose);

    await _pumpWatching(tester, container);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);

    // Reload → error; Riverpod retains the prior value (hasValue + hasError).
    fail = true;
    container.invalidate(_listProvider);
    await tester.pumpAndSettle();

    expect(find.text('alpha'), findsOneWidget, reason: 'stale rows kept');
    expect(find.text('beta'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget, reason: 'error inline');
  });

  testWidgets('a pure error with no prior rows shows just the error', (
    tester,
  ) async {
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [_listProvider.overrideWith((ref) async => throw 'nope')],
    );
    addTearDown(container.dispose);

    await _pumpWatching(tester, container);
    expect(find.textContaining('nope'), findsOneWidget);
    expect(find.text('alpha'), findsNothing);
  });

  testWidgets('plain data renders the rows', (tester) async {
    final container = ProviderContainer(
      overrides: [
        _listProvider.overrideWith((ref) async => ['one', 'two']),
      ],
    );
    addTearDown(container.dispose);

    await _pumpWatching(tester, container);
    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
  });
}
