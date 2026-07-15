import 'dart:async';
import 'dart:io';

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
      humanizeSshError(
        const SocketException('Connection refused'),
      ),
      contains('Connection refused'),
    );
    expect(
      humanizeSshError(TimeoutException('auth')),
      contains('Timed out reaching'),
    );
  });

  test('humanizeSshError maps auth-shaped strings', () {
    expect(
      humanizeSshError(Exception('SSHAuthFailError: All authentication methods failed')),
      contains('Authentication failed'),
    );
  });
}
