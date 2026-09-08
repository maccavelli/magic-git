// MADR 0032 Phase 5 — the namespace field as a search input.
//
// The field is still free text, and that is the contract every test here
// works around: the dropdown, the chips and the server search are three
// conveniences layered on a plain text field, and none of them may take the
// field away, block it, or offer a namespace the create would reject.
//
// What is actually being pinned:
//
//  * the tail of the creatable list is REACHABLE — the defect MADR 0032 opened
//    with was 7 of 24 groups offered and 17 with no route to them at all;
//  * a query matches a nested path by its LAST SEGMENT, which is the wildcard
//    behaviour the request asked for;
//  * a debounced server search backfills what the cached list cannot hold, and
//    a superseded response never overwrites a newer one;
//  * a successful create REMEMBERS its namespace, and a failed one does not.

import 'package:flutter/cupertino.dart' hide OverlayVisibilityMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/namespace_suggestions.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/common/tappable.dart';
import 'package:riverpod/misc.dart' show Override;

import 'helpers/create_repo_harness.dart';

Finder _namespaceField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'Search namespaces…',
);

/// A row of the attached dropdown, as distinct from a chip: the rows live in
/// the list, the chips in a `Wrap` above it.
Finder _row(String namespace) =>
    find.descendant(of: find.byType(ListView), matching: find.text(namespace));

/// The dropdown's selectable rows, in the order they are offered.
///
/// Scoped through `Tappable` on purpose: the list also carries section
/// headers, which are `Text` but are not rows, and counting them as offers
/// would make every order assertion here quietly wrong.
List<String> _rowOrder(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Tappable),
        ),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data)
    .whereType<String>()
    .toList();

/// Scrolls the dropdown until [label] is a built row, dragging from a point
/// 20 px below the list's top edge.
///
/// Not `scrollUntilVisible`: that drags from the widget's *center*, and the
/// dropdown hangs below the wizard body's viewport, so its center can sit in
/// clipped space where a pointer hits nothing — which is exactly what happened
/// when the wizard gained a step (MADR 0036) and its header grew 12 px. The
/// top rows are always inside the viewport while the field is. A fresh finder
/// per iteration also sidesteps flutter_test's finder caching.
Future<void> _scrollDropdownTo(WidgetTester tester, String label) async {
  Finder row() =>
      find.descendant(of: find.byType(ListView), matching: find.text(label));
  for (var i = 0; i < 20 && row().evaluate().isEmpty; i++) {
    final from =
        tester.getTopLeft(find.byType(ListView)) + const Offset(100, 20);
    await tester.dragFrom(from, const Offset(0, -60));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// The dropdown's section headers, in order.
List<String> _sections(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(of: find.byType(ListView), matching: find.byType(Text)),
    )
    .map((t) => t.data)
    .whereType<String>()
    .where((s) => s == s.toUpperCase() && s.contains(' '))
    .toList();

const _noOrigin = SSHCommandResult(
  exitCode: 2,
  stdout: '',
  stderr: 'fatal: No such remote',
);

/// Drives the wizard to the Details step in GitHub mode, with the suggestion
/// list stubbed directly — these tests are about the field, not the fetch.
Future<(FakeCreateExecutor, FakeConnectionStore)> _toDetails(
  WidgetTester tester, {
  List<String> recent = const [],
  List<String> all = const [],
  Map<String, DateTime> times = const {},
  List<Override> extraOverrides = const [],
}) async {
  final (_, exec, store) = await pumpConnected(
    tester,
    extraOverrides: [
      namespaceSuggestionsProvider.overrideWith(
        (ref, key) async =>
            NamespaceSuggestions(recent: recent, all: all, times: times),
      ),
      ...extraOverrides,
    ],
  );
  await nextStep(tester); // → Source
  await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
  await tester.pumpAndSettle();
  await nextStep(tester); // → Details
  return (exec, store);
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_namespaceField(), text);
  await tester.pumpAndSettle();
}

/// Past the 150 ms debounce, then settle whatever the search scheduled.
Future<void> _settleSearch(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

void main() {
  group('reaching a namespace', () {
    testWidgets('typing filters the list to matching namespaces', (
      tester,
    ) async {
      await _toDetails(
        tester,
        all: ['me', 'platform', 'team/subgroup', 'infra'],
      );
      await _type(tester, 'pl');

      expect(_row('platform'), findsOneWidget);
      expect(_row('infra'), findsNothing);
      expect(_row('me'), findsNothing);
    });

    testWidgets('a nested path matches on its last segment alone', (
      tester,
    ) async {
      // The wildcard behaviour MADR 0032 was opened for: the user knows the
      // subgroup, not the parent it hangs under.
      await _toDetails(tester, all: ['me', 'team/subgroup', 'other/thing']);
      await _type(tester, 'subgr');

      expect(_row('team/subgroup'), findsOneWidget);
      expect(_row('other/thing'), findsNothing);
    });

    testWidgets('a last-segment match outranks a mid-word one', (tester) async {
      // Substring matching alone would find both and order them by position in
      // the list. Matching the LAST SEGMENT as well is what makes the namespace
      // the user meant come first: an exact segment beats a fragment buried in
      // someone else's name.
      await _toDetails(
        tester,
        all: ['unrelated-subgroup-thing', 'team/subgroup'],
      );
      await _type(tester, 'subgroup');

      expect(_rowOrder(tester), ['team/subgroup', 'unrelated-subgroup-thing']);
    });

    testWidgets('one query matches every namespace sharing its prefix', (
      tester,
    ) async {
      // "I have access to <group> and <group>-software; typing the shorter
      // name should offer both" — the request, with the real names redacted.
      await _toDetails(tester, all: ['alpha', 'alpha-software', 'beta']);
      await _type(tester, 'alph');

      expect(_row('alpha'), findsOneWidget);
      expect(_row('alpha-software'), findsOneWidget);
      expect(_row('beta'), findsNothing);
    });

    testWidgets('focusing the field lists every creatable namespace', (
      tester,
    ) async {
      // The "by scrolling" route of acceptance criterion 1: no typing at all,
      // and the whole list is there — including the tail the chips cut off.
      final many = [for (var i = 0; i < 24; i++) 'group-$i'];
      await _toDetails(tester, all: many);

      expect(find.byType(ListView), findsNothing, reason: 'closed until used');
      await tester.tap(_namespaceField());
      await tester.pumpAndSettle();

      // The list builds lazily, so only the first screenful is realised —
      // which is the point: the rest arrive by scrolling rather than all at
      // once. Asserting the whole list here would assert the row height.
      final visible = _rowOrder(tester);
      expect(visible, isNotEmpty);
      expect(
        visible,
        many.take(visible.length),
        reason: 'a prefix of the list, in order — the count is row height',
      );
      await _scrollDropdownTo(tester, 'group-23');
      expect(_row('group-23'), findsOneWidget, reason: 'the tail is reachable');
    });

    testWidgets('a namespace past the recents section is still reachable', (
      tester,
    ) async {
      // The defect this MADR opened with: the old surface showed an
      // alphabetical head and everything after it had no route at all.
      final many = [for (var i = 0; i < 24; i++) 'group-$i'];
      await _toDetails(tester, all: many);

      await _type(tester, 'group-23');
      expect(_rowOrder(tester), ['group-23'], reason: 'reachable by typing');
    });

    testWidgets('recents come first, under their own heading', (tester) async {
      // The amended 5B: two sections, recents above everything else, so the
      // namespaces the account actually works in are the first thing seen.
      await _toDetails(
        tester,
        recent: ['team/subgroup'],
        all: ['team/subgroup', 'alpha', 'beta'],
      );

      await tester.tap(_namespaceField());
      await tester.pumpAndSettle();

      expect(_sections(tester), [
        'RECENTLY ACTIVE',
        'ALL YOU CAN CREATE IN (2)',
      ]);
      expect(
        _rowOrder(tester).first,
        'team/subgroup',
        reason: 'the recent namespace leads, not the alphabetical first',
      );
      expect(_rowOrder(tester), [
        'team/subgroup',
        'alpha',
        'beta',
      ], reason: 'a recent namespace is not repeated in the second section');
    });

    testWidgets('an account with no recents shows no empty heading', (
      tester,
    ) async {
      // A heading over nothing reads as a fault. A new account, a quiet week
      // or an unreachable forge all land here.
      await _toDetails(tester, all: ['alpha', 'beta']);

      await tester.tap(_namespaceField());
      await tester.pumpAndSettle();

      expect(_sections(tester), ['YOU CAN CREATE IN']);
      expect(_rowOrder(tester), ['alpha', 'beta']);
    });

    testWidgets('the recents section offers ten, not eight', (tester) async {
      // The previous surface capped at 8 while the service already fetched 10,
      // so two were fetched and silently dropped.
      final ten = [for (var i = 0; i < 10; i++) 'recent-$i'];
      await _toDetails(tester, recent: ten, all: ten);

      await tester.tap(_namespaceField());
      await tester.pumpAndSettle();
      await _scrollDropdownTo(tester, 'recent-9');

      expect(_row('recent-9'), findsOneWidget);
    });
  });

  group('choosing one', () {
    testWidgets('tapping a row fills the field', (tester) async {
      await _toDetails(tester, all: ['me', 'team/subgroup']);
      await _type(tester, 'sub');
      await tester.tap(_row('team/subgroup'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<MacosTextField>(_namespaceField()).controller!.text,
        'team/subgroup',
      );
      expect(find.byType(ListView), findsNothing, reason: 'closes on choice');
    });

    testWidgets('arrow-down then Enter chooses from the keyboard', (
      tester,
    ) async {
      await _toDetails(tester, all: ['alpha', 'alpha-software']);
      await _type(tester, 'alph');

      // Highlight starts on the first row; one step down selects the second.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(
        tester.widget<MacosTextField>(_namespaceField()).controller!.text,
        'alpha-software',
      );
    });

    testWidgets('the dropdown does not swallow Escape', (tester) async {
      // Escape belongs to the sheet, not to the list. `CommandPalette` records
      // the same rule: dismissal is registry-based and focus-independent, so a
      // focus-scoped Escape binding here would fight it and win only sometimes.
      // The list closes on choice and on blur instead.
      await _toDetails(tester, all: ['alpha']);
      await _type(tester, 'alph');
      expect(find.byType(ListView), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(
        _namespaceField(),
        findsNothing,
        reason: 'Escape still dismisses the whole sheet, as it always did',
      );
    });

    testWidgets('a namespace the API never returned stays typeable', (
      tester,
    ) async {
      // 0031's contract, and the reason option 5C (a required picker) was
      // rejected: a fresh grant or a paginated tail must not be unreachable.
      await _toDetails(tester, all: ['me']);
      await _type(tester, 'granted/yesterday');

      expect(
        tester.widget<MacosTextField>(_namespaceField()).controller!.text,
        'granted/yesterday',
      );
      // The hint is the proof it reached the create path rather than merely
      // sitting in the field: it renders the composed forge path.
      await tester.enterText(nameField(), 'repo');
      await tester.pumpAndSettle();
      expect(
        find.text('Creates granted/yesterday/repo on the forge.'),
        findsOneWidget,
      );
    });
  });

  group('when it was last used', () {
    testWidgets('a recent row is labelled with its relative time', (
      tester,
    ) async {
      await _toDetails(
        tester,
        recent: ['team/subgroup'],
        all: ['team/subgroup'],
        times: {
          'team/subgroup': DateTime.now().subtract(const Duration(days: 3)),
        },
      );

      await tester.tap(_namespaceField());
      await tester.pumpAndSettle();

      // House wording is the long form — every other surface says it this way.
      expect(find.text('3 days ago'), findsOneWidget);
    });

    testWidgets('a row with no known time carries no label', (tester) async {
      // Local history recorded before Phase 8 has no timestamp. A missing
      // entry means "not known", never "never used", so nothing is invented.
      await _toDetails(
        tester,
        recent: ['team/subgroup'],
        all: ['team/subgroup'],
      );

      await tester.tap(_namespaceField());
      await tester.pumpAndSettle();

      expect(_row('team/subgroup'), findsOneWidget);
      expect(find.textContaining('ago'), findsNothing);
    });

    testWidgets('the non-recent section is never labelled', (tester) async {
      // "You can create in" is a permission list, not an activity list — a
      // time there would claim knowledge the forge feed never supplied.
      await _toDetails(
        tester,
        recent: ['team/subgroup'],
        all: ['team/subgroup', 'never-touched'],
        times: {
          'team/subgroup': DateTime.now().subtract(const Duration(hours: 2)),
        },
      );

      await tester.tap(_namespaceField());
      await tester.pumpAndSettle();

      expect(find.text('2 hours ago'), findsOneWidget);
      expect(find.textContaining('ago'), findsOneWidget);
    });
  });

  group('clearing', () {
    testWidgets('the in-field clear button empties the namespace', (
      tester,
    ) async {
      // Replaces the "Clear" chip the pre-amendment surface carried. Emptying
      // the field is how "create under my own account" is expressed, so it
      // must stay one click rather than a select-all and delete.
      await _toDetails(tester, all: ['team/subgroup']);
      await tester.enterText(nameField(), 'repo');
      await _type(tester, 'team/subgroup');
      expect(
        find.text('Creates team/subgroup/repo on the forge.'),
        findsOneWidget,
      );

      final clear = find.descendant(
        of: find.byType(MacosTextField),
        matching: find.byIcon(CupertinoIcons.clear_thick_circled),
      );
      expect(clear, findsOneWidget, reason: 'shown while there is text');
      await tester.tap(clear);
      await tester.pumpAndSettle();

      expect(
        tester.widget<MacosTextField>(_namespaceField()).controller!.text,
        isEmpty,
      );
      expect(
        find.textContaining('Leave empty to create under your own account'),
        findsOneWidget,
        reason: 'back to the default namespace, and the hint says so',
      );
    });

    testWidgets('no clear button while the field is empty', (tester) async {
      await _toDetails(tester, all: ['team/subgroup']);
      expect(
        find.descendant(
          of: find.byType(MacosTextField),
          matching: find.byIcon(CupertinoIcons.clear_thick_circled),
        ),
        findsNothing,
      );
    });
  });

  group('the server half', () {
    testWidgets('a debounced search backfills what the cache lacks', (
      tester,
    ) async {
      final queries = <String>[];
      await _toDetails(
        tester,
        all: ['me'],
        extraOverrides: [
          namespaceSearchProvider.overrideWith((ref, key) async {
            queries.add(key.$4);
            return ['deep/tail'];
          }),
        ],
      );

      // Three keystrokes inside one debounce window. `pumpAndSettle` is not
      // usable here — it advances in 100 ms steps and would step straight over
      // the 150 ms interval, proving nothing about coalescing.
      await tester.enterText(_namespaceField(), 'd');
      await tester.pump(const Duration(milliseconds: 40));
      await tester.enterText(_namespaceField(), 'de');
      await tester.pump(const Duration(milliseconds: 40));
      await tester.enterText(_namespaceField(), 'deep');
      await tester.pump(const Duration(milliseconds: 40));
      expect(queries, isEmpty, reason: 'still inside the debounce window');

      await _settleSearch(tester);

      expect(queries, ['deep'], reason: 'one request, not one per keystroke');
      expect(_row('deep/tail'), findsOneWidget);
    });

    testWidgets('a superseded response never replaces a newer one', (
      tester,
    ) async {
      await _toDetails(
        tester,
        all: ['me'],
        extraOverrides: [
          namespaceSearchProvider.overrideWith((ref, key) async {
            // The superseded query answers slowly; the current one at once.
            // Both results match the FINAL query, so a stale response that
            // slipped through would be visible — the test would be vacuous if
            // the query filtered it out for an unrelated reason.
            if (key.$4 == 'ab') {
              await Future<void>.delayed(const Duration(seconds: 1));
              return ['abc/stale'];
            }
            return ['abc/fresh'];
          }),
        ],
      );

      // Explicit pumps throughout: `pumpAndSettle` advances in 100 ms steps
      // and would blur the debounce boundary this test is built on.
      await tester.enterText(_namespaceField(), 'ab');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200)); // issues 'ab'
      await tester.enterText(_namespaceField(), 'abc');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200)); // issues 'abc'
      await tester.pumpAndSettle();
      expect(_row('abc/fresh'), findsOneWidget);

      // Now let the superseded request finish, long after it stopped mattering.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(
        _row('abc/stale'),
        findsNothing,
        reason: 'the generation counter must discard it',
      );
    });

    testWidgets('a failing search leaves the cached matches standing', (
      tester,
    ) async {
      await _toDetails(
        tester,
        all: ['alpha'],
        extraOverrides: [
          namespaceSearchProvider.overrideWith(
            (ref, key) async => throw StateError('forge unreachable'),
          ),
        ],
      );

      await _type(tester, 'alph');
      await _settleSearch(tester);

      expect(_row('alpha'), findsOneWidget);
      expect(find.byType(ProgressCircle), findsNothing);
      expect(
        tester.widget<MacosTextField>(_namespaceField()).controller!.text,
        'alph',
      );
    });
  });

  // -------------------------------------------------------------------------
  // The writer half of the recency list (Phase 5 deviation, 2026-09-07).
  //
  // Phase 3b built `NamespaceHistory.record` and Phase 4 wired the reader, but
  // nothing called the writer — so "local history first" read a store that was
  // permanently empty. These pin the call site.
  // -------------------------------------------------------------------------
  group('remembering the namespace that was used', () {
    testWidgets('a successful forge create records it', (tester) async {
      final (exec, store) = await _toDetails(tester, all: ['team/subgroup']);
      await tester.enterText(nameField(), 'repo');
      await _type(tester, 'team/subgroup');
      await nextStep(tester); // → Review

      exec.respond = _cleanCreate();
      await pumpCreate(tester);

      // Non-vacuous: the create really did run, and cleanly.
      expect(
        exec.calls.any(
          (c) => c.join(' ').startsWith('gh repo create team/subgroup/repo'),
        ),
        isTrue,
      );
      expect(find.textContaining('failed'), findsNothing);

      final written = store.updated
          .map((c) => c.namespacesFor('github@github.com'))
          .where((list) => list.isNotEmpty)
          .toList();
      expect(written, [
        ['team/subgroup'],
      ], reason: 'the create succeeded, so the namespace is now history');
    });

    testWidgets('a create that fails records nothing', (tester) async {
      final (exec, store) = await _toDetails(tester, all: ['team/subgroup']);
      await tester.enterText(nameField(), 'repo');
      await _type(tester, 'team/subgroup');
      await nextStep(tester); // → Review

      // Everything after the pre-checks fails. Aiming a positional queue at
      // one specific step is brittle — the run's call order shifts with the
      // mode — so the run is failed outright instead: what matters here is
      // that NOTHING was created, however the run got there.
      exec.results.add(okResult('absent')); // gh auth status
      exec.results.add(okResult('')); // parent-dir probe
      for (var i = 0; i < 12; i++) {
        exec.results.add(
          const SSHCommandResult(
            exitCode: 1,
            stdout: '',
            stderr: 'HTTP 500: the forge is down',
          ),
        );
      }
      await pumpCreate(tester);

      // Non-vacuous: the run really did fail, and the sheet says so rather
      // than reporting a repository that does not exist.
      // Non-vacuous: the run really did fail, and the sheet says so.
      expect(
        find.textContaining('publishing to GitHub failed'),
        findsOneWidget,
      );
      expect(
        store.updated.every(
          (c) => c.namespacesFor('github@github.com').isEmpty,
        ),
        isTrue,
        reason: 'a namespace never created in is not a namespace used',
      );
    });

    testWidgets('an empty namespace records nothing', (tester) async {
      final (exec, store) = await _toDetails(tester, all: ['team/subgroup']);
      await tester.enterText(nameField(), 'repo');
      await tester.pumpAndSettle();
      await nextStep(tester); // → Review

      exec.respond = _cleanCreate();
      await pumpCreate(tester);

      expect(
        store.updated.every(
          (c) => c.namespacesFor('github@github.com').isEmpty,
        ),
        isTrue,
        reason: '"my own account" is the default, not a remembered choice',
      );
    });
  });
}

/// A create that works end to end, answered by request rather than by queue
/// position. Every step the pipeline takes gets the reply that step expects,
/// so the run finishes with no warnings — which is what makes "records on a
/// clean run" and "records nothing otherwise" two different fixtures rather
/// than two readings of the same one.
SSHCommandResult? Function(List<String>) _cleanCreate() {
  // `origin` does not exist until the pipeline adds it, and DOES exist when it
  // verifies afterwards. Answering the same way both times leaves the run
  // warning about an origin it just wrote, and a warning suppresses recording.
  var originAdded = false;
  return (List<String> args) {
    final joined = args.join(' ');
    if (joined.contains('remote add origin')) {
      originAdded = true;
      return okResult('');
    }
    if (joined.contains('remote get-url origin')) {
      return originAdded
          ? okResult('https://github.com/team/subgroup/repo.git')
          : _noOrigin;
    }
    return _cleanStep(joined);
  };
}

SSHCommandResult? _cleanStep(String joined) {
  if (joined.startsWith('gh auth status')) return okResult('');
  if (joined.startsWith('sh -c')) return okResult('absent');
  if (joined.contains('git init')) return okResult('');
  if (joined.startsWith('gh repo create')) return okResult('');
  if (joined.contains('git_protocol')) return okResult('https');
  if (joined.contains('--json url,sshUrl')) {
    return okResult(
      '{"sshUrl":"git@github.com:team/subgroup/repo.git",'
      '"url":"https://github.com/team/subgroup/repo"}',
    );
  }
  return okResult('');
}
