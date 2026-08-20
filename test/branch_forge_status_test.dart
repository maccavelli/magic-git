import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';

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
}
