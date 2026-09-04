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

  test('isRetryableReconnectError allowlist vs auth/host-key', () {
    expect(
      isRetryableReconnectError(const SocketException('timed out')),
      isTrue,
    );
    expect(isRetryableReconnectError(SSHSocketError('reset')), isTrue);
    expect(isRetryableReconnectError(TimeoutException('x')), isTrue);
    expect(
      isRetryableReconnectError(SSHHandshakeError('Handshake timed out')),
      isTrue,
    );
    expect(isRetryableReconnectError(SSHDisconnectError(11, 'bye')), isTrue);
    expect(isRetryableReconnectError(SSHStateError('closed')), isTrue);
    expect(
      isRetryableReconnectError(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHDisconnectError(11, 'bye'),
        ),
      ),
      isTrue,
    );
    expect(
      isRetryableReconnectError(Exception('connection reset by peer')),
      isTrue,
    );

    expect(
      isRetryableReconnectError(
        SSHAuthFailError('All authentication methods failed'),
      ),
      isFalse,
    );
    expect(
      isRetryableReconnectError(SSHAuthAbortError('no more auth methods')),
      isFalse,
    );
    expect(isRetryableReconnectError(SSHHostkeyError('mismatch')), isFalse);
    expect(isRetryableReconnectError(SSHKeyDecodeError('bad pem')), isFalse);
    expect(
      isRetryableReconnectError(SSHKeyDecryptError('bad passphrase')),
      isFalse,
    );
    expect(isRetryableReconnectError(ArgumentError('no secret')), isFalse);
    expect(
      isRetryableReconnectError(SSHInternalError('kex mismatch')),
      isFalse,
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

  test('a not-ready transport reads as still connecting, not as a failure', () {
    // MADR 0018: this used to be a bare Exception, so humanizeSshError had no
    // branch for it and displayError handed the raw developer string to the
    // Repository panel.
    const error = SSHTransportNotReady('git status');
    final message = humanizeSshError(error);

    expect(message, contains('Still connecting'));
    expect(message, isNot(contains('not ready')));
    expect(message, isNot(contains('SSH transport')));
    expect(message, isNot(contains('git status')));
  });

  test('the not-ready message never reads as an error the user caused', () {
    final message = humanizeSshError(
      const SSHTransportNotReady('git ls-files'),
    ).toLowerCase();
    for (final blame in const ['failed', 'error', 'not established']) {
      expect(message, isNot(contains(blame)), reason: 'reads as a failure');
    }
  });

  group('developer text never reaches the UI', () {
    test('a full stream budget reads as an action, not a counter', () {
      final msg = humanizeSshError(
        const SSHStreamBudgetExhausted('fswatch', 8, 8),
      );
      expect(msg, contains('Too many live streams'));
      expect(msg, isNot(contains('8/8')));
    });

    test('a reclaimed lane slot does not leak its developer note', () {
      // CommandLaneOverrun.toString() is a two-sentence note aimed at whoever
      // is debugging the executor ("This is a bug in the command executor…").
      // Rare by construction, but rare is what left the watchdog unenforced
      // until it was added, and this string is worse than the ones MADR 0018
      // was written to rewrite (0024 L2).
      final msg = humanizeSshError(
        const CommandLaneOverrun(ExecLane.read, Duration(seconds: 90)),
      );
      expect(msg, 'A command did not finish and was abandoned. Try again.');
      expect(msg, isNot(contains('bug in the command executor')));
    });
  });
}
