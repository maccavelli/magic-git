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

/// Actively verifies a connection is still alive by pinging it on an interval
/// and declaring it dead after consecutive unanswered pings.
///
/// Why this exists: dartssh2's own `keepAliveInterval` sends a keepalive ping
/// every few seconds but *never checks whether it was answered* — no
/// unanswered-ping counter, no timeout on the reply. A NAT/firewall silently
/// dropping the connection therefore surfaces only when TCP itself gives up
/// (minutes) or the next command hits its own timeout (up to 60s of a wedged
/// UI). This monitor turns that into prompt detection: [onDead] force-closes
/// the client, its `done` completes, and the existing auto-reconnect machinery
/// takes over within seconds.
///
/// Two consecutive failures (not one) are required, and pings never overlap —
/// a single reply delayed past [pingTimeout] by a saturated link mustn't kill
/// a connection that's actually fine.
class ConnectionHealthMonitor {
  ConnectionHealthMonitor({
    required this.ping,
    required this.onDead,
    this.interval = const Duration(seconds: 15),
    this.pingTimeout = const Duration(seconds: 15),
    this.failureThreshold = 2,
  });

  /// Sends one keepalive round trip; the returned future completes when the
  /// peer replies (dartssh2's `SSHClient.ping`).
  final Future<void> Function() ping;

  /// Invoked exactly once, after [failureThreshold] consecutive failed pings.
  final void Function() onDead;

  final Duration interval;
  final Duration pingTimeout;
  final int failureThreshold;

  Timer? _timer;
  int _failures = 0;
  bool _probeInFlight = false;
  bool _stopped = false;

  /// Consecutive failed probes so far — for tests/diagnostics.
  int get failures => _failures;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => _probe());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _probe() async {
    // Never stack probes: a ping still awaiting its reply when the next tick
    // fires would double-count one slow round trip as two failures.
    if (_probeInFlight || _stopped) return;
    _probeInFlight = true;
    try {
      await ping().timeout(pingTimeout);
      _failures = 0;
    } catch (_) {
      if (_stopped) return;
      if (++_failures >= failureThreshold) {
        stop();
        onDead();
      }
    } finally {
      _probeInFlight = false;
    }
  }
}

/// Owns the single long-lived SSH connection. POSIX remotes only (a native
/// Windows port lives in a separate codebase), so there is no shell probing.
class SSHClientManager {
  static const Duration _socketTimeout = Duration(seconds: 15);
  static const Duration _authTimeout = Duration(seconds: 15);

  SSHClient? _client;

  /// Active dead-peer monitor for [_client] (see [ConnectionHealthMonitor]).
  /// Started when a connect succeeds, stopped when that client is retired.
  ConnectionHealthMonitor? _health;

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

  /// The generation whose [connect] produced the current [_client], or -1
  /// while no client is attached. Distinct from [generation]: a new connect
  /// bumps [generation] at its *start* but only swaps [_client] at its *end*
  /// (deliberately, so a failed attempt doesn't kill a working session) —
  /// during that window the two disagree, and a command must run against
  /// neither the stale client nor the not-yet-attached new one.
  int _clientGeneration = -1;

  SSHClient? get client => _client;

  /// Current attempt generation. Bumped by every [connect]/[disconnect].
  /// Exposed so callers that queue work against the *current* connection
  /// (notably [SSHCommandExecutor]'s command scheduler) can detect
  /// that a reconnect/disconnect happened before their turn came up, and
  /// refuse to run against whatever host happens to be connected by then.
  int get generation => _generation;

  /// The generation the currently-attached [client] belongs to (-1 when
  /// none). A command pinned to generation G may only run when *both*
  /// [generation] and this equal G — see [_clientGeneration].
  int get clientGeneration => _clientGeneration;

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
    _health?.stop();
    previous?.close();
    _client = client;
    _clientGeneration = gen;

    // Arm dead-peer detection for this client (see ConnectionHealthMonitor).
    // Its onDead force-closes the client, completing `done` so the ordinary
    // drop path (auto-reconnect) takes over. Also stop probing the moment the
    // transport closes for any other reason — the drop path is already
    // handling it, and pinging a closed client would just error pointlessly.
    final monitor = ConnectionHealthMonitor(
      ping: () => client.ping(),
      onDead: client.close,
    )..start();
    _health = monitor;
    unawaited(
      client.done.then((_) {}, onError: (_) {}).whenComplete(monitor.stop),
    );
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
    _health?.stop();
    _health = null;
    _client?.close();
    _client = null;
    _clientGeneration = -1;
  }
}
