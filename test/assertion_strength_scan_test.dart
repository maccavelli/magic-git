// MADR 0030 T3.8, and the home for the blind spot 0030 Phase 1 deferred here.
//
// Two heuristics. Neither is a proof, and both say so: they enumerate sites
// that need a human decision and fail when that enumeration drifts — the same
// registry shape as 0029, which is the only form of this that has actually
// held.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// 1. `.when()` on an AsyncValue that crossed a widget boundary
// ---------------------------------------------------------------------------
//
// `refresh_no_flash_test`'s scan matches `final x = ref.watch(<derived>(…))`
// followed by `x.when(` IN THE SAME FILE. An AsyncValue handed across a widget
// boundary — a constructor field or a method parameter — escapes it entirely.
// That is how `forge_widgets.dart` hid a real offender until it was found by
// reading (0030 Phase 1, deviation (a)).
//
// A stricter regex would over-flag, because at least one boundary site
// deliberately shows its spinner. So: enumerate, and require a decision.

/// Boundary-crossing `.when()` sites reviewed and left without the flag.
///
/// The scan cannot see provenance — that is the whole reason it exists — so it
/// flags every such site and a human decides. Two different reasons appear
/// here and both are legitimate; what is not legitimate is an unexamined entry,
/// so each states which it is.
const _reviewedBoundarySites = <String, String>{
  // Reason 1: the spinner is correct.
  'dashboard/dashboard_sheet.dart':
      'sessionAuthStatusProvider recomputes when the CONNECTION changes, not '
      'when a dependency refreshes. Holding the previous value would show '
      "one host's CLI auth state as if it were the new host's — worse than "
      'a spinner (0030 Phase 1, reviewed).',
  // Reason 2: the flag is unnecessary — this provider does not derive.
  'worktrees/worktrees_view.dart':
      'gitWorktreesProvider calls the git service directly and does not await '
      'another provider future, so invalidating it is a REFRESH, and '
      'skipLoadingOnRefresh (default true) already keeps the rows on screen. '
      'Adding the flag here would be cargo cult (0030 Phase 8).',
};

({List<String> flagged, List<String> flagged_}) _boundaryWhenSites() {
  final missing = <String>[];
  final withFlag = <String>[];
  for (final f in Directory(
    'lib/features',
  ).listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    final src = f.readAsStringSync();
    // AsyncValue arriving as a parameter or a field — provenance invisible here.
    final names = <String>{
      for (final m in RegExp(
        r'AsyncValue<[\w\s,<>?.]*>\s*\??\s*(\w+)\s*[,;)=]',
      ).allMatches(src))
        m[1]!,
      for (final m in RegExp(
        r'AsyncValue<[\w\s,<>?.]*>\s*\??\s*get\s+(\w+)',
      ).allMatches(src))
        m[1]!,
    };
    for (final n in names) {
      for (final w in RegExp('\\b$n\\.when\\(').allMatches(src)) {
        final window = src.substring(w.end).split('\n').take(40).join('\n');
        final rel = f.path.replaceFirst('lib/features/', '');
        // `skipLoadingOnReload:` WITH the colon — the argument, not the word.
        // Matching the bare word counted `dashboard_sheet.dart` as compliant
        // because the comment there explains why it deliberately omits the
        // flag. A scan that a comment can satisfy is not a scan.
        (window.contains('skipLoadingOnReload:') ? withFlag : missing).add(rel);
      }
    }
  }
  return (flagged: missing, flagged_: withFlag);
}

// ---------------------------------------------------------------------------
// 2. Text-only assertions about generated scripts
// ---------------------------------------------------------------------------

/// Test files allowed to assert only on a builder's *text*.
///
/// 0029 settled the rule: a `contains(...)` may pin COMPOSITION — that a path
/// was interpolated — but never BEHAVIOUR. A file here asserts composition
/// only, and the behaviour is asserted by an executing test elsewhere.
const _compositionOnly = <String, String>{
  'bounded_watch_test.dart':
      'asserts the script is built from the paths it was given; behaviour is '
      'executed in watcher_sweep_exec_test.dart, host_script_exec_test.dart '
      'and watch_lease_teardown_exec_test.dart (MADR 0041 — the lease loop\'s '
      'teardown, against real processes)',
  'snapshot_fallback_test.dart':
      'pins that the ref parse is handed to the parse worker at all — a '
      'structural gate with no behavioural signature (see its own comment)',
  'git_cat_file_batch_test.dart':
      'asserts the batch script is composed from the specs it was given; the '
      'BEHAVIOUR — byte-exact blobs, missing objects, a failing cat-file — '
      'is executed against a real git repo in host_script_exec_test.dart',
  'install_planner_test.dart':
      'rootlessInstallScript is permanently exempt from execution (it installs '
      'binaries); composition is all a test may claim about it (0029)',
};

void main() {
  test('every boundary-crossing .when() is flagged or deliberately not', () {
    final sites = _boundaryWhenSites();
    expect(
      sites.flagged_,
      isNotEmpty,
      reason: 'the scan must find the sites that DO carry the flag',
    );

    final undecided = sites.flagged.toSet().difference(
      _reviewedBoundarySites.keys.toSet(),
    );
    expect(
      undecided,
      isEmpty,
      reason:
          'these render an AsyncValue through .when() without '
          'skipLoadingOnReload, and their provenance is not visible where they '
          'are rendered. Add the flag, or add the file to _reviewedBoundarySites '
          'with a reason: $undecided',
    );

    final stale = _reviewedBoundarySites.keys.toSet().difference(
      sites.flagged.toSet(),
    );
    expect(stale, isEmpty, reason: 'stale exemptions: $stale');
  });

  test('every exemption states a reason', () {
    for (final e in {..._reviewedBoundarySites, ..._compositionOnly}.entries) {
      expect(
        e.value.trim().length,
        greaterThan(30),
        reason: '${e.key} is exempt without a real reason',
      );
    }
  });

  test('files asserting only on generated script text are enumerated', () {
    // The heuristic, stated as one: find test files that name a `*Script(`
    // builder and assert `contains(` on it. Each must either also execute the
    // script, or be listed as composition-only with its behavioural twin named.
    final builders = RegExp(r'^String\s+(\w*Script)\s*\(', multiLine: true);
    final names = <String>{};
    for (final f in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      for (final m in builders.allMatches(f.readAsStringSync())) {
        names.add(m[1]!);
      }
    }
    expect(names, isNotEmpty);

    final undecided = <String>[];
    for (final f in Directory(
      'test',
    ).listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      final base = f.path.split('/').last;
      final mentionsBuilder = names.any(src.contains);
      if (!mentionsBuilder) continue;
      final assertsText = src.contains('contains(');
      final executes =
          src.contains('Process.run') || src.contains('Process.start');
      if (assertsText && !executes && !_compositionOnly.containsKey(base)) {
        undecided.add(base);
      }
    }

    expect(
      undecided,
      isEmpty,
      reason:
          'these assert on a generated script\'s text without executing it. '
          'Either add an executing test, or list the file in _compositionOnly '
          'naming where the behaviour IS asserted: $undecided',
    );
  });
}
