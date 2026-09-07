// MADR 0034 F9: forge prefs apply optimistically and persist afterwards. The
// persistence failure used to be swallowed by a bare `catch (_) {}`, so the UI
// showed a setting that would not survive a restart and nothing said so.
//
// No `SharedPreferences.setMockInitialValues` here on purpose: without a
// registered mock, `getInstance()` throws, which is the real thrown-read/write
// case these catches exist for. (A *missing key* is handled explicitly before
// the catch and is not an error — that distinction is why all four sites
// report rather than only the two writes.)

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/providers/provider_retry_policy.dart';
import 'package:remote_magic_git/features/forge/forge_prefs.dart';

List<String> _errors(ProviderContainer c) => [
  for (final line in c.read(outputLogProvider).lines)
    if (line.kind == OutputLineKind.error) line.text,
];

void main() {
  test(
    'a failed Inbox/Browse write is reported, and the choice still applies',
    () async {
      final container = ProviderContainer(retry: noProviderRetry);
      addTearDown(container.dispose);

      await container.read(forgeInboxModeProvider.notifier).set(false);

      expect(
        container.read(forgeInboxModeProvider),
        isFalse,
        reason:
            'the change is optimistic and must stick — reporting, not reverting',
      );
      expect(
        _errors(container).join('\n'),
        contains('will not survive a restart'),
        reason: 'a silently-lost setting is the defect this fixes',
      );
    },
  );

  test('a failed pin write is reported, and the pin still applies', () async {
    final container = ProviderContainer(retry: noProviderRetry);
    addTearDown(container.dispose);

    const repo = '/repo';
    await container
        .read(forgeInboxMarksProvider(repo).notifier)
        .togglePin('mr:7');

    expect(container.read(forgeInboxMarksProvider(repo)).pinned, {'mr:7'});
    expect(
      _errors(container).join('\n'),
      contains('pin/snooze will not survive a restart'),
    );
  });

  test('a failed read is reported too', () async {
    final container = ProviderContainer(retry: noProviderRetry);
    addTearDown(container.dispose);

    // `build()` kicks off the load; let it fail.
    container.read(forgeInboxModeProvider);
    await Future<void>.delayed(Duration.zero);

    expect(
      _errors(container).join('\n'),
      contains('could not read the Inbox/Browse choice'),
    );
  });
}
