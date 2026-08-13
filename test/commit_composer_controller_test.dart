import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/repository/commit_composer_controller.dart';

CommitComposerController _controller({
  Future<String?> Function()? preview,
  Future<bool> Function()? gpg,
}) => CommitComposerController(
  repoPath: '/repo',
  generatePreview: preview ?? () async => null,
  loadGpgSignConfigured: gpg ?? () async => false,
);

void main() {
  test('hook preview is lazy and cached once per staged signature', () async {
    var calls = 0;
    final controller = _controller(
      preview: () async {
        calls++;
        return 'feat: generated';
      },
    );
    addTearDown(controller.dispose);
    controller.updateStaged(count: 1, signature: 'a');

    expect(calls, 0);
    await controller.ensurePreview();
    await controller.ensurePreview();
    expect(calls, 1);
    expect(controller.message, 'feat: generated');
    expect(controller.editable, isFalse);
  });

  test('editing and staged changes make regeneration intentional', () async {
    var calls = 0;
    final controller = _controller(preview: () async => 'generated ${++calls}');
    addTearDown(controller.dispose);
    controller.updateStaged(count: 1, signature: 'a');
    await controller.ensurePreview();
    controller.updateMessage('my draft');
    await controller.ensurePreview();
    expect(calls, 2, reason: 'user edits invalidate the preview cache');

    controller.updateStaged(count: 2, signature: 'b');
    expect(controller.previewStale, isTrue);
    expect(controller.message, 'generated 2');
    await controller.ensurePreview(regenerate: true);
    expect(controller.message, 'generated 3');
    expect(controller.previewStale, isFalse);
  });

  test(
    'failure retains draft, success clears it, and duplicate is guarded',
    () async {
      final controller = _controller();
      addTearDown(controller.dispose);
      controller.updateStaged(count: 1, signature: 'a');
      controller.updateMessage('fix: retain me');

      final failed = await controller.submit(commit: (_) async => false);
      expect(failed.localCommitted, isFalse);
      expect(controller.message, 'fix: retain me');

      final gate = Completer<bool>();
      final first = controller.submit(commit: (_) => gate.future);
      final duplicate = await controller.submit(commit: (_) async => true);
      expect(duplicate.duplicateIgnored, isTrue);
      gate.complete(true);
      final success = await first;
      expect(success.localCommitted, isTrue);
      expect(controller.message, isEmpty);
    },
  );

  test(
    'failed push cannot turn a successful local commit into failure',
    () async {
      final controller = _controller();
      addTearDown(controller.dispose);
      controller
        ..updateStaged(count: 1, signature: 'a')
        ..updateMessage('feat: local success');

      final outcome = await controller.submit(
        commit: (_) async => true,
        push: () async => false,
      );
      expect(outcome.localCommitted, isTrue);
      expect(outcome.pushSucceeded, isFalse);
      expect(controller.message, isEmpty);
    },
  );

  test('session key prevents host/path draft collisions', () {
    expect(
      const CommitComposerKey('/repo', 1),
      isNot(const CommitComposerKey('/repo', 2)),
    );
  });
}
