// MADR 0030 T2.4. `ProxyCommandExecutor.uploadBytes` — the path by which a
// pop-out editor writes a file back to the host.
//
// 18 of its 26 lines were uncovered, in the executor with one test file naming
// it, at 60 % coverage. The failure modes here are a lost edit and a silently
// corrupted file, so the assertions are about bytes and about errors surfacing
// — not about the method being called.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/exec/proxy_command_executor.dart';
import 'package:remote_magic_git/core/window/window_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowId = 'w-upload';
  final channel = MethodChannel(windowHubChannel(windowId));
  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Bytes a lossy String round trip would destroy: a NUL (which the native
  /// codec truncates at, per AGENTS.md) and invalid UTF-8.
  final hostile = Uint8List.fromList([
    0x68,
    0x69,
    0x00,
    0xff,
    0xfe,
    0xc3,
    0x28,
    0x0a,
    0x7a,
  ]);

  test('bytes cross the relay as Uint8List, byte-identical', () async {
    Object? seen;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'uploadBytes') seen = call.arguments;
      // The main window's success shape. A null reply is itself an error the
      // proxy reports — "returned no response" — which is the right default:
      // silence must not read as a saved file.
      return <String, Object?>{'ok': true};
    });

    await ProxyCommandExecutor.forWindow(
      windowId,
    ).uploadBytes('/host/path.bin', hostile, routingRepo: '/srv/repo');

    final map = seen! as Map<Object?, Object?>;
    expect(
      map['bytes'],
      isA<Uint8List>(),
      reason: 'never a String — the native codec truncates at the first NUL',
    );
    expect(map['bytes'], orderedEquals(hostile));
    expect(map['remotePath'], '/host/path.bin');
    expect(map['routingRepo'], '/srv/repo');

    // And the payload survives the decoder the main window runs.
    final decoded = decodeUploadBytesRequest(map);
    expect(decoded.bytes, orderedEquals(hostile));
  });

  test('a missing routingRepo is refused BEFORE any channel call', () async {
    var called = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      called = true;
      return <String, Object?>{'ok': true};
    });

    await expectLater(
      ProxyCommandExecutor.forWindow(
        windowId,
      ).uploadBytes('/p', hostile, routingRepo: null),
      throwsA(isA<ProxyExecuteException>()),
    );
    expect(
      called,
      isFalse,
      reason:
          'the main window must never be asked to write a file it cannot route '
          'to a session',
    );
  });

  test('an empty routingRepo is refused too', () async {
    await expectLater(
      ProxyCommandExecutor.forWindow(
        windowId,
      ).uploadBytes('/p', hostile, routingRepo: ''),
      throwsA(isA<ProxyExecuteException>()),
    );
  });

  test('a main-window failure surfaces, it is not a silent success', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'EIO', message: 'disk full');
    });

    await expectLater(
      ProxyCommandExecutor.forWindow(
        windowId,
      ).uploadBytes('/p', hostile, routingRepo: '/srv/repo'),
      throwsA(
        isA<ProxyExecuteException>().having(
          (e) => e.toString(),
          'message',
          contains('disk full'),
        ),
      ),
      reason: 'a swallowed failure here is an edit the user believes was saved',
    );
  });

  test('a main window that is gone surfaces as a proxy error', () async {
    // No handler registered at all: the platform reports MissingPluginException.
    messenger.setMockMethodCallHandler(channel, null);
    await expectLater(
      ProxyCommandExecutor.forWindow(
        windowId,
      ).uploadBytes('/p', hostile, routingRepo: '/srv/repo'),
      throwsA(isA<ProxyExecuteException>()),
    );
  });

  test('a null reply is an error, not a saved file', () async {
    // Silence from the main window must never read as success — this is the
    // difference between "your edit is on the host" and "your edit is gone".
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    await expectLater(
      ProxyCommandExecutor.forWindow(
        windowId,
      ).uploadBytes('/p', hostile, routingRepo: '/srv/repo'),
      throwsA(isA<ProxyExecuteException>()),
    );
  });

  test('a not-ok reply surfaces as an error', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => <String, Object?>{
        'ok': false,
        'error': 'permission denied',
      },
    );
    await expectLater(
      ProxyCommandExecutor.forWindow(
        windowId,
      ).uploadBytes('/p', hostile, routingRepo: '/srv/repo'),
      throwsA(isA<Object>()),
    );
  });
}
