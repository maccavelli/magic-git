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
}
