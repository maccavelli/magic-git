import 'dart:async';
import 'dart:developer' as developer;
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
/// Three consecutive failures (not one) are required, and pings never overlap
/// — a reply delayed past [pingTimeout] by a saturated link mustn't kill a
/// connection that's actually fine. Three rather than two: with the read lane
/// running several concurrent compressed transfers, a slow link can
/// legitimately starve keepalive replies for tens of seconds; a false kill
/// costs far more (a reconnect fails every in-flight command as superseded)
/// than the extra ~15 s a real dead peer now takes to detect.
class ConnectionHealthMonitor {
  ConnectionHealthMonitor({
    required this.ping,
    required this.onDead,
    this.onPingSample,
    this.interval = const Duration(seconds: 15),
    this.pingTimeout = const Duration(seconds: 15),
    this.failureThreshold = 3,
  });

  /// Sends one keepalive round trip; the returned future completes when the
  /// peer replies (dartssh2's `SSHClient.ping`).
  final Future<void> Function() ping;

  /// Invoked exactly once, after [failureThreshold] consecutive failed pings.
  final void Function() onDead;

  /// Invoked with each *answered* ping's round-trip time — the probes were
  /// already being sent every [interval]; this just stops discarding the
  /// timing so the dashboard can chart link latency for free.
  final void Function(Duration rtt)? onPingSample;

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
      final sw = Stopwatch()..start();
      await ping().timeout(pingTimeout);
      _failures = 0;
      if (!_stopped) onPingSample?.call(sw.elapsed);
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

/// Owns the long-lived SSH connection(s). POSIX remotes only (a native
/// Windows port lives in a separate codebase), so there is no shell probing.
///
/// **Dual client:** when connect succeeds, a second [SSHClient] is opened for
/// long-lived streams (watcher, CI trace) so request/response traffic and
/// streams each get their own OpenSSH `MaxSessions` budget. If the stream
/// client fails to authenticate, the session **degrades** to a single client
/// (streams share the command client) rather than failing connect.
class SSHClientManager {
  static const Duration _socketTimeout = Duration(seconds: 15);
  static const Duration _authTimeout = Duration(seconds: 15);
  /// Stream client is best-effort; fail open to single-client quickly.
  static const Duration _streamAuthTimeout = Duration(seconds: 10);

  /// Command / SFTP / health-monitor client (primary).
  SSHClient? _client;

  /// Long-lived stream client; null when degraded to single-client mode.
  SSHClient? _streamClient;

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

  /// Primary client (commands, SFTP, health). Backward-compatible name.
  SSHClient? get client => _client;

  /// Client for [SSHCommandExecutor.executeStream]. Falls back to [client]
  /// when the dual stream client failed to connect (degraded mode).
  SSHClient? get streamClient => _streamClient ?? _client;

  /// True when streams share the command client (stream open failed).
  bool get streamClientDegraded =>
      _client != null && _streamClient == null;

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

  /// Completes when the primary (command) transport closes — whether from a
  /// remote-side drop, network loss, or our own [disconnect]. Callers use it to
  /// detect an unexpected drop (and offer reconnect). Null when not connected.
  /// Stream-only death does **not** complete this; watchers restart on their own.
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
    void Function(Duration rtt)? onPingSample,
  }) async {
    final gen = ++_generation;
    // The previous clients (if any) are deliberately left open and serving
    // `client`/`done` through this entire attempt — they're only retired once
    // the new command client actually succeeds, at the very end of this method.
    final previousCmd = _client;
    final previousStream = _streamClient;

    final cmdClient = await _openAuthenticatedClient(
      profile,
      gen: gen,
      onVerifyHostKey: onVerifyHostKey,
      authTimeout: _authTimeout,
    );
    if (cmdClient == null) {
      // Superseded during command-client handshake — leave previous attached.
      return;
    }

    // Best-effort second client for streams. Never fail the whole connect if
    // this fails — degrade to single-client (streams share command client).
    SSHClient? streamClient;
    try {
      streamClient = await _openAuthenticatedClient(
        profile,
        gen: gen,
        onVerifyHostKey: onVerifyHostKey,
        authTimeout: _streamAuthTimeout,
      );
    } catch (e, st) {
      developer.log(
        'stream SSH client failed; degrading to single client: $e',
        name: 'SSHClientManager',
        error: e,
        stackTrace: st,
      );
      streamClient = null;
    }
    // Superseded after stream attempt — drop both new clients.
    if (gen != _generation) {
      cmdClient.close();
      streamClient?.close();
      return;
    }

    // This attempt wins: only now do we retire the previous clients.
    _health?.stop();
    previousCmd?.close();
    // Avoid double-close when previous was already degraded (stream == null)
    // or when stream shared nothing with cmd.
    if (previousStream != null && !identical(previousStream, previousCmd)) {
      previousStream.close();
    }
    _client = cmdClient;
    _streamClient = streamClient;
    _clientGeneration = gen;

    // Health monitor on the command client only. onDead must close both
    // clients but *not* null [_client]: ConnectionController listens to
    // [done] on the primary client to drive reconnect — nulling it would
    // drop that Future before the drop path observes it.
    final monitor = ConnectionHealthMonitor(
      ping: () => cmdClient.ping(),
      onDead: () {
        final stream = _streamClient;
        if (stream != null && !identical(stream, cmdClient)) {
          stream.close();
        }
        _streamClient = null;
        cmdClient.close();
      },
      onPingSample: onPingSample,
    )..start();
    _health = monitor;
    unawaited(
      cmdClient.done.then((_) {}, onError: (_) {}).whenComplete(monitor.stop),
    );
  }

  /// Opens and authenticates one [SSHClient]. Returns null if [gen] was
  /// superseded mid-handshake. Throws on auth/socket failure (caller decides
  /// whether that fails connect or degrades).
  Future<SSHClient?> _openAuthenticatedClient(
    SSHConnectionProfile profile, {
    required int gen,
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
    required Duration authTimeout,
  }) async {
    final socket = await SSHSocket.connect(
      profile.host,
      profile.port,
      timeout: _socketTimeout,
    );

    // A host-key mismatch pauses on `onVerifyHostKey` awaiting an explicit
    // human decision (see [ConnectionController._verifyHostKey]), which can
    // legitimately take far longer than the auth timeout — this flag lets the
    // timeout below tell "genuinely stuck" apart from "waiting on a person."
    var awaitingHostKeyDecision = false;
    // `SSHKeyPair.fromPem` is evaluated eagerly as a constructor argument and
    // throws on a malformed key / wrong passphrase — before the SSHClient that
    // would own closing the socket is ever constructed. Close the already-open
    // socket ourselves on any throw here, or a bad/encrypted key leaks it once
    // per attempt (and auto-reconnect repeats the attempt).
    // Auth method selection is deliberate: a non-null `onPasswordRequest`
    // *registers* the password method with the server. Returning `''` for a
    // key-only profile would attempt empty-password auth on every connect
    // (burning MaxAuthTries / fail2ban and delaying publickey). Only enable
    // password when a real password was supplied; only enable publickey when
    // a private key was supplied. Require at least one — otherwise auth can
    // never succeed and we fail fast instead of hanging on `none`.
    final password = profile.password;
    final privateKey = profile.privateKey;
    final hasPassword = password != null && password.isNotEmpty;
    final hasKey = privateKey != null && privateKey.isNotEmpty;
    if (!hasPassword && !hasKey) {
      socket.destroy();
      throw ArgumentError(
        'SSHConnectionProfile requires a password or a private key',
      );
    }

    final SSHClient client;
    try {
      client = SSHClient(
        socket,
        username: profile.username,
        // Only when a password exists — see comment above.
        onPasswordRequest: hasPassword ? () => password : null,
        identities: hasKey
            ? SSHKeyPair.fromPem(privateKey, profile.passphrase)
            : null,
        // Dead-peer detection is owned by [ConnectionHealthMonitor]
        // (which checks whether pings are *answered*). The library's own
        // keepAliveInterval fires-and-forgets without a reply counter, and
        // stacking both doubles global-request traffic during bulk reads —
        // so leave the library keepalive off.
        keepAliveInterval: null,
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

    // Superseded while the socket was connecting.
    if (gen != _generation) {
      client.close();
      return null;
    }

    // Exposed for the duration of the handshake so a concurrent disconnect()
    // can force-close this exact client rather than only marking it stale.
    _pending.add(client);
    try {
      await awaitWithPausableTimeout(
        client.authenticated,
        authTimeout,
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
      return null;
    }
    return client;
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
    final cmd = _client;
    final stream = _streamClient;
    _client = null;
    _streamClient = null;
    _clientGeneration = -1;
    cmd?.close();
    if (stream != null && !identical(stream, cmd)) {
      stream.close();
    }
  }
}
