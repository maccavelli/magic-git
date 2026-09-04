import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/native_ssh_socket.dart';

void main() {
  test(
    'NativeSshSocket connects with tcpNoDelay and round-trips a byte',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final serverDone = Completer<void>();
      final sub = server.listen((client) async {
        addTearDown(client.destroy);
        client.add(utf8.encode('ok'));
        await client.flush();
        await client.close();
        serverDone.complete();
      });
      addTearDown(sub.cancel);

      final socket = await NativeSshSocket.connect(
        '127.0.0.1',
        server.port,
        timeout: const Duration(seconds: 2),
      );
      addTearDown(socket.destroy);

      final chunks = <int>[];
      await for (final chunk in socket.stream) {
        chunks.addAll(chunk);
      }
      expect(utf8.decode(chunks), 'ok');
      await serverDone.future;
      await socket.close();
    },
  );

  test('NativeSshSocket.sink writes before the peer closes', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final received = Completer<Uint8List>();
    final sub = server.listen((client) async {
      addTearDown(client.destroy);
      final builder = BytesBuilder();
      await for (final chunk in client) {
        builder.add(chunk);
        if (builder.length >= 4) break;
      }
      if (!received.isCompleted) {
        received.complete(Uint8List.fromList(builder.takeBytes()));
      }
      client.destroy();
    });
    addTearDown(sub.cancel);

    final socket = await NativeSshSocket.connect(
      '127.0.0.1',
      server.port,
      timeout: const Duration(seconds: 2),
    );
    addTearDown(socket.destroy);
    socket.sink.add(utf8.encode('ping'));
    await socket.flush();
    expect(utf8.decode(await received.future), 'ping');
    socket.destroy();
  });

  test('applyTcpOptions sets tcpNoDelay and Darwin SO_KEEPALIVE', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final sub = server.listen((client) => addTearDown(client.destroy));
    addTearDown(sub.cancel);

    final socket = await Socket.connect(
      '127.0.0.1',
      server.port,
      timeout: const Duration(seconds: 2),
    );
    addTearDown(socket.destroy);

    NativeSshSocket.applyTcpOptions(socket);

    // Read the option back rather than trusting the setter: SO_KEEPALIVE is
    // not a SocketOption, so it is applied raw and a silent no-op would be
    // indistinguishable from success.
    final value = socket.getRawOption(
      RawSocketOption(RawSocketOption.levelSocket, 0x0008, Uint8List(4)),
    );
    expect(
      value.any((b) => b != 0),
      isTrue,
      reason: 'SO_KEEPALIVE should read back as enabled on Darwin',
    );
  });

  test('a socket that rejects setRawOption still gets tcpNoDelay', () {
    final socket = _NoRawOptionSocket();

    // The point of the bare catch in applyTcpOptions: keepalive is a nicety,
    // the connect is not. A platform without SO_KEEPALIVE must still connect.
    expect(() => NativeSshSocket.applyTcpOptions(socket), returnsNormally);
    expect(socket.options, [(SocketOption.tcpNoDelay, true)]);
    expect(socket.rawAttempts, 1);
  });

  test('a socket whose options are refused is destroyed, not leaked', () {
    // Socket.connect has already succeeded by the time the options are
    // applied, and tcpNoDelay sits deliberately outside the best-effort try
    // that guards SO_KEEPALIVE. A peer that closes in that window makes
    // setOption throw, and the exception used to leave connect() with the
    // socket neither closed nor destroyed — one leaked descriptor per attempt,
    // and _autoReconnect allows twenty (0024 L1).
    final socket = _OptionRefusingSocket();
    expect(
      () => NativeSshSocket.adopt(socket),
      throwsA(isA<SocketException>()),
    );
    expect(socket.destroyed, isTrue, reason: 'the descriptor must not leak');
  });
}

/// Accepts [Socket.setOption] and throws on every raw option, standing in for
/// a platform where `SO_KEEPALIVE` is unavailable. Everything else is routed
/// through `noSuchMethod` — the test touches only these two members.
class _NoRawOptionSocket implements Socket {
  final List<(SocketOption, bool)> options = [];
  int rawAttempts = 0;

  @override
  bool setOption(SocketOption option, bool enabled) {
    options.add((option, enabled));
    return true;
  }

  @override
  void setRawOption(RawSocketOption option) {
    rawAttempts++;
    throw const SocketException('SO_KEEPALIVE unsupported');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OptionRefusingSocket implements Socket {
  bool destroyed = false;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      throw const SocketException('closed by peer');

  @override
  void destroy() => destroyed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
