import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/viewer/file_content.dart';
import 'package:remote_magic_git/features/viewer/viewer_providers.dart';

const _repo = 'test-repo';
const _path = 'README.md';

/// Stubs [GitService.readFile] / [readFileBase64] for testing.
class _TextGit extends GitService {
  final String _text;
  final String _base64;
  _TextGit(this._text, [this._base64 = ''])
    : super(SSHCommandExecutor(SSHClientManager()));

  @override
  Future<String> readFile(String repoPath, String path) async => _text;

  @override
  Future<String> readFileBase64(String repoPath, String path) async => _base64;
}

/// Keeps an autoDispose provider alive across an async read and returns its
/// value. Mirrors the pattern in test/viewer_latin1_fallback_test.dart.
Future<FileContent> _readFileContent(
  (String, String) key, {
  required String text,
  String base64 = '',
}) async {
  final git = _TextGit(text, base64);
  final container = ProviderContainer(
    overrides: [gitServiceProvider.overrideWithValue(git)],
  );
  addTearDown(container.dispose);
  final sub = container.listen(fileContentProvider(key), (_, _) {});
  addTearDown(sub.close);
  return container.read(fileContentProvider(key).future);
}

/// Same as [_readFileContent] but for [fileBytesProvider].
Future<Uint8List> _readFileBytes(
  (String, String) key, {
  required String base64,
}) async {
  final git = _TextGit('', base64);
  final container = ProviderContainer(
    overrides: [gitServiceProvider.overrideWithValue(git)],
  );
  addTearDown(container.dispose);
  final sub = container.listen(fileBytesProvider(key), (_, _) {});
  addTearDown(sub.close);
  return container.read(fileBytesProvider(key).future);
}

void main() {
  group('mapReadError', () {
    test('SSHOutputExceeded maps to tooLarge', () {
      final result = mapReadError(const SSHOutputExceeded('cat -- file'));
      expect(result, isA<ViewerReadException>());
      expect(result.kind, ViewerReadError.tooLarge);
    });

    test('SSHCommandTimeout maps to timedOut', () {
      final result = mapReadError(const SSHCommandTimeout('cat -- file'));
      expect(result, isA<ViewerReadException>());
      expect(result.kind, ViewerReadError.timedOut);
    });

    test('SSHCommandSuperseded maps to connectionChanged', () {
      final result = mapReadError(const SSHCommandSuperseded('cat -- file'));
      expect(result, isA<ViewerReadException>());
      expect(result.kind, ViewerReadError.connectionChanged);
    });

    test('other exception maps to unavailable', () {
      final result = mapReadError(Exception('unknown'));
      expect(result, isA<ViewerReadException>());
      expect(result.kind, ViewerReadError.unavailable);
    });

    test('already a ViewerReadException passes through', () {
      const original = ViewerReadException(ViewerReadError.tooLarge, 'big');
      final result = mapReadError(original);
      expect(result, same(original));
    });
  });

  group('ViewerLastSize', () {
    test('initial state is null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(viewerLastSizeProvider), isNull);
    });

    test('set updates state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const size = Size(800.0, 600.0);
      container.read(viewerLastSizeProvider.notifier).set(size);
      expect(container.read(viewerLastSizeProvider), size);
    });

    test('set replaces previous value', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const a = Size(100.0, 100.0);
      const b = Size(200.0, 200.0);
      container.read(viewerLastSizeProvider.notifier).set(a);
      container.read(viewerLastSizeProvider.notifier).set(b);
      expect(container.read(viewerLastSizeProvider), b);
    });
  });

  group('OpenFileViewers', () {
    test('initial state is empty', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(openFileViewersProvider), isEmpty);
    });

    test('open adds viewer and returns id', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final id = container
          .read(openFileViewersProvider.notifier)
          .open(_repo, _path);
      final viewers = container.read(openFileViewersProvider);
      expect(viewers.length, 1);
      expect(viewers[0].id, id);
      expect(viewers[0].repoPath, _repo);
      expect(viewers[0].path, _path);
    });

    test('open with same path returns existing id and focuses', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final first = container
          .read(openFileViewersProvider.notifier)
          .open(_repo, _path);
      final second = container
          .read(openFileViewersProvider.notifier)
          .open(_repo, _path);
      expect(second, first);
      expect(container.read(openFileViewersProvider).length, 1);
    });

    test('close removes viewer by id', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final id = container
          .read(openFileViewersProvider.notifier)
          .open(_repo, _path);
      container.read(openFileViewersProvider.notifier).close(id);
      expect(container.read(openFileViewersProvider), isEmpty);
    });

    test('close with unknown id is no-op', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(openFileViewersProvider.notifier).open(_repo, _path);
      container.read(openFileViewersProvider.notifier).close(999);
      expect(container.read(openFileViewersProvider).length, 1);
    });

    test('focus brings viewer to front', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final id1 = container
          .read(openFileViewersProvider.notifier)
          .open(_repo, 'a.txt');
      container.read(openFileViewersProvider.notifier).open(_repo, 'b.txt');
      container.read(openFileViewersProvider.notifier).focus(id1);
      final viewers = container.read(openFileViewersProvider);
      expect(viewers.last.id, id1);
    });

    test('focus on already-front viewer is no-op', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final id1 = container
          .read(openFileViewersProvider.notifier)
          .open(_repo, 'a.txt');
      container.read(openFileViewersProvider.notifier).open(_repo, 'b.txt');
      container.read(openFileViewersProvider.notifier).focus(id1);
      final before = container.read(openFileViewersProvider);
      container.read(openFileViewersProvider.notifier).focus(id1);
      expect(container.read(openFileViewersProvider), before);
    });

    test('closeAll removes all viewers', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(openFileViewersProvider.notifier).open(_repo, 'a.txt');
      container.read(openFileViewersProvider.notifier).open(_repo, 'b.txt');
      container.read(openFileViewersProvider.notifier).closeAll();
      expect(container.read(openFileViewersProvider), isEmpty);
    });

    test('ids increment across opens', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final id1 = container
          .read(openFileViewersProvider.notifier)
          .open(_repo, 'a.txt');
      final id2 = container
          .read(openFileViewersProvider.notifier)
          .open(_repo, 'b.txt');
      expect(id2, greaterThan(id1));
    });
  });

  group('fileContentProvider', () {
    test('returns classified text content on success', () async {
      final content = await _readFileContent((
        _repo,
        _path,
      ), text: 'hello world');
      expect(content.isText, isTrue);
      expect(content.text, contains('hello world'));
    });

    test('classifies binary content with NUL byte', () async {
      final content = await _readFileContent((
        _repo,
        _path,
      ), text: 'text\u0000more');
      expect(content.kind, FileContentKind.binary);
    });

    test('classifies too-large content', () async {
      final big = String.fromCharCodes(
        List.filled(FileContent.maxRenderChars + 1, 0x78),
      );
      final content = await _readFileContent((_repo, _path), text: big);
      expect(content.kind, FileContentKind.tooLarge);
    });
  });

  group('fileBytesProvider', () {
    test('decodes base64 from readFileBase64', () async {
      final bytes = await _readFileBytes((_repo, _path), base64: 'aGVsbG8=');
      expect(bytes, [104, 101, 108, 108, 111]);
    });
  });
}
