// ciStatusColor: maps every real GitLab CI pipeline/job status to a color.
// Regression coverage for the pre-run states (created/waiting_for_resource/
// preparing/scheduled) — previously these fell through to the same orange
// used for a genuinely unknown status, so retrying a pipeline (which lands in
// 'created' first) flashed an ambiguous warning color instead of a neutral
// "not started yet" one.

import 'package:flutter/widgets.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/gitlab/models.dart';
import 'package:remote_magic_git/features/gitlab/status_color.dart';

// Exercise the full wire-string → CiStatus → color path, matching how the
// panels color a pipeline/job status straight off `glab`'s JSON.
Color wireColor(String wire) => ciStatusColor(CiStatus.fromWire(wire));

void main() {
  group('ciStatusColor', () {
    test('pre-run states share the same neutral color as pending/running', () {
      final preRun = [
        'created',
        'waiting_for_resource',
        'preparing',
        'scheduled',
        'pending',
        'running',
      ];
      final colors = preRun.map(wireColor).toSet();
      expect(
        colors,
        {MacosColors.systemBlueColor},
        reason: 'every pre-run/running state should read as "in progress", '
            'not "problem"',
      );
    });

    test('terminal outcomes map to their own distinct colors', () {
      expect(wireColor('success'), MacosColors.systemGreenColor);
      expect(wireColor('failed'), MacosColors.systemRedColor);
    });

    test('inactive-without-error states are neutral gray', () {
      for (final s in ['canceled', 'skipped', 'manual']) {
        expect(wireColor(s), MacosColors.systemGrayColor);
      }
    });

    test(
      'a genuinely unknown status still gets the distinct "unknown" orange, '
      'never confused with a real pre-run state',
      () {
        final unknownColor = wireColor('some_future_gitlab_status');
        expect(unknownColor, MacosColors.systemOrangeColor);
        expect(unknownColor, isNot(wireColor('created')));
      },
    );
  });

  group('parseLabelColor', () {
    test('a full 6-digit hex parses opaque (0xFF alpha)', () {
      expect(parseLabelColor('#FF0000'), const Color(0xFFFF0000));
      expect(parseLabelColor('00FF00'), const Color(0xFF00FF00));
    });

    test(
      'a 3-digit shorthand falls back to gray, never a transparent chip',
      () {
        // Regression: `#abc` used to parse as Color(0x00000abc) — fully
        // transparent, so the chip was invisible instead of visibly colored.
        final c = parseLabelColor('#abc');
        expect(c, MacosColors.systemGrayColor);
        expect(c.a, greaterThan(0), reason: 'must never be fully transparent');
      },
    );

    test('malformed / non-hex input falls back to gray', () {
      expect(parseLabelColor('#zzzzzz'), MacosColors.systemGrayColor);
      expect(parseLabelColor(''), MacosColors.systemGrayColor);
    });
  });
}
