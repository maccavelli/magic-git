// Two things are covered here:
//  1. Graceful degradation when NO native `magicgit/bookmarks` channel is
//     registered (the "non-macOS platform / flutter test" case) — every call
//     genuinely throws MissingPluginException and must degrade to null/no-op.
//  2. The method-channel CONTRACT (method names + argument shapes) the native
//     Swift side in MainFlutterWindow.swift implements. A renamed method or a
//     swapped argument compiles clean but silently breaks all bookmark
//     persistence; a mock handler pins it. (The real macOS-backed success path
//     can only be verified by an actual native build/run — see the plan.)

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/local/security_scoped_bookmark.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('magicgit/bookmarks');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('with no native channel registered', () {
    test('create() returns null', () async {
      expect(await SecurityScopedBookmark.create('/some/path'), isNull);
    });

    test('startAccessing() returns null', () async {
      expect(await SecurityScopedBookmark.startAccessing('bm-data'), isNull);
    });

    test('stopAccessing() completes without throwing', () async {
      await expectLater(
        SecurityScopedBookmark.stopAccessing('/some/path'),
        completes,
      );
    });
  });

  group('method-channel contract', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'createBookmark' => 'Ym9va21hcms=',
          'startAccessingBookmark' => '/resolved/path',
          _ => null,
        };
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('create() invokes createBookmark(path) and returns the data', () async {
      final data = await SecurityScopedBookmark.create('/repos/proj');
      expect(data, 'Ym9va21hcms=');
      expect(calls.single.method, 'createBookmark');
      expect(calls.single.arguments, '/repos/proj');
    });

    test(
      'startAccessing() invokes startAccessingBookmark(data) and returns the '
      'resolved path',
      () async {
        final path = await SecurityScopedBookmark.startAccessing('Ym9va21hcms=');
        expect(path, '/resolved/path');
        expect(calls.single.method, 'startAccessingBookmark');
        expect(calls.single.arguments, 'Ym9va21hcms=');
      },
    );

    test('stopAccessing() invokes stopAccessingBookmark(path)', () async {
      await SecurityScopedBookmark.stopAccessing('/resolved/path');
      expect(calls.single.method, 'stopAccessingBookmark');
      expect(calls.single.arguments, '/resolved/path');
    });

    test('a PlatformException from the native side degrades to null', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'resolve_failed', message: 'stale');
      });
      expect(await SecurityScopedBookmark.create('/p'), isNull);
      expect(await SecurityScopedBookmark.startAccessing('d'), isNull);
      await expectLater(SecurityScopedBookmark.stopAccessing('/p'), completes);
    });
  });
}
