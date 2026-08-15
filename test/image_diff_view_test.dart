import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/common/image_diff_view.dart';

const _repo = '/repo';
final _png = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8'
  'AAAAASUVORK5CYII=',
);

class _ImageGit extends GitService {
  _ImageGit({this.fail = false})
    : super(SSHCommandExecutor(SSHClientManager()));

  final bool fail;
  final List<String> reads = [];

  @override
  Future<String> showBlobBase64(
    String repoPath,
    String revision,
    String path, {
    int maxBytes = kImageDiffMaxEncodedBytes,
  }) async {
    reads.add('$revision:$path@$maxBytes');
    if (fail) {
      throw const GitException(
        'large',
        SSHCommandResult(exitCode: 75, stdout: '', stderr: ''),
      );
    }
    return base64.encode(_png);
  }

  @override
  Future<String> readFileBase64Bounded(
    String repoPath,
    String path, {
    int maxBytes = kImageDiffMaxEncodedBytes,
  }) async {
    reads.add('worktree:$path@$maxBytes');
    return base64.encode(_png);
  }
}

Future<_ImageGit> _pump(
  WidgetTester tester, {
  bool fail = false,
  String? beforePath = 'logo.png',
  String? afterPath = 'logo.png',
}) async {
  final git = _ImageGit(fail: fail);
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [gitServiceProvider.overrideWithValue(git)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        home: SizedBox(
          width: 900,
          height: 600,
          child: ImageDiffView(
            repoPath: _repo,
            displayPath: 'logo.png',
            beforePath: beforePath,
            beforeRevision: 'HEAD',
            afterPath: afterPath,
            afterRevision: null,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return git;
}

void main() {
  testWidgets('loads bounded revision/worktree sides and reports metadata', (
    tester,
  ) async {
    final git = await _pump(tester);
    expect(git.reads, [
      'HEAD:logo.png@$kImageDiffMaxEncodedBytes',
      'worktree:logo.png@$kImageDiffMaxEncodedBytes',
    ]);
    expect(find.textContaining('Before  1 × 1'), findsOneWidget);
    expect(find.textContaining('After  1 × 1'), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
  });

  testWidgets('switches among side-by-side, overlay, and reveal slider', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('Overlay'));
    await tester.pump();
    expect(find.text('50% overlay'), findsOneWidget);

    await tester.tap(find.text('Slider'));
    await tester.pump();
    expect(find.text('Before'), findsOneWidget);
    expect(find.text('After'), findsOneWidget);
  });

  testWidgets('added image renders an explicit absent before side', (
    tester,
  ) async {
    final git = await _pump(tester, beforePath: null);
    expect(git.reads, ['worktree:logo.png@$kImageDiffMaxEncodedBytes']);
    expect(find.text('Before  Not present'), findsOneWidget);
  });

  testWidgets('byte-budget failure degrades to the binary notice', (
    tester,
  ) async {
    await _pump(tester, fail: true, afterPath: null);
    expect(find.text('Binary image change'), findsOneWidget);
    expect(find.textContaining('12 MiB'), findsOneWidget);
  });

  test(
    'invalid bytes fail dimension inspection without decoding pixels',
    () async {
      await expectLater(
        inspectImageDiffBytes(base64.decode('AAAA')),
        throwsA(isA<ImageDiffReadException>()),
      );
    },
  );

  test('an LFS pointer is named honestly instead of "could not decode" '
      '(0009 M17)', () async {
    final pointer = Uint8List.fromList(
      'version https://git-lfs.github.com/spec/v1\n'
              'oid sha256:aaaa\nsize 12345\n'
          .codeUnits,
    );
    await expectLater(
      inspectImageDiffBytes(pointer),
      throwsA(
        isA<ImageDiffReadException>().having(
          (e) => e.message,
          'message',
          contains('Git LFS pointer'),
        ),
      ),
    );
  });
}
