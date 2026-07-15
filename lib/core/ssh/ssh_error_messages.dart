import 'dart:async';
import 'dart:io' show SocketException;

import 'package:dartssh2/dartssh2.dart';

import 'ssh_command_executor.dart';

/// Maps raw SSH/transport exceptions to short, actionable copy for dialogs and
/// the connection landing card. Host-key mismatches are handled by
/// [HostKeyPrompt] and are not rewritten here.
String humanizeSshError(Object error) {
  if (error is SSHCommandTimeout) {
    return 'Timed out waiting for the remote command to finish.';
  }
  if (error is SSHCommandSuperseded) {
    return 'The connection changed before this command could run. Try again.';
  }
  if (error is SSHOutputExceeded) {
    return 'The remote command produced more output than this app will buffer.';
  }
  if (error is SSHAuthFailError || error is SSHAuthAbortError) {
    return 'Authentication failed — check the username, password, or private key.';
  }
  if (error is SSHHostkeyError) {
    return 'The host key could not be verified.';
  }
  if (error is SSHKeyDecodeError || error is SSHKeyDecryptError) {
    return 'The private key could not be read — check the key format and passphrase.';
  }
  if (error is SSHChannelOpenError) {
    return 'The host refused another SSH session (session limit). '
        'Close other SSH tools on that host, or wait and try again.';
  }
  if (error is TimeoutException) {
    return 'Timed out reaching the host.';
  }
  if (error is SocketException) {
    final msg = error.message.toLowerCase();
    if (msg.contains('refused')) {
      return 'Connection refused — is the host reachable and SSH listening?';
    }
    if (msg.contains('network is unreachable') ||
        msg.contains('no route to host')) {
      return 'Network unreachable — check VPN or network connectivity.';
    }
    if (msg.contains('failed host lookup') || msg.contains('nodename')) {
      return 'Could not resolve the host name.';
    }
    return 'Network error: ${error.message}';
  }
  if (error is ArgumentError) {
    final m = error.message?.toString() ?? error.toString();
    if (m.toLowerCase().contains('password') ||
        m.toLowerCase().contains('private key')) {
      return 'A password or private key is required to connect.';
    }
  }

  final s = error.toString();
  final lower = s.toLowerCase();
  if (lower.contains('auth') &&
      (lower.contains('fail') || lower.contains('denied'))) {
    return 'Authentication failed — check the username, password, or private key.';
  }
  if (lower.contains('connection refused')) {
    return 'Connection refused — is the host reachable and SSH listening?';
  }
  if (lower.contains('timed out') || lower.contains('timeout')) {
    return 'Timed out reaching the host.';
  }
  if (lower.contains('network is unreachable') ||
      lower.contains('no route to host')) {
    return 'Network unreachable — check VPN or network connectivity.';
  }
  if (lower.contains('channel') && lower.contains('open')) {
    return 'The host refused another SSH session (session limit). '
        'Close other SSH tools on that host, or wait and try again.';
  }
  if (lower.contains('hostkey') || lower.contains('host key')) {
    return 'The host key could not be verified.';
  }

  // Last resort: strip a common "Exception: " prefix so raw library text is
  // still readable without the Dart exception class noise.
  return s
      .replaceFirst(RegExp(r'^(Exception|Error|StateError):\s*'), '')
      .trim();
}
