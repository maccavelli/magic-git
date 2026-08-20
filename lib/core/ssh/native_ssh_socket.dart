import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// [SSHSocket] over a [Socket] we own, so TCP options dartssh2's
/// [SSHSocket.connect] never sets can be applied before the handshake.
///
/// [SocketOption.tcpNoDelay] is load-bearing for request/response multiplexed
/// with bulk. Darwin `SO_KEEPALIVE` is best-effort (not a [SocketOption]); a
/// throw must not fail the connect. Library `keepAliveInterval` stays off.
class NativeSshSocket implements SSHSocket {
  NativeSshSocket._(this._socket);

  final Socket _socket;

  /// Darwin `SO_KEEPALIVE`. Magic Git is macOS-only.
  static const int _soKeepAlive = 0x0008;

  static Future<SSHSocket> connect(
    String host,
    int port, {
    Duration? timeout,
  }) async {
    // Ownership transfers to NativeSshSocket; close/destroy are the API.
    // ignore: close_sinks
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    try {
      socket.setRawOption(
        RawSocketOption.fromBool(
          RawSocketOption.levelSocket,
          _soKeepAlive,
          true,
        ),
      );
    } catch (_) {
      // Best-effort. tcpNoDelay is the load-bearing option.
    }
    return NativeSshSocket._(socket);
  }

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() async {
    await _socket.close();
  }

  @override
  void destroy() {
    _socket.destroy();
  }

  @override
  Future<void> flush() async {
    await _socket.flush();
  }
}
