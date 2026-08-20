import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/ssh/ssh_error_messages.dart';

void main() {
  test('humanizeSshError maps timeouts and supersession', () {
    expect(
      humanizeSshError(const SSHCommandTimeout('git status')),
      contains('Timed out'),
    );
    expect(
      humanizeSshError(const SSHCommandSuperseded('git status')),
      contains('connection changed'),
    );
  });

  test('humanizeSshError maps network failures', () {
    expect(
      humanizeSshError(const SocketException('Connection refused')),
      contains('Connection refused'),
    );
    expect(
      humanizeSshError(TimeoutException('auth')),
      contains('Timed out reaching'),
    );
  });

  test('humanizeSshError maps auth-shaped strings', () {
    expect(
      humanizeSshError(
        Exception('SSHAuthFailError: All authentication methods failed'),
      ),
      contains('Authentication failed'),
    );
  });

  test('humanizeSshError maps SSHDisconnectError', () {
    expect(
      humanizeSshError(
        SSHDisconnectError(3, 'no matching key exchange method found'),
      ),
      'The host closed the connection (3: no matching key exchange method found).',
    );
  });

  test('humanizeSshError unwraps SSHAuthAbortError.reason', () {
    expect(
      humanizeSshError(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHDisconnectError(3, 'no matching key exchange method found'),
        ),
      ),
      'The host closed the connection (3: no matching key exchange method found).',
    );
  });

  test('humanizeSshError maps SSHHandshakeError', () {
    expect(
      humanizeSshError(SSHHandshakeError('Handshake timed out')),
      'Timed out during the SSH handshake.',
    );
  });

  test('humanizeSshError maps SSHPacketError', () {
    expect(
      humanizeSshError(SSHPacketError('truncated')),
      'The SSH session received a malformed packet.',
    );
  });

  test('peerDisconnectReason and transportLostMessage', () {
    expect(peerDisconnectReason(Exception('x')), isNull);
    expect(transportLostMessage(null), 'Connection lost');
    expect(transportLostMessage(Exception('x')), 'Connection lost');
    final err = SSHDisconnectError(3, 'no matching key exchange method found');
    expect(
      peerDisconnectReason(err),
      '3: no matching key exchange method found',
    );
    expect(
      transportLostMessage(err),
      'Connection lost (3: no matching key exchange method found)',
    );
    expect(
      peerDisconnectReason(
        SSHAuthAbortError('Connection closed before authentication', err),
      ),
      '3: no matching key exchange method found',
    );
  });
}
