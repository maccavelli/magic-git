import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/common/commit_assistance.dart';
import 'package:remote_magic_git/features/repository/commit_composer_controller.dart';

CommitComposerController _controller({
  Future<String?> Function()? preview,
  Future<bool> Function()? gpg,
  Future<List<String>> Function()? recentSubjects,
  Future<String?> Function()? template,
  Future<String?> Function()? pendingMessage,
}) => CommitComposerController(
  repoPath: '/repo',
  generatePreview: preview ?? () async => null,
  loadGpgSignConfigured: gpg ?? () async => false,
  loadRecentSubjects: recentSubjects,
  loadTemplate: template,
  loadPendingMessage: pendingMessage,
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

  test('landed recent subjects require no load and stay session-scoped', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const first = CommitAssistanceKey('/repo', 1);
    const second = CommitAssistanceKey('/repo', 2);

    container.read(landedCommitSubjectsProvider(first).notifier).publish([
      'feat: one',
      'feat: one',
      ' fix: two ',
    ]);

    expect(container.read(landedCommitSubjectsProvider(first)), [
      'feat: one',
      'fix: two',
    ]);
    expect(container.read(landedCommitSubjectsProvider(second)), isEmpty);
  });

  test(
    'explicit recent load is bounded, trimmed, and user-selectable',
    () async {
      var calls = 0;
      final controller = _controller(
        recentSubjects: () async {
          calls++;
          return [
            ' feat: newest ',
            '',
            'feat: newest',
            for (var i = 0; i < 12; i++) 'fix: $i',
          ];
        },
      );
      addTearDown(controller.dispose);

      expect(controller.recentSubjects, isEmpty);
      expect(calls, 0);
      await controller.loadRecentSubjects();

      expect(calls, 1);
      expect(controller.recentSubjects, hasLength(10));
      expect(controller.recentSubjects.first, 'feat: newest');
      controller.useRecentSubject(controller.recentSubjects.last);
      expect(controller.message, controller.recentSubjects.last);
    },
  );

  test('template loads once and never overwrites a non-empty draft', () async {
    var calls = 0;
    final controller = _controller(
      template: () async {
        calls++;
        return 'feat: template\n\nDetails';
      },
    );
    addTearDown(controller.dispose);

    await controller.loadTemplate();
    await controller.loadTemplate();
    expect(calls, 1);
    controller.useTemplate();
    expect(controller.message, 'feat: template\n\nDetails');

    controller.updateMessage('fix: keep this');
    controller.useTemplate();
    expect(controller.message, 'fix: keep this');
  });

  test('validated co-authors append deterministic unique trailers', () async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller
      ..updateStaged(count: 1, signature: 'a')
      ..updateMessage(
        'feat: pair\n\nCo-authored-by: Existing <existing@example.com>',
      );

    expect(
      controller.addCoAuthor(' Ada  Lovelace ', 'ADA@EXAMPLE.COM'),
      isTrue,
    );
    expect(controller.addCoAuthor('Bad\nName', 'bad@example.com'), isFalse);
    expect(controller.addCoAuthor('Existing', 'existing@example.com'), isTrue);

    String? committed;
    final outcome = await controller.submit(
      commit: (message) async {
        committed = message;
        return true;
      },
    );

    expect(outcome.localCommitted, isTrue);
    expect(
      committed,
      'feat: pair\n\n'
      'Co-authored-by: Existing <existing@example.com>\n'
      'Co-authored-by: Ada Lovelace <ada@example.com>',
    );
    expect(controller.coAuthors, isEmpty);
  });

  test('a pending operation message wins over generation (0009 M14)', () async {
    var generateCalls = 0;
    final controller = _controller(
      preview: () async {
        generateCalls++;
        return 'feat: generated';
      },
      pendingMessage: () async =>
          "Merge branch 'topic'\n\n# Conflicts already stripped",
    );
    addTearDown(controller.dispose);
    controller.updateStaged(count: 1, signature: 'a');
    await controller.ensurePreview();

    expect(generateCalls, 0, reason: 'MERGE_MSG must preempt generation');
    expect(controller.message, startsWith("Merge branch 'topic'"));
    expect(controller.generated, isFalse);
    expect(controller.editable, isTrue);

    // A typed draft is never clobbered by the prepared message.
    controller.updateMessage('my own words');
    controller.updateStaged(count: 2, signature: 'b');
    await controller.ensurePreview();
    expect(controller.message, 'my own words');
  });

  test('a failing pending-message read falls through to generation', () async {
    final controller = _controller(
      preview: () async => 'feat: generated',
      pendingMessage: () async => throw Exception('unreadable'),
    );
    addTearDown(controller.dispose);
    controller.updateStaged(count: 1, signature: 'a');
    await controller.ensurePreview();
    expect(controller.message, 'feat: generated');
  });

  test(
    'assistance load errors are humanized, not raw toString (0009 M18)',
    () async {
      final controller = _controller(
        recentSubjects: () async => throw Exception('boom'),
      );
      addTearDown(controller.dispose);
      await controller.loadRecentSubjects();
      expect(
        controller.error,
        contains('Could not load recent commit subjects.'),
      );
      expect(controller.error, contains('boom'));
      expect(controller.error, isNot(contains('Exception:')));
    },
  );
}
