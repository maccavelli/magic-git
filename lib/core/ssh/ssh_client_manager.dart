import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../utils/pausable_timeout.dart';

class SSHConnectionProfile {
  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKey;
  final String? passphrase;

  const SSHConnectionProfile({
    required this.host,
    this.port = 22,
    required this.username,
    this.password,
    this.privateKey,
    this.passphrase,
  });
}

/// Owns the single long-lived SSH connection. POSIX remotes only (a native
/// Windows port lives in a separate codebase), so there is no shell probing.
class SSHClientManager {
  static const Duration _socketTimeout = Duration(seconds: 15);
  static const Duration _authTimeout = Duration(seconds: 15);

  SSHClient? _client;

  /// Every client currently being authenticated by an in-flight [connect].
  /// Tracked separately from [_client] (which is only assigned once auth
  /// succeeds) so [disconnect] can force-close all of them immediately
  /// instead of leaving their handshakes to run unbounded in the background.
  /// A set, not a single nullable slot: if two connect() attempts overlap
  /// during the handshake phase (e.g. a fast reconnect-tap racing an already
  /// in-flight attempt), a single slot would only track whichever attempt
  /// wrote it last, leaving an earlier attempt's socket silently open past a
  /// disconnect() until its own auth timeout eventually closes it.
  final Set<SSHClient> _pending = {};

  /// Monotonic attempt counter. Every [connect]/[disconnect] bumps it; an
  /// in-flight connect that finds the counter changed knows it has been
  /// superseded (by a newer connect or a disconnect) and tears its client down
  /// instead of attaching it — this prevents attaching the UI to the wrong host
  /// and prevents leaking an authenticated connection past a disconnect.
  int _generation = 0;

  SSHClient? get client => _client;

  /// Current attempt generation. Bumped by every [connect]/[disconnect].
  /// Exposed so callers that queue work against the *current* connection
  /// (notably [SSHCommandExecutor]'s serialized command queue) can detect
  /// that a reconnect/disconnect happened before their turn came up, and
  /// refuse to run against whatever host happens to be connected by then.
  int get generation => _generation;

  /// Completes when the active connection's transport closes — whether from a
  /// remote-side drop, network loss, or our own [disconnect]. Callers use it to
  /// detect an unexpected drop (and offer reconnect). Null when not connected.
  Future<void>? get done => _client?.done;

  /// Connects to [profile]. When given, [onVerifyHostKey] is consulted with
  /// the presented host key's algorithm name and OpenSSH-style SHA256
  /// fingerprint (`SHA256:<base64>`, matching `ssh-keygen -lf`'s output) —
  /// return true to trust it and proceed, false to reject it and abort the
  /// connection. Omitting it accepts any host key unverified.
  Future<void> connect(
    SSHConnectionProfile profile, {
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
  }) async {
    final gen = ++_generation;
    // The previous client (if any) is deliberately left open and serving
    // `client`/`done` through this entire attempt — it's only retired once
    // the new one actually succeeds, at the very end of this method. This
    // used to close it eagerly at the top, so switching to a connection that
    // then failed (bad host, auth failure, network down) left the user fully
    // disconnected even though the connection they already had was still
    // fine. `previous` itself is never reassigned to `_client` again; it's
    // only closed, either here on success or by whatever supersedes this
    // attempt (a concurrent disconnect() closes whatever `_client` currently
    // is, which is still `previous` until the line below runs).
    final previous = _client;

    final socket = await SSHSocket.connect(
      profile.host,
      profile.port,
      timeout: _socketTimeout,
    );

    // A host-key mismatch pauses on `onVerifyHostKey` awaiting an explicit
    // human decision (see [ConnectionController._verifyHostKey]), which can
    // legitimately take far longer than [_authTimeout] — this flag lets the
    // timeout below tell "genuinely stuck" apart from "waiting on a person."
    var awaitingHostKeyDecision = false;
    // `SSHKeyPair.fromPem` is evaluated eagerly as a constructor argument and
    // throws on a malformed key / wrong passphrase — before the SSHClient that
    // would own closing the socket is ever constructed. Close the already-open
    // socket ourselves on any throw here, or a bad/encrypted key leaks it once
    // per attempt (and auto-reconnect repeats the attempt).
    final SSHClient client;
    try {
      client = SSHClient(
        socket,
        username: profile.username,
        onPasswordRequest: () => profile.password ?? '',
        identities: profile.privateKey != null
            ? SSHKeyPair.fromPem(profile.privateKey!, profile.passphrase)
            : null,
        // Explicit keepalive so a dead peer (dropped Wi-Fi, NAT/firewall idle
        // timeout) surfaces promptly on `done`, which drives auto-reconnect.
        keepAliveInterval: const Duration(seconds: 10),
        onVerifyHostKey: onVerifyHostKey == null
            ? null
            : (type, fingerprint) async {
                awaitingHostKeyDecision = true;
                try {
                  return await onVerifyHostKey(type, fingerprint);
                } finally {
                  awaitingHostKeyDecision = false;
                }
              },
      );
    } catch (_) {
      socket.destroy();
      rethrow;
    }

    // Superseded while the socket was connecting — `previous` is left
    // untouched for whatever superseded this attempt (a fresh connect() or a
    // disconnect()) to deal with.
    if (gen != _generation) {
      client.close();
      return;
    }

    // Exposed for the duration of the handshake so a concurrent disconnect()
    // can force-close this exact client rather than only marking it stale.
    _pending.add(client);
    try {
      await awaitWithPausableTimeout(
        client.authenticated,
        _authTimeout,
        isPaused: () => awaitingHostKeyDecision,
      );
    } catch (_) {
      client.close();
      rethrow;
    } finally {
      _pending.remove(client);
    }

    // Superseded while authenticating — don't leak the live connection.
    if (gen != _generation) {
      client.close();
      return;
    }

    // This attempt wins: only now do we retire the previous client.
    previous?.close();
    _client = client;
  }

  Future<void> disconnect() async {
    ++_generation; // supersede any in-flight connect
    // Force-close every in-flight auth handshake immediately rather than
    // leaving them to run unbounded in the background until the generation
    // check (or the auth timeout) eventually notices they were superseded.
    for (final client in _pending) {
      client.close();
    }
    _pending.clear();
    _closeClient();
  }

  void _closeClient() {
    _client?.close();
    _client = null;
  }
}
