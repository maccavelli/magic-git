// Tests for the external-tool catalog: version parsing/comparison, the catalog
// shape the doctor panel relies on, OS relevance, and platform install hints.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/tool_catalog.dart';

void main() {
  group('ToolVersion.parse', () {
    test('extracts x.y.z from noisy version output', () {
      expect(
        ToolVersion.parse('git version 2.39.3 (Apple Git-145)'),
        const ToolVersion(2, 39, 3),
      );
      expect(ToolVersion.parse('glab 1.40.0'), const ToolVersion(1, 40, 0));
    });

    test('missing patch defaults to 0', () {
      expect(ToolVersion.parse('gh version 2.62'), const ToolVersion(2, 62, 0));
    });

    test('returns null when there is no version token', () {
      expect(ToolVersion.parse('unrecognized option'), isNull);
      expect(ToolVersion.parse(''), isNull);
    });
  });

  group('ToolVersion comparison', () {
    test('orders by major, then minor, then patch', () {
      expect(const ToolVersion(2, 24, 0) < const ToolVersion(2, 24, 1), isTrue);
      expect(const ToolVersion(2, 23, 9) < const ToolVersion(2, 24, 0), isTrue);
      expect(const ToolVersion(1, 99, 0) < const ToolVersion(2, 0, 0), isTrue);
      expect(
        const ToolVersion(2, 24, 0) >= const ToolVersion(2, 24, 0),
        isTrue,
      );
      expect(
        const ToolVersion(2, 30, 0) >= const ToolVersion(2, 24, 0),
        isTrue,
      );
    });
  });

  group('catalog', () {
    test('git is essential with a 2.24 floor (for --end-of-options)', () {
      final git = toolSpecFor('git')!;
      expect(git.tier, ToolTier.essential);
      expect(git.minVersion, const ToolVersion(2, 24, 0));
    });

    test('glab and gh are feature-tier and OS-agnostic', () {
      for (final bin in ['glab', 'gh']) {
        final spec = toolSpecFor(bin)!;
        expect(spec.tier, ToolTier.feature);
        expect(spec.onlyOs, isNull);
      }
    });

    test('watchers are optional and OS-specific', () {
      expect(toolSpecFor('fswatch')!.onlyOs, 'macos');
      expect(toolSpecFor('inotifywait')!.onlyOs, 'linux');
      expect(toolSpecFor('fswatch')!.tier, ToolTier.optional);
    });

    test('unknown binary has no spec', () {
      expect(toolSpecFor('svn'), isNull);
    });
  });

  group('relevantOn', () {
    test('fswatch is relevant on macOS but not Linux', () {
      final fswatch = toolSpecFor('fswatch')!;
      expect(fswatch.relevantOn('macos'), isTrue);
      expect(fswatch.relevantOn('linux'), isFalse);
    });

    test('inotifywait is relevant on Linux but not macOS', () {
      final ino = toolSpecFor('inotifywait')!;
      expect(ino.relevantOn('linux'), isTrue);
      expect(ino.relevantOn('macos'), isFalse);
    });

    test('everything is relevant when the OS is unknown', () {
      for (final spec in kToolCatalog) {
        expect(spec.relevantOn('unknown'), isTrue);
      }
    });

    test('OS-agnostic tools are relevant everywhere', () {
      expect(toolSpecFor('git')!.relevantOn('linux'), isTrue);
      expect(toolSpecFor('git')!.relevantOn('macos'), isTrue);
    });
  });

  group('installHints', () {
    test('macOS git offers Xcode CLT and Homebrew', () {
      final hints = installHints('git', 'macos');
      expect(
        hints.map((h) => h.command),
        containsAll(['xcode-select --install', 'brew install git']),
      );
    });

    test('Linux gh includes the official apt repo and a rootless option', () {
      final hints = installHints('gh', 'linux');
      final labels = hints.map((h) => h.label).join(' | ');
      expect(labels, contains('Debian / Ubuntu'));
      expect(labels.toLowerCase(), contains('rootless'));
      // The official keyring step is present.
      expect(hints.any((h) => h.command.contains('cli.github.com')), isTrue);
    });

    test('Linux inotifywait flags the EPEL requirement for RHEL', () {
      final hints = installHints('inotifywait', 'linux');
      expect(hints.any((h) => h.command.contains('epel-release')), isTrue);
    });

    test('fswatch has no Linux hints (macOS-only in this app)', () {
      expect(installHints('fswatch', 'linux'), isEmpty);
    });

    test('unknown OS falls back to Homebrew for brew-able tools', () {
      expect(
        installHints('glab', 'unknown').single.command,
        'brew install glab',
      );
    });
  });
}
