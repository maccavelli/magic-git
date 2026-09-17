import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';

/// Counts failures Riverpod reports to observers, mirroring the one in
/// app_providers_test.dart (MADR 0050 F3).
base class _CountingObserver extends ProviderObserver {
  final failures = <Object>[];

  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    failures.add(error);
  }
}

void main() {
  group('ForgeCi enum', () {
    test('all expected values exist', () {
      expect(ForgeCi.success, ForgeCi.success);
      expect(ForgeCi.failure, ForgeCi.failure);
      expect(ForgeCi.running, ForgeCi.running);
      expect(ForgeCi.canceled, ForgeCi.canceled);
      expect(ForgeCi.skipped, ForgeCi.skipped);
      expect(ForgeCi.unknown, ForgeCi.unknown);
    });
  });

  group('BranchForge model', () {
    test('default-constructed instance has no request, no CI', () {
      const bf = BranchForge();
      expect(bf.requestNumber, isNull);
      expect(bf.requestUrl, isNull);
      expect(bf.requestTitle, isNull);
      expect(bf.requestDraft, isFalse);
      expect(bf.hasRequest, isFalse);
      expect(bf.isMr, isFalse);
      expect(bf.ci, isNull);
      expect(bf.ciUrl, isNull);
    });

    test('hasRequest reflects requestNumber', () {
      expect(const BranchForge(requestNumber: 1).hasRequest, isTrue);
      expect(const BranchForge().hasRequest, isFalse);
    });

    test('requestLabel shows # for PR, ! for MR', () {
      expect(
        const BranchForge(requestNumber: 42, isMr: false).requestLabel,
        '#42',
      );
      expect(
        const BranchForge(requestNumber: 7, isMr: true).requestLabel,
        '!7',
      );
    });

    test('requestLabel handles null requestNumber gracefully', () {
      // null requestNumber → '#null' — acceptable for a missing-case sentinel.
      expect(const BranchForge().requestLabel, '#null');
    });

    test('CI state and URL are forwarded', () {
      const bf = BranchForge(
        ci: ForgeCi.running,
        ciUrl: 'https://gitlab.com/group/proj/-/pipelines/1',
      );
      expect(bf.ci, ForgeCi.running);
      expect(bf.ciUrl, 'https://gitlab.com/group/proj/-/pipelines/1');
    });

    test('draft flag is forwarded', () {
      expect(
        const BranchForge(requestNumber: 1, requestDraft: true).requestDraft,
        isTrue,
      );
    });
  });

  group('MADR 0050 — branchForgeProvider ref.mounted guard', () {
    const repoPath = '/repo';

    test('disposed (last listener leaves) while the forge await is pending: '
        'zero failures', () async {
      final forgeGate = Completer<Forge>();
      final observer = _CountingObserver();
      final container = ProviderContainer(
        observers: [observer],
        overrides: [
          forgeProvider(repoPath).overrideWith((ref) => forgeGate.future),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen<AsyncValue<Map<String, BranchForge>>>(
        branchForgeProvider(repoPath),
        (_, _) {},
      );
      await Future<void>.delayed(Duration.zero);

      // The only listener leaves while the forge await is still pending —
      // autoDispose tears the family entry down right away.
      sub.close();
      await Future<void>.delayed(Duration.zero);

      // Github takes the switch's first case, which is what used to watch
      // pullRequestsProvider/workflowRunsProvider on a dead Ref.
      forgeGate.complete(Forge.github);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(observer.failures, isEmpty);
    });
  });
}
